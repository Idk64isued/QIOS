import CoreGraphics
import Foundation
import HostRuntime
import ImageIO
import Testing

@testable import LightTouchCore

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
    "../../../../.."
).standardizedFileURL

/// An asset's pixels, decoded as 8-bit RGBA in the image's own color space (no conversion).
private struct Pixels {
    let width: Int, height: Int
    private let bytes: [UInt8]

    init(_ url: URL) throws {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        (self.width, self.height, self.bytes) = (width, height, bytes)
    }

    /// (r, g, b) at a top-left-origin pixel.
    func rgb(_ x: Int, _ y: Int) -> [Int] {
        let i = (y * width + x) * 4
        return (0..<3).map { Int(bytes[i + $0]) }
    }
    func alpha(_ x: Int, _ y: Int) -> Int { Int(bytes[(y * width + x) * 4 + 3]) }
    /// The brightest luma (ITU-R 601) in a top-left-origin rect.
    func maxLuma(_ rect: CGRect) -> Double {
        var best = 0.0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let c = rgb(x, y)
                best = max(best, 0.299 * Double(c[0]) + 0.587 * Double(c[1]) + 0.114 * Double(c[2]))
            }
        }
        return best
    }
}

/// The flat pictures: every catalog board has its own (except the pairs Sam chose to share, 10-06), each the size of its
/// profile's shellPixels; the iPad frame's cutout and Home circle; the model-rendered art's cutout and glass.
struct BoardArtTests {
    static let assets = repository.appendingPathComponent("LightTouchMac/Assets.xcassets")
    /// The boards that show another's picture, and whose.
    static let shared: [Board: Board] = [.n18: .n72, .n88: .m68]

    static func png(_ name: String) throws -> URL {
        let imageset = assets.appendingPathComponent(name + ".imageset")
        let contents =
            try JSONSerialization.jsonObject(with: Data(contentsOf: imageset.appendingPathComponent("Contents.json")))
            as? [String: Any]
        let file = try #require(((contents?["images"] as? [[String: Any]])?.first?["filename"]) as? String)
        return imageset.appendingPathComponent(file)
    }

    static func catalogBoards() throws -> [String] {
        let catalog =
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: repository.appendingPathComponent("LightTouchMac/Resources/firmware-catalog.json")
                )
            ) as? [String: Any]
        let entries = try #require(catalog?["entries"] as? [[String: Any]])
        return Set(entries.compactMap { $0["board"] as? String }).sorted()
    }

    @Test func everyCatalogBoardHasItsOwnPictureAtItsShellSize() throws {
        var seen: [(Board, String, Data)] = []
        for name in try Self.catalogBoards() {
            let board = try #require(Board(rawValue: name), "\(name): no Board")
            let url = try Self.png(board.shellImageName)
            let data = try Data(contentsOf: url)
            for (other, otherName, otherData) in seen {
                if Self.shared[board] == other || Self.shared[other] == board {
                    #expect(board.shellImageName == otherName, "\(name) should show \(other.rawValue)'s picture")
                    continue
                }
                #expect(board.shellImageName != otherName, "\(name) and \(other.rawValue) share \(otherName)")
                #expect(data != otherData, "\(name) and \(other.rawValue) are the same image")
            }
            seen.append((board, board.shellImageName, data))
            let pixels = try Pixels(url)
            #expect(
                CGSize(width: pixels.width, height: pixels.height) == board.shellPixels,
                "\(name): \(url.lastPathComponent) vs shellPixels \(board.shellPixels)"
            )
        }
        #expect(seen.count >= 8)
    }

    /// The iPods' screen-off LCD is one tone: the 2G photo's, which the art rendered from the 1G and 4G models paints.
    @Test func theIPodsShareOneScreenOffTone() throws {
        func lcd(_ board: Board) throws -> [Int] {
            let c = board.screenCutout
            return try Pixels(Self.png(board.shellImageName)).rgb(Int(c.midX), Int(c.midY))
        }
        let reference = try lcd(.n72)
        for board in [Board.n45, .n81] {
            let tone = try lcd(board)
            #expect(zip(tone, reference).map { abs($0 - $1) }.max()! <= 6, "\(board) \(tone) vs n72 \(reference)")
        }
    }

    /// The art rendered from our own models (N45, N81): transparent outside the chassis, the screen-off LCD filling
    /// exactly the profile's screenCutout, opaque glass right
    /// around it, and that glass one even tone (the 3D view's glass face-on, with no sheen or streak across it).
    @Test(arguments: [Board.n45, .n81]) func modelArtFillsItsCutoutAndNothingElse(_ board: Board) throws {
        let art = try Pixels(Self.png(board.shellImageName))
        let c = board.screenCutout
        for (x, y) in [(0, 0), (art.width - 1, 0), (0, art.height - 1), (art.width - 1, art.height - 1)] {
            #expect(art.alpha(x, y) == 0, "\(board): corner \(x),\(y) not transparent")
        }
        let lcd = art.rgb(Int(c.midX), Int(c.midY))
        func near(_ a: [Int], _ b: [Int], _ tolerance: Int) -> Bool {
            zip(a, b).map { abs($0 - $1) }.max()! <= tolerance
        }
        // Inside, less its edge rows and columns (the render's LCD edges fall up to a fifth of a pixel off the
        // profile's whole-pixel cutout, so they blend with the glass).
        var inside = 0
        for y in Int(c.minY) + 1..<Int(c.maxY) - 1 {
            for x in Int(c.minX) + 1..<Int(c.maxX) - 1
            where art.alpha(x, y) != 255 || !near(art.rgb(x, y), lcd, 2) {
                inside += 1
            }
        }
        #expect(inside == 0, "\(board): \(inside) cutout pixels aren't the screen-off LCD \(lcd)")
        // Around: a band of glass 2 to 20 pixels outside each edge (clear of the camera and Home button).
        var glass: [[Int]] = []
        let (x0, x1) = (Int(c.minX), Int(c.maxX))
        let (y0, y1) = (Int(c.minY), Int(c.maxY))
        for d in 2...20 {
            for x in x0..<x1 { glass += [art.rgb(x, y0 - d), art.rgb(x, y1 + d)] }
            for y in y0..<y1 { glass += [art.rgb(x0 - d, y), art.rgb(x1 - 1 + d, y)] }
            for x in x0..<x1 {
                #expect(art.alpha(x, y0 - d) == 255 && art.alpha(x, y1 + d) == 255, "\(board): glass not opaque")
            }
        }
        let tone = glass[0]
        #expect(!near(tone, lcd, 4), "\(board): glass \(tone) reads as the LCD \(lcd): the cutout is off")
        let off = glass.filter { !near($0, tone, 3) }
        #expect(off.isEmpty, "\(board): \(off.count) glass pixels off its tone \(tone), e.g. \(off.prefix(3))")
    }

    @Test func iPadFrameMatchesItsCutoutAndHomeButton() throws {
        let p = Board.k48
        let frame = try Pixels(Self.png(p.shellImageName))
        #expect(p.shellImageName == "ipad-frame")
        #expect(CGSize(width: frame.width, height: frame.height) == p.shellPixels)
        let shell = p.shellPixels
        let cut = p.screenCutout
        #expect(
            cut.size == CGSize(width: 768, height: 1024) && cut.minX * 2 + cut.width == shell.width
                && cut.minY * 2 + cut.height == shell.height,
            "\(cut)"
        )
        // The Home button is lighter than the glass beside it.
        let r = p.homeButtonDiameter / 2
        let cy = shell.height - p.homeButtonBottomInset - r
        let button = frame.maxLuma(
            CGRect(x: (shell.width / 2 - r).rounded(.down), y: (cy - r).rounded(.down), width: 2 * r, height: 2 * r)
        )
        let beside = frame.maxLuma(
            CGRect(x: (shell.width / 2 + 2 * r).rounded(.down), y: (cy - r).rounded(.down), width: 2 * r, height: 2 * r)
        )
        #expect(button > beside + 60, "button \(button), beside \(beside)")
    }

    /// An Intel Mac's boot gets the budget its slower emulation needs; Apple silicon keeps iPod 240 s, iPad 300 s.
    @Test func bootBudgetsScaleByTheHostSlowdown() {
        #if arch(x86_64)
            let slowdown = 5.0
        #else
            let slowdown = 1.0
        #endif
        #expect(Board.hostSlowdown == slowdown)
        #expect(Board.n72.bootBudget == 240 * slowdown && Board.k48.bootBudget == 300 * slowdown)
    }
}
