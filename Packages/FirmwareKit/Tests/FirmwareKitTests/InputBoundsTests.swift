import Crypto
import Foundation
import Testing

@testable import FirmwareKit

/// What a prepare reads is what it hashed (Preparer.pinnedCopy), and the raw byte readers throw past their input
/// instead of reading beyond it.
struct InputBoundsTests {
    static func sha1(_ d: Data) -> String { Insecure.SHA1.hash(data: d).hexString }

    /// The verify step's private copy: the pinned bytes are copied, the user's file changing afterward changes
    /// nothing read, and other bytes are refused with no copy left.
    @Test func theCopyIsWhatWasHashed() throws {
        try Oracle.withTemp { dir in
            let user = dir.appendingPathComponent("user.ipsw")
            let pinned = Data("the pinned IPSW".utf8)
            try pinned.write(to: user)
            let work = dir.appendingPathComponent("work")
            let copy = try Preparer.pinnedCopy(user, sha1: Self.sha1(pinned).uppercased(), entry: "test", into: work)
            try Data("changed after the check".utf8).write(to: user)
            #expect(try Data(contentsOf: copy) == pinned)
            #expect(copy.path.hasPrefix(work.path + "/"))

            do {
                _ = try Preparer.pinnedCopy(user, sha1: Self.sha1(pinned), entry: "test", into: work)
                Issue.record("other bytes were taken as the pinned IPSW")
            } catch let error as FirmwareError {
                #expect(error.code == .shaMismatch)
            }
            #expect(!FileManager.default.fileExists(atPath: copy.path), "a refused copy is removed")
        }
    }

    /// The steps after verify read the private copy, never the file the options name.
    @Test func theStepsReadOnlyTheCopy() throws {
        struct Catalog: Decodable { var entries: [FirmwareEntry] }
        let entries = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: Oracle.catalog)).entries
        let entry = try #require(entries.first { $0.recipe != nil })
        try Oracle.withTemp { dir in
            let user = dir.appendingPathComponent("user.ipsw")
            let c = Recipe.Context(
                Preparer.Options(entry: entry, ipsw: user, out: dir, helper: nil, guestTools: dir),
                recipe: try #require(entry.recipe),
                emit: { _ in }
            )
            #expect(c.ipsw.url != user, "before verify nothing reads the user's file")
            c.source = c.work.appendingPathComponent("copy.ipsw")
            #expect(c.ipsw.url == c.source)
        }
    }

    @Test func rawReadersThrowPastTheirInput() throws {
        let bytes = Data([1, 2, 3, 4, 5, 6])
        let b = [UInt8](bytes)
        #expect(try le32(b, 2) == 0x0605_0403)
        #expect(try be16(b, 4) == 0x0506)
        #expect(throws: FirmwareError.self) { try le32(b, 3) }
        #expect(throws: FirmwareError.self) { try le16(b, -1) }
        #expect(throws: FirmwareError.self) { try be64(b, 0) }
        #expect(throws: FirmwareError.self) { try parsing(bytes, "t") { s in try s.bytes(at: 4, Int.max) } }
        #expect(try parsing(bytes, "t") { s in try s.cBytes(at: 4) } == [5, 6])
        #expect(throws: FirmwareError.self) { try parsing(bytes, "t") { s in try s.cBytes(at: 7) } }
    }

    /// A 32-bit Mach-O whose load commands claim more than the file holds.
    @Test func aTruncatedMachOThrows() {
        var header = Data(count: 28)
        header.replaceSubrange(0..<4, with: [0xCE, 0xFA, 0xED, 0xFE])
        header.replaceSubrange(16..<20, with: [1, 0, 0, 0])  // one command, none there
        #expect(throws: FirmwareError.self) { try MachO(header) }
        var segment = header + Data(count: 8)
        segment.replaceSubrange(28..<32, with: [1, 0, 0, 0])  // LC_SEGMENT, its fields past the end
        segment.replaceSubrange(32..<36, with: [56, 0, 0, 0])
        #expect(throws: FirmwareError.self) { try MachO(segment) }
    }

    /// A dyld_v1 cache whose mapping and image tables lie past its end.
    @Test func aCacheWithTablesPastItsEndThrows() {
        var cache = Data("dyld_v1   armv7\0".utf8) + Data(count: 16)
        cache.replaceSubrange(0x10..<0x14, with: [0x00, 0x10, 0, 0])  // mappings at 0x1000
        cache.replaceSubrange(0x14..<0x18, with: [3, 0, 0, 0])
        #expect(throws: FirmwareError.self) { try DyldSharedCache(data: cache) }
    }
}
