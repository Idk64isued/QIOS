import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// Stop is a hard halt, never a guest shutdown; Shut Down asks the guest and waits for it to power off, gives up
/// after its budget, and Force Stop can take over while it waits.
struct ShutdownLadderTests {
    func session(_ directory: URL, state: VMState = .booting) -> FakeSession {
        let s = FakeSession(directory: directory)
        s.state = state
        s.ladder.budgets.halt = 0.3
        s.ladder.budgets.serviceTeardown = 0.3
        s.ladder.budgets.shutdown = 0.5
        return s
    }
    func halt(_ s: FakeSession) async -> Bool { await s.ladder.halt().value }

    @Test func stopMidBootHaltsAtOnceAndJoinsRequests() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.bootScope[.readiness] = Task { try? await Task.sleep(for: .seconds(60)) }
            let readiness = c.bootScope[.readiness]
            #expect(c.ladder.canStop)
            let started = Date()
            let first = c.ladder.halt()
            let second = c.ladder.halt()
            #expect(c.shuttingDown && c.halting && !c.ladder.canStop && readiness?.isCancelled == true)
            #expect(c.steps == ["retire"])
            let results = [await first.value, await second.value]
            #expect(results == [true, true] && c.fakeHelper!.terms == 1 && c.fakeHelper!.kills == 0 && !c.shuttingDown)
            #expect(Date().timeIntervalSince(started) < 1, "a halt never waits on the guest")
            #expect(c.link.commands.isEmpty, "no guest shutdown asked")
        }
    }

    @Test func aHungHelperIsKilledAndAGoneOneIsAlreadyStopped() async throws {
        try await withScratchDirectory { directory in
            let hung = session(directory)
            hung.fakeHelper!.hung = true
            #expect(await halt(hung) && hung.fakeHelper!.kills == 1)

            let gone = session(directory)
            gone.fakeHelper!.isDead = true
            let goneHalt = gone.ladder.halt()
            #expect(gone.fakeHelper!.terms == 0 && !gone.shuttingDown)
            #expect(await goneHalt.value)
            // Powered off by its guest, the helper is quit: nothing is left to flush.
            let off = session(directory, state: .poweredOff)
            off.link.onCommand = { if case .machine(.quit) = $0 { off.fakeHelper!.exit() } }
            #expect(await off.ladder.halt().value && off.fakeHelper!.terms == 0 && off.fakeHelper!.kills == 0)
            #expect(off.link.commands == [.machine(.quit)])
        }
    }

    /// State audit A-10: a halt the helper outlived used to leave `halting` set for good, so the boot watch could
    /// never abort the device again and its later crash read as Stopped.
    @Test func aHaltTheHelperOutlivedEndsItsHalting() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.ladder.budgets.kill = 0.1
            c.fakeHelper!.hung = true
            c.fakeHelper!.unkillable = true
            #expect(await !halt(c) && c.fakeHelper!.kills == 1)
            #expect(!c.halting && !c.shuttingDown && c.ladder.canStop, "the helper is still there to stop")
            c.bootWatch.helperDied("The iPod stopped unexpectedly.")
            #expect(c.state == .dead(exitCode: nil), "its later death is a crash, not Stopped")
        }
    }

    @Test func meddledFilesQuitWithoutAFlush() async throws {
        try await withScratchDirectory { directory in
            let c = session(directory)
            c.filesMeddled = true
            c.link.onCommand = { if case .machine(.quit) = $0 { c.fakeHelper!.exit() } }
            #expect(await halt(c))
            #expect(c.link.commands == [.machine(.quit)] && c.fakeHelper!.terms == 0 && c.fakeHelper!.kills == 0)
        }
    }

    @Test func aStuckServicesWorkerCantHoldStop() async throws {
        try await withScratchDirectory { directory in
            let stuck = session(directory)
            stuck.hangWorker = true
            let started = Date()
            #expect(await halt(stuck))
            #expect(stuck.fakeHelper!.terms == 1 && !stuck.shuttingDown && Date().timeIntervalSince(started) < 2)
            let stuckHung = session(directory)
            stuckHung.hangWorker = true
            stuckHung.fakeHelper!.hung = true
            #expect(await halt(stuckHung) && stuckHung.fakeHelper!.kills == 1, "the kill doesn't wait on the worker")
        }
    }

    @Test func shutDownAsksTheGuestAndWaitsForItToPowerOff() async throws {
        try await withScratchDirectory { directory in
            let clean = session(directory, state: .running)
            #expect(clean.ladder.canShutDown)
            var shutdown: Task<ShutdownOutcome, Never>?
            #expect(
                observes({ _ = clean.ladder.shuttingDown }) { shutdown = clean.ladder.shutDown() },
                "the window's Shutting down… follows"
            )
            var result: ShutdownOutcome?
            Task { result = await shutdown?.value }
            #expect(clean.link.commands == [.machine(.shutdown)] && clean.steps == ["willStop"])
            #expect(
                clean.shuttingDown && clean.ladder.isShuttingDownCleanly && !clean.ladder.canShutDown
                    && clean.ladder.canForceStop
            )
            try await Task.sleep(for: .milliseconds(100))
            #expect(result == nil, "finished before the guest powered off")
            clean.state = .poweredOff
            await eventually("shut down finished") { result != nil }
            #expect(result == .poweredOff && !clean.shuttingDown && clean.fakeHelper!.terms == 0, "the helper stays")
        }
    }

    @Test func aGuestThatNeverPowersOffIsLeftRunning() async throws {
        try await withScratchDirectory { directory in
            let stubborn = session(directory, state: .running)
            let gaveUp = await stubborn.ladder.shutDown().value
            #expect(
                gaveUp == .timedOut && !stubborn.shuttingDown && stubborn.state == .running
                    && stubborn.ladder.canShutDown
            )
            // Storage failed, or the helper gone: no Shut Down.
            for change: (FakeSession) -> Void in [
                { $0.storageFailed = true }, { $0.fakeHelper!.isDead = true },
                { $0.isErasing = true }
            ] {
                let s = session(directory, state: .running)
                change(s)
                let refused = s.ladder.shutDown()
                #expect(s.link.commands.isEmpty)
                #expect(await refused.value == .timedOut)
            }
        }
    }

    /// Sam's 1321 log: a Shut Down chosen mid-boot asked a guest that couldn't answer yet; the boot went on under
    /// "Stopping…" (its toast still "Connecting over USB") until the shutdown budget force stopped it ~50 s later.
    @Test func shutDownBeforeReadyHaltsAtOnceAndEndsTheBoot() async throws {
        try await withScratchDirectory { directory in
            for state in [VMState.booting, .running] {
                let c = session(directory, state: state)
                c.ladder.budgets.shutdown = 30
                c.usbAnswers = false
                c.readiness.start()
                c.bootWatch.start()
                let readiness = c.readiness.current
                let watchdog = c.bootWatch.current
                #expect(c.preparingDevice && c.ladder.canShutDown && c.ladder.shutDownHalts)
                let started = Date()
                let shutdown = c.ladder.shutDown()
                #expect(c.halting && c.shuttingDown && !c.ladder.isShuttingDownCleanly, "the window says Stopping…")
                #expect(readiness?.isCancelled == true && watchdog?.isCancelled == true, "the boot's watches end")
                #expect(c.link.commands.isEmpty, "no guest shutdown asked")
                #expect(await shutdown.value == .forced)
                #expect(Date().timeIntervalSince(started) < 2, "a halt, not the shutdown budget")
                #expect(c.fakeHelper!.terms == 1 && c.steps.prefix(2) == ["willStop", "retire"])
                await eventually("the startup banner went") { !c.preparingDevice }
                // USB answering now moves no boot stage: the boot is over.
                let stage = c.bootStage
                c.usbAnswers = true
                try await Task.sleep(for: .milliseconds(400))
                #expect(c.bootStage == stage && c.springBoardChecks == 0)
            }
        }
    }

    @Test func forceStopTakesOverAShutDown() async throws {
        try await withScratchDirectory { directory in
            let forced = session(directory, state: .running)
            let shutDown = forced.ladder.shutDown()
            #expect(!forced.ladder.canStop && forced.ladder.canForceStop)
            let halted = await forced.ladder.forceStop().value
            // State audit A-15: this used to read as powered off, so Shut Down First opened the file system of a
            // device that had been cut off mid-write.
            #expect(await shutDown.value == .forced, "the shut down ends, stopped, not powered off")
            #expect(halted && forced.fakeHelper!.terms == 1 && !forced.shuttingDown)
            #expect(forced.steps.filter { $0 == "willStop" }.count == 2)

            let idle = session(directory, state: .notStarted)
            let refused = idle.ladder.forceStop()
            #expect(idle.fakeHelper!.terms == 0, "nothing started, nothing to stop")
            #expect(await !refused.value)
        }
    }

    @Test func budgetsAddUpToTheQuitBackstop() {
        let budgets = ShutdownLadder.Budgets()
        #expect(budgets.halt == 10 && budgets.kill == 5 && budgets.serviceTeardown == 2)
        #expect(budgets.stop == 17)
    }
}
