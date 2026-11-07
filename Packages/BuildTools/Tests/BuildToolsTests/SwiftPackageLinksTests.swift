import Foundation
import Testing

@testable import BuildTools

/// What SwiftPackageLinks counts as linked, over manifests shaped as dump-package writes them.
struct SwiftPackageLinksTests {
    static func target(_ name: String, _ type: String = "regular", deps: [[String: Any]] = []) -> [String: Any] {
        ["name": name, "type": type, "dependencies": deps]
    }
    static func manifest(_ targets: [[String: Any]], products: [(String, [String])] = [], deps: [String] = [])
        -> [String: Any]
    {
        [
            "targets": targets,
            "products": products.map { ["name": $0.0, "targets": $0.1] as [String: Any] },
            "dependencies": deps.map { ["sourceControl": [["identity": $0]]] }
        ]
    }

    @Test func macrosPluginsTestsAndUnusedProductsLinkNothing() {
        let manifests: [String: [String: Any]] = [
            "root": Self.manifest(
                [
                    Self.target(
                        "Kit",
                        deps: [["product": ["Parsing", "swift-parsing", nil, nil]], ["byName": ["Small", nil]]]
                    ),
                    Self.target("KitTests", "test", deps: [["byName": ["Testing", nil]]])
                ],
                deps: ["swift-parsing", "small", "testing"]
            ),
            "swift-parsing": Self.manifest(
                [
                    Self.target("Parsing", deps: [["byName": ["ParsingMacros", nil]]]),
                    Self.target("ParsingMacros", "macro", deps: [["product": ["Syntax", "swift-syntax", nil, nil]]]),
                    Self.target("Tool", "executable", deps: [["product": ["Args", "swift-args", nil, nil]]])
                ],
                products: [("Parsing", ["Parsing"]), ("tool", ["Tool"])],
                deps: ["swift-syntax", "swift-args"]
            ),
            "small": Self.manifest([Self.target("Small")], products: [("Small", ["Small"])]),
            "testing": Self.manifest([Self.target("Testing")], products: [("Testing", ["Testing"])]),
            "swift-syntax": Self.manifest([Self.target("Syntax")], products: [("Syntax", ["Syntax"])]),
            "swift-args": Self.manifest([Self.target("Args")], products: [("Args", ["Args"])]),
            "sparkle": Self.manifest([Self.target("Sparkle")], products: [("Sparkle", ["Sparkle"])])
        ]
        #expect(
            SwiftPackageLinks.linked(roots: ["root"], direct: ["sparkle"], manifests: manifests)
                == ["root", "swift-parsing", "small", "sparkle"]
        )
    }

    /// LightTouchDevice loads the GPL-2.0-only emulator, so the local packages it links take no remote package (an
    /// Apache-2.0 one such as swift-crypto can't be linked beside GPL-2.0-only code).
    @Test func theHelpersPackagesTakeNoRemotePackage() throws {
        let repository = URL(fileURLWithPath: #filePath).appendingPathComponent("../../../../..").standardized
        for name in ["DeviceRuntime", "HostRuntime"] {
            let path = repository.appendingPathComponent("Packages/\(name)").path
            let json = try output(["swift", "package", "dump-package", "--package-path", path])
            let manifest = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            let remote = (manifest?["dependencies"] as? [[String: Any]] ?? []).filter { $0["sourceControl"] != nil }
            #expect(manifest != nil && remote.isEmpty, "\(name) takes remote packages: \(remote)")
        }
    }
}
