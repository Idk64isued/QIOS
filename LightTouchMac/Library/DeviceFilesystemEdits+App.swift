import Cocoa
import LightTouchCore

extension DeviceFilesystemEdits {
    /// The app's: volumes open in Finder, errors in an alert.
    static let shared = DeviceFilesystemEdits(
        open: { NSWorkspace.shared.open($0) },
        presentError: { NSApp.presentError($0) }
    )

    func perform(_ action: DeviceAction, entry: FirmwareCatalog.Entry, host: DeviceSessionHost) {
        perform(
            action,
            entry: entry,
            instance: host.instance(for: entry),
            library: host.library,
            releaseStopped: { await host.releaseStopped(for: entry) }
        )
    }

    func release(_ instance: DeviceInstance, entry: FirmwareCatalog.Entry, host: DeviceSessionHost, commit: Bool?)
        async throws
    {
        try await release(instance, library: host.library, commit: commit)
    }
}
