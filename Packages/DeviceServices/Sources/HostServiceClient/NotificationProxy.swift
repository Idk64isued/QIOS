// Push instead of poll. iOS 3.1.3 already has notification_proxy, and it
// publishes application_installed / application_uninstalled — so the sidebar
// can be told the moment something changes on the device instead of asking
// every few seconds. The np symbols were loaded for exactly this and had gone
// unused; this is the consumer.
//
// Stock install/uninstall notifications refresh promptly. The inspector's
// existing service poll also reads the Home screen layout, for which these
// older SpringBoard versions publish no notification. The session itself runs in the services helper
// (LightTouchServices/Engine/NotificationEngine.swift); this is the app's watcher that keeps one open.

import Foundation
import HostServiceWire

/// A long-lived notification_proxy session. One per device; `start` is
/// idempotent and the watcher re-establishes itself if the link drops.
@MainActor
public final class NotificationProxy {
    private var running = false
    private let endpoint: HostServiceEndpoint
    /// Held so the watcher can actually be stopped. This used to be
    /// bare `Task.detached`s with nothing retaining them, so `Task.isCancelled`
    /// was never true and the loops ran for the life of the process — the
    /// blocking one parked on a cooperative-pool thread, which is core-count
    /// sized and shared with every other async task in the app.
    private var watcher: Task<Void, Never>?
    public typealias Observer =
        @Sendable (HostServiceEndpoint, @escaping @Sendable () async -> Bool, @escaping @Sendable () -> Void) async ->
        Bool
    private let observe: Observer

    public init(
        clientSocket: String,
        udid: String? = nil,
        session: UUID = DeviceServices.session,
        observe: @escaping Observer = { endpoint, allowed, change in
            guard await allowed() else { return false }
            return await HostServiceWorkers.shared.observe(endpoint: endpoint, onChange: change)
        }
    ) {
        self.endpoint = HostServiceEndpoint(socket: clientSocket, udid: udid, session: session)
        self.observe = observe
    }

    /// Only inspect host activity in `attachAllowed`; existing subscriptions
    /// stay open during installs. The library reports loss of this specific
    /// service, so there is no extra USB health probe to queue behind transfers.
    public func start(
        attachAllowed: @escaping @Sendable () async -> Bool,
        onChange: @escaping @Sendable () -> Void
    ) {
        guard !running else { return }
        running = true
        let endpoint = self.endpoint
        let observe = self.observe

        watcher = Task {
            // Re-establish on loss: the guest drops its services on reboot and
            // on a USB reset, and a watcher that gave up then would leave the
            // sidebar quietly stale for the rest of the session.
            while !Task.isCancelled {
                guard await attachAllowed() else {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    continue
                }
                let ok = await observe(endpoint, attachAllowed, onChange)
                // A failed attach usually means the guest is still booting;
                // a successful session that ended means the link dropped.
                do { try await Task.sleep(for: .seconds(ok ? 2 : 10)) } catch { break }
            }
        }
    }

    /// Ends the session. Called when the inspector goes away or USB does.
    public func stop() {
        running = false
        watcher?.cancel()
        watcher = nil
    }

    deinit { watcher?.cancel() }
}
