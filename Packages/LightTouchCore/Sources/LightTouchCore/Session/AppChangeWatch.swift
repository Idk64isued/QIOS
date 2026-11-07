// The guest's own install and uninstall notifications (notification_proxy) for the device's current boot, so the
// inspector's list changes the moment an app does instead of on its next poll.

import Foundation
import HostServiceClient
import HostServiceWire

/// One watcher per boot: on the boot's endpoint (which carries the boot's id), replaced as soon as Restart or Power On
/// renews the boot, stopped while the device has no services. Only the current boot's events reach `onChange`.
public final class AppChangeWatch {
    private let apps: DeviceApps
    private let attachAllowed: @Sendable () async -> Bool
    private let onChange: () -> Void
    /// The watcher's attach and observe; nil is NotificationProxy's own (the services worker).
    var observe: NotificationProxy.Observer?
    public private(set) var endpoint: HostServiceEndpoint?
    private var watcher: NotificationProxy?
    private var boots: ObservationLoop?

    public init(apps: DeviceApps, attachAllowed: @escaping @Sendable () async -> Bool, onChange: @escaping () -> Void) {
        self.apps = apps
        self.attachAllowed = attachAllowed
        self.onChange = onChange
    }

    /// Watches the current boot from now on, following each new one (the scope's id and usbmuxd are observable).
    public func start() {
        guard boots == nil else { return }
        boots = ObservationLoop(read: { [weak self] in self?.follow() })
    }

    public func stop() {
        boots?.cancel()
        boots = nil
        endWatcher()
    }

    /// A new watcher when the boot changed, none without services.
    private func follow() {
        let current = (try? apps.services)?.endpoint
        guard current != endpoint else { return }
        endWatcher()
        endpoint = current
        guard let current else { return }
        let watcher =
            observe.map {
                NotificationProxy(
                    clientSocket: current.socket,
                    udid: current.udid,
                    session: current.session,
                    observe: $0
                )
            } ?? NotificationProxy(clientSocket: current.socket, udid: current.udid, session: current.session)
        self.watcher = watcher
        watcher.start(attachAllowed: attachAllowed) { [weak self] in
            // Off the library's callback thread and onto ours.
            Task { @MainActor in
                guard let self, (try? self.apps.services)?.endpoint == current else { return }
                self.onChange()
            }
        }
    }

    private func endWatcher() {
        watcher?.stop()
        watcher = nil
        endpoint = nil
    }
}
