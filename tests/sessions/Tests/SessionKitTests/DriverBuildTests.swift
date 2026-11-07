import Foundation
import Testing

@testable import SessionKit

/// A driver beside sessions in the package's own build is rebuilt in that build's configuration; a copy elsewhere
/// is left as it is.
struct DriverBuildTests {
    let package = URL(fileURLWithPath: "/repo/tests/sessions")

    @Test func aDriverInThePackagesBuildIsBuiltInItsConfiguration() {
        let debug = package.appendingPathComponent(".build/out/Products/Debug")
        #expect(
            DriverBuild.arguments(product: "helper-driver", bin: debug, package: package)
                == ["build", "--package-path", "/repo/tests/sessions", "--product", "helper-driver"]
        )
        let release = package.appendingPathComponent(".build/arm64-apple-macosx/release")
        #expect(
            DriverBuild.arguments(product: "session-driver", bin: release, package: package)?.suffix(2)
                == ["-c", "release"]
        )
        let copy = URL(fileURLWithPath: "/tmp/bin")
        #expect(DriverBuild.arguments(product: "helper-driver", bin: copy, package: package) == nil)
    }
}
