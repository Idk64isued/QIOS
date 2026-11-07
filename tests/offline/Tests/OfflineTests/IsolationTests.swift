import Foundation
import OfflineIsolation
import Testing

@testable import LightTouchCore

/// The views here read and write app state (the library, preferences, caches, logs): never the real one.
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
