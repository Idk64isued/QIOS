// The byte readers and writers FirmwareKit's formats share: integers at offsets of an image, hex, zlib's CRC-32.
import BinaryParsing
import Foundation
import zlib

/// The integer at offset `o` of `b`, read through ParserSpan: one past the end throws (FirmwareError's
/// unsupported) where a subscript would trap. What these read comes from firmware files and guest storage.
func le16(_ b: [UInt8], _ o: Int) throws -> UInt16 {
    try integer(b, o) { s throws(ParsingError) in try UInt16(parsingLittleEndian: &s) }
}
func le32(_ b: [UInt8], _ o: Int) throws -> UInt32 {
    try integer(b, o) { s throws(ParsingError) in try UInt32(parsingLittleEndian: &s) }
}
func le64(_ b: [UInt8], _ o: Int) throws -> UInt64 {
    try integer(b, o) { s throws(ParsingError) in try UInt64(parsingLittleEndian: &s) }
}
func be16(_ b: [UInt8], _ o: Int) throws -> UInt16 {
    try integer(b, o) { s throws(ParsingError) in try UInt16(parsingBigEndian: &s) }
}
func be32(_ b: [UInt8], _ o: Int) throws -> UInt32 {
    try integer(b, o) { s throws(ParsingError) in try UInt32(parsingBigEndian: &s) }
}
func be64(_ b: [UInt8], _ o: Int) throws -> UInt64 {
    try integer(b, o) { s throws(ParsingError) in try UInt64(parsingBigEndian: &s) }
}

private func integer<T: FixedWidthInteger>(
    _ b: [UInt8],
    _ o: Int,
    _ read: (inout ParserSpan) throws(ParsingError) -> T
) throws -> T {
    do {
        return try b.withParserSpan { s throws(ParsingError) in
            try s.seek(toRelativeOffset: o)
            return try read(&s)
        }
    } catch {
        throw FirmwareError(.unsupported, "\(MemoryLayout<T>.size) bytes at \(o) run past the \(b.count) there are")
    }
}

/// `v`, big-endian (HFS+), at `o`.
func putBE16(_ b: inout [UInt8], _ o: Int, _ v: UInt16) {
    b[o] = UInt8(v >> 8)
    b[o + 1] = UInt8(v & 0xFF)
}

/// `v`, big-endian (HFS+), at `o`.
func putBE32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    for k in 0..<4 { b[o + k] = UInt8(truncatingIfNeeded: v >> (24 - 8 * k)) }
}

/// `v`, big-endian (HFS+), at `o`.
func putBE64(_ b: inout [UInt8], _ o: Int, _ v: UInt64) {
    putBE32(&b, o, UInt32(v >> 32))
    putBE32(&b, o + 4, UInt32(truncatingIfNeeded: v))
}

/// `v`'s low 16 bits, little-endian, at `o`.
func put16(_ b: inout [UInt8], _ o: Int, _ v: Int) {
    b[o] = UInt8(v & 0xFF)
    b[o + 1] = UInt8((v >> 8) & 0xFF)
}

/// `v`, little-endian, at `o`.
func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    for k in 0..<4 { b[o + k] = UInt8(truncatingIfNeeded: v >> (8 * k)) }
}

/// zlib's CRC-32 of `b`.
func crc(_ b: ArraySlice<UInt8>) -> UInt32 {
    UInt32(b.withUnsafeBufferPointer { zlib.crc32(0, $0.baseAddress, uInt($0.count)) })
}

extension Sequence<UInt8> {
    /// Lowercase hex, two digits a byte.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// The parsers read firmware files through BinaryParsing's ParserSpan, whose reads check their bounds and throw.
extension ParserSpan {
    /// The integer `o` bytes in, big-endian; the span stays where it is.
    func be16(at o: Int) throws(ParsingError) -> UInt16 {
        var s = try seeking(toRelativeOffset: o)
        return try UInt16(parsingBigEndian: &s)
    }
    func be32(at o: Int) throws(ParsingError) -> UInt32 {
        var s = try seeking(toRelativeOffset: o)
        return try UInt32(parsingBigEndian: &s)
    }
    func le32(at o: Int) throws(ParsingError) -> UInt32 {
        var s = try seeking(toRelativeOffset: o)
        return try UInt32(parsingLittleEndian: &s)
    }
    func byte(at o: Int) throws(ParsingError) -> UInt8 {
        var s = try seeking(toRelativeOffset: o)
        return try UInt8(parsing: &s)
    }
    /// The `n` bytes `o` bytes in.
    func bytes(at o: Int, _ n: Int) throws(ParsingError) -> [UInt8] {
        var s = try seeking(toRelativeOffset: o)
        return try [UInt8](parsing: &s, byteCount: n)
    }
    /// The NUL-terminated string's bytes `o` bytes in: up to the NUL, or to the span's end when there is none.
    func cBytes(at o: Int) throws(ParsingError) -> [UInt8] {
        let s = try seeking(toRelativeOffset: o)
        return s.withUnsafeBytes { Array($0.prefix { $0 != 0 }) }
    }
    /// The NUL-terminated string `o` bytes in, as Latin-1.
    func latin1(at o: Int) throws(ParsingError) -> String {
        String(try cBytes(at: o).map { Character(Unicode.Scalar($0)) })
    }
}

/// `body` over `bytes`, a ParsingError (input cut short or out of range) as FirmwareError's unsupported, naming
/// `what`.
func parsing<T>(
    _ bytes: some ParserSpanProvider,
    _ what: @autoclosure () -> String,
    _ body: (inout ParserSpan) throws -> T
) throws -> T {
    do { return try bytes.withParserSpan(body) } catch let e as ParsingError {
        throw FirmwareError(.unsupported, "\(what()): \(e)")
    }
}
