// The Apps menu (the menu bar's, over the selected row) and a row's context menu (over the clicked row), without
// AppKit: which items, in what order, enabled when. AppsInspectorViewController turns them into NSMenuItems.

import Foundation
import HostServiceWire

public struct AppsMenuItem {
    public enum Action {
        case installApp, importMedia, resumeTransfers, refresh
        case install(CatalogApp)
        case installBatch([CatalogApp])
        case chooseVersion(CatalogApp)
        case viewOnLegacyStore(CatalogApp)
        case cancelInstall(InstallJob)
        case dismissInstall(InstallJob)
        case open(InstalledApp)
        case uninstall([InstalledApp])
        case showInLegacyStore(InstalledApp)
        /// This device's retained copy, queued on another running device.
        case installOn(file: URL, device: AnyObject)
        /// A title with nothing behind it (dimmed placeholders, the Install on ▸ parent).
        case none
        case separator
    }
    public var title: String
    public var action: Action
    /// With ⌘, and ⇧ when `shift`.
    public var keyEquivalent = ""
    public var shift = false
    public var isEnabled = true
    public var submenu: [AppsMenuItem]?

    public init(
        _ title: String,
        _ action: Action,
        keyEquivalent: String = "",
        shift: Bool = false,
        isEnabled: Bool = true,
        submenu: [AppsMenuItem]? = nil
    ) {
        self.title = title
        self.action = action
        self.keyEquivalent = keyEquivalent
        self.shift = shift
        self.isEnabled = isEnabled
        self.submenu = submenu
    }

    public static var separator: AppsMenuItem { AppsMenuItem("", .separator) }
    public var isSeparator: Bool { if case .separator = action { true } else { false } }
}

/// Another running device a retained .ipa could go to (Install on ▸).
public struct AppsMenuTarget {
    public var title: String
    public var canQueueInstall: Bool
    public var isThisDevice: Bool
    public var device: AnyObject
    public init(title: String, canQueueInstall: Bool, isThisDevice: Bool, device: AnyObject) {
        self.title = title
        self.canQueueInstall = canQueueInstall
        self.isThisDevice = isThisDevice
        self.device = device
    }
}

public struct AppsMenu {
    public var rows: AppsInspectorRows
    /// The menu bar's Apps menu (over the selected row), not a row's context menu (over the clicked one).
    public var isMainMenu: Bool
    /// The selected row (main menu) or the clicked one (context menu); -1 for none.
    public var row: Int
    public var selection: IndexSet
    /// The inspector's window is the main window. The menu's explicit targets obey the same window scope as the
    /// responder-chain device commands: never refresh or delete a selection behind another window.
    public var inFrontWindow = true
    /// This device's retained copy of an app (IPALibrary).
    public var retainedCopy: (String) -> URL? = { _ in nil }
    /// Every running device's session.
    public var targets: [AppsMenuTarget] = []

    public init(
        rows: AppsInspectorRows,
        isMainMenu: Bool,
        row: Int,
        selection: IndexSet,
        inFrontWindow: Bool = true,
        retainedCopy: @escaping (String) -> URL? = { _ in nil },
        targets: [AppsMenuTarget] = []
    ) {
        self.rows = rows
        self.isMainMenu = isMainMenu
        self.row = row
        self.selection = selection
        self.inFrontWindow = inFrontWindow
        self.retainedCopy = retainedCopy
        self.targets = targets
    }

    /// The row commands a menu with no selection shows dimmed (MainMenuBuilder.resetAppsMenu too).
    public static let libraryPlaceholders = ["Open", "Uninstall…", "View on Legacy Store"]
    public static let storePlaceholders = ["Install", "Choose Version…", "View on Legacy Store"]

    public var items: [AppsMenuItem] {
        var menu: [AppsMenuItem] = []
        let device = rows.device
        if isMainMenu {
            menu.append(
                AppsMenuItem(
                    "Install App…",
                    .installApp,
                    keyEquivalent: "i",
                    shift: true,
                    isEnabled: device.canQueueInstall
                )
            )
            menu.append(AppsMenuItem("Import Media…", .importMedia, isEnabled: device.canQueueInstall))
            menu.append(.separator)
        }
        // The Apps menu always lists Resume Transfers (dimmed unless paused); a row's menu only when paused.
        if isMainMenu || device.transfersPaused {
            menu.append(AppsMenuItem("Resume Transfers", .resumeTransfers, isEnabled: device.transfersPaused))
            menu.append(.separator)
        }
        appendAppActions(to: &menu)
        // With no selection the menu keeps the mode's row commands, dimmed (issue 7).
        if isMainMenu, row < 0 {
            let titles = rows.searching ? AppsMenu.storePlaceholders : AppsMenu.libraryPlaceholders
            for title in titles { menu.append(AppsMenuItem(title, .none, isEnabled: false)) }
        }
        if menu.last?.isSeparator == false { menu.append(.separator) }
        menu.append(AppsMenuItem(isMainMenu ? "Refresh Apps" : "Refresh", .refresh))
        if isMainMenu, !inFrontWindow {
            for index in menu.indices { menu[index].isEnabled = false }
        }
        return menu
    }

    private func appendAppActions(to menu: inout [AppsMenuItem]) {
        let device = rows.device
        if rows.searching {
            guard rows.catalogResults.indices.contains(row) else { return }
            let app = rows.catalogResults[row]
            // A right-click inside a multi-row selection offers the batch; the
            // whole queue machinery (independent downloads and serial installs,
            // per-row progress) already handles N jobs.
            if selection.count > 1, selection.contains(row) {
                let installable =
                    selection
                    .compactMap { rows.catalogResults.indices.contains($0) ? rows.catalogResults[$0] : nil }
                    .filter { rows.catalogState(of: $0) == .installable }
                if installable.count > 1 {
                    menu.append(AppsMenuItem("Install \(installable.count) Apps", .installBatch(installable)))
                    return
                }
            }
            let installedApp = rows.apps.first { $0.id == app.bundleID }
            if let job = rows.catalogJob(for: app), !job.isFinished {
                menu.append(
                    AppsMenuItem(
                        "Cancel Install",
                        .cancelInstall(job),
                        isEnabled: !job.isCancelled && job.isCancellable
                    )
                )
            } else if installedApp == nil {
                menu.append(
                    AppsMenuItem("Install", .install(app), isEnabled: rows.catalogState(of: app) == .installable)
                )
            }
            if let installed = installedApp {
                if menu.last?.isSeparator == false { menu.append(.separator) }
                menu.append(
                    AppsMenuItem("Open", .open(installed), isEnabled: !rows.busyWithDevice && device.canReachDevice)
                )
                menu.append(
                    AppsMenuItem(
                        "Uninstall…",
                        .uninstall([installed]),
                        isEnabled: rows.canUninstall([installed]) && rows.catalogJob(for: app)?.isFinished != false
                    )
                )
                menu.append(.separator)
            }
            menu.append(AppsMenuItem("Choose Version…", .chooseVersion(app)))
            if app.appURL != nil { menu.append(AppsMenuItem("View on Legacy Store", .viewOnLegacyStore(app))) }
            return
        }
        // `!isFinished`, not just the index: a finished job is DRAWN as an
        // ordinary app row, so classifying by index alone offered "Cancel
        // Install" (which by then does nothing) on a row showing an installed
        // app's own icon and name, and never offered Uninstall.
        let pending = rows.pending
        if row >= 0, row < pending.count, pending[row].failed {
            menu.append(AppsMenuItem("Dismiss", .dismissInstall(pending[row])))
        } else if row >= 0, row < pending.count, !pending[row].isFinished {
            let job = pending[row]
            menu.append(
                AppsMenuItem("Cancel Install", .cancelInstall(job), isEnabled: !job.isCancelled && job.isCancellable)
            )
        } else if let app = rows.app(at: row) {
            // A right-click inside a multi-row selection acts on the batch.
            let selected = rows.selectedApps(selection)
            if selected.count > 1, selected.contains(where: { $0.id == app.id }) {
                menu.append(
                    AppsMenuItem(
                        "Uninstall \(selected.count) Apps…",
                        .uninstall(selected),
                        isEnabled: rows.canUninstall(selected)
                    )
                )
                return
            }
            menu.append(
                AppsMenuItem(
                    "Open",
                    .open(app),
                    isEnabled: !rows.busyWithDevice && device.canReachDevice && !rows.uninstalling.contains(app.id)
                )
            )
            menu.append(AppsMenuItem("Uninstall…", .uninstall([app]), isEnabled: rows.canUninstall([app])))
            // The retained copy can go to any other running device that takes installs.
            if let file = retainedCopy(app.id) {
                let others = targets.filter { !$0.isThisDevice && $0.canQueueInstall }
                if !others.isEmpty {
                    menu.append(
                        AppsMenuItem(
                            "Install on",
                            .none,
                            submenu: others.map { AppsMenuItem($0.title, .installOn(file: file, device: $0.device)) }
                        )
                    )
                }
            }
            menu.append(AppsMenuItem("View on Legacy Store", .showInLegacyStore(app)))
            menu.append(.separator)
        }
    }
}
