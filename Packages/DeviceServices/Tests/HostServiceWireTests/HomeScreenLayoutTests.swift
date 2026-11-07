import Testing

@testable import HostServiceWire

/// Flatten and rebuild are exact inverses, and a rebuild keeps every page and the dock at the size it already
/// was: getting this wrong scrambles somebody's Home screen.
struct HomeScreenLayoutTests {
    let dock: [Any] = [["displayIdentifier": "com.apple.mobilemusic"]]
    let page: [Any] = [
        ["displayIdentifier": "com.apple.MobileAddressBook"],
        ["displayIdentifier": "com.shazam.Shazam"],
        ["displayIdentifier": "com.condenet.Epicurious"]
    ]
    var state: [Any] { [dock, page] }

    @Test func flattenReadsDockThenPages() {
        #expect(
            HomeScreenLayout.flatten(state) == [
                "com.apple.mobilemusic", "com.apple.MobileAddressBook",
                "com.shazam.Shazam", "com.condenet.Epicurious"
            ]
        )
    }

    @Test func folderChildrenAreFlattened() {
        let folder: [Any] = [
            ["displayName": "Games", "iconLists": [[["displayIdentifier": "a.b"], ["displayIdentifier": "c.d"]]]]
        ]
        #expect(HomeScreenLayout.flatten([dock, folder]) == ["com.apple.mobilemusic", "a.b", "c.d"])
    }

    @Test func rebuildInvertsFlatten() {
        #expect(
            HomeScreenLayout.flatten(HomeScreenLayout.rebuild(state, order: HomeScreenLayout.flatten(state)))
                == HomeScreenLayout.flatten(state)
        )
    }

    @Test func moveKeepsPageSizes() {
        var ids = HomeScreenLayout.flatten(state)
        ids.removeAll { $0 == "com.condenet.Epicurious" }
        ids.insert("com.condenet.Epicurious", at: ids.firstIndex(of: "com.shazam.Shazam")!)
        let moved = HomeScreenLayout.rebuild(state, order: ids)
        #expect(
            HomeScreenLayout.flatten(moved) == [
                "com.apple.mobilemusic", "com.apple.MobileAddressBook",
                "com.condenet.Epicurious", "com.shazam.Shazam"
            ]
        )
        #expect((moved[0] as? [Any])?.count == 1)
        #expect((moved[1] as? [Any])?.count == 3)
    }
}
