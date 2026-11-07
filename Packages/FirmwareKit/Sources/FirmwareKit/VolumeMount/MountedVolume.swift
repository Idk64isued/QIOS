// MountedVolume: VolumeFiles over a folder on the host: a volume VolumeMount.withMounted mounted (the kernel
// backend), or a tree copied off one (the /private/var skeleton a data volume is seeded from). Every call goes
// through DevicePath, so no link on the device's volume is followed: files written in place 0666 less the umask
// (a link or a hard-linked name replaced by a new file), folders 0777 less it.

import Foundation

public final class MountedVolume: VolumeFiles {
    public let root: URL

    public init(root: URL) { self.root = root }

    func url(_ path: String) -> URL { path.isEmpty ? root : root.appendingPathComponent(path) }

    public func item(at path: String) throws -> VolumeItem? {
        guard let st = try DevicePath.status(url(path)) else { return nil }
        let kind: VolumeItem.Kind =
            switch st.st_mode & S_IFMT {
            case S_IFDIR: .folder
            case S_IFLNK: .symlink
            default: .file
            }
        return VolumeItem(
            kind: kind,
            uid: st.st_uid,
            gid: st.st_gid,
            mode: UInt16(st.st_mode),
            size: kind == .folder ? 0 : UInt64(st.st_size),
            modified: Date(
                timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec)
                    / 1e9
            )
        )
    }

    public func contents(at path: String) throws -> Data { try DevicePath.read(url(path)) }

    public func contentsOfDirectory(at path: String) throws -> [String] { try DevicePath.contents(url(path)) }

    public func destinationOfSymlink(at path: String) throws -> String { try DevicePath.linkTarget(url(path)) }

    public func put(_ data: Data, at path: String, mode: UInt16?) throws {
        try DevicePath.write(data, url(path), mode: mode.map { mode_t($0) })
    }

    public func put(contentsOf source: URL, at path: String, mode: UInt16?) throws {
        try put(Data(contentsOf: source), at: path, mode: mode)  // host file
    }

    public func makeDirectory(_ path: String, mode: UInt16?) throws {
        try DevicePath.mkdirs(url(path))
        if let mode { try setMode(path, mode) }
    }

    public func makeSymlink(_ path: String, to target: String) throws { try DevicePath.symlink(url(path), to: target) }

    public func link(_ path: String, to existing: String) throws {
        let from = try DevicePath.parent(url(existing))
        defer { close(from.fd) }
        let to = try DevicePath.parent(url(path))
        defer { close(to.fd) }
        guard linkat(from.fd, from.name, to.fd, to.name, 0) == 0 else { throw DevicePath.failure("link", url(path)) }
    }

    public func rename(_ path: String, to destination: String) throws {
        let from = try DevicePath.parent(url(path))
        defer { close(from.fd) }
        let to = try DevicePath.parent(url(destination))
        defer { close(to.fd) }
        guard renameatx_np(from.fd, from.name, to.fd, to.name, UInt32(RENAME_EXCL)) == 0 else {
            throw DevicePath.failure("rename", url(path))
        }
    }

    public func remove(_ path: String) throws { try DevicePath.remove(url(path)) }

    public func setModified(_ path: String, _ date: Date) throws {
        let t = date.timeIntervalSince1970.rounded(.down)
        let ns = Int((date.timeIntervalSince1970 - t) * 1e9)
        try DevicePath.setModified(url(path), timespec(tv_sec: Int(t), tv_nsec: ns))
    }

    public func setMode(_ path: String, _ mode: UInt16) throws {
        try DevicePath.setPermissions(url(path), mode_t(mode & 0o7777))
    }

    /// Extracted on the host, then merged in keeping what is there (SystemEdits.copyTree keepingExisting, as tar -k):
    /// tar -k into the volume itself would set an archive member's mode on whatever a link already at its name
    /// leads to.
    public func extract(tar: URL, excluding: [String]) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("ltm-tar-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)  // host file
        defer { try? fm.removeItem(at: staging) }  // host file
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments =
            ["-xkf", tar.path, "-C", staging.path] + excluding.flatMap { ["--exclude", "./" + $0, "--exclude", $0] }
        let err = Pipe()
        p.standardError = err
        try p.run()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw FirmwareError(.internal, "tar -x: \(String(decoding: errors, as: UTF8.self))")
        }
        try SystemEdits.copyTree(try DevicePath.real(staging), root, keepingExisting: true)
    }
}
