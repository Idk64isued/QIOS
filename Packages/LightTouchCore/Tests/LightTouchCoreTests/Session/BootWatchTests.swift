import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// A boot that never lights ends as a named error with the helper halted, never "Booting…" forever; recovery mode
/// does the same at once; a base missing a boot file is named before anything boots.
struct BootWatchTests {
    func session(_ directory: URL, _ profile: Board = .n72) -> FakeSession {
        let s = FakeSession(directory: directory, profile: profile)
        s.bootWatch.budget = 0.3
        s.bootWatch.haltBudget = 0.2
        s.fakeHelper!.onExit = { [unowned s] in s.bootWatch.helperDied("The emulator stopped.") }
        return s
    }
    /// The deadline fired and chose to stop (the helper was told), then the helper's exit ends the session.
    func halted(_ c: FakeSession) async {
        await c.bootWatch.current?.value
        #expect(c.fakeHelper!.terms == 1, "not stopped at the deadline")
        await eventually("dead") { c.isDead }
    }

    @Test func noAnswerWithinTheBudgetHaltsWithTheDeadlineReason() async throws {
        try await withScratchDirectory { directory in
            let late = session(directory)
            late.bootWatch.start()
            await halted(late)
            #expect(late.state == .dead(exitCode: nil) && late.bootWatch.deathReason == BootWatch.deadlineReason(.n72))
            #expect(late.bootWatch.deathReason!.hasPrefix("The iPod didn’t start within"))
            #expect(
                late.steps == ["retire", "discard", "forgetBootFacts", "release"] && late.timeZoneStops == 1,
                "the helper's death retires the boot's work"
            )
        }
    }

    /// State audit A-2: with the lid closed past the boot budget, the deadline fired the moment the Mac woke and the
    /// device died with "didn't start within 240 seconds". The Mac's sleep and a paused device don't count.
    @Test func neitherTheMacsSleepNorAPauseCountsAgainstTheBoot() async throws {
        try await withScratchDirectory { directory in
            let asleep = session(directory)
            asleep.hostPower.hostWillSleep()
            asleep.bootWatch.start()
            try await Task.sleep(for: .milliseconds(600))
            #expect(asleep.fakeHelper!.terms == 0 && !asleep.isDead, "the Mac slept through the budget")
            asleep.hostPower.hostDidWake()
            await halted(asleep)
            #expect(asleep.bootWatch.deathReason == BootWatch.deadlineReason(.n72), "awake, the boot's time runs again")

            let paused = session(directory)
            paused.state = .paused
            paused.bootWatch.start()
            try await Task.sleep(for: .milliseconds(600))
            #expect(paused.fakeHelper!.terms == 0 && !paused.isDead, "a paused device isn't judged")
            paused.state = .booting
            await halted(paused)
        }
    }

    @Test func aFinishedOrVisibleBootIsLeftAlone() async throws {
        try await withScratchDirectory { directory in
            let lit = session(directory, .k48)
            lit.bootFinished = true
            lit.bootWatch.start()
            await lit.bootWatch.current?.value
            #expect(lit.fakeHelper!.terms == 0 && !lit.isDead && lit.bootWatch.deathReason == nil)
            // iOS on screen ("slide to set up") with its guest tools reporting, USB never answering: kept running.
            let setUp = session(directory, .k48)
            setUp.state = .running
            setUp.readiness.noteBoot(.guestTools)
            setUp.bootWatch.start()
            await setUp.bootWatch.current?.value
            #expect(!setUp.isDead && setUp.fakeHelper!.terms == 0 && setUp.bootWatch.deathReason == nil)
        }
    }

    @Test func iBootsPictureOrNoPictureIsStillStopped() async throws {
        try await withScratchDirectory { directory in
            let quiet = session(directory, .k48)
            quiet.bootWatch.start()
            await halted(quiet)
            #expect(quiet.isDead, "a lit display without lockdown is not a finished boot")
            let logo = session(directory, .k48)
            logo.state = .running
            logo.readiness.noteBoot(.serial("Darwin Kernel Version"))
            logo.bootWatch.start()
            await halted(logo)
            #expect(logo.bootWatch.deathReason == BootWatch.deadlineReason(.k48), "iBoot's picture alone is not iOS")
            let dark = session(directory, .k48)
            dark.readiness.noteBoot(.guestTools)
            dark.bootWatch.start()
            await halted(dark)
            #expect(dark.isDead, "no picture by the deadline: stopped")
        }
    }

    @Test func recoveryModeStopsAtOnceKeepingItsReason() async throws {
        try await withScratchDirectory { directory in
            let recovery = session(directory, .k48)
            recovery.bootWatch.start()
            recovery.bootWatch.abort(BootWatch.recoveryReason(.k48))
            #expect(recovery.bootWatch.current?.isCancelled == true)
            await eventually("recovery halted") { recovery.isDead }
            #expect(recovery.fakeHelper!.terms == 1 && recovery.bootWatch.deathReason == BootWatch.recoveryReason(.k48))
            #expect(
                recovery.bootWatch.deathReason!.contains("recovery mode")
                    && recovery.bootWatch.deathReason!.contains("iPad")
            )
            recovery.bootWatch.abort("again")
            #expect(recovery.fakeHelper!.terms == 1, "a dead session isn't aborted twice")
        }
    }

    @Test func aHelperIgnoringSIGTERMIsKilledAndStoppingSessionsAreLeftAlone() async throws {
        try await withScratchDirectory { directory in
            let stuck = session(directory)
            stuck.fakeHelper!.hung = true
            stuck.bootWatch.abort("stuck")
            await eventually("killed") { stuck.fakeHelper!.kills == 1 }
            #expect(stuck.fakeHelper!.terms == 1)

            let stopping = session(directory)
            stopping.ladder.halt()
            let terms = stopping.fakeHelper!.terms
            stopping.bootWatch.abort("late")
            #expect(stopping.fakeHelper!.terms == terms && stopping.bootWatch.deathReason == nil)
            await eventually("halted") { stopping.isDead || stopping.state == .poweredOff }
            #expect(
                stopping.state == .poweredOff && stopping.bootWatch.deathReason == nil,
                "a halt's exit is Stopped, not a crash"
            )
        }
    }

    @Test func aDeathKeepsAnAbortedBootsReasonAndHappensOnce() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.bootWatch.helperDied("The iPod stopped unexpectedly.")
            #expect(c.state == .dead(exitCode: nil) && c.bootWatch.deathReason == "The iPod stopped unexpectedly.")
            c.bootWatch.helperDied("again")
            #expect(
                c.steps == ["retire", "discard", "forgetBootFacts", "release"],
                "once, and the install queue goes with the helper (a restart or a crash leaves no jobs behind)"
            )
            #expect(c.bootWatch.deathReason == "The iPod stopped unexpectedly.")
        }
    }

    /// State audit A-1: a boot that couldn't be built went `.dead` and stopped there; the helper's death that
    /// followed was skipped as already dead, so the boot's status poll, loops, usbmuxd and serial capture ran on.
    @Test func aBootThatCantBeBuiltEndsLikeAnyOther() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.bootScope[.foreground] = Task { try? await Task.sleep(for: .seconds(60)) }
            let loop = c.bootScope[.foreground]
            c.bootWatch.failBoot(CocoaError(.fileReadCorruptFile))
            #expect(c.state == .dead(exitCode: 1) && c.bootScope.retired && loop?.isCancelled == true)
            #expect(c.steps == ["retire", "discard", "forgetBootFacts", "release"], "\(c.steps)")
            c.bootWatch.helperDied("The emulator stopped.")
            #expect(c.steps.count == 4 && c.state == .dead(exitCode: 1), "ended once")
        }
    }

    /// State audit A-12: a device that crashed or stopped with its display asleep still drew as asleep (the toolbar
    /// offered Wake) and still read as reachable.
    @Test func anEndedBootForgetsTheGuest() async throws {
        try await withScratchDirectory { directory in
            for end in [BootEnd.helperGone, .guestPoweredOff, .unbuildable] {
                let c = session(directory)
                c.state = .running
                c.isSleeping = true
                c.deviceReachable = true
                c.bootWatch.endBoot(end)
                #expect(!c.isSleeping && c.deviceReachable == nil, "\(end)")
                #expect(c.steps.contains("release") == (end != .guestPoweredOff), "the helper stays powered off")
            }
        }
    }

    @Test func missingBootFilesAreNamedBeforeBoot() async throws {
        try await withScratchDirectory { directory in
            let missing = CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "/state/Devices/x/base/iBoot.bin"])
            let reason = BootWatch.bootFilesReason(missing, profile: .n72)
            #expect(
                reason
                    == "This iPod’s system files are incomplete: iBoot.bin is missing. Delete it and prepare it again."
            )
            #expect(
                BootWatch.bootFilesReason(CocoaError(.fileReadCorruptFile), profile: .k48).hasPrefix(
                    "Couldn’t prepare the iPad’s storage: "
                )
            )
            let failing = session(directory)
            #expect(
                observes({ _ = failing.bootWatch.deathReason }) { failing.bootWatch.failBoot(missing) },
                "the dead overlay's reason follows"
            )
            #expect(
                failing.state == .dead(exitCode: 1) && failing.bootWatch.deathReason == reason
                    && failing.notices.message == reason
            )
        }
    }
}
