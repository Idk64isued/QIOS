import Darwin
import Foundation

/// Counts frames the guest has drawn (read by the sampler, bumped by the display).
enum PerfStats {
    static var frames = 0
}

/// The process's own memory footprint, as Apple's jetsam counts it. Used during firmware preparation to warn when
/// the phone is close to the per-process limit.
enum MemoryStats {
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint) / (1024 * 1024)
    }
}

/// A log file you can send: Files > On My iPhone > LightTouch > lighttouch.log, rewritten every launch.
/// The emulator's own messages (stderr) land in it too, including the vCPU accounting switched on by IT_VCPU_ACCT.
enum LTMLog {
    private static var started = ProcessInfo.processInfo.systemUptime

    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("lighttouch.log")
    }

    static func start() {
        started = ProcessInfo.processInfo.systemUptime
        _ = freopen(url.path, "w", stderr)
        setvbuf(stderr, nil, _IOLBF, 0)
    }

    static func note(_ text: String) {
        let t = ProcessInfo.processInfo.systemUptime - started
        fputs("[ltm \(String(format: "%.1f", t))s] \(text)\n", stderr)
    }

    /// CPU seconds this process has used, all threads.
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6
            + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Writes one line every ten seconds: how much CPU the app is using (100% = one core fully busy) and how many
    /// frames per second the guest draws. A slow boot with low CPU means the emulator is waiting, not computing.
    static func sample(while keepGoing: @escaping () -> Bool) {
        Task.detached {
            var lastCPU = cpuSeconds()
            var lastWall = Date()
            var lastFrames = PerfStats.frames
            while keepGoing() {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                let cpu = cpuSeconds(), now = Date(), frames = PerfStats.frames
                let wall = max(now.timeIntervalSince(lastWall), 0.001)
                note(String(format: "cpu %.0f%% of one core, %.1f frames/s, thermal %@, low power %@", (cpu - lastCPU) / wall * 100,
                    Double(frames - lastFrames) / wall, thermal, ProcessInfo.processInfo.isLowPowerModeEnabled ? "ON" : "off"))
                lastCPU = cpu; lastWall = now; lastFrames = frames
            }
        }
    }
}
