// DisplayView's world, as the device window would give it: a fake helper link (a fresh one-color ring surface per
// frame of frameWidth x frameHeight, every command recorded), a fake device hub that records its buttons, keys and
// tilt, and a stand-in for the 3D model whose loading and first frame take as long as a test says (no RealityKit).
import AppKit
import DeviceRuntime
import HostRuntime
import IOSurface
import LightTouchCore

/// The machines as LightTouchDevice's machines launch reports them (tests/fixtures/machines.json), set before a board's facts are read.
let fixtureMachines: Void = {
    let url = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        .appendingPathComponent("../../../fixtures/machines.json").standardizedFileURL
    Machines.set(try! JSONDecoder().decode([DeviceInfo].self, from: Data(contentsOf: url)))
}()

@MainActor var touches: [(Double, Double)] = []
/// Every command the display sent the link.
@MainActor var sent: [LinkCommand] = []
@MainActor var frameWidth: Int32 = 320
@MainActor var frameHeight: Int32 = 480
/// A static screen: the link keeps answering with the frame it has.
@MainActor var frozen = false
@MainActor var frameColor: UInt32 = 0xff20_80c0

@MainActor final class FakeLink {
    var serial: UInt64 = 0
    var surfaces: [String: IOSurface] = [:]
    func frontSurface() -> (surface: IOSurface, serial: UInt64, isNew: Bool)? {
        if !frozen { serial += 1 }
        let key = "\(frameWidth)x\(frameHeight)x\(frameColor)"
        let surface =
            surfaces[key]
            ?? {
                let s = IOSurface(properties: [
                    .width: Int(frameWidth), .height: Int(frameHeight), .bytesPerElement: 4, .pixelFormat: 0x4247_5241
                ])!
                s.lock(options: [], seed: nil)
                for y in 0..<Int(frameHeight) {
                    for x in 0..<Int(frameWidth) {
                        s.baseAddress.storeBytes(
                            of: frameColor,
                            toByteOffset: y * s.bytesPerRow + x * 4,
                            as: UInt32.self
                        )
                    }
                }
                s.unlock(options: [], seed: nil)
                return s
            }()
        surfaces[key] = surface
        return (surface, serial, true)
    }
    func send(_ command: LinkCommand) {
        sent.append(command)
        if case .touch(_, _, let x, let y) = command { touches.append((x, y)) }
    }
}

/// A Store row's payload (only its id travels).
struct CatalogApp: Codable { let id: Int }
extension NSPasteboard.PasteboardType { static let ltmCatalogApp = Self("test.catalog") }
@MainActor final class SleepingAnimationView: NSView {}
/// DeviceContentView's notices (here a status only says whether it shows) and its overlay panel's policy.
@MainActor final class CaptureStatusView: NSView {
    var isWindowActive = false
    var onVisibilityChange: (() -> Void)?
}
enum WindowRestorationPolicy { static func configure(_ window: NSWindow) {} }

@MainActor final class EmulatorController {
    enum Pose { case flat, upright }
    var motionPose = Pose.upright, rotationDegrees = 0, acceptsInput = true, canQueueInstall = true
    /// How the device is held: here every turn is the user's, so it is the rotation.
    var heldDegrees: Int { rotationDegrees }
    var keyboardInputEnabled = true, keyboardTiltRate = 90.0, isSleeping = false, isPoweredOff = false,
        shuttingDown = false
    var preparingDevice = false
    var shakeGeneration: UInt64 = 0, homeCount = 0, lockCount = 0, volume = 0
    var vibrating = false
    let link: FakeLink? = FakeLink()
    /// Keys ("<code>v" down, "<code>^" up) and text ("type:<text>[+shift]") as they reached the guest.
    var log: [String] = []
    func pressLock() { lockCount += 1 }
    func powerOn() {}
    func pressVolumeUp() { volume += 1 }
    func pressVolumeDown() { volume -= 1 }
    var attitude = (angle: CGFloat.zero, pitch: CGFloat.zero)
    func shake() { shakeGeneration &+= 1 }
    func setTilt(angle: CGFloat, pitch: CGFloat) { attitude = (angle, pitch) }
    func pressHome() { homeCount += 1 }
    /// The user's touches and keys on the screen (what lets a device's copy reach the Mac's pasteboard).
    var interactions = 0
    func userInteracted() { interactions += 1 }
    func sendKey(macKeyCode: UInt16, down: Bool) { log.append("\(macKeyCode)\(down ? "v" : "^")") }
    func typeText(_ text: String, shiftHeld: Bool) { log.append("type:\(text)\(shiftHeld ? "+shift" : "")") }
}

/// The 3D model as far as DisplayView sees it: no RealityKit; loading takes loadingDelay, the first frame
/// preparationDelay (a late callback that ignores cancellation, as a busy renderer's).
@MainActor final class DeviceModelView: NSView {
    var drawsNearest = true
    var viewportCenter: CGPoint?
    static var loadingDelay: Duration = .zero
    static var preparationDelay: Duration = .milliseconds(50)
    static var framesPrepared = 0
    let delay: Duration
    var shellPixels: CGSize { CGSize(width: 737, height: 1318) }
    enum Control { case sleepWake, volumeUp, volumeDown }
    func control(at p: CGPoint) -> Control? { nil }
    init(url: URL, profile: Board) async throws {
        delay = Self.preparationDelay
        try await Task.sleep(for: Self.loadingDelay)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    func prepareFirstFrame() async -> Bool {
        await withCheckedContinuation { continuation in
            Task {
                try? await Task.sleep(for: delay)
                continuation.resume()
            }
        }
        Self.framesPrepared += 1
        return true
    }
    func pose(
        scale: CGFloat,
        rotation: Int,
        roll: CGFloat,
        pitch: CGFloat,
        yaw: CGFloat = 0,
        flat: Bool = false,
        animated: Bool,
        spring: Bool = false
    ) {}
    func updateFrame(_ image: CGImage) {}
    func setScreenOff(_ off: Bool) {}
    var homeButtonRect: CGRect? { nil }
    func projectedPoint(_ p: CGPoint) -> CGPoint { .zero }
    func panelPoint(_ p: CGPoint, unbounded: Bool = false) -> CGPoint? { nil }
    func isChassis(_ p: CGPoint) -> Bool { false }
    func advanceAnimations() -> Bool { false }
    func shake() {}
    func specialTrick() {}
}
