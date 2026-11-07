// A phone's browser as the device (Device ▸ Play on Phone…): its gravity becomes the accelerometer's, its touches
// the panel's, and it shows the panel the way the device is held. The math, without the server and page
// (PhoneRemoteController in the app; PhoneRemoteRequest reads its requests).

import CoreGraphics
import DeviceRuntime
import Foundation

public enum PhoneRemote {
    /// The phone's gravity (DeviceMotionEvent's accelerationIncludingGravity, pointing down as iOS reports it: flat
    /// and face up is (0, 0, -1), at any length) as the emulator's flat-pose attitude. qemu-ios's ipod_attitude_gravity,
    /// flat, is (−sin r cos p, sin p, −cos r cos p), which the guest reads as it is (the roll the chassis tilt sends is
    /// negated for the same reason, ChassisTilt.attitudeCommand); every direction is one roll and pitch.
    public static func attitude(x: Double, y: Double, z: Double) -> LinkCommand {
        .attitude(pitch: atan2(y, hypot(x, z)) * 180 / .pi, roll: atan2(-x, -z) * 180 / .pi, pose: 1)
    }

    /// Clockwise quarter-turns from the published surface to the panel as it sits in the upright device: the scan to
    /// upright. PanelCapture's window turns, without the shell's.
    public static func quarterTurns(guestTurn: CGFloat) -> Int {
        (Int((guestTurn * 2 / .pi).rounded()) % 4 + 4) % 4
    }

    /// A point on the phone's picture (normalized, y down) on the surface it was turned from by `turns`.
    public static func surfacePoint(_ p: CGPoint, turns: Int) -> CGPoint {
        switch turns {
        case 1: CGPoint(x: p.y, y: 1 - p.x)
        case 2: CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 3: CGPoint(x: 1 - p.y, y: p.x)
        default: p
        }
    }
}
