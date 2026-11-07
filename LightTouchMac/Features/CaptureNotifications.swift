import Cocoa
import HostRuntime
import LightTouchCore
import UserNotifications

/// The "ready to use" notification for a device that finished preparing while another was selected. Merely creating
/// the service never prompts for access.
@MainActor
final class CaptureNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CaptureNotifications()
    /// A "ready to use" notification was clicked: its catalog entry id.
    var onShowDevice: ((String) -> Void)?

    private let center: UNUserNotificationCenter
    private nonisolated static let readyCategory = CaptureNotificationContent.readyCategory

    private override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    private func requestAuthorization() async -> Bool {
        do { return try await center.requestAuthorization(options: [.alert]) } catch { return false }
    }

    /// A device finished preparing while another was selected. Asks for permission the first time it has news.
    func notifyReady(_ name: String, entryID: String) async {
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = await requestAuthorization()
            settings = await center.notificationSettings()
        }
        guard Self.canPresent(settings) else { return }
        try? await center.add(
            UNNotificationRequest(
                identifier: "device-ready-\(entryID)",
                content: CaptureNotificationContent.ready(name, entryID: entryID),
                trigger: nil
            )
        )
    }

    private static func canPresent(_ settings: UNNotificationSettings) -> Bool {
        (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
            && ((settings.alertSetting == .enabled && settings.alertStyle != .none)
                || settings.notificationCenterSetting == .enabled)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(
            notification.request.content.categoryIdentifier == Self.readyCategory ? [.banner, .list] : []
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        if content.categoryIdentifier == Self.readyCategory, let id = content.userInfo["entry"] as? String {
            await showDevice(id)
        }
    }

    private func showDevice(_ id: String) { onShowDevice?(id) }
}
