import DeviceRuntime
import Foundation
import Testing

/// DeviceRuntime's power-off gesture and its shutdown driver: event deadlines, the wire round trip, the cable gate after
/// backlight and completion, refusal, timeout, interruption and cancellation. No guest.
struct VirtualInputTests {
    @Test func powerOffGestureDeadlines() throws {
        let n72 = try HostInputAutomation.powerOffGesture(firstGeneration: false)
        let n45 = try HostInputAutomation.powerOffGesture(firstGeneration: true)
        #expect(n72.count == 29 && VirtualInputEvent.valid(n72) && VirtualInputEvent.valid(n45))
        #expect(n72[0].atMilliseconds == 0 && n72[1].atMilliseconds == 150)
        #expect(n72[2].atMilliseconds == 2650 && n72[3].atMilliseconds == 6150)
        #expect(n45[3].atMilliseconds == 8650 && n72.last!.atMilliseconds == 9570)
        #expect(n72.last!.phase == 2 && n72.last!.x == 295.0 / 320)
        var bad = n72
        bad[1].atMilliseconds = -1
        #expect(!VirtualInputEvent.valid(bad))
        bad = n72
        bad[8].x = .nan
        #expect(!VirtualInputEvent.valid(bad))
        bad = n72
        bad.removeLast()
        #expect(!VirtualInputEvent.valid(bad))
        #expect(throws: (any Error).self) {
            try HostInputAutomation.powerOffGesture(firstGeneration: false, knobY: 480)
        }
    }

    @Test func typedEventsSurviveTheWire() throws {
        let n72 = try HostInputAutomation.powerOffGesture(firstGeneration: false)
        let encoded = try JSONEncoder().encode(AppMessage.request(id: 1, .inputSequence(id: 99, events: n72)))
        guard
            case .request(_, .inputSequence(let id, let events)) = try JSONDecoder().decode(
                AppMessage.self,
                from: encoded
            )
        else {
            Issue.record("not an input sequence")
            return
        }
        #expect(id == 99 && events == n72)
    }

    @Test func shutdownUnplugsOnlyAfterBacklightAndCompletion() async throws {
        let n72 = try HostInputAutomation.powerOffGesture(firstGeneration: false)
        var replies = 0
        var seen: [LinkRequest] = []
        var confirmed = false
        var sleeping = false
        try await HostInputAutomation.performShutdown(
            id: 99,
            events: n72,
            timeout: 3,
            request: { r in
                seen.append(r)
                switch r {
                case .inputSequence: return .ok(true)
                case .inputSequenceStatus:
                    replies += 1
                    if replies == 1 {
                        sleeping = true
                        return .inputSequenceStatus(1)
                    }
                    return .inputSequenceStatus(2)
                case .usbConnection(false):
                    confirmed = true
                    return .ok(true)
                default:
                    Issue.record("unexpected \(r)")
                    return .ok(false)
                }
            },
            power: { (confirmed, sleeping, false) }
        )
        #expect(replies == 2 && seen.last == .usbConnection(false))
    }

    @Test func refusalIsReported() async throws {
        let n72 = try HostInputAutomation.powerOffGesture(firstGeneration: false)
        var refused: [LinkRequest] = []
        await #expect(throws: HostInputAutomation.Failure.refused) {
            try await HostInputAutomation.performShutdown(
                id: 100,
                events: n72,
                timeout: 1,
                request: { r in
                    refused.append(r)
                    return .failure("old dylib")
                },
                power: { (false, false, false) }
            )
        }
        #expect(refused.count == 1)
    }

    @Test func timeoutCancelsTheSequenceAndKeepsTheCable() async throws {
        let n72 = try HostInputAutomation.powerOffGesture(firstGeneration: false)
        var timed: [LinkRequest] = []
        await #expect(throws: HostInputAutomation.Failure.timedOut) {
            try await HostInputAutomation.performShutdown(
                id: 101,
                events: n72,
                timeout: 0.02,
                request: { r in
                    timed.append(r)
                    if case .inputSequenceStatus = r { return .inputSequenceStatus(1) }
                    return .ok(true)
                },
                power: { (false, true, false) }
            )
        }
        #expect(timed.last == .inputSequenceCancel(id: 101))
        #expect(!timed.contains(.usbConnection(false)))
    }

    @Test func interruptionCancelsTheSequence() async throws {
        let n72 = try HostInputAutomation.powerOffGesture(firstGeneration: false)
        var interrupted: [LinkRequest] = []
        await #expect(throws: HostInputAutomation.Failure.interrupted) {
            try await HostInputAutomation.performShutdown(
                id: 102,
                events: n72,
                timeout: 1,
                request: { r in
                    interrupted.append(r)
                    if case .inputSequenceStatus = r { return .inputSequenceStatus(3) }
                    return .ok(true)
                },
                power: { (false, false, false) }
            )
        }
        #expect(interrupted.last == .inputSequenceCancel(id: 102))
    }

    @Test func taskCancellationCancelsTheSequence() async throws {
        let n72 = try HostInputAutomation.powerOffGesture(firstGeneration: false)
        var cancelled: [LinkRequest] = []
        let task = Task { @MainActor in
            try await HostInputAutomation.performShutdown(
                id: 103,
                events: n72,
                timeout: 1,
                request: { r in
                    cancelled.append(r)
                    if case .inputSequenceStatus = r { return .inputSequenceStatus(1) }
                    return .ok(true)
                },
                power: { (false, false, false) }
            )
        }
        while cancelled.isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancelled.last == .inputSequenceCancel(id: 103))
    }
}
