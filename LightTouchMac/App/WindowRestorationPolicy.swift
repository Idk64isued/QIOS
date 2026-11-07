import Cocoa

/// Every launch builds a new Mac interface (and RestorationDefaults turns AppKit's saved state off for the
/// process). This does not govern guest snapshots or the explicit capture/toolbar preferences stored by the app.
enum WindowRestorationPolicy {
    /// No restoration. `frameAutosaveName` keeps just the window's frame in the
    /// defaults (not its contents); returns true when a saved frame was applied.
    @discardableResult
    static func configure(_ window: NSWindow, frameAutosaveName: String = "") -> Bool {
        window.isRestorable = false
        window.restorationClass = nil
        window.disableSnapshotRestoration()
        let restored = !frameAutosaveName.isEmpty && window.setFrameUsingName(frameAutosaveName)
        window.setFrameAutosaveName(frameAutosaveName)
        return restored
    }
}

/// AppKit's restoration funnel remains closed even if an older saved archive
/// survives an upgrade or a launch request explicitly asks to restore it.
@objc(LightTouchApplication)
final class LightTouchApplication: NSApplication {
    override func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
    ) -> Bool {
        completionHandler(nil, nil)
        return true
    }

    // Intentionally omit super: it would encode/decode AppKit's saved interface.
    override func restoreState(with coder: NSCoder) {}
    override func encodeRestorableState(with coder: NSCoder) {}
    override func encodeRestorableState(with coder: NSCoder, backgroundQueue: OperationQueue) {}
}
