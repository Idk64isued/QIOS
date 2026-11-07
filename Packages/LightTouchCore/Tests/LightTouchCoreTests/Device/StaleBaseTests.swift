import FirmwareSchema
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// A device whose base an older recipe made is flagged for Prepare Again; current bases and other boards' aren't.
/// Locks are written in the shape firmwarekit writes (entry.content is the catalog entry the base came from) against
/// the shipped catalog. The RC7 cases pin the shipped recipes: a later bump flags every existing device, so it must
/// change them knowingly. N72 recipe-1 bases are not flagged because boot admission migrates n72 1 -> 2 in place
/// (FirmwareWire.admissionRecipeSteps); an N72 lock below every declared step (recipe 0) still is.
struct StaleBaseTests {
    // nonisolated(unsafe): an immutable fixture read from the shipped catalog once.
    nonisolated(unsafe) static let raw: [String: [String: Any]] = {
        let json =
            try! JSONSerialization.jsonObject(with: Data(contentsOf: LibraryFixtures.shippedCatalog)) as! [String: Any]
        return Dictionary(uniqueKeysWithValues: (json["entries"] as! [[String: Any]]).map { ($0["id"] as! String, $0) })
    }()
    static let catalog = try! FirmwareCatalog.load(from: LibraryFixtures.shippedCatalog)

    nonisolated enum Lock: Sendable, CustomStringConvertible {
        case firmwarekit(String, recipe: Int?, tool: String)
        case raw(String)
        var description: String {
            switch self {
            case .firmwarekit(let id, let r, let t): "\(id) recipe \(r.map(String.init) ?? "-") tool \(t)"
            case .raw(let s): s
            }
        }
        var data: Data {
            switch self {
            case .raw(let text): return Data(text.utf8)
            case .firmwarekit(let id, let recipe, let tool):
                var content = StaleBaseTests.raw[id]!
                if let recipe {
                    var r = content["recipe"] as! [String: Any]
                    r["version"] = recipe
                    content["recipe"] = r
                }
                return try! JSONSerialization.data(withJSONObject: [
                    "format": 1, "board": content["board"]!, "build": content["build"]!,
                    "tool": ["name": "firmwarekit", "version": tool],
                    "entry": ["id": id, "sha256": String(repeating: "0", count: 64), "content": content]
                ])
            }
        }
    }
    nonisolated static func lock(_ id: String, recipe: Int? = nil, tool: String = "0.2.0") -> Lock {
        .firmwarekit(id, recipe: recipe, tool: tool)
    }

    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        let name: String, entry: String, lock: Lock, flagged: Bool
        var marker: [String: Sendable]? = nil
        var testDescription: String { name }
    }
    nonisolated static let migrated: [String: Sendable] = ["recipe": 2, "step": "n72-exact-gpt"]
    nonisolated static let cases: [Case] = [
        .init(name: "n45-old", entry: "n45ap-4B1", lock: lock("n45ap-4B1", recipe: 1), flagged: true),
        .init(name: "n45-old-3A101a", entry: "n45ap-3A101a", lock: lock("n45ap-3A101a", recipe: 1), flagged: true),
        .init(name: "n45-current", entry: "n45ap-4B1", lock: lock("n45ap-4B1"), flagged: false),
        .init(name: "n45-rc7", entry: "n45ap-3A101a", lock: lock("n45ap-3A101a", recipe: 2), flagged: false),
        .init(
            name: "n72-rc7-unmigrated-2x",
            entry: "n72ap-5F138",
            lock: lock("n72ap-5F138", recipe: 1),
            flagged: false
        ),
        .init(name: "n72-rc7-unmigrated-3x", entry: "n72ap-7E18", lock: lock("n72ap-7E18", recipe: 1), flagged: false),
        .init(
            name: "n72-rc7-unmigrated-4x",
            entry: "n72ap-8C148",
            lock: lock("n72ap-8C148", recipe: 1),
            flagged: false
        ),
        .init(
            name: "n72-below-admission-steps",
            entry: "n72ap-7E18",
            lock: lock("n72ap-7E18", recipe: 0),
            flagged: true
        ),
        .init(name: "n72-current", entry: "n72ap-7E18", lock: lock("n72ap-7E18"), flagged: false),
        .init(name: "n72-exact-gpt", entry: "n72ap-8C148", lock: lock("n72ap-8C148", recipe: 2), flagged: false),
        .init(
            name: "n72-current-old-tool-field",
            entry: "n72ap-7E18",
            lock: lock("n72ap-7E18", tool: "0.1.0"),
            flagged: false
        ),
        .init(
            name: "n72-rc7-migrated-2x",
            entry: "n72ap-5F138",
            lock: lock("n72ap-5F138", recipe: 1),
            flagged: false,
            marker: migrated
        ),
        .init(
            name: "n72-rc7-migrated-3x",
            entry: "n72ap-7E18",
            lock: lock("n72ap-7E18", recipe: 1),
            flagged: false,
            marker: migrated
        ),
        .init(
            name: "n72-rc7-migrated-4x",
            entry: "n72ap-8C148",
            lock: lock("n72ap-8C148", recipe: 1),
            flagged: false,
            marker: migrated
        ),
        .init(
            name: "n72-rc7-marker-recipe-1",
            entry: "n72ap-7E18",
            lock: lock("n72ap-7E18", recipe: 1),
            flagged: false,
            marker: ["recipe": 1]
        ),
        .init(name: "k48-rc4", entry: "k48ap-7B500", lock: lock("k48ap-7B500", tool: "0.1.0"), flagged: false),
        .init(name: "k48-rc5", entry: "k48ap-8C148", lock: lock("k48ap-8C148"), flagged: false),
        .init(name: "k48-rc7", entry: "k48ap-7B500", lock: lock("k48ap-7B500", recipe: 1), flagged: false),
        .init(
            name: "device-py",
            entry: "n45ap-4B1",
            lock: .raw(#"{"format": 1, "board": "n45ap", "activation_hook": null}"#),
            flagged: false
        ),
        .init(name: "unreadable", entry: "n45ap-4B1", lock: .raw("not json"), flagged: false)
    ]

    @Test func shippedRecipesAreTheFixedOnes() {
        #expect(
            (Self.raw["n45ap-4B1"]!["recipe"] as! [String: Any])["version"] as! Int > 1,
            "the N45 entries require the fixed recipe"
        )
        for (id, e) in Self.raw where e["board"] as? String == "n72ap" {
            #expect(
                (e["recipe"] as! [String: Any])["version"] as! Int > 1,
                "\(id): N72 recipes mark the corrected partition geometry"
            )
        }
    }

    @Test(arguments: cases)
    func onlyBasesOlderThanTheirRecipeAreFlagged(_ c: Case) throws {
        try withTemporaryDirectory { tmp in
            let lockURL = tmp.appendingPathComponent("device.lock.json")
            let device = tmp.appendingPathComponent("device")
            try c.lock.data.write(to: lockURL)
            try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
            if let marker = c.marker {
                try JSONSerialization.data(withJSONObject: marker).write(
                    to: device.appendingPathComponent("migrated-recipe.json")
                )
            }
            let entry = try #require(Self.catalog.entry(id: c.entry))
            let row = DeviceRow(
                entry: entry,
                instanceID: UUID(),
                session: nil,
                job: nil,
                baseRecipe: DeviceRow.baseRecipeVersion(lockURL, device: device)
            )
            #expect(row.preparedByOlderRecipe == c.flagged)
            #expect(row.allows(.prepareAgain, canDownload: true) == c.flagged)
            #expect(
                row.olderRecipeNote == (c.flagged ? "This iPod was prepared by an older version of Light Touch." : nil)
            )
            #expect(row.primaryAction == .start, "Start stays the placeholder's button")
            guard c.flagged else { return }
            #expect(!row.allows(.prepareAgain, canDownload: false), "Prepare Again without the preparer")
            #expect(
                !DeviceRow(entry: entry, instanceID: UUID(), session: .running, job: nil, baseRecipe: 1)
                    .allows(.prepareAgain, canDownload: true),
                "Prepare Again while running"
            )
            for session in [SessionPhase.stopped, .dead("This iPod’s data was made with an older system image.")] {
                #expect(
                    DeviceRow(entry: entry, instanceID: UUID(), session: session, job: nil, baseRecipe: 1)
                        .allows(.prepareAgain, canDownload: true),
                    "Prepare Again once \(session), without quitting (state audit B-4)"
                )
            }
            #expect(
                !DeviceRow(entry: entry, instanceID: nil, session: nil, job: nil, baseRecipe: 1).preparedByOlderRecipe,
                "flagged with no device"
            )
        }
    }

    /// The row's lock facts are read once per base, not once per device (state audit A-18): a new storage generation
    /// (another base path) says what its own lock says, and `forget` (a boot that admitted another generation) reads
    /// the lock again. Activation used to be cached by device id for the life of the app.
    @Test @MainActor func lockFactsFollowTheBase() throws {
        try withTemporaryDirectory { tmp in
            let device = tmp.appendingPathComponent("device")
            let old = tmp.appendingPathComponent("base-1")
            let new = tmp.appendingPathComponent("base-2")
            for base in [old, new] {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            }
            func write(_ base: URL, activated: Bool) throws {
                let activation = activated ? #"{"input_sha256": "a", "output_sha256": "b"}"# : "null"
                try Data(#"{"inputs": {"ipsw": {}, "activation": \#(activation)}}"#.utf8)
                    .write(to: base.appendingPathComponent(DeviceLock.fileName))
            }
            try write(old, activated: false)
            try write(new, activated: true)
            let facts = BaseLockFacts()
            #expect(facts.facts(base: old, device: device).lacksActivation)
            #expect(!facts.facts(base: new, device: device).lacksActivation, "the new generation's own lock")
            try write(old, activated: true)
            #expect(facts.facts(base: old, device: device).lacksActivation, "read once per base")
            facts.forget()
            #expect(!facts.facts(base: old, device: device).lacksActivation, "read again after forget")
        }
    }
}
