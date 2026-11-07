// Flat catalog wire data shared by preparation and the GUI. Foundation only;
// presentation policy and firmware operations belong to their own layers.
import Foundation

nonisolated public enum FirmwareWire {
    /// Devices/<uuid>/<this>: {"recipe": N}, the recipe a stopped device's storage was migrated up to in place
    /// (boot admission), so a base whose lock names an older recipe is still current. Survives Erase on purpose:
    /// admission re-applies the migration's pages to a fresh overlay on every start.
    public static let migratedRecipeFile = "migrated-recipe.json"
    /// A 1.x device's record of the certificate its guest trusts as a system anchor (`firmwarekit edit --action
    /// trust-anchor`): {"sha1": hex, "key": the storage key that commit published}.
    public static let trustAnchorFile = "trust-anchor.json"

    /// Recipe steps boot admission migrates in place, per board: a stopped base at recipe `key` reaches `value` at
    /// its next start (FirmwareBootAdmission), so the GUI counts it as already there and offers no Prepare Again.
    /// The one list of such steps; a migration that isn't listed here leaves its devices flagged.
    public static let admissionRecipeSteps: [String: [Int: Int]] = [
        "n72ap": [1: 2], "n45ap": [2: 3], "m68ap": [1: 2],
        "n90ap": [1: 2], "n88ap": [1: 2]
    ]

    /// `version` after every admission step for `board` (FirmwareWire.admissionRecipeSteps).
    public static func admittedRecipe(_ version: Int, board: String?) -> Int {
        var version = version
        while let next = board.flatMap({ admissionRecipeSteps[$0]?[version] }), next > version { version = next }
        return version
    }

    /// Stopped launch admission reply shared by all host clients. Generation
    /// paths remain durable record data, rather than a second GUI device schema.
    public struct BootAdmission: Codable, Sendable, Equatable {
        public let event: String
        public let changed: Bool
        /// What the device's window should say, quietly (a storage update that couldn't run, and why).
        public let notice: String?
        public init(event: String = "admitted", changed: Bool, notice: String? = nil) {
            self.event = event
            self.changed = changed
            self.notice = notice
        }
    }

    public struct Entry: Codable, Sendable, Equatable {
        public struct Source: Codable, Sendable, Equatable {
            public var kind: String
            public var url: URL?
            public var sha1: String?
            public var bytes: Int64?
            public var resource: String?
            /// Copies of the same file elsewhere (archive.org, BetaArchive), tried in order after `url`.
            public var mirrors: [Mirror]?
            /// kind "rar": `url` is a RAR archive (a developer beta's only public copy) holding the IPSW as `member`.
            /// The download is checked against archive_sha1/archive_bytes, the extracted IPSW against sha1/bytes.
            public var archiveSHA1: String?
            public var archiveBytes: Int64?
            public var member: String?
            enum CodingKeys: String, CodingKey {
                case kind
                case url
                case sha1
                case bytes
                case resource
                case mirrors
                case member
                case archiveSHA1 = "archive_sha1"
                case archiveBytes = "archive_bytes"
            }

            /// Another copy of the same IPSW (sha1/bytes are the IPSW's). `kind` "rar": `url` is an archive holding it as
            /// `member`, checked like a "rar" source; nil or "ipsw": the IPSW itself.
            public struct Mirror: Codable, Sendable, Equatable {
                public var url: URL
                public var sha1: String
                public var bytes: Int64
                public var kind: String?
                public var archiveSHA1: String?
                public var archiveBytes: Int64?
                public var member: String?
                enum CodingKeys: String, CodingKey {
                    case url
                    case sha1
                    case bytes
                    case kind
                    case member
                    case archiveSHA1 = "archive_sha1"
                    case archiveBytes = "archive_bytes"
                }
            }

            public var isArchive: Bool { kind == "rar" }
            /// What a download of `urls` must hash to and weigh: the archive's for a "rar" source, else the IPSW's.
            public var downloadSHA1: String? { isArchive ? archiveSHA1 : sha1 }
            public var downloadBytes: Int64? { isArchive ? archiveBytes : bytes }

            /// What to download, in order: this source, then each mirror that records this sha1 and size as a source of
            /// its own (its kind, URL and archive fields; the same IPSW sha1 and bytes).
            public var alternatives: [Source] {
                (url == nil ? [] : [self])
                    + (mirrors ?? []).filter { $0.sha1 == sha1 && $0.bytes == bytes }.map {
                        Source(
                            kind: $0.kind ?? "ipsw",
                            url: $0.url,
                            sha1: sha1,
                            bytes: bytes,
                            archiveSHA1: $0.archiveSHA1,
                            archiveBytes: $0.archiveBytes,
                            member: $0.member
                        )
                    }
            }
            /// Where to download from, in order (`alternatives`' URLs).
            public var urls: [URL] { alternatives.compactMap(\.url) }
            /// The alternative a download from `url` came from; this source when none matches.
            public func alternative(for url: URL?) -> Source { alternatives.first { $0.url == url } ?? self }
        }

        /// An img3's IV/key, or a root filesystem's VFDecrypt key (no IV). `file` is the name inside the IPSW.
        public struct Key: Codable, Sendable, Equatable {
            public var file: String
            public var iv: String?
            public var key: String
            public init(file: String, iv: String?, key: String) {
                self.file = file
                self.iv = iv
                self.key = key
            }
        }

        public struct Recipe: Codable, Sendable, Equatable {
            public struct Guest: Codable, Sendable, Equatable {
                public var arch: String
                public var glEngine: String?
                enum CodingKeys: String, CodingKey {
                    case arch
                    case glEngine = "gl_engine"
                }
            }
            public var name: String
            /// Raised when users' devices of the row must be prepared again (the app offers Prepare Again for a lower
            /// one, after FirmwareWire.admissionRecipeSteps). Every change to what preparation writes into a base also
            /// appends a PreparationChanges entry, whether or not it raises this.
            public var version: Int
            public var storage: String
            public var systemMiB: Int
            public var dataSize: String
            public var options: [String: Bool]
            public var guest: Guest?
            /// The k48 boot chain: "iboot" (iBoot -> kernel; default when absent) or "kboot"
            /// (direct-kernel, for debugging). Ignored by n72ap.
            public var boot: String?
            /// A sibling entry (same iOS major, ramdisk keys known) whose restore ramdisk boots the data-protection
            /// keybag one-shot when this build has no public ramdisk keys (iPad 4.3.1-4.3.5 -> k48ap-8F190). The caller
            /// supplies that entry and its IPSW (firmwarekit create --sibling-entry/--sibling-ipsw).
            public var keybagRamdiskFrom: String?
            /// NANDDRIVERSIGN flags the build's FTL formats with, when not the store's default (0x5 plain, 0x10005
            /// whitened): the iPod touch 3G's 3.1.x AppleNANDFTL writes 4 and refuses anything above it.
            public var nandSigFlags: Int?
            /// The NAND vendor type the store's VFL context declares, when not the part's default (0x100014, two VFL banks
            /// per CE). 0x10001 (one bank) for iOS 3.0 on the S5L8920 boards: K48NAND.Geometry.k48With16GBV1.
            public var nandVendorType: Int?
            /// The PMU clock at power-on (Unix seconds) for every boot, when not the host's: a developer beta
            /// checks its expiry date against it (6.0 beta 1's lockdownd: 2012-07-18).
            public var rtcEpoch: Int?
            enum CodingKeys: String, CodingKey {
                case name
                case version
                case storage
                case options
                case guest
                case boot
                case systemMiB = "system_mib"
                case dataSize = "data_size"
                case keybagRamdiskFrom = "keybag_ramdisk_from"
                case nandSigFlags = "nand_sig_flags"
                case nandVendorType = "nand_vendor_type"
                case rtcEpoch = "rtc_epoch"
            }
        }

        public struct Emulator: Codable, Sendable, Equatable {
            public var minProtocol: Int
            enum CodingKeys: String, CodingKey { case minProtocol = "min_protocol" }
        }

        public struct Estimates: Codable, Sendable, Equatable {
            public var preparedBytes: Int64
            public var peakBytes: Int64
            public var seconds: Int
            enum CodingKeys: String, CodingKey {
                case seconds
                case preparedBytes = "prepared_bytes"
                case peakBytes = "peak_bytes"
            }
        }

        public var id: String
        public var board: String
        public var productType: String
        public var version: String
        public var build: String
        public var released: String?
        public var prerelease: String?
        public var prereleaseNumber: Int?
        public var status: String
        public var statusNote: String?
        /// The libraries the guest's media helpers have been qualified on for this build ("Music", "Photos",
        /// "Videos"; qemu-ios contrib/it-media): Import Media offers these only.
        public var media: [String]?
        public var source: Source
        public var keys: [String: Key]
        public var recipe: Recipe?
        public var emulator: Emulator
        public var estimates: Estimates

        enum CodingKeys: String, CodingKey {
            case id
            case board
            case version
            case build
            case released
            case prerelease
            case status
            case media
            case source
            case keys
            case recipe
            case emulator
            case
                estimates
            case productType = "product_type"
            case statusNote = "status_note"
            case prereleaseNumber = "prerelease_number"
        }
    }
}
