import Darwin
import Foundation

@_silgen_name("csops")
private func c_csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

/// What the process knows about JIT right now. StikDebug (or any debugger) sets CS_DEBUGGED on the process it
/// attaches to; on iOS 26 TXM devices it also stays attached until the app detaches (see tcg/region.c).
enum JIT {
    /// CS_DEBUGGED: stays set after the debugger detaches. Enough for JIT on non-TXM devices.
    static var csDebugged: Bool {
        var flags: UInt32 = 0
        return c_csops(getpid(), 0 /* CS_OPS_STATUS */, &flags, MemoryLayout<UInt32>.size) == 0 && (flags & 0x1000_0000) != 0
    }

    /// P_TRACED: a debugger is attached right now (what TXM JIT needs).
    static var traced: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    static var hardware: String {
        var u = utsname()
        uname(&u)
        return withUnsafePointer(to: &u.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
    }

    /// Mirrors StikDebug's ProcessInfo.hasTXM (and tcg/region.c ios_has_txm).
    static var hasTXM: Bool {
        guard #available(iOS 26, *) else { return false }
        if #available(iOS 27, *) { return hardware != "iPad8,11" && hardware != "iPad8,12" }
        let h = hardware
        let ipad = h.hasPrefix("iPad")
        let parts = h.dropFirst(ipad ? 4 : 6).split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        return parts[0] > 14 || (parts[0] == 14 && parts[1] >= (ipad ? 5 : 2))
    }

    /// True inside LiveContainer (best effort: it sets LC_* environment variables for its guests).
    static var inLiveContainer: Bool {
        ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("LC_") }
    }

    /// JIT is usable now: non-TXM needs CS_DEBUGGED; TXM needs the debugger attached to bless the region.
    static var ready: Bool { hasTXM ? traced : csDebugged }

    static var summary: String {
        "device \(hardware), \(hasTXM ? "TXM" : "non-TXM"), CS_DEBUGGED \(csDebugged ? "yes" : "no"), debugger attached \(traced ? "yes" : "no")"
            + (inLiveContainer ? ", LiveContainer" : "")
    }
}
