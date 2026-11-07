import Foundation
import Testing

@testable import LightTouchCore

/// The boot toast's stage comes from the device's own signals, never a timer: a recorded iPad 4.2.1 serial log
/// (kernel console on) through the app's serial watch, then the guest tools and USB. The readiness rule for a boot
/// whose USB never answers, and the Home-screen wait's agent answer, are here too; so is the serial watch on its
/// own (each phrase once, across write boundaries, every byte logged).
struct BootStageTests {
    nonisolated final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ s: String) { lock.withLock { all.append(s) } }
        var phrases: [String] { lock.withLock { all } }
    }
    static let recorded = [":: iBoot for", "Loading kernel cache", "iBoot version: ", "launchd[1] has started up"]

    @Test func theRecordedBootsSerialLinesGiveTheStagesInOrder() async throws {
        try await withScratchDirectory { dir in
            var fds: [Int32] = [-1, -1]
            #expect(pipe(&fds) == 0)
            let seen = Seen()
            let reader = try LogPipeReader(
                descriptor: fds[0],
                log: RotatingLog(url: dir.appendingPathComponent("serial.log")),
                watch: .init(phrases: Array(BootStage.serialMarkers.keys)) { seen.add($0) }
            )
            let log = try Data(
                contentsOf: repositoryRoot.appendingPathComponent("tests/fixtures/serial-k48ap-8C148.log")
            )
            // 64 bytes at a time: markers split across writes.
            for start in stride(from: 0, to: log.count, by: 64) {
                let chunk = log[start..<min(start + 64, log.count)]
                _ = chunk.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress, chunk.count) }
                try await Task.sleep(for: .milliseconds(2))
            }
            try await Task.sleep(for: .milliseconds(100))
            reader.flush()
            Darwin.close(fds[1])
            reader.finish()
            // Each once; one read can carry several, so compare as a set (stages only move forward).
            #expect(seen.phrases.count == 4 && Set(seen.phrases) == Set(Self.recorded), "\(seen.phrases)")
            #expect(seen.phrases.map(BootStage.Event.serial).reduce(BootStage.poweringOn) { $0.after($1) } == .system)

            let text = String(decoding: log, as: UTF8.self)
            #expect(
                Self.recorded
                    == Self.recorded.sorted { text.range(of: $0)!.lowerBound < text.range(of: $1)!.lowerBound }
            )
        }
    }

    @Test func theToastSaysEachStageOnceOnlyMovingForward() {
        let events = Self.recorded.map(BootStage.Event.serial) + [.guestTools, .usbAttached]
        var stage = BootStage.poweringOn
        var said = [stage.text]
        for event in events {
            let next = stage.after(event)
            if next != stage { said.append(next.text) }
            stage = next
        }
        #expect(
            said == [
                "Powering on", "Loading iOS", "Starting the system", "Connecting over USB",
                "Waiting for the Home screen"
            ]
        )
        #expect(stage == .usb)
        // Only forward: a late marker (a reset reprinting iBoot, the loader reporting after USB) changes nothing.
        #expect(BootStage.usb.after(.serial(":: iBoot for")) == .usb && BootStage.usb.after(.guestTools) == .usb)
        #expect(BootStage.kernel.after(.serial("no such phrase")) == .kernel)
        // Without the kernel console (the default), iBoot's lines, then the guest tools, then USB.
        #expect(BootStage.poweringOn.after(.serial("Loading kernel cache")).after(.guestTools) == .system)
        // The iPod touch (1st generation): iBoot-204 prints no banner; the kernel's line is the first sign.
        #expect(BootStage.poweringOn.after(.serial("Darwin Kernel Version")) == .kernel)
    }

    @Test func theDeadlineKeepsIOSOnScreenAndStopsNoPicture() {
        #expect(
            ReadinessDeadline.verdict(painted: true, stage: .system) == .keepRunning,
            "slide to set up, no USB: keep it"
        )
        #expect(ReadinessDeadline.verdict(painted: true, stage: .usb) == .keepRunning)
        #expect(
            ReadinessDeadline.verdict(painted: false, stage: .system) == .stop,
            "iOS runs but never shows a picture"
        )
        #expect(ReadinessDeadline.verdict(painted: false, stage: .poweringOn) == .stop)
        #expect(
            ReadinessDeadline.verdict(painted: true, stage: .loading) == .stop
                && ReadinessDeadline.verdict(painted: true, stage: .kernel) == .stop,
            "iBoot lights the display too: its logo alone is not iOS"
        )
        let recordedStage = Self.recorded.map(BootStage.Event.serial).reduce(BootStage.poweringOn) { $0.after($1) }
        #expect(
            ReadinessDeadline.verdict(painted: true, stage: recordedStage) == .keepRunning,
            "the recorded boot, had USB never come: kept"
        )
        #expect(
            ReadinessDeadline.notice(shortName: "iPad") == "Apps and files will be available when the iPad connects."
        )
    }

    @Test func springBoardIsUpByTheAgentsFrontmost() {
        #expect(
            SpringBoardAnswer.up(frontmost: "com.apple.springboard")
                && SpringBoardAnswer.up(frontmost: "com.apple.purplebuddy"),
            "slide to set up / Setup Assistant: SpringBoard is up"
        )
        #expect(!SpringBoardAnswer.up(frontmost: nil) && !SpringBoardAnswer.up(frontmost: ""), "no answer is not ready")
        #expect(
            !SpringBoardAnswer.up(frontmost: "com.apple.mobilesafari"),
            "an app in front says nothing about readiness"
        )
    }

    nonisolated final class Matches: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func add(_ phrase: String) { lock.withLock { seen.append(phrase) } }
        var all: [String] { lock.withLock { seen } }
    }

    @Test func theSerialWatchReportsEachPhraseOnceAcrossWrites() throws {
        try withTemporaryDirectory { dir in
            var fds: [Int32] = [-1, -1]
            #expect(pipe(&fds) == 0)
            let matches = Matches()
            let reader = try LogPipeReader(
                descriptor: fds[0],
                log: RotatingLog(url: dir.appendingPathComponent("serial.log")),
                watch: .init(phrases: ["Entering recovery mode", "root filesystem mount failed"]) { matches.add($0) }
            )
            // Each write is drained (flush waits on the reader's queue) before the next: every write is its own chunk.
            func write(_ text: String) {
                _ = text.withCString { Darwin.write(fds[1], $0, strlen($0)) }
                reader.flush()
            }
            write("iBoot-636.66\nroot filesystem mou")
            write("nt failed\nEntering reco")
            #expect(matches.all == ["root filesystem mount failed"])
            write("very mode\n")
            write("Entering recovery mode\n")  // once only
            reader.flush()
            #expect(matches.all == ["root filesystem mount failed", "Entering recovery mode"])
            Darwin.close(fds[1])
            reader.finish()
            let logged = try String(contentsOf: dir.appendingPathComponent("serial.log"), encoding: .utf8)
            #expect(logged.contains("iBoot-636.66\nroot filesystem mount failed\n"))
        }
    }
}
