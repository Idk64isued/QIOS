import AppKit
import Testing

@testable import AppViews

extension SharedState {
    /// The Files window's column browser over a fake device: loading, navigation, menu validation, multi-select, drag
    /// out (file promises) and in, Quick Look copies, 360-900 pt layout and stale replies dropped. Never ordered in.
    @Suite struct FilesBrowserTests {
        /// A drop of `urls` (only the pasteboard matters to the browser delegate).
        final class Drop: NSObject, NSDraggingInfo {
            let pasteboard = NSPasteboard(name: .init("ltm-files-ui-drop-" + UUID().uuidString))
            init(_ urls: [URL]) {
                super.init()
                pasteboard.clearContents()
                pasteboard.writeObjects(urls as [NSURL])
            }
            var draggingDestinationWindow: NSWindow? { nil }
            var draggingSourceOperationMask: NSDragOperation { .copy }
            var draggingLocation: NSPoint { .zero }
            var draggedImageLocation: NSPoint { .zero }
            var draggedImage: NSImage? { nil }
            var draggingPasteboard: NSPasteboard { pasteboard }
            var draggingSource: Any? { nil }
            var draggingSequenceNumber: Int { 1 }
            func slideDraggedImage(to screenPoint: NSPoint) {}
            var draggingFormation: NSDraggingFormation {
                get { .default }
                set {}
            }
            var animatesToDestination: Bool {
                get { false }
                set {}
            }
            var numberOfValidItemsForDrop: Int {
                get { 1 }
                set {}
            }
            func enumerateDraggingItems(
                options: NSDraggingItemEnumerationOptions = [],
                for view: NSView?,
                classes: [AnyClass],
                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
            ) {}
            var springLoadingHighlight: NSSpringLoadingHighlight { .none }
            func resetSpringLoading() {}
        }
        final class Sink: NSResponder {
            var events = 0
            override func keyDown(with event: NSEvent) { events += 1 }
            override func scrollWheel(with event: NSEvent) { events += 1 }
        }

        @Test func browser() async throws {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            uploads = []
            let controller = DeviceFilesWindowController(profile: .n72)
            let vc = controller.browser
            vc.services = DeviceServices()
            let window = controller.window!
            window.setContentSize(NSSize(width: 360, height: 500))
            // Wait on the listing itself; the deadline only guards a hang (host load must not decide the verdict).
            func until(_ what: String, _ ok: () -> Bool) async throws {
                let deadline = Date().addingTimeInterval(15)
                while !ok() {
                    try #require(Date() < deadline, "hung waiting: \(what)")
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            vc.reload()
            func children(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + children($0) } }
            let all = children(vc.view)
            let browser = try #require(all.compactMap { $0 as? NSBrowser }.first)
            func rows(_ column: Int) -> Int {
                guard column <= browser.lastColumn else { return -1 }
                return (0...).first { browser.loadedCell(atRow: $0, column: column) == nil }!
            }
            try await until("the root listing") { rows(0) == 1 }
            browser.selectRow(0, inColumn: 0)
            browser.addColumn()
            try await until("the folder listing") { rows(1) == 2 }
            browser.selectRow(0, inColumn: 1)
            browser.sendAction(browser.action!, to: browser.target)
            let export = try #require(all.compactMap { $0 as? NSButton }.first { $0.title == "Save to Mac…" })
            #expect(export.isEnabled)
            let save = NSMenuItem(
                title: "Save to Mac…",
                action: #selector(DeviceFilesViewController.exportFile),
                keyEquivalent: ""
            )
            let copy = NSMenuItem(
                title: "Copy to iPod…",
                action: #selector(DeviceFilesViewController.importFile),
                keyEquivalent: ""
            )
            let cancel = NSMenuItem(
                title: "Cancel Transfer",
                action: #selector(DeviceFilesViewController.cancelTransfer),
                keyEquivalent: ""
            )
            let hidden = NSMenuItem(
                title: "Show Hidden Files",
                action: #selector(DeviceFilesViewController.toggleHidden(_:)),
                keyEquivalent: ""
            )
            #expect(vc.validateMenuItem(save) && vc.validateMenuItem(copy) && !vc.validateMenuItem(cancel))
            vc.toggleHidden(hidden)
            #expect(vc.validateMenuItem(hidden) && hidden.title == "Hide Hidden Files" && hidden.state == .off)
            vc.toggleHidden(hidden)
            try await until("the root listing again") { rows(0) == 1 }
            browser.selectRow(0, inColumn: 0)
            browser.addColumn()
            try await until("the folder listing again") { rows(1) == 2 }
            #expect(!vc.validateMenuItem(save), "Directories cannot be exported as files")
            browser.selectRow(0, inColumn: 1)
            browser.sendAction(browser.action!, to: browser.target)
            for width in [360.0, 660.0, 900.0] {
                window.setContentSize(NSSize(width: width, height: 500))
                vc.view.layoutSubtreeIfNeeded()
                for button in all.compactMap({ $0 as? NSButton }) where !button.isHidden {
                    let frame = button.convert(button.bounds, to: vc.view)
                    #expect(frame.minX >= 0 && frame.maxX <= width, "clipped \(button.title): \(frame)")
                }
            }
            // Several at once: both files selected export, drag out as two file promises, and fulfill into the drop folder.
            browser.selectRowIndexes(IndexSet([0, 1]), inColumn: 1)
            browser.sendAction(browser.action!, to: browser.target)
            #expect(vc.validateMenuItem(save) && export.isEnabled, "two files selected can be saved")
            #expect(
                vc.browser(browser, canDragRowsWith: IndexSet([0, 1]), inColumn: 1, with: NSEvent()),
                "files drag out"
            )
            #expect(
                !vc.browser(browser, canDragRowsWith: IndexSet([0]), inColumn: 0, with: NSEvent()),
                "a folder doesn't drag out"
            )
            let board = NSPasteboard(name: .init("ltm-files-ui-" + UUID().uuidString))
            #expect(
                vc.browser(browser, writeRowsWith: IndexSet([0, 1]), inColumn: 1, to: board)
                    && board.pasteboardItems?.count == 2,
                "two promises"
            )
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-files-ui-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: out) }
            let provider = vc.promise(
                DeviceFile(name: "note.txt", path: "Folder/note.txt", isDirectory: false, isRegular: true, size: 5)
            )
            #expect(vc.filePromiseProvider(provider, fileNameForType: provider.fileType) == "note.txt")
            // A name whose bidi override would show "photo.zip" as "photopiz.jpg" lands with the override visible.
            let spoof = vc.promise(
                DeviceFile(name: "photo\u{202E}gpj.zip", path: "x", isDirectory: false, isRegular: true, size: 1)
            )
            #expect(vc.filePromiseProvider(spoof, fileNameForType: spoof.fileType) == "photo[U+202E]gpj.zip")
            var fulfilled: Error?? = nil
            vc.filePromiseProvider(provider, writePromiseTo: out.appendingPathComponent("note.txt")) {
                fulfilled = .some($0)
            }
            try await until("the promise") { fulfilled != nil }
            #expect(
                fulfilled! == nil
                    && (try? String(contentsOf: out.appendingPathComponent("note.txt"), encoding: .utf8))
                        == "device:Folder/note.txt",
                "promised file written"
            )
            // Drag in: onto the folder row puts the files in it; a Finder file anywhere in column 1 goes to Folder.
            let local = out.appendingPathComponent("from-mac.txt")
            try Data("x".utf8).write(to: local)
            var row = 0
            var column = 0
            var op = NSBrowser.DropOperation.on
            #expect(
                vc.browser(browser, validateDrop: Drop([local]), proposedRow: &row, column: &column, dropOperation: &op)
                    == .copy
            )
            #expect(vc.browser(browser, acceptDrop: Drop([local]), atRow: 0, column: 0, dropOperation: .on))
            try await until("the drop upload") { !vc.hasTransfer && uploads.count == 1 }
            #expect(uploads.last! == ("from-mac.txt", "Folder"), "dropped into the folder: \(uploads)")
            try await until("the folder listing after the drop") { rows(0) == 1 }
            browser.selectRow(0, inColumn: 0)
            browser.addColumn()
            try await until("the folder listing after the drop") { rows(1) == 2 }
            row = 1
            column = 1
            op = .on
            #expect(
                vc.browser(browser, validateDrop: Drop([local]), proposedRow: &row, column: &column, dropOperation: &op)
                    == .copy && op == .above && row == -1
            )
            #expect(vc.browser(browser, acceptDrop: Drop([local]), atRow: -1, column: 1, dropOperation: .above))
            try await until("the second drop upload") { !vc.hasTransfer && uploads.count == 2 }
            #expect(uploads.last! == ("from-mac.txt", "Folder"), "dropped into the column's folder: \(uploads)")
            // Quick Look: the selected files copied to a private folder for the panel (never shown here).
            try await until("the root listing for Quick Look") { rows(0) == 1 }
            browser.selectRow(0, inColumn: 0)
            browser.addColumn()
            try await until("the folder listing for Quick Look") { rows(1) == 2 }
            browser.selectRowIndexes(IndexSet([0, 1]), inColumn: 1)
            browser.sendAction(browser.action!, to: browser.target)
            var presented = false
            vc.presentPreview = { presented = true }
            vc.quickLook(nil)
            try await until("the Quick Look copies") { presented }
            #expect(
                vc.previewURLs.map(\.lastPathComponent) == ["file.bin", "note.txt"]
                    && vc.previewURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
            )
            // One folder per copy, so names that differ only in case don't replace each other on the Mac.
            #expect(Set(vc.previewURLs.map { $0.deletingLastPathComponent() }).count == 2)
            #expect(vc.numberOfPreviewItems(in: nil) == 2)
            #expect(controller.browser === vc && browser.selectedColumn == 1)
            #expect(!window.isExcludedFromWindowsMenu && window.styleMask.contains(.resizable))
            // The source menu: Media, then the device's apps; an app's container is browsed from its top, and the
            // context menu's edits follow the selection.
            let picker = try #require(all.compactMap { $0 as? NSPopUpButton }.first)
            try await until("the apps in the source menu") { picker.itemTitles.contains("Game") }
            #expect(picker.titleOfSelectedItem == "Media" && picker.itemTitles.first == "Media")
            func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }
            let rename = item(#selector(DeviceFilesViewController.renameItem(_:)))
            let delete = item(#selector(DeviceFilesViewController.deleteItems(_:)))
            let folder = item(#selector(DeviceFilesViewController.newFolder(_:)))
            #expect(!vc.validateMenuItem(rename) && vc.validateMenuItem(delete), "two files: delete, not rename")
            // ⌘⌫ deletes the selection after asking, with Delete marked destructive; a bare Delete or Forward
            // Delete deletes nothing, and Cancel leaves the files.
            var questions: [NSAlert] = []
            vc.presentAlert = { alert, _, done in
                questions.append(alert)
                done(.alertSecondButtonReturn)
            }
            func key(_ character: Int, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
                let text = String(UnicodeScalar(UInt16(character))!)
                return NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: modifiers,
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: text,
                    charactersIgnoringModifiers: text,
                    isARepeat: false,
                    keyCode: code
                )!
            }
            for (event, name) in [
                (key(NSDeleteCharacter, 51, []), "Delete"),
                (key(NSDeleteFunctionKey, 117, []), "Forward Delete"),
                (key(NSDeleteCharacter, 51, [.shift, .command]), "Shift-Command-Delete")
            ] {
                #expect(!vc.handleBrowserKey(event) && questions.isEmpty, "\(name) deletes nothing")
            }
            #expect(vc.handleBrowserKey(key(NSDeleteCharacter, 51, .command)), "⌘⌫ is the browser's")
            #expect(
                questions.map(\.messageText) == ["Delete 2 items?"]
                    && questions.first?.buttons.map(\.title) == ["Delete", "Cancel"]
                    && questions.first?.buttons.first?.hasDestructiveAction == true,
                "⌘⌫ asks first: \(questions.map(\.messageText))"
            )
            #expect(
                browser.menu?.items.first { $0.action == #selector(DeviceFilesViewController.deleteItems(_:)) }?
                    .keyEquivalent == "\u{7f}",
                "the context menu shows ⌘⌫"
            )
            picker.selectItem(withTitle: "Game")
            picker.sendAction(picker.action!, to: picker.target)
            func first() -> String? { (browser.loadedCell(atRow: 0, column: 0) as? NSCell)?.stringValue }
            try await until("the app's container") { rows(0) == 1 && first() == "com.example.Game" }
            #expect(vc.services?.app == "com.example.Game" && picker.titleOfSelectedItem == "Game")
            browser.selectRow(0, inColumn: 0)
            browser.sendAction(browser.action!, to: browser.target)
            #expect(vc.validateMenuItem(rename) && vc.validateMenuItem(delete) && vc.validateMenuItem(folder))
            #expect(
                all.contains { ($0 as? NSTextField)?.stringValue == "Game / com.example.Game" },
                "the path names the app"
            )
            picker.selectItem(withTitle: "Media")
            picker.sendAction(picker.action!, to: picker.target)
            try await until("Media again") { rows(0) == 1 && first() == "Folder" }
            #expect(vc.services?.app == nil)
            // A listing that answers after the device went away is dropped.
            let asked = replies
            vc.reload()
            vc.services = nil
            vc.reload()
            try await until("the stale listing's reply") { replies > asked }
            #expect(rows(0) == 0 && !export.isEnabled)
            #expect(!vc.validateMenuItem(save) && !vc.validateMenuItem(copy) && !vc.validateMenuItem(cancel))
            let idleStatus = vc.transferStatus
            vc.cancelTransfer()
            #expect(vc.transferStatus == idleStatus)
            let sink = Sink()
            let next = vc.view.nextResponder
            vc.view.nextResponder = sink
            let key = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "x",
                charactersIgnoringModifiers: "x",
                isARepeat: false,
                keyCode: 7
            )!
            vc.view.keyDown(with: key)
            vc.view.scrollWheel(with: key)
            #expect(sink.events == 0, "the browser swallows its keys and scrolls")
            vc.view.nextResponder = next
            vc.stop()
        }
    }
}
