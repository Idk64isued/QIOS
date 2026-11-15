import Foundation

#if canImport(FirmwareKit)
import FirmwareKit

/// FirmwareKit's preparation boots (the keybag, seal and check boots of iOS 4 data protection and the A4/S5L8920
/// boards), run in this process. The Mac app starts each in a helper process; iOS starts no processes, and QEMU starts
/// only once per library image (it never releases what it allocates). So every boot loads its own copy of the
/// emulator library — a copied file is a new image with fresh globals, under the same code signature — runs it
/// headless on a thread, and is abandoned when the boot ends. The memory it held stays taken until Light Touch quits,
/// which is why the plan says to restart the app after preparing.
enum OneShotRunner {
    private static var installed = false

    /// Hands FirmwareKit the runner and the emulator's machine list (the recipes look their board's machine up).
    static func install() {
        guard !installed else { return }
        installed = true
        sweep()
        // The iPod touch 2G keybag boot loads its bootrom from Documents/Device (FirmwareKit reads LTM_FILES).
        let files = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Device")
        setenv("LTM_FILES", files.path, 1)
        if let main = try? QemuRuntime.load() { main.registerMachines() }
        InProcessOneShot.run = { request, log in try run(request, log: log) }
    }

    /// What the recipes take as their helper (they check it is an executable file and record its hash): a small
    /// stand-in, since the boots run here. The app's own executable can't be it: under LiveContainer it isn't
    /// marked executable.
    static func helperStandIn() -> URL? {
        let fm = FileManager.default
        let url = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LightTouchDevice")
        if !fm.isExecutableFile(atPath: url.path) {
            try? fm.removeItem(at: url)
            guard fm.createFile(atPath: url.path, contents: Data("#!/bin/false\nLight Touch runs its preparation boots in-process.\n".utf8))
            else { return nil }
            chmod(url.path, 0o755)
        }
        return fm.isExecutableFile(atPath: url.path) ? url : nil
    }

    private static var root: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oneshot", isDirectory: true)
    }

    /// Copies left by earlier launches (each was in use until its process ended).
    private static func sweep() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A fresh image of the emulator library: the JIT build when JIT is on, else the interpreter.
    private static func freshLibrary() throws -> QemuRuntime {
        let dir = Bundle.main.privateFrameworksPath ?? (Bundle.main.bundlePath + "/Frameworks")
        let jit = dir + "/libqemu-arm.dylib", tci = dir + "/libqemu-arm-tci.dylib"
        let fm = FileManager.default
        var candidates: [(String, Bool)] = []
        if JIT.ready, fm.fileExists(atPath: jit) { candidates.append((jit, true)) }
        if fm.fileExists(atPath: tci) { candidates.append((tci, false)) }
        var errors: [String] = []
        for (source, isJIT) in candidates {
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let copy = folder.appendingPathComponent((source as NSString).lastPathComponent)
                try fm.copyItem(atPath: source, toPath: copy.path)
                return try QemuRuntime(path: copy.path, isJIT: isJIT)
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        throw FirmwareError(
            .oneshotFailed,
            "no emulator library could be loaded for the preparation boot: " + (errors.isEmpty ? "none bundled" : errors.joined(separator: "; ")))
    }

    final class Flags: @unchecked Sendable {
        private let lock = NSLock()
        private var _exited = false, _code: Int32 = 0
        func finish(_ code: Int32) { lock.lock(); _exited = true; _code = code; lock.unlock() }
        var exited: (Bool, Int32) { lock.lock(); defer { lock.unlock() }; return (_exited, _code) }
    }

    static func run(_ request: InProcessOneShot.Request, log: (String) -> Void) throws -> InProcessOneShot.Result {
        let qemu = try freshLibrary()
        var argv = request.argv
        if !argv.contains("-accel") {
            // A seal boot runs a whole iOS start-up (launchd, SpringBoard, the daemons): a code cache big enough to
            // hold it all means nothing is translated twice. Its pages are only used as they fill.
            argv += qemu.isJIT ? ["-accel", "tcg,tb-size=256,split-wx=on"] : ["-accel", "tcg,tb-size=64"]
        }
        // The interpreter runs these boots several times slower than JIT; the recipes' limits are for JIT speed.
        let timeout = request.timeout * (qemu.isJIT ? 1.5 : 6)
        log("one-shot: in-process on \(qemu.isJIT ? "JIT" : "the interpreter"), limit \(Int(timeout)) s")
        LTMLog.note("oneshot args \(argv.joined(separator: " "))")
        let flags = Flags()
        let start = Date()
        let thread = Thread { [argv] in
            var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
            cargs.append(nil)
            let rc = qemu.main(Int32(argv.count), &cargs)
            flags.finish(rc)
        }
        thread.name = "qemu-oneshot"
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInteractive
        thread.start()

        var marker = false
        var stopping = false
        while true {
            usleep(500_000)
            if flags.exited.0 { break }
            if request.stopMarker != nil || request.stopPattern != nil,
                let text = try? String(contentsOf: request.serial, encoding: .isoLatin1)
            {
                if let stop = request.stopMarker, text.contains(stop) { marker = true }
                if let pattern = request.stopPattern,
                    text.replacingOccurrences(of: "\n", with: "").range(of: pattern, options: .regularExpression) != nil
                {
                    marker = true
                }
            }
            if marker || request.shouldStop() || Date().timeIntervalSince(start) > timeout {
                stopping = true
                qemu.quit()
                let deadline = Date().addingTimeInterval(10)
                while !flags.exited.0, Date() < deadline { usleep(50_000) }
                if !flags.exited.0 { qemu.pause?() }  // it would not stop: at least stop it using the CPU
                break
            }
        }
        let (exited, code) = flags.exited
        return InProcessOneShot.Result(
            exited: exited && !stopping, exitCode: exited ? code : -1, marker: marker,
            seconds: Date().timeIntervalSince(start))
    }
}
#else
enum OneShotRunner {
    static func install() {}
}
#endif
