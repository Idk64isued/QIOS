import CoreGraphics
import Foundation

/// Where the divider may rest. Pure numbers (ConsoleSplitView is the view).
public struct ConsoleSplitLayout: Codable, Equatable {
    /// IDEDefaultDebugArea.preferredMinimumSize: 100 pt tall.
    public static let minimumHeight: CGFloat = 100
    /// NSSplitView collapses a collapsible pane once the drag passes half its minimum.
    public static let collapseThreshold = minimumHeight / 2
    /// DVTTheme.splitViewDividerSnappingTolerance.
    public static let snapTolerance: CGFloat = 10
    /// The resting height a fresh window opens the console at, and a detent
    /// (Xcode snaps its navigator divider to navigatorAreaDefaultWidth the same way).
    public static let defaultHeight: CGFloat = 200
    /// What the device pane keeps before the console gives up height.
    public static let topMinimum: CGFloat = 160

    /// The height the user chose; kept while the window is too short to show it
    /// (IDEEditorArea's _heightToReturnToDebuggerArea), and while collapsed.
    public var height = defaultHeight
    public var isCollapsed = true

    public init(height: CGFloat = defaultHeight, isCollapsed: Bool = true) {
        self.height = height
        self.isCollapsed = isCollapsed
    }

    public static func maximumHeight(in available: CGFloat) -> CGFloat {
        max(minimumHeight, available - topMinimum)
    }

    /// The default height, and the middle of the drag range
    /// (IDESplitViewDebugArea snaps its divider to the rounded midpoint).
    public static func detents(in available: CGFloat) -> [CGFloat] {
        let maximum = maximumHeight(in: available)
        return [defaultHeight, ((minimumHeight + maximum) / 2).rounded()].filter { $0 <= maximum }
    }

    /// A proposed console height from a drag: nil collapses, else a height
    /// clamped to the range and pulled onto a detent within the tolerance.
    public static func resolve(_ proposed: CGFloat, in available: CGFloat) -> CGFloat? {
        if proposed < collapseThreshold { return nil }
        let clamped = min(max(proposed, minimumHeight), maximumHeight(in: available)).rounded(.down)
        return detents(in: available).first { abs(clamped - $0) < snapTolerance } ?? clamped
    }

    public mutating func toggle() {
        isCollapsed.toggle()
        if !isCollapsed, height < Self.minimumHeight { height = Self.defaultHeight }
    }

    /// A drag that started at `start`. Collapsing by drag keeps the height it
    /// started from, so the toggle brings back the console the user had.
    public mutating func drag(from start: ConsoleSplitLayout, to proposed: CGFloat, in available: CGFloat) {
        if let resolved = Self.resolve(proposed, in: available) {
            height = resolved
            isCollapsed = false
        } else {
            height = start.height
            isCollapsed = true
        }
    }

    /// Per-window autosave, like DVTSplitView's state token: one key per name.
    /// A dictionary; earlier builds kept JSON data, rewritten on the first load.
    public static func load(_ name: String, from defaults: UserDefaults = .standard) -> ConsoleSplitLayout {
        switch defaults.object(forKey: "ConsoleSplit \(name)") {
        case let json as Data:
            guard let layout = try? JSONDecoder().decode(Self.self, from: json) else { return Self() }
            layout.save(name, to: defaults)
            return layout
        case let object?:
            return (try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0))
                .flatMap { try? PropertyListDecoder().decode(Self.self, from: $0) } ?? Self()
        case nil: return Self()
        }
    }

    public func save(_ name: String, to defaults: UserDefaults = .standard) {
        let object = (try? PropertyListEncoder().encode(self)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil)
        }
        defaults.set(object, forKey: "ConsoleSplit \(name)")
    }
}
