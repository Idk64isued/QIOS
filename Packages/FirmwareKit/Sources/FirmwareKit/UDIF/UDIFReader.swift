// UDIFReader: the raw disk of a UDIF disk image (.dmg) without hdiutil. The image ends in a 512-byte "koly" trailer
// naming its XML property list, whose resource-fork "blkx" entries are "mish" block tables: runs of the disk's
// 512-byte sectors, each stored raw, zero-filled, or compressed (zlib or ADC; the IPSW root filesystems are zlib
// and raw). Writes the same bytes as `hdiutil convert -format UDTO`; zero runs are left sparse.
//
//   try UDIFReader.convertToRaw(dmg, to: raw)

import BinaryParsing
import Foundation
import zlib

enum UDIFReader {
    /// A block table's run: its type, where it goes in the disk and how long it is there, where it is stored and
    /// how long it is stored.
    struct Chunk { let type: UInt32, at: Int, size: Int, offset: UInt64, length: Int }

    static func convertToRaw(_ src: URL, to out: URL) throws {
        let input = open(src.path, O_RDONLY)
        guard input >= 0 else { throw FirmwareError(.internal, "open \(src.path)") }
        defer { close(input) }
        var st = stat()
        guard fstat(input, &st) == 0, st.st_size >= 512 else {
            throw FirmwareError(.unsupported, "\(src.lastPathComponent): too short")
        }
        func read(_ at: UInt64, _ n: Int) throws -> [UInt8] {
            guard at <= UInt64(st.st_size), UInt64(n) <= UInt64(st.st_size) - at else {
                throw FirmwareError(.unsupported, "\(src.lastPathComponent): read past its end at \(at)")
            }
            var b = [UInt8](repeating: 0, count: n)
            guard pread(input, &b, n, off_t(at)) == n else {
                throw FirmwareError(.unsupported, "\(src.lastPathComponent): read past its end at \(at)")
            }
            return b
        }
        let koly = try read(UInt64(st.st_size) - 512, 512)
        guard koly.starts(with: Array("koly".utf8)) else {
            throw FirmwareError(.unsupported, "\(src.lastPathComponent): no UDIF trailer")
        }
        // the data fork's offset, the XML property list's offset and length, the disk's size (its sectors' bytes)
        let (dataFork, xmlAt, xmlLength, disk) = try parsing(koly, "\(src.lastPathComponent): UDIF trailer") { s in
            try s.seek(toRelativeOffset: 0x18)
            let dataFork = try UInt64(parsingBigEndian: &s)
            try s.seek(toAbsoluteOffset: 0xD8)
            let xml = (try UInt64(parsingBigEndian: &s), try Int(parsing: &s, storedAsBigEndian: UInt64.self))
            try s.seek(toAbsoluteOffset: 0x1EC)
            let disk = try Int(parsing: &s, storedAsBigEndian: UInt64.self).multipliedThrowingOnOverflow(by: 512)
            return (dataFork, xml.0, xml.1, disk)
        }
        let xml = Data(try read(xmlAt, xmlLength))
        guard let plist = try PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
            let blkx = (plist["resource-fork"] as? [String: Any])?["blkx"] as? [[String: Any]]
        else { throw FirmwareError(.unsupported, "\(src.lastPathComponent): no blkx table") }

        guard FileManager.default.createFile(atPath: out.path, contents: nil) else {
            throw FirmwareError(.internal, "cannot create \(out.path)")
        }
        let output = open(out.path, O_WRONLY)
        guard output >= 0 else { throw FirmwareError(.internal, "open \(out.path)") }
        defer { close(output) }
        for entry in blkx {
            guard let m = entry["Data"] as? Data, m.starts(with: Array("mish".utf8)) else {
                throw FirmwareError(.unsupported, "\(src.lastPathComponent): a blkx entry is not a block table")
            }
            for (i, c) in try chunks(m, dataFork: dataFork, src).enumerated() {
                let (at, size) = (c.at, c.size)
                guard at <= disk, size <= disk - at else {
                    throw FirmwareError(.unsupported, "\(src.lastPathComponent): chunk \(i) past the disk's end")
                }
                let stored = { try read(c.offset, c.length) }
                let bytes: [UInt8]
                switch c.type {
                case 0, 2, 0x7FFF_FFFE, 0xFFFF_FFFF: continue  // zero-filled, ignored, comment, end
                case 1: bytes = try stored()
                case 0x8000_0005: bytes = try inflate(try stored(), size, src)
                case 0x8000_0004: bytes = try adc(try stored(), size, src)
                default:
                    throw FirmwareError(
                        .unsupported,
                        "\(src.lastPathComponent): chunk type \(String(c.type, radix: 16))"
                    )
                }
                guard bytes.count == size, pwrite(output, bytes, size, off_t(at)) == size else {
                    throw FirmwareError(.internal, "\(src.lastPathComponent): chunk \(i) at sector \(at / 512)")
                }
            }
        }
        guard ftruncate(output, off_t(disk)) == 0 else {
            throw FirmwareError(.internal, "truncate \(out.path)")
        }
    }

    /// A "mish" block table's runs: the table's first sector and its data's offset (from the data fork's), then at
    /// 200 the run count and the 40-byte runs (type, comment, sector, sector count, offset, length).
    static func chunks(_ m: Data, dataFork: UInt64, _ src: URL) throws -> [Chunk] {
        try parsing(m, "\(src.lastPathComponent): block table") { s in
            try s.seek(toRelativeOffset: 8)
            let first = try UInt64(parsingBigEndian: &s)
            try s.seek(toRelativeOffset: 8)
            let base = try dataFork.addingThrowingOnOverflow(try UInt64(parsingBigEndian: &s))
            try s.seek(toAbsoluteOffset: 200)
            var out: [Chunk] = []
            for _ in 0..<(try UInt32(parsingBigEndian: &s)) {
                let type = try UInt32(parsingBigEndian: &s)
                try s.seek(toRelativeOffset: 4)
                let sector = try first.addingThrowingOnOverflow(try UInt64(parsingBigEndian: &s))
                out.append(
                    Chunk(
                        type: type,
                        at: try Int(throwingOnOverflow: sector.multipliedThrowingOnOverflow(by: 512)),
                        size: try Int(parsing: &s, storedAsBigEndian: UInt64.self).multipliedThrowingOnOverflow(
                            by: 512
                        ),
                        offset: try base.addingThrowingOnOverflow(try UInt64(parsingBigEndian: &s)),
                        length: try Int(parsing: &s, storedAsBigEndian: UInt64.self)
                    )
                )
            }
            return out
        }
    }

    static func inflate(_ z: [UInt8], _ size: Int, _ src: URL) throws -> [UInt8] {
        // deflate expands at most 1032:1
        guard size <= 1032 * z.count + 1032 else {
            throw FirmwareError(.unsupported, "\(src.lastPathComponent): bad zlib chunk")
        }
        var out = [UInt8](repeating: 0, count: size)
        var n = uLongf(size)
        guard uncompress(&out, &n, z, uLong(z.count)) == Z_OK, n == size else {
            throw FirmwareError(.unsupported, "\(src.lastPathComponent): bad zlib chunk")
        }
        return out
    }

    /// Apple Data Compression: literal runs (0x80 | n-1), and copies of 3-18 bytes from up to 1 KiB back (two-byte
    /// codes) or 4-67 bytes from up to 64 KiB back (three-byte codes).
    static func adc(_ c: [UInt8], _ size: Int, _ src: URL) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(min(size, 67 * c.count))
        var i = 0
        while i < c.count && out.count < size {
            let b = Int(c[i])
            var length: Int
            var distance: Int
            if b & 0x80 != 0 {
                length = (b & 0x7F) + 1
                guard i + 1 + length <= c.count else { break }
                out += c[i + 1..<i + 1 + length]
                i += 1 + length
                continue
            } else if b & 0x40 != 0 {
                guard i + 3 <= c.count else { break }
                length = (b & 0x3F) + 4
                distance = Int(c[i + 1]) << 8 | Int(c[i + 2])
                i += 3
            } else {
                guard i + 2 <= c.count else { break }
                length = (b >> 2 & 0x0F) + 3
                distance = (b & 0x03) << 8 | Int(c[i + 1])
                i += 2
            }
            guard distance < out.count else {
                throw FirmwareError(.unsupported, "\(src.lastPathComponent): bad ADC chunk")
            }
            for _ in 0..<length { out.append(out[out.count - distance - 1]) }
        }
        guard out.count == size else { throw FirmwareError(.unsupported, "\(src.lastPathComponent): short ADC chunk") }
        return out
    }
}
