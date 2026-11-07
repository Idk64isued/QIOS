import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// The app's side of host power: the screen's visibility reaches the helper once per change and paces the status
/// poll; the Mac's sleep pauses a running device and its wake resumes it and resyncs the clock; installs hold off
/// idle sleep.
struct HostPowerTests {
    @Test func visibilityReachesTheHelperOncePerChangeAndPacesThePoll() async throws {
        try await withScratchDirectory { directory in
            let c = FakeSession(directory: directory)
            var repolls = 0
            let power = HostPower(host: c) { repolls += 1 }
            power.screenVisible = true
            power.screenVisible = true
            #expect(c.link.commands == [.screenVisible(true)] && repolls == 1)
            power.screenVisible = false
            #expect(c.link.commands == [.screenVisible(true), .screenVisible(false)] && repolls == 2)
            #expect(HostPower.pollInterval(screenVisible: false) == 0.25, "hidden: 4 Hz")
            #expect(abs(HostPower.pollInterval(screenVisible: true) - 1.0 / 30) < 1e-12, "shown: 30 Hz")
        }
    }

    @Test func macSleepPausesAndWakeResumesWithAClockSync() async throws {
        try await withScratchDirectory { directory in
            let c = FakeSession(directory: directory)
            c.state = .running
            let power = HostPower(host: c) {}
            power.hostWillSleep()
            #expect(c.state == .paused && c.link.commands == [.machine(.pause)])
            power.hostDidWake()
            #expect(
                c.state == .running && c.link.commands == [.machine(.pause), .machine(.resume)]
                    && c.steps == ["resyncTimeZone"]
            )
            power.hostDidWake()
            #expect(c.steps == ["resyncTimeZone"], "a second wake does nothing")

            let paused = FakeSession(directory: directory)
            paused.state = .paused
            let pausedPower = HostPower(host: paused) {}
            pausedPower.hostWillSleep()
            pausedPower.hostDidWake()
            #expect(
                paused.state == .paused && paused.link.commands.isEmpty && paused.steps.isEmpty,
                "the user's pause stays"
            )
            let off = FakeSession(directory: directory)
            off.state = .poweredOff
            let offPower = HostPower(host: off) {}
            offPower.hostWillSleep()
            offPower.hostDidWake()
            #expect(off.link.commands.isEmpty && off.steps.isEmpty, "a device not running is left alone")
            let stopping = FakeSession(directory: directory)
            stopping.state = .running
            stopping.ladder.halt()
            let stoppingPower = HostPower(host: stopping) {}
            stoppingPower.hostWillSleep()
            #expect(
                stopping.state == .running && !stopping.link.commands.contains(.machine(.pause)),
                "a stopping device isn't paused"
            )
        }
    }

    @Test func pauseAndResumeMoveOnlyTheirOwnStates() async throws {
        try await withScratchDirectory { directory in
            let c = FakeSession(directory: directory)
            c.state = .booting
            c.pause()
            #expect(
                c.state == .booting && c.link.commands == [.machine(.pause)],
                "a booting VM pauses but stays booting"
            )
            c.state = .paused
            c.storageFailed = true
            c.resume()
            #expect(c.state == .paused && c.link.commands.count == 1, "never resumes over failed storage")
            c.storageFailed = false
            c.resume()
            #expect(c.state == .running && c.link.commands.last == .machine(.resume))
        }
    }

    @Test func installsHoldOffIdleSleep() async throws {
        func holdsIdleSleep() throws -> Bool {
            let process = Process()
            let out = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g", "assertions"]
            process.standardOutput = out
            try process.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return text.split(separator: "\n").contains {
                $0.contains("pid \(getpid())(") && $0.contains("PreventUserIdleSystemSleep")
            }
        }
        let queue = InstallationQueue()
        #expect(try !holdsIdleSleep(), "no assertion before any work")
        try await queue.acquire()
        #expect(try holdsIdleSleep(), "an install holds off idle sleep")
        queue.release()
        #expect(try !holdsIdleSleep(), "released once the queue is idle")
    }
}
