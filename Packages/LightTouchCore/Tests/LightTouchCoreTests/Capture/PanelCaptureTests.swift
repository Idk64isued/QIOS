import CoreGraphics
import Foundation
import Testing

@testable import LightTouchCore

/// A panel capture turns the way the window shows it.
struct PanelCaptureTests {
    /// 2x1, a red pixel on the left (y-up CG space).
    func image() throws -> CGImage {
        let ctx = try #require(
            CGContext(
                data: nil,
                width: 2,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return try #require(ctx.makeImage())
    }

    /// The red pixel, top-left origin.
    func red(_ img: CGImage) -> [Int] {
        let data = img.dataProvider!.data! as Data
        let row = img.bytesPerRow
        for y in 0..<img.height { for x in 0..<img.width where data[y * row + x * 4] > 128 { return [x, y] } }
        return []
    }

    @Test func quarterTurnsMoveTheLeftPixel() throws {
        let image = try image()
        let cw = try #require(PanelCapture.rotated(image, clockwiseQuarterTurns: 1))
        #expect(cw.width == 1 && cw.height == 2 && red(cw) == [0, 0], "clockwise: left goes to the top")
        #expect(
            red(try #require(PanelCapture.rotated(image, clockwiseQuarterTurns: 3))) == [0, 1],
            "counter-clockwise: left goes to the bottom"
        )
        #expect(red(try #require(PanelCapture.rotated(image, clockwiseQuarterTurns: 2))) == [1, 0])
        #expect(PanelCapture.rotated(image, clockwiseQuarterTurns: 0) === image)
    }

    @Test func turnsCombineScanAndDeviceRotation() {
        // The iPad's panel scans a quarter counter-clockwise of upright (panelRotation -pi/2).
        #expect(PanelCapture.quarterTurns(guestTurn: -.pi / 2, deviceDegrees: 0) == 3)
        #expect(PanelCapture.quarterTurns(guestTurn: -.pi / 2, deviceDegrees: 90) == 0)
        #expect(PanelCapture.quarterTurns(guestTurn: 0, deviceDegrees: 270) == 3, "an iPod held landscape")
        #expect(PanelCapture.quarterTurns(guestTurn: .pi, deviceDegrees: 180) == 0)
    }
}
