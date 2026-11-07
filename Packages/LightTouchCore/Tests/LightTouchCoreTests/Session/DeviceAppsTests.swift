import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// App management's gates: usbmuxd and storage for managing apps, a real round trip for commands, and for the
/// install queue also our own install holding the device; services only for a live boot; the Home screen's
/// answer only where springboardservices exists.
struct DeviceAppsTests {
    final class Host: AppsHost {
        let bootScope = BootSessionScope()
        let profile = Board.n72
        var iosVersion = "3.1.3"
        var usbmuxSession: String? = "UNIX:/tmp/ltm-tests-none.sock"
        var guestUDID: String?
        var storageFailed = false, isRunning = true, isPoweredOff = false, shuttingDown = false
        var deviceReachable: Bool? = true
        var installerUsesDevice = false
        let guestAgent = GuestAgent(cache: GuestAgentCache())
        var guest: GuestServices { GuestServices(agent: guestAgent) }
    }

    @Test func commandsNeedARoundTripTheQueueOnlyALiveDevice() async {
        let host = Host()
        let apps = DeviceApps(host: host)
        #expect(apps.canManageApps && apps.canReachDevice && apps.canQueueInstall)

        host.deviceReachable = nil  // the inspector's reads stand aside, or the first one hasn't landed
        #expect(apps.canManageApps && !apps.canReachDevice && !apps.canQueueInstall)
        host.installerUsesDevice = true
        #expect(!apps.canReachDevice && apps.canQueueInstall, "an install holding the device still takes more")
        host.installerUsesDevice = false
        await apps.holdingDevice {
            #expect(apps.isInstalling && apps.canQueueInstall && !apps.canReachDevice)
        }
        #expect(!apps.isInstalling && !apps.canQueueInstall)

        host.deviceReachable = true
        for (name, change) in [
            ("not running", { host.isRunning = false }),
            ("storage failed", { host.storageFailed = true }), ("no usbmuxd", { host.usbmuxSession = nil })
        ] {
            change()
            #expect(!apps.canReachDevice && !apps.canQueueInstall, "\(name)")
            host.isRunning = true
            host.storageFailed = false
            host.usbmuxSession = "UNIX:/tmp/x.sock"
            #expect(apps.canReachDevice)
        }
        host.storageFailed = true
        #expect(!apps.canManageApps)
    }

    @Test func servicesOnlyForALiveBootWithUSBMux() throws {
        let host = Host()
        let apps = DeviceApps(host: host)
        let services = try apps.services
        #expect(services.clientSocket == host.usbmuxSession)
        host.usbmuxSession = nil
        #expect(throws: DeviceToolsError.self) { try apps.services }
        host.usbmuxSession = "UNIX:/tmp/x.sock"
        host.bootScope.retire()
        #expect(throws: DeviceToolsError.self) { try apps.installPipeline }
    }

    @Test func refusalsHappenBeforeTouchingTheDevice() async throws {
        let host = Host()
        let apps = DeviceApps(host: host)
        host.isPoweredOff = true
        host.isRunning = false
        await #expect(throws: DeviceError.self) { try await apps.checkDeviceConnection() }
        #expect(await !apps.deviceReady())
        await #expect(throws: DeviceToolsError.self) {
            try await apps.importMedia(
                .photo(
                    MediaPhoto(
                        id: "p",
                        directory: URL(fileURLWithPath: "/nonexistent"),
                        image: URL(fileURLWithPath: "/nonexistent/p.jpg"),
                        title: "p"
                    )
                ),
                progress: { _ in },
                willCommit: { Issue.record("committed") }
            )
        }
        host.isRunning = false
        try await apps.restartSpringBoard()  // not running: nothing to restart
        #expect(!apps.restartingSpringBoard)
    }

    @Test func theHomeScreenAnswersOnlyFromThreeOneOn() async throws {
        let host = Host()
        let apps = DeviceApps(host: host)
        #expect(apps.hasSpringBoardServices)
        for version in ["1.0", "1.1.4", "2.2.1", "3.0"] {
            host.iosVersion = version
            #expect(!apps.hasSpringBoardServices)
            try await apps.waitForSpringBoard()  // returns at once: lockdown answering is as ready as it gets
        }
        host.iosVersion = "3.1"
        #expect(apps.hasSpringBoardServices)
    }
}
