import Cocoa
import DeviceRuntime
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore
import UniformTypeIdentifiers

extension AppsInspectorViewController {
    /// Keep polling for the life of the view, not just until the device answers
    /// once: right after boot, installation_proxy can answer with an empty
    /// list before installd has finished registering apps, which used to read
    /// as "answered" and stop the loop — leaving the sidebar empty until an
    /// install/uninstall notification forced a reload. Polling forever instead
    /// self-heals within one more tick either way.
    func startInitialLoad() {
        guard emulator.canManageApps else {
            showInstalledPlaceholder("Apps can’t be managed without a USB connection.")
            updateButtons()
            return
        }
        // Push, so an install or uninstall shows up at once instead of on the
        // next tick. The poll below stays as the backstop.
        appChanges.start()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                // Ask "is the device even up?" in-process before spawning
                // anything: the probe answers in milliseconds, so a cold boot
                // no longer costs one failing lockdown session per
                // second, and a transient lockdown wobble skips a poll
                // instead of failing it. Not while installing — the probe is
                // itself a lockdown session, the very thing being avoided.
                if self.readsSuppressed {
                    // Reads are suppressed while our own device work runs, but
                    // "unknown" is not "reachable": leaving the last value
                    // frozen meant Install App…, the toolbar and drag-to-install
                    // all kept claiming a device that might have gone away ten
                    // minutes ago. The type already models this as nil.
                    self.emulator.deviceReachable = nil
                } else {
                    do {
                        try await self.emulator.checkDeviceConnection()
                        // A transfer may have started while the probe waited
                        // for its service slot. Its wait is not a device fault.
                        guard !Task.isCancelled else { return }
                        if !self.readsSuppressed { await self.loadOnce() }
                    } catch is CancellationError {
                        return
                    } catch {
                        if !self.readsSuppressed {
                            self.emulator.reportConnectionFailure(error, operation: "Checking USB connection")
                            if !self.haveLoaded, self.pending.isEmpty {
                                self.showInstalledPlaceholder(
                                    self.emulator.connectionIssue?.summary
                                        ?? "Connecting to \(self.emulator.profile.shortName)…"
                                )
                            } else if self.haveLoaded {
                                self.showStaleBanner()
                            }
                            self.updateButtons()
                        }
                    }
                }
                // Press hard until the device has answered once — a cold boot
                // takes ~40 s and the list is the first thing anyone looks at.
                // After that this is only a BACKSTOP: notification_proxy pushes
                // install/uninstall the moment they happen, so the poll exists
                // for what the guest never publishes (icon reordering) and for
                // a dropped session, neither of which needs a 3 s cadence. An
                // unactivated guest refuses every service: nothing to press for.
                try? await Task.sleep(
                    for: .seconds(self.haveLoaded || self.emulator.connectionIssue?.persistent == true ? 15 : 1)
                )
            }
        }
    }

    @objc func refreshIconDimming() {
        // Catalog mode: different row count, and pending.count may exceed it —
        // the range below would raise. Catalog rows redraw on reload anyway.
        guard !searching else { return }
        for row in pending.count..<numberOfRows(in: tableView) {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?
                .imageView?.layer?.opacity = NSApp.isActive ? 1 : 0.5
        }
    }

    /// Drop finished install rows once the device lists their apps, asking it again once per row
    /// (AppsInspector.pendingRow).
    private func prunePending() {
        pending.removeAll { job in
            let key = ObjectIdentifier(job)
            switch AppsInspector.pendingRow(
                job,
                listed: { id in apps.contains { $0.id == id } },
                rereadAsked: rereads.contains(key)
            ) {
            case .keep: return false
            case .drop:
                rereads.remove(key)
                return true
            case .reread(let delay):
                rereads.insert(key)
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    await self.loadOnce()
                }
                return false
            }
        }
    }

    /// What the inspector knows, as the table's rows (LightTouchCore's AppsInspectorRows).
    var rows: AppsInspectorRows {
        AppsInspectorRows(
            searching: searching,
            apps: apps,
            pending: pending,
            installedQuery: queries[.installed, default: ""],
            catalogResults: catalogResults,
            uninstalling: uninstalling,
            removingApp: removingApp,
            device: device,
            displayName: { [unowned self] in displayName($0) },
            icons: AppRowIcons(
                catalog: { [unowned self] in catalogIcon($0).map(ObjectIdentifier.init) },
                pending: { [unowned self] in pendingIcon($0).map(ObjectIdentifier.init) },
                installed: { AppMetadataCache.shared.icon(for: $0).map(ObjectIdentifier.init) }
            )
        )
    }

    /// The device, as the rows and menus weigh it.
    var device: AppsDevice {
        AppsDevice(
            id: emulator.instance.id,
            canQueueInstall: emulator.canQueueInstall,
            canReachDevice: emulator.canReachDevice,
            installing: installing,
            preparingDevice: emulator.preparingDevice,
            hasFileTransfer: emulator.hasFileTransfer,
            isReconnecting: emulator.isReconnecting,
            transfersPaused: AppInstaller.isPaused(emulator.instance.id)
        )
    }

    /// Keep selection attached to objects, rebuilding only changed rows. An
    /// unchanged background poll leaves native views and accessibility intact.
    func reloadTablePreservingSelection() {
        let rows = rows
        switch displayed.show(rows.identities, rows.appearances, selected: tableView.selectedRowIndexes) {
        case .rows(let changed): tableView.reloadData(forRowIndexes: changed, columnIndexes: [0])
        case .table(let selection):
            tableView.reloadData()
            tableView.selectRowIndexes(selection, byExtendingSelection: false)
        case nil: break
        }
    }

    @objc func appsChanged(_ note: Notification) {
        if let device = note.object as? UUID, device != emulator.instance.id { return }
        prunePending()
        // Reload NOW, not from loadOnce: its failure path doesn't touch the
        // table, and an install that failed because the device died is exactly
        // the case where the next read fails too — leaving a phantom pending
        // row on screen while every data-source index has shifted up one (the
        // right-click-hits-the-wrong-app bug).
        reloadTablePreservingSelection()
        updateButtons()
        Task { await loadOnce() }
    }

    /// What of the device the rows and buttons show: its reachability and install state (`device`), not the
    /// status line's every tick.
    func trackedDeviceState() { _ = device }
    func deviceStatusChanged() {
        reloadTablePreservingSelection()
        updateButtons()
    }

    @objc func installStarted(_ note: Notification) {
        guard let job = note.object as? InstallJob, job.deviceID == emulator.instance.id else { return }
        pending.append(job)
        if AppsInspector.revealsTransfer(job) {
            setMode(.installed)
            if let split = parent as? NSSplitViewController,
                let item = split.splitViewItem(for: self)
            {
                item.animator().isCollapsed = false
            }
        }
        showInstalledPlaceholder(nil)
        reloadTablePreservingSelection()
        if AppsInspector.revealsTransfer(job) { tableView.scrollRowToVisible(pending.count - 1) }
        updateButtons()
    }

    @objc func installProgressed(_ note: Notification) {
        guard let job = note.object as? InstallJob, job.deviceID == emulator.instance.id else { return }
        reloadTablePreservingSelection()
        updateButtons()
    }

    private var poweringDown: Bool { emulator.shuttingDown || emulator.isPoweredOff || emulator.isErasing }

    /// One attempt to read the installed list.
    ///
    /// A failed read leaves the previous list on screen. It used to replace it
    /// with an empty one — every transient "could not start the service" blanked
    /// a sidebar that was perfectly correct a second earlier, and read as the
    /// list having lost its contents for no reason.
    func loadOnce() async {
        // Not while powering off. Power Off and Erase post .ltmAppsChanged
        // (discardAll) as they start, and the guest halt goes over the agent,
        // not the gate, so this read raced installd going down: "Install
        // service error (browse): code -8" (APIInternalError) at Power Off.
        guard emulator.canManageApps, !poweringDown else { return }
        // Nothing talks to the device while an install runs (see `installing`);
        // the finish notification reloads the list anyway.
        guard !readsSuppressed else { return }
        // One at a time. Every .ltmAppsChanged used to spawn another of these,
        // and an upgrade publishes two notifications back to back — so two
        // reads queued on the gate for up to 20s each and the SLOWER, older one
        // assigned `apps` last, putting a stale list on screen.
        // Coalesce, don't drop. A refresh that arrives while one is in flight
        // used to be discarded outright — and the read already running was
        // started BEFORE the change that prompted it, so the list it publishes
        // is already stale. Notification-driven refreshes, the post-reorder
        // re-read and the user's own Refresh all went through this path, which
        // is a large part of "the list and the home screen fall out of sync".
        guard !isLoading else {
            needsReload = true
            return
        }
        isLoading = true
        defer {
            isLoading = false
            if needsReload {
                needsReload = false
                Task { await loadOnce() }
            }
        }
        do {
            let live = try await emulator.services.installedApps()
            // Read the home-screen order BEFORE publishing anything. Assigning
            // `apps` and then awaiting left the data source reporting a row
            // count the table had never been told about, and anything that
            // re-queried it during that window (a layout pass, the
            // active/inactive icon dimming) asked for a row that did not exist
            // — an out-of-range raise, not a glitch.
            let order = (try? await emulator.services.homeScreenOrder()) ?? homeOrder
            // No suspension points from here to reloadData().
            apps = live
            homeOrder = order
            haveLoaded = true
            lastLoaded = Date()
            emulator.deviceReachable = true
            hideStaleBanner()
            // SpringBoard publishes no notification when icons are rearranged
            // on the device — notification_proxy carries application_installed
            // and application_uninstalled, but nothing for the icon layout — so
            // a reorder made on the guest can only be noticed by asking again,
            // every time round, or the sidebar disagrees with the home screen
            // until something else happens to refresh it.
            //
            sortApps()
            prunePending()  // the list just changed; a row may have earned its exit
            reloadTablePreservingSelection()
            showInstalledPlaceholder(installedPlaceholderText)
            updateButtons()
        } catch is CancellationError {
            // Closing the inspector or ending a poll is not a failed device.
            return
        } catch {
            // A read already in flight when Power Off began is not a device fault.
            if !poweringDown {
                emulator.reportConnectionFailure(error, operation: "Refreshing apps")
            }
            // Prune here too. This path never touched `pending`, so a row whose
            // install failed because the device went away stayed on screen —
            // and the failing list read is exactly when that happens.
            prunePending()
            reloadTablePreservingSelection()
            // The reason rides along so a manual Refresh that fails says why,
            // instead of sitting on the same three words the boot wait shows.
            if !haveLoaded, pending.isEmpty {
                if case DeviceError.unavailable = error {
                    // Permanent and host-side: "Waiting" is the wrong frame and
                    // names no remedy.
                    showInstalledPlaceholder(
                        "App services are missing from this copy of Light Touch. Reinstall Light Touch."
                    )
                } else {
                    showInstalledPlaceholder(emulator.connectionIssue?.summary ?? "Couldn’t update apps. Retrying…")
                }
                placeholder.toolTip = emulator.connectionIssue?.detail
            } else if haveLoaded {
                showStaleBanner()  // keep the list, mark it stale
            }
            // Also on the failure path: when usbmuxd dies the session goes away
            // and canManageApps flips false, but nothing told the inspector, so
            // "+" stayed enabled, opened a file picker, and the install failed
            // with an error blaming the guest for a host daemon that had died.
            updateButtons()
        }
    }

    /// True when the HOST side is gone rather than the guest — worth saying,
    /// because "device not responding" points the user at the wrong thing.
    private var usbUnavailable: Bool { !emulator.canManageApps }

    private func showStaleBanner() {
        let when = AppsInspector.freshnessText(since: lastLoaded)
        if emulator.isPoweredOff {
            staleReason = "Device powered off"
        } else if emulator.shuttingDown {
            staleReason = "Device powering off…"
        } else if emulator.isReconnecting {
            staleReason = "Reconnecting app services…"
        } else {
            staleReason =
                usbUnavailable
                ? "USB connection unavailable"
                : emulator.connectionIssue?.summary ?? "Connecting to \(emulator.profile.shortName)…"
        }
        banner.toolTip = [emulator.connectionIssue?.detail, when]
            .compactMap { $0 }.joined(separator: "\n")
        showBanner()
    }

    func hideStaleBanner() {
        staleReason = nil
        showBanner()
    }

    /// The banner as AppsInspectorBanner derives it now: paused transfers, else the stale reason, else none.
    private func showBanner() {
        let shown = AppsInspectorBanner(paused: AppInstaller.isPaused(emulator.instance.id), stale: staleReason)
        resumeButton.isHidden = shown != .paused
        banner.stringValue = shown.text ?? ""
        banner.isHidden = shown == .none
        bannerHeight?.constant = shown.height
    }

    /// Home-screen order when SpringBoard has told us one, and the *displayed*
    /// name otherwise — sorting by the reported name while showing the cached
    /// one is what made the list look unsorted and shuffle as metadata landed.
    private func sortApps() {
        // Sorted on a key, not a mix of two rules: comparing home-screen index
        // when both are known and names otherwise is not a consistent ordering,
        // and sort() is free to produce nonsense from one.
        apps.sort { a, b in
            let i = homeOrder.firstIndex(of: a.id) ?? .max
            let j = homeOrder.firstIndex(of: b.id) ?? .max
            if i != j { return i < j }
            return displayName(a).localizedCaseInsensitiveCompare(displayName(b)) == .orderedAscending
        }
    }

    func displayName(_ app: InstalledApp) -> String {
        AppMetadataCache.shared.name(for: app.id) ?? app.name
    }

    func showPlaceholder(_ text: String?) {
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = (text == nil)
        let actions = AppsInspector.placeholderActions(
            message: text,
            searching: searching,
            haveLoaded: haveLoaded,
            nothingListed: apps.isEmpty && pending.isEmpty,
            catalogFailed: catalogFailed
        )
        browseButton.isHidden = !actions.browseAndInstall
        installButton.isHidden = !actions.browseAndInstall
        installButton.isEnabled = emulator.canQueueInstall
        retryButton.isHidden = !actions.retry
        emptyActions.isHidden = !actions.group
    }

    /// Installed-list placeholders only — a no-op while the catalog results own
    /// the table, so the background poll can't clobber "No compatible apps
    /// found" with "Waiting for the device…" mid-search.
    private func showInstalledPlaceholder(_ text: String?) {
        guard !searching else { return }
        showPlaceholder(text)
    }

    var installedPlaceholderText: String? { rows.installedPlaceholder(haveLoaded: haveLoaded) }

    /// Network downloads and waiting rows do not hold a device session.
    var installing: Bool { AppInstaller.isUsingDevice(emulator.instance.id) || emulator.isInstalling }

    func canUninstall(_ selection: [InstalledApp]) -> Bool { rows.canUninstall(selection) }
    func removalStatus(for bundleID: String) -> String { rows.removalStatus(for: bundleID) }

    /// Any device operation of ours in flight.
    var busyWithDevice: Bool { rows.busyWithDevice }

    /// See AppsDevice.readsSuppressed.
    private var readsSuppressed: Bool { device.readsSuppressed }

    func updateButtons() {
        // A cached list can outlive the connection. Match the removal action's
        // reachability gate so stale rows never advertise a usable Uninstall.
        showBanner()
        addRemove.setEnabled(emulator.canQueueInstall, forSegment: 0)
        addRemove.setEnabled(haveLoaded && canUninstall(selectedApps), forSegment: 1)
    }

    var selectedApps: [InstalledApp] { rows.selectedApps(tableView.selectedRowIndexes) }
    var visibleApps: [InstalledApp] { rows.visibleApps }
    func app(at row: Int) -> InstalledApp? { rows.app(at: row) }
}
