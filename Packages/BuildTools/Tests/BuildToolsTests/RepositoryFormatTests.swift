import BuildSupport
import Foundation
import Testing

/// The checkout as a whole: formatted and lint-clean, its build reading nothing of Homebrew's, and the scripts' shell
/// tests passing.
struct RepositoryFormatTests {
    static let repository = URL(fileURLWithPath: #filePath).appendingPathComponent("../../../../..").standardized

    /// `scripts/format --check` over every tracked file.
    @Test func everyTrackedFileIsFormattedAndLintClean() throws {
        let check = try Shell.run(["/bin/bash", "scripts/format", "--check"], directory: Self.repository)
        #expect(check.succeeded, "scripts/format these; fix what lint names:\n\(check.output)\(check.error)")
    }

    /// What defines the build (manifests, the project, the xcconfigs, the scripts and recipes) and what checks it (the
    /// build tools, and the release checks, whose bundle tools run on the system's PATH only) names no Homebrew or
    /// /usr/local path: headers and libraries come from the vendor directory, so a Mac's Homebrew can't leak in.
    @Test func theBuildReadsNothingOfHomebrews() throws {
        let found = try Shell.run(
            [
                "git", "grep", "-n", "-E", "/opt/homebrew|/usr/local", "--", "*Package.swift",
                "*.pbxproj", "*.xcconfig", "*.xctestplan", "scripts", "build-support",
                "Packages/BuildTools/Sources", "Packages/ReleaseChecks/Sources"
            ],
            directory: Self.repository
        )
        #expect(found.status == 1 && found.output.isEmpty, "\(found.output)\(found.error)")
    }

    /// Each of tests/scripts/*.sh (ok/FAIL per case, exit 1 on any FAIL), so the Unit plan runs them.
    @Test(
        arguments: try FileManager.default.contentsOfDirectory(
            atPath: repository.appendingPathComponent("tests/scripts").path
        ).filter { $0.hasSuffix(".sh") }.sorted())
    func scriptTests(_ name: String) throws {
        let run = try Shell.run(["/bin/bash", "tests/scripts/\(name)"], directory: Self.repository)
        let failures = run.output.split(separator: "\n").filter { $0.hasPrefix("FAIL") }
        #expect(
            run.succeeded, "\(name) exited \(run.status):\n\(failures.joined(separator: "\n"))\(run.error.suffix(800))")
    }
}
