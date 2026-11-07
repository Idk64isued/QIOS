// How a prepared base was made, read back from its device.lock.json: the `firmwarekit create` that prepares it again
// from the tree (sessions reprepare), and where its recipe is not its catalog row's (sessions bases).
import Foundation

nonisolated public enum LockedPreparation {
    /// What `create` makes a base again with: the lock's entry and choices, the tree's catalog row for the rest.
    public struct Plan {
        /// The catalog row now, with `recipe(locked:row:)` as its recipe.
        public var entry: FirmwareWire.Entry
        /// The lock's inputs.ipsw (path and SHA-1).
        public var ipsw: String
        public var ipswSHA1: String?
        /// identity.seed: the same UDID, serial and MACs.
        public var seed: String?
        /// create --language and --keyboards, when the lock records them (inputs.language, inputs.keyboards; a base
        /// prepared before they were recorded, or without them, takes the Mac's again).
        public var language: String?
        public var keyboards: [String]?
        /// The sibling entry's IPSW (inputs.sibling.ipsw), for a recipe with keybag_ramdisk_from.
        public var siblingIPSW: String?
        /// create --hfs (inputs.hfs): the route its volumes were edited through, kept (a base prepared before the lock
        /// recorded it was mounted: kernel).
        public var hfs: HFSRoute
        /// Where the base's recipe is not its row's (`variants`): what preparing it again keeps.
        public var variants: [String]

        /// The recipe's options create's flags name, for the checks that boot the base (sessions single --skip-setup).
        public func option(_ name: String) -> Bool { entry.recipe?.options[name] == true }

        /// `create` writing the base to `out` from `entryFile` (this plan's entry, written there), with the run's own
        /// decrypt cache, guest tools and the sibling row's entry file.
        public func create(
            entryFile: URL,
            out: URL,
            ipsw: URL? = nil,
            cache: URL?,
            guestTools: URL?,
            sibling: (entry: URL, ipsw: URL)? = nil
        ) -> FirmwareCommand.Create {
            FirmwareCommand.Create(
                entry: entryFile,
                ipsw: ipsw ?? URL(fileURLWithPath: self.ipsw),
                out: out,
                seed: seed,
                cache: cache,
                guestTools: guestTools,
                sibling: sibling,
                language: language,
                keyboards: keyboards?.joined(separator: ","),
                hfs: hfs
            )
        }
    }

    public struct Unreadable: Error, CustomStringConvertible {
        public let description: String
    }

    /// `lock`: a base's device.lock.json; `catalog`: the tree's rows.
    public static func plan(lock: [String: Any], catalog: [FirmwareWire.Entry]) throws -> Plan {
        let entry = lock["entry"] as? [String: Any]
        guard let id = entry?["id"] as? String, let content = entry?["content"] as? [String: Any] else {
            throw Unreadable(description: "its lock names no catalog entry: firmwarekit did not prepare it")
        }
        guard var row = catalog.first(where: { $0.id == id }) else {
            throw Unreadable(description: "the catalog has no row \(id) any more")
        }
        let inputs = lock["inputs"] as? [String: Any]
        guard let ipsw = (inputs?["ipsw"] as? [String: Any])?["path"] as? String else {
            throw Unreadable(description: "its lock records no IPSW (inputs.ipsw.path)")
        }
        var variants: [String] = []
        if let rowRecipe = row.recipe, let locked = content["recipe"] {
            let decoded = try JSONDecoder().decode(
                FirmwareWire.Entry.Recipe.self,
                from: JSONSerialization.data(withJSONObject: locked)
            )
            row.recipe = try recipe(locked: decoded, row: rowRecipe)
            variants = try Self.variants(locked: decoded, row: rowRecipe)
        }
        return Plan(
            entry: row,
            ipsw: ipsw,
            ipswSHA1: (inputs?["ipsw"] as? [String: Any])?["sha1"] as? String,
            seed: (lock["identity"] as? [String: Any])?["seed"] as? String,
            language: inputs?["language"] as? String,
            keyboards: inputs?["keyboards"] as? [String],
            siblingIPSW: (inputs?["sibling"] as? [String: Any])?["ipsw"] as? String,
            hfs: (inputs?["hfs"] as? String).flatMap(HFSRoute.init) ?? .kernel,
            variants: variants
        )
    }

    /// The recipe a base is prepared again with: every field the lock records as the lock has it (a variant stays
    /// one: the iPad prepared with kboot, --skip-setup, --jailbreak, --gl-test), except the row's recipe version and
    /// the row's value of each option the row sets (the base having another is stale, not a variant:
    /// PreparationChanges.recipeDifferences); a field the lock doesn't record is the row's.
    public static func recipe(
        locked: FirmwareWire.Entry.Recipe,
        row: FirmwareWire.Entry.Recipe
    ) throws -> FirmwareWire.Entry.Recipe {
        var merged = try object(row)
        for (key, value) in try object(locked) where key != "version" && key != "options" { merged[key] = value }
        var recipe = try JSONDecoder().decode(
            FirmwareWire.Entry.Recipe.self,
            from: JSONSerialization.data(withJSONObject: merged)
        )
        recipe.options = locked.options.merging(row.options) { _, catalog in catalog }
        return recipe
    }

    /// Where a base's recipe is not its row's and preparing it again keeps it (`recipe(locked:row:)`): a field the
    /// row has otherwise or not at all (boot kboot on a row that boots iBoot), an option the row doesn't set.
    public static func variants(locked: FirmwareWire.Entry.Recipe, row: FirmwareWire.Entry.Recipe) throws -> [String] {
        let mine = try object(locked)
        let theirs = try object(row)
        func text(_ value: Any?) -> String {
            guard let value else { return "none" }
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
                return "\(value)"
            }
            return String(decoding: data, as: UTF8.self)
        }
        var out: [String] = []
        for key in mine.keys.sorted() where key != "version" && key != "options" {
            if text(mine[key]) != text(theirs[key]) {
                out.append("recipe \(key) \(text(mine[key])) (the catalog row's: \(text(theirs[key])))")
            }
        }
        for (key, value) in locked.options.sorted(by: { $0.key < $1.key }) where row.options[key] == nil {
            out.append("recipe option \(key) \(value ? "on" : "off") (the catalog row doesn't set it)")
        }
        return out
    }

    private static func object(_ recipe: FirmwareWire.Entry.Recipe) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try JSONSerialization.jsonObject(with: encoder.encode(recipe)) as? [String: Any] ?? [:]
    }
}
