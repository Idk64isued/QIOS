// swift-tools-version: 6.0
// ltm-device-access: developer SSH, SFTP and GDB for one device instance (README.md).
import PackageDescription

let package = Package(
    name: "DeviceAccess",
    platforms: [.macOS("14.4")],
    dependencies: [.package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2")],
    targets: [
        .executableTarget(
            name: "device-access",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]
        )
    ]
)
