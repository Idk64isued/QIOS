import CoreHaptics
import CoreMotion
import Foundation
import SwiftUI
import UIKit

// Everything the emulator can be told about the outside world, and everything it reports back.
//
// The Mac app drives the device through a set of host calls; this is the rest of them, the ones the port hadn't
// picked up yet: rotation, a second finger, the sensors the real phone can stand in for, the pasteboard, the
// vibrator, and the device's own answers about whether its screen is asleep or its storage has failed.
//
// Everything is optional. An older emulator build is missing some of these symbols, and every call here checks
// first, so a missing one quietly does nothing instead of taking the app down.

@MainActor
final class DeviceControls: ObservableObject {
    /// Set once the emulator's library is loaded.
    var qemu: QemuRuntime?

    // What the device is doing, polled.
    @Published private(set) var screenAsleep = false
    @Published private(set) var backlight = 100
    @Published private(set) var storageFailed = false
    @Published private(set) var guestWantsShutdown = false
    /// Text the guest copied, waiting to go to the real pasteboard.
    @Published private(set) var guestCopied: String?
    /// Which way up the device is, as UIDeviceOrientation numbers it: 1 portrait, 2 upside down, 3 turned
    /// anticlockwise (Home on the right), 4 turned clockwise (Home on the left).
    @Published private(set) var orientation = 1

    /// How far the picture of the screen turns, in clockwise quarter turns: how the device's interface stands.
    ///
    /// Two angles, as on the Mac and on hardware: how the device is held (`orientation`, the accelerometer, which
    /// only the user's turns move) and how its interface stands (this), which also follows the front app. Open a
    /// landscape-only app and the screen swings round by itself; press Home and it swings back. It follows the
    /// guest's *changes* only, never its steady state: the Home screen is portrait-only on 3.1.3, so following the
    /// level would undo every manual turn the instant it was made.
    @Published private(set) var quarterTurns = 0

    static func turns(forHeld orientation: Int) -> Int {
        switch orientation {
        case 4: return 1
        case 2: return 2
        case 3: return 3
        default: return 0
        }
    }

    /// SpringBoard's degrees (the agent's `orientation`) -> clockwise quarter turns of the screen.
    /// LandscapeLeft (90) has the Home button on the right: the picture turns anticlockwise.
    static func turns(forGuest degrees: Int) -> Int? {
        switch degrees {
        case 0: return 0
        case 180: return 2
        case 90: return 3
        case -90, 270: return 1
        default: return nil
        }
    }

    private var lastGuestDegrees: Int?
    private var orientationWatch: Task<Void, Never>?

    /// Follows the front app's orientation through the guest agent (3.1.3; other builds don't answer and the
    /// screen stays where the user put it). Four times a second, nothing while asleep or installing.
    func watchGuestOrientation(agent: GuestAgent) {
        orientationWatch?.cancel()
        lastGuestDegrees = nil
        orientationWatch = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: misses > 3 ? 5_000_000_000 : 250_000_000)
                guard let self else { return }
                guard self.running else { continue }
                guard agent.status == .alive, agent.ops.contains("orientation"), !agent.isInstalling,
                    !self.screenAsleep
                else { continue }
                guard let degrees = await agent.orientation() else {
                    misses += 1
                    continue
                }
                misses = 0
                self.guestOrientation(degrees)
            }
        }
    }

    private func guestOrientation(_ degrees: Int) {
        guard let turns = Self.turns(forGuest: degrees) else { return }
        defer { lastGuestDegrees = degrees }
        guard let previous = lastGuestDegrees, previous != degrees else { return }   // the first reading only seeds
        if turns != quarterTurns { quarterTurns = turns }
    }

    // Settings the user can turn on. Plain UserDefaults rather than @AppStorage: this is not a view, and a
    // property wrapper built for views does not publish changes from here.
    static func setting(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
    var passBattery: Bool { Self.setting("passBattery", default: true) }
    var reportCharger: Bool { Self.setting("reportCharger", default: true) }
    var passMotion: Bool { Self.setting("passMotion", default: false) }
    var mirrorVibration: Bool { Self.setting("mirrorVibration", default: true) }

    private var timer: Timer?
    private var vibratorPulses: UInt64 = 0
    private var vibrating = false
    private var haptics: CHHapticEngine?
    private var buzz: CHHapticAdvancedPatternPlayer?
    /// Calls this machine turned out not to have (the 1G boards have no battery or USB-attach property). Asked
    /// once, then left alone, so the log isn't filled with the same refusal.
    private var unsupported: Set<String> = []
    private var pasteboardSerial: UInt64 = 0
    private let motion = CMMotionManager()
    private var lastBattery: (level: Int, charging: Int)?
    private var running = false

    // MARK: - Lifecycle

    /// Starts watching the device and telling it about this phone. Call once the emulator is running.
    func start(qemu: QemuRuntime?) {
        self.qemu = qemu
        guard !running else { return }
        running = true
        orientation = 1
        quarterTurns = 0
        vibratorPulses = 0

        UIDevice.current.isBatteryMonitoringEnabled = true
        applyPowerState()
        if passMotion { startMotion() }

        // One timer for everything: the device's own state, the vibrator, the guest's pasteboard, the battery.
        // Four times a second is enough to feel immediate without costing anything.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer.tolerance = 0.1
        self.timer = timer
    }

    func stop() {
        orientationWatch?.cancel()
        orientationWatch = nil
        timer?.invalidate()
        timer = nil
        stopMotion()
        stopBuzz()
        running = false
    }

    // MARK: - Polling

    private func poll() {
        guard let qemu else { return }

        if let sleeping = qemu.displaySleeping?() {
            if sleeping != screenAsleep { screenAsleep = sleeping }
        }
        if let raw = qemu.backlightLevel?() {
            let level = Int(raw)   // the emulator answers in Int32
            if level != backlight { backlight = level }
        }
        if let failed = qemu.storageFailed?(), failed != storageFailed { storageFailed = failed }
        if let confirmed = qemu.shutdownConfirmed?(), confirmed != guestWantsShutdown {
            guestWantsShutdown = confirmed
        }

        // The device's vibration motor. Its answer is whether the motor runs right now, and `pulses` counts every
        // start, so a buzz shorter than this poll still shows up. Mirror both: a continuous buzz for as long as
        // the motor runs (a ringing phone), and a sharp tap for a start that came and went between polls.
        if mirrorVibration, let vibrator = qemu.vibrator {
            var pulses: UInt64 = 0
            let runningNow = vibrator(&pulses)
            if runningNow != vibrating {
                vibrating = runningNow
                runningNow ? startBuzz() : stopBuzz()
            } else if pulses > vibratorPulses, !runningNow {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            vibratorPulses = pulses
        } else if vibrating {
            vibrating = false
            stopBuzz()
        }

        // Something was copied inside the device.
        if let read = qemu.guestPasteboard {
            var serial = pasteboardSerial
            if let raw = read(&serial) {
                let text = String(cString: raw)
                free(raw)
                pasteboardSerial = serial
                if !text.isEmpty { guestCopied = text }
            }
        }

        if passBattery { applyBattery() }
    }

    // MARK: - Power

    /// Tells the device what this phone's battery is doing, so the old status bar matches.
    private func applyBattery() {
        guard let battery = qemu?.battery, !unsupported.contains("battery") else { return }
        let device = UIDevice.current
        let raw = device.batteryLevel
        guard raw >= 0 else { return }   // -1 while monitoring is still starting
        let level = Int((raw * 100).rounded())
        let charging = device.batteryState == .charging || device.batteryState == .full ? 1 : 0
        if let last = lastBattery, last.level == level, last.charging == charging { return }
        lastBattery = (level, charging)
        if !battery(Int32(level), Int32(charging)) { unsupported.insert("battery") }
    }

    /// A cable and a high-power port. iOS reports "external power" and stops idle-sleeping when it sees one, which
    /// is also what keeps a device awake while you are looking at it.
    func applyPowerState() {
        if !unsupported.contains("usb"), let connect = qemu?.usbConnection, !connect(reportCharger) {
            unsupported.insert("usb")
        }
        if !unsupported.contains("charger"), let charger = qemu?.usbCharger, !charger(reportCharger) {
            unsupported.insert("charger")
        }
    }

    // MARK: - Vibration on this phone

    /// A continuous buzz that lasts until stopBuzz, the closest this phone's Taptic Engine gets to a motor.
    private func startBuzz() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        do {
            if haptics == nil {
                let engine = try CHHapticEngine()
                engine.isAutoShutdownEnabled = true
                engine.resetHandler = { [weak self] in
                    Task { @MainActor in self?.buzz = nil }
                }
                haptics = engine
            }
            try haptics?.start()
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35),
                ],
                relativeTime: 0, duration: 30)
            let player = try haptics?.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player?.start(atTime: CHHapticTimeImmediate)
            buzz = player
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    private func stopBuzz() {
        try? buzz?.stop(atTime: CHHapticTimeImmediate)
        buzz = nil
    }

    // MARK: - Gestures and orientation

    /// Turns the device a quarter turn, the way you would turn the phone in your hand.
    ///
    /// The orientation is set outright rather than stepped: the step the emulator offers goes through a keyboard
    /// chord whose direction depends on the board, which is why the first version turned the wrong way. Setting
    /// the accelerometer to a named orientation, and turning the picture to match, cannot disagree with itself.
    func rotate(clockwise: Bool) {
        let next: [Int: Int] = clockwise ? [1: 4, 4: 2, 2: 3, 3: 1] : [1: 3, 3: 2, 2: 4, 4: 1]
        setOrientation(next[orientation] ?? 1)
    }

    /// Back to portrait.
    func upright() { setOrientation(1) }

    private func setOrientation(_ value: Int) {
        if let apply = qemu?.orientation, apply(Int32(value)) {
            orientation = value
        } else if let step = qemu?.rotate {
            // An older library without the outright setter: step, and hope the board agrees on direction.
            let clockwise = ([1: 4, 4: 2, 2: 3, 3: 1][orientation] ?? 4) == value
            step(clockwise)
            orientation = value
        } else {
            return
        }
        quarterTurns = Self.turns(forHeld: value)
    }

    /// Sleep / Wake, for the overlay a sleeping screen shows.
    func wakeScreen() {
        guard let qemu else { return }
        qemu.button(1, true)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) { qemu.button(1, false) }
    }

    /// Shake, for the undo prompt.
    func shake() { qemu?.shake?() }

    // MARK: - Motion

    func setMotion(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "passMotion")
        on ? startMotion() : stopMotion()
    }

    /// The real phone's tilt becomes the device's tilt, so anything that reads the accelerometer works, and its
    /// heading becomes the device's compass. Asking for a magnetic reference frame is what fills in the heading.
    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        let frame: CMAttitudeReferenceFrame =
            CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical)
            ? .xMagneticNorthZVertical : .xArbitraryZVertical
        var lastHeading = -1
        motion.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.qemu?.attitude?(data.attitude.pitch * 180 / .pi, data.attitude.roll * 180 / .pi, 0)
            let heading = Int(data.heading.rounded())
            if heading >= 0, heading != lastHeading {
                lastHeading = heading
                _ = self.qemu?.compass?(Int32(heading))
            }
        }
    }

    private func stopMotion() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }

    // MARK: - Pasteboard

    /// Sends what is on this phone's clipboard to the device.
    @discardableResult
    func pasteIntoDevice() -> Bool {
        guard let paste = qemu?.paste, let text = UIPasteboard.general.string, !text.isEmpty else { return false }
        text.withCString { paste($0) }
        return true
    }

    /// Takes what the device last copied and puts it on this phone's clipboard.
    @discardableResult
    func copyFromDevice() -> Bool {
        guard let text = guestCopied, !text.isEmpty else { return false }
        UIPasteboard.general.string = text
        return true
    }

    // MARK: - Running state

    /// Stops the emulated CPU while the app is in the background, so an old iPhone isn't quietly eating this
    /// phone's battery in a pocket. Resumed on the way back.
    func suspend() {
        qemu?.pause?()
    }

    /// `resumeCPU` is false when the machine comes back from a background save, which restarts it its own way.
    func wake(resumeCPU: Bool = true) {
        if resumeCPU { qemu?.resume?() }
        applyPowerState()
    }

    /// A proper restart and a proper power-off, rather than pulling the plug.
    func restartDevice() { qemu?.reset?() }

    @discardableResult
    func powerOffDevice() -> Bool {
        guard let shutdown = qemu?.shutdown else { return false }
        return shutdown() == 0
    }

    // MARK: - Networking policy

    /// Restricted: the device reaches nothing but the host's services. LAN: whether it may see this network.
    func setNetwork(restricted: Bool, lanAllowed: Bool) {
        "cell0".withCString { qemu?.netRestrict?($0, restricted) }
        "wifi0".withCString { qemu?.netRestrict?($0, restricted) }
        "cell0".withCString { qemu?.netLAN?($0, lanAllowed) }
        "wifi0".withCString { qemu?.netLAN?($0, lanAllowed) }
    }
}
