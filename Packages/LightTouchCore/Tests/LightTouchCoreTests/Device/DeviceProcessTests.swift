import DeviceRuntime
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// The shared session owner (DeviceRuntime's DeviceSessionProcess) and the app's adapter around it (DeviceProcess):
/// a helper's death classified by what was asked of it, the row's three labels, the link's last frame, and the
/// boot's storage admission (preparation) with its lease, cancellation and exactly-once completion.
struct DeviceProcessTests {
    @Test func exitsAreClassifiedByWhatWasAsked() {
        // (start failure, QEMU's exit, stop asked, the app sent SIGKILL, termination) -> death
        let cases: [(DeviceLinkError?, Int32?, Bool, Bool, DeviceTermination, DeviceProcessDeath)] = [
            (nil, 0, true, false, .exited(0), .stopped),
            (nil, nil, true, false, .exited(0), .stopped),
            (nil, nil, false, false, .exited(0), .unexpected),
            (nil, nil, false, false, .signaled(11), .unexpected),
            (nil, nil, false, false, .exited(70), .unexpected),
            (nil, 1, false, false, .exited(1), .unexpected),
            (nil, nil, false, false, .signaled(9), .unexpected),
            (.helperFailure("not booted"), 0, true, false, .exited(0), .startFailed(.helperFailure("not booted"))),
            (nil, nil, true, false, .signaled(9), .unexpected),
            (nil, nil, true, false, .unknown, .unexpected),
            // The app's own SIGKILL (release() before storage changes, a halt past its budget) is a stop, with or
            // without the SIGTERM before it; anything else after it is still what it was.
            (nil, nil, true, true, .signaled(9), .stopped),
            (nil, nil, false, true, .signaled(9), .stopped),
            (nil, nil, true, true, .signaled(11), .unexpected),
            (nil, nil, true, true, .exited(70), .unexpected),
            (nil, nil, true, true, .unknown, .unexpected),
            (.helperFailure("not booted"), nil, true, true, .signaled(9), .startFailed(.helperFailure("not booted")))
        ]
        for (failure, code, requested, killed, termination, expected) in cases {
            #expect(
                DeviceProcessDeath.classify(
                    startFailure: failure,
                    qemuExitCode: code,
                    stopRequested: requested,
                    killRequested: killed,
                    termination: termination
                ) == expected,
                "\(termination) requested=\(requested) killed=\(killed)"
            )
        }
    }

    @Test(arguments: [Board.n45, .n72, .k48])
    func theRowsThreeLabelsAndTheLeaseRefusal(_ profile: Board) {
        #expect(DeviceProcess.reason(.stopped, profile: profile) == profile.stoppedReason)
        #expect(DeviceProcess.reason(.unexpected, profile: profile) == "The \(profile.shortName) stopped unexpectedly.")
        #expect(
            DeviceProcess.reason(.startFailed(.helperFailure("not booted")), profile: profile)
                == "The \(profile.shortName) didn’t start."
        )
        #expect(
            DeviceProcess.reason(.startFailed(.helperFailure(DeviceLinkWire.leaseRefusal)), profile: profile)
                == DeviceLinkWire.leaseRefusal
        )
    }

    final class Received: @unchecked Sendable {
        let lock = NSLock()
        var got: [String] = []
        var closedAfter = -1
    }

    @Test func aReapedHelpersLastFrameIsDeliveredOnceBeforeClose() throws {
        for _ in 0..<50 {
            var sv: [Int32] = [-1, -1]
            #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0)
            let queue = DispatchQueue(label: "link")
            let received = Received()
            let channel = LinkChannel<HelperMessage, AppMessage>(
                fd: sv[0],
                queue: queue,
                onMessage: {
                    if case .event(.qemuExited(let rc)) = $0 {
                        received.lock.withLock { received.got.append("exit \(rc)") }
                    }
                },
                onClose: { _ in received.lock.withLock { received.closedAfter = received.got.count } }
            )
            // The helper: its last message, then exit (the peer end closes).
            let frame = try LinkChannel<AppMessage, HelperMessage>.frame(.event(.qemuExited(0)))
            _ = frame.withUnsafeBytes { write(sv[1], $0.baseAddress, $0.count) }
            close(sv[1])
            // Reaped on the link's queue before the read source had its turn (or after: either way once).
            queue.sync { channel.drainIncoming() }
            channel.close()
            queue.sync {}
            let (got, closedAfter) = received.lock.withLock { (received.got, received.closedAfter) }
            #expect(got == ["exit 0"] && closedAfter == 1, "delivered \(got), closed after \(closedAfter)")
        }
    }

    enum Failure: Error { case controlled }

    @Test func aFailedAdmissionNeverSpawnsAndReleasesItsLease() async throws {
        try await withScratchDirectory { dir in
            let leasePath = dir.appendingPathComponent("work/lease")
            var configuration = DeviceLink.Configuration(instance: UUID())
            configuration.helper = dir.appendingPathComponent("must-not-spawn")
            let failed = DeviceSessionProcess(configuration: configuration)
            var completions = 0
            var deaths = 0
            var configured = false
            var wrongFailure = false
            failed.onDeath = { _ in deaths += 1 }
            failed.start(
                { _ in
                    configured = true
                    return nil
                },
                preparation: {
                    let lease = try StorageLease(leasePath)
                    defer { lease.close() }
                    // admission holds exclusion
                    #expect(throws: StorageLease.Failure.inUse) { _ = try StorageLease(leasePath) }
                    throw Failure.controlled
                }
            ) { result in
                completions += 1
                guard case .failure(.helperFailure(let message)) = result, message.contains("controlled") else {
                    wrongFailure = true
                    return
                }
            }
            #expect(await failed.waitForExit(timeout: 3))
            #expect(completions == 1 && deaths == 1 && !configured && !wrongFailure && failed.link.pid == 0)
            let after = try StorageLease(leasePath)
            after.close()
        }
    }

    @Test(arguments: [false, true])
    func stopOrKillDuringAdmissionCancelsItCleanly(_ kill: Bool) async throws {
        try await withScratchDirectory { dir in
            let leasePath = dir.appendingPathComponent("work/lease")
            var configuration = DeviceLink.Configuration(instance: UUID())
            configuration.helper = dir.appendingPathComponent("must-not-spawn")
            let stopped = DeviceSessionProcess(configuration: configuration)
            var release: CheckedContinuation<Void, Never>?
            var entered = false
            var completions = 0
            var deaths: [DeviceProcessDeath] = []
            var configured = false
            var succeeded = false
            stopped.onDeath = { deaths.append($0) }
            stopped.start(
                { _ in
                    configured = true
                    return nil
                },
                preparation: {
                    let lease = try StorageLease(leasePath)
                    defer { lease.close() }
                    entered = true
                    // Even an operation which returns after cancellation cannot spawn later.
                    await withCheckedContinuation { release = $0 }
                }
            ) { result in
                completions += 1
                if case .failure(.closed) = result {} else { succeeded = true }
            }
            await eventually("admission entered") { entered }
            if kill { stopped.kill() } else { stopped.terminate() }
            #expect(stopped.link.pid == 0 && !stopped.isDead)
            // Stop can't abandon active ownership
            #expect(throws: StorageLease.Failure.inUse) { _ = try StorageLease(leasePath) }
            release!.resume()
            #expect(await stopped.waitForExit(timeout: 3))
            #expect(completions == 1 && deaths == [.stopped] && !configured && !succeeded && stopped.link.pid == 0)
            let after = try StorageLease(leasePath)
            after.close()
            var duplicate = 0
            var duplicateConfigured = false
            stopped.start({ _ in
                duplicateConfigured = true
                return nil
            }) { result in
                if case .failure(.closed) = result { duplicate += 1 }
            }
            #expect(duplicate == 1 && deaths.count == 1 && !duplicateConfigured, "no second start")
        }
    }
}
