// The Apps inspector's table, without AppKit: which rows it shows (the installed list — pending transfers, then
// the installed apps the search keeps — or the Store's results), what each row shows, what each Store row can
// offer, and how a new set of rows reaches the table without replacing unchanged ones. AppsInspectorViewController
// holds the state and draws it.

import Foundation
import HostServiceWire

/// The inspector's one banner line, derived whenever it may change: the transfer queue paused (Resume beside it)
/// over a stale list's reason, or nothing.
public enum AppsInspectorBanner: Equatable {
    case none
    /// The list is kept but the device stopped answering; why.
    case stale(String)
    case paused

    public init(paused: Bool, stale: String?) { self = paused ? .paused : stale.map(Self.stale) ?? .none }

    public var text: String? {
        switch self {
        case .none: nil
        case .stale(let reason): reason
        case .paused: "Transfers paused"
        }
    }
    /// The paused line is taller: the Resume button sits on it.
    public var height: CGFloat {
        switch self {
        case .none: 0
        case .stale: 18
        case .paused: 28
        }
    }
}

/// The device as the Apps inspector sees it right now.
public struct AppsDevice: Equatable {
    public var id: UUID
    public var canQueueInstall = false
    public var canReachDevice = false
    /// Our own device work holds the guest connection: a job in this device's queue slot, or the controller's install.
    public var installing = false
    public var preparingDevice = false
    public var hasFileTransfer = false
    public var isReconnecting = false
    /// This device's transfer queue is paused after a transport failure.
    public var transfersPaused = false

    public init(
        id: UUID,
        canQueueInstall: Bool = false,
        canReachDevice: Bool = false,
        installing: Bool = false,
        preparingDevice: Bool = false,
        hasFileTransfer: Bool = false,
        isReconnecting: Bool = false,
        transfersPaused: Bool = false
    ) {
        self.id = id
        self.canQueueInstall = canQueueInstall
        self.canReachDevice = canReachDevice
        self.installing = installing
        self.preparingDevice = preparingDevice
        self.hasFileTransfer = hasFileTransfer
        self.isReconnecting = isReconnecting
        self.transfersPaused = transfersPaused
    }

    /// Waiting removals must not suppress recovery: a paused transfer queue can
    /// contain them indefinitely. Only the operation actually owning the guest
    /// connection (or a recovery in progress) needs reads to stand aside.
    public var readsSuppressed: Bool { installing || preparingDevice || hasFileTransfer || isReconnecting }
}

/// What a catalog row can offer right now.
public enum CatalogRowState: Equatable {
    case installable
    /// 0…1, or negative when the total size is unknown (indeterminate).
    case downloading(Double)
    case installing, installed, unavailable
}

/// Which row is which: selection and unchanged views follow this, not the row's index.
public enum AppRowIdentity: Hashable {
    case job(ObjectIdentifier)
    case app(String)
    case catalog(Int)
}

/// Only the values that affect a row's presentation. A device poll or unrelated transfer must not replace
/// buttons under the pointer or reset VoiceOver's current element.
public struct AppRowAppearance: Equatable {
    public enum Kind { case app, install, open, progress, failed, resume }
    public var title: String
    public var subtitle: String
    public var icon: ObjectIdentifier?
    public var kind: Kind = .app
    public var progress: Double?
    public var enabled = true

    public init(
        title: String,
        subtitle: String,
        icon: ObjectIdentifier? = nil,
        kind: Kind = .app,
        progress: Double? = nil,
        enabled: Bool = true
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.kind = kind
        self.progress = progress
        self.enabled = enabled
    }
}

/// The icons rows show, by identity (the app's NSImages): a Store result's, a pending job's best guess and an
/// installed app's.
public struct AppRowIcons {
    public var catalog: (CatalogApp) -> ObjectIdentifier?
    public var pending: (InstallJob) -> ObjectIdentifier?
    public var installed: (String) -> ObjectIdentifier?

    public init(
        catalog: @escaping (CatalogApp) -> ObjectIdentifier? = { _ in nil },
        pending: @escaping (InstallJob) -> ObjectIdentifier? = { _ in nil },
        installed: @escaping (String) -> ObjectIdentifier? = { _ in nil }
    ) {
        self.catalog = catalog
        self.pending = pending
        self.installed = installed
    }
}

/// What a Store row draws: a transfer or removal in flight (the progress row), or the result with its button.
public enum CatalogRowContent {
    case progress(subtitle: String, fraction: Double? = nil, job: InstallJob? = nil)
    case result(button: String, enabled: Bool)
}

/// The inspector's rows over what it knows.
public struct AppsInspectorRows {
    /// The table shows Legacy Store results, not the installed list.
    public var searching: Bool
    public var apps: [InstalledApp]
    public var pending: [InstallJob]
    /// The Installed search field's text.
    public var installedQuery: String
    /// The Store's results, through the filter menu.
    public var catalogResults: [CatalogApp]
    /// Apps with an uninstall in flight, and the one being removed now.
    public var uninstalling: Set<String>
    public var removingApp: String?
    public var device: AppsDevice
    /// An installed app's name as the list shows it (the cached display name, else the reported one).
    public var displayName: (InstalledApp) -> String
    public var icons: AppRowIcons

    public init(
        searching: Bool,
        apps: [InstalledApp] = [],
        pending: [InstallJob] = [],
        installedQuery: String = "",
        catalogResults: [CatalogApp] = [],
        uninstalling: Set<String> = [],
        removingApp: String? = nil,
        device: AppsDevice,
        displayName: @escaping (InstalledApp) -> String = { $0.name },
        icons: AppRowIcons = AppRowIcons()
    ) {
        self.searching = searching
        self.apps = apps
        self.pending = pending
        self.installedQuery = installedQuery
        self.catalogResults = catalogResults
        self.uninstalling = uninstalling
        self.removingApp = removingApp
        self.device = device
        self.displayName = displayName
        self.icons = icons
    }

    /// Any device operation of ours in flight.
    public var busyWithDevice: Bool { device.installing || !uninstalling.isEmpty }

    /// The installed apps actually shown. An app being replaced by a newer
    /// build is hidden while its pending row is up — otherwise a reinstall
    /// lists the same app twice, once installing and once as the old version,
    /// and the old row's Uninstall would remove what is being installed.
    public var visibleApps: [InstalledApp] {
        let replacing = Set(pending.compactMap { $0.isFinished ? nil : $0.bundleID })
        let query = installedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return apps.filter {
            !replacing.contains($0.id)
                && (query.isEmpty || displayName($0).localizedStandardContains(query)
                    || $0.id.localizedStandardContains(query))
        }
    }

    public var rowCount: Int { searching ? catalogResults.count : pending.count + visibleApps.count }

    /// The installed app on this row. Catalog mode: the rows are CatalogApps, and every installed-list
    /// interaction that resolves a row through here (uninstall, reorder, context menu) must come up empty.
    public func app(at row: Int) -> InstalledApp? {
        guard !searching else { return nil }
        let index = row - pending.count
        let shown = visibleApps
        return shown.indices.contains(index) ? shown[index] : nil
    }

    /// Every selected installed app — pending rows and catalog rows resolve to nil through app(at:) and drop out.
    public func selectedApps(_ rows: IndexSet) -> [InstalledApp] { rows.compactMap { app(at: $0) } }

    public func canUninstall(_ selection: [InstalledApp]) -> Bool {
        device.canQueueInstall && !selection.isEmpty && !selection.contains { uninstalling.contains($0.id) }
    }

    public func removalStatus(for bundleID: String) -> String {
        if removingApp == bundleID { return "Removing…" }
        return device.transfersPaused ? "Removal paused" : "Waiting to remove…"
    }

    /// The job working on this catalog app, if one is. Matched by the copy's
    /// own id first, then bundle id (a local .ipa install of the same app
    /// counts too). Failed and cancelled jobs don't claim the row — the user
    /// should be able to try again.
    public func catalogJob(for app: CatalogApp) -> InstallJob? {
        pending.first { job in
            guard !job.failed, !job.isCancelled else { return false }
            if job.catalogIpaID == app.ipaID { return true }
            return job.bundleID != nil && job.bundleID == app.bundleID
        }
    }

    /// Is this catalog app already on the device, or on its way there?
    public func catalogState(of app: CatalogApp) -> CatalogRowState {
        if let job = catalogJob(for: app) {
            // A cleanly finished job reads as installed even before the device
            // lists it — otherwise Install flashed back for the second between
            // the install completing and installd admitting the app exists.
            if job.isFinished { return .installed }
            if let fraction = job.downloadProgress { return .downloading(fraction) }
            return .installing
        }
        if let id = app.bundleID, apps.contains(where: { $0.id == id }) { return .installed }
        if app.incompatibility != nil { return .unavailable }  // grayed, with the server's reason
        // Busy with our own install means the device is fine, just serialized —
        // more jobs may queue behind it. (The poll deliberately parks
        // deviceReachable at nil while device work runs, so canReachDevice
        // alone would disable every Install button for the whole install.)
        if device.canQueueInstall { return .installable }
        return .unavailable
    }

    /// The failed job for a Store row (by copy or bundle id) that still offers Retry.
    private func failedJob(for app: CatalogApp) -> InstallJob? {
        pending.last {
            $0.failed && !$0.dismissed
                && ($0.catalogIpaID == app.ipaID || ($0.bundleID != nil && $0.bundleID == app.bundleID))
        }
    }

    /// Whether the installed app a Store row stands for can open now.
    private func canOpen(_ app: CatalogApp) -> Bool {
        device.canReachDevice && !busyWithDevice && apps.contains { $0.id == app.bundleID }
    }

    /// What a Store row draws. In-flight states use the same row the installed list uses for its own pending
    /// work, so the two modes can never drift apart visually.
    public func catalogRow(for app: CatalogApp) -> CatalogRowContent {
        if let bundleID = app.bundleID, uninstalling.contains(bundleID) {
            return .progress(subtitle: removalStatus(for: bundleID))
        }
        if let failed = failedJob(for: app) { return .progress(subtitle: failed.status, job: failed) }
        switch catalogState(of: app) {
        case .downloading(let fraction):
            return .progress(
                subtitle: catalogJob(for: app)?.status ?? "Downloading…",
                fraction: fraction,
                job: catalogJob(for: app)
            )
        case .installing:
            return .progress(subtitle: catalogJob(for: app)?.status ?? "Installing…", job: catalogJob(for: app))
        case .installed: return .result(button: "Open", enabled: canOpen(app))
        case .installable: return .result(button: "Install", enabled: true)
        // The device can't take an install right now (booting, or gone) — same gate as every other install entry point.
        case .unavailable: return .result(button: "Install", enabled: false)
        }
    }

    public var identities: [AppRowIdentity] {
        if searching { return catalogResults.map { .catalog($0.ipaID) } }
        return pending.map { .job(ObjectIdentifier($0)) } + visibleApps.map { .app($0.id) }
    }

    public var appearances: [AppRowAppearance] {
        func transfer(_ job: InstallJob, icon: ObjectIdentifier?) -> AppRowAppearance {
            AppRowAppearance(
                title: job.name,
                subtitle: job.isCancelled ? "Cancelling…" : job.status,
                icon: icon,
                kind: job.failed ? .failed : job.status == "Paused" ? .resume : .progress,
                progress: job.downloadProgress,
                enabled: job.failed || job.isCancellable
            )
        }
        if searching {
            return catalogResults.map { app in
                let icon = icons.catalog(app)
                if let id = app.bundleID, uninstalling.contains(id) {
                    return AppRowAppearance(
                        title: app.name,
                        subtitle: removalStatus(for: id),
                        icon: icon,
                        kind: .progress
                    )
                }
                if let failed = failedJob(for: app) { return transfer(failed, icon: icon) }
                let state = catalogState(of: app)
                if let job = catalogJob(for: app), !job.isFinished { return transfer(job, icon: icon) }
                return AppRowAppearance(
                    title: app.name,
                    subtitle: app.subtitle,
                    icon: icon,
                    kind: state == .installed ? .open : .install,
                    enabled: state == .installed ? canOpen(app) : state == .installable
                )
            }
        }
        let transfers = pending.map { job in
            if job.isFinished, !job.isCancelled, !job.failed {
                return AppRowAppearance(
                    title: job.name,
                    subtitle: job.bundleID ?? job.status,
                    icon: job.bundleID.flatMap(icons.installed)
                )
            }
            return transfer(job, icon: icons.pending(job))
        }
        return transfers
            + visibleApps.map { app in
                AppRowAppearance(
                    title: displayName(app),
                    subtitle: uninstalling.contains(app.id) ? removalStatus(for: app.id) : app.version,
                    icon: icons.installed(app.id),
                    kind: uninstalling.contains(app.id) ? .progress : .app
                )
            }
    }

    /// What the installed list's placeholder should say right now — for
    /// restoring it when a search is cleared. The poll re-corrects within a
    /// tick if this guesses wrong.
    public func installedPlaceholder(haveLoaded: Bool) -> String? {
        if !haveLoaded { return pending.isEmpty ? "Waiting for the device…" : nil }
        return visibleApps.isEmpty && pending.isEmpty
            ? (installedQuery.isEmpty ? "No apps installed" : "No matching apps") : nil
    }
}

/// The rows on screen, and how the next set reaches the table: with the same rows in the same order, only those
/// whose appearance changed reload (an unchanged background poll leaves native views and accessibility intact);
/// otherwise the table reloads and the selection follows the rows it was on.
public struct AppTableRows {
    public private(set) var identities: [AppRowIdentity] = []
    public private(set) var appearances: [AppRowAppearance] = []

    public enum Reload: Equatable {
        case rows(IndexSet)
        case table(selecting: IndexSet)
    }

    public init() {}

    /// Show these rows; nil when nothing on screen changes. `selected` is the table's selection now.
    public mutating func show(_ identities: [AppRowIdentity], _ appearances: [AppRowAppearance], selected: IndexSet)
        -> Reload?
    {
        if identities == self.identities {
            let changed = IndexSet(
                appearances.indices.filter {
                    !self.appearances.indices.contains($0) || appearances[$0] != self.appearances[$0]
                }
            )
            self.appearances = appearances
            return changed.isEmpty ? nil : .rows(changed)
        }
        let kept = Set(selected.compactMap { self.identities.indices.contains($0) ? self.identities[$0] : nil })
        self.identities = identities
        self.appearances = appearances
        return .table(selecting: IndexSet(identities.indices.filter { kept.contains(identities[$0]) }))
    }
}

/// The inspector's words that depend only on what it knows.
public enum AppsInspector {
    /// What a read does to a transfer's row (`pendingRow`).
    public enum PendingRow: Equatable {
        case keep
        case drop
        /// Keep it, and ask the device once more after this many seconds.
        case reread(after: TimeInterval)
    }

    /// A finished install's row stays until the device lists its app: instproxy doesn't list a new app the instant
    /// the install returns, and dropping the row then left the app looking vanished. Its age bounds it: from 20 s
    /// the device is asked again, once per row (`rereadAsked`), where every read after that asked for another
    /// back to back for the next 40 s; at 60 s it goes anyway. A failed row stays for its Retry; a cancelled or
    /// dismissed one goes, as does one whose app was never named once 15 s have passed.
    public static func pendingRow(
        _ job: InstallJob,
        listed: (String) -> Bool,
        rereadAsked: Bool,
        now: Date = Date()
    ) -> PendingRow {
        if job.dismissed { return .drop }
        guard job.isFinished else { return .keep }
        if job.failed { return .keep }
        if job.isCancelled { return .drop }
        let age = now.timeIntervalSince(job.finishedAt ?? now)
        guard let id = job.bundleID else { return age > 15 ? .drop : .keep }
        if listed(id) || age > 60 { return .drop }
        return rereadAsked ? .keep : .reread(after: max(0, 20 - age))
    }

    public static func freshnessText(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "not yet refreshed" }
        guard now.timeIntervalSince(date) >= 60 else { return "last updated just now" }
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
        return "last updated \(relative)"
    }

    /// The Store's placeholder while a search for `query` starts: iPhone OS 1 predates the App Store (Legacy
    /// Store's suggested list is empty for it by definition, which read as the store being broken; a search still
    /// runs and says why each app can't install); cached rows stay usable while their refresh is in flight.
    public static func searchStarting(query: String, iosVersion: String, haveResults: Bool) -> String? {
        if query.isEmpty, iosVersion.compare("2.0", options: .numeric) == .orderedAscending {
            return "iPhone OS \(iosVersion) has no App Store."
        }
        return haveResults ? nil : query.isEmpty ? "Loading Legacy Store…" : "Searching Legacy Store…"
    }

    /// Whether the search for an empty query runs at all (see searchStarting).
    public static func searchRuns(query: String, iosVersion: String) -> Bool {
        !(query.isEmpty && iosVersion.compare("2.0", options: .numeric) == .orderedAscending)
    }

    /// The Store's placeholder once `fetched` arrived, of which `shown` pass the filter.
    public static func searchFinished(query: String, fetched: Int, shown: Int) -> String? {
        if fetched == 0 {
            return query.isEmpty ? "Legacy Store is empty right now." : "No compatible apps found for “\(query)”."
        }
        return shown == 0 ? "No apps match the filter." : nil
    }

    /// The Store's placeholder when the search failed: Legacy Store's own errors say it plainly; a network
    /// error needs the name.
    public static func searchFailed(_ error: Error, marketingName: String) -> String {
        if case CatalogError.unsupportedDevice = error {
            return CatalogError.unsupportedDevice(name: marketingName).localizedDescription
        }
        return error is CatalogError
            ? error.localizedDescription : "Couldn’t reach Legacy Store — \(error.localizedDescription)"
    }

    /// Which of the placeholder's buttons show: Browse Store and Install App… under an empty installed list,
    /// Retry under a failed Store search; the group hides with the message or when it has nothing to offer.
    public struct PlaceholderActions: Equatable {
        public var browseAndInstall: Bool, retry: Bool, group: Bool
    }
    public static func placeholderActions(
        message: String?,
        searching: Bool,
        haveLoaded: Bool,
        nothingListed: Bool,
        catalogFailed: Bool
    ) -> PlaceholderActions {
        let empty = !searching && haveLoaded && nothingListed
        return PlaceholderActions(
            browseAndInstall: empty,
            retry: catalogFailed && searching,
            group: message != nil && (empty || (catalogFailed && searching))
        )
    }

    /// Files dropped on the canvas have no Store row to carry their progress: such a transfer is revealed in
    /// the installed list at once, even when the inspector was closed or showing the Store.
    public static func revealsTransfer(_ job: InstallJob) -> Bool { job.catalogIpaID == nil }
}
