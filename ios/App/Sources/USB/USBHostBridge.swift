import Foundation

// The USB host, as one thread that never gives up.
//
// Passing `usb-tcp-addr` to the emulator switches OFF the host QEMU otherwise runs in-process
// (synopsys_host_tick), so from that moment everything a host is supposed to do is this file's job. That is the
// part the earlier attempt got wrong: it tried the handshake once, a few seconds into the boot, and when that
// failed it went quiet for the rest of the session — leaving the guest with a cable that reports a host present
// and a host that never speaks.
//
// What a host has to keep doing:
//   * retry from the top, every few seconds, for as long as the device runs. The guest needs roughly 100 seconds of
//     boot before its driver has programmed the USB core, and until then every transaction is NAKed. That is
//     normal; QEMU's own built-in host restarts enumeration every 3 seconds until the guest answers.
//   * cope with the link coming and going. QEMU dials at realize and again on every USB core soft reset, so one
//     boot can produce several connections.
//   * once configured, keep polling the bulk IN endpoint. AppleUSBDeviceMux restarts the whole stack a few seconds
//     after activation if the host stays silent.
//
// Nothing here is allowed to be fatal. Any failure means "wait and start over".

final class USBHostBridge: @unchecked Sendable {
    enum Status: Equatable {
        case waiting           // listening; the emulator has not dialled in yet
        case bringingUp        // dialled in, driving reset/enumeration (normal for the first ~100 s of boot)
        case running           // configured, mux up, polling
        case retrying(String)  // last attempt failed; trying again shortly

        var text: String {
            switch self {
            case .waiting: return "waiting for the emulator"
            case .bringingUp: return "bringing the device up"
            case .running: return "connected"
            case .retrying(let why): return "retrying (\(why))"
            }
        }
    }

    let transport: TCPUSBTransport
    let mux = MuxDevice()
    /// Told when the status changes, on an arbitrary thread.
    var onStatus: (@Sendable (Status) -> Void)?

    private let lock = NSLock()
    private var statusValue: Status = .waiting
    private var stopped = false
    private var thread: Thread?
    private var attempts = 0
    private var lastFailure: String?
    private(set) var deviceSummary: String?

    /// How long the bridge has been in the running state, for the UI.
    private(set) var configuredAt: Date?

    init() throws {
        transport = try TCPUSBTransport()
    }

    /// The value for the emulator's `usb-tcp-addr` machine option.
    var qemuAddress: String { "127.0.0.1:\(transport.port)" }

    var status: Status {
        lock.lock()
        defer { lock.unlock() }
        return statusValue
    }

    func start() {
        transport.startAccepting()
        guard thread == nil else { return }
        let runner = Thread { [weak self] in self?.run() }
        runner.name = "ltm.usb.host"
        runner.stackSize = 512 * 1024
        thread = runner
        runner.start()
        LTMLog.note("usb: bridge listening on \(qemuAddress)")
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        mux.linkDropped(TCPUSBError.disconnected)
        transport.stop()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func set(_ status: Status) {
        lock.lock()
        let changed = statusValue != status
        statusValue = status
        lock.unlock()
        if changed { onStatus?(status) }
    }

    // MARK: - The loop

    private func run() {
        while !isStopped {
            guard transport.isConnected || transport.waitForConnection(timeout: 1) else {
                set(.waiting)
                continue
            }
            if isStopped { return }
            set(.bringingUp)
            do {
                let device = USBDevice(transport: transport)
                try device.enumerate()
                mux.setTransactionLimit(device.maxTransaction)
                mux.restart()
                deviceSummary = String(format: "%04x:%04x", device.descriptor.idVendor, device.descriptor.idProduct)
                configuredAt = Date()
                attempts = 0
                lastFailure = nil
                set(.running)
                try pump(device)
            } catch {
                report(error)
                mux.linkDropped(error)
                configuredAt = nil
                // The link may simply have gone (QEMU redials on a core soft reset); otherwise leave the guest
                // alone for a moment, exactly as the built-in host's restart delay does.
                if let usb = error as? TCPUSBError, case .disconnected = usb {
                    _ = transport.waitForConnection(timeout: 5)
                } else {
                    Thread.sleep(forTimeInterval: 3)
                }
            }
        }
    }

    /// Drives the configured device: send whatever the mux has queued, then poll the bulk IN endpoint. One thread
    /// owns the transport, so nothing else ever has to take a turn.
    private func pump(_ device: USBDevice) throws {
        var idleRounds = 0
        while !isStopped {
            var worked = false
            // Writes first: a service waiting on a reply should not sit behind a poll.
            var budget = 16
            while budget > 0, let packet = mux.nextOutbound() {
                try device.bulkOut(packet)
                worked = true
                budget -= 1
            }
            if let data = try device.bulkIn(), !data.isEmpty {
                mux.feed(data)
                worked = true
            }
            if worked {
                idleRounds = 0
            } else {
                // 5 ms is what QEMU's built-in host polls at; back off a little when nothing is going on so an
                // idle device costs almost nothing.
                idleRounds = min(idleRounds + 1, 20)
                usleep(idleRounds < 10 ? 5000 : 20000)
            }
        }
    }

    private func report(_ error: Error) {
        attempts += 1
        let text = (error as? CustomStringConvertible)?.description ?? "\(error)"
        set(.retrying(text))
        // The first failure is worth a line; after that only occasionally, or the log fills up with the NAKs that
        // are a normal part of waiting for the guest to boot.
        if text != lastFailure || attempts % 12 == 0 {
            LTMLog.note("usb: bring-up attempt \(attempts) did not take (\(text)); trying again")
            lastFailure = text
        }
    }

    // MARK: - Diagnostics

    /// Opens lockdown and asks who the device is. This is the end-to-end proof that the bridge works: transport,
    /// enumeration, mux version handshake, a TCP channel and a plist round trip. Returns a one-line summary.
    func probeLockdown(timeout: TimeInterval = 30) throws -> String {
        let pipe = try mux.connect(toPort: 62078, timeout: timeout)
        defer { pipe.close() }
        let lockdown = LockdownClient(pipe: pipe)
        try lockdown.query(timeout: timeout)
        var parts: [String] = []
        for key in ["ProductVersion", "ProductType", "DeviceName", "UniqueDeviceID"] {
            if let value = try? lockdown.value(key, timeout: timeout) { parts.append("\(key)=\(value)") }
        }
        let summary = parts.isEmpty ? "lockdown answered QueryType" : parts.joined(separator: ", ")
        LTMLog.note("usb: lockdown says \(summary)")
        return summary
    }
}
