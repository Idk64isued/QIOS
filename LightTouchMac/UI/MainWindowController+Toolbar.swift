import Cocoa
import FirmwareSchema
import HostRuntime
import HostServiceWire
import LightTouchCore
import SwiftUI
import UniformTypeIdentifiers

extension MainWindowController {
    // MARK: - Toolbar

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch id {
        case .addDevice:
            return button(id, "Add Device", "plus", #selector(addDevice(_:)), "Add Device")
        case .screenshot:
            return button(
                id,
                "Save Screenshot",
                "square.and.arrow.down",
                #selector(saveScreenshot(_:)),
                "Save Screenshot (⌘S)"
            )
        case .recording:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = RecordingToolbarButton(target: self, action: #selector(toggleRecording(_:)))
            item.target = self
            item.action = #selector(toggleRecording(_:))
            item.label = "Record"
            item.paletteLabel = "Record"
            item.visibilityPriority = .high
            item.isEnabled = validateToolbarItem(item)
            return item
        case .saveScreenshotAs:
            return button(
                id,
                "Save Screenshot As…",
                "square.and.arrow.down.on.square",
                #selector(saveScreenshotAs(_:)),
                "Save Screenshot As… (⇧⌘S)"
            )
        case .openScreenshot:
            return button(
                id,
                "Open Screenshot",
                "arrow.up.forward.app",
                #selector(openScreenshot(_:)),
                "Open Screenshot"
            )
        case .captureOptions:
            return button(
                id,
                "Capture Options",
                "slider.horizontal.3",
                #selector(showCaptureOptions(_:)),
                "Change screenshot and recording settings"
            )
        case .liveText:
            return button(
                id,
                "Select Text on Screen",
                "text.viewfinder",
                #selector(showLiveText(_:)),
                "Select text on the device screen"
            )
        case .copyScreen:
            return button(
                id,
                "Copy Screenshot",
                "document.on.document",
                #selector(copyScreen(_:)),
                "Copy Screenshot (⌘C)"
            )
        case .fingerDots:
            return button(
                id,
                "Show Finger Dots",
                "hand.draw",
                #selector(toggleTouchOverlay(_:)),
                "Show touches on screen and in captures"
            )
        case .motion:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Motion"
            item.paletteLabel = "Motion Controls"
            item.image = NSImage(systemSymbolName: "move.3d", accessibilityDescription: "Motion Controls")
            item.toolTip = "Tilt, level, or shake the device"
            item.showsIndicator = true
            item.isBordered = true
            item.menu = MainMenuBuilder.motionMenu(target: self)
            return item
        case .files:
            return button(
                id,
                "\(currentProfile.shortName) Files",
                "folder",
                #selector(toggleFiles(_:)),
                "Show \(currentProfile.shortName) Files (⌘2)"
            )
        case .home:
            return button(id, "Home Screen", "square.grid.3x3.fill", #selector(deviceHome(_:)), "Home Screen (⇧⌘H)")
        case .lock:
            return button(id, "Lock", "lock", #selector(deviceLock(_:)), "Lock (⌘L)")
        case .rotate:
            let action = RotationControlAction(
                rotationDegrees: emulator?.rotationDegrees ?? 0,
                optionPressed: NSEvent.modifierFlags.contains(.option)
            )
            return button(id, action.title, action.symbol, #selector(deviceRotate(_:)), action.help)
        case .installApp:
            return button(id, "Install App", "plus.app", #selector(installApp(_:)), "Install apps from .ipa files")
        case .searchCatalog:
            // The inspector owns the field (its text drives the catalog/installed
            // mode switch); the toolbar is just where it lives — the standard
            // Mac home for search, riding above the inspector pane thanks to
            // the tracking separator.
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.label = "Search Apps"
            item.paletteLabel = "Search Apps"
            item.toolTip = "Search Installed Apps or Store (⌥⌘F)"
            if flag { inspectorVC?.attachSearchField(to: item) }
            return item
        case .zoom:
            return makeZoomToolbarItem()
        case .inspectorTrackingSeparator:
            // Must be supplied explicitly with the split view and the divider
            // it tracks. Listing the identifier alone got it silently dropped,
            // so the toolbar never split at the divider — which is why the
            // inspector's material stopped at the toolbar instead of running
            // top to bottom, and the toggle floated over the device pane
            // instead of sitting above the inspector (compare Xcode).
            guard let split = contentSplitViewController else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: id,
                splitView: split.splitView,
                dividerIndex: 1
            )
        case .sidebarTrackingSeparator:
            // The same, for the divider between the sidebar and the device.
            guard let split = contentSplitViewController else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: id,
                splitView: split.splitView,
                dividerIndex: 0
            )
        default:
            return nil
        }
    }

    var contentSplitViewController: NSSplitViewController? {
        window?.contentViewController as? NSSplitViewController
    }

    func button(
        _ id: NSToolbarItem.Identifier,
        _ label: String,
        _ symbol: String,
        _ action: Selector,
        _ help: String
    ) -> NSToolbarItem {
        .button(id, label, symbol, action, help, target: self)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        NSToolbarItem.Identifier.mainDefaults
    }

    /// The sidebar and inspector stay wide enough for the toolbar items above them (ToolbarSectionFit), also after
    /// the toolbar is customized.
    func fitPanesToToolbar() {
        paneFitPending = false
        guard let window, let toolbar = window.toolbar else { return }
        ToolbarSectionFit.fitPanes(of: window, sidebarFloor: Self.sidebarFloor, inspectorFloor: Self.inspectorFloor) {
            self.toolbar(toolbar, itemForItemIdentifier: $0, willBeInsertedIntoToolbar: false)
        }
    }

    /// Once for a run of changes (the toolbar adds its items one by one), after them: an added item isn't among the
    /// toolbar's items yet when it is announced.
    func fitPanesToToolbarLater() {
        guard !paneFitPending else { return }
        paneFitPending = true
        DispatchQueue.main.async { [weak self] in
            if self?.paneFitPending == true { self?.fitPanesToToolbar() }
        }
    }

    func toolbarWillAddItem(_ notification: Notification) { fitPanesToToolbarLater() }

    func toolbarDidRemoveItem(_ notification: Notification) { fitPanesToToolbarLater() }

    /// Add the actions displaced from the removed floating bar once. Preserve
    /// existing customization and subsequent choices to remove toolbar items.
    func migrateCaptureToolbar(_ toolbar: NSToolbar) {
        guard !UserDefaults.standard.bool(forKey: "captureToolbarMigrated") else { return }
        for id: NSToolbarItem.Identifier in [.home, .rotate, .openScreenshot, .screenshot, .copyScreen, .recording]
        where !toolbar.items.contains(where: { $0.itemIdentifier == id }) {
            let index =
                toolbar.items.firstIndex { $0.itemIdentifier == .inspectorTrackingSeparator } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: id, at: index)
        }
        UserDefaults.standard.set(true, forKey: "captureToolbarMigrated")
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .addDevice, .files, .home, .lock, .rotate, .motion, .zoom, .screenshot, .recording, .saveScreenshotAs,
            .openScreenshot, .captureOptions, .liveText, .copyScreen, .fingerDots, .installApp, .searchCatalog,
            .space, .flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, .inspectorTrackingSeparator,
            .toggleInspector
        ]
    }

    /// Add Device arrived after toolbars were saved: once, at the sidebar's trailing edge.
    func migrateAddDeviceToolbar(_ toolbar: NSToolbar) {
        guard !UserDefaults.standard.bool(forKey: "addDeviceToolbarMigrated") else { return }
        if !toolbar.items.contains(where: { $0.itemIdentifier == .addDevice }),
            let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .sidebarTrackingSeparator })
        {
            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: index)
            toolbar.insertItem(withItemIdentifier: .addDevice, at: index + 1)
        }
        UserDefaults.standard.set(true, forKey: "addDeviceToolbarMigrated")
    }

    /// The sidebar arrived after toolbars were saved; give them its toggle and
    /// separator once, in front, without disturbing the rest.
    func migrateSidebarToolbar(_ toolbar: NSToolbar) {
        guard !toolbar.items.contains(where: { $0.itemIdentifier == .sidebarTrackingSeparator }) else { return }
        toolbar.insertItem(withItemIdentifier: .sidebarTrackingSeparator, at: 0)
        if !toolbar.items.contains(where: { $0.itemIdentifier == .toggleSidebar }) {
            toolbar.insertItem(withItemIdentifier: .toggleSidebar, at: 0)
        }
    }
}

// MARK: - Toolbar item validation (same command model as the menus)

extension MainWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .captureOptions, .files, .motion, .searchCatalog, .toggleSidebar: return true
        case .addDevice: return window?.attachedSheet == nil
        default: break
        }
        guard let emulator, let deviceVC else {
            (item.view as? NSControl)?.isEnabled = false
            if item.itemIdentifier == .lock { item.show(label: "Lock", toolTip: "Lock (⌘L)", symbol: "lock") }
            if item.itemIdentifier == .recording {
                (item.view as? RecordingToolbarButton)?.update(
                    .idle,
                    elapsed: recording.elapsed,
                    enabled: canToggleRecording
                )
                return canToggleRecording
            }
            return false
        }
        // Custom views keep their own enabled state; the cases below narrow it. Live Text sets its own: enabling it here
        // first flipped a disabled button on and off at every validation, which AppKit runs after each event.
        if item.itemIdentifier != .recording, item.itemIdentifier != .liveText, let control = item.view as? NSControl,
            !control.isEnabled
        {
            control.isEnabled = true
        }
        switch item.itemIdentifier {
        // Install is NOT gated on isInstalling: AppInstaller queues jobs behind
        // one another, so choosing a second .ipa mid-install is supported and
        // blocking it was a regression. The terminal is gated, because it opens
        // a competing lockdown session.
        case .screenshot:
            return canTakeScreenshot
        case .copyScreen:
            item.show(
                symbol: capture.copiedScreenshot ? "checkmark.circle" : "document.on.document",
                symbolDescription: "Copy Screenshot"
            )
            return canTakeScreenshot
        case .recording:
            let phase: RecordingToolbarButton.Phase =
                recording.phase == .saving
                ? .saving
                : recording.canStop ? .recording : .idle
            (item.view as? RecordingToolbarButton)?.update(
                phase,
                elapsed: recording.elapsed,
                enabled: canToggleRecording
            )
            item.show(label: "Record", toolTip: (item.view as? NSButton)?.toolTip)
            return canToggleRecording
        case .openScreenshot:
            item.show(
                label: "Open Screenshot",
                toolTip: "Open Screenshot in \(capturePreferences.openInApplicationName)"
            )
            return canTakeScreenshot
        case .saveScreenshotAs:
            return canTakeScreenshot
        case .captureOptions:
            return true
        case .liveText:
            let label = deviceVC.screen.isShowingLiveText ? "Done Selecting Text" : "Select Text on Screen"
            (item.view as? NSButton)?.state = deviceVC.screen.isShowingLiveText ? .on : .off
            if item.label != label {
                item.show(label: label, toolTip: label)
                (item.view as? NSButton)?.toolTip = label
                (item.view as? NSButton)?.setAccessibilityLabel(label)
            }
            let enabled = !recording.isActive && (deviceVC.screen.isShowingLiveText || canTakeScreenshot)
            (item.view as? NSButton)?.isEnabled = enabled
            return enabled
        case .fingerDots:
            let label = deviceVC.screen.showsTouches ? "Hide Finger Dots" : "Show Finger Dots"
            (item.view as? NSButton)?.state = deviceVC.screen.showsTouches ? .on : .off
            if item.label != label {
                item.show(label: label, toolTip: label)
                (item.view as? NSButton)?.toolTip = label
                (item.view as? NSButton)?.setAccessibilityLabel(label)
            }
            return true
        case .installApp:
            return emulator.canQueueInstall
        case .lock:
            let label = emulator.isPoweredOff ? "Start" : emulator.isSleeping ? "Wake" : "Lock"
            item.show(label: label, toolTip: label + " (⌘L)", symbol: emulator.isPoweredOff ? "power" : "lock")
            return emulator.acceptsInput || (emulator.isPoweredOff && !emulator.shuttingDown)
        case .home, .rotate:
            return emulator.acceptsInput
        case .files, .motion, .searchCatalog:
            return true
        default:
            return !emulator.isDead
        }
    }
}
