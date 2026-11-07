import BuildSupport
import Foundation
import Testing

@testable import BuildTools

/// Archive integrity and source staging, without network or a dependency build.
struct DependencySourcesTests {
    let content = Data("fixed source archive contents".utf8)

    func fixture(_ body: (URL, URL, URL) throws -> Void) throws {
        let root = url(MergeNative.real(files.temporaryDirectory.path)).appendingPathComponent(
            "dependency-sources-\(UUID().uuidString)"
        )
        let cache = root.appendingPathComponent("archive cache")
        let manifest = root.appendingPathComponent("dependencies.json")
        try files.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { remove(root) }
        try writeJSON(
            [
                "schema_version": 1,
                "packages": [
                    [
                        "name": "example", "groups": ["native"], "archive": "example-1.tar.gz",
                        "cache_aliases": ["example.tar.gz"], "url": "https://example.invalid/source.tar.gz",
                        "sha256": sha256Hex(content)
                    ]
                ]
            ],
            to: manifest
        )
        try body(root, cache, manifest)
    }

    func failure(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch { return "\(error)" }
    }

    @Test func cachedArchivesAreVerifiedNeverReplacedByTheNetwork() throws {
        try fixture { root, cache, manifest in
            let destination = root.appendingPathComponent("sources")
            func fetch(
                offline: Bool = true,
                download: @escaping (String, URL) throws -> Void = { _, _ in Issue.record("downloaded") }
            ) -> String? {
                failure {
                    try DependencySources.fetch(
                        manifest: manifest,
                        group: "native",
                        destination: destination,
                        caches: [cache],
                        offline: offline,
                        download: download
                    )
                }
            }
            #expect(fetch()?.contains("offline source missing") == true)
            try Data("corrupted cached bytes".utf8).write(to: cache.appendingPathComponent("example.tar.gz"))
            #expect(
                fetch(offline: false)?.contains("SHA-256 mismatch") == true,
                "a bad cache must fail, not fall back to the network"
            )
            #expect(!files.fileExists(atPath: destination.appendingPathComponent("example-1.tar.gz").path))
            try content.write(to: cache.appendingPathComponent("example.tar.gz"))
            #expect(fetch() == nil)
            #expect(try Data(contentsOf: destination.appendingPathComponent("example-1.tar.gz")) == content)
            let record = try readJSON(destination.appendingPathComponent("native-sources.json"))
            #expect(
                (record["packages"] as? [[String: Any]])?.first?["obtained_from"] as? String
                    == cache.appendingPathComponent("example.tar.gz").path
            )
            try Data("modified since last fetch".utf8).write(to: destination.appendingPathComponent("example-1.tar.gz"))
            #expect(fetch()?.contains("SHA-256 mismatch") == true, "an existing archive is verified again")
            remove(destination)
            remove(cache.appendingPathComponent("example.tar.gz"))
            #expect(
                fetch(offline: false) { _, to in try Data("wrong download".utf8).write(to: to) }?.contains(
                    "SHA-256 mismatch"
                ) == true
            )
            #expect((try? files.contentsOfDirectory(atPath: destination.path)) == [], "a bad download is removed")
        }
    }

    @Test func stagingKeepsEditsAndRefusesUntrackedSource() throws {
        try fixture { root, _, _ in
            let repository = root.appendingPathComponent("repository")
            try files.createDirectory(at: repository, withIntermediateDirectories: true)
            func git(_ arguments: String...) throws -> String {
                try output(["git", "-C", repository.path] + arguments)
            }
            _ = try git("init", "-q")
            try "*.o\nbuild/\n".write(
                to: repository.appendingPathComponent(".gitignore"),
                atomically: true,
                encoding: .utf8
            )
            try "original source\n".write(
                to: repository.appendingPathComponent("main.c"),
                atomically: true,
                encoding: .utf8
            )
            try Data("metadata".utf8).write(to: repository.appendingPathComponent(".DS_Store"))
            _ = try git("add", ".")
            _ = try git(
                "-c",
                "user.name=Source test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-qm",
                "fixture"
            )
            try "current edited source\n".write(
                to: repository.appendingPathComponent("main.c"),
                atomically: true,
                encoding: .utf8
            )
            try Data("stale build product".utf8).write(to: repository.appendingPathComponent("main.o"))
            let staged = root.appendingPathComponent("staged")
            let record = root.appendingPathComponent("staged.json")
            try DependencySources.stageGit(source: repository, destination: staged, record: record)
            #expect(
                try String(contentsOf: staged.appendingPathComponent("main.c"), encoding: .utf8)
                    == "current edited source\n"
            )
            for absent in ["main.o", ".git", ".DS_Store"] {
                #expect(!files.fileExists(atPath: staged.appendingPathComponent(absent).path), "\(absent)")
            }
            let written = try readJSON(record)
            #expect(written["modified"] as? Bool == true)
            #expect(written["commit"] as? String == (try git("rev-parse", "HEAD")))
            try "untracked source\n".write(
                to: repository.appendingPathComponent("new-feature.c"),
                atomically: true,
                encoding: .utf8
            )
            let again = root.appendingPathComponent("staged-2")
            #expect(
                failure { try DependencySources.stageGit(source: repository, destination: again, record: record) }?
                    .contains("new-feature.c") == true
            )
            #expect(!files.fileExists(atPath: again.path))
        }
    }

    @Test func noteNamesTheArchiveAndPatches() throws {
        try fixture { _, _, manifest in
            let note = try DependencySources.note(manifest: manifest, name: "example", patches: ["a.patch"])
            #expect(note.hasPrefix("example : https://example.invalid/source.tar.gz\nSHA256: \(sha256Hex(content))\n"))
            #expect(note.hasSuffix("Patches: a.patch (in this directory), applied with patch -p1"))
        }
    }

    /// dependencies.json is the Swift packages' license and provenance ledger, and their one set of pins: every package
    /// a committed Package.resolved pins (the project's, which Xcode and scripts/ship use, and each package's own, for
    /// `swift build`) has a record at that version; every remote package of every manifest and of the project is
    /// pinned exactly (no ranges) at its record's version; and each manifest that pins one is named in its record.
    @Test func theLedgerRecordsEverySwiftPackageAndWhereItIsPinned() throws {
        let repository = URL(fileURLWithPath: #filePath).appendingPathComponent("../../../../..").standardized
        let records = Dictionary(
            (try readJSON(repository.appendingPathComponent("build-support/dependencies.json"))["packages"]
                as? [[String: Any]] ?? []).map { (($0["name"] as? String ?? "").lowercased(), $0) },
            uniquingKeysWith: { a, _ in a }
        )
        func tracked(_ pattern: String) throws -> [String] {
            let listed = try Shell.run(["git", "ls-files", pattern], directory: repository)
            try #require(listed.succeeded, "\(listed.error)")
            return listed.output.split(separator: "\n").map(String.init)
        }
        let resolvedFiles = try tracked("*Package.resolved")
        #expect(
            resolvedFiles.contains("LightTouchMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
        for file in resolvedFiles {
            for pin in try readJSON(repository.appendingPathComponent(file))["pins"] as? [[String: Any]] ?? [] {
                let identity = pin["identity"] as? String ?? ""
                let version = (pin["state"] as? [String: Any])?["version"] as? String
                #expect(records[identity]?["version"] as? String == version, "\(file): \(identity) \(version ?? "")")
            }
        }
        let project = try String(
            contentsOf: repository.appendingPathComponent("LightTouchMac.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let references = project.matches(
            of: /isa = XCRemoteSwiftPackageReference;\s*repositoryURL = "([^"]+)";\s*requirement = \{([^}]*)\}/
        )
        #expect(references.count == project.matches(of: /isa = XCRemoteSwiftPackageReference;/).count)
        for reference in references {
            let name = String(reference.1.split(separator: "/").last ?? "").replacingOccurrences(of: ".git", with: "")
            let version = reference.2.firstMatch(of: /version = ([^;\s]+);/).map { String($0.1) }
            #expect(reference.2.contains("kind = exactVersion;"), "the project pins \(name) with a range")
            #expect(records[name.lowercased()]?["version"] as? String == version, "the project: \(name)")
        }
        let manifests = try tracked("*Package.swift")
        #expect(manifests.count >= 10, "\(manifests)")
        let pinned = /\.package\(url: "[^"]*\/([^\/"]+?)(?:\.git)?", exact: "([^"]+)"\)/
        for manifest in manifests {
            let text = try String(contentsOf: repository.appendingPathComponent(manifest), encoding: .utf8)
            #expect(
                text.matches(of: pinned).count == text.matches(of: /\.package\(\s*url:/).count,
                "\(manifest): a remote package pinned other than exact:"
            )
            for match in text.matches(of: pinned) {
                let record = records[String(match.1).lowercased()]
                #expect(record?["version"] as? String == String(match.2), "\(manifest): \(match.1) \(match.2)")
                #expect(
                    (record?["checksum_source"] as? String)?.contains(manifest) == true,
                    "\(match.1)'s record doesn't name \(manifest)"
                )
            }
        }
    }
}
