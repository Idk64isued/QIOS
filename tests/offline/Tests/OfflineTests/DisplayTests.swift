import AppKit
import HostRuntime
import Testing

@testable import Display
@testable import LightTouchCore

extension SharedState {
    /// The production DisplayView over a fake link and device (Sources/Display): windows built and never ordered in.
    @Suite struct DisplayTests {
        init() {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            _ = fixtureMachines
        }

        static let n72Model = [
            "Models/N72.usdz": "Models/N72.usdz",
            "shell.png": "LightTouchMac/Assets.xcassets/shell.imageset/shell_opaque.png"
        ]

        /// The flat LCD layer is black-backed, stretched to the cutout, and upscales nearest-neighbor (minification filters).
        @Test(arguments: [Board.n72, .k48, .n45, .n81, .n88]) func lcdLayerMagnifiesNearest(_ profile: Board) {
            let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: profile)
            func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
            let lcds = all(display.layer!).filter {
                $0.backgroundColor == NSColor.black.cgColor && $0.contentsGravity == .resize
            }
            #expect(lcds.count == 1, "expected one LCD layer, found \(lcds.count)")
            #expect(
                lcds.first?.magnificationFilter == .nearest,
                "DisplayView's LCD upscales with \(String(describing: lcds.first?.magnificationFilter.rawValue))"
            )
            #expect(lcds.first?.minificationFilter != .nearest, "DisplayView's LCD minification should filter")
        }

        /// The flat device's shadow is cast from its art's outline (a shadow path), never from the layer's pixels:
        /// without a path Core Animation renders the shadow from everything the shell holds, the live screen
        /// included, so each frame re-rendered it offscreen and redrew its area, up under the toolbar (issue 107).
        /// The outline is the device's: it holds the screen and stays inside the art's rounded corners.
        @Test(arguments: [Board.n72, .k48, .n45, .n81, .n90, .m68]) func flatShadowFollowsTheArt(_ profile: Board)
            async throws
        {
            let name = profile.shellImageName
            let folder = MainBundle.repository.appendingPathComponent("LightTouchMac/Assets.xcassets/\(name).imageset")
            let png = try #require(
                FileManager.default.contentsOfDirectory(atPath: folder.path).first { $0.hasSuffix(".png") }
            )
            try await MainBundle.with(["\(name).png": "LightTouchMac/Assets.xcassets/\(name).imageset/\(png)"]) {
                DisplayView.bezel = .flat
                defer { UserDefaults.standard.removeObject(forKey: DisplayView.bezelKey) }
                let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: profile)
                let shell = display.shellLayer
                #expect(shell.contents != nil, "\(profile): the flat art is loaded")
                #expect(shell.shadowOpacity > 0, "\(profile): the flat device casts a shadow")
                let path = try #require(shell.shadowPath, "\(profile): the shadow is cast from the layer's pixels")
                let size = profile.shellPixels
                let box = path.boundingBox
                #expect(
                    box.height > size.height * 0.95 && box.width > size.width * 0.8 && box.maxX <= size.width + 0.5
                        && box.maxY <= size.height + 0.5,
                    "\(profile): outline \(box) in art \(size)"
                )
                let cutout = profile.screenCutout
                #expect(path.contains(CGPoint(x: cutout.midX, y: cutout.midY)), "\(profile): the screen is inside")
                let corners = [CGPoint(x: 1, y: 1), CGPoint(x: size.width - 1, y: size.height - 1)]
                #expect(!corners.contains { path.contains($0) }, "\(profile): the outline keeps the art's corners out")
                display.applyBezel(.off)
                #expect(shell.shadowOpacity == 0 && shell.shadowPath == nil, "\(profile): no bezel, no shadow")
            }
        }

        /// A display that leaves its window before its model is presented (another device selected meanwhile) shows
        /// the model when it comes back, where it kept the shell and the Home button hidden until the bezel changed.
        @Test func aModelLoadCutShortLoadsAgainOnReturn() async throws {
            try await MainBundle.with(Self.n72Model) {
                DeviceModelView.loadingDelay = .milliseconds(300)
                defer { DeviceModelView.loadingDelay = .zero }
                let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 500, height: 800), profile: .n72)
                let emulator = EmulatorController()
                display.emulator = emulator
                let window = NSWindow(
                    contentRect: display.frame,
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                window.contentView = display
                try await Task.sleep(for: .milliseconds(50))
                window.contentView = nil
                try await Task.sleep(for: .milliseconds(400))
                window.contentView = display
                let started = ContinuousClock.now
                @MainActor func live() -> Bool {
                    display.subviews.contains { ($0 as? DeviceModelView)?.alphaValue ?? 0 > 0.99 }
                }
                while !live() && ContinuousClock.now - started < .seconds(5) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(live(), "the model loads again once the display is back in a window")
                window.contentView = nil
            }
        }

        /// The 3D model's startup: a fast first frame, a slow asset and a slow first frame all reach live 3D; the photo
        /// placeholder never flashes before the model's first second and shows after it while unprepared models stay
        /// invisible; a stalled renderer callback doesn't keep a closed display alive.
        @Test func modelStartupPlaceholderAndLifetime() async throws {
            try await MainBundle.with(Self.n72Model) {
                for scenario in ["fast", "slow asset", "slow frame"] {
                    DeviceModelView.loadingDelay = scenario == "slow asset" ? .milliseconds(1400) : .zero
                    DeviceModelView.preparationDelay =
                        scenario == "slow frame" ? .milliseconds(1400) : .milliseconds(50)
                    DeviceModelView.framesPrepared = 0
                    let started = ContinuousClock.now
                    let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 500, height: 800), profile: .n72)
                    let e = EmulatorController()
                    display.emulator = e
                    let window = NSWindow(
                        contentRect: display.frame,
                        styleMask: [.titled],
                        backing: .buffered,
                        defer: false
                    )
                    window.contentView = display
                    display.needsLayout = true
                    display.layoutSubtreeIfNeeded()
                    let shell = try #require(
                        display.layer!.sublayers!.first { $0.bounds.size == CGSize(width: 737, height: 1318) }
                    )
                    // Sampled every 10 ms: a late wake-up must not skip the placeholder's 1.0-1.4 s window or read the model mid-fade.
                    var placeholderShown = false
                    @MainActor func live() -> Bool {
                        let m = display.subviews.compactMap { $0 as? DeviceModelView }
                        return DeviceModelView.framesPrepared > 0 && m.count == 1 && m[0].alphaValue > 0.99
                            && shell.isHidden
                    }
                    while !live() && ContinuousClock.now - started < .seconds(5) {
                        if !shell.isHidden {
                            #expect(
                                ContinuousClock.now - started >= .seconds(1),
                                "\(scenario): the photo flashed before the model's first chance to render"
                            )
                            if DeviceModelView.framesPrepared == 0 {
                                #expect(
                                    display.subviews.compactMap { $0 as? DeviceModelView }.allSatisfy {
                                        $0.alphaValue == 0
                                    },
                                    "Unprepared models must stay invisible"
                                )
                            }
                            placeholderShown = true
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    if scenario != "fast" { #expect(placeholderShown, "\(scenario): no placeholder within one second") }
                    #expect(
                        live(),
                        "\(scenario): a ready first frame must eventually present live 3D, including after the placeholder"
                    )
                    window.contentView = nil
                }
                DeviceModelView.loadingDelay = .zero
                DeviceModelView.preparationDelay = .seconds(5)
                defer { DeviceModelView.preparationDelay = .milliseconds(50) }
                var closing: DisplayView? = DisplayView(
                    frame: NSRect(x: 0, y: 0, width: 500, height: 800),
                    profile: .n72
                )
                weak let released = closing
                let closingWindow = NSWindow(
                    contentRect: closing!.frame,
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                closingWindow.contentView = closing
                try await Task.sleep(for: .milliseconds(100))
                closingWindow.contentView = nil
                closing = nil
                try await Task.sleep(for: .milliseconds(100))
                #expect(released == nil, "A stalled renderer callback must not retain the closed display")
            }
        }

        /// 3D on Apple's Metal drivers only (issue 99: RealityKit's engine start crashed inside a Hackintosh's
        /// third-party NVIDIA driver): elsewhere the 3D setting shows the flat device and never starts RealityKit.
        @Test func modelOnlyOnAppleMetalDrivers() async throws {
            #expect(DisplayView.rendersModel, "this Mac's Metal driver is Apple's")
            #expect(DisplayView.isAppleMetalDriver("com.apple.AGXMetalG16X"))
            #expect(DisplayView.isAppleMetalDriver("com.apple.AMDMTLBronzeDriver"))
            #expect(!DisplayView.isAppleMetalDriver("com.nullmoth.NVMTLDriver"))
            #expect(!DisplayView.isAppleMetalDriver(nil))
            try await MainBundle.with(Self.n72Model) {
                DisplayView.bezel = .model
                defer {
                    UserDefaults.standard.removeObject(forKey: DisplayView.bezelKey)
                    DisplayView.rendersModel = true
                }
                for renders in [true, false] {
                    DisplayView.rendersModel = renders
                    let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 500, height: 800), profile: .n72)
                    #expect((display.modelLoadTask != nil) == renders, "renders \(renders): a model load started")
                    #expect(display.shellLayer.isHidden == renders, "renders \(renders): the flat device shows")
                    display.applyBezel(.off)
                }
            }
        }

        /// A run that died starting the 3D device (CrashGuard's mark left at the next launch) shows the flat device at
        /// 3D and starts no model; View ▸ Device Bezels ▸ 3D loads it again, and a load that ends leaves no mark.
        @Test func modelSkippedAfterACrashInIt() async throws {
            let domain = "ltm-display-crash-guard-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            CrashGuard.launch(defaults)
            CrashGuard.begin(.model)
            #expect(CrashGuard.launch(defaults) == [.model], "the run died with the model loading")
            try await MainBundle.with(Self.n72Model) {
                DisplayView.bezel = .model
                defer {
                    UserDefaults.standard.removeObject(forKey: DisplayView.bezelKey)
                    CrashGuard.tryAgain(.model)
                }
                let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 500, height: 800), profile: .n72)
                #expect(display.modelLoadTask == nil, "no model load after a crash in one")
                #expect(!display.shellLayer.isHidden, "the flat device shows")
                // View ▸ Device Bezels ▸ 3D (MainWindowController.selectDeviceBezel).
                CrashGuard.tryAgain(.model)
                DisplayView.bezel = .model
                let load = try #require(display.modelLoadTask, "choosing 3D loads the model")
                #expect(defaults.dictionary(forKey: CrashGuard.key) as? [String: String] == ["model": "running"])
                await load.value
                #expect(defaults.object(forKey: CrashGuard.key) == nil, "a load that ends leaves no mark")
                #expect(CrashGuard.launch(defaults).isEmpty && !CrashGuard.skips(.model))
                display.applyBezel(.off)
            }
        }

        /// The display link steps at the guest's refresh (60 Hz, or 120 with the experimental setting), never at the
        /// display's own top rate, which on a ProMotion Mac is 120 Hz: a link left at that holds the panel at 120 Hz and
        /// steps twice for every 60 Hz frame while the device is shown, frames or not (issue 107).
        @Test(arguments: [false, true]) func displayLinkRunsAtTheGuestsRefresh(_ refresh120: Bool) {
            UserDefaults.standard.set(refresh120, forKey: DisplayRefresh.key)
            defer { UserDefaults.standard.removeObject(forKey: DisplayRefresh.key) }
            let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 720, height: 640), profile: .n72)
            let window = NSWindow(contentRect: display.frame, styleMask: [.titled], backing: .buffered, defer: true)
            window.contentView = display
            defer { window.contentView = nil }
            let range = try? #require(display.displayLink?.preferredFrameRateRange)
            let hz: Float = refresh120 ? 120 : 60
            #expect(range?.maximum == hz && range?.preferred == hz, "the link asks for \(String(describing: range))")
        }

        /// What changes with each guest frame stays out of the toolbar (issue 107): in the main window's full-size
        /// content window, with the sidebar shown or collapsed, at Fit and zoomed past the pane, no live layer (the
        /// flat screen, the 3D model's renderer) shows under the toolbar, where the glass would be composited again
        /// with every frame, and a frame lays nothing out and marks nothing for display in the device's pane.
        @Test(arguments: [DisplayView.Bezel.off, .flat, .model], [false, true])
        func framesStayOutOfTheToolbar(_ bezel: DisplayView.Bezel, sidebarCollapsed: Bool) async throws {
            try await MainBundle.with(Self.n72Model) {
                DisplayView.bezel = bezel
                defer { UserDefaults.standard.removeObject(forKey: DisplayView.bezelKey) }
                let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 720, height: 640), profile: .n72)
                let emulator = EmulatorController()
                display.emulator = emulator
                let content = DeviceContentView(screen: display)
                // As MainWindowController builds it: a sidebar beside the device pane, the toolbar unified.
                let split = NSSplitViewController()
                let library = NSViewController()
                library.view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 640))
                let sidebar = NSSplitViewItem(sidebarWithViewController: library)
                split.addSplitViewItem(sidebar)
                let pane = NSViewController()
                pane.view = content
                split.addSplitViewItem(NSSplitViewItem(viewController: pane))
                let window = NSWindow(contentViewController: split)
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                window.setContentSize(NSSize(width: 980, height: 700))
                window.toolbarStyle = .unified
                window.toolbar = NSToolbar(identifier: "frames-\(UUID())")
                sidebar.isCollapsed = sidebarCollapsed
                defer {
                    window.contentViewController = nil
                    withExtendedLifetime(emulator) {}
                }
                // Toolbar and titlebar: the window above its content layout rect.
                let layoutRect = window.contentLayoutRect
                let toolbar = CGRect(x: 0, y: layoutRect.maxY, width: window.frame.width, height: 10_000)
                #expect(layoutRect.maxY < window.frame.height - 20, "the window has a toolbar over its content")
                @MainActor func model() -> DeviceModelView? {
                    display.subviews.compactMap { $0 as? DeviceModelView }.first { $0.alphaValue > 0.99 }
                }
                if bezel == .model {
                    let started = ContinuousClock.now
                    while model() == nil && ContinuousClock.now - started < .seconds(5) {
                        display.step()
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(model() != nil, "the 3D model is live")
                }
                /// A rect of `view` in window points, as far as the views that clip it show it.
                @MainActor func shown(_ rect: CGRect, in view: NSView) -> CGRect {
                    var shown = view.convert(rect, to: nil)
                    var next: NSView? = view
                    while let clip = next {
                        if clip.layer?.masksToBounds == true {
                            shown = shown.intersection(clip.convert(clip.bounds, to: nil))
                        }
                        next = clip.superview
                    }
                    return shown
                }
                func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
                for zoom in [ZoomMode.fit, .points(2)] {
                    display.zoom = zoom
                    window.layoutIfNeeded()
                    for _ in 0..<3 { display.step() }
                    window.layoutIfNeeded()
                    for frame in 0..<10 {
                        // Never ordered in, the window draws nothing: what was marked before the frame stays marked.
                        window.layoutIfNeeded()
                        let before = Set(all(content.layer!).filter { $0.needsDisplay() }.map(ObjectIdentifier.init))
                        display.step()
                        let tag = "\(bezel) sidebar \(sidebarCollapsed ? "collapsed" : "shown") \(zoom) frame \(frame)"
                        #expect(!display.needsLayout && !content.needsLayout, "\(tag): the frame laid the pane out")
                        let marked = all(content.layer!).filter {
                            $0.needsDisplay() && !before.contains(ObjectIdentifier($0))
                        }
                        #expect(marked.isEmpty, "\(tag): the frame marked \(marked) for display")
                        var live: [(String, CGRect)] = []
                        if !display.shellLayer.isHidden, !display.contentLayer.isHidden {
                            let screen = display.contentLayer.convert(display.contentLayer.bounds, to: display.layer!)
                            live.append(("screen", shown(screen, in: display)))
                        }
                        if let model = model() { live.append(("3D model", shown(model.bounds, in: model))) }
                        #expect(!live.isEmpty, "\(tag): something shows the frames")
                        for (name, rect) in live where rect.intersects(toolbar) {
                            Issue.record(
                                "\(tag): the \(name) shows under the toolbar: \(rect), toolbar from y \(toolbar.minY)"
                            )
                        }
                    }
                }
                display.applyBezel(.off)
            }
        }
    }
}
