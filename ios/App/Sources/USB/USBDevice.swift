import Foundation

// Standard USB enumeration over the TCP transport.
//
// The device model has NO concept of a control transfer: SETUP, data and status are three independent endpoint
// transactions and the guest's own USB stack supplies the descriptors. So a host bridge performs enumeration by
// hand, in the order the spec fixes:
//
//     hello -> reset -> (guest programs DCFG and EP0) -> enumdone -> SETUP on EP0
//
// The sequence below is deliberately the same one QEMU runs in-process when no bridge is configured
// (synopsys_host_tick in hw/arm/ipod_touch_usb_otg.c): device descriptor, SET_ADDRESS 1, every configuration
// descriptor until the one carrying the mux interface (class 255, subclass 254, protocol 2), SET_CONFIGURATION of
// that one, Apple's vendor power request, then the string descriptors. Passing usb-tcp-addr switches that built-in
// host off, so anything it does that we skip is something the guest stops getting — the power request in
// particular is what makes iOS report external power and stop idle-sleeping.

struct USBDeviceDescriptor {
    var bcdUSB: UInt16 = 0
    var deviceClass: UInt8 = 0
    var maxPacketSize0: UInt8 = 64
    var idVendor: UInt16 = 0
    var idProduct: UInt16 = 0
    var manufacturer: UInt8 = 0
    var product: UInt8 = 0
    var serialNumber: UInt8 = 0
    var numConfigurations: UInt8 = 0
}

/// The mux interface and its two bulk endpoints.
struct USBMuxInterface {
    var number: UInt8 = 0
    var inEndpoint: UInt8 = 0x81
    var outEndpoint: UInt8 = 0x02
    var maxPacketIn: UInt16 = 64
    var maxPacketOut: UInt16 = 64
    /// bConfigurationValue of the configuration this interface belongs to.
    var configurationValue: UInt8 = 1
}

enum USBEnumError: Error, CustomStringConvertible {
    case noMuxInterface
    case descriptor(String)
    var description: String {
        switch self {
        case .noMuxInterface: return "the guest advertises no Apple mux interface yet"
        case .descriptor(let m): return "USB descriptor: \(m)"
        }
    }
    var isRetryable: Bool { true }
}

/// Drives one device through enumeration and then owns its bulk endpoints.
final class USBDevice {
    let transport: TCPUSBTransport
    private(set) var descriptor = USBDeviceDescriptor()
    private(set) var mux: USBMuxInterface?
    private(set) var serial: String?
    /// The largest payload the device will take in one transaction, from the hello.
    private(set) var maxTransaction = TCPUSB.maxTransaction

    init(transport: TCPUSBTransport) { self.transport = transport }

    // MARK: - Bring-up

    /// hello → reset → enumdone → descriptors → SET_ADDRESS → SET_CONFIGURATION → power request → strings.
    /// Throws on anything that did not work; the caller is expected to wait and start over, which is what a real
    /// host does and what QEMU's own built-in host does every 3 seconds until the guest answers.
    func enumerate() throws {
        let hello = try transport.hello()
        maxTransaction = hello.maxTransaction

        // A USB reset, then enumeration-done once the guest has had a moment to arm EP0. The built-in host leaves
        // 500 ms between the two and so do we: sending enumdone too early leaves the guest's driver behind.
        try transport.signalReset()
        Thread.sleep(forTimeInterval: 0.5)
        try transport.signalEnumDone()
        Thread.sleep(forTimeInterval: 0.5)

        // GET_DESCRIPTOR(DEVICE, 18)
        let deviceBytes = try controlIn(0x80, 6, 0x0100, 0, 18)
        guard deviceBytes.count >= 18, deviceBytes[1] == 1 else {
            throw USBEnumError.descriptor("device descriptor is \(deviceBytes.count) bytes")
        }
        descriptor = USBDeviceDescriptor(
            bcdUSB: u16(deviceBytes, 2), deviceClass: deviceBytes[4], maxPacketSize0: deviceBytes[7],
            idVendor: u16(deviceBytes, 8), idProduct: u16(deviceBytes, 10),
            manufacturer: deviceBytes[14], product: deviceBytes[15], serialNumber: deviceBytes[16],
            numConfigurations: deviceBytes[17])

        // SET_ADDRESS(1), then let the guest program DCFG before the next SETUP, as usbmuxd does.
        try controlOut(0x00, 5, 1, 0, Data())
        Thread.sleep(forTimeInterval: 0.1)

        // Walk the configurations and keep the one with the mux interface; fall back to the last one.
        var chosen: USBMuxInterface?
        var fallbackValue: UInt8?
        let configurations = max(Int(descriptor.numConfigurations), 1)
        for index in 0..<configurations {
            let value = UInt16(0x0200) | UInt16(index)
            let head = try controlIn(0x80, 6, value, 0, 9)
            guard head.count >= 9 else { throw USBEnumError.descriptor("configuration header is \(head.count) bytes") }
            let total = Int(u16(head, 2))
            guard total >= 9, total <= 4096 else { throw USBEnumError.descriptor("configuration is \(total) bytes") }
            let full = try controlIn(0x80, 6, value, 0, UInt16(total))
            let configurationValue = full.count > 5 ? full[5] : head[5]
            fallbackValue = configurationValue
            if var found = Self.findMuxInterface(full) {
                found.configurationValue = configurationValue
                chosen = found
                break
            }
        }
        var interface: USBMuxInterface
        if let found = chosen {
            interface = found
        } else {
            // No mux interface in any configuration. Fall back to the endpoints QEMU's built-in host assumes
            // (0x81 in, 0x02 out) rather than refusing to configure the device at all.
            guard let value = fallbackValue else { throw USBEnumError.noMuxInterface }
            interface = USBMuxInterface()
            interface.configurationValue = value
            LTMLog.note("usb: no mux interface advertised; using the default bulk endpoints")
        }
        mux = interface

        // SET_CONFIGURATION, which is what makes the guest's mux interface come up.
        try controlOut(0x00, 9, UInt16(interface.configurationValue), 0, Data())

        // Apple's vendor power request, as a Mac's high-power port sends it: 500 mA base plus 1600 mA extra. Without
        // it iOS reports a 500 mA port, says "Not Charging" and keeps idle-sleeping.
        do {
            try controlOut(0x40, 0x40, 500, 1600, Data())
        } catch {
            LTMLog.note("usb: power request refused (\(error)); carrying on")
        }

        // String descriptors are optional: a STALL here is not a failure.
        _ = try? controlIn(0x80, 6, 0x0300, 0, 255)
        if descriptor.serialNumber != 0,
            let raw = try? controlIn(0x80, 6, 0x0300 | UInt16(descriptor.serialNumber), 0x0409, 255),
            raw.count > 2
        {
            serial = String(data: Data(raw.dropFirst(2)), encoding: .utf16LittleEndian)
        }
        LTMLog.note(String(format: "usb: device %04x:%04x configured (config %d, bulk in %#04x out %#04x)%@",
            descriptor.idVendor, descriptor.idProduct, Int(interface.configurationValue),
            interface.inEndpoint, interface.outEndpoint, serial.map { ", serial \($0)" } ?? ""))
    }

    // MARK: - Bulk endpoints

    /// Polls the mux IN endpoint once. An idle endpoint NAKs, which is not an error: that comes back as nil.
    /// A short read is normal — the device answers min(armed, requested) and keeps the rest armed for the next poll.
    func bulkIn(size: Int = TCPUSB.pollSize, nakTimeout: TimeInterval = 0.002) throws -> Data? {
        guard let mux else { throw USBEnumError.noMuxInterface }
        let want = min(size, maxTransaction)
        guard let reply = try transport.transfer(
            ep: mux.inEndpoint, inLength: want, nakTimeout: nakTimeout, nakIsEmpty: true)
        else { return nil }
        return reply.data
    }

    /// Writes one logical packet to the mux OUT endpoint. The transport is transfer-oriented: one OUT transaction is
    /// one complete transfer and the device retires the endpoint afterwards, so a packet is never split. A ZLP
    /// follows when the length is a multiple of the endpoint's wMaxPacketSize, which is how the guest's mux finds
    /// the end of a message.
    func bulkOut(_ data: Data, nakTimeout: TimeInterval = 2) throws {
        guard let mux else { throw USBEnumError.noMuxInterface }
        guard data.count <= maxTransaction else { throw TCPUSBError.tooLarge(data.count) }
        guard try transport.transfer(ep: mux.outEndpoint, out: data, nakTimeout: nakTimeout) != nil else {
            throw TCPUSBError.timeout("bulk OUT")
        }
        let packetSize = Int(mux.maxPacketOut == 0 ? 64 : mux.maxPacketOut)
        if !data.isEmpty, data.count % packetSize == 0 {
            _ = try? transport.transfer(ep: mux.outEndpoint, out: Data(), nakTimeout: 0.5)
        }
    }

    // MARK: - Control transfers

    /// SETUP, then 64-byte IN chunks until the device answers short, then the OUT status stage.
    func controlIn(_ kind: UInt8, _ request: UInt8, _ value: UInt16, _ index: UInt16, _ length: UInt16) throws -> [UInt8] {
        try sendSetup(kind, request, value, index, length)
        var out = [UInt8]()
        let packet = Int(descriptor.maxPacketSize0 == 0 ? 64 : descriptor.maxPacketSize0)
        while out.count < Int(length) {
            let want = min(packet, Int(length) - out.count)
            guard let reply = try transport.transfer(ep: TCPUSB.directionIn, inLength: want, nakTimeout: 2) else {
                throw TCPUSBError.timeout("control IN")
            }
            out.append(contentsOf: [UInt8](reply.data))
            if reply.status < want { break }   // a short packet ends the data stage
        }
        _ = try transport.transfer(ep: 0, nakTimeout: 2)            // status: zero-length OUT
        return out
    }

    /// SETUP, then 64-byte OUT chunks, then the IN status stage.
    func controlOut(_ kind: UInt8, _ request: UInt8, _ value: UInt16, _ index: UInt16, _ payload: Data) throws {
        // subdata(in:) below takes absolute indices, so a sliced Data has to be re-indexed first.
        let data = payload.startIndex == 0 ? payload : Data(payload)
        try sendSetup(kind, request, value, index, UInt16(data.count))
        var offset = 0
        let packet = Int(descriptor.maxPacketSize0 == 0 ? 64 : descriptor.maxPacketSize0)
        while offset < data.count {
            let end = min(offset + packet, data.count)
            let chunk = data.subdata(in: offset..<end)
            guard let reply = try transport.transfer(ep: 0, out: chunk, nakTimeout: 2) else {
                throw TCPUSBError.timeout("control OUT")
            }
            guard reply.status == chunk.count else {
                throw USBEnumError.descriptor("control OUT took \(reply.status) of \(chunk.count) bytes")
            }
            offset = end
        }
        _ = try transport.transfer(ep: TCPUSB.directionIn, nakTimeout: 2)   // status: zero-length IN
    }

    private func sendSetup(_ kind: UInt8, _ request: UInt8, _ value: UInt16, _ index: UInt16, _ length: UInt16) throws {
        var setup = Data(count: 8)
        setup[0] = kind
        setup[1] = request
        setup[2] = UInt8(truncatingIfNeeded: value)
        setup[3] = UInt8(truncatingIfNeeded: value >> 8)
        setup[4] = UInt8(truncatingIfNeeded: index)
        setup[5] = UInt8(truncatingIfNeeded: index >> 8)
        setup[6] = UInt8(truncatingIfNeeded: length)
        setup[7] = UInt8(truncatingIfNeeded: length >> 8)
        guard try transport.transfer(ep: 0, flags: TCPUSBFlags.setup, out: setup, nakTimeout: 2) != nil else {
            throw TCPUSBError.timeout("SETUP")
        }
    }

    // MARK: - Configuration descriptor walker

    /// Finds Apple's mux interface (class 255, subclass 254, protocol 2) and its two bulk endpoints.
    static func findMuxInterface(_ bytes: [UInt8]) -> USBMuxInterface? {
        var offset = 0
        var current: USBMuxInterface?
        var isMux = false
        var best: USBMuxInterface?
        while offset + 2 <= bytes.count {
            let length = Int(bytes[offset])
            let type = bytes[offset + 1]
            if length < 2 || offset + length > bytes.count { break }
            switch type {
            case 0x04 where length >= 9:   // interface
                if isMux, let done = current, done.inEndpoint != 0, done.outEndpoint != 0 { best = done }
                isMux = bytes[offset + 5] == 255 && bytes[offset + 6] == 254 && bytes[offset + 7] == 2
                current = isMux
                    ? USBMuxInterface(
                        number: bytes[offset + 2], inEndpoint: 0, outEndpoint: 0,
                        maxPacketIn: 64, maxPacketOut: 64)
                    : nil
            case 0x05 where length >= 7:   // endpoint
                if isMux, current != nil {
                    let address = bytes[offset + 2]
                    let attributes = bytes[offset + 3]
                    let maxPacket = u16(bytes, offset + 4)
                    if attributes & 0x03 == 0x02 {   // bulk
                        if address & 0x80 != 0 {
                            current?.inEndpoint = address
                            current?.maxPacketIn = maxPacket
                        } else {
                            current?.outEndpoint = address
                            current?.maxPacketOut = maxPacket
                        }
                    }
                }
            default: break
            }
            offset += length
        }
        if isMux, let done = current, done.inEndpoint != 0, done.outEndpoint != 0 { best = done }
        return best
    }
}

private func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    guard offset + 1 < bytes.count else { return 0 }
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}
