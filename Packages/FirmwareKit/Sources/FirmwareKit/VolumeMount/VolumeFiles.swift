// VolumeFiles: the file operations a recipe makes on a volume it edits, by volume-relative path ("" is the root),
// whichever backend edits it: a mounted volume or a host folder (MountedVolume), or an image edited offline
// (HFSPlusWriter). VolumeMount.withVolume hands a recipe the one its backend picks.
//
//   try VolumeMount.withVolume(image, at: mountPoint) { v in
//       try v.put(Data(fstab.utf8), at: "private/etc/fstab")
//       if v.exists("usr/lib/dyld") { ... }
//   }
//
// The device writes these volumes, so no link on them is followed, in any component of a path (DevicePath's rule,
// which both backends keep): a link on the way throws, a read takes regular files only, and a write at a link or
// at one name of a hard-linked file replaces that name with a new file. FitCheck.Firmware resolves the
// firmware's own links itself, inside the volume.

import Foundation

public protocol VolumeFiles: AnyObject {
    /// What is at `path` (a link is a link), or nil.
    func item(at path: String) throws -> VolumeItem?
    func contents(at path: String) throws -> Data
    /// The names in a folder, in no particular order.
    func contentsOfDirectory(at path: String) throws -> [String]
    func destinationOfSymlink(at path: String) throws -> String
    /// Writes `data` into the file in place (an existing file keeps its record and owner), else creates it 0666 less
    /// the umask; with `mode`, sets the permission bits. A link or a hard-linked name there is replaced.
    func put(_ data: Data, at path: String, mode: UInt16?) throws
    /// `put` from a file on the host.
    func put(contentsOf source: URL, at path: String, mode: UInt16?) throws
    /// mkdir -p, 0777 less the umask; with `mode`, sets the last folder's permission bits.
    func makeDirectory(_ path: String, mode: UInt16?) throws
    func makeSymlink(_ path: String, to target: String) throws
    /// A hard link at `path` to the file at `existing`.
    func link(_ path: String, to existing: String) throws
    func rename(_ path: String, to destination: String) throws
    /// Removes `path`, a folder with everything in it; nothing there is no error.
    func remove(_ path: String) throws
    /// Sets the permission bits (the file type kept).
    func setMode(_ path: String, _ mode: UInt16) throws
    /// Sets the modification time (HFS keeps whole seconds).
    func setModified(_ path: String, _ date: Date) throws
    /// Extracts a tar archive as `/usr/bin/tar -xkf` does (nothing that exists replaced), members at or under an
    /// `excluding` path left out.
    func extract(tar: URL, excluding: [String]) throws
}

/// What `VolumeFiles.item(at:followLast:)` tells about a path.
public struct VolumeItem: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case file, folder, symlink }
    public let kind: Kind
    public let uid: UInt32, gid: UInt32, mode: UInt16
    public let size: UInt64
    /// The content-modification time (st_mtime; the catalog's contentModDate).
    public let modified: Date
}

extension VolumeFiles {
    /// Whether anything is at `path` (a link itself, not followed); false too where a link is on the way.
    public func exists(_ path: String) -> Bool { ((try? item(at: path)) ?? nil) != nil }
    public func isDirectory(_ path: String) -> Bool { ((try? item(at: path)) ?? nil)?.kind == .folder }
    public func isFile(_ path: String) -> Bool { ((try? item(at: path)) ?? nil)?.kind == .file }
    public func isSymlink(_ path: String) -> Bool { ((try? item(at: path)) ?? nil)?.kind == .symlink }

    public func put(_ data: Data, at path: String) throws { try put(data, at: path, mode: nil) }

    /// The IPSW's `member` at `path`: on a mount extracted there, as the recipes always have (so the volume a mount
    /// builds keeps its bytes: the kernel counts the extraction's writes), else put as a new file, as the extraction
    /// makes one (FileManager.createFile replaces what is there: a new record, dated as it is written).
    func put(member: String, of ipsw: IPSWArchive, at path: String) throws {
        if let m = self as? MountedVolume { return try ipsw.extract(member, to: m.url(path)) }
        try remove(path)
        try put(ipsw.read(member), at: path)
    }
    public func makeDirectory(_ path: String) throws { try makeDirectory(path, mode: nil) }

    /// The dictionary property list at `path` (any format), or nil when it is absent, refused or not one.
    public func plist(at path: String) -> NSMutableDictionary? {
        guard let d = try? contents(at: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d, options: .mutableContainersAndLeaves, format: nil))
            as? NSMutableDictionary
    }

    /// Every path under `top` (not `top` itself), parents before their children, symlinked folders not entered.
    public func walk(_ top: String = "") throws -> [String] {
        var out: [String] = []
        for name in try contentsOfDirectory(at: top).sorted() {
            let p = top.isEmpty ? name : top + "/" + name
            out.append(p)
            if try item(at: p)?.kind == .folder { out += try walk(p) }
        }
        return out
    }
}
