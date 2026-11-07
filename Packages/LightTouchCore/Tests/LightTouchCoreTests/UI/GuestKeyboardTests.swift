import Testing

@testable import LightTouchCore

/// US-layout keys go to the guest as key codes, anything else as text; held keys are let go once.
struct GuestKeyboardTests {
    static let japanese = "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"

    @Test func usKeysPassThroughOtherLayoutsAreText() {
        #expect(GuestKeyboard.passesThrough(keyCode: 0, characters: "a", shift: false))
        #expect(GuestKeyboard.passesThrough(keyCode: 0, characters: "A", shift: true))
        #expect(
            !GuestKeyboard.passesThrough(keyCode: 0, characters: "q", shift: false),
            "AZERTY's q on the US a key is text"
        )
        #expect(!GuestKeyboard.passesThrough(keyCode: 14, characters: "", shift: false), "a dead key is text")
        #expect(
            !GuestKeyboard.passesThrough(keyCode: 0, characters: "a", shift: false, inputSource: Self.japanese),
            "an input method composes"
        )
        #expect(
            GuestKeyboard.passesThrough(keyCode: 36, characters: "\r", shift: false, inputSource: Self.japanese),
            "Return is a key"
        )
    }

    @Test func keyForCharacter() {
        #expect(GuestKeyboard.key(for: "Q")! == (12, true))
        #expect(GuestKeyboard.key(for: "/")! == (44, false))
        #expect(GuestKeyboard.key(for: "\n")! == (36, false) && GuestKeyboard.key(for: "\t")! == (48, false))
        #expect(GuestKeyboard.key(for: "é") == nil)
    }

    @Test func heldKeysReleaseOnce() {
        var held = HeldKeys()
        held.press(56)
        held.press(0)
        let first = held.release(0)
        let second = held.release(0)
        let rest = held.releaseAll()
        #expect(first && !second && rest == [56] && held.down.isEmpty)
    }
}
