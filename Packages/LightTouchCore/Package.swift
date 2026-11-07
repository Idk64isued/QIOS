// swift-tools-version: 6.2
// LightTouchCore: the app's logic that needs no window: the device library and catalog, device records and boot
// pieces, the install and media pipelines, capture naming, the session's state machines and the input and zoom
// math. The app links it; LightTouchCoreTests (Swift Testing) is the Unit test plan's suite. Built like the app:
// MainActor by default with approachable concurrency. What it reads out of guest and media bytes goes through
// swift-binary-parsing's ParserSpan, as FirmwareKit's readers do.
import PackageDescription

let settings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility")
]

let package = Package(
    name: "LightTouchCore",
    platforms: [.macOS("14.4")],
    products: [.library(name: "LightTouchCore", type: .static, targets: ["LightTouchCore"])],
    dependencies: [
        .package(path: "../HostRuntime"),
        .package(path: "../FirmwareKit"),
        .package(path: "../DeviceServices"),
        .package(path: "../DeviceRuntime"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.2"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3"),
        .package(url: "https://github.com/apple/swift-binary-parsing.git", exact: "0.0.4")
    ],
    targets: [
        .target(
            name: "LightTouchCore",
            dependencies: [
                .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "FirmwareSchema", package: "FirmwareKit"),
                .product(name: "HostServiceWire", package: "DeviceServices"),
                .product(name: "HostServiceClient", package: "DeviceServices"),
                .product(name: "DeviceRuntime", package: "DeviceRuntime"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "BinaryParsing", package: "swift-binary-parsing")
            ],
            swiftSettings: settings
        ),
        // Gives each test process a private home and app state before any test runs.
        .target(name: "TestIsolation", path: "Tests/TestIsolation"),
        // The tests stay in the Swift 5 language mode for now (their fixtures share state across threads by design).
        .testTarget(
            name: "LightTouchCoreTests",
            dependencies: ["LightTouchCore", "TestIsolation", .product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: settings + [.swiftLanguageMode(.v5)]
        )
    ],
    swiftLanguageModes: [.v6]
)
