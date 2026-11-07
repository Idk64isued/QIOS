import CoreGraphics
import Testing

@testable import LightTouchCore

/// A two-finger trackpad scroll as a finger (ScrollDrag): AppKit's event sequences in, the touch stream out.
struct ScrollDragTests {
    typealias P = ScrollDrag.Phase
    struct Driver {
        var drag = ScrollDrag()
        /// "phase@x" per touch, x in hundredths.
        var sent: [String] = []
        /// One event moving `dx` (panel fractions) along x; a gesture's finger goes down at x 0.5.
        mutating func event(_ phase: P, _ dx: Double = 0) {
            for t in drag.scroll(phase: phase, delta: CGVector(dx: dx, dy: 0), start: CGPoint(x: 0.5, y: 0.5)) {
                #expect(t.point.y == 0.5)
                sent.append("\(t.phase)@\(Int((t.point.x * 100).rounded()))")
            }
        }
    }

    /// A quick short flick: down at the cursor and moved by the began event's own delta, every finger sample as it
    /// arrives, up where the fingers left at their ended; the momentum phase after it (phase empty) sends nothing.
    @Test func flick() {
        var d = Driver()
        d.event(.mayBegin)
        d.event(.began, 0.01)
        d.event(.changed, 0.03)
        d.event(.changed, 0.04)
        d.event(.changed, 0.02)
        d.event(.ended)
        for _ in 0..<40 { d.event([], 0.04) }
        #expect(d.sent == ["begin@50", "update@51", "update@54", "update@58", "update@60", "end@60"], "\(d.sent)")
        #expect(d.drag.point == nil)
    }

    /// Two flicks in a row, the first's momentum still running when the second's fingers land: its stale events,
    /// ended included, neither move nor lift the second finger. Fingers that begin again with a finger still down
    /// (an ended never seen) lift it first.
    @Test func twoFlicksInARow() {
        var d = Driver()
        d.event(.began, 0.02)
        d.event(.ended)
        d.event([], 0.04)
        d.event(.mayBegin)
        d.event(.began, -0.02)
        d.event([], 0.03)
        d.event([], 0)
        d.event(.changed, -0.03)
        d.event(.began, 0.01)
        #expect(
            d.sent == [
                "begin@50", "update@52", "end@52", "begin@50", "update@48", "update@45", "end@45", "begin@50",
                "update@51"
            ],
            "\(d.sent)"
        )
    }

    /// Cancelled fingers lift; a drag clamps to the panel; with no point under the cursor nothing starts.
    @Test func cancelAndBounds() {
        var d = Driver()
        d.event(.changed, 0.1)
        #expect(d.sent.isEmpty)
        d.event(.began, 0.7)
        d.event(.cancelled)
        #expect(d.sent == ["begin@50", "update@100", "end@100"], "\(d.sent)")
        #expect(d.drag.scroll(phase: .began, delta: .zero, start: nil).isEmpty)
        #expect(d.drag.point == nil)
    }
}
