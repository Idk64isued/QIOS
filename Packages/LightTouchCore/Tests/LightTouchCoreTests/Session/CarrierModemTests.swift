import DeviceRuntime
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// The fake network's settings: saved per device only when valid, and only what changed written to the running
/// modem; the modem's status for this boot only; nothing at all on a board without a radio.
struct CarrierModemTests {
    @Test func validSettingsAreSavedAndOnlyChangesReachTheModem() throws {
        try withTemporaryDirectory { directory in
            let link = RecordingLink()
            let scope = BootSessionScope()
            let modem = CarrierModem(
                hasCellular: true,
                settings: DeviceSettingsFile(directory: directory),
                scope: scope
            ) { link }
            #expect(modem.carrierSettings == CarrierSettings())
            var next = CarrierSettings()
            next.carrier = "Lab"
            next.bars = 2
            var saved = false
            #expect(observes({ _ = modem.carrierSettings }) { saved = modem.setCarrierSettings(next) })
            #expect(saved)
            #expect(
                link.requests == [
                    .modemSet(property: "carrier", value: "Lab"),
                    .modemSet(property: "signal-dbm", value: String(CarrierSettings.signalDBM(bars: 2)))
                ]
            )
            #expect(DeviceSettings.load(directory).carrier == next && modem.carrierSettings == next)

            var invalid = next
            invalid.mccMNC = "12"
            #expect(!modem.setCarrierSettings(invalid))
            #expect(link.requests.count == 2 && DeviceSettings.load(directory).carrier == next, "nothing saved or sent")

            // Another device's file, since this one's settings are shared while the modem holds them.
            let other = directory.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            var file = DeviceSettings()
            file.carrier = invalid
            try file.save(other)
            let reopened = CarrierModem(
                hasCellular: true,
                settings: DeviceSettingsFile(directory: other),
                scope: scope
            ) { link }
            #expect(reopened.carrierSettings == CarrierSettings(), "an invalid saved value falls back to the defaults")
        }
    }

    @Test func aBoardWithoutARadioHasNoModem() throws {
        try withTemporaryDirectory { directory in
            let link = RecordingLink()
            let modem = CarrierModem(
                hasCellular: false,
                settings: DeviceSettingsFile(directory: directory),
                scope: BootSessionScope()
            ) { link }
            var queued: Bool?
            modem.modem("incoming-call", "+15551234", done: { queued = $0 })
            var status: ModemStatus? = ModemStatus()
            modem.modemStatus { status = $0 }
            #expect(!modem.setCarrierSettings(CarrierSettings()))
            #expect(queued == false && status == nil && link.requests.isEmpty)
        }
    }

    @Test func theStatusIsThisBootsOnly() throws {
        try withTemporaryDirectory { directory in
            let link = RecordingLink()
            let scope = BootSessionScope()
            link.answer = nil
            let modem = CarrierModem(
                hasCellular: true,
                settings: DeviceSettingsFile(directory: directory),
                scope: scope
            ) { link }
            var statuses: [ModemStatus?] = []
            modem.modemStatus { statuses.append($0) }
            link.pending.removeFirst()(.success(.modemStatus(#"{"carrier":"Lab","call-state":"ringing"}"#)))
            #expect(statuses.count == 1 && statuses[0]?.carrier == "Lab" && statuses[0]?.callState == "ringing")

            modem.modemStatus { statuses.append($0) }
            scope.renew()  // a restart in place: the reply belongs to the old boot
            link.pending.removeFirst()(.success(.modemStatus(#"{"carrier":"Old"}"#)))
            #expect(statuses.count == 2 && statuses[1] == nil, "a reply from an earlier boot reads as no status")
            scope.retire()
            modem.modemStatus { statuses.append($0) }
            #expect(statuses.count == 3 && statuses[2] == nil && link.pending.isEmpty, "a retired boot isn't asked")
        }
    }
}
