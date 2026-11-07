import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// Failed service reads: which become a standing issue, which restart the management service (once, with a
/// cooldown, never during a transfer, an install, boot preparation or a shutdown), and the per-boot activation verdict.
struct ConnectionRecoveryTests {
    static let unactivated = "This iPod isn’t activated. Choose Erase All Content and Settings, then prepare it again."

    func session(_ directory: URL) -> FakeSession {
        let s = FakeSession(directory: directory)
        s.state = .running
        s.recovery.settle = .milliseconds(1)
        s.activation.retryDelay = .milliseconds(5)
        return s
    }
    /// Waits for the boot's activation verdict.
    func verdict(_ s: FakeSession) async { await s.bootScope[.activation]?.value }
    /// Lets the recovery (or activation) task run.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(30))
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func repeatedManagementFailuresRecoverOnceWithCooldownAndGuards() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            #expect(
                observes({ _ = c.recovery.issue }) {
                    c.recovery.reportFailure(
                        DeviceError.instproxy(.opInProgress, phase: "browse"),
                        operation: "Refreshing apps"
                    )
                },
                "the inspector's placeholder and the status line follow the issue"
            )
            #expect(
                c.recovery.issue?.summary == "Updating apps…" && c.deviceReachable == nil,
                "installd busy blocks nothing"
            )
            for error: DeviceError in [
                .endpointBusy, .notAttached, .unavailable, .timedOut(operation: "USB connection"),
                .instproxy(.opFailed, phase: "browse"), .lockdown(-17), .lockdown(-4), .lockdown(-27), .lockdown(-32)
            ] {
                c.recovery.reportFailure(error, operation: "Checking connection")
                c.deviceReachable = false
                c.deviceReachable = false
                await settle()
                #expect(c.recoveries == 0, "\(error): not a failure lockdownd's restart fixes")
            }
            c.recovery.reportFailure(DeviceError.endpointBusy, operation: "Checking connection")
            #expect(
                c.recovery.issue?.summary == "Waiting for another device’s USB request…"
                    && c.recovery.issue?.reconnectManagement == false
            )
            let previous = c.recovery.issue
            c.recovery.reportFailure(CancellationError(), operation: "Closing inspector")
            #expect(c.recovery.issue == previous, "a cancellation is not a connection failure")

            c.recovery.reportFailure(DeviceError.instproxy(.connFailed, phase: "connect"), operation: "Refreshing apps")
            await settle()
            #expect(c.recoveries == 0, "one failure is not enough")
            c.deviceReachable = false
            for _ in 0..<10 { c.deviceReachable = false }
            await settle()
            #expect(c.recoveries == 1 && !c.recovery.isReconnecting && c.steps.contains("appsChanged"))
            c.deviceReachable = true
            #expect(c.recovery.issue == nil, "a service answering clears the issue")

            c.recovery.reportFailure(DeviceError.lockdown(-8), operation: "Refreshing apps")
            c.deviceReachable = false
            await settle()
            #expect(c.recoveries == 1, "backs off for a minute")
            c.recovery.lastRecovery = .distantPast
            c.installerUsesDevice = true
            c.deviceReachable = false
            c.deviceReachable = false
            await settle()
            #expect(c.recoveries == 1, "never interrupts an install")
            c.installerUsesDevice = false
            c.readiness.preparingDevice = true
            c.deviceReachable = false
            await settle()
            #expect(c.recoveries == 1, "never interrupts boot preparation")
            c.readiness.preparingDevice = false
            c.hasFileTransfer = true
            c.deviceReachable = false
            await settle()
            #expect(c.recoveries == 1, "never interrupts a file transfer")
            c.hasFileTransfer = false
            c.isInstalling = true
            c.deviceReachable = false
            await settle()
            #expect(c.recoveries == 1, "never interrupts an install in progress")
            c.isInstalling = false
            c.liveAgentStatus = 0
            c.deviceReachable = false
            await settle()
            #expect(c.recoveries == 1, "no independent channel to do it through")
            c.liveAgentStatus = 1
            c.isRunning = false
            c.deviceReachable = false
            await settle()
            #expect(c.recoveries == 1, "never during a shutdown")
            c.isRunning = true
            c.deviceReachable = false
            await settle()
            #expect(c.recoveries == 2)
        }
    }

    @Test func activatedStatesAndTheUnactivatedIssue() {
        for state in ["Activated", "FactoryActivated", "WildcardActivated"] {
            #expect(DeviceConnectionIssue.activation(state: state, profile: .n72) == nil, "\(state)")
        }
        for state in ["Unactivated", "Pending", "", "SomeOtherActivated"] {
            #expect(DeviceConnectionIssue.activation(state: state, profile: .n72) != nil, "\(state)")
        }
        #expect(DeviceConnectionIssue.activation(state: nil, profile: .n72) == nil)
    }

    @Test func unactivatedIsAPersistentIssueThatALaterServiceAnswerClears() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.readiness.preparingDevice = true
            let preparation = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
            c.bootScope[.readiness] = preparation
            c.activationAnswers = ["Unactivated", "Unactivated", "Unactivated"]
            c.deviceReachable = true
            await verdict(c)
            #expect(c.activationAsked == 3, "a verdict takes three answers")
            #expect(c.recovery.issue?.summary == Self.unactivated && c.recovery.issue?.persistent == true)
            #expect(c.recovery.issue?.blocksCommands == true && c.recovery.issue?.reconnectManagement == false)
            #expect(
                c.deviceReachable == false && !c.preparingDevice && preparation.isCancelled
                    && c.notices.message == Self.unactivated
            )
            #expect(c.notices.offersErase)
            // Transient failures leave it; -34 maps to it.
            c.recovery.reportFailure(DeviceError.lockdown(-8), operation: "Refreshing apps")
            #expect(c.recovery.issue?.summary == Self.unactivated)
            c.recovery.reportFailure(DeviceError.lockdown(-34), operation: "Refreshing apps")
            #expect(c.recovery.issue?.summary == Self.unactivated && c.recovery.issue?.persistent == true)
            // A service that answers later (the inspector's list read) clears it: installs are no longer blocked.
            c.deviceReachable = true
            await verdict(c)
            #expect(
                c.activationAsked == 3 && c.recovery.issue == nil && c.deviceReachable == true
                    && c.notices.message == nil
            )
            // The next boot asks again.
            c.bootScope.renew()
            c.activationAnswers = ["Activated"]
            c.deviceReachable = true
            await verdict(c)
            #expect(c.activationAsked == 4 && c.recovery.issue == nil && c.finished == 1)
        }
    }

    @Test func servicesThatAnswerWinOverTheString() async throws {
        try await withScratchDirectory { directory in
            // The built-in iPod reports Unactivated and works.
            let works = session(directory)
            works.readiness.preparingDevice = true
            works.notices.report("stale", for: .activation)
            works.activationAnswers = ["Unactivated", "Unactivated", "Unactivated"]
            works.servicesAnswer = true
            works.deviceReachable = true
            await verdict(works)
            #expect(
                works.activationAsked == 3 && works.probed == 1 && works.recovery.issue == nil
                    && works.deviceReachable == true
            )
            #expect(
                works.preparingDevice && works.notices.message == nil,
                "not blocked; a stale activation notice resolved"
            )
            // A -34 standing when a service read later succeeds clears with it.
            works.recovery.reportFailure(DeviceError.lockdown(-34), operation: "Refreshing apps")
            #expect(works.recovery.issue?.persistent == true && works.deviceReachable == false)
            works.deviceReachable = true
            await verdict(works)
            #expect(works.recovery.issue == nil)
        }
    }

    @Test func transientAnswersNeverDecideAndCompletionRetries() async throws {
        try await withScratchDirectory { directory in
            let flaky = session(directory)
            flaky.readiness.preparingDevice = true
            flaky.activationAnswers = [nil, "Unactivated", "WildcardActivated"]
            flaky.deviceReachable = true
            await verdict(flaky)
            #expect(flaky.activationAsked == 3 && flaky.recovery.issue == nil && flaky.preparingDevice)

            // Three unanswered questions are asked again on the next answer; activated, nothing more this boot.
            let ok = session(directory)
            ok.activationAnswers = [nil, nil, nil, "Activated"]
            ok.deviceReachable = true
            await verdict(ok)
            #expect(ok.activationAsked == 3 && ok.recovery.issue == nil)
            ok.deviceReachable = true
            await verdict(ok)
            #expect(ok.activationAsked == 4 && ok.finished == 1)
            ok.deviceReachable = true
            await verdict(ok)
            #expect(ok.activationAsked == 4)

            // An unacknowledged completion keeps the check eligible.
            let retry = session(directory)
            retry.activationAnswers = Array(repeating: "Activated", count: 4)
            retry.completionFailures = 3
            retry.deviceReachable = true
            await verdict(retry)
            #expect(retry.finished == 3)
            retry.deviceReachable = true
            await verdict(retry)
            #expect(retry.finished == 4)
            retry.deviceReachable = true
            await verdict(retry)
            #expect(retry.finished == 4)

            // A fresh -34 with no prior issue is the same persistent issue.
            let refused = session(directory)
            refused.recovery.reportFailure(DeviceError.lockdown(-34), operation: "Refreshing apps")
            #expect(refused.recovery.issue?.summary == Self.unactivated && refused.recovery.issue?.persistent == true)
        }
    }

    @Test func theLockSaysPreparedWithoutActivation() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("device.lock.json")
            func lacks(_ text: String) -> Bool {
                try! Data(text.utf8).write(to: url)
                return DeviceInstance.lockLacksActivation(url)
            }
            #expect(lacks(#"{"inputs": {"ipsw": {}, "activation": null}}"#))
            #expect(lacks(#"{"inputs": {"ipsw": {}, "activation_hook": null}}"#))
            #expect(!lacks(#"{"inputs": {"activation": {"input_sha256": "a", "output_sha256": "b"}}}"#))
            #expect(!lacks("not json"))
            #expect(!DeviceInstance.lockLacksActivation(directory.appendingPathComponent("missing")))
        }
    }
}
