// The device's input besides the keyboard (KeyboardInput): the hardware buttons, shake, the chassis tilt and its
// motion pose, pasting and composed text.

import DeviceRuntime
import Foundation
import HostRuntime
import Observation

/// What the input reads of the session.
public protocol InputHost: AnyObject {
    var helperLink: HelperLink? { get }
    /// The guest can take input: actually executing.
    var acceptsInput: Bool { get }
    var isSleeping: Bool { get }
    /// Keyboard passthrough (KeyboardInput.enabled).
    var keyboardInputEnabled: Bool { get }
    /// it_agent's `type` into the focused field (it_typein); false where the agent can't (no it_typein, no field).
    func typeThroughAgent(_ text: String) async -> Bool
}

@Observable public final class DeviceInput {
    @ObservationIgnored private unowned let host: InputHost
    @ObservationIgnored private let settings: DeviceSettingsFile
    public init(host: InputHost, settings: DeviceSettingsFile) {
        self.host = host
        self.settings = settings
    }

    // MARK: Hardware buttons

    /// The emulator's button numbers (qemu-ios-ui.h).
    public enum Button: Int {
        case home = 0
        case power, volumeUp, volumeDown
    }

    static let holdInterval: TimeInterval = 0.10

    public func tap(_ button: Button) {
        guard let link = host.helperLink else { return }
        link.send(.button(button.rawValue, down: true))
        // Release off the main queue (send is thread-safe and ordered), so a
        // stalled main runloop must not be what holds a hardware button down.
        // nonisolated(unsafe): the link's send is thread-safe and ordered (DeviceLink writes on its own queue).
        nonisolated(unsafe) let release = link
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.holdInterval) {
            release.send(.button(button.rawValue, down: false))
        }
    }

    /// Counts shakes, so the shell can wobble once per shake.
    public private(set) var shakeGeneration: UInt64 = 0
    public func shake() {
        host.helperLink?.send(.shake)
        shakeGeneration &+= 1
    }

    // MARK: Motion

    public enum MotionPose: Int { case upright, flat }
    /// Per device (DeviceSettings.motionPose).
    public var motionPose: MotionPose { settings.value.motionPose.flatMap(MotionPose.init(rawValue:)) ?? .upright }
    public func setMotionPose(_ pose: MotionPose) { settings.change { $0.motionPose = pose.rawValue } }

    /// Layer rotation and mounted device roll have opposite signs. Normalize
    /// across the upside-down seam before passing degrees to the shared model.
    public func setTilt(angle: Double, pitch: Double = 0) {
        guard host.acceptsInput, !host.isSleeping else { return }
        host.helperLink?.send(ChassisTilt.attitudeCommand(angle: angle, pitch: pitch, pose: motionPose.rawValue))
    }

    // MARK: Text

    public func paste(_ text: String) { host.helperLink?.send(.paste(text)) }

    /// Composed text (DisplayView's NSTextInputClient): it_agent's `type` into the focused field (it_typein),
    /// in order; where the agent can't (no it_typein, no field), the US keys that type it, one by one.
    @ObservationIgnored private var typing: Task<Void, Never>?
    /// The gap between typed characters.
    @ObservationIgnored var keyGap: Duration = .milliseconds(15)
    public func typeText(_ text: String, shiftHeld: Bool) {
        guard !text.isEmpty, host.keyboardInputEnabled, host.acceptsInput, !host.isSleeping else { return }
        let previous = typing
        typing = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if await host.typeThroughAgent(text) { return }
            for character in text {
                guard let (code, shift) = GuestKeyboard.key(for: character) else { continue }
                let pressShift = shift && !shiftHeld
                if pressShift { host.helperLink?.send(.key(macKeyCode: 56, down: true)) }
                host.helperLink?.send(.key(macKeyCode: Int(code), down: true))
                host.helperLink?.send(.key(macKeyCode: Int(code), down: false))
                if pressShift { host.helperLink?.send(.key(macKeyCode: 56, down: false)) }
                try? await Task.sleep(for: keyGap)
            }
        }
    }
    /// The text being typed now, for whoever must wait for it.
    var currentTyping: Task<Void, Never>? { typing }
}
