import Foundation
#if canImport(Darwin)
import Darwin
#endif

// The TCP USB transport, host side (qemu-ios docs/tcp-usb-protocol.md, the canonical spec).
//
// Roles: QEMU is the CLIENT and dials out; we listen. It dials at device realize and again on every USB core soft
// reset, so a connection can arrive, drop and arrive again several times during one boot. Every exchange is a
// 5-byte packed header {addr, ep, flags, int16 length}, optionally followed by a payload, and the whole protocol is
// strictly host-driven request/response: the device never speaks unprompted, so nothing is ever readable until we
// have asked for it.
//
// A negative reply length is a QEMU USB_RET_* status, not a size: -1 NODEV, -2 NAK, -3 STALL. NAK is the entire
// flow-control mechanism — every endpoint NAKs until the guest arms it, and the guest needs ~100 s of boot before
// it has programmed the USB core at all, so NAK means "ask again", never "failed".
//
// This file is the byte transport and nothing else. Enumeration lives in USBDevice.swift, the device-side usbmux
// protocol in USBMux.swift, and the loop that drives both in USBHostBridge.swift.
//
// Plain BSD sockets rather than Network.framework: the protocol is synchronous request/response driven by one
// thread, which is exactly what blocking sockets with poll() timeouts do well, and it leaves no connection state
// machine to race with.

enum TCPUSBError: Error, CustomStringConvertible {
    case notListening(String)
    case disconnected
    case protocolMismatch(String)
    case timeout(String)
    case stall(UInt8)
    case noDevice
    case tooLarge(Int)
    case wrongEndpoint(expected: UInt8, got: UInt8)

    var description: String {
        switch self {
        case .notListening(let m): return "USB bridge could not listen: \(m)"
        case .disconnected: return "the emulator is not connected to the USB bridge"
        case .protocolMismatch(let m): return "USB handshake: \(m)"
        case .timeout(let m): return "USB timeout: \(m)"
        case .stall(let ep): return String(format: "USB endpoint %#04x stalled", ep)
        case .noDevice: return "USB: the device reported NODEV"
        case .tooLarge(let n): return "USB transfer too large: \(n) > \(TCPUSB.maxTransaction)"
        case .wrongEndpoint(let e, let g): return String(format: "USB reply on %#04x, not %#04x", g, e)
        }
    }

    /// True when trying again later is the right response (the link dropped, or the device did not answer in time).
    /// QEMU redials, so these are all normal during a boot.
    var isRetryable: Bool {
        switch self {
        case .disconnected, .timeout: return true
        default: return false
        }
    }
}

enum TCPUSB {
    /// int16 length field; one transaction can never carry more.
    static let maxTransaction = 32767
    /// What usbmuxd polls with (USB_MRU). The device answers min(armed, requested) and keeps the rest armed.
    static let pollSize = 16384
    /// Endpoint the version handshake uses.
    static let controlEndpoint: UInt8 = 0x7f
    static let directionIn: UInt8 = 0x80

    /// USB_RET_* status codes that can come back in the length field.
    static let statusNoDev = -1
    static let statusNAK = -2
    static let statusStall = -3
}

struct TCPUSBFlags {
    static let none: UInt8 = 0
    static let setup: UInt8 = 1 << 0
    static let reset: UInt8 = 1 << 1
    static let enumdone: UInt8 = 1 << 2
    static let hello: UInt8 = 1 << 3
}

/// The 5-byte packed transaction header.
struct TCPUSBHeader {
    var addr: UInt8
    var ep: UInt8
    var flags: UInt8
    var length: Int16   // negative in a reply is a USB_RET_* status

    static let size = 5

    func encoded() -> [UInt8] {
        let raw = UInt16(bitPattern: length)
        return [addr, ep, flags, UInt8(truncatingIfNeeded: raw), UInt8(truncatingIfNeeded: raw >> 8)]
    }

    init(addr: UInt8 = 0, ep: UInt8, flags: UInt8 = 0, length: Int16 = 0) {
        self.addr = addr
        self.ep = ep
        self.flags = flags
        self.length = length
    }

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= Self.size else { return nil }
        addr = bytes[0]
        ep = bytes[1]
        flags = bytes[2]
        length = Int16(bitPattern: UInt16(bytes[3]) | (UInt16(bytes[4]) << 8))
    }
}

/// What the device says about itself in the version handshake.
struct TCPUSBHello {
    var version: UInt16
    var maxTransaction: Int
}

/// Listens for QEMU, and performs one request/response exchange at a time.
///
/// Thread safety: `exchange` must be called from one thread at a time (the bridge's). Connect and disconnect happen
/// on an accept thread, and the socket is swapped under a lock, so an exchange in flight when the link drops fails
/// with `.disconnected` rather than reading another connection's bytes.
final class TCPUSBTransport: @unchecked Sendable {
    /// The port QEMU is told to dial (`usb-tcp-addr=127.0.0.1:<port>`).
    private(set) var port: UInt16 = 0

    private var listenFD: Int32 = -1
    private var socketFD: Int32 = -1
    private let lock = NSCondition()
    private var stopped = false
    /// Bumped on every new connection, so a caller can tell "still the same link" from "redialled".
    private(set) var generation: UInt64 = 0
    /// The address the device reports back, which is how we learn a SET_ADDRESS took effect. Resets on reconnect.
    private var address: UInt8 = 0
    private var acceptThread: Thread?

    // MARK: - Listening

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw TCPUSBError.notListening(Self.errnoText()) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_port = 0                              // the kernel picks a free port
        addr.sin_addr.s_addr = Self.loopbackAddress     // 127.0.0.1 only
        var bindResult: Int32 = -1
        withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bindResult = bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let text = Self.errnoText()
            close(fd)
            throw TCPUSBError.notListening("bind: \(text)")
        }
        guard listen(fd, 4) == 0 else {
            let text = Self.errnoText()
            close(fd)
            throw TCPUSBError.notListening("listen: \(text)")
        }
        // Read back the port the kernel chose.
        var bound = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                _ = getsockname(fd, generic, &size)
            }
        }
        listenFD = fd
        port = UInt16(bigEndian: bound.sin_port)
        guard port != 0 else {
            close(fd)
            listenFD = -1
            throw TCPUSBError.notListening("the kernel gave no port")
        }
    }

    /// Starts accepting connections. QEMU may dial several times in one boot; the newest connection wins.
    func startAccepting() {
        guard acceptThread == nil, listenFD >= 0 else { return }
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "ltm.usb.accept"
        thread.stackSize = 128 * 1024
        acceptThread = thread
        thread.start()
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let listening = listenFD
            let done = stopped
            lock.unlock()
            if done || listening < 0 { return }

            let fd = accept(listening, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return   // the listener was closed
            }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            // Every control transfer is a round trip; Nagle would add 40 ms to each (the spec requires NODELAY).
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

            lock.lock()
            if stopped {
                lock.unlock()
                close(fd)
                return
            }
            // QEMU redials on a core soft reset without closing cleanly first, so drop whatever we had.
            let previous = socketFD
            socketFD = fd
            generation &+= 1
            address = 0
            let now = generation
            lock.broadcast()
            lock.unlock()
            if previous >= 0 { close(previous) }
            LTMLog.note("usb: emulator connected to the bridge (link \(now))")
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let (listening, connected) = (listenFD, socketFD)
        listenFD = -1
        socketFD = -1
        lock.broadcast()
        lock.unlock()
        if listening >= 0 { close(listening) }
        if connected >= 0 { close(connected) }
    }

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return socketFD >= 0 && !stopped
    }

    /// Waits for QEMU to dial in. Returns false on timeout or if the transport was stopped.
    func waitForConnection(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        defer { lock.unlock() }
        while socketFD < 0, !stopped {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            lock.wait(until: Date(timeIntervalSinceNow: min(remaining, 0.5)))
        }
        return socketFD >= 0 && !stopped
    }

    /// Drops the current connection, so QEMU's retry timer dials again and both ends start from a clean stream.
    func dropConnection() {
        lock.lock()
        let fd = socketFD
        socketFD = -1
        address = 0
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    // MARK: - One exchange

    /// Sends one request and reads the reply. `out` is the payload for an OUT request; `inLength` is how much an IN
    /// request asks for. The returned status is the reply's length field: >= 0 is a byte count, negative is a
    /// USB_RET_* code which this method passes through untouched (NAK is normal, see the note at the top).
    @discardableResult
    func exchange(ep: UInt8, flags: UInt8 = 0, out: Data = Data(), inLength: Int = 0, timeout: TimeInterval = 2)
        throws -> (status: Int, data: Data)
    {
        let incoming = ep & TCPUSB.directionIn != 0
        let payloadLength = incoming ? inLength : out.count
        guard payloadLength >= 0, payloadLength <= TCPUSB.maxTransaction else {
            throw TCPUSBError.tooLarge(payloadLength)
        }

        // Claim the socket for this exchange. If it is swapped while we are mid-packet the generation check below
        // turns that into .disconnected instead of a desynchronised stream.
        lock.lock()
        let fd = socketFD
        let startGeneration = generation
        let currentAddress = address
        lock.unlock()
        guard fd >= 0 else { throw TCPUSBError.disconnected }

        let header = TCPUSBHeader(
            addr: currentAddress, ep: ep, flags: flags, length: Int16(payloadLength))
        var request = Data(header.encoded())
        if !incoming, !out.isEmpty { request.append(out) }
        try writeAll(fd: fd, data: request, timeout: timeout)

        let headerBytes = try readExactly(fd: fd, count: TCPUSBHeader.size, timeout: timeout, since: startGeneration)
        guard let reply = TCPUSBHeader(headerBytes) else { throw TCPUSBError.protocolMismatch("short reply header") }
        guard reply.ep == ep else { throw TCPUSBError.wrongEndpoint(expected: ep, got: reply.ep) }

        // The device overwrites addr with its own DCFG address: that is how a SET_ADDRESS is confirmed.
        lock.lock()
        if generation == startGeneration { address = reply.addr }
        lock.unlock()

        let status = Int(reply.length)
        if status < 0 { return (status, Data()) }
        guard status <= payloadLength else { throw TCPUSBError.protocolMismatch("reply of \(status) for a \(payloadLength)-byte request") }
        var body = Data()
        if incoming, status > 0 {
            body = Data(try readExactly(fd: fd, count: status, timeout: timeout, since: startGeneration))
        }
        return (status, body)
    }

    /// An exchange that retries while the device NAKs, which is what every endpoint does until the guest arms it.
    /// STALL and NODEV are real answers and are thrown. Returns nil only if `nakIsEmpty` and the deadline passed,
    /// which is how a poll of an idle IN endpoint reports "nothing there".
    func transfer(ep: UInt8, flags: UInt8 = 0, out: Data = Data(), inLength: Int = 0,
        nakTimeout: TimeInterval = 2, nakIsEmpty: Bool = false) throws -> (status: Int, data: Data)?
    {
        let deadline = Date().addingTimeInterval(nakTimeout)
        while true {
            let reply = try exchange(ep: ep, flags: flags, out: out, inLength: inLength)
            if reply.status >= 0 { return reply }
            switch reply.status {
            case TCPUSB.statusNAK:
                if Date() >= deadline {
                    if nakIsEmpty { return nil }
                    throw TCPUSBError.timeout(String(format: "endpoint %#04x kept NAKing", ep))
                }
                usleep(1000)   // HOST_RETRY_MS, as QEMU's own built-in host does
            case TCPUSB.statusStall:
                throw TCPUSBError.stall(ep)
            default:
                throw TCPUSBError.noDevice
            }
        }
    }

    // MARK: - Version handshake

    /// The host's opening exchange: an IN request on endpoint 0x7f with the hello flag and length >= 12. A device
    /// that predates the handshake answers STALL, which is the point — it fails loudly instead of silently
    /// disagreeing about the maximum transaction size.
    func hello() throws -> TCPUSBHello {
        let wanted = 12
        guard let reply = try transfer(
            ep: TCPUSB.controlEndpoint | TCPUSB.directionIn, flags: TCPUSBFlags.hello, inLength: wanted,
            nakTimeout: 3)
        else { throw TCPUSBError.timeout("hello") }
        let body = [UInt8](reply.data)
        guard body.count >= wanted else { throw TCPUSBError.protocolMismatch("hello is \(body.count) bytes") }
        let magic = UInt32(body[0]) | (UInt32(body[1]) << 8) | (UInt32(body[2]) << 16) | (UInt32(body[3]) << 24)
        let version = UInt16(body[4]) | (UInt16(body[5]) << 8)
        let max = UInt32(body[8]) | (UInt32(body[9]) << 8) | (UInt32(body[10]) << 16) | (UInt32(body[11]) << 24)
        // "TUSB" as a little-endian uint32.
        guard magic == 0x4253_5554 else {
            throw TCPUSBError.protocolMismatch(String(format: "magic %08x is not TUSB", magic))
        }
        guard version == 1 else { throw TCPUSBError.protocolMismatch("device speaks protocol v\(version), we speak v1") }
        let cap = max == 0 ? TCPUSB.maxTransaction : min(Int(max), TCPUSB.maxTransaction)
        return TCPUSBHello(version: version, maxTransaction: cap)
    }

    /// Signals a USB reset to the guest, then enumeration-done. Both are header-only transactions on EP0.
    func signalReset() throws { _ = try exchange(ep: 0, flags: TCPUSBFlags.reset) }
    func signalEnumDone() throws { _ = try exchange(ep: 0, flags: TCPUSBFlags.enumdone) }

    // MARK: - Socket plumbing

    private func writeAll(fd: Int32, data: Data, timeout: TimeInterval) throws {
        var sent = 0
        let bytes = [UInt8](data)
        let deadline = Date().addingTimeInterval(timeout)
        while sent < bytes.count {
            if Date() > deadline { throw TCPUSBError.timeout("sending \(bytes.count) bytes") }
            let written = bytes.withUnsafeBytes { raw -> Int in
                send(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
            }
            if written > 0 {
                sent += written
                continue
            }
            if written == 0 { throw TCPUSBError.disconnected }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                guard try wait(fd: fd, forReading: false, deadline: deadline) else {
                    throw TCPUSBError.timeout("socket not writable")
                }
                continue
            }
            throw TCPUSBError.disconnected
        }
    }

    private func readExactly(fd: Int32, count: Int, timeout: TimeInterval, since generation: UInt64) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        let deadline = Date().addingTimeInterval(timeout)
        while got < count {
            // If the link was replaced under us, the rest of this packet belongs to a stream that is gone.
            lock.lock()
            let live = self.generation == generation && socketFD == fd && !stopped
            lock.unlock()
            guard live else { throw TCPUSBError.disconnected }

            guard try wait(fd: fd, forReading: true, deadline: deadline) else {
                throw TCPUSBError.timeout("reading \(count) bytes (\(got) so far)")
            }
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                recv(fd, raw.baseAddress!.advanced(by: got), count - got, 0)
            }
            if read > 0 {
                got += read
                continue
            }
            if read == 0 { throw TCPUSBError.disconnected }   // the emulator closed the link
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            throw TCPUSBError.disconnected
        }
        return buffer
    }

    /// poll() for readability or writability. False means the deadline passed.
    private func wait(fd: Int32, forReading: Bool, deadline: Date) throws -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            var descriptor = pollfd(
                fd: fd, events: Int16(forReading ? POLLIN : POLLOUT), revents: 0)
            let milliseconds = Int32(min(max(remaining * 1000, 1), 2000))
            let result = withUnsafeMutablePointer(to: &descriptor) { poll($0, 1, milliseconds) }
            if result > 0 {
                if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw TCPUSBError.disconnected }
                return true
            }
            if result == 0 { continue }           // timed out this round; the loop checks the deadline
            if errno == EINTR { continue }
            throw TCPUSBError.disconnected
        }
    }

    private static var loopbackAddress: in_addr_t {
        // 127.0.0.1 in network byte order.
        in_addr_t(0x7f00_0001).bigEndian
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
}
