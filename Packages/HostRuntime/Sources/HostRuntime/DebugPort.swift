// The per-device debug port: QEMU's gdbstub on a Unix socket only this user can reach, and the lldb command that
// attaches to it (qemu-ios docs/guest-debug.md: kernel and userland debugging through imgtools/lldb/xnu.py).

import Foundation

public nonisolated enum DebugPort {
    /// QEMU's argv for a gdbstub on the Unix socket `path`. The stub has no authentication, so it is never on TCP:
    /// the socket is in the per-user temporary directory (0700, as usbmuxd's and the web proxy's are), and a socket
    /// takes a connection only from who may write it (its owner). A sandboxed helper can't bind there: its spawner
    /// binds `path` and hands it the listener (listenerArguments).
    public static func arguments(socket path: String) -> [String] {
        ["-gdb", "unix:\(path.replacingOccurrences(of: ",", with: ",,")),server=on,wait=off"]
    }

    /// QEMU's argv for a gdbstub accepting on the listening socket `fd`, which the caller bound.
    public static func listenerArguments(fd: Int32) -> [String] {
        ["-chardev", "socket,id=ltm-gdb,fd=\(fd),server=on,wait=off", "-gdb", "chardev:ltm-gdb"]
    }

    /// The socket `argv`'s gdbstub listens on (arguments(socket:)), nil without one.
    public static func socket(in argv: [String]) -> String? {
        guard let i = argv.firstIndex(of: "-gdb"), i + 1 < argv.count, argv[i + 1].hasPrefix("unix:") else {
            return nil
        }
        let value = argv[i + 1].dropFirst("unix:".count).replacingOccurrences(of: ",,", with: "\u{1}")
        return String(value.prefix { $0 != "," }).replacingOccurrences(of: "\u{1}", with: ",")
    }

    /// `argv` with its gdbstub on the listener `fd` instead of its socket path, or with no gdbstub when nil.
    public static func replacingSocket(in argv: [String], withListener fd: Int32?) -> [String] {
        guard let i = argv.firstIndex(of: "-gdb"), i + 1 < argv.count, argv[i + 1].hasPrefix("unix:") else {
            return argv
        }
        return Array(argv[..<i]) + (fd.map(listenerArguments) ?? []) + Array(argv[(i + 2)...])
    }

    /// A listening Unix socket at `path` (an older one there unlinked), or nil.
    public static func listen(at path: String) -> Int32? {
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        unlink(path)
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok, chmod(path, 0o600) == 0, Darwin.listen(fd, 4) == 0 else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// A fresh socket path for one gdbstub (a Unix socket path stays under 104 bytes).
    public static func socketPath(_ prefix: String = "gdb") -> String {
        HelperSandbox.socketPath(prefix + "-" + UUID().uuidString.prefix(8) + ".sock")
    }

    /// lldb attached to the stub at `socket`.
    public static func lldbConnect(socket: String) -> String { "process connect unix-connect://\(socket)" }

    /// What to paste into Terminal. KERNELCACHE stays a placeholder: the decrypted kernel lives in the firmware,
    /// not in the device (qemu-ios docs/guest-debug.md lists where each board's comes from).
    public static func lldbCommand(board: String, socket: String) -> String {
        "lldb -o 'target create --arch \(Board(rawValue: board)?.arch ?? "armv7")-apple-ios KERNELCACHE'"
            + " -o '\(lldbConnect(socket: socket))'"
            + " -o 'command script import QEMU_IOS/imgtools/lldb/xnu.py'"
    }
}
