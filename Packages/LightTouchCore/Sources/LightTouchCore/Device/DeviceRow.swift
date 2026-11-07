// What the sidebar row, its context menu, the Device menu and the placeholder show for one catalog entry,
// from the record and what the sessions say about it. Pure Foundation; DeviceRowTests covers it.

import FirmwareSchema
import Foundation
import HostRuntime

// MARK: - Row state

/// A command the sidebar, its context menu, the Device menu and the
/// placeholder offer for one catalog entry.
/// `stop` is Shut Down (the guest powers itself off); `forceStop` the hard halt.
public nonisolated enum DeviceAction: CaseIterable, Sendable {
    case start, stop, forceStop, downloadAndPrepare, importIPSW, cancel, erase, showInFinder, delete, prepareAgain
    case openFilesystem, commitFilesystem, discardFilesystem, recoverFilesystem
    /// What the Jailbreak option adds, on a prepared device FirmwareJobs.jailbreakWorks allows that is stopped (DeviceFilesystemEdits).
    case jailbreak
}

/// A command on several sidebar rows at once: the rows the one-row command allows (`targets`), the rest left as they
/// are (`skipped`), and its title, which says how many it acts on. Several-row Delete is the sidebar's own Batch.
public nonisolated struct DeviceBatch<Item> {
    /// The commands several rows take, with their titles' verbs; the ones that ask first end in an ellipsis.
    static var verbs: [DeviceAction: String] {
        [
            .start: "Start", .forceStop: "Force Stop", .jailbreak: "Jailbreak", .erase: "Erase"
        ]
    }
    public let action: DeviceAction
    public let targets: [Item]
    public let skipped: [Item]

    /// Nil for a command that acts on one row only.
    public init?(_ action: DeviceAction, _ items: [Item], allows: (Item) -> Bool) {
        guard Self.verbs[action] != nil else { return nil }
        self.action = action
        targets = items.filter(allows)
        skipped = items.filter { !allows($0) }
    }

    public var isEnabled: Bool { !targets.isEmpty }
    /// Start 3 Devices, Force Stop 1 Device…, Erase Devices… (dimmed: none qualifies).
    public var title: String {
        let count = targets.count
        let noun = count == 0 ? "Devices" : count == 1 ? "1 Device" : "\(count) Devices"
        return "\(Self.verbs[action] ?? "") \(noun)" + (action == .start ? "" : "…")
    }
}

/// A download or preparation in flight for a catalog entry (FirmwareJobs).
/// `remaining` is the estimated seconds left for the whole job (the download and the preparation after it), nil until
/// there is one; `files` is how many IPSWs the one job fetches (2 for a build that boots its sibling's ramdisk),
/// `fraction` all of them; `mirror` the host it comes from when that isn't Apple's (archive.org, a mirror);
/// `speed` bytes per second, once measured.
public nonisolated enum FirmwareJob: Equatable, Sendable {
    case downloading(
        fraction: Double,
        remaining: TimeInterval? = nil,
        files: Int = 1,
        mirror: String? = nil,
        speed: Double? = nil
    )
    case preparing(Preparation)
    case failed(String)

    /// A download host the user should hear about ("archive.org"); nil for Apple's own.
    public static func thirdParty(_ host: String) -> String? {
        host == "apple.com" || host.hasSuffix(".apple.com") ? nil : host
    }

    /// The job's one bar, as its row shows it (DeviceRow.progress); nil for a failure or no fraction yet.
    public var progress: Double? {
        switch self {
        case .downloading(let fraction, _, _, _, _): fraction / 2
        case .preparing(let p): p.bar
        case .failed: nil
        }
    }

    /// The Dock's bar: every running job's, averaged; nil when none is running.
    public static func dockProgress(_ jobs: some Collection<FirmwareJob>) -> Double? {
        let running = jobs.filter { if case .failed = $0 { false } else { true } }
        guard !running.isEmpty else { return nil }
        return running.map { $0.progress ?? 0 }.reduce(0, +) / Double(running.count)
    }
}

/// Where a preparation stands (the preparer contract's begin, step and progress events).
public nonisolated struct Preparation: Equatable, Sendable {
    public init(
        step: Int = 0,
        steps: Int = 0,
        name: String,
        fraction: Double = 0.0,
        seconds: [Double] = [],
        detail: String? = nil,
        remaining: TimeInterval? = nil,
        startsAt: Double = 0.0
    ) {
        self.step = step
        self.steps = steps
        self.name = name
        self.fraction = fraction
        self.seconds = seconds
        self.detail = detail
        self.remaining = remaining
        self.startsAt = startsAt
    }
    /// 1-based; 0 of 0 is a job with no steps yet (hashing an import).
    public var step = 0, steps = 0
    public var name: String
    /// Within the step, 0...1.
    public var fraction = 0.0
    /// The preparer's expected seconds per step; equal steps without them.
    public var seconds: [Double] = []
    /// The preparer's words for what the step is doing now.
    public var detail: String?
    public var remaining: TimeInterval?
    /// Where the preparation starts on the job's one bar: 0.5 after a download (the first half), else 0.
    public var startsAt = 0.0

    /// Its part of the job's one bar (DeviceRow.progress).
    public var bar: Double? { overall.map { startsAt + (1 - startsAt) * $0 } ?? (startsAt > 0 ? startsAt : nil) }

    /// Finished steps plus this one's fraction, weighted by expected seconds; nil with no steps yet.
    public var overall: Double? {
        guard steps > 0 else { return nil }
        let weights =
            seconds.count == steps && seconds.allSatisfy({ $0 > 0 }) ? seconds : Array(repeating: 1, count: steps)
        let done = weights.prefix(min(max(step - 1, 0), steps)).reduce(0, +)
        let current = (1...steps).contains(step) ? weights[step - 1] * min(max(fraction, 0), 1) : 0
        return min(1, (done + current) / weights.reduce(0, +))
    }
}

/// Seconds left for a job that went from `start` to `now` (0...1) in `elapsed` seconds; nil until
/// it has run 5 s and moved 2 %, so the first guesses don't swing.
public nonisolated func estimatedRemaining(elapsed: TimeInterval, from start: Double, to now: Double) -> TimeInterval? {
    guard elapsed >= 5, now - start >= 0.02 else { return nil }
    return elapsed * (1 - now) / (now - start)
}

/// A started device, as the sidebar sees it.
public nonisolated enum SessionPhase: Equatable, Sendable {
    case running, stopping, stopped
    case dead(String)
}

public nonisolated enum DeviceRowState: Equatable, Sendable {
    public enum Unavailable: Equatable, Sendable { case comingSoon, requiresIPSW }
    case notDownloaded(bytes: Int64?)
    /// Its IPSW is in a store (downloaded or imported), not yet prepared.
    case downloaded
    /// The app ships its prepared base (`entry.bundled`), not yet unpacked.
    case bundled
    case downloading(
        fraction: Double,
        remaining: TimeInterval? = nil,
        files: Int = 1,
        mirror: String? = nil,
        speed: Double? = nil
    )
    case preparing(Preparation)
    case ready, running, stopping
    /// Its storage is being removed (DeviceStorageWork); the row leaves when that's done.
    case deleting
    /// A device with no running session is being erased (DeviceStorageWork).
    case erasing
    case error(String)
    case unavailable(Unavailable)
}

/// One sidebar row: a catalog entry and what the library, the jobs and the
/// sessions say about it.
public nonisolated struct DeviceRow: Equatable, Sendable {
    /// Work on a device's storage while it has no running session (DeviceStorageWork): the row offers nothing that
    /// would touch it until that's done.
    public enum Busy: Equatable, Sendable { case deleting, erasing }

    public let entry: FirmwareCatalog.Entry
    public let instanceID: UUID?
    public let hasSession: Bool
    public let state: DeviceRowState
    /// The device's lock records no activation (DeviceInstance.lockLacksActivation).
    public let preparedWithoutActivation: Bool
    /// The device's base was made by a recipe older than its catalog entry's (`baseRecipe` below the entry's
    /// recipe.version): Erase keeps the old base, so only preparing it again brings the fix.
    public let preparedByOlderRecipe: Bool

    /// `downloaded`: IPSWStore has this entry's IPSW. `baseRecipe`: DeviceRow.baseRecipeVersion of the device's lock.
    /// `busy`: DeviceStorageWork is deleting or erasing the device.
    public init(
        entry: FirmwareCatalog.Entry,
        instanceID: UUID?,
        session: SessionPhase?,
        job: FirmwareJob?,
        downloaded: Bool = false,
        preparedWithoutActivation: Bool = false,
        baseRecipe: Int? = nil,
        busy: Busy? = nil
    ) {
        self.entry = entry
        self.instanceID = instanceID
        self.preparedWithoutActivation = preparedWithoutActivation
        preparedByOlderRecipe = instanceID != nil && baseRecipe.map { $0 < entry.recipe?.version ?? 0 } ?? false
        hasSession = session != nil
        state =
            switch busy {
            case .deleting?: .deleting
            case .erasing?: .erasing
            case nil:
                Self.state(
                    entry: entry,
                    startable: instanceID != nil,
                    session: session,
                    job: job,
                    downloaded: downloaded
                )
            }
    }

    /// A session outranks everything; then the catalog's own verdict, a job
    /// in flight, and finally whether a device exists.
    private static func state(
        entry: FirmwareCatalog.Entry,
        startable: Bool,
        session: SessionPhase?,
        job: FirmwareJob?,
        downloaded: Bool
    ) -> DeviceRowState {
        switch session {
        case .running?: return .running
        case .stopping?: return .stopping
        case .dead(let reason)?: return .error(reason)
        case .stopped?: return .ready
        case nil: break
        }
        if entry.status == .comingSoon { return .unavailable(.comingSoon) }
        switch job {
        case .downloading(let fraction, let remaining, let files, let mirror, let speed)?:
            return .downloading(fraction: fraction, remaining: remaining, files: files, mirror: mirror, speed: speed)
        case .preparing(let preparation)?: return .preparing(preparation)
        case .failed(let reason)?: return .error(reason)
        case nil: break
        }
        if startable { return .ready }
        if entry.bundled != nil { return .bundled }
        if downloaded { return .downloaded }
        return entry.status == .userIPSW ? .unavailable(.requiresIPSW) : .notDownloaded(bytes: entry.source.bytes)
    }

    public var title: String { "iOS \(entry.version)" }
    public var isExperimental: Bool { entry.status == .experimental }
    /// The tag beside the title, in secondary text: a developer build's "beta 3"/"GM 1". How well a build is
    /// tested isn't the row's to shout: that is `supportNote`, in the tooltip, VoiceOver and the placeholder's popover.
    public var badge: String? { entry.prereleaseBadge }
    public var supportNote: String? { entry.status == .untested ? "Untested" : isExperimental ? "Experimental" : nil }
    public var isStartable: Bool { instanceID != nil }
    public var isDimmed: Bool { if case .unavailable = state { true } else { false } }
    public var isError: Bool { if case .error = state { true } else { false } }
    /// The job's one bar: a download fills the first half and the preparation after it the second (a preparation
    /// with no download before it, the whole bar); nil while a job with no download has no steps yet.
    public var progress: Double? {
        switch state {
        case .downloading(let fraction, _, _, _, _): fraction / 2
        case .preparing(let p): p.bar
        default: nil
        }
    }

    /// VoiceOver's words for the ring: "43%"; nil while there is no fraction yet (the ring spins).
    public var progressSummary: String? { progress.map { "\(Int(($0 * 100).rounded(.down)))%" } }

    /// What the sidebar shows after the title. Only what differs from the usual: a downloaded, built-in or
    /// ready build shows nothing; one that isn't here yet shows a download glyph (its size is in VoiceOver).
    public enum Accessory: Equatable, Sendable {
        /// `stopping`: an indeterminate ring (stopping, deleting).
        case none, notDownloaded, running, stopping, error
        /// The ring alone: its fraction, or spinning while there is none.
        case progress(Double?)
        case text(String)
    }
    public var accessory: Accessory {
        switch state {
        case .notDownloaded: .notDownloaded
        case .downloaded, .bundled, .ready: .none
        case .downloading, .preparing: .progress(progress)
        case .running: .running
        case .stopping, .deleting, .erasing: .stopping
        case .error: .error
        case .unavailable(.comingSoon): .text("Coming soon")
        case .unavailable(.requiresIPSW): .text("Requires an IPSW")
        }
    }

    /// The placeholder's headline over the bar: the stage ("Downloading from archive.org…", the preparer's step
    /// "Decrypting…"); nil outside a job.
    public var progressHeadline: String? {
        switch state {
        case .downloading(_, _, _, let mirror, _): mirror.map { "Downloading from \($0)…" } ?? "Downloading…"
        case .preparing(let p): p.steps > 0 && !p.name.isEmpty ? p.name + "…" : "Preparing…"
        default: nil
        }
    }

    /// The line under the bar: the percent, the time left and, for a slow or long download, its speed
    /// ("43% — About 12 minutes remaining — 1.2 MB/s"); nil outside a job.
    public var progressLine: String? {
        let remaining: TimeInterval?
        let speed: Double?
        switch state {
        case .downloading(_, let r, _, _, let s): (remaining, speed) = (r, s)
        case .preparing(let p): (remaining, speed) = (p.remaining, nil)
        default: return nil
        }
        // Slow: under ~2 MB/s, or long: more than 10 minutes to go.
        let showSpeed = speed.map { $0 < 2_000_000 || (remaining ?? 0) > 600 } ?? false
        let parts = [
            progressSummary, remaining.map(Self.remainingText),
            showSpeed
                ? speed.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + "/s" } : nil
        ]
        let line = parts.compactMap { $0 }.joined(separator: " — ")
        return line.isEmpty ? nil : line
    }

    /// What the job is doing inside, for the bar's tooltip only: the preparer's step and its words, or the IPSW count
    /// and the third-party mirror it comes from.
    public var progressDetail: [String] {
        switch state {
        case .downloading(_, _, let files, let mirror, _):
            (files > 1 ? ["\(files) IPSWs"] : []) + (mirror.map { ["From \($0), a third-party mirror"] } ?? [])
        case .preparing(let p) where p.steps > 0:
            ["Step \(p.step) of \(p.steps): \(p.name)", p.detail].compactMap { $0 }
        case .preparing(let p): [p.name]
        default: []
        }
    }

    /// "Untested." or "Experimental." and the catalog's note (source); the placeholder shows its ⓘ when there is one.
    public var catalogNote: String? {
        let tag = entry.status == .untested ? "Untested." : isExperimental ? "Experimental." : nil
        let text = [tag, entry.statusNote].compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// What `supportNote` means, the line under it in the ⓘ popover.
    public var supportExplanation: String? {
        switch entry.status {
        case .untested: "Light Touch hasn’t run this build yet. It may not prepare or start."
        case .experimental:
            "This build prepares and starts, but it hasn’t been through every check. Some features may not work."
        default: nil
        }
    }

    /// "Released June 7, 2011", from the catalog's `released` date.
    public var releaseLine: String? {
        guard let released = entry.released, let date = try? Date(released + "T12:00:00Z", strategy: .iso8601) else {
            return nil
        }
        return "Released "
            + date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt))
    }

    /// Before a download or preparation, when `available` bytes can't hold it: the copy's words; nil when there is room.
    public func spaceShortage(available: Int64) -> String? {
        let download: Int64 = if case .notDownloaded(let bytes) = state { bytes ?? 0 } else { 0 }
        let needed = download + entry.estimates.peakBytes
        guard [.downloaded, .bundled].contains(state) || download > 0, needed > available else { return nil }
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return "Not enough disk space: this needs \(format(needed)), and \(format(available)) is available."
    }

    public static func remainingText(_ seconds: TimeInterval) -> String {
        guard seconds >= 10 else { return "Almost done…" }
        // Rounded to tens of seconds under a minute, whole minutes under 90, then hours.
        let (rounded, unit): (TimeInterval, NSCalendar.Unit) =
            switch seconds {
            case ..<60: ((seconds / 10).rounded(.up) * 10, .second)
            case ..<5400: ((seconds / 60).rounded() * 60, .minute)
            default: ((seconds / 3600).rounded() * 3600, .hour)
            }
        let format = DateComponentsFormatter()
        format.unitsStyle = .full
        format.allowedUnits = unit
        format.includesApproximationPhrase = true
        format.includesTimeRemainingPhrase = true
        return format.string(from: rounded) ?? "Almost done…"
    }

    /// `canDownload` is FirmwareJobs.canDownload: whether the preparer is present.
    private var working: Bool {
        switch state {
        case .downloading, .preparing, .stopping, .deleting, .erasing: true
        default: false
        }
    }

    /// Whether the sidebar may drop this row now: a prepared device when it may be deleted (which asks first),
    /// any other when nothing is running or in flight for it.
    public var canRemoveFromSidebar: Bool {
        instanceID != nil ? allows(.delete, canDownload: false) : !hasSession && !working
    }

    /// A prepared device's data goes with it, after asking; a row with nothing on disk just leaves the list.
    public var removeTitle: String { instanceID != nil ? "Delete Device…" : "Remove Device" }

    public func allows(_ action: DeviceAction, canDownload: Bool) -> Bool {
        switch action {
        // A dead session's Start is a restart (DeviceSessionHost.restart).
        case .start: return isStartable && (state == .ready || isError)
        case .stop: return state == .running
        // Also while stopping: a Shut Down the guest doesn't finish.
        case .forceStop: return state == .running || state == .stopping
        case .downloadAndPrepare:
            return canDownload && !isStartable && !working && !isDimmed
        case .importIPSW:
            return !isStartable && entry.status != .comingSoon && !working
        case .cancel: return !hasSession && primaryAction == .cancel
        case .erase: return instanceID != nil && !working
        case .openFilesystem, .commitFilesystem, .discardFilesystem, .recoverFilesystem:
            return instanceID != nil && !working && state != .running && state != .stopping
        case .jailbreak:
            return FirmwareJobs.jailbreakWorks(entry) && allows(.openFilesystem, canDownload: canDownload)
        case .showInFinder: return instanceID != nil && state != .deleting
        // Also with a shut-down or dead session: it lets go of the storage first (DeviceSessionHost.delete).
        case .delete: return instanceID != nil && !working && state != .running
        case .prepareAgain: return preparedByOlderRecipe && canDownload && allows(.delete, canDownload: canDownload)
        }
    }

    /// The placeholder's one button.
    public var primaryAction: DeviceAction? {
        switch state {
        case .ready: .start
        case .notDownloaded, .downloaded, .bundled: .downloadAndPrepare
        case .downloading, .preparing: .cancel
        case .error:
            isStartable ? .start : entry.status == .userIPSW && entry.bundled == nil ? .importIPSW : .downloadAndPrepare
        case .unavailable(.requiresIPSW): .importIPSW
        case .unavailable(.comingSoon), .running, .stopping, .deleting, .erasing: nil
        }
    }

    public var primaryTitle: String? {
        if isError { return "Try Again" }
        return switch primaryAction {
        case .start: "Start"
        case .downloadAndPrepare: prepareTitle
        case .importIPSW: "Import IPSW…"
        case .cancel: "Cancel"
        default: nil
        }
    }

    /// Download and Prepare's name in every menu: Prepare once the IPSW is here.
    public var prepareTitle: String { state == .downloaded || state == .bundled ? "Prepare" : "Download and Prepare" }
    /// Cancel's name in every menu: what it cancels.
    public var cancelTitle: String { if case .preparing = state { "Cancel Preparation" } else { "Cancel Download" } }

    /// The row's note beside a quiet accessory: a device prepared without activation says so.
    public var note: String? { preparedWithoutActivation && instanceID != nil ? "Prepared without activation" : nil }

    /// The placeholder's line for a base made by an older recipe, beside Prepare Again.
    public var olderRecipeNote: String? {
        preparedByOlderRecipe
            ? "This \(entry.profile?.shortName ?? "device") was prepared by an older version of Light Touch." : nil
    }

    /// The recipe version that made a base: firmwarekit's lock keeps the catalog entry it was prepared from
    /// (`entry.content.recipe.version`, every lock since the first firmwarekit). Nil for an unreadable lock or one
    /// without it (a device.py base): nothing to claim. `device`: the device's directory, whose
    /// FirmwareWire.migratedRecipeFile raises it to the recipe boot admission migrated its storage to, and
    /// FirmwareWire.admissionRecipeSteps to the one admission will migrate it to at its next start.
    public static func baseRecipeVersion(_ url: URL, device: URL? = nil) -> Int? {
        let lock = (try? DeviceLock.read(url)) ?? nil
        guard let version = lock?.recipeVersion else { return nil }
        let migrated =
            device.flatMap { try? Data(contentsOf: $0.appendingPathComponent(FirmwareWire.migratedRecipeFile)) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["recipe"] as? Int
        return FirmwareWire.admittedRecipe(max(version, migrated ?? 0), board: lock?.entryBoard)
    }

    /// The accessory's words: what VoiceOver reads after the version.
    public var stateDescription: String {
        switch state {
        case .notDownloaded(let bytes):
            bytes.map { "Not downloaded, " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                ?? "Not downloaded"
        case .downloaded: "Downloaded"
        case .bundled: "Built in"
        case .downloading: "Downloading" + (progressSummary.map { ", " + $0 } ?? "…")
        case .preparing: "Preparing" + (progressSummary.map { ", " + $0 } ?? "…")
        case .ready: "Ready"
        case .running: "Running"
        case .stopping: "Stopping"
        case .deleting: "Deleting"
        case .erasing: "Erasing"
        case .error: "Error"
        case .unavailable(.comingSoon): "Coming soon"
        case .unavailable(.requiresIPSW): "Requires an IPSW"
        }
    }
}

/// What a device's base lock tells its row (DeviceRow's preparedWithoutActivation and baseRecipe), read once per base:
/// a published base doesn't change, a new storage generation is another base path, and `forget` (a boot that admitted
/// another generation or migrated it) reads every lock again.
@MainActor public final class BaseLockFacts {
    public struct Facts: Equatable, Sendable {
        public let lacksActivation: Bool
        public let recipe: Int?
    }
    private var known: [String: Facts] = [:]
    public init() {}

    /// `device`: the device's directory, for its migrated recipe (DeviceRow.baseRecipeVersion).
    public func facts(base: URL, device: URL) -> Facts {
        if let facts = known[base.path] { return facts }
        let lock = base.appendingPathComponent(DeviceLock.fileName)
        let facts = Facts(
            lacksActivation: DeviceInstance.lockLacksActivation(lock),
            recipe: DeviceRow.baseRecipeVersion(lock, device: device)
        )
        known[base.path] = facts
        return facts
    }

    public func forget() { known.removeAll() }
}
