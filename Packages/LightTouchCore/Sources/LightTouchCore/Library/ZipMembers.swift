// Zip members read in process (ZIPFoundation): an .ipa's paths, modes and small files, an IPSW's Restore.plist.
// Members are named exactly, never as patterns, so `[`, `]`, `*` and `?` in a bundle name are just characters.

import Foundation
import ZIPFoundation

public nonisolated enum ZipMembers {
    /// Every path in the archive; empty when it is not a readable zip.
    public static func paths(_ zip: URL) -> [String] {
        guard let archive = try? Archive(url: zip, accessMode: .read, pathEncoding: nil) else { return [] }
        return archive.map(\.path)
    }

    /// The member's bytes, or nil when it is missing, empty, over `limit` bytes or unreadable.
    public static func data(_ zip: URL, _ path: String, limit: Int = 1 << 22) -> Data? {
        guard let archive = try? Archive(url: zip, accessMode: .read, pathEncoding: nil), let entry = archive[path],
            entry.type == .file, entry.uncompressedSize > 0, entry.uncompressedSize <= UInt64(limit)
        else { return nil }
        var data = Data()
        guard (try? archive.extract(entry, skipCRC32: false) { data.append($0) }) != nil else { return nil }
        return data
    }

    /// The member's POSIX permission bits, or nil when it is missing.
    public static func permissions(_ zip: URL, _ path: String) -> UInt16? {
        guard let archive = try? Archive(url: zip, accessMode: .read, pathEncoding: nil), let entry = archive[path]
        else { return nil }
        return (entry.fileAttributes[.posixPermissions] as? NSNumber).map { UInt16(truncating: $0) }
    }
}
