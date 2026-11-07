import CoreGraphics
import Foundation
import ImageIO

/// Is a captured frame the right picture, not just lit? A frame written upside down, with red and blue swapped, or left
/// stale (a previous surface) is still lit. The reference is a `width`-wide box-filter downsample of a known-good frame
/// (tests/sessions/matrix-refs/<entry>-<shot>.png, a few KB): `verdict` downsamples the capture the same way and
/// reports the fraction of blocks (the status-bar band masked) that differ by more than `tolerance`. Measured margins: a
/// correct frame 0.000-0.007; a flip 0.30-0.69, an R/B swap 0.21-0.31, a stale iPad surface 0.10.
public enum FrameCheck {
    public static let width = 64
    /// Per-channel block-mean drift still counted as the same block.
    public static let tolerance = 8
    /// The most of the unmasked blocks that may differ.
    public static let threshold = 0.02
    /// The top band left out: the status-bar clock (and the iPad's lock time).
    public static let maskTop = 0.08
    /// The iPod panel model scales every pixel by the backlight level the guest programs, as a dim real screen looks;
    /// the references are at full exposure. 2.x's SpringBoard leaves the backlight at ~0.76-0.79, so its captures are
    /// the right picture, uniformly dimmer: `verdict` measures that gain and undoes it, down to this exposure.
    public static let exposureMin = 0.6

    /// Block means, row by row.
    public struct Signature: Equatable, Sendable {
        public var width: Int, height: Int
        public var pixels: [[Int]]  // [r, g, b]
        public init(width: Int, height: Int, pixels: [[Int]]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }
    }

    /// An image's RGBX bytes.
    static func rgb(_ url: URL) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let w = image.width
        let h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: w * 4,
                    space: image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(
                        name: CGColorSpace.sRGB
                    )!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]) }
        return (w, h, rgba)
    }

    /// A frame's `width`-wide area-weighted box downsample (a reference already that wide comes back as it is).
    public static func signature(_ url: URL, width gw: Int = width) throws -> Signature {
        let (w, h, px) = try rgb(url)
        return signature(width: w, height: h, rgbx: px, gridWidth: gw)
    }

    public static func signature(width w: Int, height h: Int, rgbx px: [UInt8], gridWidth gw: Int = width) -> Signature
    {
        let gh = max(1, Int((Double(gw) * Double(h) / Double(w)).rounded()))
        let sx = Double(w) / Double(gw)
        let sy = Double(h) / Double(gh)
        var out: [[Int]] = []
        out.reserveCapacity(gw * gh)
        for oy in 0..<gh {
            let y0 = Double(oy) * sy
            let y1 = y0 + sy
            for ox in 0..<gw {
                let x0 = Double(ox) * sx
                let x1 = x0 + sx
                var r = 0.0
                var g = 0.0
                var b = 0.0
                var weight = 0.0
                for y in Int(y0)..<min(h, Int(y1.rounded(.up))) {
                    let wy = min(Double(y + 1), y1) - max(Double(y), y0)
                    for x in Int(x0)..<min(w, Int(x1.rounded(.up))) {
                        let k = (min(Double(x + 1), x1) - max(Double(x), x0)) * wy
                        let i = (y * w + x) * 4
                        r += Double(px[i]) * k
                        g += Double(px[i + 1]) * k
                        b += Double(px[i + 2]) * k
                        weight += k
                    }
                }
                out.append([r, g, b].map { Int(($0 / max(weight, 1e-9)).rounded()) })
            }
        }
        return Signature(width: gw, height: gh, pixels: out)
    }

    /// The fraction of unmasked blocks whose largest channel drift exceeds `tolerance`.
    public static func fractionDiffering(
        _ capture: Signature,
        _ reference: Signature,
        tolerance: Int = tolerance,
        maskTop: Double = maskTop
    ) throws -> Double {
        guard capture.width == reference.width, capture.height == reference.height else {
            throw CocoaError(
                .formatting,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "grid mismatch: capture \(capture.width)x\(capture.height) vs reference \(reference.width)x\(reference.height)"
                ]
            )
        }
        let first = Int(Double(capture.height) * maskTop) * capture.width
        var differ = 0
        var total = 0
        for i in first..<capture.pixels.count {
            let a = capture.pixels[i]
            let b = reference.pixels[i]
            if max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2])) > tolerance { differ += 1 }
            total += 1
        }
        return total == 0 ? 0 : Double(differ) / Double(total)
    }

    /// The capture's backlight gain against the reference: the median capture/reference ratio over the blocks the
    /// reference has bright (a uniform backlight scales them all alike).
    public static func exposure(_ capture: Signature, _ reference: Signature) -> Double {
        let ratios = zip(capture.pixels, reference.pixels).compactMap { c, f -> Double? in
            let sf = f.reduce(0, +)
            return sf > 150 ? Double(c.reduce(0, +)) / Double(sf) : nil
        }.sorted()
        return ratios.isEmpty ? 1 : ratios[ratios.count / 2]
    }

    /// Undo a backlight gain; outside [exposureMin, 1) the capture stays as it is.
    public static func normalize(_ capture: Signature, gain: Double) -> Signature {
        guard exposureMin <= gain, gain < 1 else { return capture }
        var out = capture
        out.pixels = capture.pixels.map { $0.map { min(255, Int((Double($0) / gain).rounded())) } }
        return out
    }

    public struct Verdict: Sendable {
        public var ok: Bool, fraction: Double?, exposure: Double?, why: String
    }

    /// A captured frame against a reference PNG.
    public static func verdict(capture: URL, reference: URL, threshold: Double = threshold) -> Verdict {
        do {
            let ref = try signature(reference)
            let cap = try signature(capture, width: ref.width)
            let gain = exposure(cap, ref)
            let fraction = try fractionDiffering(normalize(cap, gain: gain), ref)
            let ok = fraction <= threshold
            return Verdict(
                ok: ok,
                fraction: fraction,
                exposure: gain,
                why: ok
                    ? String(format: "matches the reference (%.3f <= %.2f)", fraction, threshold)
                    : String(
                        format: "differs from the reference (%.3f > %.2f): flip / color swap / stale surface",
                        fraction,
                        threshold
                    )
            )
        } catch {
            return Verdict(
                ok: false,
                fraction: nil,
                exposure: nil,
                why: "could not compare: \(error.localizedDescription)"
            )
        }
    }
}
