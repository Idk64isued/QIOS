import Foundation
import Testing

@testable import SessionKit

/// `sessions affected`: which family rows a change boots. Unsure routes to every family, never to no boot.
struct AffectedTests {
    static let every: Set<String> = ["m68ap", "n45ap", "n72ap", "k48ap", "n81ap", "n88ap", "n90ap"]

    @Test func placesEachKindOfPath() {
        #expect(Affected.boards(for: "README.md") == [])
        #expect(Affected.boards(for: "LightTouchMac/UI/DisplayView.swift") == nil)
        #expect(Affected.boards(for: "Packages/FirmwareKit/Tests/FirmwareKitTests/X.swift") == nil)
        // K48Board prepares the iPad, the 3GS and the A4 boards.
        for path in ["K48/K48Recipe.swift", "K48NAND/K48NAND.swift", "KBoot/KBoot.swift"] {
            #expect(
                Affected.boards(for: "Packages/FirmwareKit/Sources/FirmwareKit/" + path)
                    == ["k48ap", "n81ap", "n88ap", "n90ap"]
            )
        }
        #expect(Affected.boards(for: "Packages/FirmwareKit/Sources/FirmwareKit/N45/N45.swift") == ["n45ap", "m68ap"])
        // Boot paths, the emulator's pin, the helper, guest code and anything unknown boot every family.
        for path in [
            "Packages/FirmwareKit/Sources/FirmwareKit/HFSPlus/Writer.swift", "build-support/sources.json",
            "LightTouchDevice/WebProxy.swift", "Packages/HostRuntime/Sources/HostRuntime/BootConfig.swift",
            "Packages/LightTouchCore/Sources/LightTouchCore/Device/GuestAgent.swift",
            "LightTouchMac/Resources/firmware-catalog.json", "tests/sessions/Sources/session-driver/single.swift",
            "somewhere/new.file"
        ] {
            #expect(Affected.boards(for: path) == Self.every, "\(path)")
        }
    }

    @Test func plansTheUnionWithAReasonPerBoard() {
        let plan = Affected.plan(paths: [
            "CONTRIBUTING.md", "LightTouchMac/UI/X.swift", "Packages/FirmwareKit/Sources/FirmwareKit/N72/N72.swift"
        ])
        #expect(plan.boards == ["n72ap"])
        #expect(plan.reasons == ["n72ap": "Packages/FirmwareKit/Sources/FirmwareKit/N72/N72.swift"])
        #expect(plan.unitOnly == ["LightTouchMac/UI/X.swift"])
        #expect(plan.nothing == ["CONTRIBUTING.md"])
    }
}
