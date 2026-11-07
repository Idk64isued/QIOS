import CoreGraphics
import HostRuntime
import Testing

@testable import LightTouchCore

/// Free-form resizing over every board that has it, zooms from a quarter point to two points per guest pixel and
/// drags from tiny to huge: every size is one the machine's panel= takes, snapping is idempotent and monotone, a
/// one-sided drag keeps the opposite edge, an edge at a limit says why, and wider than tall is allowed.
struct FreeFormResizeTests {
    nonisolated static let boards: [Board] = {
        _ = ShippedResources.machines
        return Board.allCases.filter(\.supportsFreeForm)
    }()

    /// The C setters' rules (qemu-ios's panel= parsing), on the scan.
    static func accepted(_ board: Board, upright: CGSize) -> Bool {
        guard let info = board.hardware else { return false }
        let s = board.scan(upright: upright)
        let (w, h) = (Int(s.width), Int(s.height))
        return CGFloat(w) == s.width && CGFloat(h) == s.height && w >= info.panelMin && h >= info.panelMin
            && w <= info.panelMaxWidth && h <= info.panelMaxHeight && w % info.panelWidthStep == 0
            && (info.panelMaxPixels == 0 || w * h <= info.panelMaxPixels)
    }

    static let requests: [CGSize] = stride(from: 1, through: 3000, by: 97).flatMap { w in
        stride(from: 1, through: 3000, by: 113).map { CGSize(width: w, height: $0) }
    }

    @Test(arguments: boards)
    func everySnapIsAPanelTheMachineTakesAndSnappingAgainChangesNothing(_ board: Board) {
        let model = FreeFormResize(board: board)
        for request in Self.requests {
            let snapped = model.snap(upright: request).size
            #expect(Self.accepted(board, upright: snapped), "\(request) gave \(snapped)")
            #expect(model.snap(upright: snapped) == FreeFormResize.Snapped(size: snapped, limit: nil), "\(snapped)")
        }
    }

    @Test(arguments: boards)
    func snappingIsMonotone(_ board: Board) {
        let model = FreeFormResize(board: board)
        for height in [100, 480, 1000] as [CGFloat] {
            var last: CGFloat = 0
            for width in stride(from: 1 as CGFloat, through: 2500, by: 7) {
                let w = model.snap(upright: CGSize(width: width, height: height), moving: (true, false)).size.width
                #expect(w >= last, "\(board) \(width)x\(height): \(w) after \(last)")
                last = w
            }
        }
    }

    @Test(arguments: boards, [0.25, 0.5, 1, 2] as [CGFloat])
    func aOneSidedDragKeepsTheOppositeEdge(_ board: Board, points p: CGFloat) {
        let model = FreeFormResize(board: board)
        let start = board.uprightScreenPixels
        for edges in [
            CGVector(dx: 1, dy: 0), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: -1)
        ] {
            for delta in [-150, -13, 9, 77, 400] as [CGFloat] {
                for turned in [false, true] {
                    let seen = turned ? CGSize(width: start.height, height: start.width) : start
                    let drag = model.drag(
                        from: seen,
                        edges: edges,
                        by: CGVector(dx: delta, dy: delta),
                        points: p,
                        symmetric: false,
                        quarterTurned: turned
                    )
                    // The edge opposite the grabbed one, in points from the old center: before, and after the shift.
                    for (axis, e) in [(0, edges.dx), (1, edges.dy)] where e != 0 {
                        let before = axis == 0 ? seen.width : seen.height
                        let after = axis == 0 ? drag.size.width : drag.size.height
                        let shift = axis == 0 ? drag.shift.dx : drag.shift.dy
                        let moved = (shift - e * after / 2 * p) - (-e * before / 2 * p)
                        #expect(abs(moved) <= p / 2 + 0.0001, "\(board) \(edges) by \(delta) at \(p): moved \(moved)")
                    }
                    let symmetric = model.drag(
                        from: seen,
                        edges: edges,
                        by: CGVector(dx: delta, dy: delta),
                        points: p,
                        symmetric: true,
                        quarterTurned: turned
                    )
                    #expect(symmetric.shift == .zero, "⌥ keeps the center")
                }
            }
        }
    }

    @Test(arguments: boards)
    func anEdgeAtALimitSaysWhy(_ board: Board) throws {
        let model = FreeFormResize(board: board)
        let info = try #require(board.hardware)
        let tiny = model.snap(upright: CGSize(width: 1, height: 1))
        #expect(tiny.size == CGSize(width: info.panelMin, height: info.panelMin) && tiny.limit != nil)
        let huge = model.snap(upright: CGSize(width: 5000, height: 5000))
        #expect(huge.limit != nil && Self.accepted(board, upright: huge.size))
        #expect(model.snap(upright: board.uprightScreenPixels) == .init(size: board.uprightScreenPixels, limit: nil))
    }

    @Test func theCLCDBoardsStopAtTheirLineCount() throws {
        for board in [Board.n72, .n18, .n88] {
            let rows = try #require(board.hardware?.panelMaxHeight)
            let tall = FreeFormResize(board: board).snap(upright: CGSize(width: 320, height: rows + 57))
            #expect(tall.size == CGSize(width: 320, height: rows))
            #expect(tall.limit == "iOS keeps this screen’s height in 9 bits, so \(rows) lines is the most it can use.")
        }
    }

    /// Sam (2026-10-08): wider than tall on every board, no minimum beyond the emulator's own.
    @Test(arguments: boards)
    func widerThanTallIsAllowed(_ board: Board) {
        let wide = CGSize(width: 512, height: 320)
        #expect(FreeFormResize(board: board).snap(upright: wide).size == wide)
    }

    @Test func aDragFollowsThePointerThroughTheZoom() {
        let pod = FreeFormResize(board: .n72)
        let drag = pod.drag(
            from: CGSize(width: 320, height: 480),
            edges: CGVector(dx: 1, dy: 0),
            by: CGVector(dx: 40, dy: 0),
            points: 2,
            symmetric: false,
            quarterTurned: false
        )
        #expect(drag.size == CGSize(width: 340, height: 480) && drag.shift == CGVector(dx: 20, dy: 0))
        let both = pod.drag(
            from: CGSize(width: 320, height: 480),
            edges: CGVector(dx: 1, dy: 0),
            by: CGVector(dx: 40, dy: 0),
            points: 2,
            symmetric: true,
            quarterTurned: false
        )
        #expect(both.size == CGSize(width: 360, height: 480))
    }

    @Test func handlesAreJustOutsideTheEdgesAndCornersTakeBoth() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 300)
        #expect(FreeFormResize.edges(at: CGPoint(x: 305, y: 200), screen: r, band: 10) == CGVector(dx: 1, dy: 0))
        #expect(FreeFormResize.edges(at: CGPoint(x: 95, y: 95), screen: r, band: 10) == CGVector(dx: -1, dy: -1))
        #expect(FreeFormResize.edges(at: CGPoint(x: 200, y: 405), screen: r, band: 10) == CGVector(dx: 0, dy: 1))
        #expect(FreeFormResize.edges(at: CGPoint(x: 200, y: 200), screen: r, band: 10) == nil, "on the screen: a touch")
        #expect(FreeFormResize.edges(at: CGPoint(x: 320, y: 200), screen: r, band: 10) == nil)
    }

    @Test func aFreeFormScanIsMountedAsTheShippedPanel() {
        _ = ShippedResources.machines
        #expect(Board.n72.freeFormTurn(scan: CGSize(width: 504, height: 320)) == 0, "the iPod shows a wide scan as is")
        #expect(Board.k48.freeFormTurn(scan: CGSize(width: 1280, height: 768)) == .pi / 2)
        #expect(Board.k48.freeFormTurn(scan: CGSize(width: 768, height: 1024)) == .pi / 2, "a wide iPad screen")
        #expect(Board.k48.freeFormTurn(scan: CGSize(width: 1024, height: 1024)) == 0)
        #expect(Board.k48.uprightPanel(scan: CGSize(width: 1280, height: 768)) == CGSize(width: 768, height: 1280))
    }
}
