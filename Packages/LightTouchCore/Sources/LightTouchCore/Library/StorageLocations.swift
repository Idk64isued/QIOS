import Foundation

/// Where the app's state and logs live. A layout
/// from before the device library is not migrated: LegacyState offers to
/// erase it once.
public nonisolated enum StorageLocations {
    public static let bundleIdentifier = "gold.samhenri.LightTouchMac"
    public static let logLimit = 1_000_000

    public struct Layout: Sendable {
        public let state: URL
        public let logs: URL
    }

    /// The state root's name: `.noindex` keeps Spotlight out of the device
    /// pages (hundreds of thousands of files). `.metadata_never_index` inside a
    /// folder no longer works (macOS 27 indexed it); the suffix does, and
    /// renaming an indexed folder drops its entries.
    public static let stateDirectoryName = bundleIdentifier + ".noindex"

    public static func stateRoot(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(stateDirectoryName, isDirectory: true)
    }

    public static func prepare(applicationSupport: URL, library: URL, override: URL? = nil) throws -> Layout {
        let state = override ?? stateRoot(applicationSupport: applicationSupport)
        if override == nil {
            try adoptUnsuffixedRoot(
                applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true),
                as: state
            )
        }
        try privateDirectory(state)
        // Device storage is recreatable from the IPSW or lives only for the
        // device's sake; Time Machine skips it (the xattr covers new devices).
        for name in ["Devices", "Preparing"] {
            let url = state.appendingPathComponent(name, isDirectory: true)
            if (try? privateDirectory(url)) != nil { excludeFromBackup(url) }
        }
        let logs =
            override?.appendingPathComponent("Logs", isDirectory: true)
            ?? library.appendingPathComponent("Logs/\(bundleIdentifier)", isDirectory: true)
        try privateDirectory(logs)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logs.path)
        return Layout(state: state, logs: logs)
    }

    /// Builds before the `.noindex` root kept state under the bare identifier:
    /// one rename moves it (records hold paths relative to the root). Not while
    /// an older build holds that root's app lock.
    public static func adoptUnsuffixedRoot(_ old: URL, as state: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: state.path) else { return }
        let fd = open(old.appendingPathComponent(".app-lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw CocoaError(
                .fileLocking,
                userInfo: [NSLocalizedDescriptionKey: "Light Touch is already running with this library."]
            )
        }
        try fm.moveItem(at: old, to: state)
    }

    public static func privateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
        } else {
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    public struct DaemonIdentity: Equatable {
        public let parent: UInt32
        public let uid: UInt32
        public let started: UInt64
        public let micros: UInt64
        public let path: String
    }

    public static func daemonIdentity(_ pid: pid_t) -> DaemonIdentity? {
        var info = proc_bsdinfo()
        guard
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                &info,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            ) == MemoryLayout<proc_bsdinfo>.size,
            info.pbi_status != 5
        else { return nil }  // A zombie cannot write files.
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return DaemonIdentity(
            parent: info.pbi_ppid,
            uid: info.pbi_uid,
            started: info.pbi_start_tvsec,
            micros: info.pbi_start_tvusec,
            path: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        )
    }

    /// Time Machine skips it (an xattr, so it survives renames).
    public static func excludeFromBackup(_ url: URL, _ excluded: Bool = true) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try? url.setResourceValues(values)
    }

    public static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    /// AppMetadataCache's names and icons: disposable metadata, not device
    /// storage, so the system caches; an isolated run keeps even its cache under
    /// LTM_STATE_DIR.
    public static func appMetadataDirectory(state: URL, caches: URL, isolated: Bool) -> URL {
        let root =
            isolated
            ? state.appendingPathComponent("Caches", isDirectory: true)
            : caches.appendingPathComponent(bundleIdentifier, isDirectory: true)
        let directory = root.appendingPathComponent("AppMetadata", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// macOS can remove disposable cache files while the app is running.
    /// Recreate the parent for each write, then publish complete bytes together.
    public static func writeCacheData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
