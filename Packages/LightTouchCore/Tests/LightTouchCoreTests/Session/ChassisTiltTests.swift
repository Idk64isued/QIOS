import CoreGraphics
import DeviceRuntime
import Foundation
import Testing

@testable import LightTouchCore

/// Tilt's gesture math: drags from the grab point, scrolls (points or lines, both signs), twists, their clamps,
/// the release to rest, and the attitude the accelerometer gets, upright and flat, in every quarter turn.
/// (tests/offline/check-tilt-game-input.py runs the same gestures into qemu-ios's gravity model.)
struct ChassisTiltTests {
    static let degree = CGFloat.pi / 180
    func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }
    /// A drag of `right`/`up` degrees from `grab` (the view is flipped: up is a smaller y).
    func point(_ grab: CGPoint, right: CGFloat, up: CGFloat) -> CGPoint {
        CGPoint(
            x: grab.x + right * Self.degree / ChassisTilt.dragGain,
            y: grab.y - up * Self.degree / ChassisTilt.dragGain
        )
    }

    @Test func restAnglesTakeTheShortWayRound() {
        #expect(ChassisTilt.layerAngle(0) == 0 && close(ChassisTilt.layerAngle(90), .pi / 2))
        #expect(close(ChassisTilt.layerAngle(180), .pi) && close(ChassisTilt.layerAngle(270), -.pi / 2))
    }

    @Test(arguments: [CGPoint(x: 37, y: 91), CGPoint(x: -200, y: 300)])
    func dragsMeasureFromTheGrabPointAndClamp(_ grab: CGPoint) {
        var tilt = ChassisTilt()
        tilt.beginDrag(at: grab, rotation: 90)
        #expect(tilt.tilting && close(tilt.restAngle(rotation: 0), .pi / 2), "the gesture keeps its rest angle")
        tilt.drag(to: point(grab, right: 30, up: 0))
        #expect(close(tilt.tiltAngle, 30 * Self.degree) && close(tilt.pitchAngle, 0))
        tilt.drag(to: point(grab, right: -30, up: 20))
        #expect(close(tilt.tiltAngle, -30 * Self.degree) && close(tilt.pitchAngle, 20 * Self.degree))
        tilt.drag(to: point(grab, right: 500, up: -500))
        #expect(close(tilt.tiltAngle, .pi / 4) && close(tilt.pitchAngle, -.pi / 4), "a drag clamps at 45°")
        tilt.reset()
        #expect(!tilt.tilting && tilt.tiltAngle == 0 && tilt.pitchAngle == 0 && tilt.motionRestAngle == nil)
        #expect(close(tilt.restAngle(rotation: 270), -.pi / 2), "at rest, the guest's orientation again")
    }

    /// The rates themselves: 25 points of drag is 0.1 rad, 10 swipe points or one wheel line is 0.015 rad.
    @Test func gainsAreTheTunedRates() {
        var tilt = ChassisTilt()
        tilt.beginDrag(at: CGPoint(x: 10, y: 20), rotation: 0)
        tilt.drag(to: CGPoint(x: 35, y: 70))
        #expect(close(tilt.tiltAngle, 0.1) && close(tilt.pitchAngle, -0.2))
        for (delta, precise) in [(10.0, true), (1.0, false)] {
            tilt.reset()
            tilt.beginScroll(rotation: 0)
            tilt.scroll(by: ChassisTilt.scrollMovement(dx: delta, dy: -2 * delta, precise: precise))
            #expect(close(tilt.tiltAngle, 0.015) && close(tilt.pitchAngle, -0.03), "precise \(precise)")
        }
    }

    @Test func scrollsAccumulateInPointsOrLinesAndClamp() {
        for precise in [true, false] {
            for sign in [-1.0, 1.0] {
                var tilt = ChassisTilt()
                tilt.beginScroll(rotation: 0)
                let points = sign * Double.pi / 6 / ChassisTilt.scrollTiltGain
                tilt.scroll(by: ChassisTilt.scrollMovement(dx: points / (precise ? 1 : 10), dy: 0, precise: precise))
                #expect(tilt.scrollTilting && close(tilt.tiltAngle, sign * .pi / 6), "\(precise) \(sign)")
                tilt.scroll(by: ChassisTilt.scrollMovement(dx: 0, dy: points / (precise ? 1 : 10), precise: precise))
                #expect(
                    close(tilt.tiltAngle, sign * .pi / 6) && close(tilt.pitchAngle, sign * .pi / 6),
                    "a second movement adds"
                )
            }
        }
        var clamp = ChassisTilt()
        clamp.beginScroll(rotation: 0)
        clamp.scroll(by: CGVector(dx: 1_000_000, dy: -1_000_000))
        #expect(close(clamp.tiltAngle, .pi / 3) && close(clamp.pitchAngle, -.pi / 3), "a scroll clamps at 60°")
        clamp.reset()
        #expect(!clamp.scrollTilting && clamp.tiltAngle == 0 && clamp.pitchAngle == 0)
        // A scroll picks up from the tilt it starts at, then starts over after a reset.
        clamp.beginScroll(rotation: 0)
        clamp.scroll(by: CGVector(dx: 100, dy: 0))
        #expect(close(clamp.tiltAngle, 100 * ChassisTilt.scrollTiltGain))
    }

    @Test func twistsAreCounterclockwiseDegreesAndClamp() {
        var tilt = ChassisTilt()
        tilt.beginTwist(rotation: 180)
        #expect(tilt.rotatingChassis && close(tilt.restAngle(rotation: 0), .pi))
        tilt.twist(byDegrees: 10)
        #expect(close(tilt.tiltAngle, -10 * Self.degree), "counterclockwise twist, clockwise roll")
        tilt.twist(byDegrees: -1000)
        #expect(close(tilt.tiltAngle, .pi / 3))
        tilt.reset()
        #expect(!tilt.rotatingChassis)
    }

    @Test(arguments: [0, 90, 180, 270])
    func uprightAttitudeIsTheShellAngle(_ rotation: Int) {
        var tilt = ChassisTilt()
        tilt.beginDrag(at: .zero, rotation: rotation)
        tilt.drag(to: point(.zero, right: 30, up: 10))
        let attitude = tilt.attitude(rotation: rotation, flat: false)
        #expect(
            close(attitude.angle, ChassisTilt.layerAngle(rotation) + 30 * Self.degree)
                && close(attitude.pitch, 10 * Self.degree)
        )
    }

    @Test func flatAttitudeTurnsScreenAxesIntoSensorAxes() {
        var tilt = ChassisTilt()
        let rest = tilt.attitude(rotation: 0, flat: true)
        #expect(close(rest.angle, 0) && close(rest.pitch, 0), "flat at rest: gravity straight into the display")
        tilt.beginDrag(at: .zero, rotation: 0)
        tilt.drag(to: point(.zero, right: 30, up: 0))
        var a = tilt.attitude(rotation: 0, flat: true)
        #expect(close(a.angle, 30 * Self.degree) && close(a.pitch, 0), "portrait: right is roll")
        tilt.reset()
        tilt.beginDrag(at: .zero, rotation: 90)
        tilt.drag(to: point(.zero, right: 30, up: 0))
        a = tilt.attitude(rotation: 90, flat: true)
        #expect(
            close(a.angle, 0) && close(a.pitch, 30 * Self.degree),
            "landscape: the screen's right is the sensor's pitch"
        )
        tilt.reset()
        tilt.beginDrag(at: .zero, rotation: 180)
        tilt.drag(to: point(.zero, right: 0, up: 30))
        a = tilt.attitude(rotation: 180, flat: true)
        #expect(close(a.angle, 0) && close(a.pitch, -30 * Self.degree), "upside down: up is the sensor's down")
    }

    @Test func attitudeCommandsAreDegreesNormalizedAcrossTheSeam() {
        guard
            case .attitude(let pitch, let roll, let pose) = ChassisTilt.attitudeCommand(
                angle: .pi / 6,
                pitch: .pi / 12,
                pose: 1
            )
        else {
            Issue.record("not an attitude")
            return
        }
        #expect(
            abs(pitch - 15) < 1e-9 && abs(roll + 30) < 1e-9 && pose == 1,
            "layer rotation and device roll have opposite signs"
        )
        guard
            case .attitude(_, let seam, _) = ChassisTilt.attitudeCommand(
                angle: 1.5 * .pi + 10 * .pi / 180 + 2 * .pi,
                pitch: 0,
                pose: 0
            )
        else {
            Issue.record("not an attitude")
            return
        }
        #expect(abs(seam - 80) < 1e-9, "past the upside-down seam the roll is the short way: \(seam)")
    }
}
