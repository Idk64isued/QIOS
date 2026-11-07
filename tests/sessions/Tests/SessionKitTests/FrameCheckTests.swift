import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import SessionKit

/// The frame references: block means, the masked status band, the backlight gain, and real references against
/// themselves, flipped and with red and blue swapped.
struct FrameCheckTests {
    typealias S = FrameCheck.Signature
    static let refs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
        "../../matrix-refs"
    ).standardized

    @Test func blocksDifferOnlyPastTheTolerance() throws {
        let black = S(width: 2, height: 2, pixels: Array(repeating: [0, 0, 0], count: 4))
        let red = S(width: 2, height: 2, pixels: Array(repeating: [255, 0, 0], count: 4))
        #expect(try FrameCheck.fractionDiffering(black, black) == 0)
        #expect(try FrameCheck.fractionDiffering(black, red) == 1)
        #expect(try FrameCheck.fractionDiffering(black, red, tolerance: 255) == 0)
        #expect(throws: (any Error).self) {
            try FrameCheck.fractionDiffering(black, S(width: 1, height: 4, pixels: black.pixels))
        }
    }

    @Test func aDimBacklightIsUndoneButADimFlipStillFails() throws {
        let grad = S(
            width: 2,
            height: 2,
            pixels: [[40, 80, 120], [200, 160, 120], [120, 200, 40], [240, 240, 240]]
        )
        let dim = S(width: 2, height: 2, pixels: grad.pixels.map { $0.map { Int((Double($0) * 0.76).rounded()) } })
        #expect(abs(FrameCheck.exposure(dim, grad) - 0.76) < 0.01)
        #expect(
            try FrameCheck.fractionDiffering(FrameCheck.normalize(dim, gain: FrameCheck.exposure(dim, grad)), grad) == 0
        )
        #expect(FrameCheck.normalize(dim, gain: 0.5) == dim)  // below exposureMin: as it is
        let flip = S(width: 2, height: 2, pixels: dim.pixels.reversed())
        #expect(
            try FrameCheck.fractionDiffering(FrameCheck.normalize(flip, gain: FrameCheck.exposure(flip, grad)), grad)
                > 0.5
        )
    }

    @Test func boxDownsampleAveragesEachBlock() {
        // 4x2 pixels -> 2x1 blocks: the left block's mean of (0, 100), the right's of (200, 255).
        let px: [UInt8] = [
            0, 0, 0, 0, 100, 100, 100, 0, 200, 200, 200, 0, 255, 255, 255, 0,
            0, 0, 0, 0, 100, 100, 100, 0, 200, 200, 200, 0, 255, 255, 255, 0
        ]
        let s = FrameCheck.signature(width: 4, height: 2, rgbx: px, gridWidth: 2)
        #expect(s == S(width: 2, height: 1, pixels: [[50, 50, 50], [228, 228, 228]]))
    }

    /// A reference PNG written as `transform` of `source`.
    func write(_ source: URL, to url: URL, _ transform: (inout [UInt8], Int, Int) -> Void) throws {
        var (w, h, px) = try FrameCheck.rgb(source)
        transform(&px, w, h)
        let provider = CGDataProvider(data: Data(px) as CFData)!
        let image = CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test(arguments: ["m68ap-1A543a-home", "k48ap-8C148-home", "n72ap-5F138-home"])
    func aReferenceMatchesItselfAndNotItsFlipOrSwap(_ name: String) throws {
        let ref = Self.refs.appendingPathComponent("\(name).png")
        #expect(FrameCheck.verdict(capture: ref, reference: ref).ok)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("framecheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let flipped = dir.appendingPathComponent("flipped.png")
        let swapped = dir.appendingPathComponent("swapped.png")
        try write(ref, to: flipped) { px, w, h in
            let rows = (0..<h).map { Array(px[($0 * w * 4)..<(($0 + 1) * w * 4)]) }
            px = Array(rows.reversed().joined())
        }
        try write(ref, to: swapped) { px, _, _ in
            for i in stride(from: 0, to: px.count, by: 4) { px.swapAt(i, i + 2) }
        }
        let flip = FrameCheck.verdict(capture: flipped, reference: ref)
        let swap = FrameCheck.verdict(capture: swapped, reference: ref)
        #expect(!flip.ok, "a flipped \(name) passed: \(flip.why)")
        #expect(!swap.ok, "an R/B-swapped \(name) passed: \(swap.why)")
    }
}
