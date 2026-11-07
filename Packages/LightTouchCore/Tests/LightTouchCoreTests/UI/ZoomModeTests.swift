import CoreGraphics
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// Zoom in points per guest pixel: over every board, backing scale and display density, and panes from small to
/// full screen, the stops ⌘+/⌘− walk, the named sizes they reach, crisp versus smoothed, and the saved zoom.
struct ZoomModeTests {
    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        let board: Board
        let backing: CGFloat
        /// Display points per inch: a 27" 1440p, a 218 ppi Retina at 2x, a MacBook Pro's default.
        let pointsPerInch: CGFloat
        let pane: CGSize
        let bare: Bool
        var testDescription: String {
            "\(board.rawValue) @\(Int(backing))x \(Int(pointsPerInch)) pt/in \(Int(pane.width))x\(Int(pane.height))\(bare ? " bare" : "")"
        }

        /// What DisplayView gives: Fit of the shell (or the screen alone) in the pane with its 16 pt inset.
        var context: ZoomContext {
            let box = bare ? board.screenCutout.size : board.shellPixels
            let shellFit = min((pane.width - 32) / box.width, (pane.height - 32) / box.height)
            let fit = shellFit * board.screenCutout.width / board.uprightScreenPixels.width
            return ZoomContext(
                fit: fit,
                physical: ZoomContext.physical(pointsPerMillimeter: pointsPerInch / 25.4, ppi: board.panelPPI),
                backing: backing
            )
        }
    }

    nonisolated static let cases: [Case] = {
        _ = ShippedResources.machines
        let panes = [
            CGSize(width: 480, height: 400), CGSize(width: 720, height: 640), CGSize(width: 1512, height: 900)
        ]
        return Board.allCases.flatMap { board in
            [1, 2].flatMap { backing in
                [92, 109, 127].flatMap { ppi in
                    panes.flatMap { pane in
                        [false, true].map {
                            Case(
                                board: board,
                                backing: CGFloat(backing),
                                pointsPerInch: CGFloat(ppi),
                                pane: pane,
                                bare: $0
                            )
                        }
                    }
                }
            }
        }
    }()

    static func named(_ c: ZoomContext) -> [(ZoomMode, CGFloat)] {
        [(.fit, c.fit), (.pixelAccurate, c.pixelAccurate)] + (c.physical.map { [(.physical, $0)] } ?? [])
    }

    static func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.02 * max(a, b) }

    @Test(arguments: cases)
    func stopsAscendAndCoverEveryNamedSize(_ c: Case) {
        let context = c.context
        let stops = context.stops.map(\.points)
        #expect(zip(stops, stops.dropFirst()).allSatisfy { $0 < $1 }, "\(stops)")
        for (mode, p) in Self.named(context) {
            #expect(stops.contains { Self.close($0, p) }, "\(mode) at \(p) is no stop: \(stops)")
        }
        for step in ZoomMode.ladder { #expect(stops.contains { Self.close($0, step) }) }
    }

    @Test(arguments: cases)
    func everyStepFromANamedSizeMovesThatWay(_ c: Case) {
        let context = c.context
        let stops = context.stops.map(\.points)
        for (mode, p) in Self.named(context) {
            for direction in [-1, 1] {
                guard let next = context.step(from: p, direction: direction) else {
                    let end = direction < 0 ? stops.first : stops.last
                    #expect(
                        end.map { Self.close($0, p) } == true,
                        "\(mode) \(p): no step \(direction) short of the end"
                    )
                    #expect(!context.canStep(from: p, direction: direction))
                    continue
                }
                let q = context.points(for: next)
                #expect(direction < 0 ? q < p : q > p, "\(mode) \(p) stepped \(direction) to \(next) \(q)")
                #expect(context.canStep(from: p, direction: direction))
            }
        }
    }

    @Test(arguments: cases)
    func zoomingOutFromTheTopVisitsEveryNamedSize(_ c: Case) {
        let context = c.context
        var p = context.stops.map(\.points).max() ?? 0
        var visited: [CGFloat] = [p]
        while let next = context.step(from: p, direction: -1) {
            let q = context.points(for: next)
            #expect(q < p)
            p = q
            visited.append(p)
        }
        for (mode, named) in Self.named(context) {
            #expect(visited.contains { Self.close($0, named) }, "\(mode) at \(named) was skipped: \(visited)")
        }
    }

    /// Sam's bug: on old code, ⌘− from any size under the ladder's first step (1 display pixel) went to that step,
    /// zooming in (an iPod 2G at Fit on a 1x display is 0.78).
    @Test func zoomOutFromAFitUnderOneShrinks() {
        let context = ZoomContext(fit: 0.78, physical: 0.66, backing: 1)
        let next = context.step(from: 0.78, direction: -1)
        #expect(next == .physical)
        #expect(context.points(for: next ?? .fit) < 0.78)
        #expect(context.step(from: 0.66, direction: -1) == .points(0.5))
        #expect(context.step(from: 0.25, direction: -1) == nil)
        #expect(context.step(from: 0.78, direction: 1) == .pixelAccurate, "1 pt is Pixel Accurate at 1x")
    }

    @Test func aFixedSizeKeepsItsPointsOnAnyDisplayAndPixelAccurateFollowsTheBacking() {
        let retina = ZoomContext(fit: 0.7, physical: nil, backing: 2)
        let plain = ZoomContext(fit: 0.7, physical: nil, backing: 1)
        #expect(retina.points(for: .points(1.5)) == plain.points(for: .points(1.5)))
        #expect(retina.points(for: .pixelAccurate) == 0.5 && plain.points(for: .pixelAccurate) == 1)
    }

    @Test func physicalWithoutSizeDataShowsFitButStaysPhysical() {
        let context = ZoomContext(fit: 0.8, physical: nil, backing: 2)
        #expect(context.points(for: .physical) == 0.8)
        #expect(context.shown(.physical) == .fit)
        #expect(context.stops.allSatisfy { $0.mode != .physical })
    }

    /// Physical Size is the panel's real width on the display, from its ppi alone: the same in every bezel mode.
    @Test(arguments: Board.allCases)
    func physicalIsThePanelsRealWidth(_ board: Board) {
        _ = ShippedResources.machines
        let pointsPerMillimeter: CGFloat = 109 / 25.4
        let p = ZoomContext.physical(pointsPerMillimeter: pointsPerMillimeter, ppi: board.panelPPI) ?? 0
        let width = board.uprightScreenPixels.width
        let millimeters = width / board.panelPPI * 25.4
        #expect(abs(p * width - millimeters * pointsPerMillimeter) < 0.01)
    }

    @Test(arguments: [1, 2] as [CGFloat])
    func crispOnlyAtWholeDisplayPixels(backing: CGFloat) {
        for p in ZoomMode.ladder {
            let pixels = p * backing
            #expect(
                ZoomContext.drawsNearest(points: p, backing: backing) == (pixels >= 1 && pixels == pixels.rounded()),
                "\(p) pt at \(backing)x"
            )
        }
        #expect(ZoomContext.drawsNearest(points: 1 / backing, backing: backing), "Pixel Accurate is crisp")
        #expect(!ZoomContext.drawsNearest(points: 0.78, backing: backing))
    }

    @Test(arguments: [ZoomMode.fit, .physical, .pixelAccurate, .points(1.5), .points(0.25)])
    func savedZoomComesBackAsItself(_ mode: ZoomMode) {
        #expect(ZoomMode(defaultsValue: mode.defaultsValue) == mode)
    }

    @Test func unknownSavedZoomIsFit() {
        for value in [nil, "", "pixels:2", "p:x", "p:0", "p:-1", "p:inf", "zoom"] as [String?] {
            #expect(ZoomMode(defaultsValue: value) == .fit)
        }
    }

    @Test func eachBoardKeepsItsOwnZoom() throws {
        let defaults = try #require(UserDefaults(suiteName: "ZoomModeTests.\(UUID())"))
        ZoomMode.points(2).save(for: .n72, in: defaults)
        ZoomMode.physical.save(for: .k48, in: defaults)
        #expect(ZoomMode.saved(for: .n72, in: defaults) == .points(2))
        #expect(ZoomMode.saved(for: .k48, in: defaults) == .physical)
        #expect(ZoomMode.saved(for: .n90, in: defaults) == .fit)
    }
}
