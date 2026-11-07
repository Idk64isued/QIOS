import Darwin
import Foundation
import HostRuntime

/// Disk operations shared by the controller and the device-free regression check.
public nonisolated enum DeviceStateStorage {
    /// Only call after the native VM has exited and released its files.
    /// `snapshots`: saved-state files older builds wrote (and their .meta), swept with the overlay.
    /// `preparedNOR`: the device's private NOR copy, which pairs with its overlay. Removed under the same lease, so no
    /// helper starting meanwhile keeps the old one.
    /// `owner` is the device being erased; every path must pass checkRemovable before any is removed.
    /// The overlay is renamed to .erasing-<name> beside it first, so a crash mid-removal never leaves a half-erased
    /// overlay (pages without their base identity read as an older system image); sweepDeleting finishes it.
    public static func erase(
        overlay: URL,
        snapshots: [URL],
        preparedNOR: URL? = nil,
        state: URL,
        owner: UUID?
    ) throws {
        let lease = try stoppedLease(owner, state: state)
        defer { withExtendedLifetime(lease) {} }
        try removeAside(
            overlay,
            with: snapshots.flatMap { [$0, $0.appendingPathExtension("meta")] } + [preparedNOR].compactMap { $0 },
            state: state,
            owner: owner
        )
        if let owner { try returnToPrepared(owner, state: state) }
    }

    /// `tree` renamed to .erasing-<name> beside it, then `files` and it removed; every path checked first.
    private static func removeAside(_ tree: URL, with files: [URL], state: URL, owner: UUID?) throws {
        let fm = FileManager.default
        let doomed = tree.deletingLastPathComponent().appendingPathComponent(".erasing-" + tree.lastPathComponent)
        for path in files + [tree, doomed] { try checkRemovable(path, state: state, owner: owner) }
        if fm.fileExists(atPath: tree.path) {
            try removeTree(doomed)
            guard rename(tree.path, doomed.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        for path in files where fm.fileExists(atPath: path.path) {
            try fm.removeItem(at: path)
        }
        // Erased once renamed; what can't go now goes at the next launch.
        try? removeTree(doomed)
    }

    /// A saved file system edit (Save Changes, Jailbreak…) publishes a generation whose base holds the edited
    /// volumes, the device's data at that time included, so erasing its overlay isn't enough: the record goes back to
    /// the prepared base, Devices/<uuid>/base, which every edit clones and none writes, and to fresh storage beside
    /// it. Each generation keeps the record it replaced (original-device.plist); the first of the chain is the
    /// prepared one. The record's other fields (name, guest, panel) stay. Then generations/ goes, renamed aside like
    /// the overlay. A crash before the record is written leaves an erased overlay on the edited base (Erase again
    /// finishes); after it, at worst a .erasing- directory the launch sweep removes.
    static func returnToPrepared(_ owner: UUID, state: URL) throws {
        let fm = FileManager.default
        let device = DeviceInstance.directory(owner, state: state)
        let generations = device.appendingPathComponent("generations")
        guard fm.fileExists(atPath: generations.path) else { return }
        let recordURL = device.appendingPathComponent(DeviceRecord.name)
        var record = try DeviceRecord.object(Data(contentsOf: recordURL))
        var prepared = record
        var seen: Set<String> = []
        while let key = (prepared["storage"] as? [String: Any])?["key"] as? String, seen.insert(key).inserted,
            let data = try? Data(contentsOf: generations.appendingPathComponent("\(key)/original-\(DeviceRecord.name)"))
        {
            prepared = try DeviceRecord.object(data)
        }
        if (prepared["storage"] as? [String: Any])?["key"] as? String
            != (record["storage"] as? [String: Any])?["key"] as? String
        {
            // The prepared storage as the device last left it, before its first edit.
            let paths = try StorageRecordPaths(bytes: DeviceRecord.data(prepared), relativeRoot: state)
            let snapshots = [paths.snapshot].compactMap { $0 }.flatMap { s in
                ["", ".meta", ".tmp", ".bad"].map { URL(fileURLWithPath: s.path + $0) }
            }
            try removeAside(
                paths.overlay,
                with: snapshots + [paths.writableNOR].compactMap { $0 },
                state: state,
                owner: owner
            )
            // the prepared storage's format too: an edit of a format 1 device leaves it in format 2
            for key in ["base", "storage", "provenance", "format"] { record[key] = prepared[key] }
            try DeviceRecord.data(record).write(to: recordURL, options: .atomic)
        }
        try removeAside(generations, with: [], state: state, owner: owner)
    }

    /// The helper/export/edit lock is the authority, including external CLI
    /// owners. A cached GUI "stopped" state cannot authorize deleting its files.
    private static func stoppedLease(_ owner: UUID?, state: URL) throws -> StorageLease? {
        guard let owner else { return nil }  // legacy profile-only stores
        let work = state.appendingPathComponent("Devices/\(owner.uuidString)/work")
        try checkRemovable(work, state: state, owner: owner)
        do { return try StorageLease(work.appendingPathComponent("lease")) } catch let error as StorageLease.Failure {
            if case .openFailed(let code) = error { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            throw CocoaError(
                .fileWriteNoPermission,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "This device’s storage is in use. Shut down the device, or save or discard its file system changes, first."
                ]
            )
        }
    }

    // MARK: - Removal

    public static func canonicalPath(_ url: URL) -> String { StoragePathAuthority.canonicalPath(url) }

    public static func checkBootPaths(base: URL, mutable: [URL], state: URL, owner: UUID) throws {
        do {
            try StoragePathAuthority.checkBootPaths(base: base, mutable: mutable, state: state, owner: owner)
        } catch StoragePathAuthority.Failure.invalidPath(let url) {
            throw CocoaError(
                .fileWriteNoPermission,
                userInfo: [
                    NSFilePathErrorKey: url.path,
                    NSLocalizedDescriptionKey:
                        "Light Touch can’t start this device because \(url.path) isn’t its writable storage."
                ]
            )
        }
    }

    public static func checkRemovable(_ url: URL, state: URL, owner: UUID?) throws {
        do { try StoragePathAuthority.checkRemovable(url, state: state, owner: owner) } catch StoragePathAuthority
            .Failure.invalidPath
        {
            throw CocoaError(
                .fileWriteNoPermission,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Light Touch didn’t remove \(url.path): it isn’t this device’s storage."
                ]
            )
        }
    }

    /// Removes a tree even where a preparer made it read-only (the NAND is
    /// chmod a-w) or lockBase made it immutable: on a refusal every directory
    /// in it is unlocked and made writable, then the removal is tried once
    /// more and its error thrown.
    public static func removeTree(_ url: URL) throws {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: url.path)) != nil else { return }
        if (try? fm.removeItem(at: url)) != nil { return }
        for directory in directories(under: url) {
            chflags(directory.path, 0)
            chmod(directory.path, 0o700)
        }
        try fm.removeItem(at: url)
    }

    /// `url` and every directory below it (symlinks not followed).
    private static func directories(under url: URL) -> [URL] {
        var directories = [url]
        if let walk = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) {
            for case let item as URL in walk {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true, values?.isSymbolicLink != true { directories.append(item) }
            }
        }
        return directories
    }

    /// A published base is immutable (chflags uchg on it and every directory
    /// in it): the Finder refuses to delete, rename or add to it with a system
    /// dialog, and nothing here writes into it. Idempotent; removeTree undoes it.
    ///
    /// The base itself is locked last, so its flag means the whole tree is
    /// done: a locked base returns at once instead of walking a root
    /// filesystem's worth of directories (seconds, at every launch).
    public static func lockBase(_ base: URL) {
        var info = stat()
        if lstat(base.path, &info) == 0, info.st_flags & UInt32(UF_IMMUTABLE) != 0 { return }
        for directory in directories(under: base).reversed() { chflags(directory.path, UInt32(UF_IMMUTABLE)) }
    }

    /// Delete Device: Devices/<uuid> is renamed to Devices/.deleting-<uuid>
    /// first, so a crash mid-removal never leaves a half device that loads
    /// (DeviceInstance.all skips the name); the launch sweep finishes it.
    public static func removeDevice(_ id: UUID, state: URL) throws {
        let lease = try stoppedLease(id, state: state)
        defer { withExtendedLifetime(lease) {} }
        let devices = state.appendingPathComponent("Devices", isDirectory: true)
        let directory = devices.appendingPathComponent(id.uuidString, isDirectory: true)
        let doomed = devices.appendingPathComponent(".deleting-\(id.uuidString)", isDirectory: true)
        try checkRemovable(directory, state: state, owner: id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try removeTree(doomed)
            guard rename(directory.path, doomed.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        try removeTree(doomed)
    }

    /// Launch (under the app lock): finish deletes and erases a crash interrupted (Devices/.deleting-<uuid>,
    /// Devices/<uuid>/.erasing-<overlay>).
    public static func sweepDeleting(state: URL) {
        let fm = FileManager.default
        let devices = state.appendingPathComponent("Devices", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: devices.path)) ?? [] {
            let device = devices.appendingPathComponent(name)
            if name.hasPrefix(".deleting-") {
                try? removeTree(device)
                continue
            }
            for inner in (try? fm.contentsOfDirectory(atPath: device.path)) ?? [] where inner.hasPrefix(".erasing-") {
                try? removeTree(device.appendingPathComponent(inner))
            }
        }
    }

    /// Publish a complete private NOR copy beside the NAND pages. Keeping it
    /// inside the overlay also includes it in erase and snapshot freshness.
    public static func writableNOR(base: URL, overlay: URL) throws -> URL {
        try PreparedDeviceBoot.writableNOR(base: base, overlay: overlay)
    }

    /// A copy-on-write overlay is only valid over the exact base it was made
    /// from: over a rebuilt base its dirty pages mix with different clean ones
    /// (seen as an unactivated iPad after a golden rebuild). The overlay
    /// carries the base's identity; false means it belongs to another base,
    /// or predates pinning, and must not be booted. An empty or missing
    /// overlay is adopted by the base.
    public static func pinOverlay(_ overlay: URL, toBase identity: String) throws -> Bool {
        try PreparedDeviceBoot.pinOverlay(overlay, toBase: identity)
    }
}
