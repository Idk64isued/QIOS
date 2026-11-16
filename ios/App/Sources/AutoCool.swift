import Foundation

/// Cools the device down by itself when this phone gets hot (Settings › Cool down automatically, on by default):
/// once iOS reports the phone's thermal state as critical (and until it is back to fair), the device's screen runs at 30 frames a second
/// instead of 60 (qemu-ios patch 0018 changes the panel's rate while it runs), and this app presents at 30 too. That
/// halves the drawing work on both sides, which is most of what heats the phone while nothing else changes. When the
/// phone is back to fair or nominal, it returns to 60. Settings › Cool mode keeps it at 30 all the time instead.
@MainActor
final class AutoCool {
    static let shared = AutoCool()
    /// Posted when `cooling` changes (DisplayUIView follows it with its own frame rate).
    static let changed = Notification.Name("LTMAutoCoolChanged")

    private(set) var cooling = false
    private weak var qemu: QemuRuntime?
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    var enabled: Bool { UserDefaults.standard.object(forKey: "autoCool") as? Bool ?? true }

    func start(qemu: QemuRuntime?) {
        self.qemu = qemu
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
            ) { _ in Task { @MainActor in AutoCool.shared.evaluate() } }
        }
        // Also now and then: the emulator may not have been ready to take a change the first time.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in AutoCool.shared.evaluate() }
        }
        evaluate()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        timer?.invalidate()
        timer = nil
        qemu = nil
        set(false, apply: false)
    }

    func evaluate() {
        guard qemu != nil else { return }
        // Critical, not serious: a phone running an emulator sits at serious from its first minute (the first
        // test cooled from 8 s in and the device felt laggy the whole session for it), so serious would mean 30 Hz
        // always. Critical is the phone about to throttle hard on its own; it cools until the phone is back to fair.
        let state = ProcessInfo.processInfo.thermalState
        let hot = cooling ? state.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                          : state == .critical
        // Cool mode already booted the device at 30 Hz; nothing to change then.
        let coolMode = UserDefaults.standard.bool(forKey: "coolMode")
        set(enabled && hot && !coolMode, apply: true)
    }

    private func set(_ on: Bool, apply: Bool) {
        guard on != cooling else { return }
        if apply {
            guard let setRate = qemu?.setRefreshHz, setRate(on ? 30 : 60) else { return }  // not ready: try again later
        }
        cooling = on
        LTMLog.note(on ? "auto cool: the phone is hot; the device's screen runs at 30 frames a second until it cools"
                       : "auto cool: back to 60 frames a second")
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
