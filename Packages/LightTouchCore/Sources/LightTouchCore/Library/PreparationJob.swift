import Crypto
import FirmwareSchema
import Foundation
import HostRuntime
import Subprocess
import System

// One IPSW → device preparation: runs `firmwarekit create` into
// State/Preparing/<id>/, reads its JSON Lines, and publishes the result as
// Devices/<id>/base plus device.plist.
//
// The job id is also the new device's id and its identity seed. Staging and
// the published device are on one volume, so the publish is a rename and the
// sparse NAND stays sparse. Nothing outside Preparing/ is written until the
// preparer says done; the whole device is assembled in Preparing/<id>.publish
// and appears in Devices/ with one rename, so a failure never leaves a half
// device and never touches a published one.

public nonisolated final class PreparationJob: @unchecked Sendable {
    public struct Request: Sendable {
        public init(
            entry: FirmwareCatalog.Entry,
            ipsw: URL,
            sibling: (entry: FirmwareCatalog.Entry, ipsw: URL)? = nil,
            state: URL,
            preparer: URL,
            helper: URL,
            cache: URL,
            log: URL,
            blob: URL? = nil,
            skipSetup: Bool = false,
            jailbreak: Bool = false,
            hfs: HFSRoute? = nil
        ) {
            self.entry = entry
            self.ipsw = ipsw
            self.sibling = sibling
            self.ipsw = ipsw
            self.state = state
            self.preparer = preparer
            self.helper = helper
            self.cache = cache
            self.log = log
            self.blob = blob
            self.skipSetup = skipSetup
            self.jailbreak = jailbreak
            self.hfs = hfs
        }
        public var entry: FirmwareCatalog.Entry
        public var ipsw: URL
        /// recipe.keybag_ramdisk_from: that entry and its IPSW (its ramdisk boots the keybag one-shot).
        public var sibling: (entry: FirmwareCatalog.Entry, ipsw: URL)?
        /// The state directory (Preparing/ and Devices/ are under it).
        public var state: URL
        public var preparer: URL
        public var helper: URL
        /// Decrypted components by IPSW sha1; this IPSW's are deleted when the job ends, however it ends.
        public var cache: URL
        /// The preparer's stderr.
        public var log: URL
        /// A packed base (the built-in device) to unpack with an identity of its own instead of preparing `ipsw`.
        public var blob: URL? = nil
        /// Prepare the device past Setup Assistant (firmwarekit create --skip-setup).
        public var skipSetup = false
        /// Prepare the device jailbroken (firmwarekit create --jailbreak).
        public var jailbreak = false
        /// How the volumes are edited (create and unpack-base --hfs; nil: firmwarekit's default, mounted).
        public var hfs: HFSRoute?
    }

    public enum Event: Sendable, Equatable {
        /// The preparer's expected seconds per step (empty if it gave none), before the first step.
        case begin(seconds: [Double])
        case step(Int, of: Int, name: String)
        /// Within the current step, 0...1, and what the step is doing.
        case progress(Double, detail: String?)
        case warning(String)
        case published(DeviceInstance)
        case failed(String)
        case cancelled
    }

    /// One line of the preparer's stdout.
    public enum Line: Equatable {
        case begin(steps: Int, seconds: [Double] = [])
        case step(index: Int, name: String)
        case progress(Double, detail: String? = nil)
        case warning(String)
        case done(lock: String)
        /// `piece`: a required fit check's piece that didn't fit ("OpenGLES front end (contrib/gles-public)").
        case error(code: String, message: String, piece: String? = nil)

        public init?(_ text: some StringProtocol) {
            guard let data = text.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let event = object["event"] as? String
            else { return nil }
            let int = { (key: String) in (object[key] as? NSNumber)?.intValue }
            switch event {
            case "begin":
                guard let steps = int("steps") else { return nil }
                self = .begin(steps: steps, seconds: (object["seconds"] as? [NSNumber])?.map(\.doubleValue) ?? [])
            case "step":
                guard let index = int("index") else { return nil }
                self = .step(index: index, name: object["name"] as? String ?? "")
            case "progress":
                guard let fraction = (object["fraction"] as? NSNumber)?.doubleValue else { return nil }
                self = .progress(fraction, detail: object["detail"] as? String)
            case "warning": self = .warning(object["message"] as? String ?? "")
            case "done": self = .done(lock: object["lock"] as? String ?? "device.lock.json")
            case "error":
                self = .error(
                    code: object["code"] as? String ?? "internal",
                    message: object["message"] as? String ?? "",
                    piece: object["piece"] as? String
                )
            default: return nil
            }
        }
    }

    /// What the row says for an error event. The detail stays in the preparer's log.
    public static func message(code: String, detail: String, piece: String? = nil, beta: Bool = false) -> String {
        if code == "unsupported", let piece {
            return "Light Touch can’t prepare this \(beta ? "beta" : "version") yet: \(unsupportedReason(piece))."
        }
        return switch code {
        case "key_missing": "Light Touch doesn’t have the keys for this firmware."
        case "sha_mismatch": "This IPSW doesn’t match the one Light Touch knows."
        case "unsupported": "This IPSW isn’t supported."
        case "activation_failed", "hook_failed": "Couldn’t activate this device."
        case "oneshot_failed": "The device’s first boot didn’t finish."
        case "disk_full": "Not enough disk space to prepare this device."
        // The placeholder's headline already says "Couldn’t prepare": the reason alone, as a sentence.
        default: detail.isEmpty ? "No reason was given." : sentence(detail)
        }
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let capitalized = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        return ".!?".contains(capitalized.last ?? ".") ? capitalized : capitalized + "."
    }

    /// A fit check's piece (FirmwareKit's FitCheck names) in the user's words.
    public static func unsupportedReason(_ piece: String) -> String {
        if piece == HFSRoute.writerRefusal {
            return "its disk images have to be mounted to prepare it (turn off Prepare devices without mounting disk "
                + "images in Settings ▸ General)"
        }
        if piece.hasPrefix("OpenGLES") { return "its graphics library isn’t supported" }
        if piece.hasPrefix("kernelcache") || piece.hasPrefix("boot-arg") || piece.hasPrefix("DeviceTree") {
            return "the way it starts up isn’t supported"
        }
        if piece.hasPrefix("iPhone OS 1") { return "only iPhone OS 1 runs on this device" }
        if piece.localizedCaseInsensitiveContains("appsync") { return "installing apps on it isn’t supported" }
        return "the guest tools don’t run on it"  // it_boot, the guest package's pieces, the helpers
    }

    public let id: UUID
    public let request: Request
    private let onEvent: @Sendable (Event) -> Void
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var steps = 0
    private var outcome: Line?
    private var cancelled = false

    public var staging: URL { Self.preparing(request.state).appendingPathComponent(id.uuidString, isDirectory: true) }
    private var entryFile: URL { Self.preparing(request.state).appendingPathComponent("\(id.uuidString).entry.json") }
    private var siblingFile: URL {
        Self.preparing(request.state).appendingPathComponent("\(id.uuidString).sibling.json")
    }
    public static func preparing(_ state: URL) -> URL { state.appendingPathComponent("Preparing", isDirectory: true) }

    /// Events arrive on a background queue, `.published`, `.failed` or `.cancelled` last.
    public init(_ request: Request, id: UUID = UUID(), onEvent: @escaping @Sendable (Event) -> Void) {
        self.id = id
        self.request = request
        self.onEvent = onEvent
    }

    public func start() {
        do {
            try StorageLocations.privateDirectory(staging)
            StorageLocations.excludeFromBackup(Self.preparing(request.state))
            try JSONEncoder().encode(request.entry).write(to: entryFile)
            try StorageLocations.privateDirectory(request.log.deletingLastPathComponent())
            FileManager.default.createFile(atPath: request.log.path, contents: nil)
            let arguments: [String]
            if let blob = request.blob {
                arguments =
                    FirmwareCommand.UnpackBase(blob: blob, out: staging, seed: id.uuidString, hfs: request.hfs)
                    .arguments
            } else {
                if let sibling = request.sibling { try JSONEncoder().encode(sibling.entry).write(to: siblingFile) }
                arguments =
                    FirmwareCommand.Create(
                        entry: entryFile,
                        ipsw: request.ipsw,
                        out: staging,
                        seed: id.uuidString,
                        helper: request.helper,
                        cache: request.cache,
                        sibling: request.sibling.map { (siblingFile, $0.ipsw) },
                        skipSetup: request.skipSetup,
                        jailbreak: request.jailbreak,
                        hfs: request.hfs
                    ).arguments
            }
            let log = try FileDescriptor.open(request.log.path, .writeOnly)
            let task = Task.detached { [self] in await run(arguments, log: log) }
            lock.withLock { self.task = task }
            if lock.withLock({ cancelled }) { task.cancel() }
        } catch {
            finish(.failed("Couldn’t start preparing the device: \(error.localizedDescription)"))
        }
    }

    /// SIGTERM, and SIGKILL if the preparer is still there after 5 s (the
    /// contract gives it 2). The staging directory goes when it exits.
    public func cancel() {
        lock.withLock { cancelled = true }
        lock.withLock { task }?.cancel()
    }

    /// The preparer, its JSON Lines read as they come, its stderr into the log.
    private func run(_ arguments: [String], log: FileDescriptor) async {
        var options = PlatformOptions()
        options.teardownSequence = [.send(signal: .terminate, allowedDurationToNextStep: .seconds(5))]
        let status: Int32
        do {
            let result = try await Subprocess.run(
                .path(FilePath(request.preparer.path)),
                arguments: Arguments(arguments),
                platformOptions: options,
                input: .none,
                output: .sequence,
                error: .fileDescriptor(log, closeAfterSpawningProcess: true)
            ) { execution in
                for try await line in execution.standardOutput.strings() { receive(Line(line)) }
            }
            status =
                switch result.terminationStatus {
                case .exited(let code): code
                case .signaled(let signal): 128 + signal
                }
        } catch {
            if lock.withLock({ cancelled }) { return finish(.cancelled) }
            return finish(.failed("Couldn’t start preparing the device: \(error.localizedDescription)"))
        }
        if lock.withLock({ cancelled }) { return finish(.cancelled) }
        switch lock.withLock({ outcome }) {
        case .done(let lockName)? where status == 0:
            do { finish(.published(try publish(lock: lockName))) } catch {
                finish(.failed("Couldn’t save the prepared device: \(error.localizedDescription)"))
            }
        case .error(let code, let detail, let piece)?:
            // A cached or imported IPSW that fails its SHA is never used again (a reference: the link, not the file).
            if code == "sha_mismatch" { try? FileManager.default.removeItem(at: request.ipsw) }
            finish(
                .failed(Self.message(code: code, detail: detail, piece: piece, beta: request.entry.prerelease != nil))
            )
        default:
            logEvent("firmware: firmwarekit exited \(status) without a result")
            finish(.failed("Preparation stopped unexpectedly."))
        }
    }

    private func receive(_ line: Line?) {
        switch line {
        case .begin(let count, let seconds)?:
            lock.withLock { steps = count }
            onEvent(.begin(seconds: seconds))
        case .step(let index, let name)?: onEvent(.step(index, of: lock.withLock { steps }, name: name))
        case .warning(let message)?: onEvent(.warning(message))
        case .done?, .error?: lock.withLock { if outcome == nil { outcome = line } }
        case .progress(let fraction, let detail)?: onEvent(.progress(fraction, detail: detail))
        case nil: break
        }
    }

    private func finish(_ event: Event) {
        if case .published = event {} else { try? DeviceStateStorage.removeTree(staging) }
        try? FileManager.default.removeItem(at: entryFile)
        try? FileManager.default.removeItem(at: siblingFile)
        // Retain verified results for reuse. Cleanup is coordinated by the
        // preparer's cache-prune command, which holds the same root lease as
        // every reader; a completed job cannot delete another job's inputs.
        onEvent(event)
    }

    /// Launch, under the app lock: nothing in Preparing/ is a device. Disk
    /// images a killed preparer left attached there are detached first
    /// (`firmwarekit detach-images`, FirmwareKit's DiskImage), or their files couldn't go.
    public static func sweep(state: URL, preparer: URL?) {
        let preparing = preparing(state)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: preparing.path)) ?? []
        guard !names.isEmpty else { return }
        if let preparer {
            let detach = Process()
            detach.executableURL = preparer
            detach.arguments = FirmwareCommand.DetachImages(root: preparing).arguments
            detach.standardOutput = FileHandle.nullDevice
            if (try? detach.run()) != nil {
                detach.waitUntilExit()
                if detach.terminationStatus != 0 {
                    logEvent("firmware: detach-images exited \(detach.terminationStatus)")
                }
            }
        }
        for name in names { try? DeviceStateStorage.removeTree(preparing.appendingPathComponent(name)) }
    }

    // MARK: - Publish

    public func publish(lock lockName: String) throws -> DeviceInstance {
        try Self.publish(staging: staging, entry: request.entry, id: id, state: request.state, lock: lockName)
    }

    /// Assembles Preparing/<id>.publish/{base, device.plist} (the staging
    /// directory renamed to base) and renames it to Devices/<id> in one
    /// step. Any failure before that rename leaves Devices/ untouched. Also
    /// a development base's record (`staging` absolute, kept in place: `keep`).
    public static func publish(
        staging: URL,
        entry: FirmwareCatalog.Entry,
        id: UUID,
        state: URL,
        lock lockName: String = "device.lock.json",
        keep: Bool = false
    ) throws -> DeviceInstance {
        let fm = FileManager.default
        let profile = entry.profile ?? .k48
        let lockURL = staging.appendingPathComponent(lockName)
        let lock = try DeviceLock.read(lockURL)
        let boot = try profile.requiredFiles(strategy: lock?.bootStrategy)
        for name in [boot.boot, "nand", "identity.json", lockName] + boot.files
        where !fm.fileExists(atPath: staging.appendingPathComponent(name).path) {
            throw FirmwareError.failed("The prepared device is incomplete (\(name) is missing).")
        }
        let lockData = try Data(contentsOf: lockURL)
        let identity = identity(
            identityJSON: try? Data(contentsOf: staging.appendingPathComponent("identity.json")),
            lock: lock,
            seed: id.uuidString
        )
        let directory = DeviceInstance.directory(id, state: state)
        let relative = "Devices/\(id.uuidString)"
        let base = keep ? staging.path : "\(relative)/base"
        let instance = DeviceInstance(
            // an image store (the A4 and S5L8920 boards) is format 2, which an older build must not boot
            format: PreparedDeviceBoot.isImageStore(staging.appendingPathComponent("nand"))
                ? DeviceRecord.imageFormat : 1,
            id: id,
            name: entry.marketingName,
            board: entry.board,
            firmware: entry.id,
            created: DeviceInstance.now,
            base: .init(kind: .prepared, path: base),
            storage: .init(
                key: String(sha256(lockData).prefix(16)),
                overlay: "\(relative)/overlay",
                writableNOR: fm.fileExists(atPath: staging.appendingPathComponent("nor.bin").path)
                    ? "\(relative)/nor.bin" : nil,
                snapshot: "\(relative)/snapshot",
                usbmuxConf: "\(relative)/usbmuxd-conf"
            ),
            identity: identity,
            provenance: .init(lock: "\(base)/\(lockName)", sha256: sha256(lockData))
        )
        let publishing = preparing(state).appendingPathComponent("\(id.uuidString).publish", isDirectory: true)
        do {
            try StorageLocations.privateDirectory(publishing)
            if !keep { try fm.moveItem(at: staging, to: publishing.appendingPathComponent("base", isDirectory: true)) }
            try DeviceInstance.encoder.encode(instance)
                .write(to: publishing.appendingPathComponent(DeviceInstance.recordName), options: .atomic)
            try StorageLocations.privateDirectory(directory.deletingLastPathComponent())
            guard rename(publishing.path, directory.path) == 0 else { throw StorageLocations.posixError() }
        } catch {
            try? DeviceStateStorage.removeTree(publishing)
            throw error
        }
        if !keep { DeviceStateStorage.lockBase(directory.appendingPathComponent("base", isDirectory: true)) }
        return instance
    }

    /// A new device from a prepared base left where it is (`sessions single --managed`): the base copied into
    /// Preparing/<id> (an APFS clone) and published, so the device is exactly a preparation's and `base` is never
    /// written.
    public static func publish(copyOf base: URL, entry: FirmwareCatalog.Entry, state: URL) throws -> DeviceInstance {
        let id = UUID()
        let staging = preparing(state).appendingPathComponent(id.uuidString, isDirectory: true)
        try StorageLocations.privateDirectory(staging.deletingLastPathComponent())
        try FileManager.default.copyItem(at: base, to: staging)
        return try publish(staging: staging, entry: entry, id: id, state: state)
    }

    /// udid and die id from identity.json, else the lock's identity; the seed is ours.
    public static func identity(identityJSON: Data?, lock: DeviceLock?, seed: String) -> DeviceInstance.Identity {
        let file = identityJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func dieID(_ value: Any?) -> String? { (value as? [String])?.joined(separator: ":") ?? value as? String }
        let locked = lock?.identity
        return .init(
            seed: locked?["seed"]?.string ?? seed,
            udid: file["udid"] as? String ?? locked?["udid"]?.string,
            dieID: dieID(file["die-id"] ?? file["die_id"])
                ?? locked?["die_id"].flatMap { $0.strings?.joined(separator: ":") ?? $0.string }
        )
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
