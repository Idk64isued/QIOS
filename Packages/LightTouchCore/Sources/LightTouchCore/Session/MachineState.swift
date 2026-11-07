// The VM's lifecycle and the machine controls that move it: pause and resume (the user's, and the Mac's sleep),
// and the screen's visibility, which paces the status poll.

import DeviceRuntime
import Foundation
import HostRuntime

/// The VM's lifecycle. Everything the UI enables or disables keys off this; `.dead` is the one that used to be
/// invisible — QEMU would exit and the app kept a frozen frame with every control live.
public enum VMState: Equatable {
    case notStarted, booting, running, paused, poweredOff
    case dead(exitCode: Int32?)

    public var isDead: Bool { if case .dead = self { true } else { false } }

    /// A new frame ends the boot's `booting` (the signal behind booting → running), except while a power-on still
    /// waits to resume the machine.
    public func runsAfterFrame(poweringOn: Bool) -> Bool { self == .booting && !poweringOn }

    /// Whether the machine may go from `self` to `next`. Dead is final: a restart is a fresh controller.
    ///
    /// Erasing and stopping are not states here but overlays the session holds beside this one (DeviceErase's
    /// `isErasing`, ShutdownLadder.step), because the machine keeps moving under them and they end wherever it went
    /// (state audit A-19). An erase halts the helper, whose exit leaves the device powered off mid-erase, and a
    /// boot's frame can make it running; a failed erase leaves it at that. A Shut Down that times out leaves it
    /// running, the guest's own power-off lands while the ladder still waits, a halt whose kill fails leaves it as
    /// it was, and a powered-off helper is halted on purpose (Start with changed settings, Erase).
    public nonisolated func allows(_ next: VMState) -> Bool {
        switch (self, next) {
        case (.notStarted, .booting), (.notStarted, .dead): true
        case (.booting, .booting), (.booting, .running): true
        case (.running, .paused), (.running, .booting): true
        // A reset's resume, or a reset whose sync the user paused under it.
        case (.paused, .running), (.paused, .booting): true
        case (.poweredOff, .booting), (.poweredOff, .poweredOff): true
        // Any live boot ends powered off (the guest's, or a halt's) or dead.
        case (.booting, .poweredOff), (.running, .poweredOff), (.paused, .poweredOff): true
        case (.booting, .dead), (.running, .dead), (.paused, .dead), (.poweredOff, .dead): true
        default: false
        }
    }

    /// The one way the session's state changes. A transition the table refuses leaves the state as it was: it
    /// asserts in debug builds and is logged in release.
    public nonisolated mutating func transition(to next: VMState) {
        guard allows(next) else {
            logEvent("lifecycle: refused \(self) → \(next)")
            assertionFailure("illegal lifecycle transition \(self) → \(next)")
            return
        }
        self = next
    }
}

/// What pause, resume and the Mac's sleep need of the session.
public protocol MachineHost: AnyObject {
    var state: VMState { get }
    /// VMState.transition(to:) on the session's state.
    func transition(to next: VMState)
    var storageFailed: Bool { get }
    var shuttingDown: Bool { get }
    var helperLink: HelperLink? { get }
    /// Set the guest's clock again through lockdown (lockdown-tz, as at boot), for this boot.
    func resyncTimeZone()
}

extension MachineHost {
    public func pause() {
        helperLink?.send(.machine(.pause))
        if state == .running { transition(to: .paused) }
    }

    public func resume() {
        guard !storageFailed else { return }
        helperLink?.send(.machine(.resume))
        if state == .paused { transition(to: .running) }
    }
}

/// Boot time spent against a deadline: measured on the suspending clock, so the Mac's sleep never counts, and only
/// while `counting` (HostPower.countsBootTime). Closing the lid past the boot budget used to kill the device on wake
/// (state audit A-2).
struct BootBudget {
    private(set) var remaining: Duration
    private var last = SuspendingClock.now
    init(_ budget: Duration) { remaining = budget }

    /// Spends the time since the last tick if `counting`; true once the budget is gone.
    mutating func tick(counting: Bool) -> Bool {
        let now = SuspendingClock.now
        if counting { remaining -= last.duration(to: now) }
        last = now
        return remaining <= .zero
    }
}

/// The Mac's side of power: its sleep pauses the VM, and a hidden screen slows the helper and the status poll.
public final class HostPower {
    private unowned let host: MachineHost
    /// Restarts the status poll at the new pace (when it runs).
    private let repoll: () -> Void
    public init(host: MachineHost, repoll: @escaping () -> Void) {
        self.host = host
        self.repoll = repoll
    }

    /// 30 Hz while the screen is on show, 4 Hz otherwise.
    public static func pollInterval(screenVisible: Bool) -> TimeInterval { screenVisible ? 1.0 / 30 : 0.25 }

    /// The window shows this device's screen (DisplayView: on screen, not occluded, minimized or hidden).
    /// Hidden, the helper publishes a few frames a second and lets the Mac idle-sleep, and the status poll slows.
    public var screenVisible = false {
        didSet {
            guard screenVisible != oldValue else { return }
            host.helperLink?.send(.screenVisible(screenVisible))
            repoll()
        }
    }

    private(set) var pausedForHostSleep = false
    /// From the Mac's will-sleep to its wake.
    public private(set) var hostAsleep = false
    /// Whether boot time counts toward the boot's deadlines now (BootBudget): not while the device is paused (by
    /// the user, or for the Mac's sleep) or the Mac sleeps (state audit A-2).
    public var countsBootTime: Bool { !hostAsleep && host.state != .paused }

    /// The Mac is going to sleep: pause the VM, so the guest's timers don't all come due at once on wake
    /// (QEMU's clock counts the sleep). A device the user paused stays paused through it.
    public func hostWillSleep() {
        hostAsleep = true
        guard host.state == .running, !host.shuttingDown else { return }
        host.pause()
        pausedForHostSleep = true
        logEvent("host sleep: paused")
    }

    /// Awake: resume, then set the guest's clock again.
    public func hostDidWake() {
        hostAsleep = false
        guard pausedForHostSleep else { return }
        pausedForHostSleep = false
        host.resume()
        logEvent("host wake: resumed")
        host.resyncTimeZone()
    }
}
