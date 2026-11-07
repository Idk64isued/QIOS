import FirmwareSchema
import Foundation
import Testing

/// A base the tree would prepare differently is stale (what sessions refuses to boot); one prepared now isn't. Locks
/// are written in firmwarekit's shape from the shipped catalog's rows.
struct PreparationChangesTests {
    static let catalog: [FirmwareWire.Entry] = {
        struct Catalog: Decodable { let entries: [FirmwareWire.Entry] }
        return try! JSONDecoder().decode(Catalog.self, from: Data(contentsOf: Oracle.catalog)).entries
    }()

    /// `id`'s lock as firmwarekit writes it, with `serial` or (nil) none, `created`, and recipe edits.
    static func lock(
        _ id: String,
        serial: Int? = PreparationChanges.serial,
        created: String = "2026-10-20T12:00:00Z",
        recipe: (inout [String: Any]) -> Void = { _ in }
    ) throws -> [String: Any] {
        let row = try #require(catalog.first { $0.id == id })
        var content = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        var r = try #require(content["recipe"] as? [String: Any])
        recipe(&r)
        content["recipe"] = r
        var lock: [String: Any] = [
            "format": 1, "created": created, "board": row.board, "build": row.build,
            "entry": ["id": id, "content": content], "tool": ["name": "firmwarekit", "version": "0.2.0"]
        ]
        if let serial { lock["preparation"] = serial }
        return lock
    }

    static func stale(_ lock: [String: Any]) -> [String] {
        PreparationChanges.verdict(lock: lock, catalog: catalog).stale
    }

    @Test func aBasePreparedNowIsFresh() throws {
        for id in ["n88ap-8B117", "n18ap-7C146", "n90ap-11D257", "n72ap-7E18", "n45ap-4A102", "k48ap-8C148"] {
            #expect(Self.stale(try Self.lock(id)) == [], "\(id)")
            #expect(Self.stale(try Self.lock(id, serial: nil, created: "2026-10-21T00:00:00Z")) == [], "\(id) by date")
        }
    }

    @Test func aChangeAfterTheSerialStalesItsRowsOnly() throws {
        // 2db3a570 (serial 9): the iPhone 3GS's 3.1.x data volume unjournaled
        let journaled = Self.stale(try Self.lock("n88ap-7E18", serial: 8))
        #expect(journaled.count == 1 && journaled.first?.hasPrefix("2db3a570") == true)
        // f3e5c8d8 (serial 12) keeps the 3GS's 4.x BTServer: that one only
        let fourX = Self.stale(try Self.lock("n88ap-8C148", serial: 8))
        #expect(fourX.count == 1 && fourX.first?.hasPrefix("f3e5c8d8") == true, "4.x isn't a 3.1 row")
        #expect(Self.stale(try Self.lock("n18ap-7C146", serial: 8)) == [], "another board")
        // 92e707b4 (serial 13): it_msmquiet in the iPhone 4's 7.x DeviceOMatic job, not its 6.x arbitrator's
        let sevenX = Self.stale(try Self.lock("n90ap-11D257", serial: 12))
        #expect(sevenX.map { String($0.prefix(8)) } == ["92e707b4", "76944f75", "e50c6d02"], "\(sevenX)")
        #expect(Self.stale(try Self.lock("n90ap-10B329", serial: 12)) == [], "6.x isn't a 7 row")
        // 76944f75 (serial 14): the 7.x read-only root's AppSync, from the guest package it was prepared with
        let sevenAppSync = Self.stale(try Self.lock("n90ap-11D257", serial: 13))
        #expect(sevenAppSync.map { String($0.prefix(8)) } == ["76944f75", "e50c6d02"], "\(sevenAppSync)")
        #expect(Self.stale(try Self.lock("n90ap-9B206", serial: 13)) == [], "5.x takes it from the package at boot")
        // 44b92c0b (serial 15): 1.1.3 and later's SystemConfiguration preferences in /private/var/preferences
        let wifi = Self.stale(try Self.lock("n45ap-4A102", serial: 14))
        #expect(wifi.count == 1 && wifi.first?.hasPrefix("44b92c0b") == true, "\(wifi)")
        #expect(Self.stale(try Self.lock("m68ap-1A543a", serial: 14)) == [], "1.0 reads root's home")
        // e50c6d02 (serial 16): the 7.x read-only root's it_prefs, from the guest package it was prepared with
        let sevenPrefs = Self.stale(try Self.lock("n90ap-11D257", serial: 15))
        #expect(sevenPrefs.count == 1 && sevenPrefs.first?.hasPrefix("e50c6d02") == true, "\(sevenPrefs)")
        #expect(Self.stale(try Self.lock("n90ap-9B206", serial: 15)) == [], "5.x takes it from the package at boot")
        // fdfd67a4 (serial 17): 4.0 beta 1's seal boot set Auto-Lock Never where its SpringBoard doesn't read it
        let betaLock = Self.stale(try Self.lock("n88ap-8A230m", serial: 16))
        #expect(betaLock.count == 1 && betaLock.first?.hasPrefix("fdfd67a4") == true, "\(betaLock)")
        #expect(Self.stale(try Self.lock("n88ap-8A248c", serial: 16)) == [], "beta 2's SpringBoard takes it")
        #expect(Self.stale(try Self.lock("n72ap-8A230m", serial: 16)) == [], "the iPod runs it_prefs at first boot")
    }

    /// The 4.1 SpringBoard crash's base: prepared 2026-10-05 08:15, before the seal boots carried the modem.
    @Test func aLockWithoutASerialIsJudgedByItsDate() throws {
        let old = Self.stale(try Self.lock("n88ap-8B117", serial: nil, created: "2026-10-05T08:15:22Z"))
        #expect(old.contains { $0.hasPrefix("8b15001c") })
        #expect(old.contains { $0.hasPrefix("9c810e4e") })
        let since = Self.stale(try Self.lock("n88ap-8B117", serial: nil, created: "2026-10-06T00:00:00Z"))
        #expect(!since.contains { $0.hasPrefix("8b15001c") } && since.contains { $0.hasPrefix("9c810e4e") })
        #expect(Self.stale(try Self.lock("n88ap-8B117", serial: nil, created: "not a date")).count == 5)
    }

    @Test func aRecipeTheCatalogNoLongerHasIsStale() throws {
        let noAppSync = try Self.lock("n88ap-7E18") {
            $0["options"] = ($0["options"] as! [String: Bool]).filter { $0.key != "appsync" }
        }
        #expect(Self.stale(noAppSync) == ["recipe option appsync on in the catalog, off in the base"])
        let derived = try Self.lock("n88ap-7E18") {
            var options = $0["options"] as! [String: Bool]
            options["writable_nor"] = true
            $0["options"] = options
        }
        #expect(Self.stale(derived) == [], "an option the catalog no longer sets is a derivation now")
        #expect(Self.stale(try Self.lock("n88ap-8B117") { $0["version"] = 1 }) == [], "admission migrates n88 1 to 2")
        #expect(Self.stale(try Self.lock("n81ap-8B117") { $0["version"] = 0 }) == ["recipe 0, the catalog's is 1"])
    }

    @Test func aLockWithoutACatalogRowIsStale() throws {
        #expect(!Self.stale(["format": 1, "board": "n45ap"]).isEmpty, "a device.py base")
        var gone = try Self.lock("n88ap-8B117")
        gone["entry"] = ["id": "n88ap-0A000", "content": ["recipe": ["version": 2]]]
        #expect(Self.stale(gone) == ["the catalog has no row n88ap-0A000 any more"])
    }

    @Test func changesAreInSerialAndDateOrder() throws {
        let dates = PreparationChanges.all.map { ISO8601DateFormatter().date(from: $0.landed) }
        #expect(!dates.contains(nil))
        #expect(PreparationChanges.all.map(\.serial) == Array(1...PreparationChanges.serial))
        #expect(dates.compactMap { $0 } == dates.compactMap { $0 }.sorted())
    }
}
