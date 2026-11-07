// The main window's toolbar items, and the panes under its tracking separators sized so the items above them fit.

import Cocoa

extension NSToolbarItem.Identifier {
    static let files = NSToolbarItem.Identifier("files")
    static let motion = NSToolbarItem.Identifier("motion")
    static let screenshot = NSToolbarItem.Identifier("screenshot")
    static let recording = NSToolbarItem.Identifier("recording")
    static let saveScreenshotAs = NSToolbarItem.Identifier("saveScreenshotAs")
    static let openScreenshot = NSToolbarItem.Identifier("openScreenshot")
    static let captureOptions = NSToolbarItem.Identifier("captureOptions")
    static let liveText = NSToolbarItem.Identifier("liveText")
    static let copyScreen = NSToolbarItem.Identifier("copyScreen")
    static let fingerDots = NSToolbarItem.Identifier("fingerDots")
    static let home = NSToolbarItem.Identifier("home")
    static let lock = NSToolbarItem.Identifier("lock")
    static let rotate = NSToolbarItem.Identifier("rotate")
    static let zoom = NSToolbarItem.zoomIdentifier
    static let installApp = NSToolbarItem.Identifier("installApp")
    static let searchCatalog = NSToolbarItem.Identifier("searchCatalog")
    static let addDevice = NSToolbarItem.Identifier("addDevice")

    /// The main toolbar's default set: frequent capture actions live beside the device controls.
    static let mainDefaults: [NSToolbarItem.Identifier] = [
        .toggleSidebar, .flexibleSpace, .addDevice, .sidebarTrackingSeparator, .home, .lock, .rotate, .zoom,
        .flexibleSpace,
        .openScreenshot, .screenshot, .copyScreen, .recording,
        .inspectorTrackingSeparator, .flexibleSpace, .searchCatalog, .toggleInspector
    ]
}

extension NSToolbarItem {
    /// A bordered symbol button, the main toolbar's usual item.
    static func button(
        _ id: NSToolbarItem.Identifier,
        _ label: String,
        _ symbol: String,
        _ action: Selector,
        _ help: String,
        target: AnyObject?
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = help
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = target
        item.action = action
        item.isBordered = true
        if id == .liveText || id == .fingerDots {
            let control = NSButton(image: item.image ?? NSImage(), target: target, action: action)
            control.setButtonType(.pushOnPushOff)
            control.bezelStyle = .texturedRounded
            control.toolTip = help
            control.setAccessibilityLabel(label)
            item.view = control
        }
        return item
    }
}

/// The sidebar and the inspector never get narrower than the toolbar items above them need (issue 107). A sidebar
/// left at its old 180 pt minimum squeezed the toggle and + against the window buttons; macOS 27.2 drew the + as an
/// empty circle and spun the CPU re-laying it out. The need is measured, not assumed: the window's panes and toolbar
/// go in an offscreen copy, traffic lights included, and the narrowest pane at which AppKit shows every item of its
/// section (the ones before the sidebar's tracking separator, or after the inspector's), plus `gap`, is the pane's
/// minimum. A width saved narrower is widened by the split view to the new minimum.
enum ToolbarSectionFit {
    /// Room left between the section's items at the minimum, so they never sit at the edge of being squeezed.
    static let gap: CGFloat = 16

    /// Raises the sidebar's and the inspector's minimum (each never below its `floor`, what its own content needs)
    /// to what `window`'s toolbar section above it needs. `makeItem` makes an item like the toolbar's delegate does.
    static func fitPanes(
        of window: NSWindow,
        sidebarFloor: CGFloat,
        inspectorFloor: CGFloat,
        makeItem: (NSToolbarItem.Identifier) -> NSToolbarItem?
    ) {
        guard let split = window.contentViewController as? NSSplitViewController, let toolbar = window.toolbar else {
            return
        }
        let measuring = Measuring(
            like: window, split: split, ids: toolbar.items.map(\.itemIdentifier), makeItem: makeItem)
        for (index, pane) in split.splitViewItems.enumerated() {
            let floor: CGFloat
            switch pane.behavior {
            case .sidebar: floor = sidebarFloor
            case .inspector: floor = inspectorFloor
            default: continue
            }
            pane.minimumThickness = max(floor, measuring.narrowest(paneAt: index).map { $0 + gap } ?? 0)
            pane.maximumThickness = max(pane.maximumThickness, pane.minimumThickness)
        }
    }

    /// An offscreen copy of the window (never ordered in): its style (the traffic lights), panes and whole toolbar.
    private final class Measuring: NSObject, NSToolbarDelegate {
        static let widest: CGFloat = 1000
        let window: NSWindow
        let split = NSSplitViewController()
        let ids: [NSToolbarItem.Identifier]
        var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
        let contentWidth = 3 * widest

        init(
            like original: NSWindow,
            split originalSplit: NSSplitViewController,
            ids: [NSToolbarItem.Identifier],
            makeItem: (NSToolbarItem.Identifier) -> NSToolbarItem?
        ) {
            self.ids = ids
            for original in originalSplit.splitViewItems {
                let content = NSViewController()
                content.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
                let item: NSSplitViewItem
                switch original.behavior {
                case .sidebar: item = NSSplitViewItem(sidebarWithViewController: content)
                case .inspector: item = NSSplitViewItem(inspectorWithViewController: content)
                default: item = NSSplitViewItem(viewController: content)
                }
                item.minimumThickness = 0
                if item.behavior != .default { item.maximumThickness = Self.widest }
                split.addSplitViewItem(item)
            }
            window = NSWindow(contentViewController: split)
            super.init()
            for id in ids where items[id] == nil { items[id] = makeItem(id) }
            window.isReleasedWhenClosed = false
            window.styleMask = original.styleMask.subtracting(.fullScreen)
            window.toolbarStyle = original.toolbarStyle
            window.setContentSize(NSSize(width: contentWidth, height: 200))
            let toolbar = NSToolbar(identifier: "ToolbarSectionFit-\(UUID().uuidString)")
            toolbar.delegate = self
            toolbar.displayMode = original.toolbar?.displayMode ?? .iconOnly
            window.toolbar = toolbar
        }

        /// The narrowest whole-point width of the sidebar or inspector at `index` at which the toolbar shows every item
        /// of the section over it, its spaces too: AppKit squeezes a section's items once its flexible space is gone
        /// (and drops that space from the visible items) before it moves any into the overflow menu. Nil for a
        /// section with nothing in it.
        func narrowest(paneAt index: Int) -> CGFloat? {
            let items = window.toolbar?.items ?? []
            let ids = items.map(\.itemIdentifier)
            let section =
                split.splitViewItems[index].behavior == .sidebar
                ? ids.firstIndex(of: .sidebarTrackingSeparator).map { items[..<$0] } ?? []
                : ids.firstIndex(of: .inspectorTrackingSeparator).map { items[($0 + 1)...] } ?? []
            guard !section.isEmpty else { return nil }
            let last = split.splitViewItems.count - 1
            func fits(_ width: CGFloat) -> Bool {
                if index == last {
                    let position = contentWidth - width - split.splitView.dividerThickness
                    split.splitView.setPosition(position, ofDividerAt: last - 1)
                } else {
                    split.splitView.setPosition(width, ofDividerAt: index)
                }
                window.layoutIfNeeded()
                let visible = window.toolbar?.visibleItems ?? []
                return section.allSatisfy { item in visible.contains { $0 === item } }
            }
            var (low, high) = (CGFloat(0), Self.widest)
            guard fits(high) else { return high }
            while high - low > 1 {
                let middle = ((low + high) / 2).rounded(.down)
                if fits(middle) { high = middle } else { low = middle }
            }
            return high
        }

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier id: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            switch id {
            case .sidebarTrackingSeparator:
                NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 0)
            case .inspectorTrackingSeparator:
                NSTrackingSeparatorToolbarItem(
                    identifier: id,
                    splitView: split.splitView,
                    dividerIndex: split.splitViewItems.count - 2
                )
            default:
                items[id]
            }
        }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    }
}
