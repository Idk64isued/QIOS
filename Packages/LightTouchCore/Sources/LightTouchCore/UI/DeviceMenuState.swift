/// What the Device menu's device items show for the selected device: a snapshot the window controller takes when
/// AppKit validates an item, and each item's enabled state, title and check mark from it.
public struct DeviceMenuState {
    /// The machine's state, one value (paused, powered off and dead can't all be claimed at once).
    public var machine = VMState.notStarted
    /// Running and ready for the user (EmulatorController.isRunning): booted, prepared, not stopping or erasing.
    public var isRunning = false
    public var isSleeping = false
    var isPaused: Bool { machine == .paused }
    var isPoweredOff: Bool { machine == .poweredOff }
    var isDead: Bool { machine.isDead }
    public var shuttingDown = false
    public var storageFailed = false
    /// An install executing now, or one queued behind it (AppInstaller).
    public var isInstalling = false
    public var hasPendingInstalls = false
    public var acceptsInput = false
    public var hasCompass = false
    public var hasCellular = false
    public var compassHeading: Int?
    /// Text is being edited in the window (an NSTextView is first responder): its arrow keys aren't rotation.
    public var editingText = false
    /// Device ▸ Accessibility: the device's firmware version (the items' titles), why it has no accessibility
    /// features (AccessibilityFeature.unavailableReason), and what the guest last said is on (nil: not read yet).
    public var version = ""
    public var accessibilityUnavailable: String?
    public var accessibilityOn: Set<AccessibilityFeature>?

    public init() {}

    public enum Item: Equatable {
        case lock
        case rotate
        case compassHeading(Int)
        case carrier
        /// Home, Shake, Volume Up and Down: plain input.
        case input
        case pause
        /// Restart: in place (a paused guest is resumed first: BootCycle.reset), or Power On when powered off.
        case restart
        /// Device ▸ Accessibility, the submenu itself.
        case accessibilityMenu
        /// One of its switches.
        case accessibility(AccessibilityFeature)
    }

    public struct Validation: Equatable {
        public var isEnabled: Bool
        /// A title the item takes (Pause/Resume, Lock/Wake/Power On); nil leaves it.
        public var title: String?
        /// A check mark; nil leaves the item's state alone.
        public var isOn: Bool?
        /// Why it is dimmed, where that isn't plain.
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
        case .lock:
            Validation(
                isEnabled: acceptsInput || (isPoweredOff && !shuttingDown),
                title: isPoweredOff ? "Start" : isSleeping ? "Wake" : "Lock"
            )
        case .rotate:
            Validation(isEnabled: acceptsInput && !editingText)
        case .compassHeading(let heading):
            Validation(isEnabled: acceptsInput && hasCompass, isOn: heading == compassHeading)
        case .carrier:
            Validation(isEnabled: hasCellular && (isRunning || isPaused))
        case .input:
            Validation(isEnabled: acceptsInput)
        case .pause:
            Validation(
                isEnabled: (isRunning || isPaused) && !isInstalling && !hasPendingInstalls,
                title: isPaused ? "Resume" : "Pause"
            )
        case .restart:
            Validation(isEnabled: !isDead && !shuttingDown && !storageFailed)
        case .accessibilityMenu:
            Validation(
                isEnabled: isRunning && accessibilityUnavailable == nil,
                toolTip: isRunning ? accessibilityUnavailable : nil
            )
        case .accessibility(let feature):
            Validation(
                isEnabled: isRunning && accessibilityUnavailable == nil,
                title: feature.title(version: version),
                isOn: isRunning && accessibilityOn?.contains(feature) == true,
                toolTip: isRunning ? accessibilityUnavailable : nil
            )
        }
    }
}

/// Which captures the Capture menu and toolbar offer now.
public struct CaptureAvailability {
    public var machine = VMState.notStarted
    /// Running and ready for the user (EmulatorController.isRunning).
    public var isRunning = false
    var isPaused: Bool { machine == .paused }
    public var isSleeping = false
    /// A screenshot is still being taken.
    public var screenshotBusy = false
    /// The recording is being written out.
    public var recordingSaving = false
    /// A recording is starting or running.
    public var recordingCanStop = false

    public init() {}

    public var canTakeScreenshot: Bool { (isRunning || isPaused) && !isSleeping && !screenshotBusy }
    public var canStartRecording: Bool { isRunning && !isSleeping && !screenshotBusy }
    /// Stopping stays available when the guest stops.
    public var canToggleRecording: Bool { !recordingSaving && (recordingCanStop || canStartRecording) }
}
