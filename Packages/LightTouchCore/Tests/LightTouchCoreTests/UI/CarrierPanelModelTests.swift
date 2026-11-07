import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// A modem that reports what it's told to report.
@MainActor private final class Modem: CarrierBackend {
    var carrierSettings = CarrierSettings()
    var reported = ModemStatus()
    var actions: [String] = []
    func setCarrierSettings(_ settings: CarrierSettings) -> Bool {
        carrierSettings = settings
        return true
    }
    func modem(_ property: String, _ value: String, done: @escaping @MainActor (Bool) -> Void) {
        actions.append("\(property)=\(value)")
        done(true)
    }
    func modemStatus(_ done: @escaping @MainActor (ModemStatus?) -> Void) { done(reported) }
}

/// The Carrier panel's model against a fake modem: Applying… until the modem reports the applied carrier and PLMN,
/// validation before anything is sent, and the phone's outgoing SMS.
struct CarrierPanelModelTests {
    @Test func applyingUntilTheModemReportsTheNewNetwork() {
        let modem = Modem()
        modem.reported.carrier = modem.carrierSettings.carrier
        modem.reported.mccMNC = modem.carrierSettings.mccMNC
        let model = CarrierPanelModel(backend: modem)
        #expect(!model.applyingNetwork, "nothing polled yet")
        model.poll()
        #expect(!model.applyingNetwork, "applying before any change")
        model.carrierName = "Fictional"
        #expect(model.networkEdited && model.networkValid)
        model.applyNetwork()
        #expect(modem.carrierSettings.carrier == "Fictional" && !model.networkEdited)
        model.poll()
        #expect(model.applyingNetwork, "no progress while the modem still reports the old carrier")
        modem.reported.carrier = "Fictional"
        modem.reported.mccMNC = modem.carrierSettings.mccMNC
        model.poll()
        #expect(!model.applyingNetwork, "still applying once the modem reports it")
    }

    @Test func aReplacedSessionTakesThePanelOver() throws {
        let old = Modem()
        let model = CarrierPanelModel(backend: old)
        model.poll()
        model.toggleWalk()
        let new = Modem()
        new.carrierSettings.carrier = "Restarted"
        new.carrierSettings.location = GPSLocation(latitude: 51.5, longitude: -0.12)
        new.reported = try #require(ModemStatus(json: #"{"call-state": "incoming", "mo-sms-count": 4}"#))
        model.rebind(to: new)
        #expect(model.settings == new.carrierSettings && model.carrierName == "Restarted", "the new session's network")
        #expect(model.status == nil, "no state from the old modem")
        #expect(model.latitude == "51.500000" && model.longitude == "-0.120000" && !model.walking, "its GPS position")
        model.poll()
        #expect(model.callState == "incoming")
        model.set(bars: 2)
        model.callNumber = "+15555550199"
        model.hangUp()
        #expect(new.carrierSettings.bars == 2 && new.actions == ["remote-hangup=1"])
        #expect(old.carrierSettings == CarrierSettings() && old.actions.isEmpty, "the old session hears nothing")
    }

    @Test func invalidNetworkIsRefusedBeforeTheModem() {
        let modem = Modem()
        let model = CarrierPanelModel(backend: modem)
        let before = modem.carrierSettings
        model.mcc = "12"
        model.applyNetwork()
        #expect(modem.carrierSettings == before && model.message != nil)
    }

    @Test func callsAndMessagesNeedValidInput() {
        let modem = Modem()
        let model = CarrierPanelModel(backend: modem)
        model.smsText = ""
        model.sendSMS()
        #expect(modem.actions.isEmpty && model.message != nil)
        model.smsText = "hello"
        model.sendSMS()
        #expect(
            modem.actions == ["incoming-sms=+15555550100|hello"] && model.smsText.isEmpty,
            "a sent message clears the field"
        )
        model.callNumber = "not a number"
        model.ring()
        #expect(modem.actions.count == 1)
    }

    @Test func outgoingMessagesAppearNewestFirst() throws {
        let modem = Modem()
        let model = CarrierPanelModel(backend: modem)
        modem.reported = try #require(ModemStatus(json: #"{"mo-sms-count": 1, "last-mo-sms": "123|before the panel"}"#))
        model.poll()
        #expect(model.sent.isEmpty, "only messages sent while the panel watches")
        modem.reported = try #require(ModemStatus(json: #"{"mo-sms-count": 2, "last-mo-sms": "555|first"}"#))
        model.poll()
        modem.reported = try #require(ModemStatus(json: #"{"mo-sms-count": 3, "last-mo-sms": "556|second"}"#))
        model.poll()
        #expect(model.sent.map(\.text) == ["second", "first"] && model.sent.first?.number == "556")
    }

    /// Set writes the receiver's position through the settings (saved, and the modem's gps-fix); a typo is refused
    /// before anything is sent; a walk moves the fix around the circle at walking speed with the course it heads,
    /// one step per poll, and stopping leaves the receiver standing where the walk got to.
    @Test func locationAndWalk() throws {
        let modem = Modem()
        let model = CarrierPanelModel(backend: modem)
        #expect(model.latitude == "37.334900" && model.longitude == "-122.009000")
        model.latitude = "north"
        model.applyLocation()
        #expect(modem.carrierSettings.location == .applePark && model.message != nil)
        model.latitude = "51.500729"
        model.longitude = "-0.124625"
        model.applyLocation()
        let start = GPSLocation(latitude: 51.500729, longitude: -0.124625)
        #expect(modem.carrierSettings.location == start)

        model.toggleWalk()
        #expect(model.walking)
        var fixes: [[Double]] = []
        for _ in 0..<3 {
            model.poll()
            let fix = try #require(modem.actions.last?.split(separator: "=").last)
            fixes.append(fix.split(separator: ",").compactMap { Double($0) })
        }
        let speed = CarrierPanelModel.walkSpeed
        for (i, f) in fixes.enumerated() {
            let step = Double(i + 1) * speed  // meters walked along the circle
            #expect(f[3] == speed)
            #expect(abs(f[4] - (90 + step / CarrierPanelModel.walkRadius * 180 / .pi)) < 0.1, "course \(f[4])")
            // East of the start by about the arc walked (a chord, close for a few steps).
            let east = (f[1] - start.longitude) * 111_320 * cos(start.latitude * .pi / 180)
            #expect(abs(east - step) < 0.2, "\(east) m east after \(step) m")
        }
        model.toggleWalk()
        #expect(!model.walking)
        let stopped = modem.carrierSettings.location
        #expect(abs(stopped.longitude - fixes[2][1]) < 1e-6 && abs(stopped.latitude - fixes[2][0]) < 1e-6)
        let sent = modem.actions.count
        model.poll()
        #expect(modem.actions.count == sent, "no more steps once stopped")
    }
}
