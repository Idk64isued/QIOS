// notification_proxy in the services helper: one session that subscribes to the install/uninstall
// notifications 3.1.3 publishes and reports each until the session dies. The app's watcher
// (HostServiceClient's NotificationProxy) keeps one open through HostServiceWorkers.observe.

import Foundation
import HostServiceWire

nonisolated enum NotificationEngine {
    /// What the guest actually publishes on 3.1.3.
    ///
    /// nonisolated, like everything else the session touches: `observeOnce`
    /// runs on a detached thread and the C callback on libimobiledevice's own,
    /// so none of this may be main-actor bound.
    nonisolated static let observed = [
        "com.apple.mobile.application_installed",
        "com.apple.mobile.application_uninstalled"
    ]

    /// Handed to the C callback; retained for the session's whole life and
    /// released only after np_client_free has joined the callback thread.
    nonisolated private final class Sink: @unchecked Sendable {
        let fire: @Sendable () -> Void
        let closed: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init(_ fire: @escaping @Sendable () -> Void) {
            self.fire = fire
            (closed, continuation) = AsyncStream.makeStream()
        }

        func receive(_ notification: UnsafePointer<CChar>?) {
            // libimobiledevice reports ProxyDeath or a failed receive by
            // calling the notification callback with an empty string, then
            // exits its reader thread. USB attachment can still be healthy.
            guard let notification, notification.pointee != 0 else {
                continuation.finish()
                return
            }
            if NotificationEngine.observed.contains(String(cString: notification)) {
                fire()
            }
        }
    }

    /// The C callback runs on libimobiledevice's own thread. Classify the
    /// notification and hand it off without blocking that reader.
    nonisolated private static let callback: np_notify_cb_t = { notification, userData in
        guard let userData else { return }
        Unmanaged<Sink>.fromOpaque(userData).takeUnretainedValue().receive(notification)
    }

    /// Opens one session and blocks until it dies. Returns whether it ever got
    /// as far as observing, so the caller can back off sensibly.
    nonisolated static func observeOnce(
        socket: String,
        attachAllowed: @escaping @Sendable () async -> Bool,
        onChange: @escaping @Sendable () -> Void
    ) async -> Bool {
        // np_client_start_service does a full lockdown handshake and start_service
        // internally, so it goes through the gate like every other service
        // connect. Its factory then closes lockdown; the lasting subscription
        // uses its own service socket and does not reserve a lockdown session.
        // A connect that lands after the deadline still has its client and
        // retained callback context freed (openBeforeDeadline).
        let handles: Session?
        do {
            handles = try await DeviceGate.shared.serialized(socket: socket) {
                // An install may have started while this task waited for the
                // gate. Do not introduce another handshake between its stages.
                guard await attachAllowed() else { return nil }
                return try await openBeforeDeadline(Timeouts.serviceProbe * 2, "notification watcher") {
                    connect(onChange: onChange)
                }
            }
        } catch {
            return false
        }
        guard let handles else { return false }

        // The callback runs on a thread libimobiledevice owns. Wait out here
        // while it does — asynchronously, so no pool thread is parked — and let
        // np_client_free join that thread before the context is released, never
        // under it.
        // Cancellation ends the stream wait as well. A busy install is not a
        // disconnected notification socket, and an attached USB device is not
        // proof that this reader thread is still alive.
        for await _ in handles.closed {}
        // np_client_free sends Shutdown and joins the C reader. A partial
        // packet can leave that reader blocked; never perform the join on the
        // main actor or release its callback context until the join completes.
        // This independent task must run even when the watcher was cancelled.
        await freeDetached(handles, Timeouts.serviceProbe * 2, "notification")
        return true
    }

    /// The blocking half: open the session and arm the callback.
    private nonisolated static func connect(onChange: @escaping @Sendable () -> Void)
        -> Session?
    {
        var device: OpaquePointer?
        guard IMobileDevice.openDevice(&device).ok, let device else { return nil }
        defer { _ = idevice_free(device) }

        var client: OpaquePointer?
        guard np_client_start_service(device, &client, "LightTouchMac").ok, let client else { return nil }

        for name in observed {
            guard np_observe_notification(client, name).ok else {
                _ = np_client_free(client)
                return nil
            }
        }

        let sink = Sink(onChange)
        let ctx = Unmanaged.passRetained(sink).toOpaque()
        guard np_set_notify_callback(client, callback, ctx).ok else {
            Unmanaged<Sink>.fromOpaque(ctx).release()
            _ = np_client_free(client)
            return nil
        }
        return Session(client: client, ctx: ctx, closed: sink.closed)
    }

    /// The open session's handles. A box, because OpaquePointer is not Sendable
    /// and these cross the gate's await.
    nonisolated private final class Session: OpenedHandles, @unchecked Sendable {
        let client: OpaquePointer
        let ctx: UnsafeMutableRawPointer
        let closed: AsyncStream<Void>
        init(client: OpaquePointer, ctx: UnsafeMutableRawPointer, closed: AsyncStream<Void>) {
            self.client = client
            self.ctx = ctx
            self.closed = closed
        }
        func free() {
            _ = np_client_free(client)
            Unmanaged<Sink>.fromOpaque(ctx).release()
        }
    }
}
