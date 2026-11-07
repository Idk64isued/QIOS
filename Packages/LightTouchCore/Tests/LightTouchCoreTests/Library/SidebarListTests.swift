import Foundation
import Testing

@testable import LightTouchCore

/// The sidebar's list (SidebarList) over the shipped catalog: which entries it shows, in what order, what each row
/// says, what persists, and which rows may leave it.
struct SidebarListTests {
    let catalog = ShippedResources.catalog
    func entry(_ id: String) -> FirmwareCatalog.Entry { catalog.entry(id: id)! }
    static let iPod2G = "iPod touch (2nd generation)"

    func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "ltm-sidebar-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    /// No saved list: a fresh install gets first_run, an updating user the entries they own; once saved (even empty)
    /// the list rules, and ids the catalog dropped or marks coming_soon are skipped.
    @Test func migrationAndPersistence() {
        withDefaults { defaults in
            var list = SidebarList.load(defaults, catalog: catalog) { _ in false }
            #expect(list.ids == ["k48ap-7B500"], "fresh install")
            #expect(defaults.stringArray(forKey: SidebarList.entriesKey) == ["k48ap-7B500"], "fresh install not saved")
            defaults.removeObject(forKey: SidebarList.entriesKey)
            let owned: Set = ["n72ap-7E18", "n72ap-8B117", "k48ap-8C148"]
            list = SidebarList.load(defaults, catalog: catalog) { owned.contains($0.id) }
            #expect(
                list.entries(in: catalog).map(\.id) == ["k48ap-8C148", "n72ap-7E18", "n72ap-8B117"],
                "migration keeps what the user owns"
            )
            list.remove("n72ap-7E18")
            list.save(defaults)
            list = SidebarList.load(defaults, catalog: catalog) { owned.contains($0.id) }
            #expect(Set(list.ids) == ["k48ap-8C148", "n72ap-8B117"], "a removed owned entry came back")
            SidebarList(ids: []).save(defaults)
            #expect(SidebarList.load(defaults, catalog: catalog) { _ in true }.ids.isEmpty, "empty list refilled")
            let soon = catalog.entries.first { $0.status == .comingSoon }!.id
            SidebarList(ids: ["n72ap-gone", "n72ap-8C148", soon], names: ["n72ap-gone": "Old", soon: "Soon"]).save(
                defaults
            )
            list = SidebarList.load(defaults, catalog: catalog) { _ in false }
            #expect(list.ids == ["n72ap-8C148"] && list.names.isEmpty, "stale or coming_soon ids")
        }
    }

    /// Added backwards and interleaved, listed per board in version order, betas before the release.
    @Test func order() {
        var list = SidebarList()
        list.add(["n72ap-8C148", "n72ap-8B117", "k48ap-7B500", "n72ap-8B5080c", "n72ap-5F138", "k48ap-7B367"])
        #expect(list.add(["n72ap-8B117"]) == false, "added twice")
        #expect(
            list.entries(in: catalog).map(\.id) == [
                "k48ap-7B367", "k48ap-7B500", "n72ap-5F138", "n72ap-8B5080c", "n72ap-8B117", "n72ap-8C148"
            ]
        )
    }

    /// Always two lines, the marketing name over the version and its badge, whatever else is listed.
    @Test func titles() {
        var list = SidebarList(ids: ["n72ap-8B117", "n72ap-8B5080c"])
        #expect(list.label(for: entry("n72ap-8B117")) == .init(title: Self.iPod2G, subtitle: "iOS 4.1"))
        #expect(list.label(for: entry("n72ap-8B5080c")) == .init(title: Self.iPod2G, subtitle: "iOS 4.1 beta 1"))
        list.add(["k48ap-7B500", "n45ap-4B1"])
        #expect(
            list.label(for: entry("n72ap-8B117")) == .init(title: Self.iPod2G, subtitle: "iOS 4.1"),
            "a mixed list changed the label"
        )
        #expect(list.label(for: entry("k48ap-7B500")) == .init(title: "iPad", subtitle: "iOS 3.2.2"))
        #expect(list.label(for: entry("n45ap-4B1")) == .init(title: "iPod touch", subtitle: "iOS 1.1.5"))
        let gm = list.label(for: entry("k48ap-8C134")).subtitle
        #expect(gm.hasPrefix("iOS 4.2") && gm.hasSuffix(" GM 1"))
    }

    /// The name over "<identifier>, iOS x.y <badge>"; saved and read back; an empty name or the default title clears
    /// it; removing forgets it.
    @Test func rename() {
        withDefaults { defaults in
            var list = SidebarList(ids: ["n72ap-8B117", "n72ap-8B5080c", "k48ap-7B500"])
            list.rename("n72ap-8B117", to: "  Test Rig ", defaultTitle: Self.iPod2G)
            #expect(
                list.label(for: entry("n72ap-8B117")) == .init(title: "Test Rig", subtitle: "\(Self.iPod2G), iOS 4.1")
            )
            list.rename("n72ap-8B5080c", to: "Beta Rig", defaultTitle: Self.iPod2G)
            #expect(
                list.label(for: entry("n72ap-8B5080c"))
                    == .init(title: "Beta Rig", subtitle: "\(Self.iPod2G), iOS 4.1 beta 1")
            )
            list.rename("n72ap-8B5080c", to: "", defaultTitle: Self.iPod2G)
            list.remove("k48ap-7B500")
            list.save(defaults)
            var reloaded = SidebarList.load(defaults, catalog: catalog) { _ in false }
            #expect(reloaded.names == ["n72ap-8B117": "Test Rig"] && reloaded == list, "names not persisted")
            reloaded.rename("n72ap-8B117", to: Self.iPod2G, defaultTitle: Self.iPod2G)
            #expect(reloaded.names.isEmpty, "the default title became a custom name")
            reloaded.rename("n72ap-8B5080c", to: "Beta", defaultTitle: Self.iPod2G)
            reloaded.rename("n72ap-8B5080c", to: "   ", defaultTitle: Self.iPod2G)
            #expect(reloaded.names.isEmpty, "an empty name kept")
            reloaded.rename("n72ap-8B117", to: "X", defaultTitle: Self.iPod2G)
            reloaded.remove("n72ap-8B117")
            reloaded.add(["n72ap-8B117"])
            #expect(reloaded.names.isEmpty, "a removed row kept its name")
        }
    }

    /// A prepared device's row says Delete Device… (asks, through delete); others say Remove Device; nothing running
    /// or in flight can leave; a deleting row offers nothing.
    @Test func removal() {
        let e = entry("n72ap-8B117")
        func row(_ instance: UUID?, session: SessionPhase? = nil, job: FirmwareJob? = nil, downloaded: Bool = false)
            -> DeviceRow
        {
            DeviceRow(entry: e, instanceID: instance, session: session, job: job, downloaded: downloaded)
        }
        let prepared = row(UUID())
        #expect(prepared.removeTitle == "Delete Device…" && prepared.canRemoveFromSidebar)
        #expect(
            row(nil).removeTitle == "Remove Device" && row(nil).canRemoveFromSidebar
                && row(nil, downloaded: true).canRemoveFromSidebar
        )
        #expect(!row(UUID(), session: .running).canRemoveFromSidebar, "a running device left the sidebar")
        #expect(
            !row(nil, job: .downloading(fraction: 0.3)).canRemoveFromSidebar,
            "a download in flight left the sidebar"
        )
        #expect(
            !row(nil, job: .preparing(Preparation(name: "x"))).canRemoveFromSidebar,
            "a preparation in flight left the sidebar"
        )
        let deleting = DeviceRow(entry: e, instanceID: UUID(), session: nil, job: nil, busy: .deleting)
        #expect(
            deleting.state == .deleting && deleting.accessory == .stopping && deleting.stateDescription == "Deleting"
        )
        #expect(
            DeviceAction.allCases.allSatisfy { !deleting.allows($0, canDownload: true) }
                && deleting.primaryAction == nil
                && !deleting.canRemoveFromSidebar,
            "a deleting row offers an action"
        )
        // A device with no session being erased (state audit A-9): the row says so and offers nothing that touches
        // its storage (Start, Erase, Delete) until the erase ends; it can still be shown in Finder.
        let erasing = DeviceRow(entry: e, instanceID: UUID(), session: nil, job: nil, busy: .erasing)
        #expect(
            erasing.state == .erasing && erasing.accessory == .stopping && erasing.stateDescription == "Erasing"
                && erasing.primaryAction == nil && !erasing.canRemoveFromSidebar
        )
        #expect(DeviceAction.allCases.filter { erasing.allows($0, canDownload: true) } == [.showInFinder])
    }
}
