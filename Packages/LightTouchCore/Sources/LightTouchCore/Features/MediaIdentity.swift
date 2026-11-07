import BinaryParsing
import Crypto
import Foundation
import HostServiceWire

public nonisolated enum MediaIdentity {
    /// Content-derived UUID; AFC compares every existing byte before reuse.
    /// Host work directories remain unique so simultaneous preparation is safe.
    public static func identifier(for file: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 65536), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        var bytes = Array(hash.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80  // UUID custom-content version.
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let cuts = [0, 8, 12, 16, 20, 32]
        return zip(cuts, cuts.dropFirst()).map { start, end in
            String(hex[hex.index(hex.startIndex, offsetBy: start)..<hex.index(hex.startIndex, offsetBy: end)])
        }.joined(separator: "-")
    }
    /// Audio/video encoders put the current time in generated movie headers.
    /// Zero only those timestamps so repeated conversion has identical bytes.
    public static func normalizeGeneratedMovie(_ file: URL) throws {
        let stamps = try timestamps(in: Data(contentsOf: file, options: .alwaysMapped))
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        for stamp in stamps {
            try handle.seek(toOffset: UInt64(stamp.lowerBound))
            try handle.write(contentsOf: Data(count: stamp.count))
        }
    }

    /// Where the movie's creation and modification times are: each mvhd, tkhd and mdhd atom's two, after its version
    /// and flags (32-bit times in version 0, 64-bit in 1), inside moov, trak and mdia, at most four deep and 4096 atoms
    /// in all. An atom is a big-endian size (1: a 64-bit size follows the type; 0: to the end of its parent) and a type.
    static func timestamps(in movie: Data) throws -> [Range<Int>] {
        var atoms = 0
        func walk(_ s: inout ParserSpan, _ depth: Int) throws -> [Range<Int>] {
            guard depth <= 4 else { throw invalid }
            var out: [Range<Int>] = []
            while !s.isEmpty {
                try Task.checkCancellation()
                atoms += 1
                guard atoms <= 4096 else { throw invalid }
                var size = UInt64(try UInt32(parsingBigEndian: &s))
                let kind = String(decoding: try [UInt8](parsing: &s, byteCount: 4), as: UTF8.self)
                var headerSize: UInt64 = 8
                if size == 1 {
                    size = try UInt64(parsingBigEndian: &s)
                    headerSize = 16
                } else if size == 0 {
                    size = UInt64(s.count) + headerSize
                }
                guard size >= headerSize else { throw invalid }
                var body = try s.sliceSpan(byteCount: size - headerSize)
                if ["moov", "trak", "mdia"].contains(kind) {
                    out += try walk(&body, depth + 1)
                } else if ["mvhd", "tkhd", "mdhd"].contains(kind) {
                    let version = try UInt8(parsing: &body)
                    guard version <= 1 else { throw invalid }
                    try body.seek(toRelativeOffset: 3)  // flags
                    let times = try body.sliceRange(byteCount: version == 0 ? 8 : 16)
                    out.append(times.lowerBound..<times.upperBound)
                }
            }
            return out
        }
        do { return try movie.withParserSpan { s in try walk(&s, 0) } } catch is ParsingError { throw invalid }
    }

    static var invalid: DeviceToolsError { .failed("The converted media file is invalid.") }
}
