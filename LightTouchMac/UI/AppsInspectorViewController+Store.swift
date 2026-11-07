import Cocoa
import DeviceRuntime
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore
import UniformTypeIdentifiers

extension AppsInspectorViewController {
    // MARK: - Legacy Store (mode + search)

    func filterChanged() {
        reloadTablePreservingSelection()
        if searching, !catalogFetched.isEmpty {
            showPlaceholder(
                AppsInspector.searchFinished(query: "", fetched: catalogFetched.count, shown: catalogResults.count)
            )
        }
        updateButtons()
    }

    @objc func modeChanged(_ sender: NSSegmentedControl) {
        setMode(PaneMode(rawValue: sender.selectedSegment) ?? .installed)
    }

    func setMode(_ newMode: PaneMode) {
        searchTask?.cancel()
        queries[mode] = searchField.stringValue
        mode = newMode
        searchField.stringValue = queries[newMode, default: ""]
        searchField.placeholderString = newMode == .store ? "Search Store" : "Search Installed Apps"
        modeControl.selectedSegment = newMode.rawValue
        filterButton.isEnabled = newMode == .store
        tableView.deselectAll(nil)
        reloadTablePreservingSelection()
        updateButtons()
        updateFooterVisibility()
        switch newMode {
        case .installed:
            showPlaceholder(installedPlaceholderText)
        case .store:
            scheduleSearch()
        }
    }

    /// Find / Search Apps: put the caret in the toolbar search field.
    func focusSearch() {
        guard let window = view.window ?? parent?.view.window else { return }
        if let split = window.contentViewController as? NSSplitViewController,
            let item = split.splitViewItem(for: self)
        {
            item.isCollapsed = false
        }
        window.contentView?.layoutSubtreeIfNeeded()
        // The field may be collapsed into a search icon or toolbar overflow.
        // AppKit owns attaching and expanding it before assigning focus.
        searchToolbarItem?.beginSearchInteraction()
    }

    @objc func browseStore() { setMode(.store) }
    @objc func installLocal() { add() }
    @objc func searchEdited() {
        queries[mode] = searchField.stringValue
        if mode == .installed {
            reloadTablePreservingSelection()
            showPlaceholder(installedPlaceholderText)
        } else {
            scheduleSearch()
        }
    }

    /// Fetch what the Store view should show for the current search text —
    /// results for a query, the suggested (most-archived compatible) list for
    /// an empty one. No-op outside Store mode.
    func scheduleSearch() {
        searchTask?.cancel()
        guard mode == .store else { return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        catalogFailed = false
        catalogFetched = []
        reloadTablePreservingSelection()
        // iPhone OS 1 predates the App Store: Legacy Store's suggested list is empty for it by definition,
        // which read as the store being broken. A search still runs (and says why each app can't install).
        // Replace the other mode's overlay before any debounce/network await.
        showPlaceholder(
            AppsInspector.searchStarting(
                query: query,
                iosVersion: emulator.iosVersion,
                haveResults: !catalogResults.isEmpty
            )
        )
        guard AppsInspector.searchRuns(query: query, iosVersion: emulator.iosVersion) else {
            updateButtons()
            return
        }
        searchTask = Task { [weak self] in
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(300))  // debounce typing
            }
            guard let self, !Task.isCancelled else { return }
            // Only the response to what's in the field now may land — a slower
            // older query resolving late must not overwrite a newer list.
            let current = {
                self.mode == .store
                    && self.searchField.stringValue.trimmingCharacters(in: .whitespaces) == query
            }
            do {
                let results = try await CatalogClient.search(
                    query,
                    device: self.emulator.productType,
                    os: self.emulator.iosVersion
                )
                guard !Task.isCancelled, current() else { return }
                self.catalogFetched = results
                self.reloadTablePreservingSelection()
                self.showPlaceholder(
                    AppsInspector.searchFinished(query: query, fetched: results.count, shown: self.catalogResults.count)
                )
                self.fetchCatalogIcons(results)
            } catch {
                guard !Task.isCancelled, current() else { return }
                self.catalogFetched = []
                self.catalogFailed = true
                self.reloadTablePreservingSelection()
                self.showPlaceholder(
                    AppsInspector.searchFailed(error, marketingName: self.emulator.profile.marketingName)
                )
            }
            self.updateButtons()
        }
    }

    /// Warm the icon memo for these results, repainting each row as its icon
    /// lands. Content-addressed URLs, so a memo hit never goes stale.
    private func fetchCatalogIcons(_ results: [CatalogApp]) {
        for app in results {
            guard let url = app.iconURL,
                CatalogClient.iconMemo.object(forKey: url.absoluteString as NSString) == nil
            else { continue }
            Task { [weak self] in
                guard await CatalogClient.icon(for: app) != nil else { return }
                self?.reloadCatalogRow(app.ipaID)
            }
        }
    }

    private func reloadCatalogRow(_ ipaID: Int) {
        guard searching, catalogResults.contains(where: { $0.ipaID == ipaID }), catalogIconReload == nil else { return }
        catalogIconReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            catalogIconReload = nil
            if searching { reloadTablePreservingSelection() }
        }
    }

    fileprivate func catalogJob(for app: CatalogApp) -> InstallJob? { rows.catalogJob(for: app) }
    fileprivate func catalogState(of app: CatalogApp) -> CatalogRowState { rows.catalogState(of: app) }

    @objc func catalogInstallClicked(_ sender: NSButton) {
        guard searching, catalogResults.indices.contains(sender.tag) else { return }
        let app = catalogResults[sender.tag]
        if let installed = apps.first(where: { $0.id == app.bundleID }) {
            launch(installed)
        } else {
            install(catalog: app)
        }
    }

    @objc func rowDoubleClicked() {
        let row = tableView.clickedRow
        if searching {
            guard catalogResults.indices.contains(row) else { return }
            let item = NSMenuItem()
            item.representedObject = catalogResults[row]
            catalogDetailsClicked(item)
            return
        }
        launch(app(at: row))
    }

    /// Launch an installed app on the guest, exactly as tapping its icon would.
    private func launch(_ app: InstalledApp?) {
        guard let app, !busyWithDevice, !uninstalling.contains(app.id) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await emulator.launchApp(app.id)
            } catch is CancellationError {
                return
            } catch {
                let alert = NSAlert()
                if case AppLaunchError.locked = error {
                    alert.alertStyle = .informational
                    alert.messageText =
                        "“\(displayName(app))” couldn’t open because the \(emulator.profile.shortName) is locked."
                    alert.informativeText = "Unlock it, then try again."
                } else {
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn’t open “\(displayName(app))”"
                    if let launchError = error as? AppLaunchError {
                        alert.informativeText = launchError.message(for: emulator.profile)
                    } else {
                        logEvent("launch \(app.id): \(error.localizedDescription)")
                        alert.informativeText = AppLaunchError.failed.message(for: emulator.profile)
                    }
                }
                if let window = view.window { _ = await alert.beginSheetModal(for: window) } else { alert.runModal() }
            }
        }
    }

    @objc func openClicked(_ sender: NSMenuItem) {
        launch(sender.representedObject as? InstalledApp)
    }

    @objc func viewOnLegacyStoreClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? CatalogApp)?.appURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func catalogDetailsClicked(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? CatalogApp else { return }
        let canInstall = { [weak self] in
            guard let self else { return false }
            return self.emulator.canQueueInstall && self.catalogJob(for: app)?.isFinished != false
        }
        let sheet = CatalogDetailsViewController(
            app: app,
            device: emulator.productType,
            deviceOS: emulator.iosVersion,
            arch: emulator.guestArch,
            installedVersion: apps.first { $0.id == app.bundleID }?.version,
            canInstall: canInstall
        ) { [weak self] copy in
            guard let self, canInstall() else { return }
            AppInstaller.startCatalog(copy, with: self.emulator, presenting: self.view.window)
        }
        presentAsSheet(sheet)
    }

    @objc func installCatalogClicked(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? CatalogApp else { return }
        install(catalog: app)
    }

    @objc func installSelectedCatalogClicked(_ sender: NSMenuItem) {
        for app in (sender.representedObject as? [CatalogApp]) ?? [] {
            install(catalog: app)
        }
    }

    func install(catalog app: CatalogApp) {
        guard catalogState(of: app) == .installable else { return }
        // The job owns the whole pipeline — download included — so the row is
        // in `pending` (and visible in the installed list) from the first byte.
        AppInstaller.startCatalog(app, with: emulator, presenting: view.window)
    }
}

// MARK: - Search field

extension AppsInspectorViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { searchEdited() }
}
