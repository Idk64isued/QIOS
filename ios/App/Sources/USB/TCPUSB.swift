import Foundation
import Network

// The TCP USB transport (qemu-ios docs/tcp-usb-protocol.md).
//
// QEMU dials OUT to a listener (TCP or Unix socket) that this file provides. Every exchange is request/response,
// strictly host-driven, with a 5-byte packed header: {addr, ep, flags, int16_t length}. NAK (length == -2) is the
// one flow-control signal; retry quickly. STALL (-3) is an endpoint refusal; NODEV (-1) is fatal.
//
// This file speaks the wire protocol. The USB enumeration and the usbmux bulk framing live in USBDevice.swift and
// USBMuxClient.swift above it.

enum TCPUSBError: Error, CustomStringConvertible {
    case disconnected
    case protocolMismatch(String)
    case timeout(String)
    case stall(UInt8)
    case noDevice
    case tooLarge(Int)
    case shortTransfer(expected: Int, got: Int)
    case wrongEndpoint(expected: UInt8, got: UInt8)

    var description: String {
        switch self {
        case .disconnected: return "The emulator's USB bridge disconnected."
        case .protocolMismatch(let m): return "USB handshake: \(m)"
        case .timeout(let m): return "USB timeout: \(m)"
        case .stall(let ep): return String(format: "USB endpoint %#04x stalled", ep)
        case .noDevice: return "USB: no device"
        case .tooLarge(let n): return "USB transfer too large: \(n) > 32767"
        case .shortTransfer(let e, let g): return "USB short transfer (\(g) of \(e))"
        case .wrongEndpoint(let e, let g): return String(format: "USB reply on %#04x, not %#04x", g, e)
        }
    }
}

/// The 5-byte transaction header.
struct TCPUSBHeader {
    var addr: UInt8
    var ep: UInt8
    var flags: UInt8
    var length: Int16   // negative is a USB_RET_* status

    static let size = 5

    init(addr: UInt8 = 0, ep: UInt8, flags: UInt8 = 0, length: Int16 = 0) {
        self.addr = addr
        self.ep = ep
        self.flags = flags
        self.length = length
    }

    func encode() -> Data {
        var bytes = Data(count: Self.size)
        bytes[0] = addr
        bytes[1] = ep
        bytes[2] = flags
        let le = UInt16(bitPattern: length).littleEndian
        bytes[3] = UInt8(truncatingIfNeeded: le)
        bytes[4] = UInt8(truncatingIfNeeded: le >> 8)
        return bytes
    }

    init?(_ bytes: Data) {
        guard bytes.count >= Self.size else { return nil }
        addr = bytes[bytes.startIndex]
        ep = bytes[bytes.startIndex + 1]
        flags = bytes[bytes.startIndex + 2]
        let low = UInt16(bytes[bytes.startIndex + 3])
        let high = UInt16(bytes[bytes.startIndex + 4])
        length = Int16(bitPattern: low | (high << 8))
    }
}

struct TCPUSBFlags {
    static let setup: UInt8 = 1 << 0
    static let reset: UInt8 = 1 << 1
    static let enumdone: UInt8 = 1 << 2
    static let hello: UInt8 = 1 << 3
}

/// The host side of the TCP USB bridge: it listens, QEMU connects, every packet is a 5-byte header and a payload
/// (for OUT or for an IN reply). The whole protocol is synchronous so each transport instance serves one queue.
final class TCPUSBTransport: @unchecked Sendable {
    private let listener: NWListener
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "ltm.usb.transport")
    private var address: UInt8 = 0     // the address the device reports back (how we learn SET_ADDRESS took)
    private let listening = DispatchSemaphore(value: 0)
    private let connected = DispatchSemaphore(value: 0)
    private var hasConnection = false
    private var available: Data = Data()
    private let availableLock = NSLock()
    private let dataArrived = NSCondition()
    private var closed = false
    private(set) var hellomax: Int = 16384

    /// The URL QEMU should dial: `tcp:127.0.0.1:port`.
    let listenPort: UInt16

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = false
        }
        // Port 0 asks the kernel to pick one. We read back the chosen port in the state handler.
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        self.listenPort = 0  // filled in once listening (see start())

        var ready = false
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if !ready { ready = true; self.listening.signal() }
            case .failed, .cancelled:
                self.listening.signal()
                self.connected.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.hasConnection else { connection.cancel(); return }
            self.hasConnection = true
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.receiveLoop(connection)
                    self?.connected.signal()
                case .failed, .cancelled:
                    self?.dataArrived.lock()
                    self?.closed = true
                    self?.dataArrived.broadcast()
                    self?.dataArrived.unlock()
                default: break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    /// Opens the listener and returns the TCP port QEMU should dial. Does NOT wait for QEMU to connect; call
    /// `waitForConnection(timeout:)` once QEMU is booting.
    func start() throws -> UInt16 {
        listener.start(queue: queue)
        guard listening.wait(timeout: .now() + 3) == .success else {
            listener.cancel()
            throw TCPUSBError.timeout("TCP USB listener did not come up")
        }
        guard case .ready = listener.state, let port = listener.port else {
            throw TCPUSBError.timeout("TCP USB listener failed to bind")
        }
        return port.rawValue
    }

    func waitForConnection(timeout: TimeInterval) -> Bool {
        connected.wait(timeout: .now() + timeout) == .success
    }

    func stop() {
        listener.cancel()
        connection?.cancel()
        dataArrived.lock()
        closed = true
        dataArrived.broadcast()
        dataArrived.unlock()
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.dataArrived.lock()
                self.available.append(data)
                self.dataArrived.broadcast()
                self.dataArrived.unlock()
            }
            if error != nil || isComplete {
                self.dataArrived.lock()
                self.closed = true
                self.dataArrived.broadcast()
                self.dataArrived.unlock()
                return
            }
            self.receiveLoop(connection)
        }
    }

    private func readExactly(_ count: Int, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        dataArrived.lock()
        defer { dataArrived.unlock() }
        while available.count < count {
            if closed { throw TCPUSBError.disconnected }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw TCPUSBError.timeout("read \(count) bytes") }
            _ = dataArrived.wait(until: Date(timeIntervalSinceNow: remaining))
        }
        let out = available.prefix(count)
        available.removeFirst(count)
        return Data(out)
    }

    private func writeAll(_ data: Data) throws {
        guard let connection, !closed else { throw TCPUSBError.disconnected }
        let sem = DispatchSemaphore(value: 0)
        var sendError: Error?
        connection.send(content: data, completion: .contentProcessed { error in
            sendError = error
            sem.signal()
        })
        if sem.wait(timeout: .now() + 5) != .success { throw TCPUSBError.timeout("send \(data.count) bytes") }
        if let sendError { throw sendError }
    }

    // MARK: - One packet exchange

    /// One request/response exchange. Returns the device's reply (length, data). Payload for OUT goes in `data`;
    /// IN uses `size` as the expected length. For an IN reply with length > 0, `data` in the result is the body.
    @discardableResult
    func packet(ep: UInt8, size: Int16 = 0, data: Data = Data(), flags: UInt8 = 0, timeout: TimeInterval = 5)
        throws -> (length: Int16, data: Data)
    {
        let inDirection = ep & 0x80 != 0
        if !inDirection, Int(size) != data.count {
            // The size field on OUT names the payload length.
        }
        if Int(size) < 0 || size > Int16.max { throw TCPUSBError.tooLarge(Int(size)) }

        let header = TCPUSBHeader(addr: address, ep: ep, flags: flags, length: Int16(inDirection ? size : Int16(data.count)))
        var packet = header.encode()
        if !inDirection { packet.append(data) }
        try writeAll(packet)

        let headerBytes = try readExactly(TCPUSBHeader.size, timeout: timeout)
        guard let reply = TCPUSBHeader(headerBytes) else { throw TCPUSBError.protocolMismatch("short header") }
        address = reply.addr   // the device overwrites addr with its DCFG; this is how we learn SET_ADDRESS stuck
        guard reply.ep == ep else { throw TCPUSBError.wrongEndpoint(expected: ep, got: reply.ep) }
        if reply.length < 0 { return (reply.length, Data()) }
        if reply.length > size, inDirection { throw TCPUSBError.protocolMismatch("oversized IN reply") }
        var body = Data()
        if inDirection, reply.length > 0 {
            body = try readExactly(Int(reply.length), timeout: timeout)
        }
        return (reply.length, body)
    }

    /// Like packet(), but retries on NAK (the whole flow-control mechanism of this transport).
    func transfer(ep: UInt8, size: Int16 = 0, data: Data = Data(), flags: UInt8 = 0, timeout: TimeInterval = 10)
        throws -> (length: Int16, data: Data)
    {
        let inDirection = ep & 0x80 != 0
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let reply = try packet(ep: ep, size: size, data: data, flags: flags, timeout: min(5, timeout))
            if reply.length >= 0 {
                return inDirection ? reply : (reply.length, Data())
            }
            switch reply.length {
            case -2:
                if Date() >= deadline { throw TCPUSBError.timeout(String(format: "NAK on %#04x", ep)) }
                usleep(1000)
            case -3:
                throw TCPUSBError.stall(ep)
            default:
                throw TCPUSBError.noDevice
            }
        }
    }

    // MARK: - Hello (version handshake)

    /// The host's first exchange: IN on endpoint 0x7f with the hello flag, length >= 12.
    /// Returns the device's advertised max_transaction so the host can cap its own MTU to it.
    func hello(timeout: TimeInterval = 10) throws -> Int {
        let (_, body) = try transfer(ep: 0xff, size: 12, flags: TCPUSBFlags.hello, timeout: timeout)
        guard body.count >= 12 else { throw TCPUSBError.protocolMismatch("hello body \(body.count) bytes") }
        let magic = body.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let version = body.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) }.littleEndian
        let max = body.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }.littleEndian
        guard magic == 0x42535554 else { throw TCPUSBError.protocolMismatch("hello magic \(String(magic, radix: 16))") }
        guard version == 1 else { throw TCPUSBError.protocolMismatch("hello version \(version)") }
        hellomax = Int(max)
        return hellomax
    }

    /// Signals USB reset to the guest; then enumeration-done once its driver is ready.
    func signalReset() throws { _ = try packet(ep: 0, flags: TCPUSBFlags.reset) }
    func signalEnumDone() throws { _ = try packet(ep: 0, flags: TCPUSBFlags.enumdone) }
}
