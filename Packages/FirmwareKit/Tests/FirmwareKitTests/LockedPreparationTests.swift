import FirmwareSchema
import Foundation
import Testing

/// sessions reprepare prepares a base again as its lock says it was prepared: nothing the lock records is dropped, and
/// the catalog row stands in only where the lock is silent or the base is stale.
struct LockedPreparationTests {
    static func row(_ id: String) throws -> FirmwareWire.Entry {
        try #require(PreparationChangesTests.catalog.first { $0.id == id })
    }

    /// The kboot iPad of k48-a4ref, prepared with every choice create takes.
    static func variantLock() throws -> [String: Any] {
        var lock = try PreparationChangesTests.lock("k48ap-8C148") {
            $0["boot"] = "kboot"
            $0["version"] = 0
            var options = $0["options"] as! [String: Bool]
            options["skip_setup"] = true
            options["jailbreak"] = true
            options["gl_test"] = true
            options["writable_nor"] = false
            options["ca_ogl"] = false  // the row turns it on: a base with it off is stale, not a variant
            $0["options"] = options
        }
        lock["identity"] = ["seed": "ipad1-8C148-default", "udid": "x"]
        lock["inputs"] = [
            "ipsw": ["path": "/ipsw/iPad1,1_4.2.1_8C148_Restore.ipsw", "sha1": "8717b3be"],
            "language": "fr-FR", "keyboards": ["com.apple.keylayout.French", "com.apple.keylayout.US"],
            "sibling": ["entry": "k48ap-8F190", "ipsw": "/ipsw/sibling.ipsw"], "hfs": "writer"
        ]
        return lock
    }

    @Test func everythingTheLockRecordsIsPreparedAgain() throws {
        let lock = try Self.variantLock()
        let plan = try LockedPreparation.plan(lock: lock, catalog: PreparationChangesTests.catalog)
        let row = try Self.row("k48ap-8C148")
        let recipe = try #require(plan.entry.recipe)
        #expect(plan.entry.id == "k48ap-8C148" && plan.entry.keys == row.keys, "the row now, but for its recipe")
        #expect(recipe.boot == "kboot", "the boot path the base was prepared with, not the row's iBoot")
        #expect(recipe.version == row.recipe?.version)
        let locked = ((lock["entry"] as! [String: Any])["content"] as! [String: Any])["recipe"] as! [String: Any]
        for (key, value) in locked["options"] as! [String: Bool] {
            let want = row.recipe?.options[key] ?? value
            #expect(recipe.options[key] == want, "option \(key): \(String(describing: recipe.options[key]))")
        }
        #expect(recipe.options["ca_ogl"] == true && recipe.options["skip_setup"] == true)
        #expect(plan.option("skip_setup") && plan.option("jailbreak") && plan.option("gl_test"))
        let url = URL(fileURLWithPath: "/w")
        let arguments = plan.create(
            entryFile: url.appendingPathComponent("entry.json"),
            out: url.appendingPathComponent("new"),
            cache: nil,
            guestTools: nil,
            sibling: (url.appendingPathComponent("sibling.json"), URL(fileURLWithPath: plan.siblingIPSW ?? "-"))
        ).arguments
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: "--\(name)").map { arguments[$0 + 1] }
        }
        #expect(value("ipsw") == "/ipsw/iPad1,1_4.2.1_8C148_Restore.ipsw")
        #expect(value("seed") == "ipad1-8C148-default")
        #expect(value("language") == "fr-FR")
        #expect(value("keyboards") == "com.apple.keylayout.French,com.apple.keylayout.US")
        #expect(value("sibling-ipsw") == "/ipsw/sibling.ipsw")
        #expect(value("hfs") == "writer", "the route its volumes were edited through")
        #expect(value("entry") == "/w/entry.json" && value("catalog") == nil, "the recipe as prepared, not the row's")
    }

    @Test func whatTheLockDoesNotRecordIsTheRows() throws {
        // A lock written before a field: the 3GS row's kboot and its keybag sibling.
        let lock = try PreparationChangesTests.lock("n88ap-8B117") {
            $0.removeValue(forKey: "boot")
            $0.removeValue(forKey: "keybag_ramdisk_from")
        }
        let plan = try LockedPreparation.plan(
            lock: lock.merging(["inputs": ["ipsw": ["path": "/i.ipsw"]]]) { $1 },
            catalog: PreparationChangesTests.catalog
        )
        #expect(plan.entry.recipe == (try Self.row("n88ap-8B117")).recipe)
        #expect(plan.variants == [] && plan.seed == nil && plan.language == nil && plan.keyboards == nil)
        #expect(plan.hfs == .kernel, "a lock from before the route was recorded: mounted")
    }

    @Test func variantsAreWhereTheBaseIsNotItsRow() throws {
        let plan = try LockedPreparation.plan(lock: try Self.variantLock(), catalog: PreparationChangesTests.catalog)
        #expect(
            plan.variants == [
                #"recipe boot "kboot" (the catalog row's: none)"#,
                "recipe option gl_test on (the catalog row doesn't set it)",
                "recipe option jailbreak on (the catalog row doesn't set it)",
                "recipe option skip_setup on (the catalog row doesn't set it)",
                "recipe option writable_nor off (the catalog row doesn't set it)"
            ],
            "\(plan.variants)"
        )
    }

    /// A create option added later is either recorded in the lock and read back by LockedPreparation, or the run's own.
    @Test func everyCreateOptionIsRecordedOrTheRunsOwn() {
        let labels = Set(Mirror(reflecting: FirmwareCommand.Create()).children.compactMap(\.label))
        let recorded: Set = [
            "_entry", "_ipsw", "_seed", "_language", "_keyboards", "_siblingEntry", "_siblingIpsw", "_glTest",
            "_skipSetup", "_jailbreak", "_hfs"
        ]
        let runsOwn: Set = ["_catalog", "_id", "_out", "_helper", "_cache", "_guestTools", "_stopAfter"]
        #expect(labels == recorded.union(runsOwn), "\(labels.subtracting(recorded.union(runsOwn)).sorted())")
    }
}
