// View ▸ Free-Form Screen's resize: the screen's edges and corners are handles, the opposite edge stays put (⌥:
// both move), and the size snaps only to what the board's panel= takes (DeviceInfo, the emulator's limits). At a
// limit the edge stops and `limit` says why. No minimum beyond the emulator's own, and wider than tall is allowed.

import CoreGraphics
import Foundation
import HostRuntime

nonisolated public struct FreeFormResize: Sendable {
    public let board: Board
    private let minSide: CGFloat
    private let maxWidth: CGFloat
    private let maxHeight: CGFloat
    private let widthStep: CGFloat
    private let maxPixels: CGFloat

    public init(board: Board) {
        self.board = board
        let info = board.hardware
        minSide = CGFloat(info?.panelMin ?? 64)
        maxWidth = CGFloat(info?.panelMaxWidth ?? 1024)
        maxHeight = CGFloat(info?.panelMaxHeight ?? 1024)
        widthStep = CGFloat(max(info?.panelWidthStep ?? 2, 1))
        maxPixels = CGFloat(info?.panelMaxPixels ?? 0)
    }

    public struct Snapped: Equatable, Sendable {
        /// Upright guest pixels.
        public var size: CGSize
        /// Why an edge stopped, for the readout; nil when nothing held it.
        public var limit: String?
    }

    /// The nearest upright size the board's panel= takes, `moving` naming the upright sides being dragged (the ones
    /// a pixel budget takes back from). The scan's width snaps to the board's step; nothing else snaps.
    public func snap(upright size: CGSize, moving: (width: Bool, height: Bool) = (true, true)) -> Snapped {
        let s = board.scan(upright: size)
        let turned = board.panelRotation != 0
        let movingScanWidth = turned ? moving.height : moving.width
        let movingScanHeight = turned ? moving.width : moving.height
        var limit: String?
        func finite(_ v: CGFloat) -> CGFloat { v.isFinite ? v : minSide }
        let loW = (minSide / widthStep).rounded(.up) * widthStep
        let hiW = (maxWidth / widthStep).rounded(.down) * widthStep
        var w = (finite(s.width) / widthStep).rounded() * widthStep
        var h = finite(s.height).rounded()
        if w < loW || h < minSide { limit = smallest }
        if w > hiW { limit = tooLarge(Int(hiW), rows: false) }
        if h > maxHeight { limit = tooLarge(Int(maxHeight), rows: true) }
        w = min(max(w, loW), hiW)
        h = min(max(h, minSide), maxHeight)
        if maxPixels > 0, w * h > maxPixels {
            if movingScanWidth && !movingScanHeight {
                w = (maxPixels / h / widthStep).rounded(.down) * widthStep
            } else {
                h = (maxPixels / w).rounded(.down)
            }
            limit = "The \(board.shortName)’s screen can have at most \(Int(maxPixels).formatted()) pixels."
        }
        return Snapped(size: board.scan(upright: CGSize(width: w, height: h)), limit: limit)
    }

    public struct Drag: Equatable, Sendable {
        /// The screen as seen, in guest pixels.
        public var size: CGSize
        /// How far the screen's center moves, in points, so the opposite edge stays where it was.
        public var shift: CGVector
        public var limit: String?
    }

    /// An edge drag: from the screen's `start` size as seen, the grabbed `edges` (-1 left/top, +1 right/bottom, 0
    /// neither) moved by `delta` points at `p` points per guest pixel. `symmetric` (⌥) moves the opposite edges too;
    /// `quarterTurned` is a device held sideways, whose screen as seen is the upright one transposed.
    public func drag(
        from start: CGSize,
        edges: CGVector,
        by delta: CGVector,
        points p: CGFloat,
        symmetric: Bool,
        quarterTurned: Bool
    ) -> Drag {
        let k: CGFloat = symmetric ? 2 : 1
        let seen = CGSize(
            width: start.width + k * delta.dx * edges.dx / p,
            height: start.height + k * delta.dy * edges.dy / p
        )
        func turn(_ s: CGSize) -> CGSize { quarterTurned ? CGSize(width: s.height, height: s.width) : s }
        let movesX = edges.dx != 0
        let movesY = edges.dy != 0
        let snapped = snap(upright: turn(seen), moving: quarterTurned ? (movesY, movesX) : (movesX, movesY))
        let size = turn(snapped.size)
        let shift =
            symmetric
            ? CGVector.zero
            : CGVector(
                dx: (size.width - start.width) / 2 * edges.dx * p,
                dy: (size.height - start.height) / 2 * edges.dy * p
            )
        return Drag(size: size, shift: shift, limit: snapped.limit)
    }

    /// The edges a point grabs on a screen at `rect` (y down): a band `band` points wide just outside each edge,
    /// the corners taking both. nil off the band or on the screen itself (a touch).
    public static func edges(at point: CGPoint, screen rect: CGRect, band: CGFloat) -> CGVector? {
        guard rect.insetBy(dx: -band, dy: -band).contains(point), !rect.contains(point) else { return nil }
        return CGVector(
            dx: point.x < rect.minX ? -1 : point.x >= rect.maxX ? 1 : 0,
            dy: point.y < rect.minY ? -1 : point.y >= rect.maxY ? 1 : 0
        )
    }

    /// "640 × 1136".
    public static func text(_ size: CGSize) -> String { "\(Int(size.width)) × \(Int(size.height))" }

    private var smallest: String { "The smallest screen is \(Int(minSide)) pixels a side." }

    private func tooLarge(_ n: Int, rows: Bool) -> String {
        // The CLCD boards' display driver keeps the window height in 9 bits: at 320x568 iPhone OS 3.1.3 writes 56
        // rows, draws only those and never gets past its boot spinner, so the emulator can't show more (2026-10-08).
        if rows, board.soc == .s5l8720 || board.soc == .s5l8920 {
            return "iOS keeps this screen’s height in 9 bits, so \(n) lines is the most it can use."
        }
        return "The \(board.shortName)’s display takes at most \(n) pixels a side."
    }
}
