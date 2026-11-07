import Foundation
import Testing

@testable import LightTouchCore

/// AppKit's saved interface is off for this process only: the user's and the emulator's preferences stay as they were.
struct RestorationDefaultsTests {
    @Test func processOnlyOverridesKeepPreferences() throws {
        let domain = "ltm-window-restoration-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "NSQuitAlwaysKeepsWindows")
        defaults.set(false, forKey: "ApplePersistenceIgnoreState")
        defaults.set("/chosen/captures", forKey: "captureFolder")
        defaults.set("guest-state", forKey: "resumeOnLaunch")
        let persisted = try #require(defaults.persistentDomain(forName: domain))
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        defaults.setVolatileDomain(
            saved.merging(["testArgument": "retained"]) { $1 },
            forName: UserDefaults.argumentDomain
        )

        RestorationDefaults.configure(defaults)

        #expect(!defaults.bool(forKey: "NSQuitAlwaysKeepsWindows"))
        #expect(defaults.bool(forKey: "ApplePersistenceIgnoreState"))
        #expect(defaults.string(forKey: "testArgument") == "retained", "other arguments survive")
        #expect(
            try #require(defaults.persistentDomain(forName: domain)) as NSDictionary == persisted as NSDictionary,
            "restoration policy must not change emulator or user preferences"
        )
    }
}
