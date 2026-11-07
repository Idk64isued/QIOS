import Foundation
import Testing

@testable import LightTouchCore

/// A step's mark left by a run that died in it skips the step from the next launch on, with one notice, until the step
/// runs to its end again; a step that ends, or a clean quit, leaves nothing. Each launch is CrashGuard.launch over the
/// same defaults, as the next process would read them.
@Suite(.serialized) struct CrashGuardTests {
    let domain = "ltm-crash-guard-test-" + UUID().uuidString
    var defaults: UserDefaults { UserDefaults(suiteName: domain)! }

    @Test func aStepLeftRunningIsSkippedUntilItRunsAgain() {
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(CrashGuard.launch(defaults).isEmpty)
        CrashGuard.begin(.model)
        // The run dies here: the next launch finds the mark.
        #expect(CrashGuard.launch(defaults) == [.model])
        #expect(CrashGuard.skips(.model) && !CrashGuard.skips(.deviceStart))
        #expect(CrashGuard.notice == "Light Touch quit unexpectedly while showing the 3D device, so it shows 2D.")
        // Still skipped at the launch after, without a second notice.
        #expect(CrashGuard.launch(defaults).isEmpty)
        #expect(CrashGuard.skips(.model) && CrashGuard.notice == nil)
        // View ▸ Device Bezels ▸ 3D: the next load runs it, and once it ends it isn't skipped again.
        CrashGuard.tryAgain(.model)
        #expect(!CrashGuard.skips(.model))
        CrashGuard.begin(.model)
        CrashGuard.end(.model)
        #expect(CrashGuard.launch(defaults).isEmpty)
        #expect(!CrashGuard.skips(.model))
        #expect(defaults.object(forKey: CrashGuard.key) == nil, "nothing left behind")
    }

    @Test func aStepThatEndsOrACleanQuitLeavesNoMark() {
        defer { defaults.removePersistentDomain(forName: domain) }
        CrashGuard.launch(defaults)
        // Two windows load a model at once: the mark stays until the second ends.
        CrashGuard.begin(.model)
        CrashGuard.begin(.model)
        CrashGuard.end(.model)
        CrashGuard.begin(.deviceStart)
        CrashGuard.end(.deviceStart)
        CrashGuard.end(.deviceStart)  // an unmatched end changes nothing
        #expect(CrashGuard.launch(defaults) == [.model], "one model still loaded when the run died")
        CrashGuard.launch(defaults)
        CrashGuard.tryAgain(.model)
        CrashGuard.begin(.deviceStart)
        CrashGuard.quit()
        #expect(CrashGuard.launch(defaults).isEmpty, "a quit while a device started is not a crash")
        #expect(!CrashGuard.skips(.deviceStart))
    }

    @Test func aDeviceThatStartsAgainIsNoLongerSkipped() {
        defer { defaults.removePersistentDomain(forName: domain) }
        CrashGuard.launch(defaults)
        CrashGuard.begin(.deviceStart)
        CrashGuard.begin(.model)
        #expect(CrashGuard.launch(defaults) == [.model, .deviceStart])
        #expect(
            CrashGuard.notice
                == "Light Touch quit unexpectedly while a device was starting, so it didn’t start one and shows 2D."
        )
        CrashGuard.dismissNotice()
        #expect(CrashGuard.notice == nil && CrashGuard.skips(.deviceStart))
        // The user's own Start: it boots, and the next launch starts the device again.
        CrashGuard.begin(.deviceStart)
        #expect(!CrashGuard.skips(.deviceStart))
        CrashGuard.end(.deviceStart)
        CrashGuard.launch(defaults)
        #expect(!CrashGuard.skips(.deviceStart) && CrashGuard.skips(.model))
    }
}
