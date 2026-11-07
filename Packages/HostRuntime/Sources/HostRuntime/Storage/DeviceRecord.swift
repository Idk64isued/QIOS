import Foundation

/// A device's record, Devices/<uuid>/device.plist (an XML property list). Records made before it were
/// device.json; the first read of such a device converts it once (`migrate`) and removes the JSON.
public nonisolated enum DeviceRecord {
    public static let name = "device.plist"
    public static let legacyName = "device.json"

    /// The newest record `format` this build can boot. A record without one is format 1 (page overlays); 2 is an image
    /// store (FirmwareKit K48NANDMigration).
    public static let currentFormat = imageFormat
    /// The format of a device whose NAND is an image store (the A4 and S5L8920 boards, the iPod touch 2G, the 1.x
    /// boards).
    public static let imageFormat = 2

    public struct NewerFormat: LocalizedError {
        public init() {}
        public var errorDescription: String? { "This device was made by a newer version of Light Touch." }
    }

    /// A record a newer build wrote may name storage this build would misread: it is listed, never booted or
    /// rewritten.
    public static func requireReadable(_ object: [String: Any]) throws {
        guard (object["format"] as? Int ?? 1) <= currentFormat else { throw NewerFormat() }
    }

    /// The record of `device`, converted from device.json first when that is all it has.
    public static func url(_ device: URL) -> URL {
        _ = try? migrate(device)
        return device.appendingPathComponent(name)
    }

    public static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return object
    }

    public static func data(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    /// device.json → device.plist: JSON nulls dropped (a plist has none), `created` (ISO 8601) a date. Atomic; the
    /// JSON goes only once the plist is in place. False when there is nothing to convert.
    @discardableResult public static func migrate(_ device: URL) throws -> Bool {
        let json = device.appendingPathComponent(legacyName)
        let plist = device.appendingPathComponent(name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: json.path) else { return false }
        if fm.fileExists(atPath: plist.path) {
            try? fm.removeItem(at: json)
            return false
        }
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        object = object.compactMapValues(withoutNulls)
        if let created = object["created"] as? String, let date = ISO8601DateFormatter().date(from: created) {
            object["created"] = date
        }
        try data(object).write(to: plist, options: .atomic)
        try? fm.removeItem(at: json)
        return true
    }

    private static func withoutNulls(_ value: Any) -> Any? {
        switch value {
        case is NSNull: nil
        case let dictionary as [String: Any]: dictionary.compactMapValues(withoutNulls)
        case let array as [Any]: array.compactMap(withoutNulls)
        default: value
        }
    }
}
