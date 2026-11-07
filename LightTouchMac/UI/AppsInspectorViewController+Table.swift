import Cocoa
import DeviceRuntime
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore
import UniformTypeIdentifiers

// MARK: - Table data

extension AppsInspectorViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        searching ? catalogResults.count : pending.count + visibleApps.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        if searching {
            guard catalogResults.indices.contains(row) else { return nil }
            return catalogCell(for: catalogResults[row], row: row)
        }
        if row < pending.count {
            let job = pending[row]
            // A finished job renders as an ORDINARY app row — icon, name, no
            // spinner, no percentage — even though it is still a pending entry
            // underneath. Two things fall out of that. It stops claiming
            // "Installing… 90%" for an app already sitting on the home screen
            // (instproxy's last progress callback is 90, then "Complete", so
            // that number was simply the last one anyone heard). And when the
            // real row finally replaces it, the two look the same, so the swap
            // that used to make the whole list flicker is now invisible.
            if job.isFinished, !job.isCancelled, !job.failed {
                let cell = appCell(tableView)
                cell.textField?.stringValue = job.name
                (cell.viewWithTag(Self.appSubtitleTag) as? NSTextField)?.stringValue =
                    job.bundleID ?? job.status
                AppRowCells.setIcon(
                    job.bundleID.flatMap { AppMetadataCache.shared.icon(for: $0) },
                    on: cell.imageView
                )
                cell.imageView?.layer?.opacity = NSApp.isActive ? 1 : 0.5
                return cell
            }
            return progressCell(
                icon: pendingIcon(job),
                title: job.name,
                subtitle: job.isCancelled ? "Cancelling…" : job.status,
                fraction: job.downloadProgress,
                job: job
            )
        }
        guard let app = app(at: row) else { return nil }
        if uninstalling.contains(app.id) {
            return progressCell(
                icon: AppMetadataCache.shared.icon(for: app.id),
                title: displayName(app),
                subtitle: removalStatus(for: app.id)
            )
        }
        let cell = appCell(tableView)
        cell.textField?.stringValue = displayName(app)
        (cell.viewWithTag(Self.appSubtitleTag) as? NSTextField)?.stringValue =
            app.version
        AppRowCells.setIcon(AppMetadataCache.shared.icon(for: app.id), on: cell.imageView)
        // AppKit only dims a *selected* row when the window resigns key,
        // leaving every other icon at full strength — inconsistent with the
        // rest of the sidebar, which dims as a whole. Set explicitly instead
        // of relying on that per-row behavior; refreshed by the app-active
        // observers below whenever it changes with no reload otherwise due.
        cell.imageView?.layer?.opacity = NSApp.isActive ? 1 : 0.5
        cell.toolTip = "\(app.id)\(app.version.isEmpty ? "" : " — \(app.version)")"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // Every row selects, pending installs included — an unselectable row in a
    // source list reads as broken. What a pending row can't do (uninstall) is
    // decided where the buttons are enabled, not by refusing the selection.

    // MARK: - Dragging — reorder within, files/links out, .ipas in

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        if searching {
            // A Store row travels as its Legacy Store link, plus a private
            // payload the device view recognizes for drag-to-install.
            guard catalogResults.indices.contains(row) else { return nil }
            let app = catalogResults[row]
            let item = NSPasteboardItem()
            if let url = app.appURL { item.setString(url.absoluteString, forType: .URL) }
            if app.incompatibility == nil, let payload = try? JSONEncoder().encode(app) {
                item.setData(payload, forType: .ltmCatalogApp)
            }
            return item
        }
        guard let app = app(at: row) else { return nil }
        // An installed row travels as its bundle id (the internal reorder
        // token) and, when the library kept the bytes, the .ipa file itself —
        // draggable straight into the Finder.
        let item = NSPasteboardItem()
        item.setString(app.id, forType: .string)
        if let file = IPALibrary.url(for: app.id, device: emulator.instance) {
            item.setString(file.absoluteString, forType: .fileURL)
        }
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        if info.draggingSource as? NSTableView !== tableView {
            // From outside: an .ipa to install, if the device can take one.
            guard emulator.canReachDevice, !Self.droppedIPAs(info).isEmpty else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)  // the list as a whole
            return .copy
        }
        // Reorder: only the installed list, only against a known home-screen
        // order, never during an install (the SpringBoard write is one more
        // lockdown session the install can't afford), and one row at a time
        // (moveOnHomeScreen takes one id).
        guard !searching, queries[.installed, default: ""].isEmpty, !homeOrder.isEmpty, !installing,
            info.draggingPasteboard.pasteboardItems?.count == 1,
            operation == .above, row >= pending.count
        else { return [] }
        return .move
    }

    private static func droppedIPAs(_ info: NSDraggingInfo) -> [URL] {
        DroppedFiles.files(info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [], .ipa)
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let ipas = Self.droppedIPAs(info)
        if !ipas.isEmpty, info.draggingSource as? NSTableView !== tableView {
            for ipa in ipas { AppInstaller.start(ipa, with: emulator, presenting: view.window) }
            return true
        }
        guard let id = info.draggingPasteboard.string(forType: .string) else { return false }
        // Dropping above row N means "put it where the app now at N sits", and
        // past the last row means the end. The bundle ID travels rather than the
        // index, so the answer survives the list reloading mid-drag.
        let target = app(at: row)?.id
        // Dropping an app on its OWN top edge is the no-op AppKit normally
        // treats as "nothing happened". Here `target` was the dragged app
        // itself, which the remove() below takes out of `apps` — so the
        // firstIndex lookup found nothing, the ?? fired, and the app was sent
        // to the END of the home screen. That got written to SpringBoard, so a
        // few pixels of accidental drag really moved the icon to the last page.
        guard target != id else { return false }

        // Move it locally first: the device round trip is slow enough that a row
        // snapping back and then jumping looks like a failed drag. Moved with
        // the table's own row animation rather than reloadData() — a reload in
        // the middle of a drop is what made this look homemade.
        if let from = apps.firstIndex(where: { $0.id == id }) {
            let app = apps.remove(at: from)
            let to = target.flatMap { t in apps.firstIndex { $0.id == t } } ?? apps.count
            apps.insert(app, at: to)
            tableView.beginUpdates()
            tableView.moveRow(at: pending.count + from, to: pending.count + to)
            tableView.endUpdates()
        }

        Task {
            do {
                // Adopt the order SpringBoard ACCEPTED. Dropping it meant the
                // next list read fell back to the pre-drag `homeOrder` and
                // re-sorted the sidebar back to where it started, while the
                // device kept the new arrangement.
                homeOrder = try await emulator.services.moveOnHomeScreen(id, before: target, profile: emulator.profile)
            } catch {
                AppInstaller.presentError(error, view.window)
            }
            await loadOnce()
        }
        return true
    }

    private func appCell(_ tableView: NSTableView) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("appCell")
        if let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        image.wantsLayer = true
        image.layer?.cornerRadius = 6
        image.layer?.cornerCurve = .circular
        image.layer?.masksToBounds = true
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.cell?.wraps = false
        // A narrow inspector truncates app names; hovering shows the whole one.
        text.allowsExpansionToolTips = true
        text.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: "")
        subtitle.tag = Self.appSubtitleTag
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.lineBreakMode = .byTruncatingMiddle  // bundle ids differ at both ends
        subtitle.allowsExpansionToolTips = true
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        [image, text, subtitle].forEach(cell.addSubview)
        cell.imageView = image
        cell.textField = text
        cell.backgroundStyle = .lowered
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 32),
            image.heightAnchor.constraint(equalToConstant: 32),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: 0),
            subtitle.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            subtitle.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 1)
        ])
        return cell
    }

    private static let appSubtitleTag = 8

    /// A Legacy Store result, or its transfer or removal in flight (LightTouchCore's catalogRow decides which).
    private func catalogCell(for app: CatalogApp, row: Int) -> NSTableCellView {
        switch rows.catalogRow(for: app) {
        case .progress(let subtitle, let fraction, let job):
            return progressCell(
                icon: catalogIcon(app),
                title: app.name,
                subtitle: subtitle,
                fraction: fraction,
                job: job
            )
        case .result(let button, let enabled):
            return AppRowCells.catalogCell(
                app,
                icon: catalogIcon(app),
                button: button,
                enabled: enabled,
                row: row,
                target: self,
                action: #selector(catalogInstallClicked(_:))
            )
        }
    }

    /// The catalog's icon for a result, if it has arrived.
    func catalogIcon(_ app: CatalogApp) -> NSImage? {
        app.iconURL.flatMap { CatalogClient.iconMemo.object(forKey: $0.absoluteString as NSString) }
    }

    /// The best icon we have for a job that hasn't landed yet: the catalog's
    /// (already fetched for the search row), else a cached one for the same
    /// bundle id (reinstalls), else the generic placeholder.
    func pendingIcon(_ job: InstallJob) -> NSImage? {
        if let url = job.catalogIconURL,
            let memo = CatalogClient.iconMemo.object(forKey: url.absoluteString as NSString)
        {
            return memo
        }
        return job.bundleID.flatMap { AppMetadataCache.shared.icon(for: $0) }
    }

    private func progressCell(
        icon: NSImage?,
        title: String,
        subtitle: String,
        fraction: Double? = nil,
        job: InstallJob? = nil
    ) -> NSTableCellView {
        AppRowCells.progressCell(icon: icon, title: title, subtitle: subtitle, fraction: fraction, job: job) {
            [weak self] in
            self?.resumeInstallsClicked(nil)
        }
    }
}
