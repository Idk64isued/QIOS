import BuildSupport
import Foundation

/// The app a Release test run checks: LTM_RELEASE_APP (a Light Touch.app) or LTM_RELEASE_ARCHIVE (an .xcarchive, whose
/// only product is Applications/<one app>). xcodebuild passes them to the tests as TEST_RUNNER_LTM_RELEASE_APP etc.
public enum ReleaseApp {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// The Release plan sets LTM_RELEASE_REQUIRED=1: without an app its tests fail instead of standing aside.
    public static var required: Bool { environment["LTM_RELEASE_REQUIRED"] == "1" }
    /// Skip the prepare matrix (LTM_RELEASE_SKIP_PREPARE=1): development dry runs only; scripts/ship refuses it
    /// for a real release.
    public static var skipPrepare: Bool { environment["LTM_RELEASE_SKIP_PREPARE"] == "1" }
    /// The app is an export (notarized, stapled): Gatekeeper and the ticket are checked too (LTM_RELEASE_EXPORTED=1).
    public static var exported: Bool { environment["LTM_RELEASE_EXPORTED"] == "1" }
    public static var given: Bool { environment["LTM_RELEASE_APP"] != nil || environment["LTM_RELEASE_ARCHIVE"] != nil }

    public enum Failure: Error, CustomStringConvertible {
        case missing
        case notAnAppArchive([String])
        public var description: String {
            switch self {
            case .missing: "no app: set LTM_RELEASE_APP or LTM_RELEASE_ARCHIVE (TEST_RUNNER_… through xcodebuild)"
            case .notAnAppArchive(let products):
                "not an app archive (Products: \(products)): Organizer can't distribute it"
            }
        }
    }

    public static func app() throws -> URL {
        if let path = environment["LTM_RELEASE_APP"] { return URL(fileURLWithPath: path).resolvingSymlinksInPath() }
        guard let path = environment["LTM_RELEASE_ARCHIVE"] else { throw Failure.missing }
        let products = URL(fileURLWithPath: path).appendingPathComponent("Products")
        let names = try FileManager.default.contentsOfDirectory(atPath: products.path).filter { !$0.hasPrefix(".") }
            .sorted()
        let apps = try FileManager.default.contentsOfDirectory(
            atPath: products.appendingPathComponent("Applications").path
        )
        .filter { $0.hasSuffix(".app") }
        guard names == ["Applications"], apps.count == 1 else { throw Failure.notAnAppArchive(names) }
        return products.appendingPathComponent("Applications/\(apps[0])").resolvingSymlinksInPath()
    }

    /// Every Mach-O in the bundle (not symlinks).
    public static func binaries(in app: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: app.appendingPathComponent("Contents"),
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        return (enumerator?.compactMap { $0 as? URL } ?? []).filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true && MachOClosure.isMachO(url)
        }.sorted { $0.path < $1.path }
    }

    /// The environment variables a Debug build reads to run other code or data than the bundle's (another services
    /// worker, emulator, usbmuxd, preparer or iBoot32Patcher, other device files, guest package or state, a test's
    /// kill hook). Each is compiled out of Release: a name in a shipped binary is an override the app still honors.
    public static let debugOverrides = [
        "LTM_HOST_SERVICE_WORKER", "LTM_QEMU_DYLIB", "LTM_USBMUXD", "LTM_FIRMWAREKIT", "LTM_FILES",
        "LTM_GUEST_PACKAGE", "LTM_STATE_DIR", "LTM_DEV_BASE", "LTM_TEST_MIGRATION_KILL", "FIRMWAREKIT_IBOOT_PATCHER",
        "IBOOT32PATCHER", "FIRMWAREKIT_DISK_IMAGE"
    ]

    /// Each of `binaries` that names a Debug override, with the names it holds.
    public static func overrideNames(in binaries: [URL]) throws -> [String: [String]] {
        var found: [String: [String]] = [:]
        for binary in binaries {
            let data = try Data(contentsOf: binary, options: .alwaysMapped)
            let names = debugOverrides.filter { data.range(of: Data($0.utf8)) != nil }
            if !names.isEmpty { found[binary.lastPathComponent] = names }
        }
        return found
    }

    /// The environment the bundle's tools run in: the user's basics, no LTM_ overrides (the bundle must stand alone).
    public static var cleanEnvironment: [String: String] {
        var clean = environment.filter {
            !$0.key.hasPrefix("LTM_") && !$0.key.hasPrefix("TEST_RUNNER_") && !$0.key.hasPrefix("XCTest")
        }
        // the system's tools and the toolchain's shims only, never Homebrew's
        clean["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return clean
    }
}
