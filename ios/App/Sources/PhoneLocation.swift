import CoreLocation
import Foundation

/// This phone's location as the device's GPS fix (Settings › Location), as the Mac app's Carrier panel sets it: the
/// iPhone 3GS's modem carries a GPS receiver (qemu-ios ios_baseband_gps.c), and its "gps-fix" property,
/// "lat,lon,alt,speed,course,accuracy", is what the guest's location services read. Only boards with a receiver
/// (Board.hasGPS) take it; at most one fix a second goes over.
@MainActor
final class PhoneLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private weak var qemu: QemuRuntime?
    private var lastSent = Date.distantPast
    private(set) var running = false
    /// Where fixes go on a board without a GPS receiver: iOS's own location simulation, through the guest agent
    /// (GuestLocation). Nil sends them to the modem's receiver, as on the 3GS.
    var sink: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    func start(qemu: QemuRuntime?) {
        self.qemu = qemu
        guard !running else { return }
        running = true
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
        LTMLog.note("location: following this phone")
    }

    /// Stops, and takes the fix away (the device's GPS loses its signal rather than keeping a stale position).
    func stop() {
        guard running else { return }
        running = false
        manager.stopUpdatingLocation()
        if sink == nil { _ = qemu?.modemSet?("gps-fix", "") }
        LTMLog.note("location: off")
    }

    /// The modem's form of a fix, inside the ranges ios_bb_gps_set accepts.
    static func fix(_ l: CLLocation) -> String? {
        let c = l.coordinate
        guard CLLocationCoordinate2DIsValid(c), l.horizontalAccuracy > 0 else { return nil }
        let alt = l.verticalAccuracy >= 0 ? max(-99_999, min(99_999, l.altitude)) : 0
        let speed = l.speed >= 0 ? min(l.speed, 1000) : 0
        let course = l.course >= 0 && l.course < 360 ? l.course : -1
        let accuracy = max(1, min(l.horizontalAccuracy, 99_999))
        return String(format: "%.7f,%.7f,%.1f,%.2f,%.1f,%.1f", c.latitude, c.longitude, alt, speed, course, accuracy)
    }

    private func send(_ location: CLLocation) {
        guard running, Date().timeIntervalSince(lastSent) >= 1, let fix = Self.fix(location) else { return }
        lastSent = Date()
        if let sink {
            sink(location)
        } else {
            _ = qemu?.modemSet?("gps-fix", fix)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.send(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor in LTMLog.note("location: \(error.localizedDescription)") }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .denied:
                LTMLog.note("location: refused. Settings \u{203A} Privacy & Security \u{203A} Location Services, and allow "
                    + (JIT.inLiveContainer ? "LiveContainer" : "Halcyon") + ".")
            case .restricted:
                // Under LiveContainer the asking app is LiveContainer, not this one: iOS reads the usage string and
                // the grant from ITS bundle. Without one there, the prompt never appears and the answer is a flat
                // "restricted", which looks like the user said no. Say where the permission actually lives.
                LTMLog.note(JIT.inLiveContainer
                    ? "location: not available. Inside LiveContainer, iOS grants location to LiveContainer itself, "
                      + "so allow Location for LiveContainer in Settings; if it never asks, LiveContainer was built "
                      + "without location and the device's GPS stays off."
                    : "location: not available on this phone (Screen Time restrictions?)")
            default:
                break
            }
        }
    }
}
