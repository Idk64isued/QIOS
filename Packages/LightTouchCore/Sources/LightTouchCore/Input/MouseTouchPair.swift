import CoreGraphics

/// Xcode Simulator's two fingers from one mouse. Option adds a second finger
/// mirrored through the panel center, so a drag pinches or rotates. Adding
/// Shift locks the pair's spacing where it is, and a drag then moves both
/// fingers together: a two-finger pan. Points are 0…1 panel space.
public struct MouseTouchPair {
    /// The second finger's offset from the cursor, frozen when Shift joins Option.
    private var lockedOffset: CGVector?
    /// The pair modifiers held when the button went down. A drag keeps the
    /// mode it started with, whatever the keys do mid-gesture.
    private var gesture: KeyModifiers?

    public init() {}

    /// Every modifier change and mouse move, with the cursor's panel point
    /// (nil off the panel).
    public mutating func track(_ flags: KeyModifiers, at point: CGPoint?) {
        guard gesture == nil else { return }
        guard flags.contains(.option), flags.contains(.shift) else {
            lockedOffset = nil
            return
        }
        if lockedOffset == nil, let point { lockedOffset = Self.mirrorOffset(point) }
    }

    public mutating func down(at point: CGPoint, _ flags: KeyModifiers) {
        track(flags, at: point)
        gesture = flags.intersection([.option, .shift])
    }

    public mutating func up() { gesture = nil }

    /// Where the second finger goes for a cursor at `point`, or nil for one
    /// finger: the gesture's modifiers while the button is down, `flags` otherwise
    /// (the hover preview).
    public func secondFinger(for point: CGPoint, _ flags: KeyModifiers) -> CGPoint? {
        let flags = gesture ?? flags
        guard flags.contains(.option) else { return nil }
        let o = flags.contains(.shift) ? lockedOffset ?? Self.mirrorOffset(point) : Self.mirrorOffset(point)
        return CGPoint(x: min(max(point.x + o.dx, 0), 1), y: min(max(point.y + o.dy, 0), 1))
    }

    private static func mirrorOffset(_ p: CGPoint) -> CGVector { CGVector(dx: 1 - 2 * p.x, dy: 1 - 2 * p.y) }
}
