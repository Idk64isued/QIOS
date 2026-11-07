// Targeted updates from @Observable models (the session's controller and its components) for AppKit observers.
//
// Observation's withObservationTracking fires once, on the first change to anything the tracked closure read; this
// re-arms it after every change, so an observer updates when what it shows changes and not on every other tick.
// AppKit only tracks Observation by itself from macOS 15 (opt-in, NSObservationTrackingEnabled) or 26 (default),
// inside view and view-controller update methods; the app targets 14.4, so observers arm one of these instead.

import Foundation
import Observation

/// Reads `read` under observation tracking; when anything it read changes, calls `onChange` (on the main actor,
/// after the change, coalescing changes made in the same turn) and reads again, re-arming for the next change.
/// Ends when cancelled or released.
public final class ObservationLoop {
    private let read: () -> Void
    private let onChange: () -> Void
    private var generation = 0

    /// `read` runs now and after every change. With no `onChange`, `read` is the update itself (it applies what it
    /// reads); otherwise `read` names the values and `onChange` acts on them.
    public init(read: @escaping () -> Void, onChange: @escaping () -> Void = {}) {
        self.read = read
        self.onChange = onChange
        arm()
    }

    /// Read again now and track what this read touches instead: the observer's reads changed shape (another
    /// session, more rows). The previous tracking is dropped.
    public func rearm() {
        generation += 1
        arm()
    }

    public func cancel() { generation += 1 }

    private func arm() {
        let armed = generation
        withObservationTracking(read) { [weak self] in
            // Fired from the mutation's willSet: hop so `onChange` and the next read see the new value.
            Task { @MainActor [weak self] in
                guard let self, armed == generation else { return }
                generation += 1
                onChange()
                arm()
            }
        }
    }
}
