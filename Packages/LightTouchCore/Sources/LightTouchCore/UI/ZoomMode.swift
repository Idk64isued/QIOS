// The device window's zoom in one unit, points per guest pixel (p). The named sizes (Fit, Physical Size, Pixel
// Accurate) are recomputed from the pane, the display and the device; a fixed size is a p of its own, so it keeps
// its size in points on any display. ⌘+ and ⌘− walk the ladder and the named sizes together.

import CoreGraphics
import Foundation
import HostRuntime

nonisolated public enum ZoomMode: Equatable, Sendable {
    case fit
    case physical
    /// One guest pixel per display pixel: 1 / the backing scale.
    case pixelAccurate
    case points(CGFloat)

    /// The fixed sizes ⌘+ and ⌘− stop at besides the named ones, in points per guest pixel.
    public static let ladder: [CGFloat] = [0.25, 0.5, 1, 1.5, 2, 3, 4]

    /// The saved form ("fit", "physical", "pixel", "p:1.5").
    public var defaultsValue: String {
        switch self {
        case .fit: "fit"
        case .physical: "physical"
        case .pixelAccurate: "pixel"
        case .points(let p): "p:\(p)"
        }
    }

    /// A saved zoom; anything unknown or out of range is Fit.
    public init(defaultsValue: String?) {
        switch defaultsValue {
        case "physical": self = .physical
        case "pixel": self = .pixelAccurate
        case let s? where s.hasPrefix("p:"):
            let p = Double(s.dropFirst(2)).map { CGFloat($0) }
            self = p.flatMap { $0.isFinite && $0 > 0.01 && $0 <= 64 ? .points($0) : nil } ?? .fit
        default: self = .fit
        }
    }

    /// Each board keeps its own zoom: one p makes an iPod and an iPad very different sizes.
    public static func defaultsKey(for board: Board) -> String { "zoomMode.\(board.rawValue)" }

    public static func saved(for board: Board, in defaults: UserDefaults = .standard) -> ZoomMode {
        ZoomMode(defaultsValue: defaults.string(forKey: defaultsKey(for: board)))
    }

    public func save(for board: Board, in defaults: UserDefaults = .standard) {
        defaults.set(defaultsValue, forKey: Self.defaultsKey(for: board))
    }

    /// The device view's accessibility value.
    public func name(points p: CGFloat) -> String {
        switch self {
        case .fit: "Fit"
        case .physical: "Physical Size"
        case .pixelAccurate: "Pixel Accurate"
        case .points: "\(Int((p * 100).rounded()))%"
        }
    }
}

/// The sizes a zoom can be in this pane, on this display, for this device, in points per guest pixel.
nonisolated public struct ZoomContext: Equatable, Sendable {
    /// The largest p that shows the whole device (or the bare screen) in the pane.
    public var fit: CGFloat
    /// The real panel's size on this display; nil when the display reports no physical size.
    public var physical: CGFloat?
    /// Display pixels per point.
    public var backing: CGFloat

    public init(fit: CGFloat, physical: CGFloat?, backing: CGFloat) {
        self.fit = fit
        self.physical = physical
        self.backing = backing
    }

    /// The p that shows a panel of `ppi` guest pixels per inch at its real size on a display of `pointsPerMillimeter`.
    public static func physical(pointsPerMillimeter: CGFloat?, ppi: CGFloat) -> CGFloat? {
        pointsPerMillimeter.map { $0 * 25.4 / ppi }
    }

    public var pixelAccurate: CGFloat { 1 / backing }

    /// The p a mode gives here. Physical Size on a display with no size data shows Fit (the mode itself is kept).
    public func points(for mode: ZoomMode) -> CGFloat {
        switch mode {
        case .fit: fit
        case .physical: physical ?? fit
        case .pixelAccurate: pixelAccurate
        case .points(let p): p
        }
    }

    /// The mode the menu checks: Physical Size without size data is showing Fit.
    public func shown(_ mode: ZoomMode) -> ZoomMode { mode == .physical && physical == nil ? .fit : mode }

    /// Every stop ⌘+ and ⌘− visit, ascending: the ladder and the named sizes. A ladder step within 2% of a named
    /// size gives way to it, as does a named size to an earlier one (Pixel Accurate, Physical Size, Fit).
    public var stops: [(mode: ZoomMode, points: CGFloat)] {
        var named: [(ZoomMode, CGFloat)] = [(.pixelAccurate, pixelAccurate)]
        if let physical { named.append((.physical, physical)) }
        named.append((.fit, fit))
        var all: [(mode: ZoomMode, points: CGFloat)] = []
        for (mode, p) in named + ZoomMode.ladder.map({ (ZoomMode.points($0), $0) })
        where p.isFinite && p > 0 && !all.contains(where: { Self.same($0.points, p) }) {
            all.append((mode, p))
        }
        return all.sorted { $0.points < $1.points }
    }

    /// The next stop strictly smaller (direction < 0) or larger than `p`, whatever produced `p`; nil past either end.
    public func step(from p: CGFloat, direction: Int) -> ZoomMode? {
        let stops = stops
        let next =
            direction > 0
            ? stops.first { $0.points > p && !Self.same($0.points, p) }
            : stops.last { $0.points < p && !Self.same($0.points, p) }
        return next?.mode
    }

    /// The one enabled-state rule for ⌘+ and ⌘−, the menu's and the toolbar's.
    public func canStep(from p: CGFloat, direction: Int) -> Bool { step(from: p, direction: direction) != nil }

    /// Crisp (nearest) when a guest pixel is a whole number of display pixels, at least one; otherwise smoothed.
    /// The flat screen and the 3D model's sampler both follow it.
    public static func drawsNearest(points p: CGFloat, backing: CGFloat) -> Bool {
        let pixels = p * backing
        return pixels >= 0.99 && abs(pixels - pixels.rounded()) < 0.01
    }

    private static func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.02 * max(a, b) }
}
