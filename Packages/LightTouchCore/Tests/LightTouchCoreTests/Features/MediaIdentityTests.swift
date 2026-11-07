import Foundation
import Testing

@testable import LightTouchCore

/// Content IDs and the bounded normalization of generated M4A timestamps (MediaIdentity).
struct MediaIdentityTests {
    func word(_ n: UInt32) -> Data {
        Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
    }
    func atom(_ kind: String, _ data: Data) -> Data { word(UInt32(data.count + 8)) + Data(kind.utf8) + data }

    @Test func normalizationClearsOnlyTheTimestampsAndIsIdempotent() throws {
        try withTemporaryFile { file in
            var payload = Data(repeating: 0x55, count: 32)
            payload[0] = 1
            try
                (atom("moov", atom("trak", atom("mdia", atom("mdhd", payload))))
                + atom("mdat", Data("unchanged audio".utf8))).write(to: file)
            try MediaIdentity.normalizeGeneratedMovie(file)
            payload.replaceSubrange(4..<20, with: Data(count: 16))
            let expected =
                atom("moov", atom("trak", atom("mdia", atom("mdhd", payload))))
                + atom("mdat", Data("unchanged audio".utf8))
            #expect(try Data(contentsOf: file) == expected)

            let first = try MediaIdentity.identifier(for: file)
            try MediaIdentity.normalizeGeneratedMovie(file)
            #expect(try MediaIdentity.identifier(for: file) == first)
            #expect(UUID(uuidString: first) != nil)
            try Data("different".utf8).write(to: file)
            #expect(try MediaIdentity.identifier(for: file) != first)
        }
    }

    nonisolated static let malformed: [Data] = [
        Data([0, 0, 0, 4] as [UInt8]) + Data("mvhd".utf8),  // a size below the header
        // a 64-bit size past the end
        Data([0, 0, 0, 1] as [UInt8]) + Data("moov".utf8) + Data(repeating: 255, count: 8),
        // an unknown version
        Data([0, 0, 0, 28] as [UInt8]) + Data("mvhd".utf8) + Data([2, 0, 0, 0] as [UInt8]) + Data(count: 16),
        Data([0, 0, 0] as [UInt8]),  // a truncated header
        // a child running past its parent (moov holds 8 bytes; its trak claims 16)
        Data([0, 0, 0, 16] as [UInt8]) + Data("moov".utf8) + Data([0, 0, 0, 16] as [UInt8]) + Data("trak".utf8)
            + Data(count: 8),
        // a version 1 timestamp field cut short by its atom
        Data([0, 0, 0, 20] as [UInt8]) + Data("tkhd".utf8) + Data([1, 0, 0, 0] as [UInt8]) + Data(count: 8)
    ]

    @Test(arguments: malformed)
    func malformedAtomsAreRefused(_ data: Data) throws {
        try withTemporaryFile { file in
            try data.write(to: file)
            #expect(throws: (any Error).self) { try MediaIdentity.normalizeGeneratedMovie(file) }
        }
    }

    @Test func nestingDepthIsBounded() throws {
        try withTemporaryFile { file in
            try atom("moov", atom("moov", atom("moov", atom("moov", atom("moov", Data()))))).write(to: file)
            #expect(throws: (any Error).self) { try MediaIdentity.normalizeGeneratedMovie(file) }
        }
    }
}
