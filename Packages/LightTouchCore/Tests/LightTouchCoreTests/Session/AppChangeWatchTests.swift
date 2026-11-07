import Foundation
import HostServiceWire
import Testing
import os

@testable import LightTouchCore

/// The guest's app notifications follow the boot: a Restart or Power On (a renewed boot) gets a watcher of its own,
/// the old boot's events are dropped, and a device without services has none.
struct AppChangeWatchTests {
    /// The watchers' observe calls: which endpoint each attached to, and its change callback.
    final class Attaches: Sendable {
        let state = OSAllocatedUnfairLock(initialState: [(HostServiceEndpoint, @Sendable () -> Void)]())
        var endpoints: [HostServiceEndpoint] { state.withLock { $0.map(\.0) } }
        func change(_ index: Int) { state.withLock { $0[index].1 }() }
    }

    @Test func aRenewedBootGetsItsOwnWatcher() async throws {
        let host = DeviceAppsTests.Host()
        let apps = DeviceApps(host: host)
        var changes = 0
        let watch = AppChangeWatch(apps: apps, attachAllowed: { true }, onChange: { changes += 1 })
        let attaches = Attaches()
        watch.observe = { endpoint, _, change in
            attaches.state.withLock { $0.append((endpoint, change)) }
            try? await Task.sleep(for: .seconds(3600))  // the session stays open until the watcher stops
            return true
        }
        watch.start()
        await eventually("the first boot's watcher") { attaches.endpoints.count == 1 }
        #expect(attaches.endpoints.first?.session == host.bootScope.id)
        attaches.change(0)
        await eventually("its event") { changes == 1 }

        host.bootScope.renew()  // Restart in place: nothing tells the watch but the boot itself
        await eventually("the new boot's watcher") { attaches.endpoints.count == 2 }
        try #require(attaches.endpoints.count == 2)
        #expect(attaches.endpoints.last?.session == host.bootScope.id && watch.endpoint?.session == host.bootScope.id)
        attaches.change(0)  // the old boot's watcher, late
        attaches.change(1)
        await eventually("the new boot's event") { changes == 2 }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(changes == 2, "the old boot's event is dropped")

        host.bootScope.retire()  // Stop
        await eventually("no services, no watcher") { watch.endpoint == nil }
        watch.stop()
        host.bootScope.renew()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(watch.endpoint == nil && attaches.endpoints.count == 2, "stopped: no more boots followed")
    }
}
