import CoreGraphics

/// A capture of the panel turned the way the window shows it.
public nonisolated enum PanelCapture {
    /// Clockwise quarter-turns from the panel's scan to the window: scan-to-upright (`guestTurn`, radians) plus the
    /// device's own rotation.
    public static func quarterTurns(guestTurn: CGFloat, deviceDegrees: Int) -> Int {
        ((Int((guestTurn * 2 / .pi).rounded()) + deviceDegrees / 90) % 4 + 4) % 4
    }

    /// `image` turned clockwise by `turns` quarters; the image itself for none.
    public static func rotated(_ image: CGImage, clockwiseQuarterTurns turns: Int) -> CGImage? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let size = turns % 2 == 0 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
        guard turns != 0,
            let context = CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: image.bitmapInfo.rawValue
            )
        else { return image }
        // CG is y-up, so a visual clockwise turn is a negative angle.
        switch turns {
        case 1:
            context.translateBy(x: 0, y: w)
            context.rotate(by: -.pi / 2)
        case 2:
            context.translateBy(x: w, y: h)
            context.rotate(by: .pi)
        default:
            context.translateBy(x: h, y: 0)
            context.rotate(by: .pi / 2)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
