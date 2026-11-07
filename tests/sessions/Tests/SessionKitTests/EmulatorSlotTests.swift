import Foundation
import SessionKit
import Testing

struct EmulatorSlotTests {
    /// With two slots, two holders get one each and a third gets none; a slot is free again once its holder lets go,
    /// and a holder that dies frees its slot too.
    @Test func aSlotIsHeldUntilItsHolderLetsGo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try #require(EmulatorSlot.take(directory: dir, count: 2))
        let second = try #require(EmulatorSlot.take(directory: dir, count: 2))
        #expect(first.slot != second.slot)
        #expect(EmulatorSlot.take(directory: dir, count: 2) == nil)
        close(first.fd)
        let again = try #require(EmulatorSlot.take(directory: dir, count: 2))
        #expect(again.slot == first.slot)
        close(again.fd)
        close(second.fd)

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = [
            "-e", #"use Fcntl ":flock"; open F, ">>", $ARGV[0]; flock(F, LOCK_EX) or die; sleep 30"#,
            dir.appendingPathComponent("slot-0").path
        ]
        try holder.run()
        let deadline = Date().addingTimeInterval(10)
        var taken: (slot: Int, fd: Int32)?
        repeat {
            taken = EmulatorSlot.take(directory: dir, count: 1)
            if let taken { close(taken.fd) }
            usleep(50_000)
        } while taken != nil && Date() < deadline
        #expect(taken == nil)
        holder.terminate()
        holder.waitUntilExit()
        let freed = try #require(EmulatorSlot.take(directory: dir, count: 1))
        close(freed.fd)
    }
}
