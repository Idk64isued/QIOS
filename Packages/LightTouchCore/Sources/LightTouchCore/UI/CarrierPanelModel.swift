// The Carrier panel's model (CarrierPanel is its view): the network settings as typed and applied, calls and SMS,
// and the modem's state polled while the panel is visible.

import Foundation
import HostRuntime
import Observation

/// What the panel drives: the running device's modem.
@MainActor public protocol CarrierBackend: AnyObject {
    var carrierSettings: CarrierSettings { get }
    @discardableResult func setCarrierSettings(_ settings: CarrierSettings) -> Bool
    func modem(_ property: String, _ value: String, done: @escaping @MainActor (Bool) -> Void)
    func modemStatus(_ done: @escaping @MainActor (ModemStatus?) -> Void)
}

@MainActor @Observable public final class CarrierPanelModel {
    public struct SentSMS: Identifiable, Equatable {
        public let id: Int
        public let number: String
        public let text: String
    }

    @ObservationIgnored private var backend: CarrierBackend
    public var settings: CarrierSettings
    /// The network fields as typed; applied (validated) with Apply.
    public var carrierName: String
    public var mcc: String
    public var mnc: String
    public var callNumber = "+15555550100"
    public var smsNumber = "+15555550100"
    public var smsText = ""
    public private(set) var status: ModemStatus?
    public private(set) var sent: [SentSMS] = []
    /// The last thing the panel or the modem refused.
    public private(set) var message: String?
    @ObservationIgnored private var lastMOCount: Int?
    /// The GPS position as typed, applied with Set.
    public var latitude: String
    public var longitude: String
    /// Walking: the receiver moves at walkSpeed around a walkRadius circle through the set location, a step per poll.
    public private(set) var walking = false
    @ObservationIgnored private var walkAngle = 0.0
    public static let walkSpeed = 1.4, walkRadius = 50.0

    public init(backend: CarrierBackend) {
        self.backend = backend
        settings = backend.carrierSettings
        carrierName = backend.carrierSettings.carrier
        mcc = String(backend.carrierSettings.mccMNC.prefix(3))
        mnc = String(backend.carrierSettings.mccMNC.dropFirst(3))
        latitude = Self.degrees(backend.carrierSettings.location.latitude)
        longitude = Self.degrees(backend.carrierSettings.location.longitude)
    }

    /// The device's session was replaced (Restart, Erase, a free-form size): the panel drives the new session's modem
    /// and shows its saved network; the old one's settings cache never writes again.
    public func rebind(to backend: CarrierBackend) {
        guard backend !== self.backend else { return }
        self.backend = backend
        settings = backend.carrierSettings
        carrierName = settings.carrier
        mcc = String(settings.mccMNC.prefix(3))
        mnc = String(settings.mccMNC.dropFirst(3))
        latitude = Self.degrees(settings.location.latitude)
        longitude = Self.degrees(settings.location.longitude)
        walking = false
        status = nil
        message = nil
        lastMOCount = nil
    }

    private static func degrees(_ value: Double) -> String { String(format: "%.6f", value) }

    public var typedPLMN: String { mcc + mnc }
    public var networkValid: Bool {
        CarrierSettings.carrierOK(carrierName) && mcc.count == 3 && CarrierSettings.plmnOK(typedPLMN)
    }
    public var networkEdited: Bool { carrierName != settings.carrier || typedPLMN != settings.mccMNC }
    /// An applied carrier or PLMN the modem doesn't report yet.
    public var applyingNetwork: Bool {
        guard let status else { return false }
        return status.carrier != settings.carrier || status.mccMNC != settings.mccMNC
    }

    public func applyNetwork() {
        guard networkValid else {
            message = "Carrier names are 1–32 characters without quotes; MCC is 3 digits and MNC 2 or 3."
            return
        }
        var s = settings
        s.carrier = carrierName
        s.mccMNC = typedPLMN
        save(s)
    }

    public func set(registered: Bool) {
        var s = settings
        s.registered = registered
        save(s)
    }
    public func set(simPresent: Bool) {
        var s = settings
        s.simPresent = simPresent
        save(s)
    }
    public func set(bars: Int) {
        var s = settings
        s.bars = bars
        save(s)
    }

    private func save(_ s: CarrierSettings) {
        if backend.setCarrierSettings(s) {
            settings = s
            message = nil
        }
    }

    public var callNumberValid: Bool { CarrierSettings.numberOK(callNumber) }
    public var smsValid: Bool { CarrierSettings.numberOK(smsNumber) && CarrierSettings.smsTextOK(smsText) }
    public var callState: String { status?.callState ?? "idle" }
    public var canRing: Bool { callNumberValid && callState == "idle" && settings.registered && settings.simPresent }
    public var canAnswer: Bool { callState == "dialing" || callState == "alerting" }
    public var canHangUp: Bool { callState != "idle" }

    public func ring() {
        guard callNumberValid else {
            message = "A caller is 1–20 digits, optionally after a +."
            return
        }
        backend.modem("incoming-call", callNumber) { [weak self] ok in
            if !ok { self?.message = "The modem isn’t available." }
        }
    }

    public func answer() { backend.modem("remote-answer", "1") { _ in } }
    public func hangUp() { backend.modem("remote-hangup", "1") { _ in } }

    public func sendSMS() {
        guard smsValid else {
            message = "A sender is 1–20 digits, optionally after a +; the text 1–160 characters."
            return
        }
        backend.modem("incoming-sms", "\(smsNumber)|\(smsText)") { [weak self] ok in
            if ok { self?.smsText = "" } else { self?.message = "The modem isn’t available." }
        }
    }

    /// Where the receiver says the phone is (a walk's latest step), else the set location.
    public var reportedLocation: GPSLocation {
        let parts = (status?.gpsFix ?? "").split(separator: ",").compactMap { Double($0) }
        return parts.count >= 2 ? GPSLocation(latitude: parts[0], longitude: parts[1]) : settings.location
    }

    /// Something to tell the user that the panel itself didn't decide (the Mac's location being unavailable).
    public func notice(_ text: String) { message = text }

    public var typedLocation: GPSLocation? {
        guard let lat = Double(latitude), let lon = Double(longitude) else { return nil }
        let location = GPSLocation(latitude: lat, longitude: lon)
        return location.isValid ? location : nil
    }

    public func applyLocation() {
        guard let location = typedLocation else {
            message = "Latitude is −90 to 90 and longitude −180 to 180, in degrees."
            return
        }
        set(location: location)
    }

    /// A new position for the receiver (a preset, a click on the map, the Mac's own); it stops a walk.
    public func set(location: GPSLocation) {
        let walked = walking
        walking = false
        latitude = Self.degrees(location.latitude)
        longitude = Self.degrees(location.longitude)
        var s = settings
        s.location = location
        save(s)
        // The saved settings only write what changed: a walk's moving fix ends here even at the same spot.
        if walked { backend.modem("gps-fix", location.fix()) { _ in } }
    }

    public func toggleWalk() {
        if walking {
            set(location: walkPosition)  // stays where the walk got to, standing still
        } else {
            walkAngle = 0
            walking = true
        }
    }

    /// Where the walk is: on the circle that starts at the set location and runs clockwise (east first).
    var walkPosition: GPSLocation {
        let r = Self.walkRadius
        return settings.location.moved(meters: r, course: 180).moved(meters: r, course: walkAngle * 180 / .pi)
    }

    /// One step of the walk, a second's worth: the next point and the course to it, as a moving fix.
    func walkStep() {
        walkAngle += Self.walkSpeed / Self.walkRadius
        let course = (walkAngle * 180 / .pi + 90).truncatingRemainder(dividingBy: 360)
        backend.modem("gps-fix", walkPosition.fix(speed: Self.walkSpeed, course: course)) { _ in }
    }

    /// One poll: the modem's state, its refusal of the last write, and any SMS the phone sent since the last poll.
    public func poll() {
        if walking { walkStep() }
        backend.modemStatus { [weak self] status in
            guard let self, let status else { return }
            self.status = status
            if let error = status.error { self.message = error }
            if let last = lastMOCount, status.moSMSCount > last, let mo = status.lastMOSMS {
                sent.insert(SentSMS(id: status.moSMSCount, number: mo.number, text: mo.text), at: 0)
                sent = Array(sent.prefix(20))
            }
            lastMOCount = status.moSMSCount
        }
    }
}
