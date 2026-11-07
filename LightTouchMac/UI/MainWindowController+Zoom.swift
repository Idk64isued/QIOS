import Cocoa
import LightTouchCore

// The window's zoom: the toolbar's segmented control, the View menu's zoom items and ⌘+/−, one ZoomMode applied to
// the device view and remembered per board (ZoomMode.saved). The device view is the source of truth; the toolbar
// and the menu read it through one rule (ZoomContext.canStep).

extension MainWindowController {
    @objc private func zoomSegmentClicked(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: zoomOut(sender)
        case 1: zoomToFit(sender)
        default: zoomIn(sender)
        }
    }

    var zoom: ZoomMode { deviceVC?.screen.zoom ?? .fit }

    func apply(_ mode: ZoomMode) {
        guard let screen = deviceVC?.screen else { return }
        screen.zoom = mode
        mode.save(for: screen.profile)
        syncZoomControls()
    }

    /// Gray out a direction there is no room left in, on every zoom item in the toolbar.
    func syncZoomControls() {
        for item in window?.toolbar?.items ?? [] where item.itemIdentifier == .zoom {
            if let control = item.view as? NSSegmentedControl { syncZoomControl(control) }
        }
    }

    private func syncZoomControl(_ control: NSSegmentedControl) {
        let screen = deviceVC?.screen
        control.setEnabled(
            screen.map { $0.zoomContext.canStep(from: $0.zoomPoints, direction: -1) } ?? false,
            forSegment: 0
        )
        control.setEnabled(screen != nil, forSegment: 1)
        control.setEnabled(
            screen.map { $0.zoomContext.canStep(from: $0.zoomPoints, direction: 1) } ?? false,
            forSegment: 2
        )
    }

    /// One stop along the ladder and the named sizes, from ⌘+ / ⌘− and the toolbar, starting from the size on
    /// screen whatever produced it. (A pinch is the guest's.)
    func stepZoom(_ direction: Int) {
        guard let screen = deviceVC?.screen,
            let mode = screen.zoomContext.step(from: screen.zoomPoints, direction: direction)
        else { return }
        apply(mode)
    }

    @objc func zoomIn(_ sender: Any?) { stepZoom(1) }
    @objc func zoomOut(_ sender: Any?) { stepZoom(-1) }
    @objc func zoomPhysicalSize(_ sender: Any?) { apply(.physical) }
    @objc func zoomToFit(_ sender: Any?) { apply(.fit) }
    @objc func zoomPixelAccurate(_ sender: Any?) { apply(.pixelAccurate) }

    func makeZoomToolbarItem() -> NSToolbarItem {
        let item = NSToolbarItem.zoom(target: self, action: #selector(zoomSegmentClicked(_:)))
        if let control = item.view as? NSSegmentedControl { syncZoomControl(control) }
        return item
    }

    /// Enablement and checkmarks for the View menu's zoom items.
    func validateZoomItem(_ menuItem: NSMenuItem, screen: DisplayView) -> Bool {
        let context = screen.zoomContext
        let shown = context.shown(screen.zoom)
        switch menuItem.action {
        case #selector(zoomIn(_:)):
            return context.canStep(from: screen.zoomPoints, direction: 1)
        case #selector(zoomOut(_:)):
            return context.canStep(from: screen.zoomPoints, direction: -1)
        case #selector(zoomPhysicalSize(_:)):
            menuItem.state = shown == .physical ? .on : .off
            menuItem.toolTip = context.physical == nil ? "This display doesn’t report its size." : nil
            return context.physical != nil
        case #selector(zoomToFit(_:)):
            menuItem.state = shown == .fit ? .on : .off
            return true
        case #selector(zoomPixelAccurate(_:)):
            menuItem.state = shown == .pixelAccurate ? .on : .off
            return true
        default:
            return true
        }
    }
}
