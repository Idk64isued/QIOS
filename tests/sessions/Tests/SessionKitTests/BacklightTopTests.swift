import Foundation
import Testing

@testable import SessionKit

/// The A4 boards' 100% backlight: the device tree's backlight-table where the kboot has one (6.x+), else 0x7b3 for
/// the iPhone 4's backlight-id 5 (AppleARMBacklight's backlight-5 table) and the full 11 bits for any other.
struct BacklightTopTests {
    static func prop(_ name: String, _ value: [UInt8]) -> Data {
        Data(name.utf8) + Data(count: 32 - name.utf8.count) + Data([UInt8(value.count), 0, 0, 0]) + Data(value)
    }
    static func top(_ kboot: Data, _ version: String = "4.2.1") throws -> Int? {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try (Data(count: 64) + kboot + Data(count: 64)).write(to: base.appendingPathComponent("kboot.bin"))
        return SessionJudge.backlightTop(board: "n90ap", base: base, productVersion: version)
    }

    @Test func followsTheBoardsTable() throws {
        #expect(try Self.top(Self.prop("backlight-id", [5, 0, 0, 0])) == 0x7b3)
        #expect(try Self.top(Self.prop("backlight-id", [0xff, 0xff, 0xff, 0xff])) == 0x7ff)
        #expect(try Self.top(Data()) == 0x7ff)
        let table = Self.prop("backlight-table", [0x10, 0, 0xb3, 0x07]) + Self.prop("backlight-id", [5, 0, 0, 0])
        #expect(try Self.top(table, "7.1.2") == 0x7b3)
    }
}
