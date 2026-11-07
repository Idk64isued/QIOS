import AppleArchive
import Crypto
import Foundation
import System

/// Resources/Guest/guest.aar (scripts/vendor): the guest binaries the app ships, packed so that codesign and the
/// notary see no nested code in Resources. It holds guest-tools/ (firmwarekit's --guest-tools set), developer-tools/
/// (the developer SSH payload), tools/ (the iPod media helpers) and developer-disk-images/ (Apple's Developer Disk
/// Images, Tweaks' Developer Settings). The app and firmwarekit unpack it once per
/// archive into the user's caches and read it there.
nonisolated public enum GuestArchive {
    /// The unpacked archive under `resources` (an app's Contents/Resources), or nil when it ships none (a
    /// development build).
    public static func unpacked(resources: URL) throws -> URL? {
        let fm = FileManager.default
        let archive = resources.appendingPathComponent("Guest/guest.aar")
        guard fm.fileExists(atPath: archive.path) else { return nil }
        let id = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gold.samhenri.LightTouchMac/Guest", isDirectory: true)
        let target = caches.appendingPathComponent(id, isDirectory: true)
        let complete = { fm.fileExists(atPath: target.appendingPathComponent(".complete").path) }
        if complete() { return target }
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        let staging = caches.appendingPathComponent(".\(id)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        try extract(archive, to: staging)
        guard fm.createFile(atPath: staging.appendingPathComponent(".complete").path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: staging.path])
        }
        if fm.fileExists(atPath: target.path), !complete() { try fm.removeItem(at: target) }
        do { try fm.moveItem(at: staging, to: target) } catch  where complete() {}  // another process unpacked it first
        return target
    }

    static func extract(_ archive: URL, to directory: URL) throws {
        let failed = CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: archive.path])
        guard
            let file = ArchiveByteStream.fileStream(
                path: FilePath(archive.path),
                mode: .readOnly,
                options: [],
                permissions: FilePermissions(rawValue: 0o644)
            )
        else { throw failed }
        defer { try? file.close() }
        guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else { throw failed }
        defer { try? decompressed.close() }
        guard let decoded = ArchiveStream.decodeStream(readingFrom: decompressed) else { throw failed }
        defer { try? decoded.close() }
        guard
            let extracted = ArchiveStream.extractStream(
                extractingTo: FilePath(directory.path),
                flags: [.ignoreOperationNotPermitted]
            )
        else { throw failed }
        defer { try? extracted.close() }
        _ = try ArchiveStream.process(readingFrom: decoded, writingTo: extracted)
    }
}
