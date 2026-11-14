import Foundation

/// One USB session per emulator launch: a listener the emulator dials into, and the host that drives whatever
/// answers. The listener has to exist before the emulator starts, because `usb-tcp-addr` is a machine option.
@MainActor
final class USBSession: ObservableObject {
    enum State: Equatable {
        case waiting                // listening; the emulator has not dialled in
        case bringingUp             // driving reset and enumeration (normal while the guest boots)
        case ready                  // device configured and the mux is up
        case retrying(String)       // last attempt failed; the bridge keeps trying

        var text: String {
            switch self {
            case .waiting: return "Waiting for the device"
            case .bringingUp: return "Bringing the device up"
            case .ready: return "Connected"
            case .retrying: return "Trying again"
            }
        }
    }

    @Published private(set) var state: State = .waiting
    @Published private(set) var detail: String?

    let bridge: USBHostBridge
    /// What the emulator is told to dial.
    let qemuAddress: String

    init() throws {
        let bridge = try USBHostBridge()
        self.bridge = bridge
        self.qemuAddress = bridge.qemuAddress
        bridge.onStatus = { [weak self] status in
            Task { @MainActor in self?.apply(status) }
        }
    }

    private func apply(_ status: USBHostBridge.Status) {
        switch status {
        case .waiting: state = .waiting
        case .bringingUp: state = .bringingUp
        case .running:
            state = .ready
            detail = bridge.deviceSummary
            // The device came up, so this boot was not a strike (see Emulator.boot).
            UserDefaults.standard.set(0, forKey: "usbStrikes")
        case .retrying(let why):
            state = .retrying(why)
            detail = why
        }
    }

    /// Starts listening and driving. Safe to call before the emulator exists.
    func start() { bridge.start() }

    func stop() { bridge.stop() }

    /// Asks the device who it is over lockdown. Proves the whole path end to end.
    func probe() async -> String? {
        let bridge = self.bridge
        return await Task.detached(priority: .utility) { () -> String? in
            do {
                return try bridge.probeLockdown()
            } catch {
                LTMLog.note("usb: lockdown probe failed: \(error)")
                return nil
            }
        }.value
    }

    // MARK: - IPA install over USB

    /// Uploads an IPA with AFC and installs it with installation_proxy, the way libimobiledevice does it.
    ///
    /// lockdown gates most services behind a pairing record and, from iOS 4 on, an SSL session. A prepared image
    /// here has never been paired with anything, so when the device asks for that this throws and the caller falls
    /// back to the guest agent. A jailbroken image is the good case: its afc2 service runs at / and takes an
    /// unauthenticated channel.
    func install(ipa url: URL, onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        let bridge = self.bridge
        try await Task.detached(priority: .userInitiated) {
            onProgress(0.02, "Opening lockdown\u{2026}")
            let lockdownPipe = try bridge.mux.connect(toPort: 62078, timeout: 30)
            defer { lockdownPipe.close() }
            let lockdown = LockdownClient(pipe: lockdownPipe)
            try lockdown.query()

            // afc2 (the jailbreak's, rooted at /) if it is there, else the stock one.
            onProgress(0.05, "Starting afc\u{2026}")
            let afcService = try lockdown.startAnyService(["com.apple.afc2", "com.apple.afc"])
            if afcService.enableSSL { throw USBInstallerError.needsSSL(afcService.name) }
            let afcPipe = try bridge.mux.connect(toPort: afcService.port, timeout: 30)
            defer { afcPipe.close() }
            let afc = AFCClient(pipe: afcPipe)

            let remote = "PublicStaging/" + url.lastPathComponent
            try? afc.makeDir("PublicStaging")
            onProgress(0.10, "Uploading \(url.lastPathComponent)\u{2026}")
            try afc.upload(url, to: remote) { fraction in
                onProgress(0.10 + fraction * 0.6, "Uploading " + String(format: "%.0f", fraction * 100) + "%")
            }

            onProgress(0.72, "Starting installation_proxy\u{2026}")
            let proxyService = try lockdown.startService("com.apple.mobile.installation_proxy")
            if proxyService.enableSSL { throw USBInstallerError.needsSSL(proxyService.name) }
            let proxyPipe = try bridge.mux.connect(toPort: proxyService.port, timeout: 30)
            defer { proxyPipe.close() }
            let proxy = InstallProxyClient(pipe: proxyPipe)
            try proxy.install(afcPath: remote) { fraction, status in
                onProgress(0.75 + fraction * 0.25, status ?? "Installing\u{2026}")
            }
            onProgress(1.0, "Installed")
        }.value
    }
}

enum USBInstallerError: Error, CustomStringConvertible {
    case notReady
    case needsSSL(String)
    case needsPairing(String)

    var description: String {
        switch self {
        case .notReady: return "The USB bridge isn\u{2019}t up yet. Give the device a minute after boot."
        case .needsSSL(let name): return "\(name) wants an SSL-paired channel, which this bridge can\u{2019}t do yet."
        case .needsPairing(let m): return "The device wants to be paired first (\(m))."
        }
    }
}
