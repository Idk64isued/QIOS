import Foundation
import TestIsolation
import Testing

@testable import LightTouchCore

/// No test may touch the real library: the process runs in a private home (Tests/TestIsolation).
struct TestIsolationTests {
    @Test func appStateLogsAndCachesAreOutsideTheRealHome() {
        let home = String(cString: ltm_test_home())
        let real = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/Users"
        #expect(!home.isEmpty && !home.hasPrefix(real + "/Library"))
        for url in [
            Bundled.stateDirectory, Bundled.logsDirectory,
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        ] {
            #expect(!url.path.hasPrefix(real + "/Library"), "\(url.path) is the real library")
        }
    }
}

/// The real app.log (~/Library/Logs/gold.samhenri.LightTouchMac, the user's own home): what a test run must never write.
let realAppLog = URL(fileURLWithPath: getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/Users")
    .appendingPathComponent("Library/Logs/\(StorageLocations.bundleIdentifier)/app.log")

struct AppLogIsolationTests {
    /// logEvent (IPALibrary's notes, the session's notices) lands in the test's own Logs, never the real app.log.
    @Test func appEventsStayOutOfTheRealAppLog() async throws {
        let marker = "test-isolation marker \(UUID().uuidString)"
        logEvent(marker)
        await AppEventLog.shared.flush()
        let isolated = try String(contentsOf: Bundled.logsDirectory.appendingPathComponent("app.log"), encoding: .utf8)
        #expect(isolated.contains(marker), "the event went nowhere (\(Bundled.logsDirectory.path))")
        let real = (try? String(contentsOf: realAppLog, encoding: .utf8)) ?? ""
        #expect(!real.contains(marker), "a test wrote the real \(realAppLog.path)")
    }
}
