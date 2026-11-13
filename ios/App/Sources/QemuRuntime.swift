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

    /// Identifies this exact emulator build (a saved state only restores into the build that wrote it).
    var buildString: String {
        (buildID?()).map { String(cString: $0) } ?? "\(path)-\(isJIT)"
    }
    lazy var audioStart = sym("qemu_ios_audio_capture_start", (@convention(c) () -> UInt64).self)
    lazy var audioRead = sym("qemu_ios_audio_capture_read", (@convention(c) (UInt64, UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<Double>) -> Int32).self)
    lazy var audioStop = sym("qemu_ios_audio_capture_stop", (@convention(c) (UInt64) -> Void).self)
    lazy var deviceInfoAt = sym("qemu_ios_device_info_at", (@convention(c) (Int32) -> UnsafeRawPointer?).self)

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
