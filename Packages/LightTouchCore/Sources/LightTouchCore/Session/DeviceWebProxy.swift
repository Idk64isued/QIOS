// The device's web proxy as the session holds it: its routing and certificate live beside the device's own state
// (WebProxyConfiguration.directory), so one device's proxy (in its helper) never reads another's mode. The boot
// writes the routing and forwards the guest to the helper's proxy; the foreground watch applies a change to the
// guest once it answers.

import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Observation

@Observable public final class DeviceWebProxy {
    @ObservationIgnored private let directoryNow: () -> URL
    @ObservationIgnored private let shortName: String

    /// `directory`: read at each use, as the device's record (its storage) can be refreshed before a boot.
    public init(directory: @escaping () -> URL, shortName: String) {
        directoryNow = directory
        self.shortName = shortName
    }
    public var directory: URL { directoryNow() }

    @ObservationIgnored public private(set) lazy var configuration = WebProxyConfiguration.load(from: directory)
    /// Where the guest's proxy settings are: the proxy editor's line.
    public private(set) var status: WebProxyStatus = .waiting
    /// Bumped by every change; the foreground watch applies each one once.
    @ObservationIgnored private(set) var revision = 0
    /// This boot's routing is written: the proxy can be changed.
    public private(set) var available = false
    /// This boot's proxy (BootConfig.webProxy): the helper serves it; nil when the routing can't be written.
    @ObservationIgnored public private(set) var endpoint: WebProxyEndpoint?

    public func configure(_ value: WebProxyConfiguration) throws {
        guard available else {
            throw DeviceToolsError.failed(
                "The proxy is unavailable. Start the \(shortName) and connect it to the internet."
            )
        }
        try value.save(in: directory)
        configuration = value
        revision += 1
        status = .waiting
    }

    /// A new boot builds its own endpoint (forward()); a stop leaves none. The old socket's path goes.
    public func forgetEndpoint() {
        if let endpoint { unlink(endpoint.socket) }
        endpoint = nil
    }

    /// Writes this device's routing and returns the guestfwd that reaches the helper's proxy; nil when the routing
    /// can't be written (the proxy then reads failed).
    public func forward() -> String? {
        do {
            try configuration.writeRouting(in: directory)
            available = true
            let endpoint = WebProxyConfiguration.endpoint(directory: directory)
            self.endpoint = endpoint
            return WebProxyConfiguration.guestForward(socket: endpoint.socket)
        } catch {
            status = .failed
            logEvent("proxy routing: \(error.localizedDescription)")
            return nil
        }
    }

    /// One pass of the foreground watch: when the routing changed since `applied` (the revision this boot last
    /// applied), sets the guest's proxy through `setUp` (on or off) and returns the revision applied now. Throws
    /// CancellationError when the watch should end: cancelled, or `isCurrent` says a later boot took over.
    public func apply(
        since applied: Int?,
        isCurrent: () -> Bool,
        setUp: (_ enabled: Bool) async throws -> WebProxyStatus
    ) async throws -> Int? {
        guard available, applied != revision else { return applied }
        let revision = self.revision
        if status == .waiting { status = .applying }
        let trust: WebProxyStatus
        do {
            trust = try await setUp(configuration.mode != .off)
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if status != .failed {
                status = .failed
                logEvent("proxy settings: \(error.localizedDescription)")
            }
            return applied
        }
        guard isCurrent() else { throw CancellationError() }
        guard revision == self.revision else { return applied }
        status = trust
        return revision
    }
}
