import AppKit
import DeviceRuntime
import HostRuntime
import Testing

@testable import Display
@testable import LightTouchCore

/// What reached the link as touches: "1:<phase>@<x>,<y>" for the first finger, "2:…" for the second, in percent.
@MainActor func touchLog() -> [String] {
    func r(_ v: Double) -> Int { Int((v * 100).rounded()) }
    return sent.compactMap {
        switch $0 {
        case .touch(_, let phase, let x, let y): "1:\(phase)@\(r(x)),\(r(y))"
        case .touch2(let phase, let x, let y): "2:\(phase)@\(r(x)),\(r(y))"
        default: nil
        }
    }
}
/// The first finger's phases.
@MainActor func touchPhases() -> [Int] {
    sent.compactMap { if case .touch(_, let phase, _, _) = $0 { phase } else { nil } }
}

final class Cursor: NSWindow {
    var at = NSPoint.zero
    override var mouseLocationOutsideOfEventStream: NSPoint { at }
}

func key(_ code: UInt16, _ chars: String, _ down: Bool = true, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(
        with: down ? .keyDown : .keyUp,
        location: .zero,
        modifierFlags: flags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: chars,
        charactersIgnoringModifiers: chars,
        isARepeat: false,
        keyCode: code
    )!
}
func flags(_ code: UInt16, _ f: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
        with: .flagsChanged,
        location: .zero,
        modifierFlags: f,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: code
    )!
}

/// A trackpad/wheel event with the fields AppKit fills in.
final class Gesture: NSEvent {
    var eventPhase: NSEvent.Phase = .changed, momentum: NSEvent.Phase = []
    var dx = 0.0, dy = 0.0, degrees: Float = 0, at = NSPoint.zero
    var precise = true, inverted = false, option = false
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var isDirectionInvertedFromDevice: Bool { inverted }
    override var modifierFlags: NSEvent.ModifierFlags { option ? .option : [] }
    override var rotation: Float { degrees }
    override var locationInWindow: NSPoint { at }
}

@MainActor final class Drag: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any?
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation = NSDraggingFormation.default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight = NSSpringLoadingHighlight.none
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override nonisolated func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func files(_ names: [String]) {
        draggingPasteboard.clearContents()
        _ = (draggingPasteboard.writeObjects(names.map { URL(fileURLWithPath: "/tmp/" + $0) as NSURL }))
    }
}

extension SharedState {
    /// DisplayView's input, as synthetic events into its handlers (no window ordered in).
    @Suite struct DisplayInputTests {
        init() {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            _ = fixtureMachines
            sent = []
            touches = []
        }

        /// Typing: US-layout keys go through as key codes, anything else (another layout, an input method) as text,
        /// composition is held back until committed, and every key the guest has down goes up when focus leaves.
        /// GuestKeyboard's table and rule, and HeldKeys, are GuestKeyboardTests'.
        @Test func typing() {
            let v = DisplayView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), profile: .n72)
            let e = EmulatorController()
            v.emulator = e
            let window = NSWindow(contentRect: v.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = v
            #expect(window.makeFirstResponder(v))
            // US layout: the key itself, down and up.
            v.keyDown(with: key(0, "a"))
            v.keyUp(with: key(0, "a", false))
            #expect(e.log == ["0v", "0^"], "\(e.log)")
            // A key is the user at the device (ClipboardSharing takes its next copy for theirs).
            #expect(e.interactions == 1)
            e.log = []
            // Another layout: AZERTY's q (US a key) becomes text, and its key-up sends nothing.
            v.keyDown(with: key(0, "q"))
            v.keyUp(with: key(0, "q", false))
            #expect(e.log == ["type:q"], "\(e.log)")
            e.log = []
            // Shift held through a layout's capital: the text says Shift is down already.
            v.flagsChanged(with: flags(56, .shift))
            v.keyDown(with: key(0, "Q", true, .shift))
            #expect(e.log == ["56v", "type:Q+shift"], "\(e.log)")
            e.log = []
            // Focus leaves with Shift and a key down: both go up, once.
            v.keyDown(with: key(1, "S", true, .shift))
            _ = v.resignFirstResponder()
            #expect(Set(e.log) == ["1v", "56^", "1^"] && e.log.count == 3, "\(e.log)")
            e.log = []
            v.releaseHeldKeys()
            v.keyUp(with: key(1, "s", false))
            #expect(e.log.isEmpty, "nothing left to release: \(e.log)")
            // Composition: marked text is held back until committed, and focus loss drops it.
            v.setMarkedText(
                "´",
                selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            #expect(v.hasMarkedText())
            v.keyDown(with: key(0, "a"))
            #expect(!e.log.contains("0v"), "a key during composition goes to the input system: \(e.log)")
            v.insertText("á", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(e.log.last == "type:á" && !v.hasMarkedText(), "\(e.log)")
        }

        /// Simulator-style two fingers from a mouse (issue #18), bezel off so the LCD alone takes the clicks: Option drags a
        /// second finger mirrored through the panel center, Option-Shift locks the spacing and pans both; a plain drag is
        /// one finger; the hover rings follow. The pair's rules are MouseTouchPairTests'.
        @Test func mouseMultitouch() async throws {
            for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            defer {
                for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            DisplayView.bezel = .off
            let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: .n72)
            let emulator = EmulatorController()
            display.emulator = emulator  // weak: held here
            defer { withExtendedLifetime(emulator) {} }
            let window = Cursor(contentRect: display.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = display
            display.needsLayout = true
            display.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(1300))
            display.needsLayout = true
            display.layoutSubtreeIfNeeded()
            func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
            let lcd = all(display.layer!).first {
                $0.backgroundColor == NSColor.black.cgColor && $0.contentsGravity == .resize
            }!
            let box = lcd.convert(lcd.bounds, to: display.layer!)
            let pairRings = all(display.layer!).compactMap { $0 as? CAShapeLayer }.filter {
                $0.bounds.size == CGSize(width: 30, height: 30)
            }
            #expect(pairRings.count == 2, "pair rings: \(pairRings.count)")
            // Points are percent of the panel.
            func ev(_ t: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, _ f: NSEvent.ModifierFlags) -> NSEvent {
                let at = display.convert(
                    CGPoint(x: box.minX + x / 100 * box.width, y: box.minY + y / 100 * box.height),
                    to: nil
                )
                window.at = at
                return NSEvent.mouseEvent(
                    with: t,
                    location: at,
                    modifierFlags: f,
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )!
            }
            func drag(_ f: NSEvent.ModifierFlags, _ path: [(CGFloat, CGFloat)]) -> [String] {
                sent = []
                display.mouseDown(with: ev(.leftMouseDown, path[0].0, path[0].1, f))
                for p in path.dropFirst() { display.mouseDragged(with: ev(.leftMouseDragged, p.0, p.1, f)) }
                display.mouseUp(with: ev(.leftMouseUp, path.last!.0, path.last!.1, f))
                return touchLog()
            }
            func hover(_ x: CGFloat, _ y: CGFloat, _ f: NSEvent.ModifierFlags) {
                display.mouseMoved(with: ev(.mouseMoved, x, y, f))
            }
            var rings: [String] {
                pairRings.map {
                    $0.isHidden
                        ? "-"
                        : "\(Int(((($0.position.x - box.minX) / box.width) * 100).rounded())),\(Int(((($0.position.y - box.minY) / box.height) * 100).rounded()))"
                }
            }
            func expect(_ got: [String], _ want: [String], _ what: String) { #expect(got == want, "\(what)") }
            expect(
                drag([], [(30, 40), (20, 30)]),
                ["1:0@30,40", "1:1@20,30", "1:2@20,30"],
                "plain drag is one finger"
            )
            // Pressing and lifting are the user at the device.
            #expect(emulator.interactions == 2)
            expect(
                drag(.option, [(30, 40), (20, 30)]),
                ["1:0@30,40", "2:0@70,60", "1:1@20,30", "2:1@80,70", "1:2@20,30", "2:2@80,70"],
                "Option mirrors through the center"
            )
            hover(30, 50, .option)
            expect(rings, ["30,50", "70,50"], "Option hover shows the mirrored pair")
            hover(30, 50, [.option, .shift])
            hover(20, 50, [.option, .shift])
            expect(rings, ["20,50", "60,50"], "Option-Shift hover keeps the spacing locked when Shift went down")
            expect(
                drag([.option, .shift], [(20, 50), (20, 30), (25, 10)]),
                [
                    "1:0@20,50", "2:0@60,50", "1:1@20,30", "2:1@60,30", "1:1@25,10", "2:1@65,10", "1:2@25,10",
                    "2:2@65,10"
                ],
                "Option-Shift drags both fingers in parallel"
            )
            expect(rings, ["25,10", "65,10"], "rings return to the hover pair after the drag")
            sent = []
            display.mouseDown(with: ev(.leftMouseDown, 20, 50, [.option, .shift]))
            display.mouseDragged(with: ev(.leftMouseDragged, 20, 40, []))
            expect(rings, ["20,40", "60,40"], "rings track the contacts mid-drag")
            display.mouseUp(with: ev(.leftMouseUp, 20, 40, []))
            expect(
                touchLog(),
                ["1:0@20,50", "2:0@60,50", "1:1@20,40", "2:1@60,40", "1:2@20,40", "2:2@60,40"],
                "releasing keys mid-drag keeps the pan"
            )
            expect(rings, ["-", "-"], "no rings without Option")
            hover(80, 50, .option)
            hover(80, 50, [.option, .shift])
            expect(
                drag([.option, .shift], [(80, 50), (70, 50)]),
                ["1:0@80,50", "2:0@20,50", "1:1@70,50", "2:1@10,50", "1:2@70,50", "2:2@10,50"],
                "releasing Option drops the old lock; the next Option-Shift locks afresh"
            )
        }

        /// Chassis tilt on the 2D bezel: grab-and-drag rolls and pitches in every orientation and leaves guest touches
        /// alone; wheel lines and precise points tilt alike, Natural Scrolling isn't undone, momentum never starts a tilt,
        /// a wheel burst returns to rest by itself; a twist tilts off the panel or with Option; layouts during repeated
        /// tilt leave screen and shell upright after release. The gesture math is ChassisTiltTests'.
        @Test func chassisDrag() async throws {
            for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            defer {
                for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            DisplayView.bezel = .flat
            let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: .n72)
            let emulator = EmulatorController()
            display.emulator = emulator  // weak: held here
            defer { withExtendedLifetime(emulator) {} }
            let window = Cursor(contentRect: display.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = display
            func layout() {
                display.needsLayout = true
                display.layoutSubtreeIfNeeded()
            }
            layout()
            func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
            let lcd = all(display.layer!).first {
                $0.backgroundColor == NSColor.black.cgColor && $0.contentsGravity == .resize
            }!
            let shell = lcd.superlayer!
            let home = display.subviews.first { String(describing: type(of: $0)) == "HomeButton" }!
            func close(_ a: CGFloat, _ b: CGFloat, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
                #expect(abs(a - b) < 1e-9, "\(what): \(a) vs \(b)", sourceLocation: sourceLocation)
            }
            func untouched() -> Bool { emulator.attitude == (7, 7) }
            /// The shell's roll from its transform: scale·Rx(pitch)·Rz(angle)·perspective leaves Rz in the first row.
            func shellAngle() -> CGFloat { atan2(shell.transform.m12, shell.transform.m11) }
            func shellTurned(_ angle: CGFloat, _ what: String) {
                close(remainder(shellAngle() - angle, 2 * .pi), 0, what)
            }
            func rest(_ rotation: Int) -> CGFloat { rotation == 270 ? -.pi / 2 : CGFloat(rotation) * .pi / 180 }
            func mouse(_ t: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                let at = display.convert(p, to: nil)
                window.at = at
                return NSEvent.mouseEvent(
                    with: t,
                    location: at,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )!
            }
            /// Above the screen on the flat shell, in view points (wherever the shell is turned).
            func chassis() -> CGPoint {
                shell.convert(CGPoint(x: shell.bounds.midX, y: lcd.frame.minY / 2), to: display.layer!)
            }
            func panel() -> CGPoint { lcd.convert(CGPoint(x: lcd.bounds.midX, y: lcd.bounds.midY), to: display.layer!) }

            // Drag: linear roll right and pitch up from the grab point (the view is flipped), clamped, in every orientation.
            for rotation in [0, 90, 180, 270] {
                emulator.rotationDegrees = rotation
                layout()
                shellTurned(rest(rotation), "rest \(rotation)")
                let grab = chassis()
                display.mouseDown(with: mouse(.leftMouseDown, grab))
                display.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: grab.x + 25, y: grab.y + 50)))
                close(emulator.attitude.angle, rest(rotation) + 0.1, "roll \(rotation)")
                close(emulator.attitude.pitch, -0.2, "pitch \(rotation)")
                shellTurned(rest(rotation) + 0.1, "the shell turns with the roll at \(rotation)")
                display.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: grab.x - 25, y: grab.y - 50)))
                close(emulator.attitude.angle, rest(rotation) - 0.1, "back \(rotation)")
                close(emulator.attitude.pitch, 0.2, "up \(rotation)")
                display.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: grab.x + 10000, y: grab.y - 10000)))
                close(emulator.attitude.angle, rest(rotation) + .pi / 4, "clamp \(rotation)")
                close(emulator.attitude.pitch, .pi / 4, "clamp \(rotation)")
                display.mouseUp(with: mouse(.leftMouseUp, grab))
                close(emulator.attitude.angle, rest(rotation), "release \(rotation)")
                close(emulator.attitude.pitch, 0, "release \(rotation)")
                shellTurned(rest(rotation), "the shell springs back at \(rotation)")
            }
            emulator.rotationDegrees = 0
            layout()
            #expect(touchPhases().isEmpty, "a chassis drag is no touch: \(sent)")
            // A press on the LCD is a touch: its drag updates the guest and leaves gravity alone.
            emulator.attitude = (7, 7)
            let p = panel()
            display.mouseDown(with: mouse(.leftMouseDown, p))
            display.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: p.x + 30, y: p.y + 30)))
            display.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: p.x + 30, y: p.y + 30)))
            #expect(touchPhases() == [0, 1, 2] && untouched(), "\(sent)")
            sent = []

            // Scroll off the panel: line wheels (x10) and precise points tilt the same; the phase's end returns to rest.
            let event = Gesture()
            event.at = display.convert(CGPoint(x: 5, y: 5), to: nil)
            for precise in [false, true] {
                event.precise = precise
                event.dx = precise ? 10 : 1
                event.dy = precise ? -20 : -2
                event.eventPhase = .began
                display.scrollWheel(with: event)
                close(emulator.attitude.angle, 0.015, "scroll roll precise=\(precise)")
                close(emulator.attitude.pitch, -0.03, "scroll pitch precise=\(precise)")
                event.eventPhase = .ended
                display.scrollWheel(with: event)
                close(emulator.attitude.angle, 0, "scroll end")
                close(emulator.attitude.pitch, 0, "scroll end")
            }
            // The same swipe arrives with opposite deltas under the other Natural Scrolling setting: AppKit has already
            // applied it, so the deltas are taken as they come.
            for inverted in [false, true] {
                event.precise = true
                event.inverted = inverted
                event.dx = inverted ? -10 : 10
                event.dy = 0
                event.eventPhase = .began
                display.scrollWheel(with: event)
                close(emulator.attitude.angle, inverted ? -0.015 : 0.015, "inverted=\(inverted)")
                event.eventPhase = .ended
                display.scrollWheel(with: event)
            }
            event.inverted = false
            // Momentum alone belongs to content scrolling: no tilt, no touch.
            emulator.attitude = (7, 7)
            event.momentum = .changed
            event.eventPhase = []
            display.scrollWheel(with: event)
            #expect(untouched() && touchPhases().isEmpty, "momentum started a gesture")
            // Nor does momentum move a tilt the fingers are holding.
            event.momentum = []
            event.dx = 10
            event.eventPhase = .began
            display.scrollWheel(with: event)
            event.momentum = .changed
            event.eventPhase = []
            display.scrollWheel(with: event)
            close(emulator.attitude.angle, 0.015, "momentum moved the tilt")
            event.momentum = []
            event.eventPhase = .ended
            display.scrollWheel(with: event)
            close(emulator.attitude.angle, 0, "momentum scroll end")
            // A conventional wheel has no phases: a burst tilts, then returns to rest by itself.
            event.momentum = []
            event.eventPhase = []
            event.precise = false
            event.dx = 1
            event.dy = 0
            display.scrollWheel(with: event)
            close(emulator.attitude.angle, 0.015, "wheel burst")
            try await Task.sleep(for: .milliseconds(250))
            close(emulator.attitude.angle, 0, "a conventional wheel must return to rest after its burst")
            // Scroll over the panel is the guest's, unless Option is held.
            event.at = display.convert(panel(), to: nil)
            event.precise = true
            event.dx = 10
            emulator.attitude = (7, 7)
            event.eventPhase = .began
            display.scrollWheel(with: event)
            #expect(untouched(), "scroll over the panel tilted")
            // A finger (ScrollDrag): down where the cursor is and moved by the began event's own delta, then by each
            // changed, up at the fingers' ended; the momentum phase after it moves nothing. A pinch the trackpad sees in
            // the same fingers doesn't start while the finger is down.
            display.magnify(with: event)
            #expect(touchPhases() == [0, 1], "a pinch began mid-swipe: \(sent)")
            event.eventPhase = .changed
            display.scrollWheel(with: event)
            event.eventPhase = .ended
            display.scrollWheel(with: event)
            event.eventPhase = []
            for phase in [NSEvent.Phase.began, .changed, .ended] {
                event.momentum = phase
                display.scrollWheel(with: event)
            }
            event.momentum = []
            #expect(touchPhases() == [0, 1, 1, 2], "\(sent)")
            // The finger keeps up with the content under the fingers: 10 points of scroll move it 10 points of the
            // screen as shown (the iPod's cutout is 594 shell pixels for a 320-pixel frame).
            let shown = lcd.convert(lcd.bounds, to: display.layer!).width
            let xs = sent.compactMap { if case .touch(_, _, let x, _) = $0 { x } else { nil } }
            #expect(abs((xs[1] - xs[0]) * shown - 10) < 0.01, "moved \((xs[1] - xs[0]) * shown) of \(shown) points")
            sent = []
            event.option = true
            event.eventPhase = .began
            display.scrollWheel(with: event)
            close(emulator.attitude.angle, 0.015, "Option-scroll over the panel tilts")
            event.eventPhase = .ended
            display.scrollWheel(with: event)
            event.option = false
            #expect(touchPhases().isEmpty, "\(sent)")

            // Twist: counterclockwise degrees roll clockwise; off the panel or with Option, else the guest's.
            event.at = display.convert(CGPoint(x: 5, y: 5), to: nil)
            event.eventPhase = .began
            event.degrees = 30
            display.rotate(with: event)
            close(emulator.attitude.angle, -.pi / 6, "twist")
            event.eventPhase = .cancelled
            display.rotate(with: event)
            close(emulator.attitude.angle, 0, "twist cancelled")
            event.at = display.convert(panel(), to: nil)
            emulator.attitude = (7, 7)
            event.eventPhase = .began
            display.rotate(with: event)
            #expect(untouched(), "a twist over the panel is the guest's")
            event.option = true
            display.rotate(with: event)
            close(emulator.attitude.angle, -.pi / 6, "Option-twist over the panel")
            event.eventPhase = .ended
            display.rotate(with: event)
            close(emulator.attitude.angle, 0, "twist ended")

            // Layouts during repeated tilt: the content counters only the guest's quarter turn, never the gesture, so after
            // release the screen stands turned with the shell at rest, unpitched, and the flat shell's Home button is
            // back. The LCD's picture keeps its size whatever the turn.
            for rotation in [0, 90, 180, 270] {
                emulator.rotationDegrees = rotation
                display.perform(NSSelectorFromString("step"))
                layout()
                for (right, down) in [(50.0, -25.0), (-75.0, 40.0), (0.0, 0.0), (100.0, 50.0)] {
                    let grab = chassis()
                    display.mouseDown(with: mouse(.leftMouseDown, grab))
                    display.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: grab.x + right, y: grab.y + down)))
                    #expect(home.isHidden == (right != 0 || down != 0), "Home over a tilting flat shell")
                    layout()
                    shellTurned(rest(rotation) + right * 0.004, "a layout mid-tilt keeps the tilt at \(rotation)")
                    display.mouseUp(with: mouse(.leftMouseUp, grab))
                    let combined = CATransform3DConcat(lcd.transform, shell.transform)
                    let scale = hypot(combined.m11, combined.m12)
                    #expect(
                        abs(remainder(atan2(combined.m12, combined.m11) - rest(rotation), 2 * .pi)) < 1e-5 && scale > 0,
                        "screen crooked at \(rotation): \(combined)"
                    )
                    #expect(abs(combined.m13) < 1e-5 && abs(combined.m23) < 1e-5, "pitch left over at \(rotation)")
                    close(emulator.attitude.angle, rest(rotation), "rest \(rotation)")
                    close(emulator.attitude.pitch, 0, "level \(rotation)")
                    #expect(!home.isHidden, "Home hidden after release at \(rotation)")
                }
            }
            #expect(touchPhases().isEmpty, "\(sent)")
            (frameWidth, frameHeight) = (320, 480)
        }

        /// A two-finger scroll over the panel moves the guest's finger the way a pointer drag the same way does, on every
        /// board, in every orientation, with the guest's UI turned or not (issue #70: on the iPods' surface, then turned by
        /// their LCD with the device, landscape swipes went upright and inverted).
        @Test(arguments: Board.allCases) func scrollFollowsPointer(board: Board) async throws {
            for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            defer {
                for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            DisplayView.bezel = .flat
            let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: board)
            let emulator = EmulatorController()
            display.emulator = emulator  // weak: held here
            defer { withExtendedLifetime(emulator) {} }
            let window = Cursor(contentRect: display.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = display
            func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
            func moved() -> CGVector {
                let ps = sent.compactMap { if case .touch(_, _, let x, let y) = $0 { (x, y) } else { nil } }
                return ps.count < 2 ? .zero : CGVector(dx: ps[1].0 - ps[0].0, dy: ps[1].1 - ps[0].1)
            }
            // A square scan turns no guest UI on any board; the shipped one turns the iPad's.
            for scan in [nil, CGSize(width: 400, height: 400)] {
                display.runningScan = scan
                for rotation in [0, 90, 180, 270] {
                    emulator.rotationDegrees = rotation
                    display.needsLayout = true
                    display.layoutSubtreeIfNeeded()
                    let lcd = all(display.layer!).first {
                        $0.backgroundColor == NSColor.black.cgColor && $0.contentsGravity == .resize
                    }!
                    let c = lcd.convert(CGPoint(x: lcd.bounds.midX, y: lcd.bounds.midY), to: display.layer!)
                    for (dx, dy) in [(30.0, 0.0), (0.0, -30.0)] {
                        let at = display.convert(c, to: nil)
                        let to = display.convert(CGPoint(x: c.x + dx, y: c.y + dy), to: nil)
                        sent = []
                        let steps: [(NSEvent.EventType, NSPoint)] = [
                            (.leftMouseDown, at), (.leftMouseDragged, to), (.leftMouseUp, to)
                        ]
                        for (type, p) in steps {
                            window.at = p
                            let e = NSEvent.mouseEvent(
                                with: type,
                                location: p,
                                modifierFlags: [],
                                timestamp: 0,
                                windowNumber: window.windowNumber,
                                context: nil,
                                eventNumber: 0,
                                clickCount: 1,
                                pressure: 1
                            )!
                            switch type {
                            case .leftMouseDown: display.mouseDown(with: e)
                            case .leftMouseDragged: display.mouseDragged(with: e)
                            default: display.mouseUp(with: e)
                            }
                        }
                        let pointer = moved()
                        sent = []
                        let event = Gesture()
                        event.at = at
                        event.dx = dx
                        event.dy = dy
                        event.eventPhase = .began
                        display.scrollWheel(with: event)
                        event.eventPhase = .ended
                        display.scrollWheel(with: event)
                        let scroll = moved()
                        #expect(
                            hypot(pointer.dx, pointer.dy) > 0.01
                                && hypot(scroll.dx - pointer.dx, scroll.dy - pointer.dy) < 0.001,
                            "\(board) at \(rotation), scan \(String(describing: scan)), (\(dx), \(dy)): scroll \(scroll), pointer \(pointer)"
                        )
                    }
                }
            }
        }

        /// A swipe started with the cursor at the screen's edge, toward that edge, gets the same travel over the panel as
        /// the same swipe from the center, on every board and in every orientation, as a trackpad gesture and as one
        /// wheel event: its finger goes down far enough in to make the whole move (down at the cursor, it clamped at the
        /// edge at once and a Home screen page didn't turn).
        @Test(arguments: Board.allCases) func swipeFromEdge(board: Board) async throws {
            for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            defer {
                for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            DisplayView.bezel = .flat
            let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: board)
            let emulator = EmulatorController()
            display.emulator = emulator  // weak: held here
            defer { withExtendedLifetime(emulator) {} }
            func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
            /// The finger's travel for a swipe of `d` view points from `p`, in three movements or as one wheel event.
            func swipe(_ p: CGPoint, _ d: CGVector, wheel: Bool) -> CGVector {
                sent = []
                let event = Gesture()
                event.at = display.convert(p, to: nil)
                if wheel {
                    event.eventPhase = []
                    event.dx = d.dx
                    event.dy = d.dy
                    display.scrollWheel(with: event)
                } else {
                    event.dx = d.dx / 3
                    event.dy = d.dy / 3
                    for phase in [NSEvent.Phase.began, .changed, .changed, .ended] {
                        event.eventPhase = phase
                        display.scrollWheel(with: event)
                    }
                }
                let ps = sent.compactMap { if case .touch(_, _, let x, let y) = $0 { (x, y) } else { nil } }
                guard let a = ps.first, let b = ps.last else { return .zero }
                return CGVector(dx: b.0 - a.0, dy: b.1 - a.1)
            }
            for rotation in [0, 90, 180, 270] {
                emulator.rotationDegrees = rotation
                display.needsLayout = true
                display.layoutSubtreeIfNeeded()
                let lcd = all(display.layer!).first {
                    $0.backgroundColor == NSColor.black.cgColor && $0.contentsGravity == .resize
                }!
                let r = lcd.convert(lcd.bounds, to: display.layer!)
                let c = CGPoint(x: r.midX, y: r.midY)
                for (ux, uy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                    // 45% of the screen's extent that way, from 2 points inside its edge that way
                    let d = CGVector(dx: ux * 0.45 * r.width, dy: uy * 0.45 * r.height)
                    let edge = CGPoint(x: c.x + ux * (r.width / 2 - 2), y: c.y + uy * (r.height / 2 - 2))
                    for wheel in [false, true] {
                        let full = swipe(c, d, wheel: wheel)
                        let got = swipe(edge, d, wheel: wheel)
                        #expect(
                            hypot(full.dx, full.dy) > 0.44 && hypot(got.dx - full.dx, got.dy - full.dy) < 0.001,
                            "\(board) at \(rotation), (\(ux), \(uy)), wheel \(wheel): from the edge \(got), from the center \(full)"
                        )
                    }
                }
            }
        }

        /// File drops on the screen: an accepted drag rings it until it leaves or ends; a mixed Finder drop queues the
        /// apps and media it can take; readiness is rechecked mid-drag; an IPSW goes to the library whatever the device
        /// does; an in-app IPA drag is refused, a Store row's payload taken. The kinds are DroppedFiles'.
        @Test func mediaDrop() throws {
            for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            defer {
                for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            DisplayView.bezel = .flat
            let view = DisplayView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), profile: .n72)
            let drag = Drag()
            let emulator = EmulatorController()
            view.emulator = emulator  // weak: held here
            defer { withExtendedLifetime(emulator) {} }
            defer { drag.draggingPasteboard.releaseGlobally() }
            var apps: [String] = []
            var media: [String] = []
            var catalog: [Int] = []
            var ipsws: [String] = []
            view.onDropIPSW = { ipsws += $0.map(\.lastPathComponent) }
            view.onDropIPA = { apps.append($0.lastPathComponent) }
            view.onDropMedia = { media.append($0.lastPathComponent) }
            view.onDropCatalogApp = { catalog.append($0.id) }
            // The drop-target ring (HIG p.294) shows only while an accepted drag is over the screen.
            func ring() -> NSView? { view.subviews.first { $0 is DropHighlight } }
            drag.files(["Notes.txt"])
            #expect(
                view.draggingEntered(drag).isEmpty && ring().map { $0.isHidden } != false,
                "a refused drag lights nothing"
            )
            // A mixed drop: the badge counts what's taken, the rest is left out without an alert (G3).
            drag.files(["App.IPA", "Photo.PNG", "Song.mp3", "Movie.MOV", "Notes.txt"])
            #expect(view.draggingEntered(drag) == .copy && drag.numberOfValidItemsForDrop == 4)
            #expect(
                ring()?.isHidden == false && view.subviews.last === ring(),
                "an accepted drag highlights the screen"
            )
            view.draggingExited(drag)
            #expect(ring()?.isHidden == true, "leaving clears the highlight")
            #expect(view.draggingUpdated(drag) == .copy && ring()?.isHidden == false)
            #expect(view.performDragOperation(drag))
            view.draggingEnded(drag)
            #expect(ring()?.isHidden == true, "a finished drop clears the highlight")
            #expect(apps == ["App.IPA"] && media == ["Photo.PNG", "Song.mp3", "Movie.MOV"])
            // The install queue remains an acceptable destination while another job
            // owns the device; readiness is rechecked if it goes away during a drag.
            #expect(view.draggingEntered(drag) == .copy)
            emulator.canQueueInstall = false
            #expect(view.draggingUpdated(drag).isEmpty && !view.performDragOperation(drag))
            #expect(apps.count == 1 && media.count == 3)
            emulator.canQueueInstall = true
            view.onDropMedia = nil
            drag.files(["Photo.png"])
            #expect(view.draggingEntered(drag).isEmpty && !view.performDragOperation(drag))
            // An IPSW goes to the library (matched by its SHA1), whatever the device is doing.
            emulator.canQueueInstall = false
            drag.files(["iPad1,1_3.2.2_7B500_Restore.IPSW", "Notes.txt"])
            #expect(view.draggingEntered(drag) == .copy && drag.numberOfValidItemsForDrop == 1)
            #expect(view.performDragOperation(drag) && ipsws == ["iPad1,1_3.2.2_7B500_Restore.IPSW"])
            emulator.canQueueInstall = true
            drag.files(["App.ipa"])
            drag.draggingSource = NSTableView()
            #expect(view.draggingEntered(drag).isEmpty && !view.performDragOperation(drag))
            // Explicit Store payloads remain accepted from inside the app.
            drag.draggingPasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(try JSONEncoder().encode(CatalogApp(id: 42)), forType: .ltmCatalogApp)
            drag.draggingPasteboard.writeObjects([item])
            #expect(view.draggingEntered(drag) == .copy && drag.numberOfValidItemsForDrop == 1)
            #expect(view.performDragOperation(drag) && catalog == [42])
        }
    }
}
