import Foundation

// usbmux as the DEVICE speaks it, over the two bulk endpoints.
//
// This is not the protocol a program speaks to a usbmuxd daemon on a desktop (length/version/message/tag plus a
// plist). On the wire to the device it is Apple's multiplexer: a header, a version handshake, and then real TCP
// segments carrying each service's bytes.
//
//     struct mux_header { uint32 protocol; uint32 length; uint32 magic; uint16 tx_seq; uint16 rx_seq; }
//
// All of it big-endian. `length` counts the header too. The magic and the two sequence numbers exist only once the
// device has agreed to protocol version 2; before that the header is the first 8 bytes alone. The host opens with a
// version packet (major 2, minor 0), the device answers with the version it wants, and for version 2 the host then
// sends a one-byte setup packet (0x07). After that each connection is a TCP stream: SYN, SYN|ACK, ACK, then data
// with the usual sequence and acknowledgement bookkeeping, and a window the device advertises in units of 256 bytes.
//
// The guest also matters to the bridge's health: AppleUSBDeviceMux restarts the whole USB stack a few seconds after
// activation if the host never says anything, so the version packet and then continuous polling of the bulk IN
// endpoint are not optional extras — they are what keeps the link up. USBHostBridge does the polling; this file
// does the framing.

enum USBMuxError: Error, CustomStringConvertible {
    case notReady
    case badFrame(String)
    case versionRejected(UInt32)
    case refused(String)
    case closed
    case timeout(String)

    var description: String {
        switch self {
        case .notReady: return "the mux is not up yet"
        case .badFrame(let m): return "mux: \(m)"
        case .versionRejected(let v): return "mux: the guest asked for protocol v\(v)"
        case .refused(let m): return "mux: connection refused (\(m))"
        case .closed: return "mux: the channel closed"
        case .timeout(let m): return "mux: timed out \(m)"
        }
    }
}

private enum MuxProtocol: UInt32 {
    case version = 0
    case control = 1
    case setup = 2
    case tcp = 6
}

private struct TCPFlags {
    static let fin: UInt8 = 0x01
    static let syn: UInt8 = 0x02
    static let rst: UInt8 = 0x04
    static let ack: UInt8 = 0x10
}

/// The multiplexer. One per device. Fed by the bridge thread, used from service threads.
final class MuxDevice: @unchecked Sendable {
    /// What a connection's bytes are read and written through; the shape Lockdown/AFC/InstallProxy expect.
    typealias Pipe = USBMuxPipe

    private let condition = NSCondition()
    private var version: UInt32 = 0
    private var active = false
    private var failure: Error?
    private var inbound = Data()
    private var outbound: [Data] = []
    private var txSeq: UInt16 = 0
    private var rxSeq: UInt16 = 0xFFFF
    private var connections: [UInt16: USBMuxPipe] = [:]
    private var nextSourcePort: UInt16 = 49152
    /// Biggest TCP payload we put in one mux packet. Must leave room for the headers inside one transaction.
    private var payloadLimit = 16384

    /// How much the device will take in one transaction (from the transport's hello).
    func setTransactionLimit(_ bytes: Int) {
        condition.lock()
        payloadLimit = max(512, min(bytes - 64, 16384))
        condition.unlock()
    }

    // MARK: - Lifecycle

    /// Clears everything for a fresh link and queues the opening version packet.
    func restart() {
        condition.lock()
        version = 0
        active = false
        failure = nil
        inbound.removeAll(keepingCapacity: true)
        outbound.removeAll(keepingCapacity: true)
        txSeq = 0
        rxSeq = 0xFFFF
        let open = connections
        connections.removeAll()
        condition.broadcast()
        condition.unlock()
        for (_, pipe) in open { pipe.linkDropped() }

        // The version request: major 2, minor 0, padding 0. This is also the packet QEMU's own built-in host sends,
        // so it is exactly what the guest's mux expects to hear first.
        var body = Data()
        body.appendBig(UInt32(2))
        body.appendBig(UInt32(0))
        body.appendBig(UInt32(0))
        enqueue(packet(.version, extra: Data(), payload: body))
    }

    /// True once the version handshake is done and connections can be opened.
    var isActive: Bool {
        condition.lock()
        defer { condition.unlock() }
        return active
    }

    func waitUntilActive(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !active {
            if let failure { throw failure }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw USBMuxError.timeout("waiting for the guest's mux") }
            condition.wait(until: Date(timeIntervalSinceNow: min(remaining, 0.25)))
        }
    }

    /// Marks the link as gone: every pipe fails, and the next restart() starts over.
    func linkDropped(_ error: Error) {
        condition.lock()
        active = false
        failure = error
        let open = connections
        connections.removeAll()
        outbound.removeAll(keepingCapacity: true)
        inbound.removeAll(keepingCapacity: true)
        condition.broadcast()
        condition.unlock()
        for (_, pipe) in open { pipe.linkDropped() }
    }

    // MARK: - The bridge's two entry points

    /// The next complete bulk packet to write, or nil when there is nothing to send.
    func nextOutbound() -> Data? {
        condition.lock()
        defer { condition.unlock() }
        return outbound.isEmpty ? nil : outbound.removeFirst()
    }

    /// Bytes that came back from a bulk IN poll. A mux packet can span several polls and a poll can carry several
    /// packets, so this buffers and parses by the header's length.
    func feed(_ data: Data) {
        condition.lock()
        inbound.append(data)
        var packets: [(UInt32, Data)] = []
        while inbound.count >= 8 {
            let proto = inbound.readBig32(0)
            let length = Int(inbound.readBig32(4))
            // A length that cannot be right means the stream is misframed; nothing good comes of guessing.
            if length < 8 || length > 1 << 20 {
                let bad = USBMuxError.badFrame("a packet claims \(length) bytes")
                condition.unlock()
                LTMLog.note("usb: \(bad)")
                linkDropped(bad)
                return
            }
            if inbound.count < length { break }
            let body = Data(inbound.prefix(length))
            inbound.removeFirst(length)
            packets.append((proto, body))
        }
        condition.unlock()
        for (proto, body) in packets { handle(muxProtocol: proto, packet: body) }
    }

    // MARK: - Inbound

    private func handle(muxProtocol proto: UInt32, packet: Data) {
        condition.lock()
        let headerLength = version >= 2 ? 16 : 8
        if version >= 2, packet.count >= 16 {
            rxSeq = UInt16(truncatingIfNeeded: packet.readBig32(12) >> 16)
        }
        condition.unlock()
        guard packet.count >= headerLength else { return }
        let payload = Data(packet.dropFirst(headerLength))

        switch MuxProtocol(rawValue: proto) {
        case .version:
            handleVersion(payload)
        case .control:
            // The device's own log line. Worth seeing once, not worth flooding the log with.
            let text = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty { LTMLog.note("usb: guest mux says: \(text.prefix(200))") }
        case .tcp:
            handleTCP(payload)
        case .setup, .none:
            break
        }
    }

    private func handleVersion(_ payload: Data) {
        guard payload.count >= 4 else { return }
        let major = payload.readBig32(0)
        guard major == 1 || major == 2 else {
            LTMLog.note("usb: \(USBMuxError.versionRejected(major))")
            linkDropped(USBMuxError.versionRejected(major))
            return
        }
        condition.lock()
        version = major
        active = true
        condition.broadcast()
        condition.unlock()
        // Version 2 wants a one-byte setup packet before anything else, and it resets both sequence counters.
        if major >= 2 {
            condition.lock()
            txSeq = 0
            rxSeq = 0xFFFF
            condition.unlock()
            enqueue(packet(.setup, extra: Data(), payload: Data([0x07])))
        }
        LTMLog.note("usb: mux up (protocol v\(major))")
    }

    private func handleTCP(_ payload: Data) {
        guard payload.count >= 20 else { return }
        // The device's destination port is our source port.
        let ourPort = UInt16(truncatingIfNeeded: payload.readBig32(0) & 0xffff)
        let deviceSeq = payload.readBig32(4)
        let deviceAck = payload.readBig32(8)
        let flags = payload[payload.startIndex + 13]
        let window = UInt32(UInt16(truncatingIfNeeded: payload.readBig32(12) & 0xffff)) << 8
        let body = Data(payload.dropFirst(20))

        condition.lock()
        guard let pipe = connections[ourPort] else {
            condition.unlock()
            return
        }
        condition.unlock()

        if flags & TCPFlags.rst != 0 {
            pipe.remoteReset()
            removeConnection(ourPort)
            return
        }
        if pipe.connecting {
            guard flags & (TCPFlags.syn | TCPFlags.ack) == (TCPFlags.syn | TCPFlags.ack) else {
                pipe.remoteReset()
                removeConnection(ourPort)
                return
            }
            pipe.accepted(deviceSeq: deviceSeq, deviceAck: deviceAck, window: window)
            sendTCP(pipe, flags: TCPFlags.ack, payload: Data())
            return
        }
        pipe.noteRemote(deviceSeq: deviceSeq, deviceAck: deviceAck, window: window)
        if !body.isEmpty {
            pipe.received(body)
            // Acknowledge at once: the device's window does not reopen until we do, and a stalled window looks
            // exactly like a hung service.
            sendTCP(pipe, flags: TCPFlags.ack, payload: Data())
        }
        if flags & TCPFlags.fin != 0 {
            pipe.remoteClosed()
        }
    }

    // MARK: - Outbound

    /// Opens a TCP channel to `port` on the guest and returns its byte pipe.
    func connect(toPort port: UInt16, timeout: TimeInterval = 20) throws -> USBMuxPipe {
        try waitUntilActive(timeout: timeout)
        condition.lock()
        let source = nextSourcePort
        nextSourcePort = nextSourcePort == 65535 ? 49152 : nextSourcePort + 1
        let pipe = USBMuxPipe(device: self, sourcePort: source, devicePort: port)
        connections[source] = pipe
        condition.unlock()

        sendTCP(pipe, flags: TCPFlags.syn, payload: Data())
        do {
            try pipe.waitUntilConnected(timeout: timeout)
        } catch {
            removeConnection(source)
            throw error
        }
        return pipe
    }

    func close(_ pipe: USBMuxPipe) {
        guard pipe.isOpen else { return }
        sendTCP(pipe, flags: TCPFlags.fin | TCPFlags.ack, payload: Data())
        pipe.localClosed()
        removeConnection(pipe.sourcePort)
    }

    private func removeConnection(_ port: UInt16) {
        condition.lock()
        connections.removeValue(forKey: port)
        condition.unlock()
    }

    /// Writes `data` to a connected pipe, in chunks that respect both the transaction limit and the device's window.
    func send(_ pipe: USBMuxPipe, data payload: Data, timeout: TimeInterval) throws {
        // Re-index: a Data that arrived as a slice has a non-zero startIndex, and subdata(in:) takes absolute
        // indices, so slicing one without this reads the wrong bytes.
        let data = payload.startIndex == 0 ? payload : Data(payload)
        var offset = 0
        let deadline = Date().addingTimeInterval(timeout)
        while offset < data.count {
            condition.lock()
            let limit = payloadLimit
            condition.unlock()
            // Wait for room in the device's receive window.
            while !pipe.canSend(bytes: 1) {
                if !pipe.isOpen { throw USBMuxError.closed }
                if Date() > deadline { throw USBMuxError.timeout("waiting for the guest's window") }
                usleep(2000)
            }
            let room = max(1, min(limit, pipe.sendableBytes()))
            let end = min(offset + room, data.count)
            let chunk = data.subdata(in: offset..<end)
            sendTCP(pipe, flags: TCPFlags.ack, payload: chunk)
            pipe.didSend(chunk.count)
            offset = end
        }
    }

    private func sendTCP(_ pipe: USBMuxPipe, flags: UInt8, payload: Data) {
        let state = pipe.sequenceState()
        var header = Data()
        header.appendBig(UInt16(pipe.sourcePort))
        header.appendBig(UInt16(pipe.devicePort))
        header.appendBig(state.sequence)
        header.appendBig(state.acknowledgement)
        header.append(0x50)                      // data offset 5 words, no options
        header.append(flags)
        header.appendBig(UInt16(truncatingIfNeeded: USBMuxPipe.receiveWindow >> 8))
        header.appendBig(UInt16(0))              // checksum: the mux does not use one
        header.appendBig(UInt16(0))              // urgent pointer
        enqueue(packet(.tcp, extra: header, payload: payload))
    }

    /// Builds one complete mux packet.
    private func packet(_ proto: MuxProtocol, extra: Data, payload: Data) -> Data {
        condition.lock()
        let useSequences = version >= 2
        let headerLength = useSequences ? 16 : 8
        let sequence = txSeq
        let acknowledgement = rxSeq
        if useSequences { txSeq = txSeq &+ 1 }
        condition.unlock()

        var out = Data()
        out.appendBig(proto.rawValue)
        out.appendBig(UInt32(headerLength + extra.count + payload.count))
        if useSequences {
            out.appendBig(UInt32(0xfeed_face))
            out.appendBig(sequence)
            out.appendBig(acknowledgement)
        }
        out.append(extra)
        out.append(payload)
        return out
    }

    private func enqueue(_ data: Data) {
        condition.lock()
        outbound.append(data)
        condition.broadcast()
        condition.unlock()
    }
}

/// One TCP-over-mux channel, as a blocking byte pipe. Lockdown, AFC and installation_proxy all talk through this.
final class USBMuxPipe: @unchecked Sendable {
    /// What we advertise to the device; it is sent in units of 256 bytes, as the mux expects.
    static let receiveWindow: UInt32 = 131_072

    let sourcePort: UInt16
    let devicePort: UInt16
    private weak var device: MuxDevice?
    private let condition = NSCondition()
    private var buffer = Data()
    private var sequence: UInt32 = 0
    private var acknowledgement: UInt32 = 0
    private var deviceAcknowledged: UInt32 = 0
    private var deviceWindow: UInt32 = 32768
    private enum State { case connecting, open, closedByPeer, closed, reset }
    private var state: State = .connecting

    init(device: MuxDevice, sourcePort: UInt16, devicePort: UInt16) {
        self.device = device
        self.sourcePort = sourcePort
        self.devicePort = devicePort
    }

    var connecting: Bool {
        condition.lock()
        defer { condition.unlock() }
        return state == .connecting
    }

    var isOpen: Bool {
        condition.lock()
        defer { condition.unlock() }
        return state == .open || state == .connecting
    }

    func sequenceState() -> (sequence: UInt32, acknowledgement: UInt32) {
        condition.lock()
        defer { condition.unlock() }
        return (sequence, acknowledgement)
    }

    func canSend(bytes: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard state == .open else { return state == .connecting }
        let outstanding = sequence &- deviceAcknowledged
        return UInt32(bytes) + outstanding <= max(deviceWindow, 1024)
    }

    func sendableBytes() -> Int {
        condition.lock()
        defer { condition.unlock() }
        let outstanding = sequence &- deviceAcknowledged
        let window = max(deviceWindow, 1024)
        return window > outstanding ? Int(window - outstanding) : 0
    }

    func didSend(_ count: Int) {
        condition.lock()
        sequence = sequence &+ UInt32(count)
        condition.unlock()
    }

    // MARK: - Events from the mux

    func accepted(deviceSeq: UInt32, deviceAck: UInt32, window: UInt32) {
        condition.lock()
        sequence = sequence &+ 1
        acknowledgement = deviceSeq &+ 1
        deviceAcknowledged = deviceAck
        deviceWindow = window
        state = .open
        condition.broadcast()
        condition.unlock()
    }

    func noteRemote(deviceSeq: UInt32, deviceAck: UInt32, window: UInt32) {
        condition.lock()
        deviceAcknowledged = deviceAck
        deviceWindow = window
        condition.unlock()
    }

    func received(_ data: Data) {
        condition.lock()
        buffer.append(data)
        acknowledgement = acknowledgement &+ UInt32(data.count)
        condition.broadcast()
        condition.unlock()
    }

    func remoteClosed() {
        condition.lock()
        if state == .open { state = .closedByPeer }
        condition.broadcast()
        condition.unlock()
    }

    func remoteReset() {
        condition.lock()
        state = .reset
        condition.broadcast()
        condition.unlock()
    }

    func localClosed() {
        condition.lock()
        state = .closed
        condition.broadcast()
        condition.unlock()
    }

    func linkDropped() {
        condition.lock()
        state = .reset
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilConnected(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while state == .connecting {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw USBMuxError.timeout("opening port \(devicePort)") }
            condition.wait(until: Date(timeIntervalSinceNow: min(remaining, 0.25)))
        }
        switch state {
        case .open, .closedByPeer: return
        case .reset: throw USBMuxError.refused("the guest reset port \(devicePort)")
        default: throw USBMuxError.closed
        }
    }

    // MARK: - The byte pipe

    /// Blocks until `count` bytes are in hand. A short return means the channel closed first.
    func read(_ count: Int, timeout: TimeInterval = 20) throws -> Data {
        guard count > 0 else { return Data() }
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while buffer.count < count {
            if state == .reset { throw USBMuxError.closed }
            if state == .closed || state == .closedByPeer { break }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw USBMuxError.timeout("reading \(count) bytes from port \(devicePort)") }
            condition.wait(until: Date(timeIntervalSinceNow: min(remaining, 0.25)))
        }
        let take = min(count, buffer.count)
        let out = Data(buffer.prefix(take))
        buffer.removeFirst(take)
        return out
    }

    func write(_ data: Data, timeout: TimeInterval = 20) throws {
        guard let device else { throw USBMuxError.closed }
        guard isOpen else { throw USBMuxError.closed }
        try device.send(self, data: data, timeout: timeout)
    }

    func close() { device?.close(self) }
}

// MARK: - Big-endian helpers

extension Data {
    fileprivate mutating func appendBig(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    fileprivate mutating func appendBig(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    fileprivate func readBig32(_ offset: Int) -> UInt32 {
        let base = startIndex + offset
        guard base + 3 < endIndex else { return 0 }
        return (UInt32(self[base]) << 24) | (UInt32(self[base + 1]) << 16)
            | (UInt32(self[base + 2]) << 8) | UInt32(self[base + 3])
    }
}
