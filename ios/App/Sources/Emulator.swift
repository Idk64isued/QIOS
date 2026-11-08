import Foundation
import HostRuntime
import UIKit

/// One emulator per process: QEMU cannot be started twice, so after Quit the app has to be relaunched.
@MainActor
final class Emulator: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var engine = "not loaded"
    private(set) var qemu: QemuRuntime?
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var audio: AudioPlayer?

    /// Loads the library that suits this launch (JIT when StikDebug has enabled it, else the interpreter).
    func load() {
        guard qemu == nil else { return }
        do {
            let q = try QemuRuntime.load()
            q.registerMachines()
            qemu = q
            engine = q.isJIT ? "JIT (TCG)" : "interpreter (TCI, slow)"
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Boots the prepared device in `directory` (a folder holding base/ and, once booted, overlay/).
    func boot(directory: URL) {
        load()
        guard let qemu, !started else {
            if started { state = .failed("The emulator already ran in this launch. Quit and reopen the app to start another device.") }
            return
        }
        do {
            var config = try Self.bootConfig(directory: directory)
            var argv = config.argv
            // iOS gives a process no 1 GiB code buffer worth of headroom: ask for a modest one. Split W^X is how
            // JIT works under CS_DEBUGGED/TXM (tcg/region.c); TCI has no code buffer to split.
            argv += qemu.isJIT ? ["-accel", "tcg,tb-size=192,split-wx=on"] : ["-accel", "tcg,tb-size=32"]
            config.argv = argv
            for (key, value) in config.environment { setenv(key, value, 1) }
            try? FileManager.default.createDirectory(at: directory.appendingPathComponent("logs"), withIntermediateDirectories: true)
            qemu.attach(nil, nil)  // the view polls qemu_ios_ui_frame on its display link; no push callback
            started = true
            state = .running
            let thread = Thread { [argv] in
                var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
                cargs.append(nil)
                let rc = qemu.main(Int32(argv.count), &cargs)
                NSLog("LightTouch: qemu_ios_main returned \(rc)")
                Task { @MainActor [weak self] in self?.state = .failed("The emulator stopped (exit \(rc)).") }
            }
            thread.name = "qemu-main"
            thread.stackSize = 16 << 20
            thread.qualityOfService = .userInteractive
            thread.start()
            watchLifecycle(qemu)
            audio = AudioPlayer(qemu: qemu)
            audio?.start()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func press(_ button: Int32) {
        guard let qemu else { return }
        qemu.button(button, true)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) { qemu.button(button, false) }
    }

    func quit() { qemu?.powerdown() }

    /// iOS kills a process that issues GL commands in the background, so the emulator is told BEFORE it happens.
    private func watchLifecycle(_ qemu: QemuRuntime) {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            qemu.setForeground?(false)
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            qemu.setForeground?(true)
        })
    }

    // MARK: - argv

    enum BootError: LocalizedError {
        case noLock(URL), unknownBoard(String), noMachine(String)
        var errorDescription: String? {
            switch self {
            case .noLock(let u): "No device.lock.json in \(u.path). Copy a prepared device's base/ folder here (see ios/README.md)."
            case .unknownBoard(let b): "Unknown board \(b)."
            case .noMachine(let b): "The emulator library has no machine for \(b)."
            }
        }
    }

    /// Where the SecureROM images live (Documents/Device/bootrom_240_4, Documents/Device/ipod1g/bootrom_s5l8900).
    static var filesRoot: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Device").path
    }

    /// The same argv the Mac app builds (HostRuntime's PreparedDeviceBoot), minus what needs a helper process:
    /// no web proxy / Wi-Fi, no USB bridge (usbmuxd), no guest package. Sound is played from the emulator's mixer (AudioPlayer).
    static func bootConfig(directory: URL) throws -> BootConfig {
        let base = directory.appendingPathComponent("base", isDirectory: true)
        let overlay = directory.appendingPathComponent("overlay", isDirectory: true)
        guard let lock = try DeviceLock.read(base: base) else { throw BootError.noLock(base) }
        guard let name = lock.board, let board = Board(rawValue: name) else { throw BootError.unknownBoard(lock.board ?? "?") }
        guard let hardware = board.hardware else { throw BootError.noMachine(name) }
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)

        // Boards that boot from NOR write to a private copy of it.
        var writableNOR: URL?
        if !board.isKBoot || lock.bootStrategy == "iboot" || lock.bootStrategy == "bootrom" {
            let source = base.appendingPathComponent("nor.bin")
            let copy = overlay.appendingPathComponent("nor.bin")
            if FileManager.default.fileExists(atPath: source.path) {
                if !FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.copyItem(at: source, to: copy) }
                writableNOR = copy
            }
        }
        let prepared = try PreparedDeviceBoot.prepare(
            board: board, base: base, overlay: overlay, writableNOR: writableNOR, storageKey: nil,
            bootrom: BootRecipe.bootrom(board.bootrom, filesRoot: filesRoot))
        return try prepared.configuration(
            hardware: hardware, bootArgs: "amfi_allow_any_signature=1 cs_enforcement_disable=1", usbAddress: nil, wifi: false,
            guestPackage: nil, serial: "null", audio: ["-audio", "driver=none"], netdev: nil)
    }
}
