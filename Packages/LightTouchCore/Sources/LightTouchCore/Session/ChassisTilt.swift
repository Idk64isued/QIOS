// Tilt for games: grabbing the shell outside the screen and dragging steers roll and pitch; off the panel a
// two-finger scroll or twist does the same, more gently. Release springs the shell back to rest and restores
// resting gravity. This is the gesture's state and math, DisplayView's tilt without the events and the shell
// drawing; the attitude reaches the guest's accelerometer as LinkCommand.attitude (EmulatorController.setTilt).

import CoreGraphics
import DeviceRuntime
import Foundation

public struct ChassisTilt {
    public init() {}

    /// Radians of device tilt per point of two-finger swipe, when the cursor is off the panel. Much gentler than a
    /// drag: a swipe has no anchor to hold on to, so the same rate that feels direct under a finger feels wild here.
    /// A full trackpad sweep is a few degrees, which is the range tilt games use.
    public static let scrollTiltGain: CGFloat = 0.0015
    /// Radians per point of a chassis drag from its grab point.
    public static let dragGain: CGFloat = 0.004

    /// Current roll from rest (the drag's horizontal, the scroll's x, the twist).
    public private(set) var tiltAngle: CGFloat = 0
    public private(set) var pitchAngle: CGFloat = 0
    public private(set) var tilting = false
    public private(set) var scrollTilting = false
    public private(set) var rotatingChassis = false
    private var scrollTilt = 0.0
    private var scrollPitch = 0.0
    /// The rest angle held for the gesture, so a guest rotation mid-gesture doesn't move its frame.
    public private(set) var motionRestAngle: CGFloat?
    private var grabPoint = CGPoint.zero

    /// The shell layer's rest rotation for a guest orientation, signed so 270° comes in as a single quarter turn
    /// (-π/2), not three of them — the implicit animation interpolates the transform, and the sign is what makes
    /// the swing take the short way round.
    public static func layerAngle(_ degrees: Int) -> CGFloat {
        degrees == 270 ? -.pi / 2 : CGFloat(degrees) * .pi / 180
    }

    /// The shell's resting rotation for the guest's current orientation.
    public func restAngle(rotation: Int) -> CGFloat { motionRestAngle ?? Self.layerAngle(rotation) }

    /// Precise deltas are points; conventional wheels report lines. Preserve both signs because NSEvent has already
    /// honored the system preference.
    public static func scrollMovement(dx: CGFloat, dy: CGFloat, precise: Bool) -> CGVector {
        let pointsPerUnit: CGFloat = precise ? 1 : 10
        return CGVector(dx: dx * pointsPerUnit, dy: dy * pointsPerUnit)
    }

    /// A press on the chassis (after `reset`): the drag measures from `point`.
    public mutating func beginDrag(at point: CGPoint, rotation: Int) {
        motionRestAngle = Self.layerAngle(rotation)
        tilting = true
        grabPoint = point
    }

    /// Horizontal movement steers with accelerometer roll, not yaw around gravity. Fixed deltas from the grab point
    /// give a diagonal the same response anywhere on the frame. The view is flipped: dragging up is an upward gesture.
    public mutating func drag(to point: CGPoint) {
        tiltAngle = min(max((point.x - grabPoint.x) * Self.dragGain, -.pi / 4), .pi / 4)
        pitchAngle = min(max((grabPoint.y - point.y) * Self.dragGain, -.pi / 4), .pi / 4)
    }

    public mutating func beginScroll(rotation: Int) {
        motionRestAngle = Self.layerAngle(rotation)
        scrollTilt = tiltAngle
        scrollPitch = pitchAngle
        scrollTilting = true
    }

    /// One scroll movement (scrollMovement's points): AppKit already applied Natural Scrolling, so the same content
    /// movement convention as the LCD, without inverting it again.
    public mutating func scroll(by delta: CGVector) {
        scrollTilt = min(max(scrollTilt + delta.dx * Self.scrollTiltGain, -.pi / 3), .pi / 3)
        scrollPitch = min(max(scrollPitch + delta.dy * Self.scrollTiltGain, -.pi / 3), .pi / 3)
        tiltAngle = scrollTilt
        pitchAngle = scrollPitch
    }

    /// A two-finger twist off the panel (after `reset`).
    public mutating func beginTwist(rotation: Int) {
        motionRestAngle = Self.layerAngle(rotation)
        rotatingChassis = true
    }

    /// NSEvent rotation is incremental counterclockwise degrees; the flipped view's roll is clockwise radians.
    public mutating func twist(byDegrees rotation: Float) {
        tiltAngle = min(max(tiltAngle - CGFloat(rotation) * .pi / 180, -.pi / 3), .pi / 3)
    }

    /// Every gesture ends here: at rest, nothing held.
    public mutating func reset() {
        rotatingChassis = false
        tilting = false
        scrollTilting = false
        scrollTilt = 0
        scrollPitch = 0
        pitchAngle = 0
        motionRestAngle = nil
        tiltAngle = 0
    }

    /// The accelerometer's roll angle and pitch for this tilt: the shell's angle upright; flat, gravity points into
    /// the display and its screen-relative X/Y components are rotated into the sensor axes, landscape included.
    public func attitude(rotation: Int, flat: Bool) -> (angle: CGFloat, pitch: CGFloat) {
        let rest = restAngle(rotation: rotation)
        guard flat else { return (rest + tiltAngle, pitchAngle) }
        let x = sin(tiltAngle) * cos(pitchAngle)
        let y = sin(pitchAngle)
        let z = -cos(tiltAngle) * cos(pitchAngle)
        let sensorX = cos(rest) * x - sin(rest) * y
        let sensorY = sin(rest) * x + cos(rest) * y
        return (atan2(sensorX, -z), atan2(sensorY, hypot(sensorX, z)))
    }

    /// The helper's attitude command. Layer rotation and mounted device roll have opposite signs; the angle is
    /// normalized across the upside-down seam before it becomes degrees for the shared model.
    public static func attitudeCommand(angle: Double, pitch: Double, pose: Int) -> LinkCommand {
        let roll = -atan2(sin(angle), cos(angle)) * 180 / .pi
        return .attitude(pitch: pitch * 180 / .pi, roll: roll, pose: pose)
    }
}
