import HostRuntime

/// The app-wide device settings in the Device menu (AppDelegate's items: Attach to Local Network, Rotate
/// Automatically, Debug Port…, Copy lldb Command, Connect to the Internet) for the device they apply to.
public struct DeviceSettingsMenu {
    /// The device the settings apply to, as they stand; nil with no device.
    public struct Device {
        public var marketingName: String
        public var shortName: String
        public var localNetworkEnabled = false
        public var autoRotateEnabled = true
        /// The switch, for the next start.
        public var debugPortEnabled = false
        /// The socket this boot's gdbstub listens on.
        public var debugSocket: String?
        public var lldbAttachCommand: String?
        /// Whether this boot has the Mac's network.
        public var network = true
        /// False: the selected device isn't running; only Attach to Local Network (its next start) applies.
        public var isRunning = true

        public init(marketingName: String, shortName: String) {
            self.marketingName = marketingName
            self.shortName = shortName
        }
    }

    public var device: Device?
    /// Connect to the Internet's choice (NetworkAccessPreference.desired).
    public var desiredNetwork: Bool

    public init(device: Device?, desiredNetwork: Bool) {
        self.device = device
        self.desiredNetwork = desiredNetwork
    }

    /// The device the items name and change: the window's selection, running or not, never another device that
    /// happens to be running (an iPad's name on a selected iPhone still preparing). Only with no window to follow,
    /// the first running device.
    public static func target<T>(hasWindow: Bool, selected: T?, running: [T]) -> T? {
        hasWindow ? selected : running.first
    }

    public enum Item { case localNetwork, autoRotate, debugPort, copyLLDBCommand, internet }

    public struct Validation: Equatable {
        public var isEnabled: Bool
        /// A title the item takes; nil leaves it.
        public var title: String?
        /// A check mark; nil leaves the item's state alone.
        public var isOn: Bool?
        public var toolTip: String?

        public init(isEnabled: Bool, title: String? = nil, isOn: Bool? = nil, toolTip: String? = nil) {
            self.isEnabled = isEnabled
            self.title = title
            self.isOn = isOn
            self.toolTip = toolTip
        }
    }

    public func validate(_ item: Item) -> Validation {
        switch item {
        case .localNetwork:
            return Validation(
                isEnabled: device != nil,
                title: device.map { "Attach \($0.marketingName) to Local Network" } ?? "Attach to Local Network",
                isOn: device?.localNetworkEnabled ?? false
            )
        case .autoRotate:
            return Validation(isEnabled: device?.isRunning == true, isOn: device?.autoRotateEnabled ?? true)
        case .debugPort:
            // A switch the running boot doesn't have yet says when it applies.
            let enabled = device?.debugPortEnabled ?? false
            return Validation(
                isEnabled: device?.isRunning == true,
                isOn: enabled,
                toolTip: device.flatMap {
                    enabled != ($0.debugSocket != nil) ? "Takes effect the next time the \($0.shortName) starts." : nil
                }
            )
        case .copyLLDBCommand:
            return Validation(
                isEnabled: device?.lldbAttachCommand != nil,
                toolTip: device?.debugSocket.map {
                    "QEMU's gdbstub is at \($0). Replace KERNELCACHE and QEMU_IOS; see qemu-ios docs/guest-debug.md."
                }
            )
        case .internet:
            // The title stays put; a choice the running device doesn't have yet says when it applies.
            return Validation(
                isEnabled: true,
                isOn: desiredNetwork,
                toolTip: device.flatMap {
                    desiredNetwork != $0.network
                        ? "Takes effect the next time Light Touch opens the \($0.shortName)." : nil
                }
            )
        }
    }
}

/// Device ▸ Debugging ▸ Debug Port…'s text: where the switch and this boot stand, and the commands that attach.
public enum DebugPortText {
    public static func state(shortName: String, enabled: Bool, socket: String?) -> String {
        switch (enabled, socket) {
        case (true, let socket?): "On, at \(socket)."
        case (true, nil): "On from the next time the \(shortName) starts."
        case (false, let socket?): "Off from the next start. Until then it’s at \(socket)."
        case (false, nil): "Off."
        }
    }

    /// (title, command) for the running stub's socket.
    public static func commands(socket: String, lldbWithSymbols: String?) -> [(String, String)] {
        [("lldb", "lldb -o '\(DebugPort.lldbConnect(socket: socket))'")]
            + (lldbWithSymbols.map { [("lldb with kernel symbols", $0)] } ?? [])
            + [("GDB", "gdb-multiarch -ex 'target remote \(socket)'")]
    }
}
