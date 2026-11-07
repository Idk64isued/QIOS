import AppKit
import LightTouchCore

/// The screen's and the capture keys' view of an event's modifiers.
extension KeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.command) { insert(.command) }
    }
}

extension MouseTouchPair {
    mutating func down(at point: CGPoint, _ flags: NSEvent.ModifierFlags) { down(at: point, KeyModifiers(flags)) }
}
