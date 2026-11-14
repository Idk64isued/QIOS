import Foundation

// USB standard-request layer on top of TCPUSBTransport. Just enough of it to find Apple's usbmuxd interface and open
// its two bulk endpoints.
//
// The usbmuxd-over-USB path inside iOS 1.x–4.x:
//   - Class 0xFF (vendor-specific), subclass 0xFE (iPhone Driver), protocol 0x02 (iPhone/iPod Touch)
//   - One interface, two bulk endpoints: IN and OUT
//   - On top of those two endpoints, Apple runs its plist-framed mux protocol (see USBMuxClient.swift)

struct USBDeviceDescriptor {
    let length: UInt8
    let descriptorType: UInt8
    let bcdUSB: UInt16
    let deviceClass: UInt8
    let deviceSubclass: UInt8
    let deviceProtocol: UInt8
    let maxPacketSize0: UInt8
    let idVendor: UInt16
    let idProduct: UInt16
    let bcdDevice: UInt16
    let manufacturer: UInt8
    let product: UInt8
    let serialNumber: UInt8
    let numConfigurations: UInt8
}

struct USBInterfaceInfo {
    var number: UInt8
    var alternate: UInt8
    var `class`: UInt8
    var subclass: UInt8
    var `protocol`: UInt8
    var inEndpoint: UInt8   // with 0x80 set
    var outEndpoint: UInt8  // without 0x80
    var maxPacketIn: UInt16
    var maxPacketOut: UInt16
}

enum USBEnumError: Error, CustomStringConvertible {
    case noMuxInterface
    case descriptor(String)
    var description: String {
        switch self {
        case .noMuxInterface: return "USB: no Apple iPhone interface advertised (guest is not ready)"
        case .descriptor(let m): return "USB descriptor: \(m)"
        }
    }
}

/// Owns a TCPUSBTransport and drives a device through enumeration (set address, read config, set config). Then
/// hands out bulk read/write on the mux interface.
final class USBDevice {
    let transport: TCPUSBTransport
    private(set) var device: USBDeviceDescriptor?
    private(set) var mux: USBInterfaceInfo?

    init(transport: TCPUSBTransport) { self.transport = transport }

    /// Full bring-up: hello → reset → enumdone → device descriptor → set address 1 → config descriptor → set config.
    /// Returns once the device is in the configured state with the mux interface's bulk endpoints known.
    func enumerate(timeout: TimeInterval = 20) throws {
        LTMLog.note("usb: handshake")
        let maxTransaction = try transport.hello(timeout: timeout)
        LTMLog.note("usb: hello ok (max transaction \(maxTransaction) bytes)")
        try transport.signalReset()
        // The guest needs time after reset to arm EP0.
        var armed = false
        for _ in 0..<40 where !armed {
            if (try? transport.packet(ep: 0, flags: TCPUSBFlags.enumdone, timeout: 1)) != nil {
                armed = true; break
            }
            usleep(100_000)
        }
        if !armed { try transport.signalEnumDone() }

        // GET_DESCRIPTOR(Device, 18): bmRequestType=0x80, bRequest=6, wValue=0x0100
        let descBytes = try controlIn(
            bmRequestType: 0x80, bRequest: 6, wValue: 0x0100, wIndex: 0, wLength: 18, timeout: timeout)
        guard descBytes.count >= 18 else { throw USBEnumError.descriptor("device descriptor short") }
        let d = USBDeviceDescriptor(
            length: descBytes[0], descriptorType: descBytes[1],
            bcdUSB: u16(descBytes, 2), deviceClass: descBytes[4], deviceSubclass: descBytes[5],
            deviceProtocol: descBytes[6], maxPacketSize0: descBytes[7],
            idVendor: u16(descBytes, 8), idProduct: u16(descBytes, 10), bcdDevice: u16(descBytes, 12),
            manufacturer: descBytes[14], product: descBytes[15], serialNumber: descBytes[16],
            numConfigurations: descBytes[17])
        device = d
        LTMLog.note(String(format: "usb: device %04x:%04x %d config(s)", d.idVendor, d.idProduct, d.numConfigurations))

        // SET_ADDRESS(1): bmRequestType=0x00, bRequest=5, wValue=1
        try controlOut(bmRequestType: 0, bRequest: 5, wValue: 1, wIndex: 0, data: Data(), timeout: timeout)

        // GET_DESCRIPTOR(Configuration, 9) to learn wTotalLength, then the full config descriptor.
        let configHead = try controlIn(
            bmRequestType: 0x80, bRequest: 6, wValue: 0x0200, wIndex: 0, wLength: 9, timeout: timeout)
        guard configHead.count >= 9 else { throw USBEnumError.descriptor("config head short") }
        let total = Int(u16(configHead, 2))
        let fullConfig = try controlIn(
            bmRequestType: 0x80, bRequest: 6, wValue: 0x0200, wIndex: 0,
            wLength: UInt16(min(total, 4096)), timeout: timeout)
        guard let interface = Self.findMuxInterface(fullConfig) else { throw USBEnumError.noMuxInterface }
        mux = interface
        LTMLog.note(String(format: "usb: mux iface %d, bulk in %#04x out %#04x",
            interface.number, interface.inEndpoint, interface.outEndpoint))

        // SET_CONFIGURATION(configuration value from the config head byte 5).
        let configValue = UInt16(configHead[5])
        try controlOut(bmRequestType: 0, bRequest: 9, wValue: configValue, wIndex: 0, data: Data(), timeout: timeout)
    }

    /// Read a bulk packet from the mux IN endpoint. Returns a short read when the device has less; a 0-length is a ZLP.
    func bulkIn(size: Int, timeout: TimeInterval = 10) throws -> Data {
        guard let mux else { throw USBEnumError.noMuxInterface }
        let capped = min(size, Int(transport.hellomax))
        let (_, body) = try transport.transfer(
            ep: mux.inEndpoint, size: Int16(capped), timeout: timeout)
        return body
    }

    /// Write a bulk packet to the mux OUT endpoint. Breaks nothing up; one logical message per call per the spec.
    func bulkOut(_ data: Data, timeout: TimeInterval = 10) throws {
        guard let mux else { throw USBEnumError.noMuxInterface }
        let max = Int(transport.hellomax)
        if data.count > max { throw TCPUSBError.tooLarge(data.count) }
        _ = try transport.transfer(ep: mux.outEndpoint, data: data, timeout: timeout)
    }

    /// Send a zero-length packet on the mux OUT endpoint (iOS 4's mux uses ZLP as message terminator for writes whose
    /// length is a multiple of wMaxPacketSize).
    func bulkOutZLP(timeout: TimeInterval = 10) throws {
        guard let mux else { throw USBEnumError.noMuxInterface }
        _ = try transport.transfer(ep: mux.outEndpoint, data: Data(), timeout: timeout)
    }

    // MARK: - Control transfers

    func controlOut(bmRequestType: UInt8, bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data,
        timeout: TimeInterval) throws
    {
        let setup = controlSetup(bmRequestType, bRequest, wValue, wIndex, UInt16(data.count))
        _ = try transport.transfer(ep: 0, size: 8, data: setup, flags: TCPUSBFlags.setup, timeout: timeout)
        var off = 0
        while off < data.count {
            let end = min(off + 64, data.count)
            let chunk = data.subdata(in: off..<end)
            _ = try transport.transfer(ep: 0, size: Int16(chunk.count), data: chunk, timeout: timeout)
            off = end
        }
        _ = try transport.transfer(ep: 0x80, size: 0, timeout: timeout)
    }

    func controlIn(bmRequestType: UInt8, bRequest: UInt8, wValue: UInt16, wIndex: UInt16, wLength: UInt16,
        timeout: TimeInterval) throws -> Data
    {
        let setup = controlSetup(bmRequestType, bRequest, wValue, wIndex, wLength)
        _ = try transport.transfer(ep: 0, size: 8, data: setup, flags: TCPUSBFlags.setup, timeout: timeout)
        var out = Data()
        while out.count < Int(wLength) {
            let want = min(64, Int(wLength) - out.count)
            let (len, body) = try transport.transfer(ep: 0x80, size: Int16(want), timeout: timeout)
            out.append(body)
            if len < want { break }
        }
        _ = try transport.transfer(ep: 0, size: 0, timeout: timeout)
        return out
    }

    private func controlSetup(_ kind: UInt8, _ request: UInt8, _ value: UInt16, _ index: UInt16, _ length: UInt16)
        -> Data
    {
        var setup = Data(count: 8)
        setup[0] = kind
        setup[1] = request
        setup.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: value.littleEndian, toByteOffset: 2, as: UInt16.self)
            bytes.storeBytes(of: index.littleEndian, toByteOffset: 4, as: UInt16.self)
            bytes.storeBytes(of: length.littleEndian, toByteOffset: 6, as: UInt16.self)
        }
        return setup
    }

    // MARK: - Config descriptor walker

    /// Finds Apple's iPhone mux interface in a USB configuration descriptor and its two bulk endpoints.
    static func findMuxInterface(_ bytes: Data) -> USBInterfaceInfo? {
        var off = 0
        var pending: USBInterfaceInfo?
        var endpoints: [UInt8: UInt16] = [:]   // bEndpointAddress -> wMaxPacketSize
        while off + 2 <= bytes.count {
            let len = Int(bytes[off])
            let type = bytes[off + 1]
            if len < 2 || off + len > bytes.count { break }
            switch type {
            case 0x04:  // interface
                // bLength=9, bDescriptorType=4, bInterfaceNumber, bAlternateSetting, bNumEndpoints,
                // bInterfaceClass, bInterfaceSubClass, bInterfaceProtocol, iInterface
                if len >= 9 {
                    if let open = pending, open.class == 0xFF, open.subclass == 0xFE,
                        let outMax = endpoints[open.outEndpoint], let inMax = endpoints[open.inEndpoint]
                    {
                        var completed = open
                        completed.maxPacketIn = inMax
                        completed.maxPacketOut = outMax
                        return completed
                    }
                    pending = USBInterfaceInfo(
                        number: bytes[off + 2], alternate: bytes[off + 3],
                        class: bytes[off + 5], subclass: bytes[off + 6], protocol: bytes[off + 7],
                        inEndpoint: 0, outEndpoint: 0, maxPacketIn: 0, maxPacketOut: 0)
                    endpoints.removeAll()
                }
            case 0x05 where len >= 7:  // endpoint
                let address = bytes[off + 2]
                let attributes = bytes[off + 3]
                let maxPacket = u16(bytes, off + 4)
                endpoints[address] = maxPacket
                if attributes & 0x03 == 0x02 {   // bulk
                    if address & 0x80 != 0 {
                        pending?.inEndpoint = address
                    } else {
                        pending?.outEndpoint = address
                    }
                }
            default: break
            }
            off += len
        }
        if let open = pending, open.class == 0xFF, open.subclass == 0xFE,
            let outMax = endpoints[open.outEndpoint], let inMax = endpoints[open.inEndpoint]
        {
            var completed = open
            completed.maxPacketIn = inMax
            completed.maxPacketOut = outMax
            return completed
        }
        return nil
    }
}

private func u16(_ d: Data, _ off: Int) -> UInt16 {
    let base = d.startIndex + off
    return UInt16(d[base]) | (UInt16(d[base + 1]) << 8)
}
