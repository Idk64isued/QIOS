import Foundation
import HostServiceWire
import Testing

@testable import LightTouchCore

/// The Apps inspector's table without AppKit (AppsInspectorRows, AppTableRows, AppsInspector): which rows, what
/// each shows and offers, and how a new set of rows reaches the table.
struct AppsInspectorRowsTests {
    func appearance(_ title: String, _ subtitle: String = "Ready") -> AppRowAppearance {
        AppRowAppearance(title: title, subtitle: subtitle)
    }

    // MARK: Reloading

    /// Native row views survive unchanged polls and another app's progress; a reorder keeps the selection on its row.
    @Test func unchangedRowsKeepTheirViewsAndSelectionFollowsIdentity() {
        var table = AppTableRows()
        let ids: [AppRowIdentity] = [.app("one"), .app("two"), .app("three")]
        var looks = [appearance("One"), appearance("Two"), appearance("Three")]
        #expect(table.show(ids, looks, selected: []) == .table(selecting: []))
        for _ in 0..<5 { #expect(table.show(ids, looks, selected: [1]) == nil, "an unchanged poll touches nothing") }
        looks[0].subtitle = "Downloading… 50%"
        #expect(table.show(ids, looks, selected: [1]) == .rows([0]), "another app's progress reloads only its own row")
        let last = looks.removeLast()
        looks.insert(last, at: 0)
        #expect(
            table.show([.app("three"), .app("one"), .app("two")], looks, selected: [1]) == .table(selecting: [2]),
            "the selection follows the app across a reorder"
        )
    }

    @Test func selectionFollowsRowsAsJobsLeaveAndResultsReorder() {
        let large = Apps.job("large")
        let small = Apps.job("small")
        var rows = AppsInspectorRows(
            searching: false,
            apps: [Apps.installed("installed")],
            pending: [large, small],
            device: Apps.device()
        )
        var table = AppTableRows()
        _ = table.show(rows.identities, rows.appearances, selected: [])
        rows.pending.removeFirst()
        #expect(table.show(rows.identities, rows.appearances, selected: [2]) == .table(selecting: [1]))
        rows.pending = []
        #expect(table.show(rows.identities, rows.appearances, selected: [1]) == .table(selecting: [0]))
        rows.searching = true
        rows.catalogResults = [Apps.store(1, "a"), Apps.store(2, "b")]
        _ = table.show(rows.identities, rows.appearances, selected: [])
        rows.catalogResults.reverse()
        #expect(table.show(rows.identities, rows.appearances, selected: [1]) == .table(selecting: [0]))
    }

    /// A device status change re-evaluates Store rows: Install enables when the device becomes ready and disables
    /// when it stops answering; a change that alters nothing a row shows keeps the row's view.
    @Test func storeInstallFollowsTheDevice() {
        var rows = AppsInspectorRows(
            searching: true,
            catalogResults: [Apps.store(7, "com.playfirst.hoteldash")],
            device: Apps.device(canQueueInstall: false, canReachDevice: false)
        )
        var table = AppTableRows()
        _ = table.show(rows.identities, rows.appearances, selected: [])
        #expect(rows.appearances[0].kind == .install && !rows.appearances[0].enabled, "booting: Install disabled")
        rows.device.canQueueInstall = true
        #expect(table.show(rows.identities, rows.appearances, selected: []) == .rows([0]))
        #expect(rows.appearances[0].enabled, "Install enables once the device is ready")
        rows.device.canReachDevice = true
        #expect(table.show(rows.identities, rows.appearances, selected: []) == nil, "nothing the row shows changed")
        rows.device.canQueueInstall = false
        #expect(
            table.show(rows.identities, rows.appearances, selected: []) == .rows([0]) && !rows.appearances[0].enabled
        )
    }

    // MARK: What rows show

    @Test func installedListHidesAnAppBeingReplacedAndOffsetsByTransfers() {
        let reinstall = Apps.job("Diner Dash", bundleID: "diner")
        var rows = AppsInspectorRows(
            searching: false,
            apps: [Apps.installed("diner"), Apps.installed("hotel")],
            pending: [reinstall],
            device: Apps.device()
        )
        #expect(rows.visibleApps.map(\.id) == ["hotel"] && rows.rowCount == 2)
        #expect(rows.app(at: 0) == nil && rows.app(at: 1)?.id == "hotel" && rows.app(at: 2) == nil)
        #expect(rows.identities == [.job(ObjectIdentifier(reinstall)), .app("hotel")])
        reinstall.isFinished = true
        #expect(rows.visibleApps.map(\.id) == ["diner", "hotel"], "a finished job no longer hides the app")
        rows.installedQuery = "  HOT "
        #expect(rows.visibleApps.map(\.id) == ["hotel"], "the Installed search matches names and bundle ids")
        rows.searching = true
        #expect(rows.app(at: 1) == nil, "Store rows never resolve to installed apps")
    }

    @Test func removalWords() {
        var rows = AppsInspectorRows(
            searching: false,
            apps: [Apps.installed("diner")],
            uninstalling: ["diner"],
            device: Apps.device()
        )
        #expect(rows.removalStatus(for: "diner") == "Waiting to remove…")
        #expect(rows.appearances.last?.subtitle == "Waiting to remove…" && rows.appearances.last?.kind == .progress)
        rows.device.transfersPaused = true
        #expect(rows.removalStatus(for: "diner") == "Removal paused")
        rows.removingApp = "diner"
        #expect(rows.removalStatus(for: "diner") == "Removing…")
    }

    @Test func storeRowsOfferWhatTheAppCanDoNow() {
        let app = Apps.store(1, "test")
        var rows = AppsInspectorRows(searching: true, catalogResults: [app], device: Apps.device())
        guard case .result("Install", true) = rows.catalogRow(for: app) else {
            Issue.record("installable")
            return
        }
        rows.device.canQueueInstall = false
        guard case .result("Install", false) = rows.catalogRow(for: app) else {
            Issue.record("device not ready")
            return
        }
        rows.device.canQueueInstall = true
        guard case .result("Install", false) = rows.catalogRow(for: Apps.store(2, "new", unavailable: true)) else {
            Issue.record("the server's verdict grays it")
            return
        }

        let downloading = Apps.job(bundleID: "test", catalog: 1, progress: 0.5)
        rows.pending = [downloading]
        guard case .progress(_, 0.5, let job?) = rows.catalogRow(for: app), job === downloading else {
            Issue.record("downloading")
            return
        }
        #expect(rows.catalogState(of: app) == .downloading(0.5))
        downloading.downloadProgress = nil
        guard case .progress("Installing…", nil, _?) = rows.catalogRow(for: app) else {
            Issue.record("installing")
            return
        }
        downloading.isFinished = true
        #expect(
            rows.catalogState(of: app) == .installed,
            "a cleanly finished job reads as installed before the device lists it"
        )
        guard case .result("Open", false) = rows.catalogRow(for: app) else {
            Issue.record("not listed yet: Open dims")
            return
        }
        rows.apps = [Apps.installed("test")]
        guard case .result("Open", true) = rows.catalogRow(for: app) else {
            Issue.record("listed: Open")
            return
        }
        rows.device.installing = true
        guard case .result("Open", false) = rows.catalogRow(for: app) else {
            Issue.record("busy: Open dims")
            return
        }
        rows.device.installing = false

        // A failed or cancelled job doesn't claim the row; a failed one offers Retry on it.
        let failed = Apps.job(status: "The device is full.", bundleID: "test", catalog: 1, failed: true)
        rows.pending = [failed]
        rows.apps = []
        #expect(rows.catalogJob(for: app) == nil)
        guard case .progress("The device is full.", nil, let job?) = rows.catalogRow(for: app), job === failed else {
            Issue.record("failed")
            return
        }
        #expect(rows.appearances[0].kind == .failed && rows.appearances[0].enabled)
        rows.pending = [Apps.job(bundleID: "test", cancelled: true)]
        #expect(rows.catalogJob(for: app) == nil && rows.catalogState(of: app) == .installable)

        // A removal in flight shows as the progress row.
        rows.pending = []
        rows.apps = [Apps.installed("test")]
        rows.uninstalling = ["test"]
        guard case .progress("Waiting to remove…", nil, nil) = rows.catalogRow(for: app) else {
            Issue.record("removal")
            return
        }
    }

    @Test func transferRows() {
        let paused = Apps.job("Paused", status: "Paused")
        let cancelling = Apps.job("Cancelling", cancelled: true)
        let landed = Apps.job("Landed", status: "Complete", bundleID: "landed", finished: true)
        let locked = Apps.job("Locked", status: "Installing… 40%", cancellable: false)
        let rows = AppsInspectorRows(
            searching: false,
            pending: [paused, cancelling, landed, locked],
            device: Apps.device()
        )
        let looks = rows.appearances
        #expect(looks[0].kind == .resume && looks[1].subtitle == "Cancelling…" && looks[1].kind == .progress)
        #expect(
            looks[2] == AppRowAppearance(title: "Landed", subtitle: "landed"),
            "a finished job is drawn as an ordinary app row"
        )
        #expect(!looks[3].enabled, "past the point cancellation can reach")
    }

    // MARK: The device

    /// Waiting removals must not suppress the health reads that recover a lost connection; the work that owns the
    /// guest connection does.
    @Test func readsStandAsideOnlyForWorkHoldingTheConnection() {
        var rows = AppsInspectorRows(
            searching: false,
            uninstalling: ["queued-behind-paused-install"],
            device: Apps.device(installing: false)
        )
        #expect(!rows.device.readsSuppressed && rows.busyWithDevice)
        rows.device.installing = true
        #expect(rows.device.readsSuppressed)
        for flag in [\AppsDevice.hasFileTransfer, \.isReconnecting, \.preparingDevice] {
            var device = Apps.device()
            device[keyPath: flag] = true
            #expect(device.readsSuppressed, "\(flag)")
        }
    }

    @Test func uninstallNeedsADeviceTakingWorkAndNoRemovalAlreadyQueued() {
        var rows = AppsInspectorRows(
            searching: false,
            apps: [Apps.installed("one"), Apps.installed("two")],
            device: Apps.device()
        )
        #expect(rows.canUninstall(rows.apps) && !rows.canUninstall([]))
        rows.uninstalling = ["one"]
        #expect(!rows.canUninstall(rows.apps) && rows.canUninstall([rows.apps[1]]))
        rows.device.canQueueInstall = false
        #expect(!rows.canUninstall([rows.apps[1]]))
    }

    // MARK: Words

    @Test func freshness() {
        let now = Date()
        #expect(AppsInspector.freshnessText(since: nil, now: now) == "not yet refreshed")
        for offset in [0.0, -0.5, -59, 1] {
            #expect(
                AppsInspector.freshnessText(since: now.addingTimeInterval(offset), now: now) == "last updated just now"
            )
        }
        let older = AppsInspector.freshnessText(since: now.addingTimeInterval(-120), now: now)
        #expect(older.hasPrefix("last updated ") && !older.contains("in ") && older != "last updated just now")
    }

    @Test func placeholders() {
        var rows = AppsInspectorRows(searching: false, device: Apps.device())
        #expect(rows.installedPlaceholder(haveLoaded: false) == "Waiting for the device…")
        #expect(rows.installedPlaceholder(haveLoaded: true) == "No apps installed")
        rows.installedQuery = "query"
        #expect(rows.installedPlaceholder(haveLoaded: true) == "No matching apps")
        rows.pending = [Apps.job()]
        #expect(
            rows.installedPlaceholder(haveLoaded: false) == nil && rows.installedPlaceholder(haveLoaded: true) == nil
        )

        #expect(
            AppsInspector.searchStarting(query: "", iosVersion: "3.1.3", haveResults: false) == "Loading Legacy Store…"
        )
        #expect(
            AppsInspector.searchStarting(query: "dash", iosVersion: "3.1.3", haveResults: false)
                == "Searching Legacy Store…"
        )
        #expect(
            AppsInspector.searchStarting(query: "dash", iosVersion: "3.1.3", haveResults: true) == nil,
            "cached rows stay usable"
        )
        #expect(
            AppsInspector.searchStarting(query: "", iosVersion: "1.1.5", haveResults: false)
                == "iPhone OS 1.1.5 has no App Store."
        )
        #expect(
            !AppsInspector.searchRuns(query: "", iosVersion: "1.1.5")
                && AppsInspector.searchRuns(query: "dash", iosVersion: "1.1.5")
        )
        #expect(AppsInspector.searchFinished(query: "", fetched: 0, shown: 0) == "Legacy Store is empty right now.")
        #expect(
            AppsInspector.searchFinished(query: "dash", fetched: 0, shown: 0) == "No compatible apps found for “dash”."
        )
        #expect(AppsInspector.searchFinished(query: "dash", fetched: 3, shown: 0) == "No apps match the filter.")
        #expect(AppsInspector.searchFinished(query: "dash", fetched: 3, shown: 1) == nil)
        #expect(
            AppsInspector.searchFailed(CatalogError.unsupportedDevice(name: nil), marketingName: "iPhone 4")
                == "Legacy Store doesn’t support iPhone 4 yet."
        )
        #expect(
            AppsInspector.searchFailed(CatalogError.badStatus(502), marketingName: "x")
                == "Legacy Store isn’t responding. Try again in a moment."
        )
        #expect(
            AppsInspector.searchFailed(URLError(.notConnectedToInternet), marketingName: "x").hasPrefix(
                "Couldn’t reach Legacy Store — "
            )
        )

        let empty = AppsInspector.placeholderActions(
            message: "No apps installed",
            searching: false,
            haveLoaded: true,
            nothingListed: true,
            catalogFailed: false
        )
        #expect(empty == .init(browseAndInstall: true, retry: false, group: true))
        let failed = AppsInspector.placeholderActions(
            message: "Couldn’t reach Legacy Store",
            searching: true,
            haveLoaded: true,
            nothingListed: true,
            catalogFailed: true
        )
        #expect(failed == .init(browseAndInstall: false, retry: true, group: true))
        let waiting = AppsInspector.placeholderActions(
            message: "Waiting for the device…",
            searching: false,
            haveLoaded: false,
            nothingListed: true,
            catalogFailed: true
        )
        #expect(waiting == .init(browseAndInstall: false, retry: false, group: false))
        #expect(
            !AppsInspector.placeholderActions(
                message: nil,
                searching: false,
                haveLoaded: true,
                nothingListed: true,
                catalogFailed: false
            ).group
        )
    }

    /// Files dropped on the canvas have no Store row: their transfer is revealed in the installed list, a Store
    /// install's isn't, and the new transfer is the last of the pending rows.
    @Test func droppedTransfersAreRevealed() {
        let store = Apps.job(catalog: 42)
        let imported = Apps.job()
        let queued = Apps.job()
        #expect(!AppsInspector.revealsTransfer(store) && AppsInspector.revealsTransfer(imported))
        let rows = AppsInspectorRows(
            searching: false,
            apps: [Apps.installed("app")],
            pending: [store, imported, queued],
            device: Apps.device()
        )
        #expect(rows.identities[rows.pending.count - 1] == .job(ObjectIdentifier(queued)) && rows.rowCount == 4)
    }

    /// One banner: paused transfers over a stale list's reason, and once the queue resumes (a stop or an erase
    /// resumes it) the banner is what the list is, not "Transfers paused" without its Resume button.
    @Test func theBannerFollowsThePauseAndTheList() {
        #expect(AppsInspectorBanner(paused: true, stale: "Device powered off") == .paused)
        #expect(AppsInspectorBanner(paused: false, stale: "Device powered off") == .stale("Device powered off"))
        #expect(AppsInspectorBanner(paused: false, stale: nil) == .none)
        #expect(AppsInspectorBanner.none.text == nil && AppsInspectorBanner.none.height == 0)
        #expect(AppsInspectorBanner.paused.text == "Transfers paused")
    }

    /// A finished install whose app isn't listed yet asks the device again once, when its row is 20 s old, where
    /// every successful read from then on spawned another for 40 s; its row still goes at 60 s or once listed.
    @Test func aFinishedInstallAsksTheDeviceAgainOnce() {
        let now = Date()
        func finished(_ age: TimeInterval, bundleID: String? = "com.example.app") -> InstallJob {
            let job = Apps.job(bundleID: bundleID, finished: true)
            job.finishedAt = now.addingTimeInterval(-age)
            return job
        }
        func row(_ job: InstallJob, listed: Bool = false, asked: Bool = false) -> AppsInspector.PendingRow {
            AppsInspector.pendingRow(job, listed: { _ in listed }, rereadAsked: asked, now: now)
        }
        #expect(row(finished(5)) == .reread(after: 15), "one re-read, when the row is 20 s old")
        #expect(row(finished(25)) == .reread(after: 0))
        #expect(row(finished(25), asked: true) == .keep, "asked already: no read back to back")
        #expect(row(finished(25), listed: true) == .drop)
        #expect(row(finished(61), asked: true) == .drop)
        #expect(row(finished(10, bundleID: nil)) == .keep && row(finished(16, bundleID: nil)) == .drop)
        #expect(row(Apps.job(bundleID: "a", failed: true, finished: true)) == .keep)
        #expect(row(Apps.job(bundleID: "a", finished: true, cancelled: true)) == .drop)
        #expect(row(Apps.job(dismissed: true)) == .drop && row(Apps.job()) == .keep)
    }
}
