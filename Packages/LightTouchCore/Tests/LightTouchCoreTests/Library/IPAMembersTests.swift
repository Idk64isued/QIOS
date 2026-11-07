import Testing

@testable import LightTouchCore

/// An archive's app is its one Payload/<name>.app; a nested .app never wins, and two (or a repeated) root apps
/// are no identity at all (IPAMembers).
struct IPAMembersTests {
    @Test func uniqueRootApp() {
        #expect(
            IPAMembers.appRoot(["Payload/One.app/Info.plist", "Payload/One.app/Nested.app/Info.plist"])
                == "Payload/One.app/"
        )
        #expect(IPAMembers.appRoot(["Payload/One.app/Info.plist", "Payload/Two.app/Info.plist"]) == nil)
        #expect(IPAMembers.appRoot(["Elsewhere.app/Info.plist"]) == nil)
        #expect(IPAMembers.appRoot(["Payload/One.app/Info.plist", "Payload/One.app/Info.plist"]) == nil)
    }
}
