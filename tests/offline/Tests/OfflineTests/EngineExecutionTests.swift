import Dispatch
import Foundation
import HostServiceWire
import Testing

@testable import Engine

nonisolated final class Blocked: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func run() -> Int {
        entered.signal()
        release.wait()
        return 42
    }
    func waitForEntry() { entered.wait() }
}

extension SharedState {
    /// The services engine's execution (LightTouchServices/Engine/DeviceExecution.swift) with no device and no timing
    /// assumptions about the main actor: a deadline's timeout and cancellation account for the abandoned worker exactly
    /// once, a cancelled queued waiter leaves at once, a timed-out one never runs, the gate is reused, and a late C
    /// connection after a timeout keeps its device's endpoint (another device waits for it, the same device recovers).
    @Suite struct EngineExecutionTests {
        static func drain() async {
            let deadline = ContinuousClock.now + .seconds(2)
            while AbandonedWork.count > 0, ContinuousClock.now < deadline { await Task.yield() }
            #expect(AbandonedWork.count == 0, "worker did not return abandonment slot")
        }

        @Test func deadlinesGateAndEndpoints() async throws {
            let timed = Blocked()
            let task = Task { try await withDeadline(0.03, "fixture") { timed.run() } }
            await Task.detached { timed.waitForEntry() }.value
            do {
                _ = try await task.value
                Issue.record("no timeout")
            } catch DeviceError.timedOut {} catch { throw error }
            #expect(AbandonedWork.count == 1)
            timed.release.signal()
            await Self.drain()
            // Cancellation completes before an uncooperative worker, without freeing
            // that worker's slot early. Its eventual result is discarded exactly once.
            let blocked = Blocked()
            let cancelled = Task { try await withDeadline(60, "cancelled") { blocked.run() } }
            await Task.detached { blocked.waitForEntry() }.value
            cancelled.cancel()
            let cancellationFinished = await withSoftDeadline(1) {
                do {
                    _ = try await cancelled.value
                    return false
                } catch is CancellationError { return true } catch { return false }
            }
            #expect(cancellationFinished == true && AbandonedWork.count == 1)
            blocked.release.signal()
            await Self.drain()
            for _ in 0..<40 {
                let value = try await withDeadline(1, "fast") { 7 }
                #expect(value == 7)
            }
            #expect(AbandonedWork.count == 0)
            let gate = DeviceGate()
            let held = ResumeOnce<Void>()
            let entered = ResumeOnce<Void>()
            let owner = Task {
                try await gate.serialized {
                    entered.resume(.success(()))
                    try await withCheckedThrowingContinuation { held.attach($0) }
                }
            }
            try await withCheckedThrowingContinuation { entered.attach($0) }
            let queued = Task {
                try await gate.serialized { () -> Bool in preconditionFailure("cancelled waiter executed") }
            }
            queued.cancel()
            let queuedCancelled = await withSoftDeadline(1) {
                do {
                    _ = try await queued.value
                    return false
                } catch is CancellationError { return true } catch { return false }
            }
            #expect(queuedCancelled == true, "queue cancellation waited for owner")
            let dropped: Bool?? = await withSoftDeadline(0.03) {
                try? await gate.serialized { () -> Bool in preconditionFailure("timed-out queue waiter executed") }
            }
            #expect(dropped == nil)
            held.resume(.success(()))
            try await owner.value
            let next = try await gate.serialized { 13 }
            #expect(next == 13)
            // A timed-out C operation can connect again after the caller has returned.
            // Keep its endpoint unchanged, including when another device is queued.
            let routed = Blocked()
            let endpointA = "UNIX:/tmp/ltm-deadline-device-a"
            let endpointB = "UNIX:/tmp/ltm-deadline-device-b"
            let late = Task {
                try await DeviceGate.shared.serialized(socket: endpointA) {
                    try await withDeadline(0.03, "late connection") {
                        _ = routed.run()
                        #expect(
                            String(cString: getenv("USBMUXD_SOCKET_ADDRESS")) == endpointA,
                            "late C connection was routed to another device"
                        )
                        return 1
                    }
                }
            }
            await Task.detached { routed.waitForEntry() }.value
            do {
                _ = try await late.value
                Issue.record("missing timeout")
            } catch DeviceError.timedOut {}
            do {
                _ = try await DeviceGate.shared.serialized(socket: endpointB) { 99 }
                Issue.record("switched endpoint with live abandoned work")
            } catch DeviceError.endpointBusy {}
            #expect(String(cString: getenv("USBMUXD_SOCKET_ADDRESS")) == endpointA)
            let same = try await DeviceGate.shared.serialized(socket: endpointA) { 17 }
            #expect(same == 17, "same-device recovery was blocked")
            routed.release.signal()
            await Self.drain()
            let other = try await DeviceGate.shared.serialized(socket: endpointB) { 23 }
            #expect(other == 23 && String(cString: getenv("USBMUXD_SOCKET_ADDRESS")) == endpointB)
        }
    }
}
