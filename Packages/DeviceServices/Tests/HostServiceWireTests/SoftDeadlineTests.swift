import Foundation
import Testing

@testable import HostServiceWire

/// withSoftDeadline and ResumeOnce, which check-deadlines' gate and cancellation races are measured with: the work's
/// result when it is in time, nil (and the work cancelled) when it isn't or the caller stops waiting, and the first
/// result wins whichever side lands first.
struct SoftDeadlineTests {
    @Test func inTimeWorkReturnsItsValue() async {
        #expect(await withSoftDeadline(5) { 7 } == 7)
    }

    @Test func lateWorkIsNilAndCancelled() async throws {
        let cancelled = ResumeOnce<Bool>()
        let start = ContinuousClock.now
        let result: Int? = await withSoftDeadline(0.05) {
            do {
                try await Task.sleep(for: .seconds(30))
                cancelled.resume(.success(false))
            } catch { cancelled.resume(.success(true)) }
            return 1
        }
        #expect(result == nil && ContinuousClock.now - start < .seconds(5))
        #expect(try await withCheckedThrowingContinuation { cancelled.attach($0) }, "the late work was not cancelled")
    }

    @Test func callerCancellationStopsTheWait() async {
        let waiter = Task {
            await withSoftDeadline(30) {
                try? await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        #expect(await waiter.value == nil)
    }

    @Test func firstResultWinsBeforeOrAfterAttach() async throws {
        let early = ResumeOnce<Int>()
        #expect(early.resume(.success(1)) && !early.resume(.success(2)))
        #expect(try await withCheckedThrowingContinuation { early.attach($0) } == 1)
        let late = ResumeOnce<Int>()
        Task {
            try? await Task.sleep(for: .milliseconds(10))
            late.resume(.success(3))
            late.resume(.success(4))
        }
        #expect(try await withCheckedThrowingContinuation { late.attach($0) } == 3)
    }

    /// A timed-out request's accounting (the winner's onWin) finishes before the losing worker returns.
    @Test func theWinnersAccountingFinishesBeforeTheLoserReturns() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func add(_ d: Int) { lock.withLock { n += d } }
            var value: Int { lock.withLock { n } }
        }
        let once = ResumeOnce<Int>()
        let counter = Counter()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let winner = Task.detached {
            once.resume(
                .success(1),
                onWin: {
                    entered.signal()
                    release.wait()
                    counter.add(1)
                }
            )
        }
        await Task.detached { blockingWait(entered) }.value
        let loser = Task.detached { if !once.resume(.success(2)) { counter.add(-1) } }
        release.signal()
        _ = await winner.value
        await loser.value
        #expect(counter.value == 0)
        #expect(try await withCheckedThrowingContinuation { once.attach($0) } == 1)
    }
}

/// DispatchSemaphore.wait off the async context (the checks above block worker threads on purpose).
nonisolated func blockingWait(_ semaphore: DispatchSemaphore) { semaphore.wait() }
