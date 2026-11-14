import Foundation

// AFC (Apple File Conduit): the service that libimobiledevice uses to put files on the device. Binary protocol over
// a lockdown-opened channel.
//
// Packet format:
//   magic:      "CFA6LPAA" (8 bytes)
//   entireLen:  uint64 LE (everything, including this header)
//   headerLen:  uint64 LE (this header + arguments; data follows after)
//   packetNum:  uint64 LE (correlation)
//   operation:  uint64 LE
//
// Operations used: 3 = file open, 8 = read, 9 = write, 20 = file close, 10 = make dir, 11 = file info,
// 13 = unlink. For an upload we only need: file open (mode wr), file write (chunks), file close.

enum AFCError: Error, CustomStringConvertible {
    case badPacket(String)
    case server(code: UInt64, path: String?)
    var description: String {
        switch self {
        case .badPacket(let m): return "afc: \(m)"
        case .server(let c, let p): return "afc: error \(c)\(p.map { " (\($0))" } ?? "")"
        }
    }
}

struct AFCPacket {
    static let magic: [UInt8] = Array("CFA6LPAA".utf8)
    var operation: UInt64
    var packetNum: UInt64
    var header: Data   // extra uint64 arguments
    var data: Data     // bulk body
}

enum AFCOp: UInt64 {
    case status = 1
    case data = 2
    case fileOpen = 13
    case fileOpenResult = 14
    case fileRead = 15
    case fileWrite = 16
    case fileClose = 20
    case makeDir = 9
    case unlink = 8        // AFC_OP_REMOVE_PATH
}

enum AFCMode: UInt64 {
    case read = 1
    case write = 3     // wr (truncate)
    case readWrite = 2
    case append = 4
    case readAppend = 5
}

final class AFCClient {
    let pipe: USBMuxPipe
    private var packetNum: UInt64 = 0

    init(pipe: USBMuxPipe) { self.pipe = pipe }

    private func nextNum() -> UInt64 { packetNum += 1; return packetNum }

    /// Opens a file for writing (truncate).
    func openWrite(_ path: String) throws -> UInt64 {
        var header = Data()
        var mode = AFCMode.write.rawValue.littleEndian
        withUnsafeBytes(of: &mode) { header.append(contentsOf: $0) }
        header.append(path.data(using: .utf8)!)
        header.append(0)  // NUL terminator
        let reply = try exchange(AFCPacket(operation: AFCOp.fileOpen.rawValue, packetNum: nextNum(), header: header, data: Data()))
        try throwIfError(reply, path: path)
        guard reply.header.count >= 8 else { throw AFCError.badPacket("file open: no handle") }
        return reply.header.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
    }

    func write(handle: UInt64, data: Data) throws {
        // The header of fileWrite is just the 8-byte handle; the body is the data.
        var header = Data()
        var h = handle.littleEndian
        withUnsafeBytes(of: &h) { header.append(contentsOf: $0) }
        let reply = try exchange(AFCPacket(operation: AFCOp.fileWrite.rawValue, packetNum: nextNum(), header: header, data: data))
        try throwIfError(reply, path: nil)
    }

    func close(handle: UInt64) throws {
        var header = Data()
        var h = handle.littleEndian
        withUnsafeBytes(of: &h) { header.append(contentsOf: $0) }
        let reply = try exchange(AFCPacket(operation: AFCOp.fileClose.rawValue, packetNum: nextNum(), header: header, data: Data()))
        try throwIfError(reply, path: nil)
    }

    func makeDir(_ path: String) throws {
        var header = Data()
        header.append(path.data(using: .utf8)!)
        header.append(0)
        let reply = try exchange(AFCPacket(operation: AFCOp.makeDir.rawValue, packetNum: nextNum(), header: header, data: Data()))
        try throwIfError(reply, path: path)
    }

    /// Uploads `url`'s contents to the AFC path `remote`. Chunks at 64 KiB.
    func upload(_ url: URL, to remote: String, progress: ((Double) -> Void)? = nil) throws {
        let handle = try openWrite(remote)
        defer { _ = try? close(handle: handle) }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let total = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        var sent: Int64 = 0
        while true {
            guard let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            try write(handle: handle, data: chunk)
            sent += Int64(chunk.count)
            if total > 0 { progress?(Double(sent) / Double(total)) }
        }
    }

    // MARK: - packet exchange

    private func exchange(_ packet: AFCPacket) throws -> AFCPacket {
        let frame = Self.encode(packet)
        try pipe.write(frame)
        return try Self.read(pipe)
    }

    private func throwIfError(_ packet: AFCPacket, path: String?) throws {
        guard packet.operation == AFCOp.status.rawValue || packet.operation == AFCOp.fileOpenResult.rawValue
            || packet.operation == AFCOp.data.rawValue
        else { return }
        if packet.operation == AFCOp.status.rawValue {
            let code = packet.header.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
            if code != 0 { throw AFCError.server(code: code, path: path) }
        }
    }

    static func encode(_ packet: AFCPacket) -> Data {
        var out = Data(capacity: 40 + packet.header.count + packet.data.count)
        out.append(contentsOf: AFCPacket.magic)
        let headerLen = UInt64(40 + packet.header.count)
        let entireLen = UInt64(40 + packet.header.count + packet.data.count)
        func append(_ v: UInt64) { var l = v.littleEndian; withUnsafeBytes(of: &l) { out.append(contentsOf: $0) } }
        append(entireLen)
        append(headerLen)
        append(packet.packetNum)
        append(packet.operation)
        out.append(packet.header)
        out.append(packet.data)
        return out
    }

    static func read(_ pipe: USBMuxPipe) throws -> AFCPacket {
        let head = try pipe.read(40)
        guard head.count == 40, Array(head.prefix(8)) == AFCPacket.magic else {
            throw AFCError.badPacket("bad header or magic")
        }
        let entireLen = head.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self).littleEndian }
        let headerLen = head.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self).littleEndian }
        let packetNum = head.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self).littleEndian }
        let op = head.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt64.self).littleEndian }
        let extra = Int(headerLen) - 40
        let header = extra > 0 ? try pipe.read(extra) : Data()
        let dataLen = Int(entireLen) - Int(headerLen)
        let data = dataLen > 0 ? try pipe.read(dataLen) : Data()
        return AFCPacket(operation: op, packetNum: packetNum, header: header, data: data)
    }
}
