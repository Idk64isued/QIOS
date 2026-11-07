import Cocoa
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore
import Quartz
import UniformTypeIdentifiers

/// AFC's media folder (a jailbroken device's whole file system: DeviceServices.wholeFileSystem) or an installed app's
/// container (house_arrest: DeviceServices.app), chosen in the source menu, presented in its own retained Mac window.
/// Files drag in (onto a folder, or the column's folder) and out (file promises), several at a time, Space shows them in
/// Quick Look, and the context menu makes, renames and deletes them.
final class DeviceFilesViewController: NSViewController, NSBrowserDelegate, NSMenuItemValidation,
    NSFilePromiseProviderDelegate, QLPreviewPanelDataSource
{
    var services: DeviceServices?
    var onActivityChange: (() -> Void)?
    var hasTransfer: Bool { transfer != nil }
    var transferStatus: String { status.stringValue }
    private let pathLabel = NSTextField(labelWithString: "Media")
    /// The device's own root (Media, or File System), then its installed apps.
    private let sourcePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var apps: [InstalledApp] = []
    private var showHidden = false
    private var transferMessage: String?
    private let browser = NSBrowser()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let profile: Board
    private let upload: NSButton
    private let download = NSButton(title: "Save to Mac…", target: nil, action: nil)
    private let refresh = NSButton(title: "Refresh", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private var directories: [String: [DeviceFile]] = [:]
    private var loading = Set<String>()
    private var tasks: [Task<Void, Never>] = []
    private var transfer: Task<Void, Never>? { didSet { activity.held = transfer != nil } }
    private var activity = UserActivity("Copying files to or from a device")
    private var revision = 0
    private var transferID = UUID()
    /// Quick Look's copies of the selected files, in a private temporary folder removed when the panel closes.
    private var previewItems: [URL] = []
    private var previewFolder: URL?
    // nonisolated(unsafe): set on the main actor in viewDidLoad and read again only by deinit, after the last use.
    nonisolated(unsafe) private var keyMonitor: Any?
    /// Drag-out promises run one after another (AFC transfers are serial anyway).
    private var promiseChain: Task<Void, Never>?
    private var idleStatusWidth: NSLayoutConstraint?
    private var activeStatusWidth: NSLayoutConstraint?

    init(profile: Board) {
        self.profile = profile
        upload = NSButton(title: "Copy to \(profile.shortName)…", target: nil, action: nil)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let box = FilesBackground()
        view = box
        pathLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        let hiddenMenu = NSMenu()
        let look = hiddenMenu.addItem(withTitle: "Quick Look", action: #selector(quickLook(_:)), keyEquivalent: "")
        look.target = self
        hiddenMenu.addItem(.separator())
        for (title, action, key) in [
            ("New Folder…", #selector(newFolder(_:)), ""), ("Rename…", #selector(renameItem(_:)), ""),
            ("Delete…", #selector(deleteItems(_:)), "\u{7f}")
        ] {
            hiddenMenu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
        }
        hiddenMenu.addItem(.separator())
        let hidden = hiddenMenu.addItem(
            withTitle: "Show Hidden Files",
            action: #selector(toggleHidden(_:)),
            keyEquivalent: ""
        )
        hidden.target = self
        browser.menu = hiddenMenu
        browser.delegate = self
        browser.target = self
        browser.action = #selector(selectionChanged)
        browser.minColumnWidth = 160
        browser.maxVisibleColumns = 3
        browser.allowsMultipleSelection = true
        browser.registerForDraggedTypes([.fileURL])
        browser.setDraggingSourceOperationMask(.copy, forLocal: false)
        browser.takesTitleFromPreviousColumn = false
        browser.isTitled = false
        browser.hasHorizontalScroller = true
        browser.setAccessibilityLabel("Device files")
        for (button, action) in [
            (upload, #selector(importFile)), (download, #selector(exportFile)),
            (refresh, #selector(refreshFiles(_:))), (cancel, #selector(cancelTransfer))
        ] {
            button.target = self
            button.action = action
        }
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar
        let options = NSButton(
            image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "File options") ?? NSImage(),
            target: self,
            action: #selector(showOptions(_:))
        )
        options.isBordered = false
        options.toolTip = "File options"
        sourcePicker.target = self
        sourcePicker.action = #selector(sourceChanged)
        sourcePicker.controlSize = .small
        sourcePicker.setAccessibilityLabel("Location")
        sourcePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [sourcePicker, upload, download, refresh, options])
        actions.spacing = 8
        for button in [upload, download, refresh] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 1
        status.lineBreakMode = .byTruncatingMiddle
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        for child in [actions, browser, pathLabel, status, progress, cancel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(child)
        }
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: box.safeAreaLayoutGuide.topAnchor, constant: 10),
            actions.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -12),
            sourcePicker.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            actions.heightAnchor.constraint(equalToConstant: 26),
            browser.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 10),
            browser.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            browser.bottomAnchor.constraint(equalTo: pathLabel.topAnchor, constant: -10),
            pathLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            pathLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            pathLabel.heightAnchor.constraint(equalToConstant: 18),
            pathLabel.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: pathLabel.leadingAnchor),
            status.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            status.heightAnchor.constraint(equalToConstant: 18),

            progress.widthAnchor.constraint(equalToConstant: 100),
            progress.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            progress.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -8),
            cancel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            cancel.centerYAnchor.constraint(equalTo: status.centerYAnchor)
        ])
        idleStatusWidth = status.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12)
        activeStatusWidth = status.trailingAnchor.constraint(equalTo: progress.leadingAnchor, constant: -12)
        updateControls()
        // Space toggles Quick Look while the browser has focus (its matrix takes the key otherwise), and ⌘⌫ deletes
        // the selection after asking, as in the Finder (a context menu's key equivalent isn't one the window sees).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === view.window,
                let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: browser)
            else { return event }
            return handleBrowserKey(event) ? nil : event
        }
    }

    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    /// A key for the focused browser: Space is Quick Look, ⌘⌫ Delete… (a bare Delete deletes nothing). True when taken.
    func handleBrowserKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.charactersIgnoringModifiers == " ", modifiers.isEmpty {
            quickLook(nil)
        } else if event.specialKey == .delete, modifiers == .command {
            deleteItems(nil)
        } else {
            return false
        }
        return true
    }

    func focusBrowser() {
        if view.window?.makeFirstResponder(browser) != true { view.window?.makeFirstResponder(view) }
    }

    func stop() {
        revision += 1
        for task in tasks { task.cancel() }
        tasks.removeAll()
        transfer?.cancel()
        transfer = nil
        loading.removeAll()
    }

    @objc private func showOptions(_ sender: NSButton) {
        browser.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc func toggleHidden(_ sender: NSMenuItem) {
        guard !hasTransfer else { return }
        showHidden.toggle()
        reload()
    }

    @objc func refreshFiles(_ sender: Any?) {
        guard !hasTransfer else { return }
        reload()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(importFile): return services != nil && !hasTransfer
        case #selector(exportFile): return services != nil && !hasTransfer && !selectedFiles.isEmpty
        case #selector(quickLook(_:)): return services != nil && !hasTransfer && !selectedFiles.isEmpty
        case #selector(cancelTransfer): return hasTransfer
        case #selector(refreshFiles(_:)): return !hasTransfer
        case #selector(newFolder(_:)): return services != nil && !hasTransfer
        case #selector(renameItem(_:)): return services != nil && !hasTransfer && selectedEntries.count == 1
        case #selector(deleteItems(_:)): return services != nil && !hasTransfer && !selectedEntries.isEmpty
        case #selector(toggleHidden(_:)):
            item.title = showHidden ? "Hide Hidden Files" : "Show Hidden Files"
            return !hasTransfer
        default: return false
        }
    }

    @objc func reload() {
        stop()
        directories.removeAll()
        browser.loadColumnZero()
        updateControls()
        guard let services else {
            apps = []
            updateSourcePicker()
            status.stringValue = "The \(profile.shortName) is disconnected."
            onActivityChange?()
            return
        }
        let generation = revision
        selectionChanged()
        tasks.append(
            Task { [weak self] in
                // 1.x has no installation_proxy: no apps, so the menu offers the device's root alone.
                guard let apps = try? await services.installedApps(), let self, generation == revision,
                    !Task.isCancelled
                else { return }
                self.apps = apps
                if let app = services.app, !apps.contains(where: { $0.id == app }) {  // uninstalled meanwhile
                    self.services?.app = nil
                    return reload()
                }
                updateSourcePicker()
            }
        )
        tasks.append(
            Task { [weak self] in
                do {
                    let bytes = try await services.freeSpaceBytes()
                    guard let self, generation == revision, !Task.isCancelled else { return }
                    status.stringValue =
                        transferMessage
                        ?? "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) available"
                    onActivityChange?()
                } catch {
                    guard let self, generation == revision, !Task.isCancelled else { return }
                    status.stringValue = error.localizedDescription
                }
            }
        )
    }

    private var deviceRootName: String { services?.wholeFileSystem == true ? "File System" : "Media" }
    private var rootName: String {
        services?.app.map { id in DeviceName.visible(apps.first { $0.id == id }?.name ?? id) } ?? deviceRootName
    }

    private func updateSourcePicker() {
        let menu = NSMenu()
        menu.addItem(withTitle: deviceRootName, action: nil, keyEquivalent: "")
        if !apps.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Apps"))
            for app in apps {
                let item = menu.addItem(withTitle: DeviceName.visible(app.name), action: nil, keyEquivalent: "")
                item.representedObject = app.id
                item.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            }
        }
        sourcePicker.menu = menu
        let current = services?.app
        sourcePicker.select(menu.items.first { $0.representedObject as? String == current && !$0.isSeparatorItem })
        sourcePicker.isEnabled = services != nil && transfer == nil
        selectionChanged()
    }

    /// The source menu picked the device's root or an app: browse it from its top.
    @objc private func sourceChanged() {
        guard services != nil, transfer == nil else { return }
        let app = sourcePicker.selectedItem?.representedObject as? String
        guard app != services?.app else { return }
        services?.app = app
        reload()
    }

    private func directory(for column: Int) -> String? {
        if column == 0 { return "" }
        guard let parent = directory(for: column - 1), let entries = directories[parent] else { return nil }
        let row = browser.selectedRow(inColumn: column - 1)
        guard entries.indices.contains(row), entries[row].isDirectory else { return nil }
        return entries[row].path
    }

    func browser(_ sender: NSBrowser, numberOfRowsInColumn column: Int) -> Int {
        guard let path = directory(for: column) else { return 0 }
        if let entries = directories[path] { return entries.count }
        guard let services, loading.insert(path).inserted else { return 0 }
        let generation = revision
        tasks.append(
            Task { [weak self] in
                do {
                    let entries = try await services.files(in: path)
                    guard let self, generation == revision, !Task.isCancelled else { return }
                    directories[path] =
                        showHidden
                        ? entries
                        : entries.filter {
                            !$0.name.hasPrefix(".") && !$0.name.hasSuffix(".lock")
                                && !$0.name.hasPrefix("com.apple.itdbprep.")
                        }
                    loading.remove(path)
                    if directory(for: column) == path { browser.reloadColumn(column) }
                    updateControls()
                } catch {
                    guard let self, generation == revision, !Task.isCancelled else { return }
                    loading.remove(path)
                    status.stringValue = error.localizedDescription
                }
            }
        )
        return 0
    }

    func browser(_ sender: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? NSBrowserCell, let path = directory(for: column),
            let entries = directories[path], entries.indices.contains(row)
        else { return }
        let file = entries[row]
        cell.stringValue = DeviceName.visible(file.name)
        cell.isLeaf = !file.isDirectory
        cell.image = NSImage(systemSymbolName: file.isDirectory ? "folder" : "doc", accessibilityDescription: nil)
    }

    private var selected: DeviceFile? {
        let column = browser.selectedColumn
        guard column >= 0, let path = directory(for: column), let entries = directories[path] else { return nil }
        let row = browser.selectedRow(inColumn: column)
        return entries.indices.contains(row) ? entries[row] : nil
    }

    /// The selected regular files (several with ⌘/⇧-click); folders in the selection are left out.
    private var selectedFiles: [DeviceFile] {
        let column = browser.selectedColumn
        guard column >= 0, let path = directory(for: column), let entries = directories[path],
            let rows = browser.selectedRowIndexes(inColumn: column)
        else { return [] }
        return rows.filter { entries.indices.contains($0) }.map { entries[$0] }.filter(\.isRegular)
    }

    /// Every selected row, folders included: what Delete and Rename act on.
    private var selectedEntries: [DeviceFile] {
        let column = browser.selectedColumn
        guard column >= 0, let path = directory(for: column), let entries = directories[path],
            let rows = browser.selectedRowIndexes(inColumn: column)
        else { return [] }
        return rows.filter { entries.indices.contains($0) }.map { entries[$0] }
    }

    /// The folder a new file goes into: the selected folder, else the selected column's.
    private var targetDirectory: String {
        selected.flatMap { $0.isDirectory ? $0.path : nil } ?? directory(for: max(0, browser.selectedColumn)) ?? ""
    }

    @objc private func selectionChanged() {
        let path = selected?.path ?? directory(for: max(0, browser.selectedColumn)) ?? ""
        let root = rootName
        pathLabel.stringValue =
            path.isEmpty ? root : root + " / " + DeviceName.visible(path).replacingOccurrences(of: "/", with: " / ")
        updateControls()
    }
    private func updateControls() {
        upload.isEnabled = services != nil && transfer == nil
        download.isEnabled = services != nil && transfer == nil && !selectedFiles.isEmpty
        refresh.isEnabled = transfer == nil
        sourcePicker.isEnabled = services != nil && transfer == nil
        cancel.isHidden = transfer == nil
        idleStatusWidth?.isActive = false
        activeStatusWidth?.isActive = false
        (hasTransfer ? activeStatusWidth : idleStatusWidth)?.isActive = true
        progress.isHidden = transfer == nil
        browser.isEnabled = transfer == nil
        onActivityChange?()
    }

    @objc func cancelTransfer() {
        guard hasTransfer else { return }
        transfer?.cancel()
        status.stringValue = "Cancelling…"
        onActivityChange?()
    }

    @objc func importFile() {
        guard let window = view.window, transfer == nil else { return }
        let path = targetDirectory
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let generation = revision
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, generation == self.revision else { return }
            self.upload(panel.urls, into: path)
        }
    }

    /// Files already in `path` with these names are replaced once the user says so.
    private func upload(_ urls: [URL], into path: String) {
        guard let services, transfer == nil, !urls.isEmpty else { return }
        let names = Set((directories[path] ?? []).map(\.name))
        let existing = urls.map(\.lastPathComponent).filter(names.contains)
        let start = { [weak self] () -> Void in
            self?.beginTransfer { progress in
                for (index, url) in urls.enumerated() {
                    try await services.uploadFile(url, into: path, replacing: names.contains(url.lastPathComponent)) {
                        progress((Double(index) + $0) / Double(urls.count))
                    }
                }
            }
        }
        guard !existing.isEmpty else {
            start()
            return
        }
        let alert = NSAlert()
        alert.messageText =
            existing.count == 1
            ? "Replace “\(existing[0])”?" : "Replace \(existing.count) items with the same names?"
        alert.informativeText = "The copy on the \(profile.shortName) is replaced once the new one is copied."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        confirm(alert) { start() }
    }

    /// `alert` as a sheet; `then` on its first button.
    private func confirm(_ alert: NSAlert, then: @escaping () -> Void) {
        let generation = revision
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, generation == revision, transfer == nil else { return }
            then()
        }
        guard let window = view.window else { return }
        presentAlert(alert, window, done)
    }

    /// Shows a question as a sheet; a check answers it without a window on screen.
    var presentAlert: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = {
        alert,
        window,
        done in
        alert.beginSheetModal(for: window, completionHandler: done)
    }

    /// A name typed into `alert`'s field; `then` with it when the first button is chosen and it is a usable name.
    private func askName(_ alert: NSAlert, initial: String, then: @escaping (String) -> Void) {
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        confirm(alert) {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name != initial { then(name) }
        }
    }

    // MARK: - Edits

    @objc func newFolder(_ sender: Any?) {
        guard let services, transfer == nil else { return }
        let parent = targetDirectory
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "In \(parent.isEmpty ? rootName : (parent as NSString).lastPathComponent)"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        askName(alert, initial: "") { [weak self] name in
            let path = parent.isEmpty ? name : parent + "/" + name
            self?.beginTransfer(working: "Creating “\(name)”…", finished: "Folder created") { _ in
                try await services.makeFolder(path)
            }
        }
    }

    @objc func renameItem(_ sender: Any?) {
        guard let services, transfer == nil, selectedEntries.count == 1, let item = selectedEntries.first else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Rename “\(DeviceName.visible(item.name))”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        askName(alert, initial: DeviceName.visible(item.name)) { [weak self] name in
            self?.beginTransfer(working: "Renaming…", finished: "Renamed") { _ in
                try await services.rename(item.path, to: name)
            }
        }
    }

    @objc func deleteItems(_ sender: Any?) {
        let items = selectedEntries
        guard let services, transfer == nil, !items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText =
            items.count == 1 ? "Delete “\(DeviceName.visible(items[0].name))”?" : "Delete \(items.count) items?"
        alert.informativeText =
            items.contains(where: \.isDirectory)
            ? "Folders are deleted with everything in them. This can’t be undone."
            : "This can’t be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        confirm(alert) { [weak self] in
            self?.beginTransfer(working: "Deleting…", finished: "Deleted") { progress in
                for (index, item) in items.enumerated() {
                    try await services.delete(item.path)
                    progress(Double(index + 1) / Double(items.count))
                }
            }
        }
    }

    @objc func exportFile() {
        guard let window = view.window, let services, transfer == nil else { return }
        let files = selectedFiles
        let generation = revision
        if files.count == 1, let file = files.first {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = DeviceName.visible(file.name)
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let self, generation == self.revision, let url = panel.url else { return }
                self.beginTransfer { progress in
                    try await services.download(file, to: url, progress: progress)
                }
            }
        } else if !files.isEmpty {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Save"
            panel.message = "Choose where to save \(files.count) files."
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let self, generation == self.revision, let folder = panel.url else { return }
                self.beginTransfer { progress in
                    for (index, file) in files.enumerated() {
                        let url = folder.appendingPathComponent(DeviceName.visible(file.name)).unused
                        try await services.download(file, to: url) {
                            progress((Double(index) + $0) / Double(files.count))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Drag in and out

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    func browser(
        _ browser: NSBrowser,
        validateDrop info: NSDraggingInfo,
        proposedRow row: UnsafeMutablePointer<Int>,
        column: UnsafeMutablePointer<Int>,
        dropOperation: UnsafeMutablePointer<NSBrowser.DropOperation>
    ) -> NSDragOperation {
        guard services != nil, transfer == nil, info.draggingSource as? NSBrowser !== browser,
            !droppedFiles(info).isEmpty,
            let path = directory(for: column.pointee), let entries = directories[path]
        else { return [] }
        // Onto a folder row: into it. Anywhere else in a column: that column's folder.
        if dropOperation.pointee == .on, entries.indices.contains(row.pointee), entries[row.pointee].isDirectory {
            return .copy
        }
        row.pointee = -1
        dropOperation.pointee = .above
        return .copy
    }

    func browser(
        _ browser: NSBrowser,
        acceptDrop info: NSDraggingInfo,
        atRow row: Int,
        column: Int,
        dropOperation: NSBrowser.DropOperation
    ) -> Bool {
        guard let path = directory(for: column), let entries = directories[path] else { return false }
        let into =
            dropOperation == .on && entries.indices.contains(row) && entries[row].isDirectory ? entries[row].path : path
        let urls = droppedFiles(info)
        upload(urls, into: into)
        return !urls.isEmpty
    }

    func browser(_ browser: NSBrowser, canDragRowsWith rowIndexes: IndexSet, inColumn column: Int, with event: NSEvent)
        -> Bool
    {
        guard services != nil, transfer == nil, let path = directory(for: column), let entries = directories[path]
        else { return false }
        return rowIndexes.allSatisfy { entries.indices.contains($0) && entries[$0].isRegular }
    }

    func browser(
        _ browser: NSBrowser,
        writeRowsWith rowIndexes: IndexSet,
        inColumn column: Int,
        to pasteboard: NSPasteboard
    ) -> Bool {
        guard let path = directory(for: column), let entries = directories[path] else { return false }
        let providers = rowIndexes.filter { entries.indices.contains($0) && entries[$0].isRegular }.map {
            promise(entries[$0])
        }
        pasteboard.clearContents()
        return !providers.isEmpty && pasteboard.writeObjects(providers)
    }

    func promise(_ file: DeviceFile) -> NSFilePromiseProvider {
        let type = UTType(filenameExtension: (DeviceName.visible(file.name) as NSString).pathExtension) ?? .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = file
        return provider
    }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String
    {
        (provider.userInfo as? DeviceFile).map { DeviceName.visible($0.name) } ?? "File"
    }

    nonisolated func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let handler = UncheckedHandler(completionHandler)
        let promised = provider.userInfo as? DeviceFile
        MainActor.assumeIsolated {
            guard let file = promised, let services else {
                handler.call(CocoaError(.fileReadUnknown))
                return
            }
            let previous = promiseChain
            status.stringValue = "Copying \(DeviceName.visible(file.name))…"
            promiseChain = Task { [weak self] in
                await previous?.value
                do {
                    try await services.download(file, to: url) { _ in }
                    handler.call(nil)
                    self?.status.stringValue = "File copied"
                } catch {
                    handler.call(error)
                    self?.status.stringValue = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Quick Look

    /// Shows the panel on the copies (a check replaces it to stay off screen).
    var presentPreview: () -> Void = {
        QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
        QLPreviewPanel.shared()?.reloadData()
    }
    var previewURLs: [URL] { previewItems }

    @objc func quickLook(_ sender: Any?) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let files = selectedFiles
        guard let services, transfer == nil, !files.isEmpty else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LightTouch-QuickLook-" + UUID().uuidString,
            isDirectory: true
        )
        let generation = revision
        beginTransfer(reloadAfter: false) { progress in
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            for (index, file) in files.enumerated() {
                let item = Self.previewItem(in: folder, index: index, name: file.name)
                try FileManager.default.createDirectory(
                    at: item.deletingLastPathComponent(),
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                try await services.download(file, to: item) {
                    progress((Double(index) + $0) / Double(files.count))
                }
            }
        } done: { [weak self] ok in
            guard let self, generation == revision else {
                try? FileManager.default.removeItem(at: folder)
                return
            }
            guard ok else {
                try? FileManager.default.removeItem(at: folder)
                return
            }
            clearPreview()
            previewFolder = folder
            previewItems = files.enumerated().map {
                Self.previewItem(in: folder, index: $0.offset, name: $0.element.name)
            }
            presentPreview()
        }
    }

    /// Each Quick Look copy gets its own folder: the device's volume is case-sensitive and the Mac's usually isn't,
    /// so a.JPG and a.jpg in one folder would land on one file here.
    private nonisolated static func previewItem(in folder: URL, index: Int, name: String) -> URL {
        folder.appendingPathComponent(String(index), isDirectory: true).appendingPathComponent(DeviceName.visible(name))
    }

    private func clearPreview() {
        if let previewFolder { try? FileManager.default.removeItem(at: previewFolder) }
        previewFolder = nil
        previewItems = []
    }

    // QuickLook's panel-control methods are declared nonisolated; it calls them on the main thread.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.reloadData()
        }
    }
    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            clearPreview()
        }
    }
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewItems.count }
    }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewItems[index] as NSURL }
    }

    private func beginTransfer(
        reloadAfter: Bool = true,
        working: String = "Copying…",
        finished message: String = "File copied",
        _ work: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void,
        done: ((Bool) -> Void)? = nil
    ) {
        let generation = revision
        let id = UUID()
        transferID = id
        progress.doubleValue = 0
        transferMessage = nil
        status.stringValue = working
        transfer = Task { [weak self] in
            do {
                try await work { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, generation == revision, transferID == id, transfer != nil else { return }
                        progress.doubleValue = value
                        status.stringValue = working == "Copying…" ? "Copying \(Int(value * 100))%" : working
                        onActivityChange?()
                    }
                }
                guard let self, generation == revision else { return }
                transfer = nil
                if reloadAfter {
                    transferMessage = message
                    reload()
                } else {
                    status.stringValue = transferMessage ?? ""
                    updateControls()
                }
                done?(true)
            } catch {
                guard let self, generation == revision else { return }
                transfer = nil
                status.stringValue =
                    error is CancellationError
                    ? (working == "Copying…" ? "Copy cancelled" : "Cancelled") : error.localizedDescription
                transferMessage = status.stringValue
                updateControls()
                done?(false)
            }
        }
        updateControls()
    }
}

// Unhandled browser events must stop here, not reach the display underneath.
private final class FilesBackground: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
}

/// A file promise's completion handler, called once from the main actor.
// @unchecked: AppKit's file-promise completion handler may be called from any thread.
nonisolated private struct UncheckedHandler: @unchecked Sendable {
    let call: (Error?) -> Void
    init(_ call: @escaping (Error?) -> Void) { self.call = call }
}
