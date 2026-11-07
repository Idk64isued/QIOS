import CIMobileDevice
import Foundation
import HostServiceWire
import Testing

@testable import Engine

/// The attachment check's one call: idevice_new over the gate-selected endpoint, attached unless told otherwise.
nonisolated enum Attachment {
    static let lock = NSLock()
    nonisolated(unsafe) static var attached = true
    static func set(attached value: Bool) { lock.withLock { attached = value } }
    static func install() {
        IMDFake.ideviceNew = { device, _ in
            precondition(
                String(cString: getenv("USBMUXD_SOCKET_ADDRESS")) == "fixture",
                "gate did not select the endpoint before the attachment call"
            )
            guard lock.withLock({ attached }) else { return IDEVICE_E_NO_DEVICE }
            device?.pointee = OpaquePointer(bitPattern: 1)
            return IDEVICE_E_SUCCESS
        }
    }
}
/// Resumes one waiter once, whichever side comes first.
nonisolated final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false, waiter: CheckedContinuation<Void, Never>?
    func fire() {
        let w: CheckedContinuation<Void, Never>? = lock.withLock {
            fired = true
            defer { waiter = nil }
            return waiter
        }
        w?.resume()
    }
    func wait() async {
        await withCheckedContinuation { c in
            if lock.withLock({
                if fired { return true }
                waiter = c
                return false
            }) {
                c.resume()
            }
        }
    }
}

extension SharedState {
    /// The services engine's connection probe (DeviceServices+Engine's checkAttachment) over the fake idevice_new: a
    /// typed not-attached failure, a probe queued behind a long write times out as "USB connection" and leaves the gate
    /// without abandoning a C call, and cancellation is prompt. The inspector's read suppression is AppsInspectorRowsTests'.
    @Suite struct EngineHealthTests {
        /// The app gone: the services helper's event and log pipes have no reader. A write there is dropped, not an
        /// NSFileHandleOperationException (Broken pipe) that aborts the helper (SIGPIPE ignored, as libimobiledevice
        /// callers commonly do).
        @Test func outputToAPipeWithNoReader() throws {
            signal(SIGPIPE, SIG_IGN)
            let pipe = Pipe()
            try pipe.fileHandleForReading.close()
            EventWriter(handle: pipe.fileHandleForWriting).send(
                HostServiceEvent(id: UUID(), session: UUID(), payload: .result(.none))
            )
            writeDroppingClosedPipe(Data("log\n".utf8), to: pipe.fileHandleForWriting)
            try pipe.fileHandleForWriting.close()
        }

        @Test func attachmentProbe() async throws {
            let probe = Timeouts.serviceProbe
            let newDevice = IMDFake.ideviceNew
            defer {
                Timeouts.serviceProbe = probe
                IMDFake.ideviceNew = newDevice
            }
            Timeouts.serviceProbe = 0.015
            Attachment.install()
            let device = DeviceServices(clientSocket: "fixture")
            try await device.checkAttachment()
            Attachment.set(attached: false)
            do {
                try await device.checkAttachment()
                Issue.record("no error")
            } catch DeviceError.notAttached {} catch { throw error }
            Attachment.set(attached: true)

            // A probe waiting behind a long write must time out, leave the gate queue,
            // and retain a USB-specific cause instead of resetting app services.
            let held = Signal()
            let entered = Signal()
            let owner = Task {
                try await DeviceGate.shared.serialized {
                    entered.fire()
                    await held.wait()
                }
            }
            await entered.wait()
            do {
                try await device.checkAttachment()
                Issue.record("no error")
            } catch DeviceError.timedOut(let operation) { #expect(operation == "USB connection") } catch { throw error }
            #expect(AbandonedWork.count == 0, "waiting is not a blocked C request")
            held.fire()
            try await owner.value
            try await device.checkAttachment()

            let cancelled = Task { try await device.checkAttachment() }
            cancelled.cancel()
            do {
                try await cancelled.value
                Issue.record("no error")
            } catch is CancellationError {} catch { throw error }
        }

        /// A device's plist is converted only within IMobileDevice's node and byte limits: one whose shared references
        /// stand for millions of nodes (a few kilobytes as a binary plist) decodes to nil without being written out,
        /// as does one whose strings and data together are over the byte limit; an ordinary reply decodes as before.
        @Test func devicePlistsAreDecodedWithinLimits() {
            func decoded(_ value: Any) -> Any? {
                let node = IMDFake.node(value)
                defer { fakePlistFree(node) }
                return IMobileDevice.decode(node)
            }
            var shared: [Any] = ["x"]
            for _ in 0..<22 { shared = [shared, shared] }  // 2^22 leaves over 23 objects
            #expect(decoded(shared) == nil)
            let wide = Array(repeating: Data(count: 1 << 20), count: 40)  // 40 MiB behind one Data
            #expect(decoded(wide) == nil)
            let apps: [Any] = [["CFBundleIdentifier": "com.example.a", "Version": 1, "Icons": [Data(count: 8)]]]
            #expect((decoded(apps) as? [[String: Any]])?.first?["CFBundleIdentifier"] as? String == "com.example.a")
        }
    }
}
