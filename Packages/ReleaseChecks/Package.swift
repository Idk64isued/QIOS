// swift-tools-version: 6.0
// Checks of a built Light Touch.app (an archive's or an export's): signatures and entitlements per executable,
// slices and the dylib load closure, bundle hygiene, the bundled helper and services worker, and boots through the
// bundle. ReleaseChecksTests runs the fixture halves always (Unit plan) and the app halves in Release.xctestplan,
// which takes the app from LTM_RELEASE_APP or LTM_RELEASE_ARCHIVE (see CONTRIBUTING, Releases).
import PackageDescription

let package = Package(
    name: "ReleaseChecks",
    platforms: [.macOS("14.4")],
    products: [.library(name: "ReleaseChecks", targets: ["ReleaseChecks"])],
    // HostRuntime (local): the tests start the bundled helper with its HelperLaunch. BuildTools (local): BuildSupport's
    // command runner, SHA-256 and MachOClosure, which scripts/vendor's native builds are checked with too.
    dependencies: [.package(path: "../HostRuntime"), .package(path: "../BuildTools")],
    targets: [
        .target(name: "ReleaseChecks", dependencies: [.product(name: "BuildSupport", package: "BuildTools")]),
        .testTarget(
            name: "ReleaseChecksTests",
            dependencies: [
                "ReleaseChecks", .product(name: "BuildSupport", package: "BuildTools"),
                .product(name: "HostRuntime", package: "HostRuntime")
            ]
        )
    ]
)
