// swift-tools-version: 6.0
// The build's own tools (scripts/ltm-build runs them): scripts/vendor (with HostRuntime's machine options from the
// vendored QEMU), the Mach-O closure check of the native builds (BuildSupport's MachOClosure), the universal merge of
// per-architecture native roots, the pinned dependency sources (fetch, stage-git, note) with the native and static
// build records, and scripts/ship's release checks (catalog, Amore id, appcast). BuildSupport (the command runner, the
// SHA-256 and MachOClosure) is shared with ReleaseChecks and tests/sessions; it lives here so that the vendor key
// (scripts/vendor-check: build-support plus this package) covers everything the build tools run.
import PackageDescription

let package = Package(
    name: "BuildTools",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "ltm-build", targets: ["ltm-build"]),
        .library(name: "BuildSupport", targets: ["BuildSupport"])
    ],
    dependencies: [.package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2")],
    targets: [
        .target(name: "BuildSupport"),
        .target(name: "BuildTools", dependencies: ["BuildSupport"]),
        .executableTarget(
            name: "ltm-build",
            dependencies: ["BuildTools", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(
            name: "BuildToolsTests",
            dependencies: ["BuildTools", "BuildSupport"]
        )
    ]
)
