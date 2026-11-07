import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// The device's web proxy: changeable only once a boot wrote its routing, each change applied to the guest once
/// (waiting, applying, then what the guest's setup reports), a failure said once, and a later boot or a
/// cancellation ending the watch.
struct DeviceWebProxyTests {
    struct SetupFailed: Error {}

    @Test func aChangeWaitsForTheRoutingThenAppliesOnce() async throws {
        try await withScratchDirectory { directory in
            let proxy = DeviceWebProxy(directory: { directory }, shortName: "iPod")
            let off = WebProxyConfiguration(mode: .off)
            #expect(throws: DeviceToolsError.self) { try proxy.configure(off) }
            #expect(
                try await proxy.apply(since: nil, isCurrent: { true }) { _ in .ready } == nil,
                "no routing yet: nothing applied"
            )

            let forward = try #require(proxy.forward())
            #expect(
                proxy.available && proxy.endpoint != nil
                    && forward == WebProxyConfiguration.guestForward(socket: proxy.endpoint!.socket)
            )
            var asked: [Bool] = []
            var applied = try await proxy.apply(since: nil, isCurrent: { true }) { enabled in
                #expect(proxy.status == .applying)
                asked.append(enabled)
                return .ready
            }
            #expect(applied == 0 && asked == [true] && proxy.status == .ready, "the boot's routing, on by default")
            applied = try await proxy.apply(since: applied, isCurrent: { true }) { _ in
                Issue.record("applied twice")
                return .ready
            }

            #expect(observes({ _ = proxy.status }) { try? proxy.configure(off) }, "the editor's line follows")
            #expect(proxy.status == .waiting && WebProxyConfiguration.load(from: directory).mode == .off)
            applied = try await proxy.apply(since: applied, isCurrent: { true }) { enabled in
                asked.append(enabled)
                return .needsTap
            }
            #expect(applied == 1 && asked == [true, false] && proxy.status == .needsTap)
        }
    }

    @Test func aFailureIsSaidAndRetriedAChangeMidwayWaits() async throws {
        try await withScratchDirectory { directory in
            let proxy = DeviceWebProxy(directory: { directory }, shortName: "iPod")
            _ = proxy.forward()
            var applied = try await proxy.apply(since: nil, isCurrent: { true }) { _ in throw SetupFailed() }
            #expect(applied == nil && proxy.status == .failed)
            applied = try await proxy.apply(since: applied, isCurrent: { true }) { _ in .ready }
            #expect(applied == 0 && proxy.status == .ready, "the next pass tries again")

            try proxy.configure(WebProxyConfiguration())
            applied = try await proxy.apply(since: applied, isCurrent: { true }) { _ in
                try proxy.configure(WebProxyConfiguration())  // changed again while the guest was set up
                return .ready
            }
            #expect(applied == 0 && proxy.status == .waiting, "the newer change is still to apply")

            await #expect(throws: CancellationError.self) {
                _ = try await proxy.apply(since: applied, isCurrent: { false }) { _ in .ready }
            }
            #expect(proxy.status == .applying, "a later boot's watch owns the status now")
        }
    }

    @Test func routingThatCantBeWrittenFails() {
        let proxy = DeviceWebProxy(directory: { URL(fileURLWithPath: "/nonexistent/ltm-tests") }, shortName: "iPod")
        #expect(proxy.forward() == nil && !proxy.available && proxy.status == .failed && proxy.endpoint == nil)
    }
}
