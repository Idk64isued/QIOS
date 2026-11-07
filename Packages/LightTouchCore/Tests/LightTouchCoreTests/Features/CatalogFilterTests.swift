import Foundation
import Testing

@testable import LightTouchCore

/// The Store's filter (CatalogFilter) and version sheet (CatalogDetailsModel) against recorded Legacy Store answers
/// (tests/fixtures/store-filter): Hotel Dash (family 1), Hotel Dash Deluxe (2, iPad only), Diner Dash (1, 2) and
/// Agent Dash (1, 2; needs iOS 4.1) judged for iPod2,1 3.1.3 and iPad1,1 3.2.
struct CatalogFilterTests {
    struct Envelope: Decodable { let apps: [CatalogApp] }
    static func apps(_ name: String) throws -> [CatalogApp] {
        try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fixture("store-filter/" + name))).apps
    }
    func names(_ list: [CatalogApp]) -> Set<String> { Set(list.map(\.name)) }

    @Test func iPodShowsUnavailableAppsUntilToldNot() throws {
        let ipod = try Self.apps("ipod2-3.1.3-dash.json")
        var filter = CatalogFilter()
        #expect(
            filter.apply(ipod, iPad: false).count == 4 && !filter.isActive(iPad: false),
            "default: every app, unavailable ones grayed"
        )
        filter.showUnavailable = false
        #expect(
            names(filter.apply(ipod, iPad: false)) == ["Hotel Dash", "Diner Dash"],
            "iPad-only and too-new apps hidden on the iPod"
        )
        #expect(filter.isActive(iPad: false))
        // The iPad-only choice never narrows an iPod.
        let iPadOnly = CatalogFilter(iPadOnly: true, showUnavailable: true)
        #expect(names(iPadOnly.apply(ipod, iPad: false)) == names(ipod) && !iPadOnly.isActive(iPad: false))
    }

    @Test func iPadFamilyChoice() throws {
        let ipad = try Self.apps("ipad1-3.2-dash.json")
        var filter = CatalogFilter(showUnavailable: false)
        #expect(
            names(filter.apply(ipad, iPad: true)) == ["Hotel Dash", "Hotel Dash Deluxe", "Diner Dash"],
            "all families, runnable"
        )
        filter.iPadOnly = true
        #expect(
            names(filter.apply(ipad, iPad: true)) == ["Hotel Dash Deluxe", "Diner Dash"],
            "iPad Apps Only drops iPhone-only Hotel Dash"
        )
        filter.showUnavailable = true
        #expect(
            names(filter.apply(ipad, iPad: true)) == ["Hotel Dash Deluxe", "Diner Dash", "Agent Dash"],
            "unavailable iPad-capable app shown again"
        )
        #expect(filter.isActive(iPad: true))
    }

    @Test func choicesPersist() throws {
        let suite = "ltm-store-filter-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CatalogFilter.load(defaults) == CatalogFilter(), "fresh defaults: all apps, unavailable shown")
        CatalogFilter(iPadOnly: true, showUnavailable: false).save(defaults)
        #expect(CatalogFilter.load(defaults) == CatalogFilter(iPadOnly: true, showUnavailable: false))
        CatalogFilter(iPadOnly: true, showUnavailable: true).save(defaults)
        #expect(CatalogFilter.load(defaults) == CatalogFilter(iPadOnly: true, showUnavailable: true))
    }
}
