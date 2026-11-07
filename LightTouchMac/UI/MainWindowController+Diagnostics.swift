import Cocoa
import DeviceRuntime
import FirmwareSchema
import HostRuntime
import HostServiceWire
import LightTouchCore
import SwiftUI
import UniformTypeIdentifiers

extension MainWindowController {
    /// The selected device's serial and usbmuxd logs and session file, with
    /// the app-wide ones.
    private var diagnosticInstance: DeviceInstance? { session?.instance ?? selectedEntry.flatMap(host.instance(for:)) }
    var diagnosticLogs: [URL] {
        let app = ["app.log", "native.log"].map { Bundled.logsDirectory.appendingPathComponent($0) }
        let device = ["serial.log", "usbmuxd.log"].compactMap {
            diagnosticInstance?.paths.logs.appendingPathComponent($0)
        }
        return (app + device).flatMap { [$0, $0.appendingPathExtension("1")] }
    }

    @objc func showDeviceLogs(_ sender: Any?) {
        // A window per device: switching the selection opens that device's logs.
        if logWindow == nil || logInstance != diagnosticInstance?.id {
            logWindow?.close()
            logWindow = LogWindowController(logs: diagnosticLogs)
            logInstance = diagnosticInstance?.id
        }
        logWindow?.showWindow(sender)
    }

    /// A device's own identity, scrubbed from what leaves the Mac (DiagnosticsExport.scrub): its record's UDID, die
    /// ID and seed, and its lock's ECID, IMEI, MAC and UID options.
    static func identitySecrets(_ instance: DeviceInstance, lock: DeviceLock?) -> [String] {
        [instance.identity?.udid, instance.identity?.dieID, instance.identity?.seed].compactMap { $0 }
            + (lock?.machine ?? [:]).filter { $0.key.contains(/ecid|imei|iccid|meid|serial|mac|uid/) }
            .compactMap(\.value.optionText)
    }

    /// Help ▸ Copy Bug Report Info (AppDelegate's, so it works with the window closed): the selected device, then
    /// every other one with a session.
    func copyBugReportInfo() {
        let (devices, secrets) = bugReportDevices()
        BugReportCopy.copy(devices: devices, bezel: bugReportBezel, secrets: secrets)
    }

    private var bugReportBezel: String? { DisplayView.bezel == .model ? nil : "\(DisplayView.bezel)" }

    /// The selected device, then every other one with a session, and the identities to scrub from them.
    private func bugReportDevices() -> ([BugReportInfo.Device], [String]) {
        var instances = [selectedInstance].compactMap { $0 }
        instances += host.sessions.map(\.instance).filter { s in !instances.contains { $0.id == s.id } }
        var secrets: [String] = []
        let devices = instances.compactMap { instance -> BugReportInfo.Device? in
            guard let entry = host.catalog.entry(id: instance.firmware) else { return nil }
            let emulator = host.sessions.first { $0.instance.id == instance.id }?.emulator
            let settings = DeviceSettings.load(instance.paths.directory)
            let lock = try? DeviceLock.read(base: instance.paths.base)
            secrets += Self.identitySecrets(instance, lock: lock)
            var device = BugReportInfo.Device(
                marketingName: entry.marketingName,
                board: instance.board,
                iosVersion: entry.version,
                iosBuild: entry.build,
                entryID: entry.id,
                state: emulator?.statusLine ?? "Not running",
                localNetwork: emulator?.localNetworkEnabled ?? settings.localNetwork ?? false
            )
            device.panel = instance.panel
            device.internet = emulator?.network
            if let lock { device.readPreparation(lock) }
            device.prepared = instance.created
            let paths = instance.paths
            device.readStorage(
                directory: paths.directory,
                format: instance.format,
                migrates: paths.base.path.hasPrefix(paths.directory.path + "/"),
                overlay: paths.overlay,
                firmwareLog: paths.logs.appendingPathComponent("firmwarekit.log")
            )
            device.readSettings(
                settings,
                proxy: WebProxyConfiguration.load(from: WebProxyConfiguration.directory(for: instance)),
                accessibilityOn: emulator?.accessibilityOn
            )
            if instance.profile?.hasCellular == true {
                device.carrier = emulator?.carrierSettings ?? settings.carrier ?? CarrierSettings()
            }
            if let emulator {
                let state = emulator.guestToolsState
                device.guestTools =
                    "\(state.text) (\(state))"
                    + (emulator.guestOffer.map { "; offered \($0.version), serial \($0.serial)" } ?? "")
                device.emulatorBuild = emulator.process?.info?.buildID
            } else if let guest = instance.guest {
                device.guestTools = "last serial \(guest.active.map(String.init) ?? "unknown"), not running"
            }
            if emulator != nil, emulator === self.emulator {
                if zoom != .fit { device.zoom = zoom.defaultsValue }
                if let inspector = inspectorVC, inspector.haveLoaded { device.apps = inspector.apps }
            }
            return device
        }
        return (devices, secrets)
    }

    @objc func exportDiagnostics(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Light Touch Diagnostics.zip"
        if let zip = UTType(filenameExtension: "zip") { panel.allowedContentTypes = [zip] }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let dest = panel.url else { return }
            Task { await self.writeDiagnostics(to: dest) }
        }
    }

    private func writeDiagnostics(to dest: URL) async {
        await AppEventLog.shared.flush()
        NativeLogging.flush()
        let logs = ["app.log", "native.log"].map { Bundled.logsDirectory.appendingPathComponent($0) }
        // the device's own, and the preparation log of its catalog entry
        var deviceLogs: [URL] = []
        if let instance = diagnosticInstance {
            deviceLogs =
                ["serial.log", "usbmuxd.log", "native.log", "firmwarekit.log"].map {
                    instance.paths.logs.appendingPathComponent($0)
                } + [Bundled.logsDirectory.appendingPathComponent("Preparing/\(instance.firmware).log")]
        }
        let device =
            emulator.map { emulator in
                """
                \(emulator.dylibProvenance)
                state: \(emulator.statusLine)
                guest tools: \(emulator.guestToolsStatus) (offer \(emulator.guestOffer.map { "\($0)" } ?? "none"))
                base: \(emulator.instance.base.path)
                network: \(emulator.network)   usbmuxd: \(emulator.usbmuxSession ?? "none")
                canManageApps: \(emulator.canManageApps)
                """
            } ?? "state: not running"
        let executables =
            Bundle.main.executableURL.flatMap {
                try? FileManager.default.contentsOfDirectory(atPath: $0.deletingLastPathComponent().path)
            } ?? []
        let reports = DiagnosticsExport.crashReports(executables: executables)
        let (devices, secrets) = bugReportDevices()
        let info = """
            LightTouchMac diagnostics
            crash reports: \(reports.isEmpty ? "none in the last 30 days" : reports.map(\.lastPathComponent).joined(separator: ", "))
            device: \(diagnosticInstance.map { "\($0.name) \($0.firmware) \($0.id)" } ?? "none")
            \(device)

            Copy Bug Report Info:
            \(BugReportCopy.text(devices: devices, bezel: bugReportBezel, secrets: secrets))
            """
        do {
            let deviceSecrets = diagnosticInstance.map {
                Self.identitySecrets($0, lock: try? DeviceLock.read(base: $0.paths.base))
            }
            try await DiagnosticsExport.write(
                to: dest,
                logs: logs.flatMap { [$0, $0.appendingPathExtension("1")] },
                deviceLogs: deviceLogs.flatMap { [$0, $0.appendingPathExtension("1")] },
                info: info,
                crashReports: reports,
                secrets: secrets + (deviceSecrets ?? [])
            )
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch is CancellationError {
            // The exporter waits for its child to stop before removing scratch.
        } catch {
            if let window { await NSAlert(error: error).beginSheetModal(for: window) }
        }
    }
}
