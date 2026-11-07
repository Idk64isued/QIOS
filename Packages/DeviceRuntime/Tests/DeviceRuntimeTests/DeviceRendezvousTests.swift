import Foundation
import Testing

@testable import DeviceRuntime

private final class BundleAnchor {}

struct DeviceRendezvousTests {
    /// RendezvousTestPeer, built beside this test bundle.
    private let peer = Bundle(for: BundleAnchor.self).bundleURL
        .deletingLastPathComponent().appendingPathComponent("RendezvousTestPeer")

    /// A helper that sends its hello and then exits (a lease refusal, a missing dylib) has no
    /// code to check any more. Its hello is dropped, not rejected, so the link reports the
    /// helper's own answer instead of a signing failure; a live peer is still checked.
    @Test func aPeerThatExitedIsDroppedAndALivePeerIsStillChecked() async throws {
        let server = DeviceRendezvousServer.shared
        #expect(server.start() == 0)
        let requirement = try #require(DeviceRendezvous.defaultRequirement(helper: peer))
        let rejections = AsyncStream<(pid_t, String)>.makeStream()
        func registration(_ pid: @escaping () -> pid_t, requirement: String) -> DeviceRendezvousServer.Registration {
            .init(
                token: "token",
                requirement: requirement,
                deliver: { _ in },
                reject: { rejections.continuation.yield((pid(), $0)) }
            )
        }
        func spawn(_ mode: String) -> pid_t {
            let process = Process()
            process.executableURL = peer
            process.arguments = [server.serviceName, "token", mode]
            guard (try? process.run()) != nil else { return -1 }
            if mode == "exit" { process.waitUntilExit() }
            return process.processIdentifier
        }

        // Spawned and reaped under the server's lock: its hello is read only once it is gone.
        nonisolated(unsafe) var gone: pid_t = 0
        gone = server.spawnAndRegister(
            { spawn("exit") },
            registration: registration({ gone }, requirement: requirement)
        )
        #expect(gone > 0)
        // Queued behind it: a live peer whose code doesn't satisfy its requirement.
        nonisolated(unsafe) var live: pid_t = 0
        live = server.spawnAndRegister(
            { spawn("stay") },
            registration: registration({ live }, requirement: "identifier \"not.the.helper\"")
        )
        defer {
            kill(live, SIGKILL)
            server.unregister(gone)
            server.unregister(live)
        }
        #expect(live > 0)

        var iterator = rejections.stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.0 == live)
        #expect(first?.1.hasPrefix("code signing requirement failed") == true)
    }
}
