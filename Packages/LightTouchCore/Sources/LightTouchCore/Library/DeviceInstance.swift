// One device the user owns: State/Devices/<uuid>/device.plist (DeviceRecord).
//
// Storage paths are relative to the state directory (so the record survives
// the state root moving) unless absolute: a development base (LTM_DEV_BASE)
// is named by its absolute path.

import Foundation
import HostRuntime

public nonisolated struct DeviceInstance: Codable, Equatable, Identifiable, Sendable {
    public init(
        format: Int = 1,
        id: UUID,
        name: String,
        board: String,
        firmware: String,
        created: Date,
        base: Base,
        storage: Storage,
        identity: Identity? = nil,
        provenance: Provenance? = nil,
        guest: Guest? = nil,
        panel: String? = nil
    ) {
        self.format = format
        self.id = id
        self.name = name
        self.board = board
        self.firmware = firmware
        self.created = created
        self.base = base
        self.storage = storage
        self.identity = identity
        self.provenance = provenance
        self.guest = guest
        self.panel = panel
    }
    public struct Base: Codable, Equatable, Sendable {
        public init(kind: Kind, path: String) {
            self.kind = kind
            self.path = path
        }
        public enum Kind: String, Codable, Sendable {
            /// Read-only `firmwarekit create` output: Devices/<uuid>/base, or a development directory.
            case prepared
        }
        public var kind: Kind
        public var path: String
    }

    public struct Storage: Codable, Equatable, Sendable {
        public init(key: String, overlay: String, writableNOR: String? = nil, snapshot: String, usbmuxConf: String) {
            self.key = key
            self.overlay = overlay
            self.writableNOR = writableNOR
            self.snapshot = snapshot
            self.usbmuxConf = usbmuxConf
        }
        /// The key the overlay, snapshot and image identity were made under.
        public var key: String
        public var overlay: String
        public var writableNOR: String?
        /// Also .meta, .tmp and .bad beside it.
        public var snapshot: String
        public var usbmuxConf: String
    }

    public struct Identity: Codable, Equatable, Sendable {
        public init(seed: String? = nil, udid: String? = nil, dieID: String? = nil) {
            self.seed = seed
            self.udid = udid
            self.dieID = dieID
        }
        public var seed: String?
        public var udid: String?
        public var dieID: String?
        public enum CodingKeys: String, CodingKey {
            case seed
            case udid
            case dieID = "die_id"
        }
    }

    public struct Provenance: Codable, Equatable, Sendable {
        public init(lock: String? = nil, sha256: String? = nil) {
            self.lock = lock
            self.sha256 = sha256
        }
        public var lock: String?
        public var sha256: String?
    }

    /// The record's `guest`: the guest package serials this device has run.
    public struct Guest: Codable, Equatable, Sendable {
        /// Baked at prepare time (device.lock.json), when known.
        public var seed: Int64?
        /// The last serial it_boot reported current.
        public var active: Int64?
        /// The last serial a healthy session ran; offered as `verdict good`.
        public var lastGood: Int64?
        /// Serials judged bad; offered as `verdict bad`, never installed again.
        public var bad: [Int64] = []
        /// Offer the built-in package (serial 0) while the bundled serial is this.
        public var builtIn: Int64?

        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            seed = try c.decodeIfPresent(Int64.self, forKey: .seed)
            active = try c.decodeIfPresent(Int64.self, forKey: .active)
            lastGood = try c.decodeIfPresent(Int64.self, forKey: .lastGood)
            bad = try c.decodeIfPresent([Int64].self, forKey: .bad) ?? []
            builtIn = try c.decodeIfPresent(Int64.self, forKey: .builtIn)
        }
    }

    /// 1: page overlays; 2: an image store (K48NANDMigration), which an older build must not boot.
    public var format = 1
    public let id: UUID
    public var name: String
    public var board: String
    /// A FirmwareCatalog entry id.
    public var firmware: String
    public var created: Date
    public var base: Base
    public var storage: Storage
    public var identity: Identity?
    public var provenance: Provenance?
    /// Guest-package serials and verdicts (GuestPackage).
    public var guest: Guest?
    /// The record's `panel`: an opt-in display of another size, "WxH" as the
    /// panel scans (iPad landscape), passed to the machine as panel=WxH
    /// (issue #21). Absent: the shipped panel.
    public var panel: String?

    public var profile: Board? { Board(rawValue: board) }

    public static let recordName = DeviceRecord.name

    /// `created` is stored as a plist date, whole seconds; a record made with a
    /// finer date would not equal itself read back.
    public static var now: Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

    // MARK: - Paths

    /// Resolves a record path against the state directory.
    public static func url(_ path: String, state: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : state.appendingPathComponent(path)
    }

    public static func directory(_ id: UUID, state: URL) -> URL {
        state.appendingPathComponent("Devices/\(id.uuidString)", isDirectory: true)
    }

    /// Runtime paths, per instance, so two running devices never share a pid
    /// file, lease or log.
    public struct Paths: Sendable {
        public let directory: URL
        public let base: URL
        public let overlay: URL
        public let writableNOR: URL?
        public let snapshot: URL
        public let usbmuxConf: URL
        /// usbmuxd.pid, the lease and the guest-package offer.
        public let work: URL
        /// serial.log, usbmuxd.log.
        public let logs: URL

        public var snapshotMeta: URL { snapshot.appendingPathExtension("meta") }
        public var snapshotTmp: URL { snapshot.appendingPathExtension("tmp") }
        public var snapshotBad: URL { snapshot.appendingPathExtension("bad") }
        public var usbmuxPID: URL { work.appendingPathComponent("usbmuxd.pid") }
        /// The helper's flock while it runs this device (LightTouchDevice --lease).
        public var lease: URL { work.appendingPathComponent("lease") }
        /// Retained .ipa copies of the apps installed on this device (IPALibrary).
        public var ipas: URL { directory.appendingPathComponent("IPAs", isDirectory: true) }
    }

    /// `logs` is the app's log root (Bundled.logsDirectory).
    public func paths(state: URL, logs: URL) -> Paths {
        let directory = Self.directory(id, state: state)
        return Paths(
            directory: directory,
            base: Self.url(base.path, state: state),
            overlay: Self.url(storage.overlay, state: state),
            writableNOR: storage.writableNOR.map { Self.url($0, state: state) },
            snapshot: Self.url(storage.snapshot, state: state),
            usbmuxConf: Self.url(storage.usbmuxConf, state: state),
            work: directory.appendingPathComponent("work", isDirectory: true),
            logs: logs.appendingPathComponent("Devices/\(id.uuidString)", isDirectory: true)
        )
    }

    /// A Start's first check (EmulatorController.start; sessions single --managed): the base and every path a boot
    /// writes are this device's own.
    public func checkBootPaths() throws {
        let paths = paths
        try DeviceStateStorage.checkBootPaths(
            base: paths.base,
            mutable: [
                paths.overlay, paths.snapshot, paths.snapshotMeta, paths.snapshotTmp, paths.snapshotBad,
                paths.usbmuxConf, paths.work, paths.lease
            ] + [paths.writableNOR].compactMap { $0 },
            state: Bundled.stateDirectory,
            owner: id
        )
    }

    /// The boot a Start builds for this device (EmulatorController; sessions single --managed): its record's base,
    /// overlay, NOR, storage key, die ID and panel, through PreparedDeviceBoot's repairs (the overlay's pin to its
    /// base, the live NAND's clone, the S5L8920 kboot's audio clock).
    public func preparedBoot(board: Board, bootrom: String, clock: Date? = nil) throws -> PreparedDeviceBoot {
        try PreparedDeviceBoot.prepare(
            board: board,
            base: paths.base,
            overlay: paths.overlay,
            writableNOR: paths.writableNOR,
            storageKey: storage.key,
            bootrom: bootrom,
            dieID: identity?.dieID,
            panel: panel,
            clock: clock
        )
    }

    /// The preparer records what activated the volume in device.lock.json
    /// `inputs.activation`; a base made without that step has null or nothing
    /// there (a device.py base: `activation_hook: null`). False for an
    /// unreadable lock: nothing to claim.
    public static func lockLacksActivation(_ url: URL) -> Bool {
        guard let lock = (try? DeviceLock.read(url)) ?? nil, lock.inputs?.object != nil else { return false }
        return !lock.activated
    }

    // MARK: - Record I/O

    public static let encoder: PropertyListEncoder = {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return encoder
    }()

    public static let decoder = PropertyListDecoder()

    /// The newest record format this build reads and writes.
    public static let currentFormat = DeviceRecord.currentFormat
    public typealias NewerFormat = DeviceRecord.NewerFormat

    /// Atomic: a crash leaves the old record or the new one, never half. A record of a newer format is not
    /// rewritten, which would drop the fields this build doesn't know.
    public func write(state: URL) throws {
        guard format <= Self.currentFormat else { throw NewerFormat() }
        let directory = Self.directory(id, state: state)
        try StorageLocations.privateDirectory(directory)
        try Self.encoder.encode(self).write(to: directory.appendingPathComponent(Self.recordName), options: .atomic)
    }

    /// `url` is the record or, converting a device.json first, its device directory. A record of a newer format is
    /// refused: its storage may be one this build would misread.
    public static func read(_ url: URL) throws -> DeviceInstance {
        let record = try decode(url)
        guard record.format <= currentFormat else { throw NewerFormat() }
        return record
    }

    private static func decode(_ url: URL) throws -> DeviceInstance {
        let record = url.lastPathComponent == recordName ? url : DeviceRecord.url(url)
        return try decoder.decode(DeviceInstance.self, from: Data(contentsOf: record))
    }

    /// Every readable record under State/Devices, oldest first. A directory
    /// without a readable record is skipped, not deleted. A newer build's record is listed (its start is refused).
    public static func all(state: URL) -> [DeviceInstance] {
        let devices = state.appendingPathComponent("Devices", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: devices.path)) ?? []
        return names.compactMap { name in
            guard let id = UUID(uuidString: name),
                let record = try? decode(devices.appendingPathComponent(name, isDirectory: true)),
                record.id == id
            else { return nil }
            return record
        }.sorted { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) }
    }
}
