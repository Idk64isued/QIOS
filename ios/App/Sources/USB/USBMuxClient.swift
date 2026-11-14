import Foundation

// usbmux over the two bulk endpoints exposed by USBDevice.
//
// usbmux's wire protocol (per libusbmuxd / libimobiledevice):
//   struct usbmux_header {
//       uint32_t length;    // includes this header
//       uint32_t version;   // 1 = XML-plist body, 2 = binary-plist body
//       uint32_t message;   // 8 = plist
//       uint32_t tag;       // caller-chosen correlation id
//   } __attribute__((packed));
//
// On top of that: plist messages. We stay on binary plist (version 2).
// Commands we actually need:
//   MessageType=Connect, DeviceID=<id>, PortNumber=<big-endian port>
//     Opens a channel; after SUCCESS, the mux pipe IS the service pipe (no more mux framing).
//   MessageType=ReadBUID, ReadPairRecord — not needed for unauthenticated services.
//
// On this USB transport there is no DeviceID (the mux is the device itself). We send 0 for DeviceID, which is what
// the spec calls "the device on this channel".

enum USBMuxError: Error, CustomStringConvertible {
    case badFrame(String)
    case notConnected
    case serverError(code: Int, message: String)
    var description: String {
        switch self {
        case .badFrame(let m): return "usbmux: \(m)"
        case .notConnected: return "usbmux: connect refused"
        case .serverError(let c, let m): return "usbmux: server returned \(c) \(m)"
        }
    }
}

final class USBMuxClient {
    let device: USBDevice
    private var nextTag: UInt32 = 1

    init(device: USBDevice) { self.device = device }

    /// Builds a usbmux frame around a plist body.
    static func frame(message: UInt32 = 8, version: UInt32 = 1, tag: UInt32, body: Data) -> Data {
        var header = Data(count: 16)
        let length = UInt32(16 + body.count)
        header.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: length.littleEndian, toByteOffset: 0, as: UInt32.self)
            bytes.storeBytes(of: version.littleEndian, toByteOffset: 4, as: UInt32.self)
            bytes.storeBytes(of: message.littleEndian, toByteOffset: 8, as: UInt32.self)
            bytes.storeBytes(of: tag.littleEndian, toByteOffset: 12, as: UInt32.self)
        }
        header.append(body)
        return header
    }

    /// Sends one usbmux request + reads one reply. Used for the pre-Connect commands. After Connect succeeds the
    /// `Pipe` below takes over the two endpoints and no more mux framing is used.
    func request(_ plist: [String: Any]) throws -> (header: (version: UInt32, message: UInt32, tag: UInt32), body: Data) {
        let bodyData: Data
        // The guest's usbmuxd expects plist version 1 (XML) for most requests — binary plist is fine too on 3.x+.
        // We use XML for maximum compatibility.
        bodyData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let tag = nextTag; nextTag &+= 1
        let out = Self.frame(message: 8, version: 1, tag: tag, body: bodyData)
        try device.bulkOut(out)
        // Mux writes expect a ZLP after any OUT whose length is a multiple of wMaxPacketSize (iOS 4's reassembler needs it).
        if out.count % Int(device.mux?.maxPacketOut ?? 64) == 0 { try? device.bulkOutZLP() }

        // Read one frame. Payload can arrive over several bulk IN packets.
        var buffer = Data()
        let want = 16
        while buffer.count < want {
            let next = try device.bulkIn(size: 16384)
            if next.isEmpty { break }
            buffer.append(next)
        }
        guard buffer.count >= want else { throw USBMuxError.badFrame("short header") }
        let length = buffer.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
        let version = buffer.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }
        let message = buffer.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self).littleEndian }
        let replyTag = buffer.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self).littleEndian }
        while buffer.count < Int(length) {
            let next = try device.bulkIn(size: 16384)
            if next.isEmpty { break }
            buffer.append(next)
        }
        let payload = Data(buffer.dropFirst(16).prefix(Int(length) - 16))
        return ((version, message, replyTag), payload)
    }

    /// Opens a TCP-like channel to `port` on the guest. Returns a pipe that reads/writes raw bytes; usbmux framing
    /// is gone from this point on.
    func connect(toPort port: UInt16) throws -> USBMuxPipe {
        // PortNumber must be sent in big-endian inside the plist (usbmuxd quirk from the days when it was a straight
        // uint16 on the wire).
        let beSwap = Int((UInt16(port) >> 8) | (UInt16(port) << 8) & 0xFF00)
        let request: [String: Any] = [
            "MessageType": "Connect",
            "DeviceID": 0,
            "PortNumber": beSwap,
            "ProgName": "LightTouch",
            "ClientVersionString": "LightTouch-iOS"
        ]
        let (_, body) = try self.request(request)
        guard let plist = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw USBMuxError.badFrame("reply not a plist")
        }
        let number = (plist["Number"] as? Int) ?? ((plist["Number"] as? NSNumber)?.intValue ?? -1)
        if number != 0 {
            let message = (plist["ErrorMessage"] as? String) ?? "connect failed"
            throw USBMuxError.serverError(code: number, message: message)
        }
        return USBMuxPipe(device: device)
    }
}

/// A duplex byte pipe over the mux IN/OUT bulk endpoints after a successful Connect. Reads and writes raw bytes with
/// no framing of their own.
final class USBMuxPipe {
    let device: USBDevice
    private var pending = Data()
    private var closed = false

    init(device: USBDevice) { self.device = device }

    /// Blocks until `count` bytes have been read (or the stream closes short).
    func read(_ count: Int, timeout: TimeInterval = 20) throws -> Data {
        while pending.count < count, !closed {
            let next = try device.bulkIn(size: 16384, timeout: timeout)
            if next.isEmpty { closed = true; break }
            pending.append(next)
        }
        let take = min(count, pending.count)
        let out = Data(pending.prefix(take))
        pending.removeFirst(take)
        return out
    }

    /// Writes `data` as one or more bulk packets; appends a ZLP when the total is a multiple of the OUT endpoint's
    /// wMaxPacketSize (iOS 4's mux needs it as a message terminator).
    func write(_ data: Data, timeout: TimeInterval = 20) throws {
        guard let mux = device.mux else { throw USBEnumError.noMuxInterface }
        let max = Int(mux.maxPacketOut)
        var off = 0
        while off < data.count {
            let end = min(off + Int(device.transport.hellomax), data.count)
            try device.bulkOut(data.subdata(in: off..<end), timeout: timeout)
            off = end
        }
        if data.count > 0, data.count % max == 0 { try? device.bulkOutZLP() }
    }
}
