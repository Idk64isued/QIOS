import Foundation

public nonisolated struct BootConfig: Codable, Sendable, Equatable {
    /// argv for qemu_ios_main, argv[0] included.
    public var argv: [String]
    /// setenv'd in the helper before QEMU starts (EmulatorController.setBootEnv).
    public var environment: [String: String] = [:]
    /// The -M machine name ("iPod-Touch", "ipad1"). Picks the orphan shutdown.
    public var machine: String
    /// The web proxy the helper serves before QEMU starts (argv's guestfwd connects to its socket).
    public var webProxy: WebProxyEndpoint?
    /// Managed boot: helper rechecks this storage generation under its lease.
    public var storageProof: StorageBootProof?
    /// What argv opens, by role: a sandboxed helper is granted these (DeviceLink; HostRuntime SandboxExtension).
    public var files: BootFiles?

    public init(argv: [String], environment: [String: String] = [:], machine: String) {
        self.argv = argv
        self.environment = environment
        self.machine = machine
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        argv = try c.decode([String].self, forKey: .argv)
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        machine = try c.decode(String.self, forKey: .machine)
        webProxy = try c.decodeIfPresent(WebProxyEndpoint.self, forKey: .webProxy)
        storageProof = try c.decodeIfPresent(StorageBootProof.self, forKey: .storageProof)
        files = try c.decodeIfPresent(BootFiles.self, forKey: .files)
    }

    /// argv's usb-tcp-addr (usbmuxd's guest socket), nil without one.
    public var usbAddress: String? { BootRecipe.usbAddress(in: argv) }

    /// The panel's refresh, Hz: 60 as on the devices, or what argv's `refresh-hz` global asks for
    /// (Board.refreshGlobals). The helper takes frames at this rate.
    public var refreshHz: Int {
        for (flag, value) in zip(argv, argv.dropFirst()) where flag == "-global" {
            if let r = value.range(of: ",property=refresh-hz,value="), let hz = Int(value[r.upperBound...]), hz > 0 {
                return hz
            }
        }
        return 60
    }

    /// argv's wifi0 user netdev boots restricted (BootRecipe.wifiNetdev): 5.x Setup runs offline. The
    /// helper's web proxy starts offline to match and opens with `.netRestrict(false)`.
    public var wifiRestricted: Bool {
        wifiOptions.contains("restrict=on")
    }

    /// argv's wifi0 netdev reaches the Mac's local networks (no `lan=off`, BootRecipe.wifiNetdev); the
    /// helper's web proxy refuses local destinations to match until `.netLocalNetwork(true)`.
    public var wifiLocalNetwork: Bool { !wifiOptions.contains("lan=off") }

    private var wifiOptions: [Substring] {
        zip(argv, argv.dropFirst()).first { $0 == "-netdev" && $1.hasPrefix("user,id=wifi0,") }?.1.split(separator: ",")
            ?? []
    }
}

public nonisolated struct WebProxyEndpoint: Codable, Sendable, Equatable {
    /// The device's web-proxy.conf: routing read per connection; the CA, cache and location beside it.
    public var config: String
    /// The Unix socket the guestfwd connects each guest connection to.
    public var socket: String
    public init(config: String, socket: String) {
        self.config = config
        self.socket = socket
    }
}
