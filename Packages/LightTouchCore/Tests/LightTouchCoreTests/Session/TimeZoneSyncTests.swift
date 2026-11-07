import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// The guest's zone follows the Mac's: set once the device is ready, retried until one try sticks, given up when
/// the device keeps its own; again when the Mac's zone changes, for this boot only. Serialized: the Mac's zone
/// change is a process-wide notification.
@Suite(.serialized) struct TimeZoneSyncTests {
    struct Transient: Error {}

    final class Host: TimeZoneHost {
        let bootScope = BootSessionScope()
        var state = VMState.running
        var shuttingDown = false, isDead = false, isPoweredOff = false, preparingDevice = false, canManageApps = true
        var ready = false
        var answers: [Error?] = []
        var sets: [String] = []
        func deviceReady() async -> Bool { ready }
        func setGuestTimeZone(_ identifier: String) async throws {
            sets.append(identifier)
            if !answers.isEmpty, let error = answers.removeFirst() { throw error }
        }
    }

    func sync(_ host: Host) -> TimeZoneSync {
        let sync = TimeZoneSync(host: host)
        sync.retryInterval = .milliseconds(5)
        return sync
    }

    func settle() async { try? await Task.sleep(for: .milliseconds(40)) }

    @Test func waitsForTheDeviceThenSetsUntilOneSticks() async {
        let host = Host()
        let sync = sync(host)
        host.answers = [Transient(), nil]
        sync.start()
        await settle()
        #expect(host.sets.isEmpty, "not before the device is ready")
        host.ready = true
        await eventually("set") { host.sets.count == 2 }
        await settle()
        #expect(
            host.sets == [TimeZone.current.identifier, TimeZone.current.identifier],
            "a transient failure is retried, a success ends it"
        )
        sync.stop()
    }

    @Test func aZoneTheDeviceKeepsIsLeft() async {
        let host = Host()
        host.ready = true
        host.answers = [DeviceToolsError.zoneKept("America/Los_Angeles")]
        let sync = sync(host)
        sync.start()
        await eventually("tried") { host.sets.count == 1 }
        await settle()
        #expect(host.sets.count == 1)
        sync.stop()
    }

    @Test func theMacsZoneChangeSyncsAgainForThisBootOnly() async {
        let host = Host()
        host.ready = true
        let sync = sync(host)
        sync.start()
        await eventually("the first sync") { host.sets.count == 1 }
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        await eventually("travel") { host.sets.count == 2 }
        sync.stop()
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        await settle()
        #expect(host.sets.count == 2, "stopped: the Mac's change is ignored")

        sync.start()
        await eventually("a new boot syncs") { host.sets.count == 3 }
        host.bootScope.renew()
        NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        sync.schedule(generation: host.bootScope.generation - 1)
        await settle()
        #expect(host.sets.count == 3, "a retired boot's observers and syncs do nothing")
        host.state = .booting
        sync.resync()
        await settle()
        #expect(host.sets.count == 3, "not until it runs")
        host.state = .running
        await eventually("then it does") { host.sets.count == 4 }
        sync.stop()
    }
}
