import Cocoa
import LightTouchCore

/// Help ▸ Copy Bug Report Info: the block (BugReportInfo) on the pasteboard, announced for VoiceOver; the menu's own
/// flash is the visual confirmation, as with any Copy.
enum BugReportCopy {
    static let title = "Copy Bug Report Info"

    /// The block, with the app-wide facts read here (free space on the library's volume, 120 Hz, ANGLE, clipboard sharing,
    /// the steps CrashGuard skips).
    static func text(devices: [BugReportInfo.Device], bezel: String? = nil, secrets: [String] = []) -> String {
        BugReportInfo.text(
            system: DiagnosticsExport.systemSummary(),
            freeSpace: try? Bundled.stateDirectory.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ])
            .volumeAvailableCapacityForImportantUsage,
            bezel: bezel,
            refresh120: DisplayRefresh.hz == 120,
            angle: ANGLERenderer.isOn,
            shareClipboard: ClipboardSync.enabled,
            skippedAfterCrash: CrashGuard.Step.allCases.filter(CrashGuard.skips).map(\.title),
            devices: devices,
            recentErrors: BugReportInfo.recentErrors(log: Bundled.logsDirectory.appendingPathComponent("app.log")),
            secrets: secrets
        )
    }

    @discardableResult
    static func copy(
        devices: [BugReportInfo.Device],
        bezel: String? = nil,
        secrets: [String] = [],
        to pasteboard: NSPasteboard = .general
    ) -> String {
        let text = text(devices: devices, bezel: bezel, secrets: secrets)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let app = NSApp {
            NSAccessibility.post(
                element: app,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "Bug report info copied", .priority: NSAccessibilityPriorityLevel.medium.rawValue
                ]
            )
        }
        return text
    }
}
