// DevicePath: every host read or write of a file on a device's volumes (a mounted system or data volume, a tree
// copied from one) goes through here. The device writes those volumes, so a name on them may be a link the device
// planted (absolute, or relative climbing out of the mount): the host opens such paths without following any link,
// in any component (O_NOFOLLOW_ANY), and with no "." or ".." component, so a path under a volume's root resolves
// only by descending from that root and never leaves it.
//
// A volume's root comes from VolumeMount (withMounted, attachHidden), which hands it out as its real path, so the
// host's own part of the path has no links either. Writes go in place, keeping the file's catalog record, except
// where the name is a link or one of several hard links: there the name itself is replaced by a new file, so
// nothing the name led to is written. Reads take regular files only (no FIFO to hang on, no device node).
//
//   let data = try DevicePath.read(m.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist"))
//   try DevicePath.write(Data(), m.appendingPathComponent(".cydia_no_stash"), mode: 0o644)

import Darwin
import Foundation

public enum DevicePath {
    /// `url`'s path, refused unless it is absolute with no "." or ".." component. The sealed system volume's own
    /// links at the top (/var, /tmp, /etc to /private), which nothing on a device's volume can make, are taken
    /// as their targets, so a root under $TMPDIR needs no realpath.
    static func path(_ url: URL) throws -> String {
        var p = url.path
        guard p.hasPrefix("/"), !p.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw FirmwareError(.unsupported, "\(p): not a plain path on the device's volume")
        }
        for top in ["/var", "/tmp", "/etc"] where p == top || p.hasPrefix(top + "/") { p = "/private" + p }
        return p
    }

    static func failure(_ what: String, _ url: URL, _ e: Int32 = errno) -> FirmwareError {
        if e == ELOOP {
            return FirmwareError(.unsupported, "\(what) \(url.path): a link on the device's volume, not followed")
        }
        return FirmwareError(.internal, "\(what) \(url.path): \(String(cString: strerror(e)))")
    }

    /// Opens `url` with no link in any component; the caller closes the descriptor.
    static func open(_ url: URL, _ flags: Int32, _ mode: mode_t = 0) throws -> Int32 {
        let fd = Darwin.open(try path(url), flags | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC, mode)
        guard fd >= 0 else { throw failure("open", url) }
        return fd
    }

    /// The folder holding `url`, opened for search, and `url`'s name in it.
    static func parent(_ url: URL) throws -> (fd: Int32, name: String) {
        let name = url.lastPathComponent
        _ = try path(url)
        return (try open(url.deletingLastPathComponent(), O_SEARCH), name)
    }

    /// `url`'s lstat (a link is a link), or nil when there is nothing there. A link above it throws.
    static func status(_ url: URL) throws -> stat? {
        let up = url.deletingLastPathComponent()
        _ = try path(url)
        let fd = Darwin.open(try path(up), O_SEARCH | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw failure("open", up)
        }
        let dir = (fd: fd, name: url.lastPathComponent)
        defer { close(dir.fd) }
        var st = stat()
        guard fstatat(dir.fd, dir.name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw failure("stat", url)
        }
        return st
    }

    /// The type bits (S_IFMT) of what is at `url`, a link not followed; nil when nothing is.
    public static func kind(_ url: URL) throws -> mode_t? { try status(url).map { $0.st_mode & S_IFMT } }

    public static func exists(_ url: URL) -> Bool { ((try? kind(url)) ?? nil) != nil }
    public static func isDirectory(_ url: URL) -> Bool { ((try? kind(url)) ?? nil) == S_IFDIR }
    public static func isLink(_ url: URL) -> Bool { ((try? kind(url)) ?? nil) == S_IFLNK }

    /// The permission bits of what is at `url`.
    public static func permissions(_ url: URL) throws -> mode_t {
        guard let st = try status(url) else { throw failure("stat", url, ENOENT) }
        return st.st_mode & 0o7777
    }

    /// Sets the permission bits of what is at `url` (never through a link).
    public static func setPermissions(_ url: URL, _ mode: mode_t) throws {
        let dir = try parent(url)
        defer { close(dir.fd) }
        guard fchmodat(dir.fd, dir.name, mode, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("chmod", url) }
    }

    /// The regular file at `url`.
    public static func read(_ url: URL) throws -> Data {
        let fd = try open(url, O_RDONLY)
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
            throw FirmwareError(.unsupported, "read \(url.path): not a regular file")
        }
        return try h.readToEnd() ?? Data()
    }

    /// The plist dictionary at `url`, or nil when it is absent, refused or not a dictionary plist.
    public static func dictionary(_ url: URL) -> NSMutableDictionary? {
        guard let data = try? read(url) else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: data,
            options: .mutableContainersAndLeaves,
            format: nil
        )
            as? NSMutableDictionary
    }

    /// Writes `data` into `url` in place (truncating an existing file, so it keeps its catalog record), creating it
    /// 0666 & ~umask if absent; with `mode`, then sets the permission bits. A link, or one name of a hard-linked
    /// file, at `url` is replaced by a new file rather than written through; a link above `url` throws.
    public static func write(_ data: Data, _ url: URL, mode: mode_t? = nil) throws {
        let dir = try parent(url)
        defer { close(dir.fd) }
        var st = stat()
        if fstatat(dir.fd, dir.name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            let type = st.st_mode & S_IFMT
            if type == S_IFLNK || (type == S_IFREG && st.st_nlink > 1) {
                FirmwareDiagnostics.write(
                    Data(
                        "\(url.path): \(type == S_IFLNK ? "a link" : "a hard link"), replaced, not written through\n"
                            .utf8
                    )
                )
                guard unlinkat(dir.fd, dir.name, 0) == 0 else { throw failure("unlink", url) }
            } else if type != S_IFREG {
                throw FirmwareError(.unsupported, "write \(url.path): not a regular file")
            }
        }
        let fd = openat(dir.fd, dir.name, O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw failure("open", url) }
        defer { close(fd) }
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, ftruncate(fd, 0) == 0 else {
            throw FirmwareError(.unsupported, "write \(url.path): not a lone regular file")
        }
        var done = 0
        try data.withUnsafeBytes { b in
            while done < b.count {
                let n = Darwin.write(fd, b.baseAddress! + done, b.count - done)
                guard n > 0 else { throw failure("write", url) }
                done += n
            }
        }
        if let mode, fchmod(fd, mode) != 0 { throw failure("chmod", url) }
    }

    /// mkdir -p with 0777 & ~umask for each folder created; anything but a folder in the way throws.
    public static func mkdirs(_ url: URL) throws {
        switch try kind(url) {
        case S_IFDIR?: return
        case nil: break
        default: throw FirmwareError(.unsupported, "mkdir \(url.path): not a folder (links are not followed)")
        }
        try mkdirs(url.deletingLastPathComponent())
        let dir = try parent(url)
        defer { close(dir.fd) }
        guard mkdirat(dir.fd, dir.name, 0o777) == 0 || errno == EEXIST else { throw failure("mkdir", url) }
    }

    /// Removes what is at `url` (a folder with everything in it); a link is removed, not followed. Nothing there is
    /// no error.
    public static func remove(_ url: URL) throws {
        guard let type = try kind(url) else { return }
        if type == S_IFDIR {
            for name in try FileManager.default.contentsOfDirectory(atPath: path(url)) {
                try remove(url.appendingPathComponent(name))
            }
        }
        let dir = try parent(url)
        defer { close(dir.fd) }
        guard unlinkat(dir.fd, dir.name, type == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else { throw failure("remove", url) }
    }

    /// Makes `url` a symbolic link to `target` (the link is made, nothing is followed).
    public static func symlink(_ url: URL, to target: String) throws {
        let dir = try parent(url)
        defer { close(dir.fd) }
        guard symlinkat(target, dir.fd, dir.name) == 0 else { throw failure("symlink", url) }
    }

    /// Sets the modification time of what is at `url` (never through a link).
    static func setModified(_ url: URL, _ time: timespec) throws {
        let dir = try parent(url)
        defer { close(dir.fd) }
        let times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), time]
        guard utimensat(dir.fd, dir.name, times, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("utimes", url) }
    }

    /// What the link at `url` says (read, not followed).
    public static func linkTarget(_ url: URL) throws -> String {
        let dir = try parent(url)
        defer { close(dir.fd) }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlinkat(dir.fd, dir.name, &buf, Int(PATH_MAX))
        guard n >= 0 else { throw failure("readlink", url) }
        return String(decoding: buf[..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A host folder's real path (its links resolved): the root a volume is handed out at, so that no link is on
    /// the host's part of a device path either.
    public static func real(_ url: URL) throws -> URL {
        guard let p = realpath(url.path, nil) else { throw failure("realpath", url) }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p), isDirectory: true)
    }

    /// The names in the folder at `url`.
    public static func contents(_ url: URL) throws -> [String] {
        guard try kind(url) == S_IFDIR else { throw FirmwareError(.unsupported, "\(url.path): not a folder") }
        return try FileManager.default.contentsOfDirectory(atPath: path(url))
    }
}
