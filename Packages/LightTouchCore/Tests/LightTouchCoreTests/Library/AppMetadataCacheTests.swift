import Foundation
import Testing

@testable import LightTouchCore

/// The app name/icon cache (AppMetadataCache): an earlier build's index.json is read once and becomes a binary
/// index.plist, which later saves write.
struct AppMetadataCacheTests {
    @Test func jsonIndexBecomesABinaryPlist() throws {
        try withTemporaryDirectory { dir in
            let json = dir.appendingPathComponent("index.json")
            let plist = dir.appendingPathComponent("index.plist")
            try Data(#"{"com.example.app":{"name":"Example","hasIcon":false}}"#.utf8).write(to: json)
            let cache = AppMetadataCache(directory: dir)
            #expect(cache.name(for: "com.example.app") == "Example", "the earlier build's entry is read")
            #expect(!FileManager.default.fileExists(atPath: json.path), "index.json is gone")
            var format = PropertyListSerialization.PropertyListFormat.xml
            let object =
                try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: &format)
                as? [String: [String: Any]]
            #expect(
                format == .binary && object?["com.example.app"]?["name"] as? String == "Example",
                "index.plist holds it, binary"
            )
            cache.forget("com.example.app")
            let after =
                try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
            #expect(after?.isEmpty == true, "saves go to index.plist")
            #expect(AppMetadataCache(directory: dir).name(for: "com.example.app") == nil, "and are read back")
        }
    }
}
