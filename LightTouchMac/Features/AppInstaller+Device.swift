// The install queue (LightTouchCore's AppInstaller) on a running device: EmulatorController is its
// InstallDevice, and its alerts are AppKit's.

import Cocoa
import HostServiceClient
import LightTouchCore

extension EmulatorController: InstallDevice {
    func prepareMedia(_ source: URL) async throws -> PreparedMedia {
        try await PreparedMedia.prepare(source, profile: profile)
    }

    func installPlaceholder(_ action: String, bundleID: String, after previous: Task<Void, Never>?) -> Task<
        Void, Never
    >? {
        (try? installPipeline)?.installPlaceholder(action, bundleID: bundleID, after: previous)
    }

    func uninstall(_ bundleID: String) async throws { try await services.uninstall(bundleID) }

    func present(_ error: Error, in window: AnyObject?) { AppInstaller.presentError(error, window as? NSWindow) }

    func warnMayNotLaunch(_ appName: String, in window: AnyObject?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(appName)” installed, but may not launch"
        let version = iosVersion
        alert.informativeText =
            "It needs a newer version of iOS than \(version). "
            + "Look for a version built for iOS \(version.split(separator: ".").first ?? "3") or earlier."
        if let window = window as? NSWindow { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
    }
}

extension AppInstaller {
    /// A failed removal's (or a refused command's) alert.
    static func presentError(_ error: Error, _ window: NSWindow?) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
