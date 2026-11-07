// The session's settings that reach the machine: the keyboard (passthrough and Connect Hardware Keyboard). The
// emulator can't be asked for these, so what the app last set is the menu's state, and every boot starts from it.

import DeviceRuntime
import Foundation
import HostRuntime

/// A control request for the running boot: `done(true)` when the machine applied it (BootSessionScope.control).
public typealias MachineControl = (LinkRequest, @escaping @MainActor (Bool) -> Void) -> Void

/// Keyboard passthrough (per device, on by default) and Connect Hardware Keyboard (⇧⌘K, per device). Both are
/// settings, so observable through the settings file.
public final class KeyboardInput {
    private let settings: DeviceSettingsFile
    private let canToggleHardwareKeyboard: Bool
    private let control: MachineControl
    private let send: (LinkCommand) -> Void
    /// The guest takes key presses now: running, accepting input, display awake.
    private let canPress: () -> Bool

    public init(
        settings: DeviceSettingsFile,
        canToggleHardwareKeyboard: Bool,
        control: @escaping MachineControl,
        send: @escaping (LinkCommand) -> Void,
        canPress: @escaping () -> Bool
    ) {
        self.settings = settings
        self.canToggleHardwareKeyboard = canToggleHardwareKeyboard
        self.control = control
        self.send = send
        self.canPress = canPress
    }

    /// Forward host keys by macOS virtual keycode; the shim maps them to QKeyCodes exactly as ui/cocoa.m does.
    public var enabled: Bool { settings.value.keyboardInputEnabled ?? true }
    public func toggleEnabled() {
        let enabled = !enabled
        settings.change { $0.keyboardInputEnabled = enabled }
    }

    /// Unplugged, iOS shows its on-screen keyboard in a text field.
    public var hardwareConnected: Bool { settings.value.hardwareKeyboard ?? true }
    public func toggleHardware() {
        let connected = !hardwareConnected
        settings.change { $0.hardwareKeyboard = connected }
        applyHardware(changed: true)
    }

    /// Each boot starts with the keyboard plugged in (BootRecipe's usb-kbd): unplug it when it's off.
    public func applyHardware(changed: Bool = false) {
        guard canToggleHardwareKeyboard, changed || !hardwareConnected else { return }
        let connected = hardwareConnected
        control(.hardwareKeyboard(connected)) { ok in
            if !ok { logEvent("keyboard: couldn’t \(connected ? "connect" : "disconnect") the hardware keyboard") }
        }
    }

    /// A press only while the guest takes input; a release always, so no key is left down.
    public func sendKey(macKeyCode: UInt16, down: Bool) {
        guard !down || (enabled && canPress()) else { return }
        send(.key(macKeyCode: Int(macKeyCode), down: down))
    }
}
