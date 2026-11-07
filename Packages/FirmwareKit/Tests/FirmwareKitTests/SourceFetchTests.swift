import FirmwareSchema
import Foundation
import Testing

@testable import FirmwareKit

/// SourceFetch walks the source, then its mirrors: a dead primary, then a mirror with other bytes, then a RAR mirror
/// (RARSourceTests' archive, whose member stands in for the IPSW) that serves it.
struct SourceFetchTests {
    static let ipsw = RARSourceTests.member  // 40 bytes, sha1 71385759…
    static let source = try! JSONDecoder().decode(
        FirmwareWire.Entry.Source.self,
        from: Data(
            """
            {"kind": "ipsw", "url": "https://primary.invalid/a.ipsw", "sha1": "71385759376d8d39d3009b7996c487889e8dbc88", "bytes": 40,
             "mirrors": [
              {"url": "https://bad.invalid/a.ipsw", "sha1": "71385759376d8d39d3009b7996c487889e8dbc88", "bytes": 40},
              {"url": "https://rar.invalid/media_ipsw.rar", "sha1": "71385759376d8d39d3009b7996c487889e8dbc88", "bytes": 40,
               "kind": "rar", "archive_sha1": "20f6a2cd45fd0bc4500c91190043e4f48b14ded9", "archive_bytes": 107, "member": "README.md"},
              {"url": "https://last.invalid/a.ipsw", "sha1": "71385759376d8d39d3009b7996c487889e8dbc88", "bytes": 40},
              {"url": "https://other.invalid/a.ipsw", "sha1": "0000000000000000000000000000000000000000", "bytes": 40}]}
            """.utf8
        )
    )

    static func out() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sourcefetch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("out.ipsw")
    }

    /// Serves: primary 404, bad mirror 40 wrong bytes, the RAR, the plain last mirror.
    static func serve(_ url: URL, _ file: URL) throws {
        switch url.host {
        case "primary.invalid": throw FirmwareError(.internal, "HTTP 404")
        case "bad.invalid": try Data(repeating: 0x41, count: 40).write(to: file)
        case "rar.invalid": try RARSourceTests.rar.write(to: file)
        default: try ipsw.write(to: file)
        }
    }

    @Test func walksToTheRARMirror() throws {
        let out = try Self.out()
        var log: [String] = []
        let from = try SourceFetch.fetch(Self.source, to: out, download: Self.serve) { log.append($0) }
        #expect(from.host == "rar.invalid")
        #expect(try Data(contentsOf: out) == Self.ipsw)
        #expect(log.contains { $0.hasPrefix("https://primary.invalid/a.ipsw failed") })
        #expect(log.contains { $0.hasPrefix("https://bad.invalid/a.ipsw failed") && $0.contains("SHA-1") })
        #expect(log.last == "served by https://rar.invalid/media_ipsw.rar")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: out.deletingLastPathComponent().path) == ["out.ipsw"]
        )
    }

    /// The app checks a finished download as the alternative it came from (FirmwareJobs' install).
    @Test func alternativeForTheServingURL() {
        let rar = Self.source.alternative(for: URL(string: "https://rar.invalid/media_ipsw.rar"))
        #expect(
            rar.isArchive && rar.member == "README.md" && rar.downloadSHA1 == "20f6a2cd45fd0bc4500c91190043e4f48b14ded9"
                && rar.sha1 == Self.source.sha1
        )
        #expect(!Self.source.alternative(for: URL(string: "https://bad.invalid/a.ipsw")).isArchive)
        #expect(Self.source.alternative(for: nil) == Self.source)
    }

    /// A mirror that records another IPSW is never tried; every failure leaves nothing at `out`.
    @Test func failsWithNothingLeft() throws {
        let out = try Self.out()
        var tried: [String] = []
        #expect(Self.source.alternatives.count == 4)
        #expect(throws: (any Error).self) {
            try SourceFetch.fetch(
                Self.source,
                to: out,
                download: { url, _ in
                    tried.append(url.host!)
                    throw FirmwareError(.internal, "HTTP 503")
                }
            )
        }
        #expect(tried == ["primary.invalid", "bad.invalid", "rar.invalid", "last.invalid"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.deletingLastPathComponent().path).isEmpty)
    }
}
