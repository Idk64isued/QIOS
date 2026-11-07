import CoreGraphics
import Foundation
import Testing

@testable import LightTouchCore

/// The console split's numbers: snap detents and the collapse threshold, show/hide, drags, per-name persistence.
struct ConsoleSplitLayoutTests {
    typealias L = ConsoleSplitLayout

    /// Available 600: range 100...440, middle 270, default 200; tolerance 10 (strict).
    @Test(
        arguments: [
            (265, 270), (279.5, 270), (261, 270), (280, 280), (260, 260), (195, 200), (209, 200), (210, 210),
            (191, 200),
            (190, 190), (99, 100), (50, 100), (49.9, nil), (0, nil), (1000, 440), (433.7, 433)
        ] as [(CGFloat, CGFloat?)]
    )
    func detentsAndCollapse(_ proposed: CGFloat, _ want: CGFloat?) {
        #expect(L.resolve(proposed, in: 600) == want)
    }

    /// A short pane: range 100...195, so the 200 detent is out of reach and must not pull past the maximum.
    @Test func shortPane() {
        #expect(L.resolve(195, in: 355) == 195 && L.resolve(300, in: 355) == 195, "detent beyond the maximum")
        #expect(L.resolve(150, in: 355) == 148, "middle of a short range snaps")  // (100+195)/2 = 147.5 -> 148
    }

    @Test func showHideKeepsTheHeight() {
        var l = L()
        #expect(l.isCollapsed && l.height == 200, "fresh state")
        l.toggle()
        #expect(!l.isCollapsed && l.height == 200, "show restores")
        l.height = 320
        l.toggle()
        #expect(l.isCollapsed && l.height == 320, "hide keeps the height")
        l.toggle()
        #expect(!l.isCollapsed && l.height == 320, "show brings it back")
        l = L(height: 40, isCollapsed: true)
        l.toggle()
        #expect(!l.isCollapsed && l.height == 200, "too-short height reopens at default")
    }

    /// Collapsing by drag keeps the height the drag started from.
    @Test func dragCollapseKeepsTheStartHeight() {
        let start = L(height: 320, isCollapsed: false)
        var l = start
        l.drag(from: start, to: 150, in: 600)
        #expect(!l.isCollapsed && l.height == 150, "mid-drag")
        l.drag(from: start, to: 30, in: 600)
        #expect(l.isCollapsed && l.height == 320)
        l.drag(from: start, to: 120, in: 600)
        #expect(!l.isCollapsed && l.height == 120, "drag back open")
    }

    @Test func persistencePerName() throws {
        let suite = "ltm-console-split-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        L(height: 333, isCollapsed: false).save("a", to: defaults)
        #expect(L.load("a", from: defaults) == L(height: 333, isCollapsed: false), "round trip")
        #expect(L.load("b", from: defaults) == L(), "other names start fresh")
        #expect(
            (defaults.dictionary(forKey: "ConsoleSplit a")?["height"] as? NSNumber)?.doubleValue == 333,
            "kept as a dictionary"
        )
        // An earlier build's JSON data loads, and is rewritten as a dictionary.
        defaults.set(Data(#"{"height":250,"isCollapsed":true}"#.utf8), forKey: "ConsoleSplit c")
        #expect(L.load("c", from: defaults) == L(height: 250, isCollapsed: true), "earlier JSON loads")
        #expect(
            defaults.dictionary(forKey: "ConsoleSplit c")?["isCollapsed"] as? Bool == true,
            "and is rewritten as a dictionary"
        )
    }
}
