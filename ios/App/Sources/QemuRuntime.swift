import Foundation
import HostRuntime

/// libqemu-arm.dylib (JIT) or libqemu-arm-tci.dylib (interpreter), dlopen-ed in-process: iOS has no helper process.
/// The symbols are the C API in qemu-ios contrib/ios-app/qemu-ios-ui.h (major version 2).
final class QemuRuntime: @unchecked Sendable {
    let path: String
    let isJIT: Bool
    private let handle: UnsafeMutableRawPointer

    init(path: String, isJIT: Bool) throws {
        guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw NSError(domain: "LTM", code: 1, userInfo: [NSLocalizedDescriptionKey: "dlopen \(path): \(String(cString: dlerror()))"])
        }
        let version = dlsym(h, "qemu_ios_api_version").map { unsafeBitCast($0, to: (@convention(c) () -> UInt32).self)() } ?? 0
        guard version >> 16 == 2 else {
            throw NSError(domain: "LTM", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(path) has C API \(version >> 16).\(version & 0xffff), need 2.x"])
        }
        self.handle = h
        self.path = path
        self.isJIT = isJIT
    }

    /// ANGLE (libEGL + libGLESv2) ships beside the emulator in this build.
    static var angleBundled: Bool {
        let dir = Bundle.main.privateFrameworksPath ?? (Bundle.main.bundlePath + "/Frameworks")
        return FileManager.default.fileExists(atPath: dir + "/libEGL.dylib")
            && FileManager.default.fileExists(atPath: dir + "/libGLESv2.framework/libGLESv2")
    }

    /// Settings › Graphics: how the device's OpenGL ES reaches this phone's GPU.
    enum Renderer: String, CaseIterable {
        /// ANGLE on Metal: ES 1.1 and ES 2.0 guests (the default).
        case angle
        /// The iPhone's own OpenGL ES, ES 1.1 and ES 3.0 contexts (qemu-ios patch 0010, gl-renderer=es3).
        case es3
        /// The iPhone's own OpenGL ES 1.1 only (the first renderer): no shaders, so the newer devices draw in software.
        case classic
    }

    /// The renderer the next boot uses: the setting, where this build has it (both new ones come with ANGLE's build).
    static var renderer: Renderer {
        let picked = Renderer(rawValue: UserDefaults.standard.string(forKey: "glRenderer") ?? "angle") ?? .angle
        return angleBundled ? picked : .classic
    }

    static var usesANGLE: Bool { renderer == .angle }

    /// Whether the renderer runs ES 2.0 shaders (what the S5L8920 and A4 devices composite with).
    static var runsShaders: Bool { renderer != .classic }

    /// The dylib that suits this launch: the JIT build when JIT is ready, else the interpreter.
    static func load() throws -> QemuRuntime {
        let dir = Bundle.main.privateFrameworksPath ?? (Bundle.main.bundlePath + "/Frameworks")
        let jit = dir + "/libqemu-arm.dylib", tci = dir + "/libqemu-arm-tci.dylib"
        var errors: [String] = []
        if JIT.ready, FileManager.default.fileExists(atPath: jit) {
            do { return try QemuRuntime(path: jit, isJIT: true) } catch { errors.append("\(error.localizedDescription)") }
        }
        if FileManager.default.fileExists(atPath: tci) {
            do { return try QemuRuntime(path: tci, isJIT: false) } catch { errors.append("\(error.localizedDescription)") }
        }
        throw NSError(domain: "LTM", code: 3, userInfo: [NSLocalizedDescriptionKey: "no usable emulator library in \(dir): " + errors.joined(separator: "; ")])
    }

    private func sym<T>(_ name: String, _: T.Type) -> T {
        guard let p = dlsym(handle, name) else { fatalError("emulator library lacks \(name)") }
        return unsafeBitCast(p, to: T.self)
    }
    private func optionalSym<T>(_ name: String, _: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }

    lazy var main = sym("qemu_ios_main", (@convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32).self)
    lazy var attach = sym("qemu_ios_ui_attach", (@convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void).self)
    lazy var frame = sym(
        "qemu_ios_ui_frame",
        (@convention(c) (UnsafeMutablePointer<UnsafeRawPointer?>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<UInt64>) -> Bool).self)
    lazy var ready = sym("qemu_ios_ui_ready", (@convention(c) () -> Bool).self)
    lazy var touch = sym("qemu_ios_ui_touch", (@convention(c) (Int32, Int32, Double, Double) -> Void).self)
    lazy var button = sym("qemu_ios_ui_button", (@convention(c) (Int32, Bool) -> Void).self)
    lazy var powerdown = sym("qemu_ios_ui_powerdown", (@convention(c) () -> Void).self)
    lazy var quit = sym("qemu_ios_ui_quit", (@convention(c) () -> Void).self)
    lazy var setForeground = optionalSym("qemu_ios_set_foreground", (@convention(c) (Bool) -> Void).self)
    lazy var buildID = optionalSym("qemu_ios_build_id", (@convention(c) () -> UnsafePointer<CChar>?).self)
    lazy var snapshotSave2 = sym("qemu_ios_snapshot_save2", (@convention(c) (UnsafePointer<CChar>) -> Void).self)
    lazy var snapshotStatus = sym("qemu_ios_snapshot_status", (@convention(c) (UnsafeMutablePointer<CChar>, UInt) -> Int32).self)
    lazy var snapshotResume = sym("qemu_ios_snapshot_resume", (@convention(c) () -> Void).self)
    /// Live GL contexts: a machine with any can't be saved on this host (the iOS GL bridge can't read its state back).
    lazy var glesContexts = optionalSym("qemu_ios_gles_contexts", (@convention(c) () -> Int32).self)

    /// Identifies this exact emulator build (a saved state only restores into the build that wrote it).
    var buildString: String {
        (buildID?()).map { String(cString: $0) } ?? "\(path)-\(isJIT)"
    }
    lazy var audioStart = sym("qemu_ios_audio_capture_start", (@convention(c) () -> UInt64).self)
    lazy var audioRead = sym("qemu_ios_audio_capture_read", (@convention(c) (UInt64, UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<Double>) -> Int32).self)
    lazy var audioStop = sym("qemu_ios_audio_capture_stop", (@convention(c) (UInt64) -> Void).self)
    lazy var deviceInfoAt = sym("qemu_ios_device_info_at", (@convention(c) (Int32) -> UnsafeRawPointer?).self)

    // The rest of the host API the Mac app drives. All optional: an older emulator build simply lacks them, and
    // every caller checks for nil rather than crashing.
    //
    // Input
    lazy var touch2 = optionalSym("qemu_ios_ui_touch2", (@convention(c) (Int32, Double, Double) -> Void).self)
    lazy var manualTouch2 = optionalSym("qemu_ios_ui_manual_touch2", (@convention(c) (Bool) -> Void).self)
    lazy var rotate = optionalSym("qemu_ios_ui_rotate", (@convention(c) (Bool) -> Void).self)
    lazy var orientation = optionalSym("qemu_ios_ui_orientation", (@convention(c) (Int32) -> Bool).self)
    lazy var shake = optionalSym("qemu_ios_ui_shake", (@convention(c) () -> Void).self)
    lazy var keyMac = optionalSym("qemu_ios_ui_key_mac", (@convention(c) (Int32, Bool) -> Void).self)
    // The phone's microphone into the S5L8920/A4 machines' I2S capture (ios/patches/qemu-ios/0007).
    lazy var micWrite = optionalSym("qemu_ios_mic_write", (@convention(c) (UnsafePointer<Int16>?, Int32) -> Int32).self)
    lazy var micEnable = optionalSym("qemu_ios_mic_enable", (@convention(c) (Bool) -> Void).self)
    lazy var micListening = optionalSym("qemu_ios_mic_listening", (@convention(c) () -> Bool).self)
    /// An abandoned preparation copy's guest RAM, handed back (qemu-ios patch 0014); the bytes released.
    lazy var releaseGuestMemory = optionalSym("qemu_ios_release_guest_memory", (@convention(c) () -> UInt64).self)
    lazy var hardwareKeyboard = optionalSym("qemu_ios_ui_hardware_keyboard", (@convention(c) (Bool) -> Bool).self)
    /// The panel's frame rate while running (qemu-ios patch 0018), for AutoCool.
    lazy var setRefreshHz = optionalSym("qemu_ios_ui_set_refresh_hz", (@convention(c) (UInt32) -> Bool).self)
    lazy var cancelInput = optionalSym("qemu_ios_ui_cancel_input", (@convention(c) () -> Void).self)
    // Sensors the real phone can stand in for
    lazy var attitude = optionalSym("qemu_ios_ui_attitude", (@convention(c) (Double, Double, Int32) -> Void).self)
    lazy var compass = optionalSym("qemu_ios_ui_compass", (@convention(c) (Int32) -> Bool).self)
    lazy var battery = optionalSym("qemu_ios_ui_battery", (@convention(c) (Int32, Int32) -> Bool).self)
    lazy var usbConnection = optionalSym("qemu_ios_ui_usb_connection", (@convention(c) (Bool) -> Bool).self)
    lazy var usbCharger = optionalSym("qemu_ios_ui_usb_charger", (@convention(c) (Bool) -> Bool).self)
    lazy var vibrator = optionalSym("qemu_ios_ui_vibrator", (@convention(c) (UnsafeMutablePointer<UInt64>) -> Bool).self)
    // What the device is doing
    lazy var displaySleeping = optionalSym("qemu_ios_ui_display_sleeping", (@convention(c) () -> Bool).self)
    lazy var backlightLevel = optionalSym("qemu_ios_ui_backlight_level", (@convention(c) () -> Int32).self)
    lazy var storageFailed = optionalSym("qemu_ios_ui_storage_failed", (@convention(c) () -> Bool).self)
    lazy var shutdownConfirmed = optionalSym("qemu_ios_ui_guest_shutdown_confirmed", (@convention(c) () -> Bool).self)
    // Running state
    lazy var pause = optionalSym("qemu_ios_ui_pause", (@convention(c) () -> Void).self)
    lazy var resume = optionalSym("qemu_ios_ui_resume", (@convention(c) () -> Void).self)
    lazy var reset = optionalSym("qemu_ios_ui_reset", (@convention(c) () -> Void).self)
    lazy var shutdown = optionalSym("qemu_ios_ui_shutdown", (@convention(c) () -> Int32).self)
    // Pasteboard: paste takes UTF-8, the guest's copy comes back malloc'd and is freed with free().
    lazy var paste = optionalSym("qemu_ios_ui_paste", (@convention(c) (UnsafePointer<CChar>) -> Void).self)
    lazy var guestPasteboard = optionalSym(
        "qemu_ios_ui_guest_pasteboard",
        (@convention(c) (UnsafeMutablePointer<UInt64>) -> UnsafeMutablePointer<CChar>?).self)
    // Networking policy
    lazy var netRestrict = optionalSym("qemu_ios_ui_net_restrict", (@convention(c) (UnsafePointer<CChar>, Bool) -> Void).self)
    lazy var netLAN = optionalSym("qemu_ios_ui_net_lan", (@convention(c) (UnsafePointer<CChar>, Bool) -> Void).self)

    // The fake cellular baseband (hw/misc/ios_baseband.c), on the iPhones only. Properties are set by name:
    // carrier, signal-dbm, registered, sim-present, incoming-call, incoming-sms ("<number>|<text>"),
    // remote-answer, remote-hangup. modem_status hands back a JSON snapshot (and refreshes it for next time).
    lazy var modemSet = optionalSym(
        "qemu_ios_ui_modem_set", (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Bool).self)
    lazy var modemStatus = optionalSym(
        "qemu_ios_ui_modem_status", (@convention(c) () -> UnsafeMutablePointer<CChar>?).self)
    lazy var modemFree = optionalSym(
        "qemu_ios_ui_modem_free", (@convention(c) (UnsafeMutablePointer<CChar>) -> Void).self)

    // Guest agent (contrib/it-agent, optional — absent in old builds)
    lazy var agentRequest = optionalSym("qemu_ios_agent_request", (@convention(c) (UnsafePointer<CChar>) -> Bool).self)
    lazy var agentCancel = optionalSym("qemu_ios_agent_cancel", (@convention(c) (UnsafePointer<CChar>) -> Void).self)
    lazy var agentResult = optionalSym("qemu_ios_agent_result", (@convention(c) () -> UnsafeMutablePointer<CChar>?).self)
    lazy var agentFreeResult = optionalSym("qemu_ios_agent_free_result", (@convention(c) (UnsafeMutablePointer<CChar>) -> Void).self)
    lazy var agentStatus = optionalSym("qemu_ios_agent_status", (@convention(c) () -> Int32).self)
    lazy var agentReport = optionalSym("qemu_ios_agent_report", (@convention(c) (UnsafeMutablePointer<UInt64>) -> UnsafeMutablePointer<CChar>?).self)

    private struct InfoC {
        var machine: UnsafePointer<CChar>?
        var board: UnsafePointer<CChar>?
        var screenWidth, screenHeight, screenScale, defaultOrientation: Int32
        var hasCellular, hasUSBHost, hasCompass, hasUSBCharger: Bool
        var panelMin, panelMaxWidth, panelMaxHeight, panelWidthStep, panelMaxPixels: Int32
    }

    /// Every machine the library runs, handed to HostRuntime's Machines table (what Board.hardware reads).
    func registerMachines() {
        var list: [DeviceInfo] = []
        while let raw = deviceInfoAt(Int32(list.count)) {
            let c = raw.load(as: InfoC.self)
            func s(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }
            list.append(DeviceInfo(
                machine: s(c.machine), board: s(c.board), screenWidth: Int(c.screenWidth), screenHeight: Int(c.screenHeight),
                screenScale: Int(c.screenScale), defaultOrientation: Int(c.defaultOrientation), hasCellular: c.hasCellular,
                hasUSBHost: c.hasUSBHost, hasCompass: c.hasCompass, panelMin: Int(c.panelMin), panelMaxWidth: Int(c.panelMaxWidth),
                panelMaxHeight: Int(c.panelMaxHeight), panelWidthStep: Int(c.panelWidthStep), panelMaxPixels: Int(c.panelMaxPixels)))
        }
        Machines.set(list)
    }
}
