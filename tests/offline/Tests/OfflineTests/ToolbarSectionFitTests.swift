import AppKit
import Testing

@testable import AppViews

extension SharedState {
    /// The main window's panes against the toolbar items above them (issue 107), laid out offscreen (never ordered
    /// in): at the sidebar's minimum the + sits clear of the toggle with at least the gap of flexible space between,
    /// for the default toolbar and for a customized sidebar section, and a width saved narrower comes back widened.
    @Suite struct ToolbarSectionFitTests {
        init() {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
        }

        /// Makes the main toolbar's items as its delegate does: bordered symbol buttons, and the tracking separators
        /// over the window's split view.
        final class Delegate: NSObject, NSToolbarDelegate {
            let ids: [NSToolbarItem.Identifier]
            weak var split: NSSplitViewController?
            init(_ ids: [NSToolbarItem.Identifier]) { self.ids = ids }

            func make(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
                let symbols: [NSToolbarItem.Identifier: (String, String)] = [
                    .addDevice: ("Add Device", "plus"), .home: ("Home Screen", "square.grid.3x3.fill"),
                    .lock: ("Lock", "lock"), .rotate: ("Rotate", "rotate.right"),
                    .openScreenshot: ("Open Screenshot", "arrow.up.forward.app"),
                    .screenshot: ("Save Screenshot", "square.and.arrow.down"),
                    .copyScreen: ("Copy Screenshot", "document.on.document"), .recording: ("Record", "record.circle")
                ]
                if id == .searchCatalog { return NSSearchToolbarItem(itemIdentifier: id) }
                if id == .zoom { return NSToolbarItem.zoom(target: self, action: #selector(NSObject.description)) }
                guard let (label, symbol) = symbols[id] else { return nil }
                return .button(id, label, symbol, #selector(NSObject.description), label, target: self)
            }

            func toolbar(
                _ toolbar: NSToolbar,
                itemForItemIdentifier id: NSToolbarItem.Identifier,
                willBeInsertedIntoToolbar flag: Bool
            ) -> NSToolbarItem? {
                guard let split else { return nil }
                switch id {
                case .sidebarTrackingSeparator:
                    return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 0)
                case .inspectorTrackingSeparator:
                    return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 1)
                default:
                    return make(id)
                }
            }
            func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
            func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
        }

        struct Built {
            let window: NSWindow
            let split: NSSplitViewController
            let delegate: Delegate
            var sidebar: NSSplitViewItem { split.splitViewItems[0] }
            var inspector: NSSplitViewItem { split.splitViewItems[2] }
        }

        /// The main window's panes, style and toolbar as MainWindowController builds them.
        static func build(_ ids: [NSToolbarItem.Identifier], autosave: String? = nil, fit: Bool = true) -> Built {
            let split = NSSplitViewController()
            func pane() -> NSViewController {
                let controller = NSViewController()
                controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
                return controller
            }
            let sidebar = NSSplitViewItem(sidebarWithViewController: pane())
            sidebar.minimumThickness = 180
            sidebar.maximumThickness = 320
            split.addSplitViewItem(sidebar)
            let device = NSSplitViewItem(viewController: pane())
            device.minimumThickness = 320
            split.addSplitViewItem(device)
            let inspector = NSSplitViewItem(inspectorWithViewController: pane())
            inspector.minimumThickness = 280
            inspector.maximumThickness = 400
            split.addSplitViewItem(inspector)
            if let autosave { split.splitView.autosaveName = autosave }
            let window = NSWindow(contentViewController: split)
            window.isReleasedWhenClosed = false
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 1100, height: 680))
            window.toolbarStyle = .unified
            let delegate = Delegate(ids)
            delegate.split = split
            let toolbar = NSToolbar(identifier: "ToolbarSectionFitTests-\(UUID().uuidString)")
            toolbar.delegate = delegate
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            if fit {
                ToolbarSectionFit.fitPanes(of: window, sidebarFloor: 180, inspectorFloor: 280, makeItem: delegate.make)
            }
            window.layoutIfNeeded()
            return Built(window: window, split: split, delegate: delegate)
        }

        static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

        /// The rendered items over the sidebar at its minimum: every one shows, clear of the window
        /// buttons and of each other, and the flexible space after the toggle (the gap between the toggle and the
        /// next item) is at least `gap`. Returns the sidebar's width there.
        @discardableResult
        func checkSidebarSection(_ ids: [NSToolbarItem.Identifier], _ what: String) -> CGFloat {
            let built = Self.build(ids)
            built.split.splitView.setPosition(built.sidebar.minimumThickness, ofDividerAt: 0)
            built.window.layoutIfNeeded()
            let width = built.split.splitViewItems[0].viewController.view.frame.width
            #expect(abs(width - built.sidebar.minimumThickness) < 1, "\(what): sidebar \(width) at its minimum")

            let section = ids[..<ids.firstIndex(of: .sidebarTrackingSeparator)!]
            let required = Set(section).subtracting([.flexibleSpace, .space])
            let visible = Set((built.window.toolbar?.visibleItems ?? []).map(\.itemIdentifier))
            #expect(required.isSubset(of: visible), "\(what): at \(width) pt only \(visible.map(\.rawValue)) show")

            // AppKit's item viewers (private, so matched by name) over the sidebar, left to right, spaces left out.
            let items = Self.descendants(built.window.contentView!.superview!)
                .filter { viewer in
                    "\(type(of: viewer))" == "NSToolbarItemViewer"
                        && !Self.descendants(viewer).contains { "\(type(of: $0))".contains("FlexibleSpace") }
                }
                .map { $0.convert($0.bounds, to: nil) }
                .filter { $0.maxX <= width + 0.5 && $0.width > 0 }
                .sorted { $0.minX < $1.minX }
            #expect(items.count == required.count, "\(what): \(items.count) items drawn over the sidebar at \(width)")
            for (left, right) in zip(items, items.dropFirst()) {
                #expect(left.maxX <= right.minX + 0.5, "\(what): \(left) overlaps \(right)")
            }
            let zoom = built.window.standardWindowButton(.zoomButton)!
            let lights = zoom.convert(zoom.bounds, to: nil)
            #expect((items.first?.minX ?? 0) >= lights.maxX, "\(what): first item under the window buttons")
            if section.starts(with: [.toggleSidebar, .flexibleSpace]), items.count > 1 {
                let space = items[1].minX - items[0].maxX
                #expect(space >= ToolbarSectionFit.gap - 0.5, "\(what): \(space) pt between toggle and + at \(width)")
            }
            return width
        }

        @Test func defaultSidebarSection() {
            checkSidebarSection(NSToolbarItem.Identifier.mainDefaults, "default toolbar")
        }

        @Test func customizedSidebarSection() {
            let ids: [NSToolbarItem.Identifier] = [
                .toggleSidebar, .flexibleSpace, .addDevice, .home, .lock, .sidebarTrackingSeparator, .rotate, .zoom,
                .flexibleSpace, .screenshot, .inspectorTrackingSeparator, .flexibleSpace, .searchCatalog,
                .toggleInspector
            ]
            checkSidebarSection(ids, "customized toolbar")
            // Every item added widens the section's minimum: measured, not a fixed number.
            #expect(
                Self.build(ids).sidebar.minimumThickness
                    > Self.build(NSToolbarItem.Identifier.mainDefaults).sidebar.minimumThickness
            )
        }

        /// The inspector's section the same way: the default fits the inspector's own 280 pt, and one customized past
        /// it raises the inspector's minimum; at the minimum every item of the section shows, its flexible space too.
        @Test func inspectorSection() {
            let crowded: [NSToolbarItem.Identifier] = [
                .toggleSidebar, .flexibleSpace, .addDevice, .sidebarTrackingSeparator, .zoom,
                .inspectorTrackingSeparator, .flexibleSpace, .home, .lock, .rotate, .openScreenshot, .screenshot,
                .copyScreen, .recording, .searchCatalog, .toggleInspector
            ]
            for (ids, what) in [(NSToolbarItem.Identifier.mainDefaults, "default"), (crowded, "crowded")] {
                let built = Self.build(ids)
                let minimum = built.inspector.minimumThickness
                #expect(what == "default" ? minimum == 280 : minimum > 280, "\(what): inspector minimum \(minimum)")
                let splitView = built.split.splitView
                splitView.setPosition(splitView.bounds.width - minimum - splitView.dividerThickness, ofDividerAt: 1)
                built.window.layoutIfNeeded()
                let width = built.split.splitViewItems[2].viewController.view.frame.width
                #expect(
                    width >= minimum - 0.5 && width <= minimum + 1,
                    "\(what): inspector \(width) at its minimum \(minimum)")
                let toolbar = built.window.toolbar!
                let section = toolbar.items.drop { $0.itemIdentifier != .inspectorTrackingSeparator }.dropFirst()
                let visible = toolbar.visibleItems ?? []
                let hidden = section.filter { item in !visible.contains { $0 === item } }.map(\.itemIdentifier.rawValue)
                #expect(hidden.isEmpty, "\(what): \(hidden) squeezed out at \(width)")
            }
        }

        /// A sidebar saved at the old 180 pt minimum comes back at the section's minimum.
        @Test func savedNarrowWidthIsClamped() {
            let name = "ToolbarSectionFitTests-\(UUID().uuidString)"
            let key = "NSSplitView Subview Frames \(name)"
            defer { UserDefaults.standard.removeObject(forKey: key) }
            // As AppKit saves it (x, y, width, height, collapsed, hidden), from a user who dragged it to 180.
            UserDefaults.standard.set(
                [
                    "0.000000, 0.000000, 180.000000, 680.000000, NO, NO",
                    "181.000000, 0.000000, 638.000000, 680.000000, NO, NO",
                    "820.000000, 0.000000, 280.000000, 680.000000, NO, NO"
                ],
                forKey: key
            )
            let old = Self.build(NSToolbarItem.Identifier.mainDefaults, autosave: name, fit: false)
            #expect(old.split.splitViewItems[0].viewController.view.frame.width == 180, "the saved width restores")
            let restored = Self.build(NSToolbarItem.Identifier.mainDefaults, autosave: name)
            let width = restored.split.splitViewItems[0].viewController.view.frame.width
            #expect(restored.sidebar.minimumThickness > 180)
            #expect(width >= restored.sidebar.minimumThickness - 0.5, "restored at \(width)")
        }
    }
}
