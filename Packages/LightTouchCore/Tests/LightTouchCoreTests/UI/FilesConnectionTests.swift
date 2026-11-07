import Foundation
import HostServiceWire
import Testing

@testable import LightTouchCore

/// The Files window binds to one device's boot: a copy keeps it there whatever the selection or the reachability
/// reads, only the copying device reads as transferring, and the binding is the boot's own endpoint, renewed with it.
struct FilesConnectionTests {
    let a = UUID(), b = UUID()
    let endpointA = HostServiceEndpoint(socket: "UNIX:/tmp/a.sock", udid: "a", session: UUID())
    let endpointB = HostServiceEndpoint(socket: "UNIX:/tmp/b.sock", udid: "b", session: UUID())

    @Test func aCopyKeepsItsBindingAndUnknownReachabilityKeepsTheBoot() {
        let files = FilesConnection()
        #expect(files.follow(device: a, endpoint: endpointA, reachable: true))
        #expect(!files.follow(device: a, endpoint: endpointA, reachable: nil), "reads held back: the boot is kept")
        #expect(files.state == .connected(.init(device: a, endpoint: endpointA)))
        files.follow(device: b, endpoint: endpointB, reachable: nil)
        #expect(files.state == .disconnected, "unknown never binds another boot")
        files.follow(device: a, endpoint: endpointA, reachable: true)

        files.setTransferring(true)
        let copying = FilesConnection.State.transferring(.init(device: a, endpoint: endpointA))
        for (device, endpoint, reachable) in [
            (a, endpointA, nil), (a, nil, false), (b, endpointB, true), (nil, nil, nil)
        ] as [(UUID?, HostServiceEndpoint?, Bool?)] {
            #expect(!files.follow(device: device, endpoint: endpoint, reachable: reachable))
            #expect(files.state == copying, "the copy's binding holds: \(String(describing: device))")
        }
        files.setTransferring(false)
        #expect(files.state == .connected(.init(device: a, endpoint: endpointA)))
        #expect(files.follow(device: b, endpoint: endpointB, reachable: true), "after the copy, the selection")
        #expect(files.binding?.device == b)
        #expect(files.follow(device: b, endpoint: endpointB, reachable: false) && files.state == .disconnected)
        files.setTransferring(true)
        #expect(files.state == .disconnected, "nothing to copy from")
    }

    @Test func onlyTheCopyingDeviceIsTransferring() {
        let files = FilesConnection()
        files.follow(device: a, endpoint: endpointA, reachable: true)
        files.setTransferring(true)
        files.follow(device: b, endpoint: endpointB, reachable: true)  // B selected mid-copy
        #expect(files.isTransferring(a) && !files.isTransferring(b))
        files.setTransferring(false)
        #expect(!files.isTransferring(a) && !files.isTransferring(b), "the end of the copy clears A, not B")
    }

    @Test func filesUseTheBootsEndpointAndFollowItsRenewal() {
        let host = DeviceAppsTests.Host()
        host.guestUDID = "udid"
        let apps = DeviceApps(host: host)
        let files = FilesConnection()
        let first = HostServiceEndpoint(socket: host.usbmuxSession!, udid: "udid", session: host.bootScope.id)
        #expect(apps.filesEndpoint == first && apps.filesReachable == true)
        files.follow(device: a, endpoint: apps.filesEndpoint, reachable: apps.filesReachable)
        host.bootScope.renew()  // Restart in place
        #expect(apps.filesEndpoint?.session == host.bootScope.id && apps.filesEndpoint != first)
        #expect(files.follow(device: a, endpoint: apps.filesEndpoint, reachable: apps.filesReachable))
        #expect(files.binding?.endpoint == apps.filesEndpoint, "the new boot's endpoint, retired with it")
        host.deviceReachable = nil
        #expect(apps.filesReachable == nil)
        host.deviceReachable = false
        #expect(apps.filesReachable == false)
        host.deviceReachable = nil
        host.isRunning = false
        #expect(apps.filesReachable == false)
        host.bootScope.retire()
        #expect(apps.filesEndpoint == nil)
    }
}
