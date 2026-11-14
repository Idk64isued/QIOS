import Foundation
import HostRuntime
import UIKit

/// One emulator per process: QEMU cannot be started twice, so after Quit the app has to be relaunched.
@MainActor
final class Emulator: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case saving
        case saved
        case failed(String)
    }

    /// The emulator screen is up (running, or being saved before the app closes).
    var showsScreen: Bool {
        switch state {
        case .running, .saving, .saved: return true
        default: return false
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var engine = "not loaded"
    private(set) var qemu: QemuRuntime?
    @Published private(set) var agent: GuestAgent?
    @Published private(set) var usb: USBSession?
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var audio: AudioPlayer?
    private var overlayURL: URL?
    @Published private(set) var saveMessage = ""

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
            // USB bridge is opt-in: passing usb-tcp-addr changes how the guest comes up. Without it, boot is exactly
            // like it was before the USB stack existed. The Settings menu has a toggle.
            let enableUSB = UserDefaults.standard.object(forKey: "enableUSB") as? Bool ?? false
            let usbSession = enableUSB ? (try? USBSession()) : nil
            if enableUSB {
                if let usbSession { self.usb = usbSession } else { LTMLog.note("usb: bridge not started") }
            }
            var config = try Self.bootConfig(directory: directory, usbAddress: usbSession?.qemuAddress)
            var argv = config.argv
            // iOS gives a process no 1 GiB code buffer worth of headroom: ask for a modest one. Split W^X is how
            // JIT works under CS_DEBUGGED/TXM (tcg/region.c); TCI has no code buffer to split.
            // The code cache has to hold the translated guest code or QEMU throws it all away and translates again
            // ("tb_flush"), which is slow; its pages are only used as they are filled. Settings can change the size.
            let configured = UserDefaults.standard.integer(forKey: "codeCacheMB")
            let cacheMB = configured > 0 ? configured : 512
            argv += qemu.isJIT ? ["-accel", "tcg,tb-size=\(cacheMB),split-wx=on"] : ["-accel", "tcg,tb-size=32"]

            // A saved state (Save & quit) restores in seconds instead of booting again.
            let overlay = directory.appendingPathComponent("overlay", isDirectory: true)
            overlayURL = overlay
            let snaps = Snapshots(overlay: overlay)
            var resumed = false
            if snaps.usable(build: qemu.buildString) {
                argv += ["-incoming", "file:\(snaps.file.path)"]
                resumed = true
            } else {
                snaps.discard()
            }

            config.argv = argv
            for (key, value) in config.environment { setenv(key, value, 1) }
            // Diagnostics: the emulator's own log (stderr) goes to lighttouch.log, and IT_VCPU_ACCT=5 makes it report every
            // five seconds whether the guest CPU is running, halted (waiting for an interrupt) or doing I/O.
            LTMLog.start()
            if UserDefaults.standard.object(forKey: "diag") as? Bool ?? true {
                setenv("IT_VCPU_ACCT", "5", 1)
                setenv("IT_GLES_PROF", "1", 1)  // where the graphics frame time goes, reported next to the frame rate
            }
            LTMLog.note("engine \(qemu.isJIT ? "JIT" : "TCI"), \(JIT.summary)")
            LTMLog.note("args \(argv.joined(separator: " "))")
            // Optional: skip the renderer's per-call GL error checks (each one makes the GPU driver catch up).
            if UserDefaults.standard.bool(forKey: "fastGL") { setenv("IT_GLES_STRICT", "0", 1) }
            // The graphics fix: rectangle textures (what the iPod touch 2G composites with) drawn as plain 2D textures.
            setenv("IT_GLES_RECT2D", (UserDefaults.standard.object(forKey: "rect2d") as? Bool ?? true) ? "1" : "0", 1)
            try? FileManager.default.createDirectory(at: directory.appendingPathComponent("logs"), withIntermediateDirectories: true)
            qemu.attach(nil, nil)  // the view polls qemu_ios_ui_frame on its display link; no push callback
            started = true
            state = .running
            let thread = Thread { [argv, resumed, snaps] in
                var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
                cargs.append(nil)
                let rc = qemu.main(Int32(argv.count), &cargs)
                NSLog("LightTouch: qemu_ios_main returned \(rc)")
                if resumed { snaps.discard() }  // a restore that did not take must not be tried again
                Task { @MainActor [weak self] in self?.state = .failed("The emulator stopped (exit \(rc)).") }
            }
            thread.name = "qemu-main"
            thread.stackSize = 16 << 20
            thread.qualityOfService = .userInteractive
            thread.start()
            LTMLog.sample { [weak self] in self != nil }
            watchLifecycle(qemu)
            audio = AudioPlayer(qemu: qemu)
            audio?.start()
            if resumed { retireSnapshot(snaps, qemu: qemu) }
            // Start the guest agent bridge — it probes once the emulator is running.
            let ga = GuestAgent(qemu: qemu)
            agent = ga
            Task.detached {
                // Give the guest a few seconds to boot before probing the agent
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await ga.probe()
                await ga.checkShellCapabilities()
            }
            // The USB bridge too — the guest's USB core comes up ~100 s after boot.
            usb?.waitForGuest()
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

    /// A restored snapshot is used once: as soon as the guest is drawing again (so the file has been read), delete it,
    /// because from here the guest writes to the disk and the old RAM image would no longer match.
    private func retireSnapshot(_ snaps: Snapshots, qemu: QemuRuntime) {
        Task.detached {
            var serial: UInt64 = 0
            var pixels: UnsafeRawPointer?
            var w: Int32 = 0, h: Int32 = 0
            for _ in 0..<2400 {  // up to ten minutes
                if qemu.ready(), qemu.frame(&pixels, &w, &h, &serial) {
                    snaps.discard()
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Saves the whole machine, then closes the app. The next launch restores it instead of booting.
    func saveAndQuit() {
        guard let qemu, let overlay = overlayURL, state == .running else { return }
        let snaps = Snapshots(overlay: overlay)
        snaps.discardTemp()
        state = .saving
        saveMessage = "Saving the device…"
        snaps.tmp.path.withCString { qemu.snapshotSave2($0) }
        Task { [weak self] in
            var buffer = [CChar](repeating: 0, count: 512)
            let started = Date()
            while true {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let code = qemu.snapshotStatus(&buffer, UInt(buffer.count))
                if code == 2 {
                    do {
                        try snaps.promote(build: qemu.buildString)
                        self?.state = .saved
                        self?.saveMessage = "Saved. Closing…"
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        exit(0)
                    } catch {
                        self?.fail(save: error.localizedDescription, qemu: qemu)
                    }
                    return
                }
                if code == 3 {
                    let reason = String(cString: buffer)
                    self?.fail(save: reason.isEmpty ? "the emulator refused" : reason, qemu: qemu)
                    return
                }
                if Date().timeIntervalSince(started) > 180 {
                    self?.fail(save: "it took too long", qemu: qemu)
                    return
                }
            }
        }
    }

    /// A save that did not work: start the guest again so the device is not left frozen.
    private func fail(save reason: String, qemu: QemuRuntime) {
        qemu.snapshotResume()
        state = .running
        saveMessage = "Could not save (\(reason)). The device keeps running."
    }

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
    static func bootConfig(directory: URL, usbAddress: String? = nil) throws -> BootConfig {
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
            hardware: hardware, bootArgs: "amfi_allow_any_signature=1 cs_enforcement_disable=1", usbAddress: usbAddress, wifi: false,
            guestPackage: nil, serial: "null", audio: ["-audio", "driver=none"], netdev: nil)
    }
}
