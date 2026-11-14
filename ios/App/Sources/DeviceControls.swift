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
        timer?.invalidate()
        timer = nil
        stopMotion()
        running = false
    }

    // MARK: - Polling

    private func poll() {
        guard let qemu else { return }

        if let sleeping = qemu.displaySleeping?() {
            if sleeping != screenAsleep { screenAsleep = sleeping }
        }
        if let level = qemu.backlightLevel?(), level != backlight { backlight = level }
        if let failed = qemu.storageFailed?(), failed != storageFailed { storageFailed = failed }
        if let confirmed = qemu.shutdownConfirmed?(), confirmed != guestWantsShutdown {
            guestWantsShutdown = confirmed
        }

        // The device buzzed: buzz this phone too.
        if mirrorVibration, let vibrator = qemu.vibrator {
            var pulses: UInt64 = 0
            if vibrator(&pulses), pulses != vibratorPulses {
                if pulses > vibratorPulses, vibratorPulses != 0 || pulses == 1 {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                }
                vibratorPulses = pulses
            }
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
        guard let battery = qemu?.battery else { return }
        let device = UIDevice.current
        let raw = device.batteryLevel
        guard raw >= 0 else { return }   // -1 while monitoring is still starting
        let level = Int((raw * 100).rounded())
        let charging = device.batteryState == .charging || device.batteryState == .full ? 1 : 0
        if let last = lastBattery, last.level == level, last.charging == charging { return }
        lastBattery = (level, charging)
        _ = battery(Int32(level), Int32(charging))
    }

    /// A cable and a high-power port. iOS reports "external power" and stops idle-sleeping when it sees one, which
    /// is also what keeps a device awake while you are looking at it.
    func applyPowerState() {
        _ = qemu?.usbConnection?(reportCharger)
        _ = qemu?.usbCharger?(reportCharger)
    }

    // MARK: - Gestures and orientation

    /// Turns the device a quarter turn. The guest redraws at the new size and the display follows on its own.
    func rotate(clockwise: Bool) {
        qemu?.rotate?(clockwise)
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

    func wake() {
        qemu?.resume?()
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
