import Cocoa
import LightTouchCore

extension FirmwareJobs {
    /// The app's jobs over its library; errors with no row to show them on go to an alert.
    static let shared = FirmwareJobs(presentError: { NSApp.presentError($0) })
}
