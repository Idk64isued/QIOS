import AppKit
import DeviceRuntime
import HostRuntime
import Testing

@testable import Display
@testable import LightTouchCore

extension SharedState {
    /// DisplayView's layouts: bezels off, a rotation with no new frame, free-form panels (no window ordered in).
    @Suite struct DisplayLayoutTests {
        init() {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            _ = fixtureMachines
            sent = []
            touches = []
            frozen = false
            (frameWidth, frameHeight) = (320, 480)
        }

        /// View ▸ Device Bezels ▸ Off: no 3D model, no shell art or shadow, no Home button; the LCD alone fills the pane
        /// (inset) at its center in portrait and landscape and takes clicks as touches (a click off it nothing); 2x zoom
        /// is two display pixels per guest pixel; 3D and 2D come back and go again; a press just off the 2D bezel's edge
        /// is an edge touch; the old bezel-off preference carries over; the iPad's sideways panel stands upright.
        @Test func bareScreen() async throws {
            try await MainBundle.with(DisplayTests.n72Model) { try await bareScreenBody() }
        }

        /// An iPhone 4 rotation (Sam 10-06/07): the A4 scans its portrait panel out as is, so the app hears of the
        /// orientation with nothing new on screen; the display's own tick lays the device out landscape and the portrait
        /// picture turns with the chassis instead of stretching.
        @Test func rotationWithoutANewFrame() async throws {
            try await MainBundle.with([
                "shell-iphone4.png": "LightTouchMac/Assets.xcassets/shell-iphone4.imageset/shell-iphone4.png"
            ]) {
                try await rotationBody(.n90)
            }
        }

        /// The same on the CLCD boards (the iPhone 2G to 3GS, the iPod touch 1G to 3G): their LCD scans its panel out as
        /// is too, so a turn shows the picture turned with the chassis, never stretched or turned back upright.
        @Test(arguments: Self.clcdBoards) func rotationOfAFixedLCD(board: Board) async throws {
            try await rotationBody(board)
        }
        static let clcdBoards = Board.allCases.filter { $0.soc != .s5l8930 }

        /// View ▸ Free-Form Screen (issue #21): the sizes each board's panel= takes, the LCD at one point per guest pixel
        /// for a non-native panel and its touch mapping, dragging the LCD's edge (live stretch, snapped readout, clamps,
        /// landscape's swapped sides, the restart on release), window and sidebar resizes that change nothing, and Off.
        @Test func freeFormScreen() async throws {
            try await MainBundle.with([
                "ipad-frame.png": "LightTouchMac/Assets.xcassets/ipad-frame.imageset/ipad-frame.png"
            ]) { try await freeFormBody() }
        }

        func bareScreenBody() async throws {
            // A crashed run can leave the key behind (this binary's own defaults domain): start clean.
            for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            defer {
                for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            #expect(DisplayView.bezel == .model, "the 3D model shows by default")
            UserDefaults.standard.set(false, forKey: DisplayView.showsBezelKey)
            #expect(DisplayView.bezel == .off, "the old bezel-off preference didn't carry over")
            UserDefaults.standard.removeObject(forKey: DisplayView.showsBezelKey)
            DisplayView.bezel = .off
            #expect(
                UserDefaults.standard.object(forKey: DisplayView.bezelKey) as? Int == DisplayView.Bezel.off.rawValue,
                "not persisted"
            )
            DeviceModelView.loadingDelay = .zero
            DeviceModelView.preparationDelay = .milliseconds(50)

            let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: .n72)
            let e = EmulatorController()
            display.emulator = e
            let window = NSWindow(contentRect: display.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = display
            func settle() async throws {
                display.needsLayout = true
                display.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(1300))
            }
            try await settle()
            func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
            let lcd = all(display.layer!).first {
                $0.backgroundColor == NSColor.black.cgColor
                    && ($0.contentsGravity == .resize || $0.contentsGravity == .center)
            }!
            let shell = lcd.superlayer!
            func models() -> [NSView] { display.subviews.filter { $0 is DeviceModelView } }
            let home = display.subviews.first { NSStringFromClass(type(of: $0)).contains("HomeButton") }!
            func check(_ ok: Bool, _ what: String, line: Int = #line) { #expect(ok, "line \(line): \(what)") }

            check(models().isEmpty && DeviceModelView.framesPrepared == 0, "bare loads no model")
            check(
                shell.contents == nil && shell.shadowOpacity == 0 && !shell.isHidden,
                "bare shell draws nothing, casts no shadow"
            )
            check(home.isHidden, "no Home button bare")
            check(!display.canPerformSpecialTrick, "the special trick is offered with no model")
            // The LCD's on-screen box, centered, filling the pane less the inset in its long dimension.
            func box() -> CGRect { lcd.convert(lcd.bounds, to: display.layer!) }
            func fills(_ landscape: Bool) {
                let b = box()
                let side = 800 - 2 * DisplayView.zoomInset
                check(abs(b.midX - 400) < 1 && abs(b.midY - 400) < 1, "LCD off center: \(b)")
                check(landscape ? b.width > b.height : b.height > b.width, "LCD orientation: \(b)")
                check(
                    abs(max(b.width, b.height) - side) < 1 && min(b.width, b.height) < side,
                    "LCD doesn't fill the pane: \(b)"
                )
            }
            fills(false)
            func click(_ p: CGPoint) {
                let b = box()
                let at = display.convert(CGPoint(x: b.minX + p.x * b.width, y: b.minY + p.y * b.height), to: nil)
                let down = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: at,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )!
                let up = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: at,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )!
                touches.removeAll()
                display.mouseDown(with: down)
                display.mouseUp(with: up)
            }
            /// A click at `p` of the LCD as seen touches the panel at `p` turned back by the device's quarter turns.
            func touchLands(_ p: CGPoint, quarters: Int = 0) {
                click(p)
                var want = p
                for _ in 0..<quarters { want = CGPoint(x: want.y, y: 1 - want.x) }
                check(
                    !touches.isEmpty && abs(touches[0].0 - want.x) < 0.01 && abs(touches[0].1 - want.y) < 0.01,
                    "touch at \(p) sent \(touches), want \(want)"
                )
            }
            for p in [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.8, y: 0.7)] { touchLands(p) }
            click(CGPoint(x: 0.5, y: -0.05))
            check(
                touches.isEmpty && e.attitude.angle == 0,
                "a click off the LCD touched or tilted: \(touches) \(e.attitude)"
            )

            // Landscape: the panel, scanned out as is, turns with the device; the LCD stays centered and fills the
            // pane's width, and a click touches the panel where it shows.
            e.rotationDegrees = 90
            display.perform(NSSelectorFromString("step"))
            try await settle()
            fills(true)
            for p in [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.8, y: 0.7)] { touchLands(p, quarters: 1) }
            e.rotationDegrees = 0

            // Zoom: 2 points per guest pixel, the LCD alone sized by it; Pixel Accurate is one display pixel each, crisp.
            display.zoom = .points(2)
            try await settle()
            check(abs(display.zoomPoints - 2) < 0.001 && abs(box().height - 960) < 1, "2 pt zoom gives \(box())")
            display.zoom = .pixelAccurate
            try await settle()
            let backing = window.backingScaleFactor
            check(abs(box().height * backing - 480) < 0.5, "Pixel Accurate LCD is \(box()) at backing \(backing)")
            check(lcd.magnificationFilter == .nearest, "Pixel Accurate isn't crisp")
            display.zoom = .fit

            // Back on: the shell art, its shadow and (with the stub renderer) the model; off again drops it.
            DisplayView.bezel = .model
            try await settle()
            check(shell.contents != nil && shell.shadowOpacity > 0, "bezel on: no shell art or shadow")
            check(models().count == 1 && DeviceModelView.framesPrepared == 1, "bezel on: the model didn't load")
            check(display.canPerformSpecialTrick, "3D: the special trick isn't offered")
            for model in models() { model.isHidden = true }
            shell.isHidden = false
            home.isHidden = false
            // 2D: the shell art, its shadow and the Home button, with no model loaded or kept.
            DisplayView.bezel = .flat
            try await settle()
            check(models().isEmpty && DeviceModelView.framesPrepared == 1, "flat: a model is loaded or shown")
            check(!display.canPerformSpecialTrick, "2D: the special trick is offered")
            check(
                shell.contents != nil && shell.shadowOpacity > 0 && !shell.isHidden && !home.isHidden,
                "flat: no shell art, shadow or Home button"
            )
            touchLands(CGPoint(x: 0.5, y: 0.5))
            // A press a few points off the screen's edge, on the bezel, is an edge touch clamped onto the edge (so edge swipes
            // start), not a chassis grab; one well out on the bezel touches nothing.
            func press(_ at: CGPoint) {
                let w = display.convert(at, to: nil)
                let down = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: w,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )!
                let up = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: w,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )!
                touches.removeAll()
                display.mouseDown(with: down)
                display.mouseUp(with: up)
            }
            let edge = box()
            for (at, lands) in [
                (CGPoint(x: edge.midX, y: edge.minY - 6), CGPoint(x: 0.5, y: 0)),
                (CGPoint(x: edge.maxX + 6, y: edge.midY), CGPoint(x: 1, y: 0.5))
            ] {
                press(at)
                check(
                    !touches.isEmpty && abs(touches[0].0 - lands.x) < 0.01 && abs(touches[0].1 - lands.y) < 0.01
                        && e.attitude.angle == 0,
                    "a press \(at) just off the edge \(edge) sent \(touches), attitude \(e.attitude)"
                )
            }
            press(CGPoint(x: edge.midX, y: edge.minY - 3 * DisplayView.screenEdgeMargin))
            check(touches.isEmpty, "a press well out on the bezel touched: \(touches)")
            DisplayView.bezel = .off
            try await settle()
            check(
                models().isEmpty && shell.contents == nil && shell.shadowOpacity == 0 && home.isHidden,
                "bezel off again: model or shell left"
            )
            fills(false)
            touchLands(CGPoint(x: 0.5, y: 0.5))
            window.contentView = nil

            // The iPad: its panel is mounted sideways in the shell; bare, the screen still stands upright, centered and fitted.
            frameWidth = Int32(Board.k48.screenPixels.width)
            frameHeight = Int32(Board.k48.screenPixels.height)
            let pad = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: .k48)
            let padEmulator = EmulatorController()
            pad.emulator = padEmulator
            let padWindow = NSWindow(contentRect: pad.frame, styleMask: [.titled], backing: .buffered, defer: false)
            padWindow.contentView = pad
            pad.needsLayout = true
            pad.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let padLCD = all(pad.layer!).first {
                $0.backgroundColor == NSColor.black.cgColor
                    && ($0.contentsGravity == .resize || $0.contentsGravity == .center)
            }!
            let padBox = padLCD.convert(padLCD.bounds, to: pad.layer!)
            let side = 800 - 2 * DisplayView.zoomInset
            check(
                !pad.subviews.contains { $0 is DeviceModelView } && padLCD.superlayer!.contents == nil,
                "iPad bare shows a device"
            )
            check(
                abs(padBox.midX - 400) < 1 && abs(padBox.midY - 400) < 1 && padBox.height > padBox.width
                    && abs(padBox.height - side) < 1,
                "iPad LCD \(padBox)"
            )
            padWindow.contentView = nil
        }

        func rotationBody(_ profile: Board) async throws {
            for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            defer {
                for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            DisplayView.bezel = .flat
            frameWidth = Int32(profile.screenPixels.width)
            frameHeight = Int32(profile.screenPixels.height)
            let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: profile)
            let e = EmulatorController()
            display.emulator = e
            let window = NSWindow(contentRect: display.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = display
            func tick() async throws {
                display.perform(NSSelectorFromString("step"))
                display.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            for _ in 0..<5 { try await tick() }
            func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
            let lcd = all(display.layer!).first {
                $0.backgroundColor == NSColor.black.cgColor
                    && ($0.contentsGravity == .resize || $0.contentsGravity == .center)
            }!
            func box() -> CGRect { lcd.convert(lcd.bounds, to: display.layer!) }
            #expect(box().height > box().width, "\(profile) not portrait at rest: \(box())")
            // The panel scans out as is (s5l8930_display.c, ipod_touch_lcd.c): the frame keeps its size. The app hears
            // of the orientation with nothing new on screen.
            frozen = true
            e.rotationDegrees = 90
            for _ in 0..<4 { try await tick() }
            // Animations off the screen: the model layer is where the layout put it.
            let b = box()
            #expect(b.width > b.height * 1.2, "the rotation didn't show without a new frame: LCD \(b)")
            // Sam 10-07: the guest stays portrait (Settings), so the picture turns with the chassis and keeps its shape.
            // The layer stretches its contents to its bounds (.resize): bounds of another shape stretch the picture.
            let aspect = lcd.bounds.width / lcd.bounds.height
            let frameAspect = CGFloat(frameWidth) / CGFloat(frameHeight)
            #expect(
                abs(aspect - frameAspect) < 0.01,
                "the portrait picture is stretched: layer \(lcd.bounds.size), frame \(frameWidth)x\(frameHeight)"
            )
            // The picture's top edge (its status bar) follows the chassis to the side, not the top of the window.
            let top = lcd.convert(CGPoint(x: lcd.bounds.midX, y: 0), to: display.layer!)
            #expect(
                abs(top.x - b.midX) > b.width * 0.4 && abs(top.y - b.midY) < b.height * 0.1,
                "the picture didn't turn with the chassis: its top edge is at \(top) in \(b)"
            )
            window.contentView = nil
        }

        func freeFormBody() async throws {
            func check(_ ok: Bool, _ what: String, line: Int = #line) { #expect(ok, "line \(line): \(what)") }
            func size(_ w: CGFloat, _ h: CGFloat) -> CGSize { CGSize(width: w, height: h) }

            // The panel= each size records (the sizes the boards take are FreeFormResizeTests').
            let pod = Board.n72
            let pad = Board.k48
            check(
                pad.panelOption(upright: size(768, 1280)) == "1280x768"
                    && pad.uprightPanel("1280x768") == size(768, 1280),
                "iPad panel="
            )
            check(
                pod.panelOption(upright: size(320, 504)) == "320x504" && pod.uprightPanel("320x504") == size(320, 504),
                "iPod panel="
            )
            let boards: [Board] = [.n72, .k48, .n45, .n81, .n90, .n88, .n18, .m68]
            // qemu-ios w05's panel= table: every board but iPhone OS 1's (its SpringBoard keeps 320x480).
            check(
                boards.filter(\.supportsFreeForm) == [pod, pad, .n81, .n90, .n88, .n18]
                    && boards.allSatisfy { ($0.freeFormUnavailableReason == nil) == $0.supportsFreeForm },
                "boards"
            )
            let four = Board.n90
            check(
                four.panelOption(upright: size(640, 1136)) == "640x1136"
                    && four.uprightPanel("640x1136") == size(640, 1136),
                "iPhone 4 panel="
            )
            var requests: [(CGSize?, Bool)] = []
            var statuses: [String] = []  // the readouts and restart notices, as the owner shows them
            var restarts = true

            func make(
                _ profile: Board,
                panel: CGSize?,
                scan: CGSize? = nil,
                key: UUID = UUID(),
                rotation: Int = 0
            ) async throws -> (DisplayView, EmulatorController, NSWindow) {
                let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 1400, height: 1400), profile: profile)
                let e = EmulatorController()
                display.emulator = e
                e.rotationDegrees = rotation
                display.configureFreeForm(scan: scan ?? panel.map { profile.scan(upright: $0) }, key: key)
                display.onFreeFormChange = { [unowned display] in
                    statuses.append(display.panelRestartText ?? display.freeFormReadout ?? "none")
                }
                display.onPanelChange = { upright, restart in
                    requests.append((upright, restart))
                    return restart && restarts
                }
                let window = NSWindow(
                    contentRect: display.frame,
                    styleMask: [.titled, .resizable],
                    backing: .buffered,
                    defer: false
                )
                // The pane sits in a container, as the window's split view holds it beside the sidebar.
                let container = NSView(frame: display.frame)
                display.autoresizingMask = [.width, .height]
                container.addSubview(display)
                window.contentView = container
                display.zoom = .points(1)  // free-form Nx is N points per guest pixel
                try await settle(display)
                return (display, e, window)
            }
            func settle(_ d: DisplayView) async throws {
                d.needsLayout = true
                d.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
            }
            func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
            func lcdLayer(_ d: DisplayView) -> CALayer { d.contentLayer }
            func box(_ d: DisplayView) -> CGRect { d.contentLayer.convert(d.contentLayer.bounds, to: d.layer!) }
            func near(_ a: CGRect, _ w: CGFloat, _ h: CGFloat) -> Bool { abs(a.width - w) < 1 && abs(a.height - h) < 1 }
            func event(
                _ type: NSEvent.EventType,
                _ d: DisplayView,
                _ p: CGPoint,
                clicks: Int = 1,
                option: Bool = false
            ) -> NSEvent {
                NSEvent.mouseEvent(
                    with: type,
                    location: d.convert(p, to: nil),
                    modifierFlags: option ? .option : [],
                    timestamp: 0,
                    windowNumber: d.window!.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: clicks,
                    pressure: 1
                )!
            }
            func key(_ code: UInt16) -> NSEvent {
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    characters: "",
                    charactersIgnoringModifiers: "",
                    isARepeat: false,
                    keyCode: code
                )!
            }
            /// A click at fraction `f` of the LCD as seen is a touch at that point of the panel as it scans: the iPod's
            /// panel scans upright, as seen at rest; a panel standing a quarter turn clockwise (the iPad's landscape one,
            /// an iPod's turned to landscape) at (f.y, 1 - f.x).
            func touchLands(_ d: DisplayView, _ f: CGPoint, quarterTurned: Bool = false) {
                let b = box(d)
                let p = CGPoint(x: b.minX + f.x * b.width, y: b.minY + f.y * b.height)
                let want = quarterTurned ? CGPoint(x: f.y, y: 1 - f.x) : f
                touches.removeAll()
                d.mouseDown(with: event(.leftMouseDown, d, p))
                d.mouseUp(with: event(.leftMouseUp, d, p))
                check(
                    !touches.isEmpty && abs(touches[0].0 - want.x) < 0.01 && abs(touches[0].1 - want.y) < 0.01,
                    "touch at \(f) sent \(touches)"
                )
            }
            /// Grab just outside the LCD at `from` (view points), drag by `by`, release.
            func drag(_ d: DisplayView, from: CGPoint, by: CGVector, release: Bool = true, option: Bool = false) {
                touches.removeAll()
                d.mouseDown(with: event(.leftMouseDown, d, from, option: option))
                let to = CGPoint(x: from.x + by.dx, y: from.y + by.dy)
                d.mouseDragged(with: event(.leftMouseDragged, d, to, option: option))
                d.layoutSubtreeIfNeeded()
                if release { d.mouseUp(with: event(.leftMouseUp, d, to, option: option)) }
                check(touches.isEmpty, "a resize drag touched the guest: \(touches)")
            }

            // iPod at 320x504: the LCD alone, a point per guest pixel, centered; touches land.
            frameWidth = 320
            frameHeight = 504
            var (d, e, w) = try await make(pod, panel: size(320, 504))
            check(d.isFreeForm && near(box(d), 320, 504), "iPod 320x504 at 1x: \(box(d))")
            check(abs(box(d).midX - 700) < 1 && abs(box(d).midY - 700) < 1, "off center: \(box(d))")
            check(!d.subviews.contains { $0 is DeviceModelView }, "free-form shows a device")
            for f in [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.8, y: 0.95)] { touchLands(d, f) }
            d.zoom = .points(2)
            try await settle(d)
            check(near(box(d), 640, 1008), "2x: \(box(d))")
            // ⌘+/⌘− step from the points per guest pixel shown.
            check(abs(d.zoomPoints - 2) < 0.001, "2x reads as \(d.zoomPoints) for zoom stepping")
            d.zoom = .points(1)
            try await settle(d)

            // Only the screen's own edges resize it. A window resize (AppKit's live resize around it) and a sidebar
            // collapse or expand leave the panel, the restart and, at Nx, the LCD's size alone (a pane too small clips it).
            func pane(_ frame: CGRect, live: Bool) async throws {
                if live { d.viewWillStartLiveResize() }
                d.frame = frame
                try await settle(d)
                if live { d.viewDidEndLiveResize() }
                try await Task.sleep(for: .milliseconds(200))
                try await settle(d)
            }
            func untouched(_ what: String, line: Int = #line) {
                check(
                    requests.isEmpty && !d.restartingAtPanel && d.freeFormTarget == nil
                        && d.freeFormPanel == size(320, 504),
                    "\(what) changed the panel: \(requests) \(String(describing: d.freeFormPanel))",
                    line: line
                )
            }
            try await pane(CGRect(x: 0, y: 0, width: 900, height: 700), live: true)
            check(near(box(d), 320, 504), "window resize moved the LCD: \(box(d))")
            untouched("a window resize")
            try await pane(CGRect(x: 300, y: 0, width: 300, height: 1400), live: false)  // the sidebar shown
            check(near(box(d), 320, 504), "sidebar shown: \(box(d))")
            untouched("a sidebar expand")
            try await pane(CGRect(x: 0, y: 0, width: 1400, height: 1400), live: false)  // and collapsed
            check(near(box(d), 320, 504), "sidebar collapsed: \(box(d))")
            untouched("a sidebar collapse")
            // Fit scales the panel into the pane as it does the shipped screen; still no new panel.
            d.zoom = .fit
            try await pane(CGRect(x: 0, y: 0, width: 600, height: 600), live: true)
            check(
                abs(box(d).height - (600 - 2 * DisplayView.zoomInset)) < 1
                    && abs(box(d).width / box(d).height - 320.0 / 504) < 0.01,
                "fit: \(box(d))"
            )
            untouched("a window resize at Fit")
            d.zoom = .points(1)
            try await pane(CGRect(x: 0, y: 0, width: 1400, height: 1400), live: true)
            untouched("a window resize back")

            // Drag the right edge 40 points: 40 more columns, the left edge where it was, the readout following.
            var b = box(d)
            drag(d, from: CGPoint(x: b.maxX + 4, y: b.midY), by: CGVector(dx: 40, dy: 0), release: false)
            check(d.freeFormReadout == "360 × 504", "readout \(d.freeFormReadout ?? "none")")
            check(near(box(d), 360, 504) && abs(box(d).minX - b.minX) < 0.5, "one-sided: \(box(d)) from \(b)")
            check(lcdLayer(d).contentsGravity == .center, "the old frame is stretched during the drag")
            // On down past 511 rows from the corner: the bottom edge stops, the readout says why; the top stays.
            d.mouseUp(with: event(.leftMouseUp, d, CGPoint(x: b.maxX + 44, y: b.midY)))
            b = box(d)
            drag(d, from: CGPoint(x: b.maxX + 4, y: b.maxY + 4), by: CGVector(dx: 10.3, dy: 400))
            check(
                d.freeFormReadout?.hasPrefix("370 × 511 — ") == true && d.freeFormLimit?.contains("511") == true,
                "clamped readout \(d.freeFormReadout ?? "none")"
            )
            check(
                near(box(d), 370, 511) && abs(box(d).minY - b.minY) < 0.5 && abs(box(d).minX - b.minX) < 0.5,
                "clamped LCD \(box(d)) from \(b)"
            )
            // Released, nothing restarts until Apply.
            try await Task.sleep(for: .milliseconds(100))
            check(requests.isEmpty && d.hasPendingPanel, "a release asked \(requests)")
            // Escape reverts; the screen is back where and what it was.
            check(d.panelKey(key(53)), "Escape wasn't the resize's")
            try await settle(d)
            check(!d.hasPendingPanel && near(box(d), 320, 504) && abs(box(d).midX - 700) < 1, "revert: \(box(d))")
            check(lcdLayer(d).contentsGravity == .resize, "reverted, the frame isn't stretched to the screen again")
            // ⌥ moves both edges: the center stays.
            b = box(d)
            drag(d, from: CGPoint(x: b.maxX + 4, y: b.midY), by: CGVector(dx: 20, dy: 0), option: true)
            check(near(box(d), 360, 504) && abs(box(d).midX - b.midX) < 0.5, "⌥: \(box(d)) from \(b)")
            // Return applies: the record and a restart at it, the last frame up unscaled meanwhile.
            check(d.panelKey(key(36)), "Return wasn't the resize's")
            check(requests.count == 1 && requests[0].0 == size(360, 504) && requests[0].1, "Apply asked \(requests)")
            check(
                d.restartingAtPanel && d.panelRestartText == "Restarting at 360 × 504…" && near(box(d), 360, 504),
                "restart: \(d.panelRestartText ?? "none") \(box(d))"
            )
            check(statuses.last == "Restarting at 360 × 504…" && statuses.contains("360 × 504"), "notices \(statuses)")
            b = box(d)
            d.mouseDown(with: event(.leftMouseDown, d, CGPoint(x: b.maxX + 4, y: b.midY)))
            check(d.panelDrag == nil && d.panelRestartText == "Restarting at 360 × 504…", "a drag during the restart")
            w.contentView = nil
            // State audit C-4: the next session's view titles its startup "Restarting at…" until its first frame, no
            // longer (a later Restart or Start showed the stale size).
            let restartKey = try #require(d.deviceKey)
            var (handedOff, handedOffDevice, nextWindow) = try await make(pod, panel: size(360, 504), key: restartKey)
            check(
                handedOff.restartTitle == "Restarting at 360 × 504…" && handedOff.showsHandoff,
                "hand-off \(handedOff.restartTitle ?? "none")"
            )
            frozen = false  // the new boot paints
            _ = handedOff.currentFrame()
            frozen = true
            _ = handedOffDevice
            check(
                handedOff.restartTitle == nil && !handedOff.showsHandoff,
                "after the first frame: \(handedOff.restartTitle ?? "none")"
            )
            nextWindow.contentView = nil
            // A restart the owner refused ends the view's: the size waits again, and its last frame is no one's.
            (d, e, w) = try await make(pod, panel: size(320, 504))
            d.freeFormTarget = size(360, 504)
            d.applyPanel()
            check(d.restartingAtPanel, "restarting")
            d.panelRestartRefused()
            check(!d.restartingAtPanel && d.panelRestartText == nil && d.hasPendingPanel, "refused: still waiting")
            let refusedKey = try #require(d.deviceKey)
            (handedOff, handedOffDevice, nextWindow) = try await make(pod, panel: size(320, 504), key: refusedKey)
            check(handedOff.restartTitle == nil && !handedOff.showsHandoff, "a refused restart hands nothing off")
            nextWindow.contentView = nil
            w.contentView = nil

            // The zoom holds through a drag and after it: Fit becomes the points it showed, no jump on release.
            requests.removeAll()
            restarts = false
            (d, e, w) = try await make(pod, panel: size(320, 504))
            d.zoom = .fit
            try await settle(d)
            let fitPoints = d.zoomPoints
            b = box(d)
            drag(d, from: CGPoint(x: b.midX, y: b.minY - 4), by: CGVector(dx: 0, dy: -3 * fitPoints))
            try await settle(d)
            let rows: CGFloat = 507
            check(
                d.zoom == .points(fitPoints) && abs(box(d).height - rows * fitPoints) < 1
                    && abs(box(d).maxY - b.maxY) < 0.5,
                "held: \(d.zoom) \(box(d)) from \(b), \(rows) rows"
            )
            // Wider than tall is allowed; with the device stopped Apply simply takes it, shown as it was dragged.
            b = box(d)
            drag(d, from: CGPoint(x: b.maxX + 4, y: b.midY), by: CGVector(dx: 300 * fitPoints, dy: 0))
            let wide = size(620, rows)
            check(d.freeFormTarget == wide, "wide: \(String(describing: d.freeFormTarget))")
            d.applyPanel()
            try await settle(d)
            check(
                requests.count == 1 && requests[0].0 == wide && d.freeFormPanel == wide && !d.hasPendingPanel
                    && near(box(d), 620 * fitPoints, rows * fitPoints),
                "wide taken: \(requests) \(box(d))"
            )
            // View ▸ Native Size and a double-click on a handle: the shipped size, waiting for Apply.
            d.showNativeSize()
            check(d.freeFormTarget == size(320, 480) && d.hasPendingPanel, "Native Size")
            d.revertPanel()
            b = box(d)
            d.mouseDown(with: event(.leftMouseDown, d, CGPoint(x: b.minX - 4, y: b.minY - 4), clicks: 2))
            d.mouseUp(with: event(.leftMouseUp, d, CGPoint(x: b.minX - 4, y: b.minY - 4), clicks: 2))
            check(d.freeFormTarget == size(320, 480) && touches.isEmpty, "double-click: \(touches)")
            w.contentView = nil

            // Landscape: the screen's sides swap, so its on-screen width is the panel's rows; the scan stays as it is.
            requests.removeAll()
            (d, e, w) = try await make(pod, panel: size(320, 504))
            e.rotationDegrees = 90
            (frameWidth, frameHeight) = (320, 504)
            d.perform(NSSelectorFromString("step"))
            try await settle(d)
            check(near(box(d), 504, 320), "landscape \(box(d))")
            touchLands(d, CGPoint(x: 0.25, y: 0.75), quarterTurned: true)
            b = box(d)
            drag(d, from: CGPoint(x: b.minX - 4, y: b.midY), by: CGVector(dx: -3, dy: 0))
            check(d.freeFormReadout == "507 × 320", "landscape readout \(d.freeFormReadout ?? "none")")
            d.applyPanel()
            // No restart (a stopped device): the size is simply taken.
            check(requests.count == 1 && requests[0].0 == size(320, 507), "landscape asked \(requests)")
            check(!d.restartingAtPanel && !d.hasPendingPanel && d.isFreeForm, "taken without a restart")
            try await settle(d)
            check(near(box(d), 507, 320), "landscape after \(box(d))")
            e.rotationDegrees = 0
            frameWidth = 320
            frameHeight = 507
            // Off at a non-native size: back to the shipped panel by a restart.
            requests.removeAll()
            restarts = true
            d.setFreeForm(false)
            check(
                requests.count == 1 && requests[0].0 == nil && requests[0].1
                    && d.panelRestartText == "Restarting at 320 × 480…",
                "off asked \(requests) \(d.panelRestartText ?? "none")"
            )
            w.contentView = nil

            // iPad at 1280x768: portrait 768x1280, touches land; its height (the scan's width) snaps to 16s.
            requests.removeAll()
            restarts = false
            frameWidth = 1280
            frameHeight = 768
            (d, e, w) = try await make(pad, panel: size(768, 1280))
            check(near(box(d), 768, 1280), "iPad 768x1280 \(box(d))")
            for f in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.6)] { touchLands(d, f, quarterTurned: true) }
            b = box(d)
            drag(d, from: CGPoint(x: b.midX, y: b.minY - 4), by: CGVector(dx: 0, dy: 20), release: false)
            check(d.freeFormReadout == "768 × 1264", "iPad shrink \(d.freeFormReadout ?? "none")")
            d.mouseDragged(with: event(.leftMouseDragged, d, CGPoint(x: b.midX, y: b.minY - 4 + 30)))
            check(d.freeFormReadout == "768 × 1248", "iPad snap \(d.freeFormReadout ?? "none")")
            d.mouseUp(with: event(.leftMouseUp, d, CGPoint(x: b.midX, y: b.minY + 26)))
            d.applyPanel()
            check(
                requests.count == 1 && requests[0].0 == size(768, 1248)
                    && pad.panelOption(upright: size(768, 1248)) == "1248x768",
                "iPad asked \(requests)"
            )
            w.contentView = nil

            // Free-form on from the shipped device: no restart, the same size; never free-form: no grab band.
            requests.removeAll()
            frameWidth = 320
            frameHeight = 480
            (d, e, w) = try await make(pod, panel: nil)
            b = box(d)
            d.mouseDown(with: event(.leftMouseDown, d, CGPoint(x: b.maxX + 4, y: b.midY)))
            d.mouseUp(with: event(.leftMouseUp, d, CGPoint(x: b.maxX + 4, y: b.midY)))
            // No grab band: the press just off the edge is an edge touch (DisplayView.screenEdgeMargin), not a resize.
            check(
                !d.isFreeForm && d.freeFormReadout == nil && touches.first.map { abs($0.0 - 1) < 0.01 } == true,
                "a shipped device grabbed: \(touches)"
            )
            d.setFreeForm(true)
            try await settle(d)
            check(
                d.isFreeForm && requests.count == 1 && requests[0].0 == size(320, 480) && !requests[0].1
                    && near(box(d), 320, 480),
                "on: \(requests) \(box(d))"
            )
            check(!d.canShowNativeSize, "Native Size offered at the native size")
            w.contentView = nil

            // Zoom only draws the screen bigger or smaller. At 1x, 2x and Fit, portrait and landscape, a 320x448 iPod's
            // LCD is the panel at a guest pixel per N points (Fit: the largest that fits the pane, aspect kept), zooming
            // changes neither the panel nor asks for a restart, and an edge drag converts the pointer through the zoom.
            requests.removeAll()
            restarts = false
            for rotation in [0, 90] {
                let sideways = rotation == 90
                let upright = size(320, 448)
                let seen = sideways ? size(448, 320) : upright
                for zoom in [ZoomMode.points(1), .points(2), .fit] {
                    (frameWidth, frameHeight) = (320, 448)  // the panel scans out as is, whatever way it is held
                    (d, e, w) = try await make(pod, panel: upright, rotation: rotation)
                    for z in [ZoomMode.points(2), .fit, .points(1), zoom] {
                        d.zoom = z
                        try await settle(d)
                    }
                    let fit = min(
                        (1400 - 2 * DisplayView.zoomInset) / seen.width,
                        (1400 - 2 * DisplayView.zoomInset) / seen.height
                    )
                    let k: CGFloat = if case .points(let p) = zoom { p } else { fit }
                    let what = "\(zoom) at \(rotation)°"
                    check(
                        near(box(d), seen.width * k, seen.height * k) && abs(box(d).midX - 700) < 1
                            && abs(box(d).midY - 700) < 1,
                        "\(what): LCD \(box(d)), want \(seen) x \(k)"
                    )
                    check(
                        requests.isEmpty && d.freeFormPanel == upright && d.freeFormTarget == nil,
                        "\(what): zooming changed the panel \(requests)"
                    )
                    // The right edge 12 points out: the seen width grows by 12 / k guest pixels.
                    let b = box(d)
                    drag(d, from: CGPoint(x: b.maxX + 4, y: b.midY), by: CGVector(dx: 12, dy: 0), release: false)
                    let grown = CGSize(width: seen.width + 12 / k, height: seen.height)
                    let want = FreeFormResize(board: pod).snap(
                        upright: sideways ? size(grown.height, grown.width) : grown
                    )
                    .size
                    let wantSeen = sideways ? size(want.height, want.width) : want
                    check(
                        d.freeFormReadout == "\(Int(wantSeen.width)) × \(Int(wantSeen.height))"
                            && near(box(d), wantSeen.width * k, wantSeen.height * k),
                        "\(what): drag gave \(d.freeFormReadout ?? "none") \(box(d)), want \(wantSeen)"
                    )
                    w.contentView = nil
                }
            }

            // A free-form scan is mounted as the board's shipped panel is (Board.freeFormTurn): the iPod's as it scans,
            // the iPad's a quarter turn, a square one neither; so a screen dragged wider than tall stays so. Square,
            // wider and taller scans on both boards, in all four rotations: the LCD and a capture are the upright screen
            // turned with the device, and a click at a point of it touches the point of the scan shown there.
            func rotCCW(_ p: CGPoint, _ quarters: Int) -> CGPoint {
                var q = p
                for _ in 0..<((quarters % 4 + 4) % 4) { q = CGPoint(x: q.y, y: 1 - q.x) }
                return q
            }
            for (profile, scans) in [
                (pod, [size(400, 400), size(320, 504), size(504, 320)]),
                (pad, [size(1024, 1024), size(1104, 1024), size(1024, 1104)])
            ] {
                for scan in scans {
                    let turned = profile.freeFormTurn(scan: scan) != 0
                    let upright = profile.uprightPanel(scan: scan)
                    for rotation in [0, 90, 180, 270] {
                        let quarters = rotation / 90
                        let sideways = quarters % 2 == 1
                        // What the guest publishes: the scan, whatever way the device is held.
                        frameWidth = Int32(scan.width)
                        frameHeight = Int32(scan.height)
                        (d, e, w) = try await make(profile, panel: nil, scan: scan, rotation: rotation)
                        let seen = sideways ? size(upright.height, upright.width) : upright
                        let what = "\(profile) scan \(Int(scan.width))x\(Int(scan.height)) at \(rotation)°"
                        check(near(box(d), seen.width, seen.height), "\(what): LCD \(box(d)), want \(seen)")
                        let shot = d.captureFrame(includeTouches: false)!
                        check(
                            shot.width == Int(seen.width) && shot.height == Int(seen.height),
                            "\(what): capture \(shot.width)x\(shot.height)"
                        )
                        for f in [CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.85, y: 0.6)] {
                            let b = box(d)
                            let at = CGPoint(x: b.minX + f.x * b.width, y: b.minY + f.y * b.height)
                            let u = rotCCW(f, quarters)
                            let g = turned ? rotCCW(u, 1) : u
                            let want = g
                            touches.removeAll()
                            d.mouseDown(with: event(.leftMouseDown, d, at))
                            d.mouseUp(with: event(.leftMouseUp, d, at))
                            check(
                                !touches.isEmpty && abs(touches[0].0 - want.x) < 0.01
                                    && abs(touches[0].1 - want.y) < 0.01,
                                "\(what): click at \(f) sent \(touches), want \(want)"
                            )
                        }
                        w.contentView = nil
                    }
                }
            }

            // Back at the shipped panel the bezel follows View ▸ Device Bezels again, live: Free-Form on, a resize,
            // Free-Form off (a restart), then the next session's view (shown, swapped out and back as the window does)
            // takes the toggle both ways. A free-form screen ignores it.
            UserDefaults.standard.removeObject(forKey: DisplayView.bezelKey)
            defer { UserDefaults.standard.removeObject(forKey: DisplayView.bezelKey) }
            DisplayView.bezel = .off
            requests.removeAll()
            restarts = true
            frameWidth = 1104
            frameHeight = 768
            let key = UUID()
            (d, e, w) = try await make(pad, panel: size(768, 1104), key: key)  // booted at the size a drag gave it
            d.setFreeForm(false)
            check(requests.last.map { $0.0 == nil && $0.1 } == true, "off at 768x1104 asked \(requests)")
            func shellShown(_ v: DisplayView) -> Bool {
                let lcd = all(v.layer!).first {
                    $0.backgroundColor == NSColor.black.cgColor
                        && ($0.contentsGravity == .resize || $0.contentsGravity == .center)
                }!
                return lcd.superlayer!.contents != nil && lcd.superlayer!.shadowOpacity > 0
            }
            DisplayView.bezel = .flat
            try await settle(d)
            check(!shellShown(d), "a free-form screen took the bezel")
            w.contentView = nil
            frameWidth = 1024
            frameHeight = 768
            let (next, _, nw) = try await make(pad, panel: nil, key: key)
            let holder = nw.contentView!
            nw.contentView = nil
            try await Task.sleep(for: .milliseconds(50))
            nw.contentView = holder  // the session swap
            try await settle(next)
            DisplayView.bezel = .off
            try await settle(next)
            check(!next.isFreeForm && !shellShown(next), "bezel off: the shipped iPad still shows it")
            DisplayView.bezel = .flat
            try await settle(next)
            check(shellShown(next), "bezel on: the shipped iPad stayed bare")
            DisplayView.bezel = .off
            try await settle(next)
            check(!shellShown(next), "bezel off again: the shipped iPad kept it")
            nw.contentView = nil
        }
    }
}
