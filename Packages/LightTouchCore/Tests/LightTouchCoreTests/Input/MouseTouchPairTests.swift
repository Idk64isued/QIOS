import CoreGraphics
import Testing

@testable import LightTouchCore

/// Simulator-style two fingers from a mouse (issue #18): Option mirrors a second finger through the panel center;
/// Option-Shift locks the spacing and drags both in parallel; a plain drag stays one finger.
struct MouseTouchPairTests {
    func near(_ a: CGPoint?, _ x: CGFloat, _ y: CGFloat) -> Bool {
        guard let a else { return false }
        return abs(a.x - x) < 1e-9 && abs(a.y - y) < 1e-9
    }

    @Test func plainDragIsOneFinger() {
        var pair = MouseTouchPair()
        pair.down(at: CGPoint(x: 0.3, y: 0.4), [])
        #expect(pair.secondFinger(for: CGPoint(x: 0.2, y: 0.3), []) == nil)
        #expect(
            pair.secondFinger(for: CGPoint(x: 0.2, y: 0.3), .option) == nil,
            "Option pressed mid-drag doesn't add a finger"
        )
    }

    @Test func optionMirrorsThroughTheCenter() {
        var pair = MouseTouchPair()
        pair.down(at: CGPoint(x: 0.3, y: 0.4), .option)
        #expect(near(pair.secondFinger(for: CGPoint(x: 0.3, y: 0.4), .option), 0.7, 0.6))
        #expect(near(pair.secondFinger(for: CGPoint(x: 0.2, y: 0.3), .option), 0.8, 0.7))
        pair.up()
        pair.track(.option, at: CGPoint(x: 0.3, y: 0.5))
        #expect(
            near(pair.secondFinger(for: CGPoint(x: 0.3, y: 0.5), .option), 0.7, 0.5),
            "Option hover shows the mirrored pair"
        )
        #expect(pair.secondFinger(for: CGPoint(x: 0.3, y: 0.5), []) == nil)
    }

    @Test func optionShiftLocksTheSpacingWhenShiftWentDown() {
        var pair = MouseTouchPair()
        pair.track([.option, .shift], at: CGPoint(x: 0.3, y: 0.5))
        pair.track([.option, .shift], at: CGPoint(x: 0.2, y: 0.5))
        #expect(
            near(pair.secondFinger(for: CGPoint(x: 0.2, y: 0.5), [.option, .shift]), 0.6, 0.5),
            "hover keeps the spacing locked"
        )
        pair.down(at: CGPoint(x: 0.2, y: 0.5), [.option, .shift])
        #expect(near(pair.secondFinger(for: CGPoint(x: 0.2, y: 0.3), [.option, .shift]), 0.6, 0.3))
        #expect(
            near(pair.secondFinger(for: CGPoint(x: 0.25, y: 0.1), [.option, .shift]), 0.65, 0.1),
            "both fingers move in parallel"
        )
        #expect(
            near(pair.secondFinger(for: CGPoint(x: 0.2, y: 0.4), []), 0.6, 0.4),
            "releasing keys mid-drag keeps the pan"
        )
        pair.track([], at: CGPoint(x: 0.2, y: 0.4))
        #expect(
            near(pair.secondFinger(for: CGPoint(x: 0.2, y: 0.4), []), 0.6, 0.4),
            "nor does a modifier change during the drag"
        )
        pair.up()
        #expect(pair.secondFinger(for: CGPoint(x: 0.2, y: 0.4), []) == nil)
    }

    @Test func releasingOptionDropsTheLock() {
        var pair = MouseTouchPair()
        pair.track([.option, .shift], at: CGPoint(x: 0.2, y: 0.5))
        pair.track([], at: CGPoint(x: 0.8, y: 0.5))
        pair.track(.option, at: CGPoint(x: 0.8, y: 0.5))
        pair.track([.option, .shift], at: CGPoint(x: 0.8, y: 0.5))
        pair.down(at: CGPoint(x: 0.8, y: 0.5), [.option, .shift])
        #expect(near(pair.secondFinger(for: CGPoint(x: 0.8, y: 0.5), []), 0.2, 0.5))
        #expect(
            near(pair.secondFinger(for: CGPoint(x: 0.7, y: 0.5), []), 0.1, 0.5),
            "the next Option-Shift locks afresh"
        )
    }

    @Test func theSecondFingerStaysOnThePanel() {
        var pair = MouseTouchPair()
        pair.track([.option, .shift], at: CGPoint(x: 0.1, y: 0.5))
        #expect(near(pair.secondFinger(for: CGPoint(x: 0.5, y: 0.5), [.option, .shift]), 1, 0.5))
    }
}
