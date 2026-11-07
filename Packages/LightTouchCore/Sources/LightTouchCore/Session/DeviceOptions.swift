// The device's options outside the machine's controls: Attach to Local Network and the debug port (per device,
// DeviceSettings), and the boot arguments Settings ▸ verbose boot and kernel console add (app-wide, UserDefaults).

import DeviceRuntime
import Foundation
import HostRuntime
import Observation

@Observable public final class DeviceOptions {
    @ObservationIgnored private let settings: DeviceSettingsFile
    @ObservationIgnored private let board: String
    @ObservationIgnored private let link: () -> HelperLink?
    @ObservationIgnored private let requestLocalNetworkAccess: () -> Void

    public init(
        settings: DeviceSettingsFile,
        board: String,
        link: @escaping () -> HelperLink?,
        requestLocalNetworkAccess: @escaping () -> Void = LocalNetworkAccess.request
    ) {
        self.settings = settings
        self.board = board
        self.link = link
        self.requestLocalNetworkAccess = requestLocalNetworkAccess
    }

    /// Attach to Local Network, per device (DeviceSettings.localNetwork), off by default: while off the
    /// emulator refuses the guest's LAN traffic (BootRecipe.wifiNetdev), so macOS never asks on its own.
    /// Turning it on asks macOS for Local Network access right then and opens the running device in place.
    public var localNetworkEnabled: Bool { settings.value.localNetwork ?? false }
    public func toggleLocalNetwork() {
        let enabled = !localNetworkEnabled
        settings.change { $0.localNetwork = enabled }
        if enabled { requestLocalNetworkAccess() }
        link()?.send(.netLocalNetwork(enabled))
    }

    /// Debug port, per device (DeviceSettings.debugPort), off by default; read at each start. QEMU's gdbstub on a
    /// Unix socket only this user reaches, `debugSocket` while this boot has one (qemu-ios docs/guest-debug.md).
    public var debugPortEnabled: Bool { settings.value.debugPort ?? false }
    public func toggleDebugPort() {
        let enabled = !debugPortEnabled
        settings.change { $0.debugPort = enabled }
    }
    public private(set) var debugSocket: String?
    /// This boot's socket: a fresh one when the option is on and the boot is built, else none. The last boot's
    /// socket file goes.
    public func chooseDebugSocket(booting: Bool) -> String? {
        if let old = debugSocket { unlink(old) }
        debugSocket = debugPortEnabled && booting ? DebugPort.socketPath() : nil
        return debugSocket
    }
    public var lldbAttachCommand: String? { debugSocket.map { DebugPort.lldbCommand(board: board, socket: $0) } }

    // MARK: Boot environment (app-wide)

    /// UserDefaults key for Settings ▸ verbose boot.
    public static let verboseBootDefaultsKey = "verboseBoot"
    public static let kernelConsoleDefaultsKey = "kernelConsole"

    /// Early iBoot handoff arguments; serial output is included in diagnostics.
    /// The regression checker compares the base command line with the harness;
    /// verbose boot and kernel-console output remain optional app settings.
    public static func bootArgs(_ defaults: UserDefaults = .standard) -> String {
        var args = "amfi_allow_any_signature=1 cs_enforcement_disable=1"
        if defaults.bool(forKey: verboseBootDefaultsKey) { args += " -v" }
        if defaults.bool(forKey: kernelConsoleDefaultsKey) { args += " serial=3 debug=0x8" }
        return args
    }
}
