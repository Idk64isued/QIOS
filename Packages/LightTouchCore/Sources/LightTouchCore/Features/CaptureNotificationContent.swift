import Foundation
import HostRuntime
import UserNotifications

/// What capture and device notifications say, and the identity their actions find again (CaptureNotifications posts them).
public enum CaptureNotificationContent {
    public nonisolated static let readyCategory = "DEVICE_READY"

    public static func ready(_ name: String, entryID: String) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(name) is ready to use"
        content.categoryIdentifier = readyCategory
        content.userInfo = ["entry": entryID]
        return content
    }
}
