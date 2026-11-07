// device.lock.json: what firmwarekit made a prepared base from and how it boots. FirmwareKit writes it
// (Recipe, PreparedBase, StoppedVolumeEdit) and everything else reads it through this one type. The keys are
// the on-disk format (qemu-ios's Python reads them too); members this type doesn't name are kept as they are.

import Foundation

/// A JSON value, for the lock's members that carry free-form records (inputs, outputs, fit, derived, ...).
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int64.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// A JSONSerialization value (FirmwareKit's records are built that way).
    public init(_ any: Any?) throws {
        switch any {
        case nil, is NSNull: self = .null
        case let v as NSNumber where CFGetTypeID(v) == CFBooleanGetTypeID(): self = .bool(v.boolValue)
        case let v as NSNumber where CFNumberIsFloatType(v): self = .double(v.doubleValue)
        case let v as NSNumber: self = .int(v.int64Value)
        case let v as String: self = .string(v)
        case let v as [Any]: self = .array(try v.map(JSONValue.init))
        case let v as [String: Any]: self = .object(try v.mapValues(JSONValue.init))
        default:
            throw CocoaError(
                .coderInvalidValue,
                userInfo: [NSLocalizedDescriptionKey: "not JSON: \(any.map { "\(type(of: $0))" } ?? "nil")"]
            )
        }
    }

    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { o[key] } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var int: Int? { if case .int(let v) = self { Int(v) } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    /// An array of strings (its other elements left out).
    public var strings: [String]? { if case .array(let v) = self { v.compactMap(\.string) } else { nil } }
    /// A scalar as a -machine option's text.
    public var optionText: String? {
        switch self {
        case .string(let v): v
        case .int(let v): String(v)
        case .double(let v): String(v)
        case .bool(let v): v ? "on" : "off"
        default: nil
        }
    }
}

public struct DeviceLock: Codable, Sendable, Equatable {
    public static let fileName = "device.lock.json"

    /// The board ID (every firmwarekit lock has it).
    public var board: String?
    public var build: String?
    public var productType: String?
    public var productVersion: String?
    /// The prepared base's boot path ("iboot", "kboot", "bootrom"); nil: the board's default (Board.requiredFiles).
    public var bootStrategy: String?
    /// The -machine options every boot of the device carries (ecid, imei, wifi-mac, rtc-epoch, aes-uid, ...).
    public var machine: [String: JSONValue]?
    public var identity: JSONValue?
    /// The catalog entry the base was made from: id, sha256 and its content (recipe, board, ...).
    public var entry: JSONValue?
    /// inputs.activation: what activated the volume; null or absent for a base made without that step.
    public var inputs: JSONValue?
    /// What the preparer seeded from the guest package (family, seed, gles, hooks, ...), or null.
    public var guestPackage: JSONValue?
    public var derived: JSONValue?
    /// Every other member, as written.
    public var other: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case board
        case build
        case productType = "product_type"
        case productVersion = "product_version"
        case bootStrategy = "boot_strategy"
        case machine
        case identity
        case entry
        case inputs
        case guestPackage = "guest_package"
        case derived
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        board = try c.decodeIfPresent(String.self, forKey: .board)
        build = try c.decodeIfPresent(String.self, forKey: .build)
        productType = try c.decodeIfPresent(String.self, forKey: .productType)
        productVersion = try c.decodeIfPresent(String.self, forKey: .productVersion)
        // Present, it must be a string: a null or mistyped strategy never silently becomes the board's default.
        bootStrategy = c.contains(.bootStrategy) ? try c.decode(String.self, forKey: .bootStrategy) : nil
        machine = try c.decodeIfPresent([String: JSONValue].self, forKey: .machine)
        identity = try c.decodeIfPresent(JSONValue.self, forKey: .identity)
        entry = try c.decodeIfPresent(JSONValue.self, forKey: .entry)
        inputs = try c.decodeIfPresent(JSONValue.self, forKey: .inputs)
        guestPackage = try c.decodeIfPresent(JSONValue.self, forKey: .guestPackage)
        derived = try c.decodeIfPresent(JSONValue.self, forKey: .derived)
        let all = try decoder.container(keyedBy: AnyKey.self)
        let named = Set(CodingKeys.allCases.map(\.rawValue))
        for key in all.allKeys where !named.contains(key.stringValue) {
            other[key.stringValue] = try all.decode(JSONValue.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(board, forKey: .board)
        try c.encodeIfPresent(build, forKey: .build)
        try c.encodeIfPresent(productType, forKey: .productType)
        try c.encodeIfPresent(productVersion, forKey: .productVersion)
        try c.encodeIfPresent(bootStrategy, forKey: .bootStrategy)
        try c.encodeIfPresent(machine, forKey: .machine)
        try c.encodeIfPresent(identity, forKey: .identity)
        try c.encodeIfPresent(entry, forKey: .entry)
        try c.encodeIfPresent(inputs, forKey: .inputs)
        try c.encodeIfPresent(guestPackage, forKey: .guestPackage)
        try c.encodeIfPresent(derived, forKey: .derived)
        var all = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in other { try all.encode(value, forKey: AnyKey(stringValue: key)) }
    }

    /// From a JSONSerialization object (FirmwareKit builds the record that way).
    public init(json: [String: Any]) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(JSONValue(json)))
    }

    /// The file's bytes: JSONSerialization's sorted keys (its order, which isn't JSONEncoder's), pretty-printed,
    /// slashes as they are; the bytes FirmwareKit has always written.
    public func data() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: JSONEncoder().encode(self)),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - Reading

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (stamp: [FileAttributeKey: AnyHashable], lock: DeviceLock)] =
        [:]

    /// The lock at `url`, decoded once while the file is unchanged (path, size, modification date, inode). nil for a
    /// missing file (a legacy base without one); a present unreadable or malformed lock throws, so it never silently
    /// picks another boot path.
    public static func read(_ url: URL) throws -> DeviceLock? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
        { return nil }
        let stamp = [FileAttributeKey.size, .modificationDate, .systemFileNumber].reduce(
            into: [FileAttributeKey: AnyHashable]()
        ) {
            $0[$1] = attributes[$1] as? AnyHashable
        }
        if let hit = cacheLock.withLock({ cache[url.path] }), hit.stamp == stamp { return hit.lock }
        let data: Data
        do { data = try Data(contentsOf: url) } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
        { return nil }
        let lock: DeviceLock
        do { lock = try JSONDecoder().decode(DeviceLock.self, from: data) } catch {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [
                    NSFilePathErrorKey: url.path, NSUnderlyingErrorKey: error,
                    NSLocalizedDescriptionKey: "Invalid boot lock at \(url.path): \(error)"
                ]
            )
        }
        cacheLock.withLock { cache[url.path] = (stamp, lock) }
        return lock
    }

    /// A prepared base's lock (`base`/device.lock.json).
    public static func read(base: URL) throws -> DeviceLock? { try read(base.appendingPathComponent(fileName)) }

    // MARK: - What the lock says

    /// The catalog entry's id.
    public var entryID: String? { entry?["id"]?.string }
    /// The recipe version the base was prepared by.
    public var recipeVersion: Int? { entry?["content"]?["recipe"]?["version"]?.int }
    /// Prepared jailbroken (firmwarekit create --jailbreak), or jailbroken since (firmwarekit edit --action jailbreak,
    /// `jailbroken` in its generation's lock): afc2 serves the whole file system.
    public var jailbroken: Bool {
        entry?["content"]?["recipe"]?["options"]?["jailbreak"]?.bool == true || other["jailbroken"]?.bool == true
    }
    /// Prepared past Setup Assistant (the Skip Setup option): it boots to the Home screen.
    public var skippedSetup: Bool { entry?["content"]?["recipe"]?["options"]?["skip_setup"]?.bool == true }
    /// The layout has a data partition (fstab mounts it on /private/var): the recipe's data_size "partition".
    public var hasDataVolume: Bool { entry?["content"]?["recipe"]?["data_size"]?.string == "partition" }
    /// The entry content's board (the recipe's board, for admission steps).
    public var entryBoard: String? { entry?["content"]?["board"]?.string }
    /// Prepared without mounting its volumes (firmwarekit create --hfs writer: inputs.hfs).
    public var preparedWithoutMounting: Bool { inputs?["hfs"]?.string == "writer" }
    /// Whether the preparer activated the volume (inputs.activation is a record).
    public var activated: Bool { inputs?["activation"]?.object != nil }
    /// Whether the boot pins the guest clock (the recipe's rtc-epoch: a beta's lockdownd stops activating past its
    /// expiry), so the host must leave the guest's clock alone.
    public var pinsClock: Bool { machine?["rtc-epoch"] != nil }
    public var identitySeed: String? { identity?["seed"]?.string }
    /// derived.nand_epoch: the N72 generated store's epoch.
    public var nandEpoch: Int? { derived?["nand_epoch"]?.int }

    /// The machine options a boot of `base` passes, with what older bases lack derived from their identity.json
    /// without touching the read-only base: the N72/K48 unit MACs and the N72's ECID (bases from before card
    /// provisioning), and a kboot iPhone's IMEI (recipe 1, IPhoneIdentity).
    public func machineOptions(base: URL) -> [String: String] {
        var options = (machine ?? [:]).compactMapValues(\.optionText)
        let board = self.board.flatMap(Board.init(rawValue:))
        let upgrades = board == .n72 || board == .k48 || board?.kbootPhone == true
        guard upgrades, let data = try? Data(contentsOf: base.appendingPathComponent("identity.json")),
            let identity = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return options }
        if board == .n72 || board == .k48 {
            // The iPad machine has wifi-mac only; its unit identity otherwise comes from die-id.
            for key in board == .k48 ? ["wifi-mac"] : ["wifi-mac", "bt-mac"] where options[key] == nil {
                if let mac = identity[key] as? String, !mac.isEmpty { options[key] = mac }
            }
        }
        if board == .n72, options["ecid"] == nil {
            if let ecid = identity["unique-chip-id"] as? String {
                options["ecid"] = ecid
            } else if let seed = identity["seed"] as? String {
                options["ecid"] = UnitSeed.ecid(seed: seed)  // legacy N72 identities omitted it
            }
        }
        if board?.kbootPhone == true, options["imei"] == nil, let upgraded = IPhoneIdentity.upgraded(identity) {
            options["imei"] = upgraded.imei
        }
        return options
    }
}
