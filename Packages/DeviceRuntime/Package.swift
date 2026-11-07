// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeviceRuntime",
    platforms: [.macOS(.v13)],
    products: [.library(name: "DeviceRuntime", type: .static, targets: ["DeviceRuntime"])],
    dependencies: [.package(path: "../HostRuntime")],
    targets: [
        .target(name: "LTMLinkC", publicHeadersPath: "."),
        .target(name: "DeviceRuntime", dependencies: ["HostRuntime", "LTMLinkC"]),
        .executableTarget(name: "RendezvousTestPeer", dependencies: ["LTMLinkC"]),
        .testTarget(name: "DeviceRuntimeTests", dependencies: ["DeviceRuntime", "RendezvousTestPeer"])
    ]
)
