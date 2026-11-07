import Darwin
import Foundation
import Testing

@testable import HostRuntime

struct DebugPortTests {
    /// The gdbstub is a Unix socket in the per-user temporary directory, never TCP.
    @Test func aUnixSocketOnlyThisUserReaches() throws {
        let path = DebugPort.socketPath()
        #expect(path.utf8.count < 104 && path != DebugPort.socketPath())
        #expect(DebugPort.arguments(socket: path) == ["-gdb", "unix:\(path),server=on,wait=off"])
        #expect(!DebugPort.arguments(socket: path).joined().contains("tcp:"))
        var directory = stat()
        #expect(stat(URL(fileURLWithPath: path).deletingLastPathComponent().path, &directory) == 0)
        #expect(directory.st_uid == getuid() && directory.st_mode & 0o077 == 0, "TMPDIR is the user's, 0700")
        #expect(DebugPort.arguments(socket: "/tmp/a,b.sock")[1].hasPrefix("unix:/tmp/a,,b.sock,"))
    }

    @Test func lldbCommandPerBoard() {
        #expect(DebugPort.lldbCommand(board: "m68ap", socket: "/s").contains("--arch armv6-apple-ios"))
        #expect(DebugPort.lldbCommand(board: "k48ap", socket: "/s").contains("--arch armv7-apple-ios"))
        #expect(DebugPort.lldbCommand(board: "n81ap", socket: "/s").contains("process connect unix-connect:///s"))
    }
}
