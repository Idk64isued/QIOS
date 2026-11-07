// The guest's keyboard is a US-layout USB keyboard fed macOS virtual key codes. A key whose character on the
// Mac's layout is what that keyboard would type goes through as the key itself; anything else (another layout,
// a dead key, an input method) goes through the text input system and reaches the guest as text.

import Foundation

public nonisolated enum GuestKeyboard {
    /// macOS virtual key code -> the US layout's unshifted and shifted characters.
    public static let us: [UInt16: (String, String)] = [
        0: ("a", "A"), 1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"), 4: ("h", "H"), 5: ("g", "G"), 6: ("z", "Z"),
        7: ("x", "X"), 8: ("c", "C"), 9: ("v", "V"), 11: ("b", "B"), 12: ("q", "Q"), 13: ("w", "W"), 14: ("e", "E"),
        15: ("r", "R"), 16: ("y", "Y"), 17: ("t", "T"), 18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"), 21: ("4", "$"),
        22: ("6", "^"), 23: ("5", "%"), 24: ("=", "+"), 25: ("9", "("), 26: ("7", "&"), 27: ("-", "_"), 28: ("8", "*"),
        29: ("0", ")"), 30: ("]", "}"), 31: ("o", "O"), 32: ("u", "U"), 33: ("[", "{"), 34: ("i", "I"), 35: ("p", "P"),
        37: ("l", "L"), 38: ("j", "J"), 39: ("'", "\""), 40: ("k", "K"), 41: (";", ":"), 42: ("\\", "|"),
        43: (",", "<"),
        44: ("/", "?"), 45: ("n", "N"), 46: ("m", "M"), 47: (".", ">"), 49: (" ", " "), 50: ("`", "~")
    ]

    /// Whether a key-down goes to the guest as its key code: a non-character key (Return, arrows, Delete…),
    /// or a character key whose character here is the US one. `characters` is the event's, on the Mac's layout;
    /// `inputSource` the selected one's identifier: an input method (Japanese, Chinese…) composes every character key.
    public static func passesThrough(keyCode: UInt16, characters: String?, shift: Bool, inputSource: String? = nil)
        -> Bool
    {
        guard let pair = us[keyCode] else { return true }
        if inputSource?.contains(".inputmethod.") == true { return false }
        return characters == (shift ? pair.1 : pair.0)
    }

    /// The US key that types `character`, with Shift or not: text for a guest without a text path.
    public static func key(for character: Character) -> (code: UInt16, shift: Bool)? {
        let text = String(character)
        for (code, pair) in us {
            if pair.0 == text { return (code, false) }
            if pair.1 == text { return (code, true) }
        }
        switch character {
        case "\n", "\r": return (36, false)
        case "\t": return (48, false)
        default: return nil
        }
    }
}

/// Keys the guest has been told are down. Whatever is still down when the screen loses focus is let go,
/// so a Shift held while ⌘-Tabbing away doesn't stay stuck in the guest.
public nonisolated struct HeldKeys {
    public init(down: Set<UInt16> = []) {
        self.down = down
    }
    public private(set) var down: Set<UInt16> = []
    public mutating func press(_ code: UInt16) { down.insert(code) }
    /// Whether the guest had it down (and should get the key-up).
    public mutating func release(_ code: UInt16) -> Bool { down.remove(code) != nil }
    public mutating func releaseAll() -> [UInt16] {
        defer { down = [] }
        return down.sorted()
    }
}
