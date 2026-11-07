import Foundation
import Testing

@testable import LightTouchCore

/// Polls `condition` every few milliseconds; fails the test (and stops waiting) after `seconds`.
func until(
    _ what: String = "the expected state",
    seconds: Double = 5,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// The device's ready queue (InstallationQueue): ready work runs one at a time in the order it became ready,
/// a cancelled waiter drains, and a paused queue holds its waiters until resumed.
struct InstallationQueueTests {
    final class Run {
        let queue = InstallationQueue()
        var order: [String] = [], ready: [String] = []
        var concurrent = 0, overlapped = false

        /// A job that becomes ready when `download` yields and holds the device until `finish` yields.
        func job(_ name: String) -> (
            task: Task<Void, Error>, download: AsyncStream<Void>.Continuation, finish: AsyncStream<Void>.Continuation
        ) {
            let download = AsyncStream<Void>.makeStream()
            let finish = AsyncStream<Void>.makeStream()
            let task = Task { @MainActor in
                for await _ in download.stream { break }
                try Task.checkCancellation()
                ready.append(name)
                try await queue.acquire()
                defer { queue.release() }
                try Task.checkCancellation()
                concurrent += 1
                if concurrent != 1 { overlapped = true }
                defer { concurrent -= 1 }
                order.append(name)
                for await _ in finish.stream { break }
            }
            return (task, download.continuation, finish.continuation)
        }
    }

    @Test func readyOrderNotSelectionOrder() async throws {
        let run = Run()
        let large = run.job("large")
        let small = run.job("small")
        let second = run.job("second")
        small.download.yield()
        try await until { run.order == ["small"] }
        second.download.yield()
        try await until { run.ready.contains("second") }
        small.finish.yield()
        try await until { run.order == ["small", "second"] }
        large.download.yield()
        large.finish.yield()
        second.finish.yield()
        try await large.task.value
        try await small.task.value
        try await second.task.value
        #expect(run.order == ["small", "second", "large"] && !run.queue.isBusy && !run.overlapped)
    }

    @Test func cancelledWaiterDrains() async throws {
        let run = Run()
        try await run.queue.acquire()
        let cancelled = run.job("cancelled")
        cancelled.download.yield()
        try await until { run.ready.contains("cancelled") }
        cancelled.task.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.task.value }
        run.queue.release()
        let next = run.job("next")
        next.download.yield()
        next.finish.yield()
        try await next.task.value
        #expect(run.order == ["next"] && !run.queue.isBusy)
    }

    @Test func pausedQueueHoldsWaiters() async throws {
        let run = Run()
        try await run.queue.acquire()
        run.queue.pause()
        let paused = run.job("paused")
        paused.download.yield()
        try await until { run.ready.contains("paused") }
        run.queue.release()
        #expect(!run.queue.isBusy && run.queue.isPaused && !run.order.contains("paused"))
        let cancelledWhilePaused = run.job("cancelled paused")
        cancelledWhilePaused.download.yield()
        try await until { run.ready.contains("cancelled paused") }
        cancelledWhilePaused.task.cancel()
        await #expect(throws: CancellationError.self) { try await cancelledWhilePaused.task.value }
        run.queue.resume()
        paused.finish.yield()
        try await paused.task.value
        #expect(run.order == ["paused"] && !run.queue.isBusy && !run.queue.isPaused)
    }
}
