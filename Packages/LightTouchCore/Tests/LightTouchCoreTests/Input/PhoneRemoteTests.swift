import CoreGraphics
import DeviceRuntime
import Foundation
import Testing

@testable import LightTouchCore

/// The phone remote's math: its gravity through qemu-ios's gravity model, and its touches back onto the surface.
struct PhoneRemoteTests {
    /// qemu-ios's ipod_attitude_gravity (include/hw/arm/ipod-attitude.h): what the guest reads.
    func guestGravity(_ command: LinkCommand) -> [Double] {
        guard case .attitude(let pitch, let roll, let pose) = command, pose == 1 else { return [] }
        let p = pitch * .pi / 180
        let r = roll * .pi / 180
        return [-sin(r) * cos(p), sin(p), -cos(r) * cos(p)]
    }

    /// Every direction the phone's gravity points, at the lengths accelerationIncludingGravity has (in m/s², shaken).
    @Test(arguments: [9.81, 1, 23])
    func theGuestReadsThePhonesGravity(length: Double) {
        for a in stride(from: -180.0, through: 180, by: 15) {
            for b in stride(from: -90.0, through: 90, by: 15) {
                let (p, q) = (a * .pi / 180, b * .pi / 180)
                let phone = [cos(q) * sin(p), sin(q), -cos(q) * cos(p)]
                let g = guestGravity(
                    PhoneRemote.attitude(x: phone[0] * length, y: phone[1] * length, z: phone[2] * length)
                )
                #expect(zip(g, phone).allSatisfy { abs($0 - $1) < 1e-9 }, "\(phone)")
            }
        }
    }

    /// The phone tipped right and away is the chassis dragged right and up, flat: the way tilt games are steered.
    @Test func tiltingThePhoneIsDraggingTheChassis() {
        var tilt = ChassisTilt()
        tilt.beginDrag(at: .zero, rotation: 0)
        let degree = CGFloat.pi / 180
        tilt.drag(to: CGPoint(x: 20 * degree / ChassisTilt.dragGain, y: -10 * degree / ChassisTilt.dragGain))
        let dragged = tilt.attitude(rotation: 0, flat: true)
        let mouse = guestGravity(ChassisTilt.attitudeCommand(angle: dragged.angle, pitch: dragged.pitch, pose: 1))
        // Right edge down 20° and top edge down 10° from flat: gravity leans toward +x and +y.
        let (right, away) = (20 * Double.pi / 180, 10 * Double.pi / 180)
        let phone = guestGravity(
            PhoneRemote.attitude(x: sin(right) * cos(away), y: sin(away), z: -cos(right) * cos(away))
        )
        #expect(zip(mouse, phone).allSatisfy { abs($0 - $1) < 1e-9 }, "mouse \(mouse), phone \(phone)")
    }

    @Test func turnsFollowTheScan() {
        // The iPad's landscape scan stands a quarter turn from upright; no board's surface follows the device.
        #expect(PhoneRemote.quarterTurns(guestTurn: .pi / 2) == 1)
        #expect(PhoneRemote.quarterTurns(guestTurn: 0) == 0)
    }

    @Test(arguments: 0..<4) func touchesLandWhereThePictureCameFrom(turns: Int) throws {
        // A 2×1 surface with its top-left pixel marked, turned as PanelCapture turns it for the phone.
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        let source = try #require(
            CGContext(
                data: nil,
                width: 2,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: info
            )
        )
        source.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try #require(source.makeImage())
        let turned = try #require(PanelCapture.rotated(image, clockwiseQuarterTurns: turns))
        // Find the marked pixel in the turned picture (y down) and map its center back.
        let context = try #require(
            CGContext(
                data: nil,
                width: turned.width,
                height: turned.height,
                bitsPerComponent: 8,
                bytesPerRow: turned.width * 4,
                space: space,
                bitmapInfo: info
            )
        )
        context.draw(turned, in: CGRect(x: 0, y: 0, width: turned.width, height: turned.height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = try #require((0..<turned.width * turned.height).first { pixels[$0 * 4] > 128 })
        let marked = CGPoint(
            x: (CGFloat(index % turned.width) + 0.5) / CGFloat(turned.width),
            y: (CGFloat(index / turned.width) + 0.5) / CGFloat(turned.height)
        )
        #expect(PhoneRemote.surfacePoint(marked, turns: turns) == CGPoint(x: 0.25, y: 0.5))
    }
}
