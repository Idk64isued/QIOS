import Crypto
import Foundation
import Testing

@testable import FirmwareKit

@Suite(.serialized) struct UDIFTests {
    @Test func apmSlice() throws {
        var map = Data("ER".utf8) + Data([0x02, 0x00]) + Data(count: 508)  // block size 512
        func entry(_ type: String, start: UInt32, count: UInt32, total: UInt32) -> Data {
            let be = { (v: UInt32) in
                Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
            }
            var e = Data("PM".utf8) + Data(count: 2) + be(total) + be(start) + be(count) + Data(count: 32)
            e += Data(type.utf8) + Data(count: 32 - type.utf8.count)
            return e + Data(count: 512 - e.count)
        }
        map += entry("Apple_partition_map", start: 1, count: 63, total: 2)
        map += entry("Apple_HFSX", start: 64, count: 1000, total: 2)
        #expect(try APM.hfsSlice(map) == (64 * 512, 1000 * 512))
        #expect(throws: FirmwareError.self) { try APM.hfsSlice(Data("xx".utf8) + map.dropFirst(2)) }
    }

    /// The raw HFS volume against the recorded digest of ipad1_rootfs.extract_rootfs's. Input: the decrypt cache's
    /// rootfs.dmg (read only) when there is one, else our own vfdecrypt of the IPSW.
    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: Oracle.firmwares
    )
    func rawVolumeMatchesRecordedDigest(_ fw: Oracle.Firmware) async throws {
        guard fw.available else { try FixtureRequirements.missing(fw.ipsw.path) }
        try await Oracle.withTemp { dir in
            var dmg = fw.cache?.appendingPathComponent("rootfs.dmg")
            if dmg == nil || !Oracle.exists(dmg!) {
                let ipsw = IPSWArchive(fw.ipsw)
                let os = try BuildComponents.load(ipsw, board: Oracle.entry(fw.entryID).board)["OS"]!
                let key = try #require(Data(hex: Oracle.entry(fw.entryID).key(forPath: os).key))
                dmg = dir.appendingPathComponent("rootfs.dmg")
                try ipsw.stream(os) { try VFDecrypt.decrypt(from: $0.fileDescriptor, output: dmg!, key: key) }
            }
            let raw = dir.appendingPathComponent("rootfs.hfs")
            try await Oracle.time("UDIF convert + APM slice \(fw.entryID)") {
                try await UDIF.extractRootfs(dmg: dmg!, to: raw)
            }
            #expect(try Oracle.sha256(file: raw) == fw.rawVolume)
        }
    }
}

/// UDIFReader against hdiutil convert -format UDTO (the oracle; test only), byte for byte over every partition
/// but the free-space ones, which hdiutil fills from whatever its buffer last held (the same bytes every run).
@Suite(.serialized) struct UDIFReaderTests {
    /// SHA-256 of `raw` over the sectors of every blkx entry of `dmg` not named Apple_Free.
    static func digest(_ raw: URL, _ dmg: URL) throws -> String {
        let d = try Data(contentsOf: dmg)
        let koly = [UInt8](d.suffix(512))
        let xmlAt = Int(try be64(koly, 0xD8))
        let xml = d[xmlAt..<xmlAt + Int(try be64(koly, 0xE0))]
        let plist = try PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any]
        let blkx = (plist?["resource-fork"] as? [String: Any])?["blkx"] as? [[String: Any]] ?? []
        let r = try Data(contentsOf: raw)
        var h = SHA256()
        for b in blkx where !((b["Name"] as? String) ?? "").contains("Apple_Free") {
            let m = [UInt8](b["Data"] as? Data ?? Data())
            let first = Int(try be64(m, 8)) * 512
            h.update(data: r[first..<first + Int(try be64(m, 16)) * 512])
        }
        #expect(blkx.count > 1)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// zlib (UDZO), ADC (UDCO) and raw (UDRO) block tables, each with zero-fill runs.
    @Test(arguments: ["UDZO", "UDCO", "UDRO"]) func matchesHdiutil(_ format: String) async throws {
        try await Oracle.withTemp { dir in
            let src = dir.appendingPathComponent("src")
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            var rng = SystemRandomNumberGenerator()
            try Data((0..<3_000_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
                .write(to: src.appendingPathComponent("noise"))
            try Data(String(repeating: "hello\n", count: 300_000).utf8).write(to: src.appendingPathComponent("text"))
            let dmg = dir.appendingPathComponent("t.dmg")
            try await DiskImage.run([
                "/usr/bin/hdiutil", "create", "-quiet", "-srcfolder", src.path, "-fs", "HFS+", "-volname", "T",
                "-format", format, dmg.path
            ])
            let ours = dir.appendingPathComponent("ours")
            try UDIFReader.convertToRaw(dmg, to: ours)
            let theirs = dir.appendingPathComponent("theirs")
            try await DiskImage.convertToRaw(dmg, to: theirs, backend: .hdiutil)
            #expect(try Self.digest(ours, dmg) == Self.digest(theirs, dmg))
        }
    }

    /// A decrypted IPSW root filesystem (n72ap 7E18, from the local decrypt cache): the volume UDIF.extractRootfs
    /// takes out through UDIFReader is the one recorded from hdiutil's conversion.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func rootFilesystemMatchesTheRecordedVolume() async throws {
        let fw = Oracle.firmware("n72ap-7E18")
        let dmg = try #require(fw.cache).appendingPathComponent("rootfs.dmg")
        guard Oracle.exists(dmg) else { try FixtureRequirements.missing(dmg.path) }
        try await Oracle.withTemp { dir in
            let ours = dir.appendingPathComponent("ours")
            try await UDIF.extractRootfs(dmg: dmg, to: ours, backend: .writer)
            #expect(try Oracle.sha256(file: ours) == fw.rawVolume)
        }
    }
}
