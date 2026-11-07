import Foundation
import HostServiceWire
import Testing

@testable import LightTouchCore

/// The Apps menu and a row's context menu (AppsMenu): selection and the clicked row, batches, cancellation,
/// unavailable devices, a stable empty selection, the front-window scope and Install on ▸.
struct AppsMenuTests {
    func installedRows(device: AppsDevice = Apps.device()) -> AppsInspectorRows {
        AppsInspectorRows(
            searching: false,
            apps: [Apps.installed("one"), Apps.installed("two")],
            catalogResults: [Apps.store(1, "one"), Apps.store(2, "two")],
            device: device
        )
    }
    func item(_ items: [AppsMenuItem], _ title: String) -> AppsMenuItem? { items.first { $0.title == title } }
    func installedApp(_ item: AppsMenuItem?) -> String? {
        switch item?.action {
        case .open(let app)?: app.id
        case .uninstall(let apps)? where apps.count == 1: apps[0].id
        default: nil
        }
    }

    @Test func mainMenuFollowsTheSelectionAndContextMenuTheClickedRow() {
        let rows = installedRows()
        let main = AppsMenu(rows: rows, isMainMenu: true, row: 0, selection: [0]).items
        let context = AppsMenu(rows: rows, isMainMenu: false, row: 1, selection: [0]).items
        #expect(installedApp(item(main, "Open")) == "one" && installedApp(item(context, "Open")) == "two")
        #expect(item(main, "Install App…")?.keyEquivalent == "i" && item(main, "Install App…")?.shift == true)
        #expect(item(main, "Refresh Apps")?.keyEquivalent.isEmpty == true && item(context, "Refresh") != nil)
        #expect(context.allSatisfy { $0.keyEquivalent.isEmpty })
        #expect(!main.contains { $0.title.contains("Bundle Identifier") })
        #expect(item(main, "Open") != nil && item(main, "Uninstall…") != nil && item(main, "Import Media…") != nil)
        #expect(item(main, "View on Legacy Store") != nil)
        // A context menu lists Resume Transfers only while paused.
        #expect(item(context, "Resume Transfers") == nil)
    }

    @Test func installNeedsADeviceThatTakesWork() {
        let main = AppsMenu(
            rows: installedRows(device: Apps.device(canQueueInstall: false)),
            isMainMenu: true,
            row: 0,
            selection: [0]
        ).items
        #expect(item(main, "Install App…")?.isEnabled == false && item(main, "Import Media…")?.isEnabled == false)
    }

    @Test func batchesAndCancellation() {
        var rows = installedRows()
        #expect(
            item(AppsMenu(rows: rows, isMainMenu: true, row: 0, selection: [0, 1]).items, "Uninstall 2 Apps…") != nil
        )
        rows.pending = [Apps.job(cancelled: true)]
        let menu = AppsMenu(rows: rows, isMainMenu: true, row: 0, selection: []).items
        #expect(item(menu, "Cancel Install")?.isEnabled == false, "a job already cancelling can't be cancelled again")
        rows.pending = [Apps.job(failed: true)]
        guard
            case .dismissInstall? = item(
                AppsMenu(rows: rows, isMainMenu: true, row: 0, selection: []).items,
                "Dismiss"
            )?.action
        else {
            Issue.record("a failed job offers Dismiss")
            return
        }
        rows.pending = [Apps.job(finished: true)]
        let finished = AppsMenu(rows: rows, isMainMenu: true, row: 0, selection: []).items
        #expect(
            item(finished, "Cancel Install") == nil,
            "a finished job is drawn as an app, never offered Cancel Install"
        )
    }

    @Test func storeRows() {
        var rows = installedRows()
        rows.searching = true
        var menu = AppsMenu(rows: rows, isMainMenu: true, row: 0, selection: [0]).items
        #expect(item(menu, "Choose Version…") != nil && item(menu, "View on Legacy Store") != nil)
        #expect(
            item(menu, "Install") == nil && item(menu, "Open") != nil,
            "installed apps offer Open, not an unavailable Install"
        )
        rows.apps = []
        menu = AppsMenu(rows: rows, isMainMenu: true, row: 0, selection: [0]).items
        #expect(item(menu, "Install")?.isEnabled == true && item(menu, "Open") == nil)
        // A right-click inside a multi-row selection installs the batch.
        menu = AppsMenu(rows: rows, isMainMenu: false, row: 1, selection: [0, 1]).items
        guard case .installBatch(let batch)? = item(menu, "Install 2 Apps")?.action else {
            Issue.record("batch")
            return
        }
        #expect(batch.map(\.ipaID) == [1, 2])
        rows.pending = [Apps.job(catalog: 1, progress: 0.3)]
        menu = AppsMenu(rows: rows, isMainMenu: false, row: 0, selection: [0]).items
        #expect(item(menu, "Cancel Install")?.isEnabled == true && item(menu, "Install") == nil)
        rows.catalogResults = [Apps.store(3, "nopage", page: false)]
        #expect(
            item(AppsMenu(rows: rows, isMainMenu: false, row: 0, selection: []).items, "View on Legacy Store") == nil
        )
    }

    /// With no selection the Apps menu keeps its shape: the mode's row commands dimmed (the library's Open,
    /// Uninstall… and View on Legacy Store; the Store's Install, Choose Version… and View on Legacy Store), Refresh
    /// Apps, and Resume Transfers dimmed (never hidden) unless the queue is paused.
    @Test func stableEmptySelection() {
        var rows = installedRows()
        func onlyMenuWideCommandsEnabled(_ menu: [AppsMenuItem]) -> Bool {
            menu.allSatisfy {
                $0.isSeparator || $0.isEnabled == ["Install App…", "Import Media…", "Refresh Apps"].contains($0.title)
            }
        }
        func middle(_ menu: [AppsMenuItem]) -> [String] {
            Array(menu.split(whereSeparator: \.isSeparator)[2]).map(\.title)
        }
        var menu = AppsMenu(rows: rows, isMainMenu: true, row: -1, selection: []).items
        #expect(middle(menu) == ["Open", "Uninstall…", "View on Legacy Store"])
        #expect(middle(menu) == middle(AppsMenu(rows: rows, isMainMenu: true, row: 0, selection: [0]).items))
        #expect(onlyMenuWideCommandsEnabled(menu))
        rows.searching = true
        rows.apps = []
        menu = AppsMenu(rows: rows, isMainMenu: true, row: -1, selection: []).items
        #expect(middle(menu) == ["Install", "Choose Version…", "View on Legacy Store"])
        #expect(middle(menu) == middle(AppsMenu(rows: rows, isMainMenu: true, row: 0, selection: [0]).items))
        #expect(onlyMenuWideCommandsEnabled(menu))
        #expect(item(menu, "Refresh Apps") != nil && item(menu, "Resume Transfers")?.isEnabled == false)
        rows.device.transfersPaused = true
        menu = AppsMenu(rows: rows, isMainMenu: true, row: -1, selection: []).items
        #expect(item(menu, "Resume Transfers")?.isEnabled == true)
        #expect(
            item(AppsMenu(rows: rows, isMainMenu: false, row: -1, selection: []).items, "Resume Transfers")?.isEnabled
                == true
        )
    }

    @Test func unreachableAndBusyDevices() {
        var rows = installedRows(device: Apps.device(canQueueInstall: false, canReachDevice: false))
        var menu = AppsMenu(rows: rows, isMainMenu: true, row: 0, selection: [0]).items
        #expect(item(menu, "Open")?.isEnabled == false && item(menu, "Uninstall…")?.isEnabled == false)
        #expect(
            item(AppsMenu(rows: rows, isMainMenu: true, row: 0, selection: [0, 1]).items, "Uninstall 2 Apps…")?
                .isEnabled == false
        )
        rows.device = Apps.device()
        rows.uninstalling = ["one"]
        #expect(
            item(AppsMenu(rows: rows, isMainMenu: true, row: 0, selection: [0, 1]).items, "Uninstall 2 Apps…")?
                .isEnabled == false
        )

        // An install must not discard a requested removal: Uninstall… stays while the device is busy; Open doesn't.
        rows.uninstalling = []
        rows.device = Apps.device(canReachDevice: false, installing: true)
        menu = AppsMenu(rows: rows, isMainMenu: true, row: 0, selection: [0]).items
        let context = AppsMenu(rows: rows, isMainMenu: false, row: 0, selection: [0]).items
        #expect(item(menu, "Uninstall…")?.isEnabled == true && item(context, "Uninstall…")?.isEnabled == true)
        #expect(item(menu, "Open")?.isEnabled == false)
        rows.searching = true
        #expect(
            item(AppsMenu(rows: rows, isMainMenu: true, row: 0, selection: [0]).items, "Uninstall…")?.isEnabled == true,
            "the Store also queues removal while installing"
        )
        rows.uninstalling = ["one"]
        #expect(
            item(AppsMenu(rows: rows, isMainMenu: true, row: 0, selection: [0]).items, "Uninstall…")?.isEnabled
                == false,
            "the same removal is never queued twice"
        )
    }

    @Test func noAppActionsBehindAnotherWindow() {
        let behind = AppsMenu(rows: installedRows(), isMainMenu: true, row: 0, selection: [0], inFrontWindow: false)
            .items
        #expect(behind.allSatisfy { !$0.isEnabled })
        #expect(
            item(AppsMenu(rows: installedRows(), isMainMenu: true, row: 0, selection: [0]).items, "Refresh Apps")?
                .isEnabled == true
        )
        // A row's own context menu is the clicked window's.
        #expect(
            item(
                AppsMenu(rows: installedRows(), isMainMenu: false, row: 0, selection: [0], inFrontWindow: false).items,
                "Open"
            )?.isEnabled == true
        )
    }

    /// Install on ▸: only with a retained copy and another running device that takes installs, never this one.
    @Test func installOnOtherDevices() {
        final class Device {}
        let remote = Device()
        let other = Device()
        let mine = Device()
        let copy = URL(fileURLWithPath: "/tmp/one.ipa")
        func menu(kept: Set<String>, _ targets: [AppsMenuTarget]) -> [AppsMenuItem] {
            AppsMenu(
                rows: installedRows(),
                isMainMenu: true,
                row: 0,
                selection: [0],
                retainedCopy: { kept.contains($0) ? copy : nil },
                targets: targets
            ).items
        }
        let targets = [
            AppsMenuTarget(title: "iPad iOS 3.2.2", canQueueInstall: true, isThisDevice: false, device: remote),
            AppsMenuTarget(title: "iPod touch iOS 3.1.3", canQueueInstall: true, isThisDevice: true, device: mine),
            AppsMenuTarget(title: "iPad iOS 3.2.2", canQueueInstall: true, isThisDevice: false, device: other)
        ]
        #expect(item(menu(kept: [], targets), "Install on") == nil, "no retained copy, nothing to install elsewhere")
        let installOn = item(menu(kept: ["one"], targets), "Install on")
        #expect(installOn?.submenu?.map(\.title) == ["iPad iOS 3.2.2", "iPad iOS 3.2.2"])
        guard case .installOn(let file, let device)? = installOn?.submenu?.first?.action else {
            Issue.record("target")
            return
        }
        #expect(file == copy && device === remote)
        var busy = targets
        busy[0].canQueueInstall = false
        #expect(
            item(menu(kept: ["one"], busy), "Install on")?.submenu?.count == 1,
            "a device that can't take installs is left out"
        )
        #expect(item(menu(kept: ["one"], [targets[1]]), "Install on") == nil, "no other running device, no submenu")
    }
}
