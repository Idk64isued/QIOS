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

    /// How far the picture inside the screen turns, in clockwise quarter turns, so the device's interface reads
    /// upright: the device's frame never turns, only its screen (DisplayUIView.turns).
    ///
    /// Two angles: how the device is held (`orientation`, the accelerometer: the menu's turns, or this phone's own
    /// tilt with Tilt and compass on) and how its interface stands (this). Where the guest agent can say how the
    /// front app stands (3.1.3) the picture simply follows it: a landscape game turns its picture upright, the
    /// portrait-only Home screen stays upright however the device is held, which is what the hardware does. Where
    /// it can't, the picture follows how the device is held.
    @Published private(set) var quarterTurns = 0 {
        didSet { DisplayUIView.turns = quarterTurns }
    }
    /// The guest agent answers orientation questions on this device.
    private var guestReports = false
    /// A turn the user asked for (Rotate left/right), which wins over the guest's report until the guest's
    /// orientation next changes or the user picks Upright: plenty of 2009 games draw sideways while telling UIKit
    /// they're portrait, and those need turning by hand and staying turned.
    private var manualTurns: Int?
    /// The last reading, waiting for a second identical one before it's acted on (an app launching reports a few
    /// orientations on its way to its own).
    private var pendingDegrees: Int?

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
    /// The guest's agent, so the sleep overlay waits until the OS is actually up (not a dark panel mid-boot), and the
    /// one that sets a simulated location (startLocation). Set by the device view before start().
    weak var agent: GuestAgent?
    /// Latched true the first time the guest comes up; before that a dark panel means booting, not asleep.
    private var hasBooted = false

    /// Follows the front app's orientation through the guest agent (3.1.3; other builds don't answer and the
    /// screen stays where the user put it). Four times a second, nothing while asleep or installing.
    func watchGuestOrientation(agent: GuestAgent) {
        self.agent = agent
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
        guestReports = true
        // Two readings in a row (half a second) before anything moves: no flicker through transitional states.
        guard pendingDegrees == degrees else {
            pendingDegrees = degrees
            return
        }
        let changed = lastGuestDegrees != nil && lastGuestDegrees != degrees
        lastGuestDegrees = degrees
        if changed { manualTurns = nil }   // the app turned itself: the user's turn no longer applies
        let want = manualTurns ?? turns
        if want != quarterTurns { quarterTurns = want }
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
    /// This phone's location as the device's GPS fix (Settings › Location), on boards with a receiver (the 3GS).
    private let location = PhoneLocation()
    /// Set by the device view before start(): whether this board's modem has a GPS receiver (Board.hasGPS).
    var hasGPS = false
    /// Set by the device view before start(): a board without a receiver running iOS 5 or later, where the
    /// location goes in through iOS's own location simulation instead (GuestLocation), and the agent that does it.
    var simulatesLocation = false
    var passLocation: Bool { Self.setting("passLocation", default: true) }
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
        guestReports = false
        manualTurns = nil
        pendingDegrees = nil
        hasBooted = false
        vibratorPulses = 0

        UIDevice.current.isBatteryMonitoringEnabled = true
        applyPowerState()
        if passMotion { startMotion() }
        if passLocation, hasGPS || simulatesLocation { startLocation() }

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
        location.stop()
        stopBuzz()
        running = false
    }

    // MARK: - Polling

    private func poll() {
        guard let qemu else { return }

        if let sleeping = qemu.displaySleeping?() {
            // A dark panel before the OS is up is a device still booting, not one asleep — the iPhone 4's boot is
            // long enough that the "Asleep, tap to wake" overlay was covering it the whole time. Only trust the
            // sleep signal once the guest has come up at least once (its agent answered).
            if agent?.status == .alive { hasBooted = true }
            let asleep = hasBooted && sleeping
            if asleep != screenAsleep { screenAsleep = asleep }
        }
        if let raw = qemu.backlightLevel?() {
            let level = Int(raw)   // the emulator answers in Int32
            if level != backlight { backlight = level }
        }
        if let failed = qemu.storageFailed?(), failed != storageFailed { storageFailed = failed }
        followHeldPhone()
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

    /// Back to portrait, and back to following the guest.
    func upright() {
        manualTurns = nil
        setOrientation(1)
        if guestReports, let degrees = lastGuestDegrees, let turns = Self.turns(forGuest: degrees) { quarterTurns = turns }
    }

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
        // The picture turns with the hold right away, and stays turned (manualTurns) until the front app turns
        // itself or the user picks Upright.
        // With Tilt and compass on, this phone's next reading holds the device again: the picture stays with it.
        if motion.isDeviceMotionActive { return }
        let turns = Self.turns(forHeld: value)
        if value != 1 { manualTurns = turns } else { manualTurns = nil }
        quarterTurns = turns
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

    func setLocation(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "passLocation")
        guard running, hasGPS || simulatesLocation else { return }
        if on {
            startLocation()
        } else {
            location.stop()
            if !hasGPS, let agent { Task { await agent.stopSimulatedLocation() } }
        }
    }

    /// This phone's location into the device: the modem's GPS receiver where the board has one, otherwise iOS's own
    /// location simulation, set from inside the device (lt-locate) each time this phone has moved far enough.
    private func startLocation() {
        if hasGPS {
            location.sink = nil
        } else {
            location.sink = { [weak self] fix in
                let c = fix.coordinate
                Task { @MainActor in await self?.agent?.simulateLocation(latitude: c.latitude, longitude: c.longitude) }
            }
        }
        location.start(qemu: qemu)
    }

    func setMotion(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "passMotion")
        manualTurns = nil
        on ? startMotion() : stopMotion()
        // Off: the device goes back to the hold picked last (tilting left it however this phone was).
        if !on, running { setOrientation(orientation) }
    }

    /// The real phone's tilt becomes the device's tilt, so anything that reads the accelerometer works, and its
    /// heading becomes the device's compass. Asking for a magnetic reference frame is what fills in the heading.
    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        let frame: CMAttitudeReferenceFrame =
            CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical)
            ? .xMagneticNorthZVertical : .xArbitraryZVertical
        var lastSentHeading = -1
        var smoothed: CMAcceleration?
        var smoothedHeading: Double?
        var lastSent: (pitch: Double, roll: Double)?
        var neutral: CMAcceleration?
        var lastShake = Date.distantPast
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            // Shaking. CoreMotion splits what the phone feels into gravity (which way is down) and the user's own
            // acceleration; only gravity was ever passed on, so a shake -- all user acceleration -- never reached
            // the device. A jolt past 1.4 g is a shake: the device gets one (its accelerometer swings hard for a
            // fifth of a second, which is what iOS and games look for), at most once every 0.6 s. (1.4 g: a firm shake, not a bump.)
            let a = data.userAcceleration
            if (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot() > 1.4, Date().timeIntervalSince(lastShake) > 0.6 {
                lastShake = Date()
                self.qemu?.shake?()
            }
            // The raw accelerometer jitters, so a tiny tilt of this phone shook the device. Smooth the gravity
            // vector lightly and send a new attitude once it has moved a quarter of a degree. (It was a heavy
            // smoothing and a whole degree at 30 Hz: a ball rolled in visible steps, which reads as twitchy.)
            let g = data.gravity
            let s = smoothed.map { CMAcceleration(x: $0.x * 0.6 + g.x * 0.4, y: $0.y * 0.6 + g.y * 0.4, z: $0.z * 0.6 + g.z * 0.4) } ?? g
            smoothed = s
            // Settings > Tilt sensitivity: how far the device tilts for each degree this phone does, measured from
            // the way the phone was held when tilt came on. At 100% the device reads exactly this phone's gravity.
            let k = Self.tiltSensitivity
            if neutral == nil { neutral = s }
            let n = neutral ?? s
            let felt = k >= 0.999 ? s : CMAcceleration(x: n.x + (s.x - n.x) * k, y: n.y + (s.y - n.y) * k, z: n.z + (s.z - n.z) * k)
            if let (pitch, roll) = Self.guestAttitude(gravity: felt) {
                let moved = lastSent.map { abs($0.pitch - pitch) > 0.25 || abs($0.roll - roll) > 0.25 } ?? true
                if moved {
                    lastSent = (pitch, roll)
                    self.qemu?.attitude?(pitch, roll, 1)
                }
            }
            // The magnetometer is noisy, so the compass jumped around. Smooth the heading the short way around the
            // circle and send it only once it has turned a couple of degrees.
            let raw = data.heading
            if raw >= 0 {
                let previous = smoothedHeading ?? raw
                var delta = (raw - previous).truncatingRemainder(dividingBy: 360)
                if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                var next = previous + delta * 0.3
                next = next.truncatingRemainder(dividingBy: 360)
                if next < 0 { next += 360 }
                smoothedHeading = next
                let heading = Int(next.rounded()) % 360
                var step = abs(heading - lastSentHeading)
                if step > 180 { step = 360 - step }
                if lastSentHeading < 0 || step >= 2 {
                    lastSentHeading = heading
                    _ = self.qemu?.compass?(Int32(heading))
                }
            }
        }
    }

    /// With Tilt and compass on, the device is held the way this phone is, and its picture turns so it stays lined
    /// up with this phone rather than with Light Touch's own interface (which turns to landscape with the phone):
    /// a guest that turns its interface when tilted then reads upright, as on the real thing. Where the guest agent
    /// reports how the front app stands, that report decides instead (guestOrientation), and a turn picked from the
    /// menu holds until the guest changes.
    private func followHeldPhone() {
        guard passMotion, motion.isDeviceMotionActive, !guestReports, manualTurns == nil else { return }
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        guard let interface = scene?.effectiveGeometry.interfaceOrientation else { return }
        let turns: Int
        switch interface {
        case .landscapeRight: turns = Self.turns(forHeld: 3)   // Home button on the right
        case .landscapeLeft: turns = Self.turns(forHeld: 4)
        default: turns = 0
        }
        if turns != quarterTurns { quarterTurns = turns }
    }

    /// This phone's gravity (CoreMotion's, in g: +x the right edge, +y the top, +z out of the screen) as the
    /// emulator's attitude in its flat pose, where 0, 0 is face up, positive pitch tips the top edge down and positive
    /// roll the right edge down: gravity (sin r cos p, sin p, -cos r cos p). The device then reads the same gravity
    /// this phone does, whichever way it is held. CoreMotion's own pitch and roll are Euler angles about another
    /// order of axes, and fed straight in they read upright as flat.
    /// Settings > Tilt sensitivity, as a fraction: 1 passes this phone's tilt through as it is.
    static var tiltSensitivity: Double {
        let v = UserDefaults.standard.object(forKey: "tiltSensitivity") as? Double ?? 1
        return max(0.25, min(1, v))
    }

    static func guestAttitude(gravity g: CMAcceleration) -> (Double, Double)? {
        let length = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        guard length > 0.1, length.isFinite else { return nil }
        let x = g.x / length, y = g.y / length, z = g.z / length
        // The emulator's flat-pose gravity is (-sin r·cos p, sin p, -cos r·cos p), so matching it to this phone's
        // gravity gives roll = atan2(-x, -z). (It was atan2(x, -z), which mirrored left and right.)
        let pitch = asin(max(-1, min(1, y))) * 180 / .pi
        let roll = abs(x) < 1e-6 && abs(z) < 1e-6 ? 0 : atan2(-x, -z) * 180 / .pi
        return (pitch, roll)
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
