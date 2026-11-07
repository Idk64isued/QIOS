import Foundation
import Testing

@testable import LightTouchCore

/// The Store's version sheet (CatalogDetailsModel) against recorded Legacy Store answers (tests/fixtures/store-filter).
extension SharedState {
    @Suite struct CatalogDetailsModelTests {
        /// The recorded version lists, copy records and the emulator endpoint's answer for 207203.
        nonisolated static let server: @Sendable (URLComponents) -> LegacyStoreStub.Reply = { request in
            var name: String? = [
                "/api/v1/apps/com.playfirst.hoteldash/versions": "versions-hoteldash.json",
                "/api/v1/apps/com.secondarm.taptapdash/versions": "versions-taptapdash.json"
            ][request.path]
            if request.path.hasPrefix("/api/v1/copies/") {
                name = "copy-" + request.path.split(separator: "/").last! + ".json"
            }
            if request.path == "/api/emulator/apps", request.items["ipa_id"] == "207203" {
                name = "emulator-207203.json"
            }
            guard let name, FileManager.default.fileExists(atPath: fixture("store-filter/" + name).path) else {
                return .error(404)
            }
            return .file(fixture("store-filter/" + name))
        }

        @Test func compatibleCopyOnTheIPod() async throws {
            let hotel = try CatalogFilterTests.apps("ipod2-3.1.3-dash.json").first { $0.name == "Hotel Dash" }!
            try await withTemporaryState { state in
                await LegacyStoreStub.serving(state: state, Self.server) {
                    var installed: Int?
                    var closed = false
                    let model = CatalogDetailsModel(
                        app: hotel,
                        device: "iPod2,1",
                        deviceOS: "3.1.3",
                        arch: "armv6",
                        installedVersion: "1.10.3",
                        canInstall: { true },
                        install: { installed = $0.ipaID }
                    )
                    model.close = { closed = true }
                    await model.load()
                    let rows = model.rows ?? []
                    #expect(
                        rows.count == 7 && rows.allSatisfy { $0.copy.architectures?.contains("armv6") == true },
                        "\(rows.map(\.copy.ipaID))"
                    )
                    #expect(model.selection == "207203", "the row's own copy selected")
                    let own = rows.first { $0.copy.ipaID == "207203" }!
                    let twin = rows.first { $0.copy.ipaID == "5635" }!
                    #expect(model.title(own) == "1.1.51, 65.6 MB")
                    #expect(model.title(twin).hasSuffix(", Copy 5635"), "twin copies are numbered")
                    await model.check()
                    #expect(model.problem == nil && model.canInstallSelection, "\(model.problem ?? "")")
                    #expect(
                        model.downgradeNote == "Version 1.10.3 is installed. An older version may not read its data."
                    )
                    model.installSelection()
                    #expect(installed == 207203 && closed, "Install fetches the revalidated copy and closes the sheet")
                }
            }
        }

        @Test func arm64OnlyAppOnTheIPad() async throws {
            let dash = try CatalogFilterTests.apps("search-86286-ipad1-4.2.1.json")[0]
            try await withTemporaryState { state in
                await LegacyStoreStub.serving(state: state, Self.server) {
                    var installs = 0
                    let model = CatalogDetailsModel(
                        app: dash,
                        device: "iPad1,1",
                        deviceOS: "4.2.1",
                        arch: "armv7",
                        installedVersion: nil,
                        canInstall: { true },
                        install: { _ in installs += 1 }
                    )
                    await model.load()
                    #expect(model.rows?.map(\.copy.ipaID) == ["86286"], "only the row's own copy")
                    await model.check()
                    #expect(model.problem == "This copy needs a newer processor than this device has.")
                    #expect(!model.canInstallSelection && model.downgradeNote == nil)
                    model.installSelection()
                    #expect(installs == 0, "an incompatible copy is never installed")
                }
            }
        }
    }
}
