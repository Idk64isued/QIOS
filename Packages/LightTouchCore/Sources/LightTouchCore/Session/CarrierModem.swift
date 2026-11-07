// Carrier (radio boards): the fake network's settings are the device's (DeviceSettings.carrier). Every boot starts
// the modem with them (BootRecipe, -global ios-baseband.*), and a change while it runs is written to the modem too.

import DeviceRuntime
import Foundation
import HostRuntime
import Observation

@Observable public final class CarrierModem: CarrierBackend {
    public let hasCellular: Bool
    @ObservationIgnored private let settings: DeviceSettingsFile
    @ObservationIgnored private let scope: BootSessionScope
    @ObservationIgnored private let link: () -> HelperLink?

    public init(
        hasCellular: Bool,
        settings: DeviceSettingsFile,
        scope: BootSessionScope,
        link: @escaping () -> HelperLink?
    ) {
        self.hasCellular = hasCellular
        self.settings = settings
        self.scope = scope
        self.link = link
    }

    /// The saved settings when valid, else the defaults.
    public var carrierSettings: CarrierSettings {
        settings.value.carrier.flatMap { $0.isValid ? $0 : nil } ?? CarrierSettings()
    }

    /// Saves valid settings and writes what changed to the running modem; false (nothing saved) for invalid ones.
    @discardableResult
    public func setCarrierSettings(_ new: CarrierSettings) -> Bool {
        guard hasCellular, new.isValid else { return false }
        let old = Dictionary(carrierSettings.properties.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        settings.change { $0.carrier = new }
        for p in new.properties where old[p.name] != p.value { modem(p.name, p.value) }
        return true
    }

    /// One modem property or action (incoming-call, remote-answer, remote-hangup, incoming-sms); `done` gets whether
    /// the helper queued it. The modem's own refusal shows in the next status's `error`.
    public func modem(_ property: String, _ value: String, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard hasCellular else { return done(false) }
        scope.control(.modemSet(property: property, value: value), on: link(), done)
    }

    /// The modem's state as of the previous poll (the helper refreshes it per call); nil when it isn't running.
    public func modemStatus(_ done: @escaping @MainActor (ModemStatus?) -> Void) {
        guard hasCellular, let link = link(), !scope.retired else { return done(nil) }
        let session = scope.id
        link.request(.modemStatus, timeout: 10) { [weak self] reply in
            MainActor.assumeIsolated {
                guard let self, !self.scope.retired, session == self.scope.id,
                    case .success(.modemStatus(let json?)) = reply
                else { return done(nil) }
                done(ModemStatus(json: json))
            }
        }
    }
}
