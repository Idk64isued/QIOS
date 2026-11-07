import Cocoa
import HostRuntime

/// The browser and transfer task survive closing this independently owned window.
final class DeviceFilesWindowController: NSWindowController {
    let browser: DeviceFilesViewController
    init(profile: Board) {
        browser = DeviceFilesViewController(profile: profile)
        let window = NSWindow(contentViewController: browser)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        // FIXME: Use morphology
        window.title = "\(profile.shortName) Files"
        window.setContentSize(NSSize(width: 660, height: 440))
        window.contentMinSize = NSSize(width: 360, height: 280)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = false
        if !WindowRestorationPolicy.configure(window, frameAutosaveName: "Files") { window.center() }
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        browser.focusBrowser()
    }
}
