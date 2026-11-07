// Keep the guest's timezone matched to the Mac's: once when the device
// first answers after this boot, and again whenever the host's zone
// changes (travel). Set through lockdown's TimeZone value — lockdownd
// rewrites /var/db/timezone/localtime and SpringBoard follows live, so
// no respring (the lock screen's clock too: lockdown-tz refreshes it).
// The link persists, so later boots start in the zone; a fresh device's
// first lock screen is drawn before lockdown answers and shows the
// restore's Pacific zone until this lands (smoke #58). The guest's clock
// itself is UTC from the RTC model; only the zone needs the host's help.

import Foundation
import HostRuntime
import HostServiceWire

/// What the time-zone sync reads of the session, and the one write it makes.
public protocol TimeZoneHost: AnyObject {
    var bootScope: BootSessionScope { get }
    var state: VMState { get }
    var shuttingDown: Bool { get }
    var isDead: Bool { get }
    var isPoweredOff: Bool { get }
    var preparingDevice: Bool { get }
    var canManageApps: Bool { get }
    func deviceReady() async -> Bool
    /// Sets the guest's zone and region to the Mac's; DeviceToolsError.zoneKept when the device keeps its own.
    func setGuestTimeZone(_ identifier: String) async throws
}

public final class TimeZoneSync {
    private unowned let host: TimeZoneHost
    public init(host: TimeZoneHost) { self.host = host }

    /// Between tries while the device isn't ready or a try fails (shorter in tests).
    var retryInterval: Duration = .seconds(5)
    private var scope = 0
    private var task: Task<Void, Never>? {
        get { host.bootScope[.timeZone] }
        set { host.bootScope[.timeZone] = newValue }
    }

    public func stop() {
        scope += 1
        task?.cancel()
        task = nil
        host.bootScope.timeZoneObserver = nil
        host.bootScope.localeObserver = nil
    }

    public func start() {
        stop()
        let generation = host.bootScope.generation
        let scope = scope
        host.bootScope.timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.host.bootScope.generation, scope == self.scope else { return }
                self.schedule(generation: generation)
            }
        }
        // The region and the 24-hour setting follow the Mac's too.
        host.bootScope.localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.host.bootScope.generation, scope == self.scope else { return }
                self.schedule(generation: generation)
            }
        }
        schedule(generation: generation)
    }

    /// Sync again for this boot (the Mac woke; Setup set its own locale), replacing a pending try.
    public func resync() { schedule(generation: host.bootScope.generation) }

    /// Sync for boot `generation`, replacing a pending try.
    public func schedule(generation: Int) {
        task?.cancel()
        task = Task { [weak self] in await self?.syncWhenReady(generation: generation) }
    }

    /// Wait out the boot (services come up well after lockdown answers), then
    /// set until one attempt sticks — a transient "Invalid service" right
    /// after boot just means the next 5 s tick tries again. A zone the device
    /// keeps whatever lockdown says stays until the Mac's zone changes again.
    /// A new timezone notification replaces the pending operation for this boot.
    private func syncWhenReady(generation: Int) async {
        while !Task.isCancelled {
            guard generation == host.bootScope.generation, !host.shuttingDown, !host.isDead, !host.isPoweredOff else {
                return
            }
            if host.state == .running, !host.preparingDevice, host.canManageApps, await host.deviceReady() {
                guard generation == host.bootScope.generation, !Task.isCancelled else { return }
                do {
                    try await host.setGuestTimeZone(TimeZone.current.identifier)
                    return
                } catch DeviceToolsError.zoneKept(let zone) {
                    guard generation == host.bootScope.generation, !Task.isCancelled else { return }
                    logEvent("timezone: the device keeps \(zone)")
                    return
                } catch {}
            }
            try? await Task.sleep(for: retryInterval)
        }
    }
}
