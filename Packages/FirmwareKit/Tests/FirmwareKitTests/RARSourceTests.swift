import FirmwareSchema
import Foundation
import Testing

@testable import FirmwareKit

/// RARSource.unwrap on a 107-byte RAR 5 archive (Unrar.swift's own test fixture test.rar, MIT) holding README.md.
struct RARSourceTests {
    static let rar = Data(
        base64Encoded:
            "UmFyIRoHAQAzkrXlCgEFBgAFAQGAgAD3EqflHwICqAAGqACkgwIWO/FfV7UGeoAAAQlSRUFETUUubWQjIFVucmFyCgpBIGRlc2NyaXB0aW9uIG9mIHRoaXMgcGFja2FnZS4KHXdWUQMFBAA="
    )!
    static let member = Data("# Unrar\n\nA description of this package.\n".utf8)

    static func source(
        archiveSHA1: String = "20f6a2cd45fd0bc4500c91190043e4f48b14ded9",
        member: String = "README.md",
        sha1: String = "71385759376d8d39d3009b7996c487889e8dbc88"
    ) -> FirmwareWire.Entry.Source {
        try! JSONDecoder().decode(
            FirmwareWire.Entry.Source.self,
            from: Data(
                """
                {"kind": "rar", "url": "https://example.invalid/media_ipsw.rar", "archive_sha1": "\(archiveSHA1)",
                 "archive_bytes": 107, "member": "\(member)", "sha1": "\(sha1)", "bytes": 40}
                """.utf8
            )
        )
    }

    /// The archive in a fresh directory, and where its IPSW goes.
    static func files() throws -> (archive: URL, out: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rarsource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try rar.write(to: dir.appendingPathComponent("media_ipsw.rar"))
        return (dir.appendingPathComponent("media_ipsw.rar"), dir.appendingPathComponent("out.ipsw"))
    }

    /// Nothing but the archive is left beside it: no IPSW, no partial extraction.
    static func untouched(_ archive: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: archive.deletingLastPathComponent().path) == [
            "media_ipsw.rar"
        ]
    }

    @Test func extractsTheCheckedMember() throws {
        let (archive, out) = try Self.files()
        let source = Self.source()
        #expect(source.isArchive && source.downloadSHA1 == source.archiveSHA1 && source.downloadBytes == 107)
        try RARSource.unwrap(archive, source: source, to: out)
        #expect(try Data(contentsOf: out) == Self.member)
    }

    @Test func refusesAnotherArchive() throws {
        let (archive, out) = try Self.files()
        #expect(throws: FirmwareError.self) {
            try RARSource.unwrap(archive, source: Self.source(archiveSHA1: String(repeating: "0", count: 40)), to: out)
        }
        #expect(try Self.untouched(archive))
    }

    @Test func refusesAMissingMember() throws {
        let (archive, out) = try Self.files()
        #expect(throws: FirmwareError.self) {
            try RARSource.unwrap(archive, source: Self.source(member: "iPod4,1_6.0_10A5316k_Restore.ipsw"), to: out)
        }
        #expect(try Self.untouched(archive))
    }

    @Test func refusesAnotherIPSW() throws {
        let (archive, out) = try Self.files()
        #expect(throws: FirmwareError.self) {
            try RARSource.unwrap(archive, source: Self.source(sha1: String(repeating: "1", count: 40)), to: out)
        }
        #expect(try Self.untouched(archive))
    }

    /// An "ipsw" source downloads and checks the IPSW itself.
    @Test func plainSourceIsTheIPSW() throws {
        let plain = try JSONDecoder().decode(
            FirmwareWire.Entry.Source.self,
            from: Data(#"{"kind": "ipsw", "sha1": "ab", "bytes": 3}"#.utf8)
        )
        #expect(!plain.isArchive && plain.downloadSHA1 == "ab" && plain.downloadBytes == 3)
    }
}
