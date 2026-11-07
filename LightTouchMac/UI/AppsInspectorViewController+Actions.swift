import Cocoa
import DeviceRuntime
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore
import UniformTypeIdentifiers

extension AppsInspectorViewController {
    @objc func addOrRemove(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? add() : remove(selectedApps)
    }

    func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa")].compactMap { $0 }
        // Several at once: ready files install one at a time.
        panel.allowsMultipleSelection = true
        panel.message = "Choose decrypted .ipa files to install."
        panel.prompt = "Install"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            for url in panel.urls {
                AppInstaller.start(url, with: self.emulator, presenting: self.view.window)
            }
        }
    }

    func remove(_ appsToRemove: [InstalledApp]) {
        guard canUninstall(appsToRemove) else { return }
        let alert = NSAlert()
        alert.messageText =
            appsToRemove.count == 1
            ? "Uninstall “\(displayName(appsToRemove[0]))”?"
            : "Uninstall \(appsToRemove.count) apps?"
        alert.informativeText =
            appsToRemove.count == 1
            ? "This removes the app and its data from the device."
            : "This removes the apps and their data from the device."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            // An install can finish while this confirmation is open, leaving
            // reachability temporarily unknown until the next probe. The
            // already accepted removal must still enter the queue.
            guard self.emulator.isRunning, self.emulator.canManageApps else {
                AppInstaller.presentError(
                    DeviceToolsError.failed(
                        "The \(emulator.profile.shortName) is unavailable. Try again when it reconnects."
                    ),
                    self.view.window
                )
                return
            }
            let remaining = appsToRemove.filter { !self.uninstalling.contains($0.id) }
            guard !remaining.isEmpty else { return }
            for app in remaining { self.uninstalling.insert(app.id) }
            self.reloadTablePreservingSelection()
            self.updateButtons()
            AppInstaller.remove(remaining, with: self.emulator, presenting: self.view.window) { app in
                self.removingApp = app.id
                self.reloadTablePreservingSelection()
            } didRemove: { app in
                self.uninstalling.remove(app.id)
                self.removingApp = nil
                self.apps.removeAll { $0.id == app.id }
                self.reloadTablePreservingSelection()
            } didFinish: {
                for app in remaining { self.uninstalling.remove(app.id) }
                self.removingApp = nil
                self.reloadTablePreservingSelection()
                self.updateButtons()
            }
        }
    }

    @objc func uninstallClicked(_ sender: NSMenuItem) {
        if let apps = sender.representedObject as? [InstalledApp] {
            remove(apps)
        } else if let app = sender.representedObject as? InstalledApp {
            remove([app])
        }
    }

    @objc func dismissInstallClicked(_ sender: NSMenuItem) {
        (sender.representedObject as? InstallJob)?.dismiss()
    }

    @objc func cancelInstallClicked(_ sender: NSMenuItem) {
        (sender.representedObject as? InstallJob)?.cancel()
    }

    /// Install on ▸ <device>: this device's retained copy, queued on the other one.
    @objc func installOnClicked(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? (file: URL, device: AnyObject),
            let emulator = target.device as? EmulatorController
        else { return }
        AppInstaller.start(target.file, with: emulator, presenting: view.window)
    }

    @objc func showInLegacyStoreClicked(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? InstalledApp else { return }
        // /app/<bundle_id> is a first-class route on the site (301s to the
        // canonical page); apps the archive doesn't know 404 there, which is
        // an honest answer.
        NSWorkspace.shared.open(CatalogClient.baseURL.appendingPathComponent("app/\(app.id)"))
    }

    @objc func resumeInstallsClicked(_ sender: Any?) {
        Task {
            guard await emulator.deviceReady() else {
                AppInstaller.presentError(DeviceError.notAttached, view.window)
                return
            }
            emulator.deviceReachable = true
            AppInstaller.resume(emulator.instance.id)
            hideStaleBanner()
            reloadTablePreservingSelection()
            updateButtons()
        }
    }

    @objc func refreshClicked(_ sender: Any?) {
        if searching {
            scheduleSearch()
            return
        }
        Task { await loadOnce() }
    }
}
