import Foundation

/// Wait for `work`, but not forever — and let it finish on its own if we stop
/// waiting. The gate's own `acquire()` has no deadline: `withDeadline` bounds
/// the WORK, not the queueing in front of it, so a device operation that is
/// allowed 120 seconds (an uninstall) could hold up everything behind it,
/// including the quit path's health probe — which then blew the quit budget and
/// terminated the app before the guest was ever asked to power down.
public func withSoftDeadline<T: Sendable>(
    _ seconds: Double,
    _ work: @escaping @Sendable () async -> T
) async -> T? {
    guard !Task.isCancelled else { return nil }
    let once = ResumeOnce<T?>()
    let worker = Task { once.resume(.success(await work())) }
    let watchdog = Task.detached {
        do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
        if once.resume(.success(nil)) { worker.cancel() }
    }
    defer { watchdog.cancel() }
    return try? await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { once.attach($0) }
    } onCancel: {
        if once.resume(.success(nil)) { worker.cancel() }
    }
}

/// First result wins; the rest are dropped. Handles the result landing before
/// the continuation attaches (a fast op) and vice versa (the normal case).
nonisolated public final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    public init() {}
    private let lock = NSLock()
    private var pending: Result<T, Error>?
    private var cont: CheckedContinuation<T, Error>?
    private var done = false

    public func attach(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending, !done {
            done = true
            lock.unlock()
            c.resume(with: pending)
            return
        }
        cont = c
        lock.unlock()
    }

    /// True if this result is the one the caller gets — i.e. this side won.
    @discardableResult
    public func resume(_ result: Result<T, Error>, onWin: () -> Void = {}) -> Bool {
        lock.lock()
        guard !done, pending == nil else {
            lock.unlock()
            return false
        }
        // Account for abandoned work before the worker can lose this race and
        // decrement it, and before the caller is allowed to start another op.
        onWin()
        if let c = cont {
            done = true
            cont = nil
            lock.unlock()
            c.resume(with: result)
            return true
        }
        pending = result
        lock.unlock()
        return true
    }
}
