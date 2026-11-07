// Hosts the device screen in the window's main column. The DisplayView is the
// main content; it centers its content and becomes first responder so
// keyboard passthrough works whenever the device area has focus.

import Cocoa
import HostRuntime
import LightTouchCore

final class DeviceViewController: NSViewController {
    let emulator: EmulatorController
    private let displayView: DisplayView
    private let panelStatus = CaptureStatusView()

    init(emulator: EmulatorController) {
        self.emulator = emulator
        self.displayView = DisplayView(
            frame: NSRect(origin: .zero, size: emulator.profile.screenPixels),
            profile: emulator.profile
        )
        super.init(nibName: nil, bundle: nil)
        displayView.emulator = emulator
        let profile = emulator.profile
        displayView.configureFreeForm(scan: Board.panelScan(emulator.instance.panel), key: emulator.instance.id)
        displayView.onPanelChange = { [weak emulator] upright, restart in
            emulator?.setPanel(upright.map(profile.panelOption(upright:)), restart: restart) ?? false
        }
        emulator.onRestartRefused = { [weak displayView] in displayView?.panelRestartRefused() }
        // A free-form size waiting for Apply, or the restart at it, is a notice like the others: same stack, same
        // glass, never under one. The window's subtitle reads the size.
        panelStatus.isHidden = true
        panelStatus.onPrimary = { [weak self] in self?.displayView.applyPanel() }
        panelStatus.onSecondary = { [weak self] in self?.displayView.revertPanel() }
        displayView.onFreeFormChange = { [weak self] in
            guard let self else { return }
            updatePanelStatus()
            onFreeFormChange?()
        }
        displayView.onDropIPA = { [weak self] url in self?.installDropped(url) }
        displayView.onDropIPSW = { FirmwareJobs.shared.importIPSWs($0) }  // matched by their SHA1s
        // Media the firmware can't take is refused on its row, with why (MediaSupport), before anything runs.
        displayView.onDropMedia = { [weak self] url in
            guard let self, self.emulator.canQueueInstall else { return }
            AppInstaller.startMedia(url, with: self.emulator, presenting: self.view.window)
        }
        displayView.onDropCatalogApp = { [weak self] app in
            guard let self, self.emulator.canQueueInstall else { return }
            AppInstaller.startCatalog(app, with: self.emulator, presenting: self.view.window)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let content = DeviceContentView(screen: displayView)
        view = content
        content.addStatus(panelStatus)
    }

    func addStatus(_ status: NSView) { (view as? DeviceContentView)?.addStatus(status) }
    func updateStatusVisibility() { (view as? DeviceContentView)?.updateStatusVisibility() }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(displayView)
        // Covered, minimized, on another Space or the app hidden: the window's occlusion covers them all.
        occlusion.map(NotificationCenter.default.removeObserver)
        occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: view.window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateScreenVisible() }
        }
        updateScreenVisible()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        occlusion.map(NotificationCenter.default.removeObserver)
        occlusion = nil
        emulator.screenVisible = phoneShowsScreen
    }

    /// EmulatorController.screenVisible: the helper paces itself by it.
    private var occlusion: NSObjectProtocol?
    /// A phone shows this screen (PhoneRemoteController): it stays on show with the window covered or the display asleep.
    var phoneShowsScreen = false {
        didSet { updateScreenVisible() }
    }
    private func updateScreenVisible() {
        emulator.screenVisible = view.window?.occlusionState.contains(.visible) == true || phoneShowsScreen
    }

    var screen: DisplayView { displayView }
    /// The free-form readout changed (the window's subtitle shows it).
    var onFreeFormChange: (() -> Void)?

    private func updatePanelStatus() {
        if let restarting = displayView.panelRestartText {
            panelStatus.update(title: restarting, busy: true)
        } else if displayView.hasPendingPanel, displayView.panelDrag == nil, let size = displayView.freeFormSize {
            panelStatus.update(
                title: size,
                detail: displayView.freeFormLimit ?? "Apply restarts the \(emulator.profile.shortName) at this size.",
                primary: "Apply",
                secondary: "Revert"
            )
        } else {
            panelStatus.isHidden = true
        }
        updateStatusVisibility()
    }

    /// The same preconditions the menu and toolbar enforce for Install App…
    /// A drop used to bypass all of them, so an .ipa dropped during the ~40s
    /// boot (or with app sync off) was accepted, put a spinner in a sidebar
    /// that wasn't even polling, and failed a moment later with a modal —
    /// while the button for the identical operation sat grayed out.
    func installDropped(_ url: URL) {
        // Deliberately NOT gated on isInstalling: AppInstaller queues each job
        // when their bytes are ready, so dropping another IPA is supported.
        // Refusing it was a regression — dropping three at once is the whole
        // point of accepting multiple files.
        guard emulator.canQueueInstall else {
            let alert = NSAlert()
            alert.messageText = "The \(emulator.profile.shortName) isn’t ready yet"
            alert.informativeText = "Try again when it has finished starting up."
            if let window = view.window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
            return
        }
        AppInstaller.start(url, with: emulator, presenting: view.window)
    }
}
