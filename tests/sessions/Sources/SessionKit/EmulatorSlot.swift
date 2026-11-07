// One of a few host-wide emulator slots, so parallel agents don't overload the Mac: a slot is an flock on
// <directory>/slot-N, which the kernel drops when the holder exits or crashes. scripts/host-ready counts the free ones.
import Foundation

public enum EmulatorSlot {
    public static var directory: URL {
        let env = ProcessInfo.processInfo.environment
        return URL(
            fileURLWithPath: env["LTM_EMULATOR_SLOT_DIR"]
                ?? NSHomeDirectory() + "/Developer/ltm-scratch.noindex/.emulator-slots"
        )
    }
    public static var count: Int {
        Int(ProcessInfo.processInfo.environment["LTM_EMULATOR_SLOTS"] ?? "") ?? 3
    }

    /// A free slot's open, locked descriptor (held until it is closed or the process ends), or nil if all are taken.
    public static func take(directory: URL = directory, count: Int = count) -> (slot: Int, fd: Int32)? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for slot in 0..<count {
            let fd = open(directory.appendingPathComponent("slot-\(slot)").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return (slot, fd) }
            close(fd)
        }
        return nil
    }

    /// Waits for a slot (saying so once), polling every `interval` seconds.
    public static func wait(interval: UInt32 = 5, waiting: () -> Void) -> (slot: Int, fd: Int32) {
        var said = false
        while true {
            if let held = take() { return held }
            if !said {
                waiting()
                said = true
            }
            sleep(interval)
        }
    }
}
