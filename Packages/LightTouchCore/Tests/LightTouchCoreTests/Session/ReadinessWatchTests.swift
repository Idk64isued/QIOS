import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// The boot's readiness watch: one display wake for a backlight that's off, nothing for an awake one or a stale,
/// cancelled or stopping boot; at the deadline iOS on screen keeps running without USB, no picture fails.
struct ReadinessWatchTests {
    func session(_ directory: URL, sleeping: Bool = false) -> FakeSession {
        let s = FakeSession(directory: directory)
        s.state = .running
        s.status = helperStatus(displaySleeping: sleeping)
        return s
    }

    @Test(arguments: [true, false])
    func wakesTheDisplayOnlyWhenItSleeps(_ sleeping: Bool) async throws {
        try await withScratchDirectory { directory in
            let c = session(directory, sleeping: sleeping)
            c.readiness.start()
            #expect(c.preparingDevice && c.readiness.preparationStatus == "Starting iOS…" && c.bootStage == .poweringOn)
            await c.readiness.current?.value
            #expect(c.homes == (sleeping ? 1 : 0) && !c.preparingDevice)
            #expect(c.preparingAtHome == (sleeping ? [true] : []), "Home only while input is still held back")
            #expect(c.readiness.bootStage == .usb, "USB answered: the toast moves on to the Home screen")
            #expect(c.deviceReachable == true && c.readiness.readinessFailure == nil)
        }
    }

    @Test func waitsForSpringBoardBeforeInput() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.springBoardReady = false
            c.readiness.start()
            await eventually("SpringBoard asked") { c.springBoardChecks > 0 }
            #expect(
                c.preparingDevice && c.readiness.preparationStatus == "Waiting for the Home screen…"
                    && c.deviceReachable == nil
            )
            c.springBoardReady = true
            await c.readiness.current?.value
            #expect(!c.preparingDevice && c.deviceReachable == true)
        }
    }

    @Test func aBootThatEndsInSetupWaitsForSetup() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.expectsSetup = true
            c.springBoardReady = false
            c.readiness.start()
            await eventually("SpringBoard asked") { c.springBoardChecks > 0 }
            #expect(c.readiness.preparationStatus == "Waiting for Setup…")
            #expect(c.bootStage.text(expectingSetup: true) == "Waiting for Setup")
            c.springBoardReady = true
            await c.readiness.current?.value
        }
    }

    /// Sam 10-07: an iPhone 4 on iOS 7 showed Setup's slide but the app said it hadn't finished starting and refused
    /// input. SpringBoard answering late is not a failed startup: the screen is live, so input is the user's, and the
    /// late answer makes the device ready with no restart.
    @Test func aLateSpringBoardNeverLocksInput() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.springBoardReady = false
            c.springBoardWait = .milliseconds(30)
            c.readiness.start()
            await eventually("one wait gave up") { c.springBoardChecks > 1 }
            #expect(!c.preparingDevice && c.readiness.readinessFailure == nil, "input enabled, no startup failure")
            #expect(c.notices.message == ReadinessWatch.springBoardNotice(shortName: "iPod"))
            #expect(c.readiness.current != nil && c.deviceReachable == nil, "still asking")
            c.springBoardReady = true
            await c.readiness.current?.value
            #expect(c.deviceReachable == true && c.notices.message == nil, "the late answer: ready, notice gone")
        }
    }

    @Test func staleCancelledAndStoppingBootsAreLeftAlone() async throws {
        try await withScratchDirectory { directory in
            let stale = session(directory, sleeping: true)
            stale.onDeviceReady = {
                stale.onDeviceReady = nil
                stale.bootScope.renew()
                stale.usbAnswers = false
                stale.readiness.start()
            }
            stale.readiness.start()
            let staleTask = stale.readiness.current
            await staleTask?.value
            #expect(stale.preparingDevice && stale.homes == 0, "a later boot owns the flag")
            stale.readiness.cancel()

            let cancelled = session(directory, sleeping: true)
            cancelled.onDeviceReady = { cancelled.readiness.cancel() }
            cancelled.readiness.start()
            await cancelled.readiness.current?.value
            #expect(cancelled.homes == 0 && !cancelled.preparingDevice && cancelled.readiness.readinessFailure == nil)

            let quitting = session(directory, sleeping: true)
            quitting.onDeviceReady = { quitting.ladder.halt() }
            quitting.readiness.start()
            await quitting.readiness.current?.value
            #expect(quitting.homes == 0)

            let stopping = session(directory)
            stopping.ladder.halt()
            stopping.readiness.start()
            #expect(stopping.readiness.current == nil && !stopping.preparingDevice, "a stopping device starts no watch")
        }
    }

    /// Sam 10-07: Shut Down while the boot was at "Connecting over USB" left "Starting iOS… Connecting over USB" counting
    /// for 16 minutes over the powered-off screen. Every ending retires the boot; the startup must end with it.
    @Test func aBootThatEndsBeforeUSBEndsItsStartup() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.usbAnswers = false
            c.readiness.start()
            c.readiness.noteBoot(.guestTools)
            #expect(c.preparingDevice && c.bootStage.text == "Connecting over USB")
            let watch = c.readiness.current
            c.state = .poweredOff
            c.retireBoot()
            await watch?.value
            #expect(!c.preparingDevice && c.readiness.current == nil, "no startup banner, nothing left counting")
            #expect(
                c.readiness.readinessFailure == nil && c.notices.message == nil,
                "an ended boot is not a failed one"
            )
        }
    }

    @Test func theDeadlineKeepsIOSOnScreenRunningWithoutUSB() async throws {
        try await withScratchDirectory { directory in
            let noUSB = session(directory)
            noUSB.readiness.budget = .milliseconds(100)
            noUSB.usbAnswers = false
            noUSB.readiness.start()
            #expect(
                observes({ _ = noUSB.readiness.bootStage }) {
                    noUSB.readiness.noteBoot(.serial("launchd[1] has started up"))
                },
                "the boot toast's stage follows"
            )
            #expect(noUSB.bootStage == .system)
            await eventually("the deadline passed") { noUSB.notices.message != nil }
            #expect(
                !noUSB.preparingDevice && noUSB.readiness.readinessFailure == nil,
                "kept running, not a startup failure"
            )
            #expect(noUSB.notices.message == ReadinessDeadline.notice(shortName: "iPod"))
            noUSB.usbAnswers = true
            await noUSB.readiness.current?.value
            #expect(
                noUSB.deviceReachable == true && noUSB.notices.message == nil && noUSB.bootStage == .usb,
                "USB came: ready, notice gone"
            )

            // No picture from iOS by the deadline: the startup fails.
            let dark = session(directory)
            dark.readiness.budget = .milliseconds(100)
            dark.usbAnswers = false
            dark.readiness.start()
            dark.readiness.noteBoot(.serial("Darwin Kernel Version"))
            await dark.readiness.current?.value
            #expect(dark.readiness.readinessFailure != nil && !dark.preparingDevice)
            #expect(dark.notices.message == "The iPod didn’t finish starting. Restart it to try again.")
        }
    }

    /// State audit A-2: the readiness deadline kept counting through the Mac's sleep, so waking from a long sleep
    /// mid-boot said "Startup failed".
    @Test func theMacsSleepDoesntCountAgainstStartup() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.readiness.budget = .milliseconds(100)
            c.usbAnswers = false
            c.hostPower.hostWillSleep()
            c.readiness.start()
            try await Task.sleep(for: .milliseconds(400))
            #expect(c.readiness.readinessFailure == nil && c.preparingDevice, "the Mac slept through the budget")
            c.hostPower.hostDidWake()
            await c.readiness.current?.value
            #expect(c.readiness.readinessFailure != nil, "awake, it runs out as before")
        }
    }

    @Test func aDeadDeviceFailsItsStartup() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.usbAnswers = false
            c.readiness.start()
            c.state = .dead(exitCode: nil)
            await c.readiness.current?.value
            #expect(c.readiness.readinessFailure != nil && !c.preparingDevice)
        }
    }
}
