import Cocoa
import DeviceRuntime
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore
import UniformTypeIdentifiers

// The right-hand inspector: a plain AppKit table of the apps installed on the
// device, in the order they sit on the home screen, with add (install an .ipa)
// and remove (uninstall) controls beneath it, source-list style. Rows can be
// dragged to reorder the home screen itself, and right-clicked for the same
// operations. While an install runs, the app appears as a pending row carrying
// the script's own progress, cancellable from its context menu.

final class AppsInspectorViewController: NSViewController {
    let emulator: EmulatorController
    let tableView = NSTableView()
    let addRemove = NSSegmentedControl()
    let searchField = NSSearchField()
    let placeholder = NSTextField.paneMessage()
    let emptyActions = NSStackView()
    let browseButton = NSButton(title: "Browse Store", target: nil, action: nil)
    let installButton = NSButton(title: "Install App…", target: nil, action: nil)
    let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    let resumeButton = NSButton(title: "Resume", target: nil, action: nil)
    var queries: [PaneMode: String] = [:]
    var catalogFailed = false

    /// Shown over a populated list when the device stops answering: the list is
    /// kept (it was correct a moment ago) but no longer silently pretends to be
    /// current.
    let banner = NSTextField.paneCaption()
    var bannerHeight: NSLayoutConstraint?
    /// Why the list shown is stale (showStaleBanner); nil once a read succeeds.
    var staleReason: String?
    /// Finished transfers whose app the device was asked to list once more (prunePending).
    var rereads: Set<ObjectIdentifier> = []
    var lastLoaded: Date?
    var apps: [InstalledApp] = []
    var pending: [InstallJob] = []
    /// Bundle IDs in home-screen order, empty until SpringBoard tells us. The
    /// list is sorted by this when we have it, so the sidebar and the icons
    /// read the same way down the screen.
    var homeOrder: [String] = []
    /// Set once the device has answered at all — until then an empty list means
    /// "we don't know yet", not "nothing is installed".
    var haveLoaded = false
    var loadTask: Task<Void, Never>?

    // MARK: - Catalog (Store) state
    //
    // The table has exactly two modes, switched by the Installed/Store
    // segmented control (typing a search flips to Store; Store with an empty
    // search shows the suggested list): the installed list (pending +
    // visibleApps, whose index arithmetic is deliberately untouched) or the
    // Legacy Store results. Never both — a third section interleaved into the
    // installed list would have to reconcile with prunePending/visibleApps at
    // every step.
    enum PaneMode: Int {
        case installed = 0
        case store = 1
    }
    /// Store first: the default view is the suggested list, ready to install.
    var mode: PaneMode = .store
    let modeControl = NSSegmentedControl(
        labels: ["Installed", "Store"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    /// What the server returned; the table shows catalogResults, these through the filter menu.
    var catalogFetched: [CatalogApp] = []
    var catalogResults: [CatalogApp] { filterButton.apply(catalogFetched) }
    lazy var filterButton = CatalogFilterButton(isIPad: emulator.profile.facts.kind == .iPad)
    var searchTask: Task<Void, Never>?
    /// The table is showing Legacy Store content.
    var searching: Bool { mode == .store }
    /// One list read at a time; see loadOnce.
    var isLoading = false
    /// A refresh arrived while one was running; run once more when it finishes.
    var needsReload = false
    /// The guest's install and uninstall notifications for the current boot, re-armed when a reboot renews it.
    lazy var appChanges = makeAppChanges()
    private func makeAppChanges() -> AppChangeWatch {
        let emulator = emulator
        return AppChangeWatch(apps: emulator.apps) {
            await MainActor.run {
                emulator.isRunning && !emulator.preparingDevice
                    && !AppInstaller.isUsingDevice(emulator.instance.id)
                    && !emulator.isInstalling && !emulator.hasFileTransfer && !emulator.isReconnecting
            }
        } onChange: {
            NotificationCenter.default.post(name: .ltmAppsChanged, object: emulator.instance.id)
        }
    }

    init(emulator: EmulatorController) {
        self.emulator = emulator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView()

        let column = NSTableColumn(identifier: .init("app"))
        column.title = "Installed Apps"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // A source list, which is what an inspector's list of things is: it
        // brings the standard row inset, selection material and — the reason
        // the old reordering looked homemade — AppKit's own drag feedback.
        tableView.style = .sourceList
        tableView.rowHeight = 56
        tableView.dataSource = self
        tableView.delegate = self
        // .string is the internal reorder drag; .fileURL is an .ipa dropped
        // from the Finder. The list of installed apps is the obvious place to
        // drop an app, and it silently ignored one — two inches to the left, on
        // the device screen, the same drop installed it.
        tableView.registerForDraggedTypes([.string, .fileURL])
        // Rows leave the app: installed rows as .ipa files (to the Finder),
        // Store rows as links — and both drop on the device view (local .copy).
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)
        tableView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        // menuNeedsUpdate decides what is enabled; automatic enabling would
        // overrule it and re-enable Cancel Install on a job already cancelling.
        menu.autoenablesItems = false
        tableView.menu = menu
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        configureAddRemove()

        placeholder.isHidden = true

        // A quiet caption, the way Mail dates its last check — no fill at all.
        // Both a yellow band and a gray quaternary strip were tried; any
        // edge-to-edge fill under the segmented control reads as a broken
        // control, not a status line.
        banner.isHidden = true
        let bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        self.bannerHeight = bannerHeight

        modeControl.selectedSegment = mode.rawValue
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.segmentDistribution = .fillEqually
        modeControl.controlSize = .large
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        // Both modes act on several rows at once: bulk install in the Store,
        // bulk uninstall in Installed.
        tableView.allowsMultipleSelection = true

        for (button, action) in [
            (browseButton, #selector(browseStore)), (installButton, #selector(installLocal)),
            (retryButton, #selector(refreshClicked(_:))), (resumeButton, #selector(resumeInstallsClicked(_:)))
        ] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        for button in [browseButton, installButton, retryButton] { emptyActions.addArrangedSubview(button) }
        emptyActions.spacing = 8
        emptyActions.translatesAutoresizingMaskIntoConstraints = false
        emptyActions.isHidden = true
        resumeButton.translatesAutoresizingMaskIntoConstraints = false
        resumeButton.isHidden = true
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        filterButton.isEnabled = mode == .store
        filterButton.onChange = { [weak self] in self?.filterChanged() }
        [modeControl, filterButton, banner, scroll, placeholder, emptyActions, resumeButton].forEach(
            container.addSubview
        )
        // Everything hangs below the safe area — a hard edge at the toolbar,
        // so rows can never slide behind the search field (full-bleed +
        // automatic insets let them scroll under the glass, unblurred and
        // unreadable; the only system knob for that edge,
        // preferredScrollEdgeEffectStyle, exists on accessory controllers,
        // not plain toolbars). Pre-26 the safe area is simply the pane.
        var constraints = [
            modeControl.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 6),
            modeControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            filterButton.leadingAnchor.constraint(equalTo: modeControl.trailingAnchor, constant: 4),
            filterButton.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            filterButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),

            banner.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 6),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            bannerHeight,

            scroll.topAnchor.constraint(equalTo: banner.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            emptyActions.topAnchor.constraint(equalTo: placeholder.bottomAnchor, constant: 12),
            emptyActions.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            resumeButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            resumeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16)
        ]
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footer)
        footer.addSubview(addRemove)
        let footerHeight = footer.heightAnchor.constraint(equalToConstant: 0)
        self.footerHeight = footerHeight
        constraints += [
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor), footerHeight,
            addRemove.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10),
            addRemove.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ]
        NSLayoutConstraint.activate(constraints)

        view = container
        updateFooterVisibility()
    }

    /// The catalog search lives in the window toolbar (the standard Mac home
    /// for search — App Store, Mail), riding above the inspector thanks to the
    /// tracking separator. A custom top-accessory strip was tried first and
    /// fought the scroll-edge system: rows rendered over the toolbar.
    weak var searchToolbarItem: NSSearchToolbarItem?

    func attachSearchField(to item: NSSearchToolbarItem) {
        configureSearchField()
        item.searchField = searchField
        searchToolbarItem = item
    }

    private func configureSearchField() {
        searchField.placeholderString = mode == .store ? "Search Store" : "Search Installed Apps"
        searchField.delegate = self
        // The cancel button clears the text and sends the action without a
        // controlTextDidChange; route both through the same handler.
        searchField.target = self
        searchField.action = #selector(searchEdited)
    }

    private var footerHeight: NSLayoutConstraint?
    func updateFooterVisibility() {
        addRemove.isHidden = mode == .store
        footerHeight?.constant = mode == .store ? 0 : 34
    }

    private func configureAddRemove() {
        addRemove.segmentStyle = .smallSquare
        addRemove.trackingMode = .momentary
        addRemove.segmentCount = 2
        addRemove.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "Install App"), forSegment: 0)
        addRemove.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: "Uninstall App"), forSegment: 1)
        addRemove.target = self
        addRemove.action = #selector(addOrRemove(_:))
        addRemove.translatesAutoresizingMaskIntoConstraints = false
        // Start disabled and let updateButtons() turn them on. Enabled-by-
        // default meant they were live all through the boot wait.
        addRemove.setEnabled(false, forSegment: 0)
        addRemove.setEnabled(false, forSegment: 1)
        updateButtons()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appsChanged(_:)), name: .ltmAppsChanged, object: nil)
        nc.addObserver(self, selector: #selector(installStarted(_:)), name: .ltmInstallStarted, object: nil)
        nc.addObserver(self, selector: #selector(installProgressed(_:)), name: .ltmInstallProgress, object: nil)
        nc.addObserver(
            self,
            selector: #selector(refreshIconDimming),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(refreshIconDimming),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        statusTracking = ObservationLoop(
            read: { [weak self] in self?.trackedDeviceState() },
            onChange: { [weak self] in self?.deviceStatusChanged() }
        )
        startInitialLoad()
        scheduleSearch()  // Store is the default view — fetch the suggested list
    }

    // MARK: - Loading / refresh
    /// The rows on screen; see AppTableRows.
    var displayed = AppTableRows()
    /// The rows' buttons follow the device (Install needs `canQueueInstall`): booting, readiness, USB and
    /// power changes re-evaluate them here, not on the next poll that happens to reload the table. Unchanged
    /// rows keep their views (reloadTablePreservingSelection compares appearances).
    private var statusTracking: ObservationLoop?
    // NotificationProxy cancels its own loops in its deinit, which is what
    // this releasing it triggers; nothing else here may touch main-actor state.
    deinit {
        loadTask?.cancel()
        searchTask?.cancel()
    }
    /// Apps with an uninstall in flight. Without this the row stayed, the
    /// buttons stayed live, and nothing said anything for up to two minutes —
    /// so the obvious thing to do was press Uninstall again.
    var uninstalling: Set<String> = []
    var removingApp: String?

    // MARK: - Legacy Store (mode + search)
    /// Icons landing together repaint once: a reload per icon rebuilt every row each time.
    var catalogIconReload: Task<Void, Never>?
}
