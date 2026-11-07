import Foundation
import HostRuntime
import Testing

@testable import DeviceRuntime

/// A sandboxed helper's USB bridge: the app hands it each connection to usbmuxd over a private socket, so no path
/// another device's helper could take is involved; the helper's end admits only its own process's connections.
struct USBBridgeTests {
    /// A short folder of its own (sun_path holds 104 bytes).
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ub-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The request goes one way and a connected descriptor comes back, which reaches what the app connected it to.
    @Test func aConnectionCrossesTheBridgeSocket() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("g.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0 && listen(listener, 2) == 0)
        defer { close(listener) }
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { for fd in pair { close(fd) } }
        // the helper asks; the app connects and answers with the descriptor
        #expect(BridgeSocket.send(pair[1]))
        #expect(BridgeSocket.receive(pair[0]) == (true, .usb, -1))
        let host = try #require(BridgeSocket.connect(path))
        #expect(BridgeSocket.send(pair[0], descriptor: host))
        close(host)
        let (ok, _, received) = BridgeSocket.receive(pair[1])
        #expect(ok && received >= 0)
        let server = accept(listener, nil, nil)
        #expect(write(received, "usb", 3) == 3)
        var buffer = [UInt8](repeating: 0, count: 3)
        #expect(read(server, &buffer, 3) == 3 && buffer == Array("usb".utf8))
        close(server)
        close(received)
        // with nothing to connect to, the answer carries none
        #expect(BridgeSocket.connect(dir.appendingPathComponent("none.sock").path) == nil)
        #expect(BridgeSocket.send(pair[0]))
        #expect(BridgeSocket.receive(pair[1]) == (true, .usb, -1))
        // and the bridge's end sees the app's close
        close(pair[0])
        pair[0] = -1
        #expect(BridgeSocket.receive(pair[1]).ok == false)
    }

    /// The helper's bridge port admits this process's connections and refuses another process's (nc).
    @Test func theBridgeAdmitsOnlyItsOwnProcess() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, size) == 0 && listen(listener, 4) == 0 && getsockname(listener, $0, &size) == 0
            }
        }
        #expect(ok)
        defer { close(listener) }
        let port = UInt16(bigEndian: address.sin_port)

        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        other.arguments = ["127.0.0.1", "\(port)"]
        other.standardInput = Pipe()
        try other.run()
        defer { other.terminate() }
        let fromOther = accept(listener, nil, nil)
        #expect(!HelperSandbox.isOwnConnection(fromOther))
        close(fromOther)

        let mine = socket(AF_INET, SOCK_STREAM, 0)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(mine, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connected == 0)
        let fromMe = accept(listener, nil, nil)
        #expect(HelperSandbox.isOwnConnection(fromMe))
        close(fromMe)
        close(mine)
    }

    /// A sandboxed helper's QEMU dials its bridge instead of usbmuxd's socket; the app reads the socket from argv.
    @Test func argvsUSBAddressIsReadAndReplaced() {
        let argv = [
            "LightTouchMac", "-M", "iPod-Touch,nand=/b/nand,usb-tcp-addr=/T/ltm-mux-1-g.sock,osk=on", "-m", "128M"
        ]
        #expect(BootRecipe.usbAddress(in: argv) == "/T/ltm-mux-1-g.sock")
        let bridged = BootRecipe.replacingUSBAddress(in: argv, with: "127.0.0.1:5000")
        #expect(bridged[2] == "iPod-Touch,nand=/b/nand,usb-tcp-addr=127.0.0.1:5000,osk=on")
        #expect(BootRecipe.usbAddress(in: ["x", "ipad1,nand=/n,usb-tcp-addr=/g.sock"]) == "/g.sock")
        #expect(BootRecipe.usbAddress(in: ["x", "ipad1,nand=/n"]) == nil)
    }

    /// A sandboxed helper names neither its web proxy's socket nor its Debug Port's: QEMU hands the proxy each guest
    /// connection over a socket pair (fdpass:), and the gdbstub accepts on the listener the app bound.
    @Test func argvsWebProxyAndDebugPortAreHandedOver() {
        let netdev =
            "user,id=wifi0,restrict=on,guestfwd=tcp:10.0.2.100:3128-unix-connect:/T/ltm-proxy-a,,b.sock,lan=off"
        let argv = ["LightTouchMac", "-netdev", netdev] + DebugPort.arguments(socket: "/T/ltm-gdb-1.sock") + ["-S"]
        let forwarded = BootRecipe.replacingGuestForward(in: argv, withSocket: 7)
        #expect(forwarded[2] == "user,id=wifi0,restrict=on,guestfwd=tcp:10.0.2.100:3128-fdpass:7,lan=off")
        #expect(!forwarded.joined().contains("ltm-proxy"))
        #expect(DebugPort.socket(in: argv) == "/T/ltm-gdb-1.sock")
        #expect(DebugPort.socket(in: ["x", "-gdb", "unix:/T/a,,b.sock,server=on,wait=off"]) == "/T/a,b.sock")
        let debugged = DebugPort.replacingSocket(in: forwarded, withListener: 9)
        #expect(
            debugged == [
                "LightTouchMac", "-netdev", forwarded[2], "-chardev", "socket,id=ltm-gdb,fd=9,server=on,wait=off",
                "-gdb",
                "chardev:ltm-gdb", "-S"
            ]
        )
        #expect(
            DebugPort.replacingSocket(in: forwarded, withListener: nil) == [
                "LightTouchMac", "-netdev", forwarded[2], "-S"
            ])
        #expect(DebugPort.socket(in: debugged) == nil)
    }

    /// The app binds the Debug Port where the helper can't, and hands the listener over the bridge.
    @Test func theDebugPortsListenerCrossesTheBridge() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("gdb.sock").path
        let listener = try #require(DebugPort.listen(at: path))
        var info = stat()
        #expect(stat(path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { for fd in pair { close(fd) } }
        #expect(BridgeSocket.send(pair[1], .gdb))
        #expect(BridgeSocket.receive(pair[0]) == (true, .gdb, -1))
        #expect(BridgeSocket.send(pair[0], .gdb, descriptor: listener))
        close(listener)
        let (ok, kind, received) = BridgeSocket.receive(pair[1])
        #expect(ok && kind == .gdb && received >= 0)
        // a debugger on the app's path reaches whoever accepts on the handed-over listener
        let debugger = try #require(BridgeSocket.connect(path))
        let accepted = accept(received, nil, nil)
        #expect(accepted >= 0 && write(debugger, "$?#3f", 5) == 5)
        var buffer = [UInt8](repeating: 0, count: 5)
        #expect(read(accepted, &buffer, 5) == 5 && buffer == Array("$?#3f".utf8))
        close(accepted)
        close(debugger)
        close(received)
    }
}
