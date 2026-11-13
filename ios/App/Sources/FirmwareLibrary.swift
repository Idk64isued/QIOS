import AppleArchive
import Foundation
import HostRuntime
import System
import ZIPFoundation

// Where everything lives, the firmware list (the Mac app's own catalog, bundled), the IPSWs, and the files that come
// out of the Mac release (boot ROMs, the ready-made iPod, the guest tools a prepared device gets).

extension Library {
    /// Files > LightTouch > Device: the SecureROMs and packed devices (also where a hand copy goes).
    static var deviceFiles: URL { documents.appendingPathComponent("Device", isDirectory: true) }
    /// Files > LightTouch > IPSW: firmware, named by catalog id (n72ap-7E18.ipsw).
    static var ipsw: URL { documents.appendingPathComponent("IPSW", isDirectory: true) }
    /// Not shown in Files: the guest tools archive and devices being prepared.
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LightTouch", isDirectory: true)
    }
    /// Things iOS may delete when the phone is full, all of which can be made again.
    static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LightTouch", isDirectory: true)
    }
    static var preparing: URL { support.appendingPathComponent("Preparing", isDirectory: true) }
    static var decrypted: URL { caches.appendingPathComponent("Decrypted", isDirectory: true) }
    static var downloads: URL { caches.appendingPathComponent("Downloads", isDirectory: true) }

    static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A folder name that is safe in Files and not taken yet under Devices.
    static func newDeviceFolder(named wanted: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .-_()"))
        var name = String(wanted.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if name.isEmpty { name = "Device" }
        var candidate = devices.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = devices.appendingPathComponent("\(name) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// Leftovers of a preparation that was interrupted (the app was closed mid-way): nothing in there is a device.
    static func sweepPreparing() {
        try? FileManager.default.removeItem(at: preparing)
    }
}

// MARK: - Catalog

/// One firmware the catalog knows (LightTouchMac/Resources/firmware-catalog.json), as much of it as the app shows.
struct CatalogFirmware: Decodable, Identifiable, Hashable {
    struct Source: Decodable, Hashable {
        struct Mirror: Decodable, Hashable {
            let url: URL
            let sha1: String
            let bytes: Int64
            let kind: String?
        }
        let kind: String
        let url: URL?
        let sha1: String?
        let bytes: Int64?
        let mirrors: [Mirror]?
    }
    struct Recipe: Decodable, Hashable { let name: String }
    struct Estimates: Decodable, Hashable {
        let preparedBytes: Int64?
        let peakBytes: Int64?
        let seconds: Double?
    }

    let id: String
    let board: String
    let productType: String
    let version: String
    let build: String
    let status: String
    let statusNote: String?
    let source: Source
    let recipe: Recipe?
    let estimates: Estimates?

    var major: Int { Int(version.prefix { $0 != "." }) ?? 0 }
    /// "iPhone OS 3.1.3" for the versions that were called that, "iOS 4.2.1" after.
    var systemName: String { (major < 4 ? "iPhone OS " : "iOS ") + version }
    var isExperimental: Bool { status != "available" }

    enum Support: Equatable {
        case onDevice
        case needsMac(String)
        case comingSoon
    }

    /// Whether this phone can make the device itself. Preparation on the phone is file work only; firmware that needs
    /// a preparation boot (iOS 4 data protection, the iPad's seal) still has to be prepared on a Mac.
    var support: Support {
        if status == "coming_soon" { return .comingSoon }
        if source.kind != "ipsw" || source.url == nil || source.sha1 == nil {
            return .needsMac("This build is only archived as a developer beta package.")
        }
        switch board {
        case "n72ap":
            return major < 4 ? .onDevice : .needsMac("iOS 4 needs a preparation boot, which only the Mac app can run.")
        case "n45ap", "m68ap":
            return .onDevice
        default:
            return .needsMac("This device needs preparation boots, which only the Mac app can run.")
        }
    }

    /// Download places, the catalog's own first, each with the sha1 and size the file must have.
    var downloads: [(url: URL, sha1: String, bytes: Int64?)] {
        var list: [(url: URL, sha1: String, bytes: Int64?)] = []
        if let url = source.url, let sha1 = source.sha1 { list.append((url, sha1.lowercased(), source.bytes)) }
        for mirror in source.mirrors ?? [] where (mirror.kind ?? "ipsw") == "ipsw" {
            list.append((mirror.url, mirror.sha1.lowercased(), mirror.bytes))
        }
        return list
    }
}

/// The device models of the catalog, in the order the wizard lists them.
struct DeviceModel: Identifiable, Hashable {
    let board: String
    var id: String { board }

    static let order = ["n72ap", "n45ap", "m68ap", "n18ap", "n88ap", "n81ap", "n90ap", "k48ap"]

    var hostBoard: Board? { Board(rawValue: board) }

    var name: String {
        switch board {
        case "n45ap": return "iPod touch (1st generation)"
        case "m68ap": return "iPhone (original)"
        default: return hostBoard?.facts.marketingName ?? board
        }
    }

    var shortName: String {
        switch board {
        case "n72ap": return "iPod touch 2G"
        case "n45ap": return "iPod touch 1G"
        case "m68ap": return "iPhone"
        case "n18ap": return "iPod touch 3G"
        case "n88ap": return "iPhone 3GS"
        case "n81ap": return "iPod touch 4G"
        case "n90ap": return "iPhone 4"
        case "k48ap": return "iPad"
        default: return board
        }
    }

    /// The flat device picture in the Mac app's asset catalog (bundled with this app too).
    var shellImage: String { hostBoard?.facts.art.shell ?? "shell" }
    var symbol: String {
        switch hostBoard?.facts.kind {
        case .some(.iPad): return "ipad"
        case .some(.iPhone): return "iphone"
        default: return "ipodtouch"
        }
    }

    /// The SecureROM the emulator needs for this board, under Files > LightTouch > Device.
    var bootROM: String? {
        switch board {
        case "n72ap": return "bootrom_240_4"
        case "n45ap", "m68ap": return "ipod1g/bootrom_s5l8900"
        default: return nil
        }
    }
}

enum FirmwareCatalog {
    private struct File: Decodable { let entries: [CatalogFirmware] }

    static var url: URL? { Bundle.main.url(forResource: "firmware-catalog", withExtension: "json") }

    /// Read once; empty if the app was built without the catalog.
    static let entries: [CatalogFirmware] = {
        guard let url = FirmwareCatalog.url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode(File.self, from: data))?.entries ?? []
    }()

    static let models: [DeviceModel] = {
        let present = Set(FirmwareCatalog.entries.map(\.board))
        return DeviceModel.order.filter(present.contains).map(DeviceModel.init)
            + present.subtracting(DeviceModel.order).sorted().map(DeviceModel.init)
    }()

    /// Newest first.
    static func firmwares(for model: DeviceModel) -> [CatalogFirmware] {
        entries.filter { $0.board == model.board }.sorted {
            let order = $0.version.compare($1.version, options: .numeric)
            return order == .orderedSame ? $0.build.compare($1.build, options: .numeric) == .orderedDescending
                : order == .orderedDescending
        }
    }

    static func entry(id: String) -> CatalogFirmware? { entries.first { $0.id == id } }
    static func entry(sha1: String) -> CatalogFirmware? {
        let wanted = sha1.lowercased()
        return entries.first { entry in entry.downloads.contains { $0.sha1 == wanted } }
    }
}

// MARK: - IPSWs

enum IPSWStore {
    static func url(for entry: CatalogFirmware) -> URL { Library.ipsw.appendingPathComponent("\(entry.id).ipsw") }

    /// The IPSW is here and whole. Its sha1 was checked when it arrived, and the preparer checks it again.
    static func has(_ entry: CatalogFirmware) -> Bool {
        let file = url(for: entry)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let size = Transfer.fileSize(file)
        return entry.downloads.contains { $0.bytes == nil || $0.bytes == size } && size > 0
    }

    static func stored() -> [(file: URL, entry: CatalogFirmware?)] {
        let items = (try? FileManager.default.contentsOfDirectory(at: Library.ipsw, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension.lowercased() == "ipsw" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0, FirmwareCatalog.entry(id: $0.deletingPathExtension().lastPathComponent)) }
    }

    /// Fetches the entry's IPSW from the first place that gives the right file. `progress`: 0...1 over download and check.
    static func download(_ entry: CatalogFirmware, progress: @escaping (Double, String) -> Void) async throws {
        Library.ensure(Library.ipsw)
        Library.ensure(Library.downloads)
        let partial = Library.downloads.appendingPathComponent("\(entry.id).ipsw.partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        var lastError: Error = Transfer.Failure(message: "The catalog has no download for \(entry.systemName).")
        for (index, source) in entry.downloads.enumerated() {
            try Task.checkCancellation()
            let host = source.url.host ?? "the server"
            do {
                try await Transfer.download(source.url, to: partial, expectedBytes: source.bytes) { fraction in
                    progress(max(0, fraction) * 0.9, "Downloading from \(host)")
                }
                if let bytes = source.bytes, Transfer.fileSize(partial) != bytes {
                    throw Transfer.Failure(message: "The download from \(host) is incomplete.")
                }
                let sha1 = try Transfer.sha1(of: partial) { progress(0.9 + $0 * 0.1, "Checking the download") }
                guard sha1 == source.sha1 else {
                    throw Transfer.Failure(message: "The file from \(host) is not the IPSW Light Touch knows (wrong checksum).")
                }
                let stored = url(for: entry)
                try? FileManager.default.removeItem(at: stored)
                try FileManager.default.moveItem(at: partial, to: stored)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                LTMLog.note("IPSW source \(index + 1) of \(entry.downloads.count) failed: \(error.localizedDescription)")
            }
        }
        throw lastError
    }

    /// A file the user picked: kept only if its sha1 is one the catalog pins. Returns the entry it is.
    static func importFile(_ file: URL, progress: @escaping (Double) -> Void) throws -> CatalogFirmware {
        let sha1 = try Transfer.sha1(of: file, progress: progress)
        guard let entry = FirmwareCatalog.entry(sha1: sha1) else {
            throw Transfer.Failure(message: "\(file.lastPathComponent) is not an IPSW Light Touch supports (or it is damaged).")
        }
        Library.ensure(Library.ipsw)
        let stored = url(for: entry)
        if file.standardizedFileURL != stored.standardizedFileURL {
            try? FileManager.default.removeItem(at: stored)
            try FileManager.default.copyItem(at: file, to: stored)
        }
        return entry
    }
}

// MARK: - The Mac release's files

/// The boot ROMs, the ready-made iPod touch and the guest tools all ship inside the Mac app. This fetches the Mac
/// release that matches this app's emulator and takes those three things out of it, on the phone.
enum MacFiles {
    /// The Mac release built from the same sources as this app's emulator. The guest's graphics library and the
    /// emulator speak a versioned protocol, so a newer or older release's files would not match. Change it together
    /// with an upstream sync (build-support/sources.json).
    static let releaseTag = "v1.0-2026.11.05"
    static let assetName = "LightTouchMac-universal.zip"
    static let approximateBytes: Int64 = 392_075_542

    static var base: URL { URL(string: "https://github.com/samhenrigold/LightTouchMac/releases/download/\(releaseTag)/")! }
    static var zipURL: URL { base.appendingPathComponent(assetName) }
    static var checksumsURL: URL { base.appendingPathComponent("SHA256SUMS") }

    static var folder: URL { Library.support.appendingPathComponent("MacFiles", isDirectory: true) }
    static var guestArchive: URL { folder.appendingPathComponent("Guest/guest.aar") }
    static var hasGuestTools: Bool { FileManager.default.fileExists(atPath: guestArchive.path) }

    static func hasBootROM(_ model: DeviceModel) -> Bool {
        guard let rom = model.bootROM else { return true }
        return FileManager.default.fileExists(atPath: Library.deviceFiles.appendingPathComponent(rom).path)
    }
    static var hasAnyBootROM: Bool {
        ["bootrom_240_4", "ipod1g/bootrom_s5l8900"].contains {
            FileManager.default.fileExists(atPath: Library.deviceFiles.appendingPathComponent($0).path)
        }
    }

    enum Stage { case downloading, checking, unpacking }

    /// Downloads the release and unpacks Device/ (boot ROMs, the packed iPod) and the guest tools archive.
    /// `progress` is called off the main thread.
    static func install(progress: @escaping (Stage, Double) -> Void) async throws {
        let fm = FileManager.default
        Library.ensure(Library.downloads)
        let zip = Library.downloads.appendingPathComponent("\(releaseTag)-\(assetName)")
        defer { try? fm.removeItem(at: zip) }

        try await Transfer.download(zipURL, to: zip, expectedBytes: approximateBytes) { progress(.downloading, $0) }
        try Task.checkCancellation()

        // The release publishes its checksum; a truncated or swapped download stops here.
        if let sums = try? await Transfer.data(checksumsURL), let text = String(data: sums, encoding: .utf8),
            let line = text.split(separator: "\n").first(where: { $0.contains(assetName) }) ?? text.split(separator: "\n").first,
            let wanted = line.split(separator: " ").first, wanted.count == 64
        {
            let actual = try Transfer.sha256(of: zip) { progress(.checking, $0) }
            guard actual == wanted.lowercased() else {
                throw Transfer.Failure(message: "The Mac release download is damaged (wrong checksum). Try again.")
            }
        }
        try Task.checkCancellation()
        try unpack(zip) { progress(.unpacking, $0) }
    }

    /// Takes Contents/Resources/Device/** and Contents/Resources/Guest/guest.aar out of a Mac release zip.
    static func unpack(_ zip: URL, progress: (Double) -> Void) throws {
        let fm = FileManager.default
        let archive: ZIPFoundation.Archive
        do { archive = try ZIPFoundation.Archive(url: zip, accessMode: .read) } catch {
            throw Transfer.Failure(message: "The Mac release is not a readable zip (\(error.localizedDescription)).")
        }
        let deviceMarker = ".app/Contents/Resources/Device/"
        let guestSuffix = ".app/Contents/Resources/Guest/guest.aar"
        var wanted: [(entry: ZIPFoundation.Entry, destination: URL)] = []
        for entry in archive where entry.type == .file {
            let path = entry.path
            if path.hasPrefix("__MACOSX/") { continue }
            if let range = path.range(of: deviceMarker) {
                let relative = String(path[range.upperBound...])
                let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
                guard !relative.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                    parts.last != ".DS_Store"
                else { continue }
                wanted.append((entry, Library.deviceFiles.appendingPathComponent(relative)))
            } else if path.hasSuffix(guestSuffix) {
                wanted.append((entry, guestArchive))
            }
        }
        guard !wanted.isEmpty else {
            throw Transfer.Failure(message: "The Mac release has no Device folder or guest tools; its layout changed.")
        }
        let total = Double(max(1, wanted.reduce(0) { $0 + Int64($1.entry.uncompressedSize) }))
        var done = 0.0
        for (entry, destination) in wanted {
            try Task.checkCancellation()
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            _ = try archive.extract(entry, to: destination)
            done += Double(entry.uncompressedSize)
            progress(min(1, done / total))
        }
        // The guest tools' unpacked copy belongs to the old archive.
        try? fm.removeItem(at: guestCache)
    }

    // MARK: Guest tools

    static var guestCache: URL { Library.caches.appendingPathComponent("Guest", isDirectory: true) }

    /// The flat guest-tools folder a preparation reads, unpacked from guest.aar (an Apple Archive) on first use.
    static func guestToolsDirectory() throws -> URL {
        let fm = FileManager.default
        guard hasGuestTools else {
            throw Transfer.Failure(message: "The guest tools are missing. Get the Mac files first.")
        }
        let id = "\(Transfer.fileSize(guestArchive))"
        let target = guestCache.appendingPathComponent(id, isDirectory: true)
        let tools = target.appendingPathComponent("guest-tools", isDirectory: true)
        if fm.fileExists(atPath: target.appendingPathComponent(".complete").path), fm.fileExists(atPath: tools.path) {
            return tools
        }
        try? fm.removeItem(at: guestCache)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try extract(appleArchive: guestArchive, to: target)
        guard fm.fileExists(atPath: tools.path) else {
            throw Transfer.Failure(message: "The Mac release's guest archive has no guest-tools folder.")
        }
        fm.createFile(atPath: target.appendingPathComponent(".complete").path, contents: nil)
        return tools
    }

    private static func extract(appleArchive archive: URL, to directory: URL) throws {
        let failed = Transfer.Failure(message: "The guest tools archive could not be unpacked.")
        guard
            let file = ArchiveByteStream.fileStream(
                path: FilePath(archive.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644))
        else { throw failed }
        defer { try? file.close() }
        guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else { throw failed }
        defer { try? decompressed.close() }
        guard let decoded = ArchiveStream.decodeStream(readingFrom: decompressed) else { throw failed }
        defer { try? decoded.close() }
        guard
            let extracted = ArchiveStream.extractStream(
                extractingTo: FilePath(directory.path), flags: [.ignoreOperationNotPermitted])
        else { throw failed }
        defer { try? extracted.close() }
        _ = try ArchiveStream.process(readingFrom: decoded, writingTo: extracted)
    }
}
