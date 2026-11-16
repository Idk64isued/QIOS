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
            // The USB bridge is opt-in. Passing usb-tcp-addr switches off the host the emulator otherwise runs
            // in-process, so this app then owes the guest everything a host does: the listener goes up here, before
            // the machine starts, and USBHostBridge keeps driving it for the whole session.
            var enableUSB = UserDefaults.standard.object(forKey: "enableUSB") as? Bool ?? false
            // A hang-loop breaker: every boot that turns the bridge on counts a strike, and reaching a configured
            // device clears them. Two boots in a row where the device never came up turn the bridge off by itself,
            // so a device can never be left unbootable by a setting the user has to go and find.
            let strikes = UserDefaults.standard.integer(forKey: "usbStrikes")
            if enableUSB, strikes >= 2 {
                enableUSB = false
                UserDefaults.standard.set(false, forKey: "enableUSB")
                UserDefaults.standard.set(0, forKey: "usbStrikes")
                LTMLog.note("usb bridge: off again — the device did not come up over USB on the last two boots")
            }
            var usbSession: USBSession?
            if enableUSB {
                UserDefaults.standard.set(strikes + 1, forKey: "usbStrikes")
                do {
                    let session = try USBSession()
                    session.start()
                    usbSession = session
                    self.usb = session
                    LTMLog.note("usb bridge: on, listening on \(session.qemuAddress)")
                } catch {
                    LTMLog.note("usb bridge: could not start (\(error)); booting without it")
                }
            } else {
                LTMLog.note("usb bridge: off")
            }
            var config = try Self.bootConfig(directory: directory, usbAddress: usbSession?.qemuAddress)
            var argv = config.argv
            // The iPhones carry a fake cellular modem on UART1 (the iPod touch has none). It is what makes the
            // status bar, calls and texts work, and it is also the first thing to turn off when a phone boots to
            // the Home screen and then wedges: the machine takes baseband=off and leaves that serial line empty.
            if UserDefaults.standard.object(forKey: "cellularModem") as? Bool == false,
                let machineIndex = argv.firstIndex(of: "-M"), machineIndex + 1 < argv.count,
                argv[machineIndex + 1].hasPrefix("iPhone-")
            {
                argv[machineIndex + 1] += ",baseband=off"
                LTMLog.note("cellular modem: off for this boot")
            }
            // iOS gives a process no 1 GiB code buffer worth of headroom: ask for a modest one. Split W^X is how
            // JIT works under CS_DEBUGGED/TXM (tcg/region.c); TCI has no code buffer to split.
            // The code cache has to hold the translated guest code or QEMU throws it all away and translates again
            // ("tb_flush"), which is slow; its pages are only used as they are filled. Settings can change the size.
            let configured = UserDefaults.standard.integer(forKey: "codeCacheMB")
            let cacheMB = configured > 0 ? configured : 512
            argv += qemu.isJIT ? ["-accel", "tcg,tb-size=\(cacheMB),split-wx=on"] : ["-accel", "tcg,tb-size=32"]
            // Named threads ("CPU 0/TCG"), so the profiler (ThreadSampler) can find the virtual CPU.
            argv += ["-name", "LightTouch,debug-threads=on"]

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
            Reports.archivePreviousLog()   // the last session's log, before this one replaces it
            LTMLog.start()
            if UserDefaults.standard.object(forKey: "diag") as? Bool ?? true {
                setenv("IT_VCPU_ACCT", "5", 1)
                setenv("IT_GLES_PROF", "1", 1)  // where the graphics frame time goes, reported next to the frame rate
            }
            LTMLog.note("engine \(qemu.isJIT ? "JIT" : "TCI"), GL \(QemuRuntime.renderer.rawValue), \(JIT.summary)")
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
            if UserDefaults.standard.object(forKey: "diag") as? Bool ?? true {
                ThreadSampler.start { [weak self] in self != nil }
            }
            watchLifecycle(qemu)
            audio = AudioPlayer(qemu: qemu)
            audio?.start()
            if resumed { retireSnapshot(snaps, qemu: qemu) }
            // Start the guest agent bridge — it probes once the emulator is running.
            let ga = GuestAgent(qemu: qemu)
            ga.guestVersion = DeviceFolder(url: directory).details.version
            agent = ga
            Task.detached {
                // The guest takes ~10 s to reach a lit frame and its agent starts later still, so one probe three
                // seconds in always misses. Keep asking (slowly) until it answers or five minutes have passed.
                for attempt in 0..<60 {
                    try? await Task.sleep(nanoseconds: attempt < 6 ? 3_000_000_000 : 6_000_000_000)
                    if Task.isCancelled { return }
                    await ga.probe()
                    let status = await ga.status
                    if status == .alive {
                        await ga.checkShellCapabilities()
                        return
                    }
                }
            }
            // The bridge is already running; it keeps retrying on its own until the guest's USB core is up, which
            // takes about 100 seconds of boot.
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

    /// Ask iOS on the device to shut itself down, and wait until it says it has.
    ///
    /// This is the one that matters for keeping a device usable. The storage is only consistent once iOS has
    /// finished its own shutdown; a device whose app was closed while it was running has to repair its filesystem
    /// on the next boot, and on hardware this slow that repair takes longer than anyone will wait — which looks
    /// exactly like a device that will not start any more.
    func powerOffCleanly() {
        guard let qemu, state == .running else { return }
        state = .saving
        saveMessage = "Shutting the device down\u{2026}"
        qemu.powerdown()
        Task { [weak self] in
            let started = Date()
            while Date().timeIntervalSince(started) < 120 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if qemu.shutdownConfirmed?() == true {
                    self?.saveMessage = "The device is off. It will start cleanly next time."
                    self?.state = .saved
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    exit(0)
                }
            }
            // An older emulator library cannot say when the guest is done. Give iOS the time it needs and go.
            self?.saveMessage = "Closing\u{2026}"
            self?.state = .saved
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            exit(0)
        }
    }

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

    // MARK: - Background: surviving a swipe-away

    /// A background save holds the machine stopped; coming back restarts it.
    private var parked = false
    private var parking = false
    private var backToFront = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Whether this machine can be saved now: not with live guest GL (3.x with hardware graphics), which this host
    /// can't read back into a snapshot.
    var canSaveState: Bool {
        guard let qemu else { return false }
        return (qemu.glesContexts?() ?? 0) == 0
    }

    /// The app went to the background. iOS may kill it there at any time (and the app switcher's swipe does), so
    /// the machine is saved now and the next launch picks up where it was. A machine that can't be saved has its
    /// guest flush its storage instead, so a kill can't leave the disk half-written.
    func enterBackground(controls: DeviceControls) {
        guard let qemu, state == .running, !parked, !parking else { return }
        backToFront = false
        let keepState = UserDefaults.standard.object(forKey: "keepState") as? Bool ?? true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save the device") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        guard keepState, canSaveState, let overlay = overlayURL else {
            Task { [weak self] in
                _ = await self?.agent?.sync()
                if self?.backToFront == false { controls.suspend() }
                self?.endBackgroundTask()
            }
            return
        }
        let snaps = Snapshots(overlay: overlay)
        snaps.discardTemp()
        parking = true
        LTMLog.note("background: saving the device")
        snaps.tmp.path.withCString { qemu.snapshotSave2($0) }
        Task { [weak self] in
            var buffer = [CChar](repeating: 0, count: 512)
            let started = Date()
            var saved = false
            while Date().timeIntervalSince(started) < 25 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let code = qemu.snapshotStatus(&buffer, UInt(buffer.count))
                if code == 2 {
                    saved = (try? snaps.promote(build: qemu.buildString)) != nil
                    break
                }
                if code == 3 {
                    LTMLog.note("background: could not save (\(String(cString: buffer)))")
                    break
                }
            }
            guard let self else { return }
            self.parking = false
            if saved {
                self.parked = true
                LTMLog.note("background: saved in \(String(format: "%.1f", Date().timeIntervalSince(started))) s; a swipe-away resumes from here")
                if self.backToFront { self.enterForeground(controls: controls) }
            } else {
                snaps.discardTemp()
                qemu.snapshotResume()           // a failed or unfinished save leaves the machine stopped
                if !self.backToFront { controls.suspend() }
            }
            self.endBackgroundTask()
        }
    }

    /// Back in front: restart what the background stopped. The saved state is dropped, because from here on the
    /// guest writes to its disk and the old RAM image would no longer match it.
    func enterForeground(controls: DeviceControls) {
        guard state == .running else { return }
        backToFront = true
        if parking { return }                   // the save's end calls back in here
        if parked, let qemu {
            parked = false
            qemu.snapshotResume()
            if let overlay = overlayURL { Snapshots(overlay: overlay).discard() }
            controls.wake(resumeCPU: false)
        } else {
            controls.wake()
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
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
    /// The kernel's boot arguments: the Mac app's (LightTouchCore DeviceOptions.bootArgs), Settings › Verbose boot
    /// (-v: the kernel's text instead of the Apple logo) and Kernel console (the kernel logs to the serial port).
    static func bootArgs(_ defaults: UserDefaults = .standard) -> String {
        var args = "amfi_allow_any_signature=1 cs_enforcement_disable=1"
        if defaults.bool(forKey: "verboseBoot") { args += " -v" }
        if defaults.bool(forKey: "kernelConsole") { args += " serial=3 debug=0x8" }
        return args
    }

    static func bootConfig(directory: URL, usbAddress: String? = nil) throws -> BootConfig {
        let base = directory.appendingPathComponent("base", isDirectory: true)
        let overlay = directory.appendingPathComponent("overlay", isDirectory: true)
        guard let lock = try DeviceLock.read(base: base) else { throw BootError.noLock(base) }
        guard let name = lock.board, let board = Board(rawValue: name) else { throw BootError.unknownBoard(lock.board ?? "?") }
        guard let hardware = board.hardware else { throw BootError.noMachine(name) }
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)

        // Every board with a NOR gets a private, writable copy of it, as the Mac app gives one (PreparationJob: a
        // writable NOR whenever the base has nor.bin). That includes the kboot boards, which don't boot from it: their
        // nor.bin carries the effaceable storage the keybag boot wrote (iOS 4 data protection). Without it the iPhone
        // 4's kernel finds no effaceable content, keybagd can't load the system keybag ("FATAL KEYBAG ERROR:
        // kb_load"), and the device reboots "into restore mode" over and over.
        var writableNOR: URL?
        do {
            let source = base.appendingPathComponent("nor.bin")
            let copy = overlay.appendingPathComponent("nor.bin")
            if FileManager.default.fileExists(atPath: source.path) {
                if !FileManager.default.fileExists(atPath: copy.path) {
                    try FileManager.default.copyItem(at: source, to: copy)
                    // A saved state from before this device had its NOR holds a blank one in its RAM image, and
                    // restoring it would put that back over the copy just made (and every reboot inside the guest
                    // keeps it). It can't be used with the NOR the device now has: boot fresh instead.
                    Snapshots(overlay: overlay).discard()
                }
                // A device prepared on the phone has a read-only base (so its files can't change), and a copy keeps
                // that. The emulator opens this copy for writing, so it has to be writable.
                chmod(copy.path, 0o644)
                writableNOR = copy
            }
        }
        let prepared = try PreparedDeviceBoot.prepare(
            board: board, base: base, overlay: overlay, writableNOR: writableNOR, storageKey: nil,
            bootrom: BootRecipe.bootrom(board.bootrom, filesRoot: filesRoot))
        // Everything under overlay/ is this device's own working data, and the emulator writes to it. Copies made
        // from a read-only base can keep its lock, so unlock them all (folders too) before the boot.
        chmod(overlay.path, 0o755)
        if let walker = FileManager.default.enumerator(at: overlay, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let item as URL in walker {
                let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                chmod(item.path, isFolder ? 0o755 : 0o644)
            }
        }
        // Wi-Fi (Settings): the machine's own Wi-Fi card on QEMU's user network (slirp, in this process), the way the
        // Mac app's device reaches the internet, minus its web proxy. Off, the card isn't there at all.
        let defaults = UserDefaults.standard
        let wifi = defaults.bool(forKey: "wifiNetwork")
        let netdev = wifi
            ? "user,id=wifi0" + (defaults.bool(forKey: "netRestricted") ? ",restrict=on" : "")
                + (defaults.bool(forKey: "netLAN") ? "" : ",lan=off")
            : nil
        // The device's serial console (iBoot, the kernel with Kernel console on, the guest helpers) goes to
        // Documents/serial.log, rewritten every boot, for Console › Device and reports. It was "null": thrown away.
        try? FileManager.default.removeItem(at: LTMLog.serialURL)
        var config = try prepared.configuration(
            hardware: hardware, bootArgs: Self.bootArgs(), usbAddress: usbAddress, wifi: wifi,
            guestPackage: nil, serial: "file:" + LTMLog.serialURL.path, audio: ["-audio", "driver=none"], netdev: netdev,
            // Settings › Graphics: ANGLE draws ES 1.1 and ES 2.0 guests on Metal; off, the iPhone's own ES 1.1 GL.
            angle: QemuRuntime.renderer == .angle)
        if QemuRuntime.renderer == .es3, let m = config.argv.firstIndex(of: "-M"), m + 1 < config.argv.count {
            config.argv[m + 1] += ",gl-renderer=es3"
        }
        // No USB keyboard plugged in at boot. The Mac app always has one (its keyboard is the device's), but iOS 4
        // hides the on-screen keyboard while a hardware keyboard is connected, so on this phone, where you type on
        // the screen, every text field came up with no keyboard. KeyboardBridgeView plugs one in when a real keyboard
        // connected to this phone sends its first key (Settings › Hardware keyboard keys), and unplugs it when that
        // keyboard goes away.
        if let i = config.argv.firstIndex(where: { $0.hasPrefix("usb-kbd") }), i > 0, config.argv[i - 1] == "-device" {
            config.argv.removeSubrange((i - 1)...i)
        }
        // Cool mode (Settings): the panel's frame interrupt at 30 Hz (both LCD models' refresh-hz), so the guest's
        // Core Animation draws, and the emulator reads back, half as many frames.
        if defaults.bool(forKey: "coolMode") {
            config.argv += ["-global", "ipodtouch.lcd.refresh-hz=30", "-global", "s5l8930.display.refresh-hz=30"]
        }
        // Debug port (Settings): QEMU's gdbstub for lldb/gdb from another machine on this network. It has no password,
        // so it is off unless asked for, and only for that boot.
        if defaults.bool(forKey: "debugPort") {
            let port = defaults.integer(forKey: "debugPortNumber")
            config.argv += ["-gdb", "tcp::\(port > 0 ? port : 1234)"]
        }
        return config
    }
}
