import Foundation

/// An app-owned Codable file kept as a property list, converted once from the JSON file earlier builds kept
/// (DeviceRecord's device.json → device.plist, for any record).
public nonisolated enum PropertyListFile {
    /// `plist` decoded, or nil when there is none. Where only `legacyJSON` exists, it is decoded as JSON, written
    /// to `plist` (atomic) and removed; with both, the JSON is a leftover and goes.
    public static func read<T: Codable>(
        _ type: T.Type,
        from plist: URL,
        legacyJSON json: URL,
        format: PropertyListSerialization.PropertyListFormat = .xml
    ) throws -> T? {
        let fm = FileManager.default
        if fm.fileExists(atPath: plist.path) {
            try? fm.removeItem(at: json)
            return try PropertyListDecoder().decode(type, from: Data(contentsOf: plist))
        }
        guard fm.fileExists(atPath: json.path) else { return nil }
        let value = try JSONDecoder().decode(type, from: Data(contentsOf: json))
        try write(value, to: plist, format: format)
        try? fm.removeItem(at: json)
        return value
    }

    public static func data<T: Encodable>(_ value: T, format: PropertyListSerialization.PropertyListFormat = .xml)
        throws -> Data
    {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = format
        return try encoder.encode(value)
    }

    public static func write<T: Encodable>(
        _ value: T,
        to url: URL,
        format: PropertyListSerialization.PropertyListFormat = .xml
    ) throws {
        try data(value, format: format).write(to: url, options: .atomic)
    }
}
