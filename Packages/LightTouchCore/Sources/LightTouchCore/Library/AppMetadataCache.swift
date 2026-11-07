// Installed apps are always files we already have on disk (the .ipa passed to
// Add). installation_proxy's browse is a lossy source of truth for the
// display name (e.g. it reports Starbucks by bundle ID), so
// on install we read the real CFBundleDisplayName/icon straight out of the
// .ipa (ZipMembers) and cache
// it to disk keyed by bundle ID. The live device list still drives *which*
// bundle IDs are installed; this only supplies the name/icon for them, so an
// app installed inside the guest simply falls back to the reported name.

import Foundation
import HostRuntime
import HostServiceWire

@MainActor
public final class AppMetadataCache {
    private static let standard = AppMetadataCache()
    /// The cache everything uses; a test swaps in one kept in a temporary directory.
    public static var shared: AppMetadataCache { testing ?? standard }
    static var testing: AppMetadataCache?

    private struct Entry: Codable {
        public let name: String
        public let hasIcon: Bool
    }

    private let dir: URL
    private var entries: [String: Entry] = [:]
    /// Decoded icons (the app's NSImages, AppMetadataCache+Icons), so the sidebar's `viewFor:` doesn't hit the
    /// disk on every visible row on every reload. NSCache evicts under memory pressure on its own; a few dozen
    /// 57px PNGs never will. Emptied of an app's icon here whenever its file changes.
    public let iconMemo = NSCache<NSString, AnyObject>()

    private convenience init() {
        self.init(
            directory: StorageLocations.appMetadataDirectory(
                state: Bundled.stateDirectory,
                caches: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                isolated: Bundled.stateOverride != nil
            )
        )
    }

    /// The cache kept in `directory` (index.plist and one <bundle id>.png per icon).
    init(directory: URL) {
        dir = directory
        entries =
            (try? PropertyListFile.read(
                [String: Entry].self,
                from: indexURL,
                legacyJSON: dir.appendingPathComponent("index.json"),
                format: .binary
            )) ?? [:]
        #if DEBUG
            Self.selfCheck()
        #endif
    }

    #if DEBUG
        /// The member-picking rules are the whole reason names and icons went
        /// missing, so they assert against the shapes that broke them.
        public static func selfCheck() {
            let members = [
                "Payload/Super Monkey Ball [SEGA].app/Info.plist",
                "Payload/Super Monkey Ball [SEGA].app/Icon.png",
                "Payload/Super Monkey Ball [SEGA].app/Icon@2x.png",
                "Payload/Super Monkey Ball [SEGA].app/Settings.bundle/Nested.app/Info.plist",
                "Payload/Super Monkey Ball [SEGA].app/Frameworks/Foo.framework/Icon.png"
            ]
            let found = IPAMembers.appRoot(members)
            assert(found == "Payload/Super Monkey Ball [SEGA].app/", "nested .app won: \(found ?? "nil")")
            let root = found ?? ""
            assert(IPAMembers.iconMember(members, root: root, info: [:]) == "\(root)Icon@2x.png")
            assert(
                IPAMembers.iconMember(members, root: root, info: ["CFBundleIconFile": "Icon.png"])
                    == "\(root)Icon@2x.png"
            )
        }
    #endif

    /// A binary property list; earlier builds kept index.json, converted on the first read.
    private var indexURL: URL { dir.appendingPathComponent("index.plist") }
    public func iconURL(_ bundleID: String) -> URL { dir.appendingPathComponent("\(bundleID).png") }

    /// A bundle id read out of an untrusted archive is about to become a path
    /// component. `appendingPathComponent` happily accepts "/" and "..", and
    /// `Data.write(to:)` resolves them — so an .ipa declaring a
    /// CFBundleIdentifier of "../../../../Library/LaunchAgents/x" wrote its icon
    /// wherever it liked, on DROP, before any install was attempted. Every zip
    /// member name here is already escaped for exactly this reason; the plist
    /// value was the one input that wasn't.
    private static func isSafeBundleID(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix(".") && !id.contains("/") && !id.contains(":") && !id.contains("\0")
    }

    /// nil if we never learned this bundle ID.
    ///
    /// Entries used to also carry the version and be discarded when it didn't
    /// match the live list — but the device list reports CFBundleVersion while
    /// we read CFBundleShortVersionString, so for any app where those differ
    /// (most of them) every entry was rejected on read AND deleted by prune,
    /// which is what made the sidebar fall back to bundle IDs at random. A name
    /// and icon barely change between versions; a stale one is not worth that.
    public func name(for bundleID: String) -> String? { entries[bundleID]?.name }

    /// Whether an icon was cached for this bundle ID (its file is iconURL).
    public func hasIcon(_ bundleID: String) -> Bool { entries[bundleID]?.hasIcon == true }

    /// Drop the cached name/icon for one bundle ID (uninstalled via our button).
    public func forget(_ bundleID: String) {
        guard entries.removeValue(forKey: bundleID) != nil else { return }
        iconMemo.removeObject(forKey: bundleID as NSString)
        try? FileManager.default.removeItem(at: iconURL(bundleID))
        save()
    }

    // There is deliberately no prune-against-the-live-list. It existed, and it
    // was what threw the name and icon away moments after learning them: the
    // sidebar polls every 3 s, an install takes far longer than that, and the
    // app being installed is not in the live list for any of those ticks — so
    // the entry written at the start of the install was deleted before installd
    // ever registered the app. An entry for an app that is gone costs a few KB
    // and is never read (lookups only happen for bundle IDs the device
    // reports); an entry deleted by mistake costs the icon and the name.

    /// Best-effort: read the display name and icon out of a decrypted .ipa and
    /// cache them, returning the name. Silently does nothing on any failure —
    /// the sidebar just falls back to whatever the device list reports.
    /// The archive's display name without touching the cache — for a row that
    /// is only a proposal until the install succeeds. See learn(from:).
    public func preview(of ipa: URL) async -> (name: String, bundleID: String)? {
        let members = await Self.members(ipa)
        guard let root = IPAMembers.appRoot(members),
            let plist = try? await Self.unzip(ipa, member: root + "Info.plist"),
            let info = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
            let bundleID = info["CFBundleIdentifier"] as? String,
            Self.isSafeBundleID(bundleID)
        else { return nil }
        let name =
            (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? ipa.deletingPathExtension().lastPathComponent
        return (name, bundleID)
    }

    @discardableResult
    public func learn(from ipa: URL) async -> String? {
        let members = await Self.members(ipa)
        guard let root = IPAMembers.appRoot(members),
            let plist = try? await Self.unzip(ipa, member: root + "Info.plist"),
            let info = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
            let bundleID = info["CFBundleIdentifier"] as? String,
            Self.isSafeBundleID(bundleID)
        else { return nil }
        let name =
            (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? ipa.deletingPathExtension().lastPathComponent
        var hasIcon = false
        if let member = IPAMembers.iconMember(members, root: root, info: info),
            let data = try? await Self.unzip(ipa, member: member)
        {
            hasIcon = (try? StorageLocations.writeCacheData(data, to: iconURL(bundleID))) != nil
            // A reinstall may ship a new icon; drop any decoded copy of the old.
            iconMemo.removeObject(forKey: bundleID as NSString)
        }
        entries[bundleID] = Entry(name: name, hasIcon: hasIcon)
        save()
        return name
    }

    /// The app's CFBundleIdentifier, for keying the install placeholder. Same
    /// Info.plist read the rest of the pre-flight already does — keying on the
    /// .ipa's filename instead meant the same app dropped from two differently
    /// named files raised two placeholder icons.
    public static func bundleID(of ipa: URL) async -> String? {
        let members = await Self.members(ipa)
        guard let root = IPAMembers.appRoot(members),
            let data = try? await Self.unzip(ipa, member: root + "Info.plist"),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        guard let id = info["CFBundleIdentifier"] as? String, isSafeBundleID(id) else { return nil }
        return id
    }

    /// The archive path of the app's main binary, e.g.
    /// "Payload/CubeRunner.app/CubeRunner" — what the exec-bit repair needs to
    /// know before staging. Same Info.plist read as learn().
    public static func executableMember(of ipa: URL) async -> String? {
        let members = await Self.members(ipa)
        guard let root = IPAMembers.appRoot(members),
            let data = try? await Self.unzip(ipa, member: root + "Info.plist"),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let exe = info["CFBundleExecutable"] as? String
        else { return nil }
        return root + exe
    }

    /// The app's Info.plist, the same read learn() does; nil for an archive
    /// with no single root app.
    public static func info(of ipa: URL) async -> [String: Any]? {
        let members = await Self.members(ipa)
        guard let root = IPAMembers.appRoot(members),
            let data = try? await Self.unzip(ipa, member: root + "Info.plist")
        else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// The lowest OS the app declares it will run on (Info.plist
    /// MinimumOSVersion). This — not the SDK it was built against — is what
    /// iPhone OS actually enforces at launch.
    public static func minimumOS(from ipa: URL) async -> String? {
        await Self.info(of: ipa)?["MinimumOSVersion"] as? String
    }

    private func save() {
        guard let data = try? PropertyListFile.data(entries, format: .binary) else { return }
        try? StorageLocations.writeCacheData(data, to: indexURL)
    }

    // MARK: - .ipa reading (Payload/<something>.app is the app bundle)
    //
    // Every member is looked up in the archive's own listing and then read by its exact name (ZipMembers), so a
    // nested .app inside a bundle can't win and a bundle named with `[`, `]` or `?` (Super Monkey Ball [SEGA].app)
    // is found like any other. Off the main actor: reading a large .ipa's directory takes a moment.

    /// Every path in the archive.
    @concurrent nonisolated private static func members(_ ipa: URL) async -> [String] {
        ZipMembers.paths(ipa)
    }

    @concurrent nonisolated private static func unzip(_ ipa: URL, member: String) async throws -> Data {
        guard let data = ZipMembers.data(ipa, member) else {
            throw DeviceToolsError.failed("no such member: \(member)")
        }
        return data
    }
}
