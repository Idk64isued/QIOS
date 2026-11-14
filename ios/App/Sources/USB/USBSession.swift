import Foundation

/// One USB session per emulator launch. Opens a TCP listener on 127.0.0.1 before the guest boots; the emulator is
/// passed `usb-tcp-addr=127.0.0.1:<port>` in its machine options and dials in when its USB core comes up.
/// Then the app can use this session to run USB operations on the device.
@MainActor
final class USBSession: ObservableObject {
    @Published private(set) var state: State = .waiting
    @Published private(set) var lastError: String?

    enum State: Equatable {
        case waiting           // listener up, guest hasn't connected yet
        case connected         // QEMU dialled in; USB bridge running
        case enumerated        // device descriptors read, mux interface found
        case failed(String)
    }

    let transport: TCPUSBTransport
    /// The address to pass to QEMU in its machine options (`usb-tcp-addr=`).
    let qemuAddress: String
    private var device: USBDevice?
    private var mux: USBMuxClient?

    init() throws {
        let transport = try TCPUSBTransport()
        self.transport = transport
        let port = try transport.start()
        self.qemuAddress = "127.0.0.1:\(port)"
        LTMLog.note("usb: listening on \(qemuAddress)")
    }

    /// Call after the emulator has started. Blocks on a background thread until QEMU connects or times out.
    func waitForGuest() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            // The guest needs ~100 s to program its USB core; be patient.
            let ok = self.transport.waitForConnection(timeout: 180)
            await MainActor.run { self.state = ok ? .connected : .failed("Guest never dialled the USB bridge.") }
            guard ok else { return }
            // Try enumeration — on a cold boot it may NAK for a while.
            let device = USBDevice(transport: self.transport)
            do {
                try device.enumerate(timeout: 120)
                await MainActor.run {
                    self.device = device
                    self.mux = USBMuxClient(device: device)
                    self.state = .enumerated
                }
            } catch {
                LTMLog.note("usb: enumerate failed: \(error)")
                await MainActor.run { self.lastError = "\(error)"; self.state = .failed("USB enumeration failed: \(error)") }
            }
        }
    }

    func stop() {
        transport.stop()
    }

    // MARK: - IPA install over USB

    /// Install an IPA, no guest agent needed. Uploads via AFC to PublicStaging/<name>.ipa, then calls
    /// installation_proxy. Returns once the device reports Status=Complete.
    nonisolated func install(ipa url: URL, onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        try await Task.detached { [weak self] in
            guard let self else { throw USBInstallerError.sessionGone }
            guard let device = await self.device, let mux = await self.mux else {
                throw USBInstallerError.notReady
            }

            // 1. lockdown on 62078
            onProgress(0.02, "Opening lockdown\u{2026}")
            let lockdownPipe = try mux.connect(toPort: 62078)
            let lockdown = LockdownClient(pipe: lockdownPipe)
            try lockdown.query()

            // 2. afc service
            onProgress(0.05, "Starting afc\u{2026}")
            let afcService = try lockdown.startService("com.apple.afc")
            if afcService.enableSSL { throw USBInstallerError.needsSSL(afcService.name) }
            // Each service goes on its own mux channel.
            let afcPipe = try mux.connect(toPort: afcService.port)
            let afc = AFCClient(pipe: afcPipe)
            _ = device  // keep the handle alive for the duration

            // 3. upload to PublicStaging/<name>.ipa
            let remote = "PublicStaging/" + url.lastPathComponent
            try? afc.makeDir("PublicStaging")
            onProgress(0.10, "Uploading \(url.lastPathComponent)\u{2026}")
            try afc.upload(url, to: remote) { fraction in
                onProgress(0.10 + fraction * 0.6, "Uploading " + String(format: "%.0f", fraction * 100) + "%")
            }

            // 4. installation_proxy
            onProgress(0.72, "Starting installation_proxy\u{2026}")
            let proxyService = try lockdown.startService("com.apple.mobile.installation_proxy")
            if proxyService.enableSSL { throw USBInstallerError.needsSSL(proxyService.name) }
            let proxyPipe = try mux.connect(toPort: proxyService.port)
            let proxy = InstallProxyClient(pipe: proxyPipe)
            try proxy.install(afcPath: remote) { fraction, status in
                onProgress(0.75 + fraction * 0.25, status ?? "Installing\u{2026}")
            }
            onProgress(1.0, "Installed")
        }.value
    }
}

enum USBInstallerError: Error, CustomStringConvertible {
    case sessionGone
    case notReady
    case needsSSL(String)

    var description: String {
        switch self {
        case .sessionGone: return "The USB session ended."
        case .notReady: return "The USB bridge isn\u{2019}t ready yet. Give the device a minute after boot."
        case .needsSSL(let n): return "\(n) needs an SSL-paired channel; this device needs to be paired on a Mac first."
        }
    }
}
