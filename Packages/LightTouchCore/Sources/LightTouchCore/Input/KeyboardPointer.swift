import CoreGraphics

/// The keys' modifiers, as the screen reads them (NSEvent.ModifierFlags' four).
nonisolated public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let control = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)
}

/// With typing off, the arrow keys move a pointer over the screen (a fraction of the panel, 0...1 each way); Space,
/// or an arrow with Shift, holds a touch at it, so Shift-arrows drag. Every key held for the touch must go up
/// before the touch ends.
public struct KeyboardPointer {
    public enum Phase: Equatable { case begin, update, end }
    public struct Touch: Equatable {
        public let phase: Phase
        public let point: CGPoint
        public init(_ phase: Phase, _ point: CGPoint) {
            self.phase = phase
            self.point = point
        }
    }
    public enum FocusMove: Equatable { case next, previous }

    public static let space: UInt16 = 49
    public static let arrows: Set<UInt16> = [123, 124, 125, 126]
    /// How far one arrow press moves the pointer.
    static let step: CGFloat = 0.02

    public var point = CGPoint(x: 0.5, y: 0.5)
    /// The keys holding the touch down.
    public private(set) var touchKeys = Set<UInt16>()
    /// The pointer has been used: its ring shows while the screen has the keyboard.
    public private(set) var isShown = false

    public init() {}

    /// A key down or up. `typingOff`: the device isn't taking typed keys, so the arrows are the pointer's;
    /// `canTouch`: the screen takes touches and no mouse touch, pinch or scroll is under way. Returns whether the key
    /// was the pointer's (not passed on) and the touches to send.
    public mutating func key(_ code: UInt16, down: Bool, modifiers: KeyModifiers, typingOff: Bool, canTouch: Bool) -> (
        handled: Bool, touches: [Touch]
    ) {
        guard code == Self.space || Self.arrows.contains(code) else { return (false, []) }
        if !down, touchKeys.contains(code) {
            if touchKeys.count == 1 { return (true, end().map { [$0] } ?? []) }
            touchKeys.remove(code)
            return (true, [])
        }
        guard typingOff, modifiers.intersection([.command, .control, .option]).isEmpty else { return (false, []) }
        guard down, canTouch else { return (true, []) }
        isShown = true
        var touches: [Touch] = []
        if code == Self.space || modifiers.contains(.shift), !touchKeys.contains(code) {
            if touchKeys.isEmpty { touches.append(Touch(.begin, point)) }
            touchKeys.insert(code)
        }
        if code != Self.space {
            switch code {
            case 123: point.x = max(0, point.x - Self.step)
            case 124: point.x = min(1, point.x + Self.step)
            case 125: point.y = min(1, point.y + Self.step)
            default: point.y = max(0, point.y - Self.step)
            }
            if !touchKeys.isEmpty { touches.append(Touch(.update, point)) }
        }
        return (true, touches)
    }

    /// Lets go of the touch, if one is down (focus left, the pointer went away).
    public mutating func end() -> Touch? {
        guard !touchKeys.isEmpty else { return nil }
        touchKeys.removeAll()
        return Touch(.end, point)
    }

    /// Modifiers changed: Shift released ends a Shift-arrow drag.
    public mutating func modifiersChanged(_ modifiers: KeyModifiers) -> Touch? {
        guard !modifiers.contains(.shift), !touchKeys.isDisjoint(with: Self.arrows) else { return nil }
        return end()
    }

    /// Tab leaves the screen while the arrow keys drive the pointer, and Control-Tab (with Shift, backwards) always
    /// does, so a keyboard user is never trapped here (HIG p.266). Typing sends Tab to the device; Command- and
    /// Option-Tab are the system's.
    public static func focusMove(keyCode: UInt16, modifiers: KeyModifiers, typingOff: Bool) -> FocusMove? {
        guard keyCode == 48, modifiers.intersection([.command, .option]).isEmpty,
            modifiers.contains(.control) || typingOff
        else { return nil }
        return modifiers.contains(.shift) ? .previous : .next
    }
}
