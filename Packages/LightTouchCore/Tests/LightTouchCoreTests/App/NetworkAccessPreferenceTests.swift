import Foundation
import Testing

@testable import LightTouchCore

/// A saved guest-network choice and the command line's --network/--no-network decide without a prompt.
struct NetworkAccessPreferenceTests {
    func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let domain = "ltm-network-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults)
    }

    @Test(arguments: [[], ["--network"], ["--no-network"], ["--network", "--no-network"]])
    func savedChoiceOrExplicitOverride(_ flags: [String]) {
        withDefaults { defaults in
            #expect(
                NetworkAccessPreference.decided(arguments: ["LightTouch"] + flags, defaults: defaults)
                    == (flags.isEmpty ? nil : !flags.contains("--no-network")),
                "no saved answer and no flag: ask"
            )
            for saved in [true, false] {
                defaults.set(saved, forKey: NetworkAccessPreference.key)
                let explicit = !flags.isEmpty
                #expect(
                    NetworkAccessPreference.decided(arguments: ["LightTouch"] + flags, defaults: defaults)
                        == (explicit ? !flags.contains("--no-network") : saved)
                )
                #expect(
                    defaults.bool(forKey: NetworkAccessPreference.key) == saved,
                    "an explicit flag is not remembered"
                )
            }
        }
    }

    @Test func menuChoiceFollowsSavedThenRunningDevice() {
        withDefaults { defaults in
            #expect(NetworkAccessPreference.desired(running: nil, defaults: defaults))
            #expect(!NetworkAccessPreference.desired(running: false, defaults: defaults))
            NetworkAccessPreference.toggle(running: false, defaults: defaults)
            #expect(defaults.object(forKey: NetworkAccessPreference.key) as? Bool == true)
            NetworkAccessPreference.toggle(running: true, defaults: defaults)
            #expect(defaults.object(forKey: NetworkAccessPreference.key) as? Bool == false)
            #expect(!NetworkAccessPreference.desired(running: true, defaults: defaults))
        }
    }
}
