import Foundation
import Testing

@testable import FirmwareKit

struct IMG3Tests {
    /// ipad1_fw.selfcheck: an odd-length payload through encrypt -> img3 -> decrypt, both tail conventions.
    @Test func partialBlockRoundTrip() throws {
        let iv = Data(count: 16)
        let key = Data(0..<32)
        let plain = Data(0..<37)
        func img3(_ payload: Data) -> Data {
            let le = { (v: Int) in DeviceTree.Value.le([UInt32(v)]) }
            // magics are byte-reversed
            let tag = Data("ATAD".utf8) + le(12 + payload.count) + le(plain.count) + payload
            return Data("3gmI".utf8) + le(0x14 + tag.count) + Data(count: 12) + tag
        }
        // 3.x+: the tail block is encrypted into the tag's padding.
        let padded = try AESCBC.crypt(plain + Data(count: 11), iv: iv, key: key, decrypt: false)
        #expect(try IMG3.decrypt(img3(padded), iv: iv, key: key) == plain)
        // 2.x: whole blocks encrypted, the last 5 bytes left in plaintext.
        let whole = try AESCBC.crypt(plain.prefix(32), iv: iv, key: key, decrypt: false) + plain.suffix(5)
        #expect(try IMG3.decrypt(img3(whole), iv: iv, key: key, plainTail: true) == plain)
        #expect(try IMG3.tags(img3(padded))["DATA"] == IMG3.Tag(magic: "DATA", offset: 0x14, total: 60, dataLength: 37))
        #expect(throws: FirmwareError.self) { try IMG3.tags(Data("nope".utf8)) }
    }

    /// NIST SP 800-38A F.2.1-F.2.6 (CBC-AES128/192/256), both directions.
    @Test(arguments: [
        (
            "2b7e151628aed2a6abf7158809cf4f3c",
            "7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2"
                + "73bed6b8e3c1743b7116e69e222295163ff1caa1681fac09120eca307586e1a7"
        ),
        (
            "8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b",
            "4f021db243bc633d7178183a9fa071e8b4d9ada9ad7dedf4e5e738763f69145a"
                + "571b242012fb7ae07fa9baac3df102e008b0e27988598881d920a9e64f5615cd"
        ),
        (
            "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4",
            "f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d"
                + "39f23369a9d9bacfa530e26304231461b2eb05e2c39be9fcda6c19078c6a9d1b"
        )
    ])
    func aesCBCMatchesNISTVectors(key: String, ciphertext: String) throws {
        let key = try #require(Data(hex: key))
        let cipher = try #require(Data(hex: ciphertext))
        let iv = Data(0..<16)
        let plain = try #require(
            Data(
                hex: "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"
                    + "30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710"
            )
        )
        #expect(try AESCBC.crypt(plain, iv: iv, key: key, decrypt: false) == cipher)
        #expect(try AESCBC.crypt(cipher, iv: iv, key: key) == plain)
    }

    /// Every ipad1_fw.py output but rootfs.dmg (VFDecryptTests), against their recorded digests.
    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: Oracle.firmwares
    )
    func decryptMatchesRecordedDigests(_ fw: Oracle.Firmware) throws {
        guard fw.available else { try FixtureRequirements.missing(fw.ipsw.path) }
        try Oracle.withTemp { dir in
            let r = try Oracle.time("decrypt components \(fw.entryID)") {
                try FirmwareDecryptor.decrypt(ipsw: fw.ipsw, entry: Oracle.entry(fw.entryID), into: dir, rootfs: false)
            }
            #expect(r.plainTail == (fw.entryID == "n72ap-5F138"))
            #expect(Set(r.files) == Set(fw.components.keys))
            for (name, sha) in fw.components {
                #expect(try Oracle.sha256(file: dir.appendingPathComponent(name)) == sha, "\(fw.entryID) \(name)")
            }
        }
    }
}
