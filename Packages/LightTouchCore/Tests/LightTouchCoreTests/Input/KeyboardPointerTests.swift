import CoreGraphics
import Testing

@testable import LightTouchCore

/// The keyboard pointer (typing off): bounds, Space hold and repeat, Shift-arrow drag, release, the modifier and
/// input-ownership gates; Tab and Control-Tab out of the screen.
struct KeyboardPointerTests {
    struct Driver {
        var pointer = KeyboardPointer()
        var sent: [KeyboardPointer.Phase] = []
        var typingOff = true, canTouch = true
        @discardableResult
        mutating func key(_ code: UInt16, _ down: Bool = true, _ modifiers: KeyModifiers = []) -> Bool {
            let (handled, touches) = pointer.key(
                code,
                down: down,
                modifiers: modifiers,
                typingOff: typingOff,
                canTouch: canTouch
            )
            for touch in touches {
                #expect((0...1).contains(touch.point.x) && (0...1).contains(touch.point.y))
                sent.append(touch.phase)
            }
            return handled
        }
        mutating func end() { if let touch = pointer.end() { sent.append(touch.phase) } }
    }

    @Test func arrowsMoveThePointerWithinThePanel() {
        var d = Driver()
        let handled = d.key(124)
        #expect(handled && d.pointer.point.x > 0.5 && d.sent.isEmpty && d.pointer.isShown)
        for _ in 0..<100 {
            d.key(123)
            d.key(126)
        }
        #expect(d.pointer.point == .zero)
        for _ in 0..<100 {
            d.key(124)
            d.key(125)
        }
        #expect(d.pointer.point == CGPoint(x: 1, y: 1))
    }

    @Test func spaceHoldsATouchThatMovesAndEndsOnRelease() {
        var d = Driver()
        d.key(49)
        d.key(49)
        d.key(123)
        d.key(49, false)
        #expect(
            d.sent == [.begin, .update, .end] && d.pointer.touchKeys.isEmpty,
            "a repeated Space doesn't begin again"
        )
    }

    @Test func shiftArrowsDragUntilTheLastKeyIsUp() {
        var d = Driver()
        d.key(123, true, .shift)
        d.key(126, true, .shift)
        d.key(123, false)
        #expect(d.sent == [.begin, .update, .update])
        d.key(126, false)
        #expect(d.sent == [.begin, .update, .update, .end])
    }

    @Test func endingTwiceSendsOneEnd() {
        var d = Driver()
        d.key(49)
        d.end()
        d.end()
        #expect(d.sent == [.begin, .end])
    }

    @Test func releasingShiftEndsAnArrowDrag() {
        var pointer = KeyboardPointer()
        _ = pointer.key(124, down: true, modifiers: .shift, typingOff: true, canTouch: true)
        let held = pointer.modifiersChanged(.shift)
        #expect(held == nil)
        let released = pointer.modifiersChanged([])
        #expect(released?.phase == .end && pointer.touchKeys.isEmpty)
        _ = pointer.key(49, down: true, modifiers: [], typingOff: true, canTouch: true)
        let space = pointer.modifiersChanged([])
        #expect(space == nil, "a Space touch isn't Shift's")
    }

    @Test(arguments: [KeyModifiers.command, .control, .option, [.control, .option]])
    func menuModifiersPassOn(_ modifiers: KeyModifiers) {
        var d = Driver()
        let handled = d.key(49, true, modifiers)
        #expect(!handled && d.sent.isEmpty)
    }

    @Test func typingOwnsTheKeys() {
        var d = Driver()
        d.typingOff = false
        let space = d.key(49)
        let arrow = d.key(123)
        let other = d.key(0)
        #expect(!space && !arrow && d.sent.isEmpty)
        #expect(!other, "not a pointer key")
    }

    /// A mouse touch, a pinch or a scroll under way (or touches off) swallows the key without touching.
    @Test func noTouchWhileTheScreenIsBusy() {
        var d = Driver()
        d.canTouch = false
        let space = d.key(49)
        let arrow = d.key(123)
        #expect(space && arrow && d.sent.isEmpty && d.pointer.point == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func tabLeavesTheScreenUnlessTyping() {
        func move(_ modifiers: KeyModifiers, typingOff: Bool) -> KeyboardPointer.FocusMove? {
            KeyboardPointer.focusMove(keyCode: 48, modifiers: modifiers, typingOff: typingOff)
        }
        #expect(
            move([], typingOff: true) == .next && move(.shift, typingOff: true) == .previous,
            "Tab must leave the screen when typing is off"
        )
        #expect(
            move([], typingOff: false) == nil && move(.shift, typingOff: false) == nil,
            "typing sends Tab to the device"
        )
        #expect(
            move(.control, typingOff: false) == .next && move([.control, .shift], typingOff: false) == .previous,
            "Control-Tab always leaves"
        )
        #expect(move(.command, typingOff: true) == nil && move(.option, typingOff: true) == nil)
        #expect(KeyboardPointer.focusMove(keyCode: 49, modifiers: [], typingOff: true) == nil)
    }
}
