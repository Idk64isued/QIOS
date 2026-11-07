import Foundation
import HostRuntime
import Testing

struct CarrierSettingsTests {
    /// A device saved with the old default name ("LightTouch") gets the new one; a typed name stays.
    @Test func oldDefaultNameBecomesLightTouch() throws {
        func decoded(_ name: String) throws -> CarrierSettings {
            var old = CarrierSettings()
            old.carrier = name
            old.bars = 2
            return try PropertyListDecoder().decode(CarrierSettings.self, from: PropertyListEncoder().encode(old))
        }
        #expect(CarrierSettings().carrier == "Light Touch")
        let migrated = try decoded("LightTouch")
        #expect(migrated.carrier == "Light Touch" && migrated.bars == 2)
        #expect(try decoded("AT&T").carrier == "AT&T")
        #expect(try decoded("Light Touch Mobile").carrier == "Light Touch Mobile")
    }

    /// The modem's own rules (qemu-ios ios_bb_plmn_ok, ios_bb_carrier_ok, ios_bb_sms_sender_ok).
    @Test func validatorsMatchTheModem() {
        #expect(CarrierSettings.plmnOK("00101") && CarrierSettings.plmnOK("310410"))
        #expect(
            !CarrierSettings.plmnOK("0010") && !CarrierSettings.plmnOK("0010123") && !CarrierSettings.plmnOK("00a01")
                && !CarrierSettings.plmnOK("") && !CarrierSettings.plmnOK("００１０１")
        )
        #expect(
            CarrierSettings.carrierOK("Test Network") && CarrierSettings.carrierOK(String(repeating: "x", count: 32))
        )
        #expect(
            !CarrierSettings.carrierOK("") && !CarrierSettings.carrierOK(String(repeating: "x", count: 33))
                && !CarrierSettings.carrierOK("a\"b") && !CarrierSettings.carrierOK("a\nb")
        )
        #expect(!CarrierSettings.carrierOK(String(repeating: "é", count: 17)))  // 34 UTF-8 bytes
        #expect(CarrierSettings.numberOK("+14155550100") && CarrierSettings.numberOK("5550100"))
        #expect(
            !CarrierSettings.numberOK("+") && !CarrierSettings.numberOK("") && !CarrierSettings.numberOK("Apple")
                && !CarrierSettings.numberOK("1+2") && !CarrierSettings.numberOK(String(repeating: "1", count: 21))
        )
        #expect(
            CarrierSettings.smsTextOK("Hi") && !CarrierSettings.smsTextOK("")
                && !CarrierSettings.smsTextOK(String(repeating: "a", count: 161))
        )
        #expect(CarrierSettings().isValid && CarrierSettings().mccMNC == "00101")
    }

    @Test func barsRoundTrip() {
        for bars in 0...5 { #expect(CarrierSettings.bars(signalDBM: CarrierSettings.signalDBM(bars: bars)) == bars) }
        #expect(CarrierSettings.signalDBM(bars: 9) == CarrierSettings.signalDBM(bars: 5))
    }

    @Test func globalsPassValuesVerbatim() {
        var s = CarrierSettings()
        s.carrier = "A, B"
        s.registered = false
        s.bars = 2
        #expect(
            s.globals == [
                "-global", "ios-baseband.carrier=A, B", "-global", "ios-baseband.mcc-mnc=00101",
                "-global", "ios-baseband.registered=off", "-global", "ios-baseband.sim-present=on",
                "-global", "ios-baseband.signal-dbm=-97",
                "-global", "ios-baseband.gps-fix=37.334900,-122.009000,0,0.00,-1.0,5"
            ]
        )
    }

    /// A device saved before the GPS (no location key) starts at Apple Park; a saved location comes back; the modem's
    /// gps-fix carries speed and course; a position off the globe isn't valid.
    @Test func gpsLocation() throws {
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CarrierSettings())) as! [String: Any]
        old.removeValue(forKey: "location")
        let migrated = try JSONDecoder().decode(
            CarrierSettings.self,
            from: JSONSerialization.data(withJSONObject: old)
        )
        #expect(migrated.location == .applePark && migrated.isValid)
        var s = CarrierSettings()
        s.location = GPSLocation(latitude: -33.8568, longitude: 151.2153)
        #expect(try JSONDecoder().decode(CarrierSettings.self, from: JSONEncoder().encode(s)) == s)
        #expect(s.location.fix(speed: 1.4, course: 45) == "-33.856800,151.215300,0,1.40,45.0,5")
        s.location.latitude = 91
        #expect(!s.isValid)
        #expect(!GPSLocation(latitude: 0, longitude: -180.5).isValid)
        #expect(!GPSLocation(latitude: .nan, longitude: 0).isValid)
        // 100 m north, then 100 m east: about 0.0009 degrees each way at the equator.
        let moved = GPSLocation(latitude: 0, longitude: 0).moved(meters: 100, course: 0).moved(meters: 100, course: 90)
        #expect(abs(moved.latitude - 0.000898) < 1e-5 && abs(moved.longitude - 0.000898) < 1e-5)
    }

    @Test func statusParsesTheDylibsJSON() throws {
        let json =
            #"{"carrier": "Test Network", "mcc-mnc": "00101", "call-state": "incoming", "last-dialed": "911", "#
            + #""last-mo-sms": "14155550100|Hi | there", "registered": true, "sim-present": false, "signal-dbm": -63, "#
            + #""mo-sms-count": 2, "emergency-call": true, "error": "the modem is not in a state to ring"}"#
        let s = try #require(ModemStatus(json: json))
        #expect(
            s.carrier == "Test Network" && s.callState == "incoming" && s.lastDialed == "911" && s.registered
                && !s.simPresent && s.emergencyCall
        )
        #expect(ModemStatus(json: "{}")?.emergencyCall == false && ModemStatus(json: "{}")?.hasGPS == false)
        let gps = try #require(ModemStatus(json: #"{"gps": true, "gps-fix": "37.3349000,-122.0090000,0,0,-1,5"}"#))
        #expect(gps.hasGPS && gps.gpsFix.hasPrefix("37.3349"))
        #expect(s.signalDBM == -63 && s.moSMSCount == 2 && s.error?.hasPrefix("the modem") == true)
        #expect(s.lastMOSMS?.number == "14155550100" && s.lastMOSMS?.text == "Hi | there")
        #expect(ModemStatus(json: #"{"last-mo-sms": "|"}"#)?.lastMOSMS == nil)
        #expect(ModemStatus(json: "nope") == nil)
    }
}
