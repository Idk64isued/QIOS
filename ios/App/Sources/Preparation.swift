import Foundation
import UIKit

#if canImport(FirmwareKit)
import FirmwareKit
#endif

// Making a device on the phone: fetch what is missing (the Mac files, the IPSW), prepare it with FirmwareKit (the
// Mac app's own preparer, running in this process with its offline disk code), and publish it into Devices.

/// What the preparer reports while it works.
enum PrepEvent {
    case begin(steps: Int)
    case step(index: Int, name: String)
    case progress(Double, detail: String?)
    case warning(String)
}

enum OnDevicePrep {
    #if canImport(FirmwareKit)
    /// This build carries the preparer.
    static let available = true

    /// Prepares `entryID` from `ipsw` into `out` (an empty folder), exactly as `firmwarekit create --hfs writer` does.
    static func create(
        entryID: String,
        ipsw: URL,
        out: URL,
        guestTools: URL,
        cache: URL,
        seed: String,
        skipSetup: Bool = false,
        jailbreak: Bool = false,
        emit: @escaping @Sendable (PrepEvent) -> Void
    ) async throws {
        guard let catalog = FirmwareCatalog.url else {
            throw Transfer.Failure(message: "This build has no firmware catalog.")
        }
        do {
            var entry = try FirmwareEntry.load(id: entryID, fromCatalog: catalog)
            if skipSetup { entry.recipe?.options["skip_setup"] = true }
            if jailbreak { entry.recipe?.options["jailbreak"] = true }
            let options = Preparer.Options(
                entry: entry, ipsw: ipsw, out: out, seed: seed, helper: nil, guestTools: guestTools, cache: cache)
            // .writer: volumes are read and written by FirmwareKit's own HFS+ and disk-image code. The default
            // (.kernel) mounts them with hdiutil and diskutil, which iOS does not have.
            try await VolumeMount.$backend.withValue(.writer) {
                try await Preparer.create(options) { event in
                    switch event {
                    case .begin(let steps, _): emit(.begin(steps: steps))
                    case .step(let index, let name): emit(.step(index: index, name: name))
                    case .progress(let fraction, let detail): emit(.progress(fraction, detail: detail))
                    case .warning(let message): emit(.warning(message))
                    case .done, .error: break
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The preparer's own wording for what went wrong (a missing key, a full disk, a piece that does not fit).
            if case .error(_, let message, _) = Preparer.errorEvent(error) { throw Transfer.Failure(message: message) }
            throw error
        }
    }
    #else
    /// This build was made without the preparer (CI falls back to it when FirmwareKit does not compile for iOS).
    static let available = false

    static func create(
        entryID: String,
        ipsw: URL,
        out: URL,
        guestTools: URL,
        cache: URL,
        seed: String,
        skipSetup: Bool = false,
        jailbreak: Bool = false,
        emit: @escaping @Sendable (PrepEvent) -> Void
    ) async throws {
        throw Transfer.Failure(message: "This build of Light Touch cannot prepare firmware. Use the ready-made iPod touch, or a newer build.")
    }
    #endif
}

extension Library {
    /// Deletes a folder even when a preparation left it read-only (a finished base is: its NAND must not change).
    static func removeTree(_ url: URL) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            chmod(url.path, 0o755)
            if let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
                for case let item as URL in walker {
                    if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { chmod(item.path, 0o755) }
                }
            }
        }
        try? fm.removeItem(at: url)
    }
}

/// What the wizard was asked to make.
struct DevicePlan {
    enum Kind {
        /// Prepare this firmware from its IPSW.
        case firmware(CatalogFirmware)
        /// Unpack the iPod touch the Mac release ships ready-made.
        case readyMade
    }
    var kind: Kind
    var name: String
    /// Prepare the device past Setup Assistant (3.x and later; nothing on 1.x and 2.x).
    var skipSetup: Bool = false
    /// Install Cydia on the device (firmwarekit create --jailbreak). Needs an in-process tar; still experimental on iOS.
    var jailbreak: Bool = false

    static let readyMadeID = "n72ap-7E18"

    var model: DeviceModel {
        switch kind {
        case .firmware(let entry): return DeviceModel(board: entry.board)
        case .readyMade: return DeviceModel(board: "n72ap")
        }
    }

    var packedDevice: URL? { PackedDevice.find().first }

    var needsMacFiles: Bool {
        switch kind {
        case .firmware: return !MacFiles.hasGuestTools || !MacFiles.hasBootROM(model)
        case .readyMade: return packedDevice == nil || !MacFiles.hasBootROM(model)
        }
    }

    var needsIPSW: Bool {
        if case .firmware(let entry) = kind { return !IPSWStore.has(entry) }
        return false
    }

    /// What will be downloaded.
    var downloadBytes: Int64 {
        var total: Int64 = needsMacFiles ? MacFiles.approximateBytes : 0
        if case .firmware(let entry) = kind, needsIPSW { total += entry.source.bytes ?? 0 }
        return total
    }

    /// Free space the whole job wants at its peak (downloads, their unpacked copies, the work files).
    var spaceNeeded: Int64 {
        var total = downloadBytes
        if needsMacFiles { total += MacFiles.approximateBytes }
        switch kind {
        case .firmware(let entry):
            let peak = entry.estimates?.peakBytes ?? 0
            total += peak > 0 ? peak : 2_500_000_000
        case .readyMade:
            total += 1_000_000_000
        }
        return total
    }
}

/// Runs a DevicePlan and tells the wizard how it is going.
@MainActor
final class DeviceCreator: ObservableObject {
    struct Stage: Identifiable {
        enum State { case waiting, running, done, failed }
        let id: String
        let title: String
        var state: State = .waiting
        var detail = ""
        /// 0...1 while it is known.
        var fraction: Double?
    }

    @Published private(set) var stages: [Stage] = []
    @Published private(set) var running = false
    @Published private(set) var failure: String?
    @Published private(set) var finished: DeviceFolder?
    @Published private(set) var warnings: [String] = []
    private var task: Task<Void, Never>?
    private var background: UIBackgroundTaskIdentifier = .invalid

    func start(_ plan: DevicePlan) {
        guard !running else { return }
        var list: [Stage] = []
        if plan.needsMacFiles { list.append(Stage(id: "mac", title: "Getting the Mac files")) }
        switch plan.kind {
        case .firmware(let entry):
            if plan.needsIPSW { list.append(Stage(id: "ipsw", title: "Downloading \(entry.systemName)")) }
            list.append(Stage(id: "prepare", title: "Preparing the device"))
        case .readyMade:
            list.append(Stage(id: "unpack", title: "Unpacking the iPod touch"))
        }
        stages = list
        failure = nil
        finished = nil
        warnings = []
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
        background = UIApplication.shared.beginBackgroundTask(withName: "Preparing a device") { [weak self] in
            Task { @MainActor in self?.endBackground() }
        }
        task = Task { [weak self] in
            do {
                let device = try await Self.run(plan) { id, update in
                    Task { @MainActor in self?.apply(id, update) }
                } warn: { message in
                    Task { @MainActor in self?.warnings.append(message) }
                }
                self?.finish(device: device, error: nil)
            } catch {
                self?.finish(device: nil, error: error)
            }
        }
    }

    func cancel() { task?.cancel() }

    private func endBackground() {
        if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        background = .invalid
    }

    /// One change to a stage, sent from the work thread (a plain value, so it crosses to the main actor safely).
    enum StageUpdate: Sendable {
        case running(detail: String)
        case progress(fraction: Double?, detail: String)
        case done(detail: String)
    }

    private func apply(_ id: String, _ update: StageUpdate) {
        guard running, let index = stages.firstIndex(where: { $0.id == id }) else { return }
        switch update {
        case .running(let detail):
            stages[index].state = .running
            stages[index].detail = detail
            stages[index].fraction = nil
        case .progress(let fraction, let detail):
            stages[index].fraction = fraction.map { min(1, max(0, $0)) }
            stages[index].detail = detail
        case .done(let detail):
            stages[index].state = .done
            stages[index].fraction = nil
            stages[index].detail = detail
        }
    }

    private func finish(device: DeviceFolder?, error: Error?) {
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        endBackground()
        if let device {
            for index in stages.indices { stages[index].state = .done; stages[index].fraction = nil }
            finished = device
            return
        }
        if let index = stages.firstIndex(where: { $0.state == .running }) { stages[index].state = .failed }
        if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
            failure = "Cancelled. Nothing was added."
        } else {
            failure = error?.localizedDescription ?? "It did not work."
        }
    }

    // MARK: - The work (off the main thread)

    private typealias Report = @Sendable (String, StageUpdate) -> Void

    /// Calls through at most a few times a second, so progress from a tight loop does not flood the main thread.
    private final class Throttle: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date.distantPast
        func pass() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let now = Date()
            guard now.timeIntervalSince(last) > 0.12 else { return false }
            last = now
            return true
        }
    }

    /// Where the preparer is: its step count, the current step and its name (written and read on its one thread).
    private final class Steps: @unchecked Sendable {
        var total = 0
        var index = 0
        var name = ""
    }

    private nonisolated static func run(
        _ plan: DevicePlan,
        report: @escaping Report,
        warn: @escaping @Sendable (String) -> Void
    ) async throws -> DeviceFolder {
        let fm = FileManager.default
        let throttle = Throttle()
        func begin(_ id: String, _ detail: String = "") {
            report(id, .running(detail: detail))
        }
        func progress(_ id: String, _ fraction: Double?, _ detail: String, force: Bool = false) {
            guard force || throttle.pass() else { return }
            report(id, .progress(fraction: fraction, detail: detail))
        }
        func done(_ id: String, _ detail: String = "") {
            report(id, .done(detail: detail))
        }

        let free = Transfer.freeSpace()
        if free > 0, free < plan.spaceNeeded {
            throw Transfer.Failure(message:
                "Not enough space: this needs about \(Transfer.format(plan.spaceNeeded)) free, and the phone has \(Transfer.format(free)).")
        }
        Library.ensure(Library.devices)
        Library.ensure(Library.deviceFiles)

        if plan.needsMacFiles {
            begin("mac", "Connecting to GitHub")
            try await MacFiles.install { stage, fraction in
                switch stage {
                case .downloading:
                    progress("mac", fraction < 0 ? nil : fraction * 0.85,
                        fraction < 0 ? "Downloading" : "Downloading \(Transfer.format(Int64(fraction * Double(MacFiles.approximateBytes)))) of \(Transfer.format(MacFiles.approximateBytes))")
                case .checking: progress("mac", 0.85 + fraction * 0.05, "Checking the download")
                case .unpacking: progress("mac", 0.9 + fraction * 0.1, "Unpacking the boot ROMs and guest tools")
                }
            }
            done("mac", "Boot ROMs and guest tools are in place")
        }
        try Task.checkCancellation()

        switch plan.kind {
        case .readyMade:
            guard let packed = plan.packedDevice else {
                throw Transfer.Failure(message: "The Mac release did not contain the ready-made iPod touch.")
            }
            begin("unpack")
            let folder = Library.newDeviceFolder(named: plan.name)
            let base = folder.appendingPathComponent("base", isDirectory: true)
            do {
                try PackedDevice.unpack(itbase: packed, into: base) { progress("unpack", $0, "Writing the device's storage") }
            } catch {
                Library.removeTree(folder)
                throw error
            }
            done("unpack")
            return DeviceFolder(url: folder)

        case .firmware(let entry):
            if plan.needsIPSW {
                begin("ipsw")
                try await IPSWStore.download(entry) { fraction, detail in progress("ipsw", fraction, detail) }
                done("ipsw", "Checked against the catalog")
            }
            try Task.checkCancellation()

            begin("prepare", "Unpacking the guest tools")
            guard OnDevicePrep.available else {
                throw Transfer.Failure(message: "This build of Light Touch cannot prepare firmware. Use the ready-made iPod touch, or a newer build.")
            }
            let tools = try MacFiles.guestToolsDirectory()
            // Preparing/ and Devices/ are on the same volume, so publishing is a rename and the sparse NAND stays sparse.
            let staging = Library.preparing.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let out = staging.appendingPathComponent("base", isDirectory: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            Library.ensure(Library.decrypted)
            defer {
                Library.removeTree(staging)
                Library.removeTree(Library.decrypted)  // decrypted firmware is only needed while preparing
            }
            // The preparer's own notes (what it found, what it left out and why) go to prepare.log in Files.
            let log = Library.documents.appendingPathComponent("prepare.log")
            _ = freopen(log.path, "w", stderr)
            setvbuf(stderr, nil, _IOLBF, 0)

            let steps = Steps()
            // Memory watch: FirmwareKit writes an 8 GiB sparse NAND, with metadata pages in RAM. On the Mac that is
            // free; on iOS a process has a strict memory limit (roughly 1–3 GB before jetsam). When memory climbs
            // the detail line says so, and the thrown error (if we get OOM-killed) will make clear why.
            let memoryWatch = Task {
                while !Task.isCancelled {
                    let used = MemoryStats.footprintMB()
                    if used > 0 { LTMLog.note("prep: \(used) MB in use (step \(steps.index) \(steps.name))") }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            defer { memoryWatch.cancel() }
            do {
                try await OnDevicePrep.create(
                    entryID: entry.id, ipsw: IPSWStore.url(for: entry), out: out, guestTools: tools,
                    cache: Library.decrypted, seed: UUID().uuidString,
                    skipSetup: plan.skipSetup, jailbreak: plan.jailbreak
                ) { event in
                    switch event {
                    case .begin(let total): steps.total = total
                    case .step(let index, let name):
                        steps.index = index
                        steps.name = name
                        let total = max(steps.total, index)
                        progress("prepare", Double(index - 1) / Double(max(total, 1)), "\(index) of \(total): \(name)", force: true)
                    case .progress(let fraction, let detail):
                        let total = max(steps.total, steps.index, 1)
                        let overall = (Double(max(steps.index, 1) - 1) + min(1, max(0, fraction))) / Double(total)
                        let label = detail.map { "\(steps.name) (\($0))" } ?? steps.name
                        progress("prepare", overall, "\(steps.index) of \(total): \(label)")
                    case .warning(let message): warn(message)
                    }
                }
            } catch {
                // A clearer message when it looks like jetsam killed the step mid-way (the preparer throws nothing then;
                // we only land here on a real error, but the memory footprint goes with the message either way).
                let used = MemoryStats.footprintMB()
                let hint = used > 1500 ? " (at \(used) MB in use \u{2014} the phone may have run out of memory for this step)" : ""
                throw Transfer.Failure(message: "\(error.localizedDescription)\(hint)")
            }
            try Task.checkCancellation()
            guard fm.fileExists(atPath: out.appendingPathComponent("device.lock.json").path) else {
                throw Transfer.Failure(message: "The preparer finished without a device (no device.lock.json). See prepare.log in Files.")
            }
            let folder = Library.newDeviceFolder(named: plan.name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: out, to: folder.appendingPathComponent("base", isDirectory: true))
            } catch {
                Library.removeTree(folder)
                throw error
            }
            done("prepare")
            return DeviceFolder(url: folder)
        }
    }
}
