// scripts/ship's JSON and appcast checks (`scripts/ltm-build release catalog|amore-id|appcast`).
import CryptoKit
import Foundation

public enum ReleaseHelper {
    /// Per id, one line: "<id> <sha1> <bytes> <url> <mirror url>..." from the firmware catalog's source.
    public static func catalog(_ catalog: URL, ids: [String]) throws -> [String] {
        guard let entries = json(catalog).flatMap({ ($0 as? [String: Any])?["entries"] as? [[String: Any]] }) else {
            throw ToolError("catalog: \(catalog.path) has no entries")
        }
        return try ids.map { id in
            guard let source = entries.first(where: { $0["id"] as? String == id })?["source"] as? [String: Any],
                let sha1 = source["sha1"] as? String, let url = source["url"] as? String
            else { throw ToolError("catalog: no IPSW source for \(id)") }
            let mirrors = (source["mirrors"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
            return ([id, sha1, "\((source["bytes"] as? NSNumber)?.intValue ?? 0)", url] + mirrors)
                .joined(separator: " ")
        }
    }

    /// The Amore release of `build`: "<id> <downloadURL>". `files` are JSON, tried in order: `amore release --format
    /// json`'s output, then the amore CLI's cached API answers (the app's details, whose releases carry the full id
    /// that `amore releases list` truncates); a cached answer counts only for `bundleID`.
    public static func amoreID(build: Int, bundleID: String, files: [URL]) throws -> String {
        for (index, file) in files.enumerated() {
            guard let value = json(file) else { continue }
            // The upload's own answer names no app; a cached answer must be this app's.
            if index > 0, (value as? [String: Any])?["bundleIdentifier"] as? String != bundleID { continue }
            if let found = releases(value, build: build).first {
                return "\(found["id"] ?? "") \(found["downloadURL"] ?? "")"
            }
        }
        throw ToolError("no release of build \(build) in \(files.map(\.path).joined(separator: ", "))")
    }

    /// The appcast's item for `build` carries `notes` as its <description> (Amore renders the Markdown as HTML) and an
    /// edSignature of `dmg` valid for `key` (SUPublicEDKey).
    public static func appcast(_ appcast: URL, build: String, key: String, dmg: URL, notes: URL) throws {
        guard let feed = FileManager.default.contents(atPath: appcast.path), let xml = try? XMLDocument(data: feed)
        else { throw ToolError("appcast: \(appcast.path) is not XML") }
        let items = (try? xml.nodes(forXPath: "//item")) ?? []
        guard
            let item = items.first(where: {
                (try? $0.nodes(forXPath: "*[local-name()='version']").first?.stringValue) == build
            }) as? XMLElement
        else { throw ToolError("appcast: no item for build \(build)") }
        let description = item.elements(forName: "description").first?.stringValue ?? ""
        guard let text = try? String(contentsOf: notes, encoding: .utf8) else {
            throw ToolError("appcast: can't read \(notes.path)")
        }
        // ponytail: compares words, not markup; Markdown Amore renders differently (an autolink, an image) reads as different.
        let have = words(description).joined(separator: " ")
        let want = words(text).joined(separator: " ")
        guard !want.isEmpty, have.contains(want) else {
            throw ToolError("appcast: build \(build)'s <description> is not the notes (\(have.prefix(120))…)")
        }
        guard let enclosure = item.elements(forName: "enclosure").first,
            let signature = enclosure.attributes?.first(where: { $0.localName == "edSignature" })?.stringValue,
            let signatureData = Data(base64Encoded: signature)
        else { throw ToolError("appcast: build \(build) has no edSignature") }
        guard let keyData = Data(base64Encoded: key),
            let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { throw ToolError("appcast: \(key) is not an Ed25519 public key") }
        guard let image = FileManager.default.contents(atPath: dmg.path) else {
            throw ToolError("appcast: can't read \(dmg.path)")
        }
        guard publicKey.isValidSignature(signatureData, for: image) else {
            throw ToolError("appcast: build \(build)'s edSignature does not verify \(dmg.path) with SUPublicEDKey")
        }
    }

    /// A file's JSON, or the JSON after whatever a command printed before it.
    static func json(_ file: URL) -> Any? {
        guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
        if let value = try? JSONSerialization.jsonObject(with: data) { return value }
        guard let start = data.firstIndex(where: { $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "[") }) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data[start...])
    }

    /// Every object under `value` that is the release of `build`.
    static func releases(_ value: Any, build: Int) -> [[String: Any]] {
        if let object = value as? [String: Any] {
            let here = (object["bundleVersion"] as? NSNumber)?.intValue ?? Int(object["bundleVersion"] as? String ?? "")
            let match = here == build && object["id"] is String && object["downloadURL"] is String
            return (match ? [object] : []) + object.values.flatMap { releases($0, build: build) }
        }
        if let array = value as? [Any] { return array.flatMap { releases($0, build: build) } }
        return []
    }

    /// Words, for comparing Markdown with the HTML Amore makes of it: tags, entities' leftovers, punctuation and the
    /// apostrophe's curl drop out, and a Markdown link keeps its text, not its URL (which HTML keeps in a tag).
    static func words(_ text: String) -> [String] {
        text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\]\([^)]*\)"#, with: " ", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
