import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// Restart syncs the guest's filesystem before the reset and retires the boot; a failed or stale sync resets
/// nothing; a device without guest tools halts and restarts. Power On renews the boot in place and resumes the
/// machine once the shutdown latch clears.
struct BootCycleTests {
    /// What every boot begins with (BootCycleHost.beginBoot), then every watch it starts (startBootWatches).
    static let begin = ["forgetBootFacts", "ensureUSBMux", "publish", "resetRotation"]
    static let watches = ["timeZone", "foreground", "orientation", "guestPackage", "bootWatch"]
    static let freshBoot = begin + watches

    func session(_ directory: URL) -> FakeSession {
        let s = FakeSession(directory: directory)
        s.state = .running
        return s
    }

    @Test func restartSyncsThenResetsInANewBoot() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            let old = c.bootScope.id
            c.cycle.reset()
            await c.bootScope[.reset]?.value
            #expect(c.syncs == 1 && c.link.commands == [.machine(.reset)])
            #expect(c.bootScope.id != old && !c.bootScope.retired && c.state == .booting)
            #expect(c.steps == ["retire"] + Self.freshBoot, "\(c.steps)")
            #expect(c.readiness.current != nil && c.preparingDevice, "the new boot's readiness watch")
            c.readiness.cancel()
        }
    }

    /// State audit A-14: Restart on a paused device asked a guest that couldn't answer to sync, then said it
    /// "didn't finish saving its files" and left it paused. It resumes the guest first.
    @Test func restartResumesAPausedGuestFirst() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.state = .paused
            c.link.onCommand = { if $0 == .machine(.resume) { c.syncFails = false } }
            c.syncFails = true  // as a paused guest's agent
            c.cycle.reset()
            await c.bootScope[.reset]?.value
            #expect(c.link.commands == [.machine(.resume), .machine(.reset)] && c.state == .booting)
            #expect(c.notices.message == nil)
            c.readiness.cancel()
        }
    }

    @Test func aFailedSyncResetsNothing() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.state = .booting
            c.syncFails = true
            c.cycle.reset()
            await c.bootScope[.reset]?.value
            #expect(c.link.commands.isEmpty && !c.bootScope.retired && c.steps.isEmpty)
            #expect(c.notices.message == "Couldn’t restart because the device didn’t finish saving its files.")
            #expect(c.readiness.current != nil, "a booting device gets its readiness watch back")
            c.readiness.cancel()
            // The next good restart resolves the notice.
            c.syncFails = false
            c.state = .running
            c.cycle.reset()
            await c.bootScope[.reset]?.value
            #expect(c.notices.message == nil && c.link.commands == [.machine(.reset)])
            c.readiness.cancel()
        }
    }

    @Test func aStaleSyncResetsNothing() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.beforeSyncReturns = { c.bootScope.retire() }
            c.cycle.reset()
            await c.bootScope[.reset]?.value
            await Task.yield()
            #expect(c.link.commands.isEmpty && c.notices.message == nil && c.steps.isEmpty)
        }
    }

    @Test func noGuestToolsHaltsAndRestarts() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.hasGuestTools = false
            var restarted = false
            c.onRestart = { restarted = true }
            c.cycle.reset()
            await eventually("restart requested") { restarted }
            #expect(c.syncs == 0 && c.link.commands.isEmpty && c.fakeHelper!.terms == 1)
        }
    }

    @Test func restartWaitsForTheBootsPreparationAndSkipsStoppedDevices() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.readiness.start()
            let preparation = c.readiness.current
            c.cycle.reset()
            #expect(preparation?.isCancelled == true, "the readiness watch is cancelled before the sync")
            await c.bootScope[.reset]?.value
            #expect(c.syncs == 1)
            c.readiness.cancel()

            let failed = session(directory)
            failed.storageFailed = true
            failed.cycle.reset()
            #expect(failed.bootScope[.reset] == nil)
            let off = session(directory)
            off.state = .poweredOff
            off.fakeHelper!.isDead = true
            off.cycle.reset()
            #expect(off.steps == ["restart"], "a halted device restarts with a fresh helper")
        }
    }

    @Test func powerOnRenewsTheBootAndResumesOnceTheLatchClears() async throws {
        try await withScratchDirectory { directory in
            let cold = session(directory)
            cold.state = .poweredOff
            cold.status = helperStatus(displaySleeping: true, shutdownConfirmed: true)
            cold.cycle.powerOn()
            #expect(cold.bootScope.generation == 1 && cold.cycle.poweringOn && cold.state == .booting)
            #expect(
                cold.steps == Self.begin,
                "\(cold.steps)"
            )
            #expect(cold.link.commands == [.machine(.reset)])
            try await Task.sleep(for: .milliseconds(100))
            #expect(cold.link.commands == [.machine(.reset)], "no resume while the latch is set")
            cold.status = helperStatus(displaySleeping: true, shutdownConfirmed: false)
            await cold.bootScope[.powerOn]?.value
            #expect(cold.link.commands == [.machine(.reset), .machine(.resume)] && !cold.cycle.poweringOn)
            #expect(cold.steps == Self.freshBoot, "every watch a fresh boot starts, auto-rotation too")
            #expect(cold.readiness.current != nil)
            // The new boot's readiness watch wakes the sleeping display once it's up.
            cold.state = .running
            await cold.readiness.current?.value
            #expect(cold.homes == 1)
        }
    }

    /// State audit A-3: Shut Down then Start (an in-place power-on) left auto-rotation off, because Power On started
    /// its own shorter list of watches. A fresh helper's boot, a Restart and a Power On now start one list.
    @Test func everyBootStartsTheSameWatches() async throws {
        try await withScratchDirectory { directory in
            let fresh = session(directory)
            fresh.state = .booting
            fresh.cycle.begin()
            #expect(fresh.steps == Self.freshBoot && fresh.readiness.current != nil, "\(fresh.steps)")
            fresh.readiness.cancel()

            let restarted = session(directory)
            restarted.cycle.reset()
            await restarted.bootScope[.reset]?.value
            #expect(Array(restarted.steps.dropFirst()) == Self.freshBoot && restarted.readiness.current != nil)
            restarted.readiness.cancel()

            let poweredOn = session(directory)
            poweredOn.state = .poweredOff
            poweredOn.status = helperStatus(shutdownConfirmed: false)
            poweredOn.cycle.powerOn()
            await poweredOn.bootScope[.powerOn]?.value
            #expect(poweredOn.steps == Self.freshBoot && poweredOn.readiness.current != nil, "\(poweredOn.steps)")
            poweredOn.readiness.cancel()
        }
    }

    /// State audit A-13: the last boot's connection issue outlived a Restart or a Power On, and the status line ranks
    /// it above the new boot's "Starting iOS…"; the display's sleep and reachability did too.
    @Test func aNewBootForgetsWhatTheLastOneLearned() async throws {
        try await withScratchDirectory { directory in
            for powerOn in [false, true] {
                let c = session(directory)
                c.isSleeping = true
                c.deviceReachable = true
                c.recovery.reportFailure(
                    DeviceError.instproxy(.connFailed, phase: "connect"),
                    operation: "Refreshing apps"
                )
                #expect(c.recovery.issue != nil)
                if powerOn {
                    c.state = .poweredOff
                    c.cycle.powerOn()
                } else {
                    c.cycle.reset()
                    await c.bootScope[.reset]?.value
                }
                #expect(c.recovery.issue == nil && !c.isSleeping && c.deviceReachable == nil, "power on: \(powerOn)")
                c.retireBoot()
            }
        }
    }

    /// State audit A-4: Start after Shut Down powered the same helper on, so a free-form size, the Internet switch,
    /// the debug port or the boot arguments chosen while it was off waited for some later Stop. A change quits the
    /// powered-off helper and starts a fresh one; with none, Start stays in place.
    @Test func startAfterShutDownTakesChangedSettingsWithAFreshHelper() async throws {
        try await withScratchDirectory { directory in
            let changed = session(directory)
            changed.state = .poweredOff
            changed.nextStartChanged = true
            changed.fakeHelper!.onExit = { [unowned changed] in changed.bootWatch.helperDied("quit") }
            changed.link.onCommand = { if case .machine(.quit) = $0 { changed.fakeHelper!.exit() } }
            var restarted = false
            changed.onRestart = { restarted = true }
            changed.cycle.powerOn()
            await eventually("a fresh helper") { restarted }
            #expect(changed.link.commands == [.machine(.quit)] && changed.state == .poweredOff)
            #expect(!changed.cycle.poweringOn && changed.fakeHelper!.kills == 0)

            let same = session(directory)
            same.state = .poweredOff
            same.status = helperStatus(shutdownConfirmed: false)
            same.cycle.powerOn()
            await same.bootScope[.powerOn]?.value
            #expect(same.link.commands == [.machine(.reset), .machine(.resume)] && !same.steps.contains("restart"))
            same.readiness.cancel()
        }
    }

    /// State audit A-10: a power-on whose task was cancelled (a Restart or a halt retiring the boot) left
    /// `poweringOn` set, so frames never moved the next boot to running and a guest power-off went unnoticed.
    @Test func aCancelledPowerOnEndsItsPoweringOn() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.state = .poweredOff
            c.status = helperStatus(shutdownConfirmed: true)
            c.cycle.powerOn()
            let task = c.bootScope[.powerOn]
            #expect(c.cycle.poweringOn)
            c.retireBoot()
            await task?.value
            #expect(!c.cycle.poweringOn)
            #expect(c.state.runsAfterFrame(poweringOn: c.cycle.poweringOn), "the next frame ends the boot")
        }
    }

    @Test func aPowerOnCancelledWhileWaitingForTheLatchEndsAtOnce() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.state = .poweredOff
            c.status = helperStatus(shutdownConfirmed: true)
            c.cycle.latchWait = .seconds(5)
            c.cycle.powerOn()
            let task = c.bootScope[.powerOn]
            try await Task.sleep(for: .milliseconds(200))  // past the workers, waiting on the latch
            let cancelled = ContinuousClock.now
            c.retireBoot()
            await task?.value
            #expect(ContinuousClock.now - cancelled < .seconds(1), "it ends at once, not when the latch wait runs out")
            #expect(!c.cycle.poweringOn && c.link.commands == [.machine(.reset)], "and never resumes the machine")
        }
    }

    @Test func powerOnGivesUpWhenTheLatchStays() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.state = .poweredOff
            c.status = helperStatus(shutdownConfirmed: true)
            c.cycle.latchWait = .milliseconds(50)
            c.cycle.powerOn()
            await c.bootScope[.powerOn]?.value
            #expect(
                c.state == .poweredOff && !c.cycle.poweringOn && c.bootScope.retired
                    && c.link.commands == [.machine(.reset)]
            )

            let gone = session(directory)
            gone.state = .poweredOff
            gone.fakeHelper!.isDead = true
            gone.cycle.powerOn()
            #expect(gone.steps == ["restart"] && gone.bootScope.generation == 0)
        }
    }
}
