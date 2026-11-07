import Foundation

/// Serializes ready installs, media imports and confirmed removals.
/// Network downloads never reserve the device.
@MainActor public final class InstallationQueue {
    public init() {}
    public private(set) var isBusy = false { didSet { activity.held = isBusy } }
    private var activity = UserActivity("Installing on a device")
    public private(set) var isPaused = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    public func acquire() async throws {
        try Task.checkCancellation()
        if !isBusy && !isPaused {
            isBusy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waiters.firstIndex(where: { $0.0 == id }) else { return }
                self.waiters.remove(at: index).1.resume(throwing: CancellationError())
            }
        }
    }

    public func pause() { isPaused = true }

    public func resume() {
        isPaused = false
        if !isBusy, !waiters.isEmpty {
            isBusy = true
            waiters.removeFirst().1.resume()
        }
    }

    public func release() {
        if waiters.isEmpty || isPaused { isBusy = false } else { waiters.removeFirst().1.resume() }
    }
}
