import Foundation
import HostRuntime
import Testing

struct PropertyListFileTests {
    struct Value: Codable, Equatable {
        var name: String
        var count: Int
        var note: String?
    }

    @Test func legacyJSONBecomesThePlistOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = root.appendingPathComponent("index.plist")
        let json = root.appendingPathComponent("index.json")
        #expect(try PropertyListFile.read([String: Value].self, from: plist, legacyJSON: json) == nil)

        try Data(#"{"a":{"name":"A","count":2}}"#.utf8).write(to: json)
        let expected = ["a": Value(name: "A", count: 2)]
        #expect(
            try PropertyListFile.read([String: Value].self, from: plist, legacyJSON: json, format: .binary) == expected
        )
        #expect(!FileManager.default.fileExists(atPath: json.path))
        let bytes = try Data(contentsOf: plist)
        #expect(bytes.starts(with: Data("bplist".utf8)))
        #expect(try PropertyListDecoder().decode([String: Value].self, from: bytes) == expected)

        // A JSON left beside a plist is stale: the plist wins and the JSON goes.
        try Data(#"{"b":{"name":"B","count":3}}"#.utf8).write(to: json)
        #expect(try PropertyListFile.read([String: Value].self, from: plist, legacyJSON: json) == expected)
        #expect(!FileManager.default.fileExists(atPath: json.path))
    }
}
