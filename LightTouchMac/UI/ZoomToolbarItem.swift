import Cocoa

extension NSToolbarItem {
    static let zoomIdentifier = NSToolbarItem.Identifier("zoom")

    /// The toolbar's zoom item: out, zoom to fit, in. Each item gets a segmented control of its own: a view lives in
    /// one place, and the customization palette asks for an item of its own, so one control shared by every item moved
    /// into the palette and left the toolbar's zoom item empty and unclickable.
    static func zoom(target: AnyObject, action: Selector) -> NSToolbarItem {
        let control = NSSegmentedControl()
        // Momentary, because all are commands rather than states to sit in: which state you are in is the menu's job,
        // where the checkmarks live.
        control.segmentCount = 3
        control.trackingMode = .momentary
        control.segmentStyle = .separated
        let symbols = [
            ("minus.magnifyingglass", "Zoom Out", "⌘−"),
            ("arrow.up.left.and.down.right.magnifyingglass", "Zoom to Fit", "⌘0"),
            ("plus.magnifyingglass", "Zoom In", "⌘+")
        ]
        for (index, (symbol, label, key)) in symbols.enumerated() {
            control.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label), forSegment: index)
            control.setToolTip("\(label) (\(key))", forSegment: index)
        }
        control.target = target
        control.action = action
        control.sizeToFit()
        let item = NSToolbarItem(itemIdentifier: zoomIdentifier)
        item.label = "Zoom"
        item.paletteLabel = "Zoom"
        item.toolTip = "Change the device’s size"
        item.view = control
        return item
    }
}
