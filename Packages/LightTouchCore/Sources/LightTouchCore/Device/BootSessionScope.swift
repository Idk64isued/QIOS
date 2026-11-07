import Foundation
import Observation

/// Owns work which must never outlive one boot. The halt transaction itself
/// belongs to the controller, so retiring a boot cannot cancel its cleanup.
/// Observable: which boot is current (`id`, `retired`), for what follows each boot (AppChangeWatch).
@MainActor @Observable
public final class BootSessionScope {
    public init() {}
    public enum Work: CaseIterable {
        case foreground, readiness, recovery, watchdog, timeZone, orientation
        case guestPackage, activation, staging, powerOn, reset, crashReports
    }
    public private(set) var id = UUID()
    @ObservationIgnored public private(set) var generation = 0
    public private(set) var retired = false
    @ObservationIgnored private var tasks: [Work: Task<Void, Never>] = [:]
    @ObservationIgnored private var observers: [String: NSObjectProtocol] = [:]

    public subscript(work: Work) -> Task<Void, Never>? {
        get { tasks[work] }
        set {
            tasks[work]?.cancel()
            guard !retired else {
                newValue?.cancel()
                return
            }
            tasks[work] = newValue
        }
    }
    public var timeZoneObserver: NSObjectProtocol? {
        get { observers["timeZone"] }
        set { setObserver("timeZone", newValue) }
    }
    /// The Mac's region and 24-hour setting (NSLocale.currentLocaleDidChangeNotification).
    public var localeObserver: NSObjectProtocol? {
        get { observers["locale"] }
        set { setObserver("locale", newValue) }
    }
    private func setObserver(_ key: String, _ newValue: NSObjectProtocol?) {
        if let old = observers[key] { NotificationCenter.default.removeObserver(old) }
        guard !retired else {
            if let newValue { NotificationCenter.default.removeObserver(newValue) }
            observers[key] = nil
            return
        }
        observers[key] = newValue
    }
    public func retire() {
        guard !retired else { return }
        retired = true
        generation += 1  // invalidate suspended completions before another boot
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        timeZoneObserver = nil
        localeObserver = nil
    }
    public func renew() {
        retire()
        id = UUID()
        retired = false
    }
}
