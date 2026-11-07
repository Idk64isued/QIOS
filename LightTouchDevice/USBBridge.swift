// A sandboxed helper's USB cable (and the way it gets its Debug Port's listener, gdbListener()). Unsandboxed, QEMU dials usbmuxd's guest socket in the user's temporary directory
// itself. Sandboxed, it can't reach that directory, and a socket in the app group's container could be taken by
// another device's helper (every helper can write the whole container), so the helper never has a path to usbmuxd:
// QEMU dials this bridge on 127.0.0.1 (a bound port can't be taken over), the bridge admits only this process's own
// connections, asks the app over fd 4 (DeviceLink's bridge socket) for a socket the app connected to this device's
// usbmuxd, and copies between the two until either end closes. QEMU dials again after a core reset or a lost link;
// each dial gets a fresh connection from the app.

import DeviceRuntime
import Foundation
import HostRuntime

final class USBBridge: @unchecked Sendable {
    /// DeviceLink's bridge socket (ltm_spawn's bridge_fd).
    static let control: Int32 = 4
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()

    /// The bridge, when DeviceLink gave this helper one (fd 4 is a socket), listening on 127.0.0.1.
    static func start() -> USBBridge? {
        var info = stat()
        guard fstat(control, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, size) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &size) == 0
            }
        }
        guard fd >= 0, ok else {
            helperLog("usb bridge: can't listen: \(String(cString: strerror(errno)))")
            if fd >= 0 { close(fd) }
            return nil
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bridge = USBBridge(listener: fd, port: UInt16(bigEndian: address.sin_port))
        helperLog("usb bridge: QEMU's cable at \(bridge.address)")
        Thread.detachNewThread { bridge.serve() }
        return bridge
    }

    private init(listener: Int32, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    /// QEMU's usb-tcp-addr: this bridge.
    var address: String { "127.0.0.1:\(port)" }

    private func serve() {
        while true {
            let guest = accept(listener, nil, nil)
            if guest < 0 { if errno == EINTR || errno == ECONNABORTED { continue } else { return } }
            guard HelperSandbox.isOwnConnection(guest) else {
                helperLog("usb bridge: refused a connection from another process")
                close(guest)
                continue
            }
            guard let host = requestHost() else {
                close(guest)  // no usbmuxd yet: QEMU dials again
                continue
            }
            var one: Int32 = 1
            setsockopt(guest, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            Self.splice(guest, host)
        }
    }

    /// A socket connected to this device's usbmuxd, from the app; nil when it has none.
    private func requestHost() -> Int32? { request(.usb) }

    /// The listening socket the app bound for this boot's Debug Port (its -gdb unix: path), nil without one.
    func gdbListener() -> Int32? { request(.gdb) }

    private func request(_ kind: BridgeSocket.Kind) -> Int32? {
        lock.withLock {
            guard BridgeSocket.send(Self.control, kind) else { return nil }
            let (ok, answer, fd) = BridgeSocket.receive(Self.control)
            guard ok, answer == kind, fd >= 0 else {
                if fd >= 0 { close(fd) }
                return nil
            }
            return fd
        }
    }

    /// Copies both ways until either side ends, then closes both.
    private static func splice(_ a: Int32, _ b: Int32) {
        let done = DispatchGroup()
        for (from, to) in [(a, b), (b, a)] {
            done.enter()
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = read(from, &buffer, buffer.count)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { break }
                    var sent = 0
                    while sent < n {
                        let w = buffer.withUnsafeBytes { write(to, $0.baseAddress! + sent, n - sent) }
                        if w < 0, errno == EINTR { continue }
                        guard w > 0 else { break }
                        sent += w
                    }
                    if sent < n { break }
                }
                shutdown(from, SHUT_RD)
                shutdown(to, SHUT_WR)
                done.leave()
            }
        }
        done.notify(queue: .global()) {
            close(a)
            close(b)
        }
    }
}
