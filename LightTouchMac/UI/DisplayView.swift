import Cocoa
import DeviceRuntime
import HostRuntime
import LightTouchCore
import Metal

// Device shell and LCD share a transform, whose scale is the zoom's points per guest pixel (DisplayView+Zoom).

/// The device: its shell (the 3D model, the flat art or none) and its live screen, sized by the zoom.
final class DisplayView: NSView {
    /// The device this view shows, fixed at init.
    let profile: Board
    /// The panel at rest — iPod touch 2G: 320×480 at 163 ppi (3.5" panel).
    /// The live frame buffer swaps its sides on rotation.
    var nativeScreenPixels: CGSize

    /// The shell art: its full pixel size, the screen cutout rect within
    /// it (top-left origin, matching this view's isFlipped space), and the
    /// home button circle — all in the shell image's own native (portrait,
    /// unrotated) pixel space.
    let shellPixels: CGSize
    var screenCutout: CGRect
    let homeButtonDiameter: CGFloat
    let homeButtonBottomInset: CGFloat

    /// Whatever the guest is actually sending right now — swaps on rotation.
    var framePixels: CGSize
    /// nil until the first layout, so the initial appearance never "rotates in".
    var lastRotation: Int?

    /// Set by the owner so key/drop events can reach the guest.
    weak var emulator: EmulatorController?
    /// Called when an .ipa is dropped on the screen.
    var onDropIPA: ((URL) -> Void)?
    /// An IPSW from outside: the library's, whatever this device is doing.
    var onDropIPSW: (([URL]) -> Void)?
    var onDropMedia: ((URL) -> Void)?
    /// Called when a Legacy Store row is dropped on the screen.
    var onDropCatalogApp: ((CatalogApp) -> Void)?

    /// How long the shell + screen take to swing between portrait and landscape.
    static let rotationDuration = 0.4

    var deviceLayoutRect: CGRect { safeAreaRect }
    /// The board's own zoom, as last left (ZoomMode.saved), read again at each window entry; the window saves what
    /// the user picks.
    var zoom: ZoomMode = .fit {
        didSet {
            guard oldValue != zoom else { return }
            pendingAnimatedLayout = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            needsLayout = true
        }
    }
    /// Called after each layout: what ⌘+ and ⌘− can do depends on the pane and the display too.
    var onZoomLayout: (() -> Void)?
    /// Set by the scaleMode toggle so the next layout animates even though
    /// orientation didn't change — mirrors how orientationChanged drives it.
    var pendingAnimatedLayout = false

    enum PowerPresentation: Equatable { case awake, sleeping, poweredOff, shuttingDown }
    var powerPresentation: PowerPresentation = .awake
    private var powerBadge: NSStackView?
    var isCapturingCanvas = false { didSet { powerBadge?.isHidden = isCapturingCanvas } }

    func updatePowerPresentation() {
        guard let emulator else { return }
        let next: PowerPresentation =
            restartingAtPanel
            ? .awake
            : emulator.isPoweredOff
                ? .poweredOff
                : emulator.shuttingDown
                    ? .shuttingDown
                    : (emulator.isSleeping && !emulator.preparingDevice && !isShowingLiveText) ? .sleeping : .awake
        guard next != powerPresentation else { return }
        powerPresentation = next
        powerBadge?.removeFromSuperview()
        powerBadge = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.3)
        shellLayer.opacity = next == .awake ? 1 : next == .sleeping ? 0.45 : 0.25
        contentLayer.isHidden = next == .poweredOff
        modelView?.alphaValue = CGFloat(shellLayer.opacity)
        modelView?.setScreenOff(next != .awake)
        CATransaction.commit()
        guard next != .awake else {
            setAccessibilityValue("Device awake")
            return
        }
        let symbol: NSView
        if next == .sleeping {
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 160, height: 128))
            let sleeping = SleepingAnimationView()
            sleeping.frame = container.bounds
            sleeping.autoresizingMask = [.width, .height]
            container.addSubview(sleeping)
            container.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                container.widthAnchor.constraint(equalToConstant: 160),
                container.heightAnchor.constraint(equalToConstant: 128)
            ])
            symbol = container
        } else {
            let power = NSTextField(labelWithString: "⏻")
            power.font = .systemFont(ofSize: 30, weight: .light)
            power.textColor = .white
            symbol = power
        }
        let title = next == .sleeping ? "Sleeping" : next == .poweredOff ? "Powered off" : "Stopping…"
        let stack = NSStackView(views: [symbol])
        if next == .shuttingDown {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 15, weight: .medium)
            label.textColor = .white
            stack.addArrangedSubview(label)
        }
        stack.appearance = NSAppearance(named: .darkAqua)
        stack.orientation = .vertical
        stack.spacing = 10
        if next != .shuttingDown {
            let button = NSButton(
                title: next == .poweredOff ? "Start" : "Wake",
                target: self,
                action: #selector(wakeDevice(_:))
            )
            button.bezelStyle = .rounded
            stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor)
        ])
        powerBadge = stack
        stack.isHidden = isCapturingCanvas
        setAccessibilityValue(title)
    }

    @objc private func wakeDevice(_ sender: Any?) {
        guard let emulator else { return }
        if emulator.isPoweredOff { emulator.powerOn() } else { emulator.pressLock() }
    }

    /// View ▸ Device Bezels, app-wide: 3D (the model), 2D (the flat shell art, no RealityKit at all), or Off — the
    /// screen alone, where input, rotation and zoom work as they do inside the device.
    enum Bezel: Int { case model, flat, off }
    static let bezelKey = "deviceBezel"
    /// The earlier on/off preference; off carries over as `.off`.
    static let showsBezelKey = "showsDeviceBezel"
    static let bezelDidChange = Notification.Name("DisplayViewBezelDidChange")
    static var bezel: Bezel {
        get {
            let defaults = UserDefaults.standard
            if let raw = defaults.object(forKey: bezelKey) as? Int, let bezel = Bezel(rawValue: raw) { return bezel }
            return defaults.object(forKey: showsBezelKey) as? Bool == false ? .off : .model
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: bezelKey)
            NotificationCenter.default.post(name: bezelDidChange, object: nil)
        }
    }
    /// 3D on Apple's own Metal drivers only. RealityKit starts its engine by uploading textures through the driver,
    /// and a third-party one (issue 99: a Hackintosh's NVIDIA driver) crashed the app there, with no error to catch;
    /// such a Mac shows 2D for 3D, as a device without a model does.
    static var rendersModel = isAppleMetalDriver(
        MTLCreateSystemDefaultDevice().flatMap { Bundle(for: type(of: $0)).bundleIdentifier }
    )
    nonisolated static func isAppleMetalDriver(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier?.hasPrefix("com.apple.") == true
    }
    var bare = false
    var appliedBezel: Bezel?

    var modelView: DeviceModelView?
    var pendingModelView: DeviceModelView?
    var modelLoadTask: Task<Void, Never>?
    var modelFallbackTask: Task<Void, Never>?
    var modelPresentationFinished = false
    var lastShakeGeneration: UInt64 = 0
    let contentLayer = CALayer()
    let shellLayer = CALayer()
    let homeButton = HomeButton()
    let attitudeIndicator = AttitudeIndicatorButton(frame: .zero)
    /// Steps the frames and the overlays while the view is in a window.
    private(set) var displayLink: CADisplayLink?
    /// The ring serial on screen, and its surface (captures read it).
    var shownSerial: UInt64 = 0
    var shownSurface: IOSurface?
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var touchPair = MouseTouchPair()
    /// Simulator-style rings where the two fingers of an Option drag land.
    let pairRings = [CAShapeLayer(), CAShapeLayer()]

    init(frame: NSRect, profile: Board) {
        self.profile = profile
        nativeScreenPixels = profile.uprightScreenPixels
        framePixels = nativeScreenPixels
        shellPixels = profile.shellPixels
        screenCutout = profile.screenCutout
        homeButtonDiameter = profile.homeButtonDiameter
        homeButtonBottomInset = profile.homeButtonBottomInset
        zoom = .saved(for: profile)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        shellLayer.contentsGravity = .resize
        // The shell stays at its native pixel size forever; layout() scales and
        // rotates it with a single transform. The content layer lives INSIDE it
        // at the cutout, so scale and rotation can never drift apart — they are
        // one matrix.
        shellLayer.bounds = CGRect(origin: .zero, size: shellPixels)
        // Enough of a shadow to lift the device off the gradient, not enough to
        // notice as an effect. The radius is in the shell's own native pixels,
        // so the transform scales it with the device and the shadow stays
        // proportionate at every window size.
        //
        // Ambient — no offset — on purpose: the shadow belongs to the shell
        // layer, so it rides the same transform, and any offset that fell
        // downwards in portrait would fall sideways once the shell rotates.
        shellLayer.shadowColor = NSColor.black.cgColor
        shellLayer.shadowOpacity = 0.4
        shellLayer.shadowRadius = 40
        shellLayer.shadowOffset = .zero
        layer?.addSublayer(shellLayer)
        touchOverlayLayer.zPosition = 50
        touchOverlayLayer.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        layer?.addSublayer(touchOverlayLayer)
        keyboardPointerLayer.zPosition = 51
        keyboardPointerLayer.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        keyboardPointerLayer.path = CGPath(ellipseIn: CGRect(x: 2, y: 2, width: 14, height: 14), transform: nil)
        keyboardPointerLayer.fillColor = NSColor.black.withAlphaComponent(0.25).cgColor
        keyboardPointerLayer.strokeColor = NSColor.white.cgColor
        keyboardPointerLayer.lineWidth = 2
        keyboardPointerLayer.shadowColor = NSColor.black.cgColor
        keyboardPointerLayer.shadowOpacity = 1
        keyboardPointerLayer.shadowRadius = 1
        keyboardPointerLayer.shadowOffset = .zero
        keyboardPointerLayer.isHidden = true
        layer?.addSublayer(keyboardPointerLayer)
        for ring in pairRings {
            ring.zPosition = 52
            ring.actions = ["position": NSNull(), "hidden": NSNull()]
            ring.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
            ring.fillColor = NSColor(white: 0.5, alpha: 0.35).cgColor
            ring.strokeColor = NSColor(white: 0.25, alpha: 0.6).cgColor
            ring.isHidden = true
            layer?.addSublayer(ring)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
        )

        contentLayer.magnificationFilter = .nearest  // until a layout picks by scale (contentsFilter)
        // The shell is opaque, so the LCD draws on top of it. Black backing
        // shows a powered-on device screen during boot, before the first frame.
        contentLayer.contentsGravity = .resize
        contentLayer.backgroundColor = NSColor.black.cgColor
        contentLayer.position = CGPoint(x: screenCutout.midX, y: screenCutout.midY)
        shellLayer.addSublayer(contentLayer)

        homeButton.target = self
        homeButton.action = #selector(homeTapped)
        addSubview(homeButton)
        applyBezel(Self.bezel)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bezelPreferenceChanged),
            name: Self.bezelDidChange,
            object: nil
        )
        attitudeIndicator.target = self
        attitudeIndicator.action = #selector(levelAttitude(_:))
        attitudeIndicator.isHidden = true
        attitudeIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(attitudeIndicator)
        NSLayoutConstraint.activate([
            attitudeIndicator.widthAnchor.constraint(equalToConstant: 40),
            attitudeIndicator.heightAnchor.constraint(equalToConstant: 40),
            attitudeIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            attitudeIndicator.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        ])

        registerForDraggedTypes([.fileURL, .ltmCatalogApp])
        setAccessibilityLabel("\(profile.displayName) screen")
        setAccessibilityRole(.group)
        setAccessibilityCustomActions(
            Self.screenActions.map { title, action in
                NSAccessibilityCustomAction(name: title) { [weak self] in NSApp.sendAction(action, to: nil, from: self)
                }
            }
        )
        setAccessibilityHelp(
            "Turn off Send Keyboard Input (Device > Input) to move a pointer with the arrow keys. Hold Space to touch; Shift-arrow drags."
        )
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }  // y-down, matching the guest
    override var acceptsFirstResponder: Bool { true }
    /// A click into a window in the background touches the device at once, as on a real screen.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The device's buttons and the capture actions, for the contextual menu and VoiceOver's actions;
    /// each goes up the responder chain to the window's own command (MainWindowController's, by name).
    static let screenActions: [(String, Selector)] = [
        ("Home Screen", NSSelectorFromString("deviceHome:")),
        ("Lock", NSSelectorFromString("deviceLock:")),
        ("Rotate Left", NSSelectorFromString("deviceRotateLeft:")),
        ("Rotate Right", NSSelectorFromString("deviceRotateRight:")),
        ("Shake", NSSelectorFromString("deviceShake:")),
        ("Copy Screenshot", NSSelectorFromString("copyScreen:")),
        ("Save Screenshot", NSSelectorFromString("saveScreenshot:"))
    ]

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (index, (title, action)) in Self.screenActions.enumerated() {
            if index == 5 { menu.addItem(.separator()) }
            menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        }
        return menu
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the window: stop the link. It retains self, and nothing ever
        // invalidated it — so the view (and the emulator through it) could never
        // deallocate and step() kept polling, deep-copying frames forever. Only
        // masked because closing the window usually quits the app.
        if window == nil {
            modelLoadTask?.cancel()
            modelFallbackTask?.cancel()
            // A model cut short is loaded again on the way back (applyBezel skips the bezel it applied).
            if !modelPresentationFinished { appliedBezel = nil }
            wheelTiltResetTask?.cancel()
            displayLink?.invalidate()
            displayLink = nil
            NotificationCenter.default.removeObserver(self)
            return
        }
        guard displayLink == nil else { return }
        // The zoom is saved per board: another device of this board may have changed it while this view was away.
        zoom = .saved(for: profile)
        // Every window entry: leaving one dropped all of this view's observers (above), the bezel's included,
        // so a view that had left a window (a session swap, a restart at a new panel) ignored View ▸ Show Device
        // Bezel for good. The preference may have changed meanwhile too.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bezelPreferenceChanged),
            name: Self.bezelDidChange,
            object: nil
        )
        bezelPreferenceChanged()
        let link = displayLink(target: self, selector: #selector(step))
        // At the guest's refresh, not the display's: left alone a link runs at the display's highest rate, which
        // holds a ProMotion panel at 120 Hz and steps twice for each 60 Hz frame (issue 107).
        let hz = Float(DisplayRefresh.hz)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, hz), maximum: hz, preferred: hz)
        link.add(to: .main, forMode: .common)
        displayLink = link
        // Moving between displays can change the backing pixel scale.
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didMoveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: name, object: window)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(releaseHeldKeys),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc private func homeTapped() {
        endLiveText()
        emulator?.pressHome()
    }

    // MARK: - Layout
    var appliedScale: CGFloat = 1

    // MARK: - Free-form screen (issue #21)
    /// The upright guest panel the running boot has, when free-form is on; nil: the device as shipped.
    var freeFormPanel: CGSize?
    /// The upright size a resize gives, waiting for Apply or restarting at; nil, none.
    var freeFormTarget: CGSize?
    /// How far a one-sided resize moved the screen's center, in points, so the opposite edge stayed put.
    var freeFormOffset = CGVector.zero
    /// Why the resize's edge stopped (FreeFormResize), for the readout.
    var freeFormLimit: String?
    /// The free-form panel as it scans (the record's `panel`); nil, the shipped one.
    var runningScan: CGSize?
    /// Records an upright panel (nil: the shipped one); with `restart` true the owner restarts the device on it.
    /// Returns whether a restart is under way.
    var onPanelChange: ((_ upright: CGSize?, _ restart: Bool) -> Bool)?
    /// The free-form size, its readout, a waiting size or a restart changed.
    var onFreeFormChange: (() -> Void)?
    var deviceKey: UUID?
    var restartingAtPanel = false
    /// Showing the last frame of the session that restarted this device at a new size, until its first new frame.
    var showsHandoff = false
    var panelDrag: (origin: CGPoint, edges: CGVector, size: CGSize, offset: CGVector)?
    /// "Restarting at W × H…" for the startup notice of a boot this view's device restarted at a new panel.
    var restartTitle: String?

    // MARK: - Frame polling
    var liveTextView: InlineLiveTextView?
    var showsTouches = UserDefaults.standard.bool(forKey: "showsTouches") {
        didSet {
            UserDefaults.standard.set(showsTouches, forKey: "showsTouches")
            updateTouchOverlay()
        }
    }
    // A sibling of the device shell, never a child of the framebuffer layer.
    // Fading/shadow compositing must not involve the guest screen's contents.
    let touchOverlayLayer = CALayer()
    var touchLayers: [Int: CALayer] = [:]
    var visibleTouches: [Int: (point: CGPoint, expires: CFTimeInterval)] = [:]

    // MARK: - Touch input
    /// Where the guest touch(es) are right now, in 0…1 panel space.
    var gestureAnchor = CGPoint.zero
    /// Half the current pinch separation, panel-relative.
    var pinchSpread = 0.0
    var pinchingGuest = false
    /// Live scroll-drag: a two-finger scroll over the screen as a finger (ScrollDrag).
    var scrollDrag = ScrollDrag()
    var scrollPoint: CGPoint? { scrollDrag.point }
    /// Tilt driven by a two-finger scroll off the panel.
    /// Tilt's gesture state and math (ChassisTilt): drag, scroll and twist off the panel.
    var tilt = ChassisTilt()
    var wheelTiltResetTask: Task<Void, Never>?

    // MARK: - Tilt (drag the chassis to rotate; the accelerometer follows)
    /// Is a mouse-driven touch currently down in the guest? The host and the
    /// guest each keep their own idea of that, and this is what keeps the two
    /// from drifting apart.
    var touchDown = false

    // MARK: - Keyboard pointer (typing disabled)
    let keyboardPointerLayer = CAShapeLayer()
    var keyboardPointer = KeyboardPointer()
    var consumedWakeSpace = false
    var heldKeys = HeldKeys()
    var keyInText: NSEvent?
    var markedText = NSMutableAttributedString()

    // MARK: - Drag & drop
    lazy var dropHighlight = DropHighlight.install(in: self)
}

/// The touch phases of qemu-ios-ui.h (LinkCommand.touch).
enum TouchPhase {
    static let begin: Int32 = 0, update: Int32 = 1, end: Int32 = 2
}

/// The shell's home button: invisible until pressed, then a soft black circle
/// — drawn directly rather than via a bezel/image since it sits on shell
/// artwork with a shape (and press state) no stock NSButton style covers.
final class HomeButton: NSButton {
    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityLabel("Home")
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(isHighlighted ? 0.5 : 0).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
