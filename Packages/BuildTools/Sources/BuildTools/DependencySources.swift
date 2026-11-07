import BuildSupport
import Foundation

/// The pinned dependency archives (build-support/dependencies.json): fetched only through their SHA-256, tracked source
/// staged without build outputs, and the SOURCE.txt a shipped build carries.
public enum DependencySources {
    static func packages(manifest: URL, group: String) throws -> [[String: Any]] {
        let object = try readJSON(manifest)
        guard object["schema_version"] as? Int == 1 else {
            throw ToolError("unsupported source manifest: \(manifest.path)")
        }
        let packages = (object["packages"] as? [[String: Any]] ?? []).filter {
            ($0["groups"] as? [String] ?? []).contains(group)
        }
        guard !packages.isEmpty else { throw ToolError("no sources declared for group \(group)") }
        var names: Set<String> = []
        for package in packages {
            let archive = package["archive"] as? String ?? ""
            for name in [archive] + (package["cache_aliases"] as? [String] ?? [])
            where name.isEmpty || name.contains("/") || name == "." || name == ".." {
                throw ToolError("invalid archive name: \(name)")
            }
            guard names.insert(archive).inserted else { throw ToolError("duplicate archive: \(archive)") }
            let sha = package["sha256"] as? String ?? ""
            guard sha.count == 64, sha.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw ToolError("invalid SHA-256 for \(package["name"] ?? "?")")
            }
            guard (package["url"] as? String ?? "").hasPrefix("https://") else {
                throw ToolError("source URL must use HTTPS: \(package["url"] ?? "")")
            }
        }
        return packages
    }

    static func verify(_ file: URL, _ expected: String) throws {
        let actual = try sha256(file)
        guard actual == expected else {
            throw ToolError("SHA-256 mismatch: \(file.path)\nexpected \(expected)\nactual   \(actual)")
        }
    }

    /// Every archive of `group` into `destination` (verified there, else from a cache, else downloaded unless
    /// `offline`), and `<group>-sources.json` recording where each came from. A corrupt cache fails, never falls back.
    public static func fetch(
        manifest: URL,
        group: String,
        destination: URL,
        caches: [URL],
        offline: Bool,
        download: (String, URL) throws -> Void = curl
    ) throws {
        let packages = try packages(manifest: manifest, group: group)
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        for package in packages {
            guard let archive = package["archive"] as? String, let sha = package["sha256"] as? String,
                let source = package["url"] as? String
            else { throw ToolError("invalid source entry: \(package["name"] ?? "?")") }
            let out = destination.appendingPathComponent(archive)
            var origin = out.path
            if files.fileExists(atPath: out.path) {
                try verify(out, sha)
            } else {
                let names = [archive] + (package["cache_aliases"] as? [String] ?? [])
                let cached = caches.lazy.flatMap { cache in names.map { cache.appendingPathComponent($0) } }
                    .first { files.fileExists(atPath: $0.path) }
                if let cached {
                    try verify(cached, sha)
                } else if offline {
                    throw ToolError("offline source missing: \(archive)")
                }
                let temporary = destination.appendingPathComponent(".download-\(UUID().uuidString)")
                defer { remove(temporary) }
                if let cached {
                    try files.copyItem(at: cached, to: temporary)
                    origin = MergeNative.real(cached.path)
                } else {
                    print("Fetching \(archive)")
                    try download(source, temporary)
                    origin = source
                }
                try verify(temporary, sha)
                try files.moveItem(at: temporary, to: out)
            }
            var record = package
            record["path"] = out.path
            record["obtained_from"] = origin
            records.append(record)
        }
        try writeJSON(
            ["schema_version": 1, "manifest_sha256": try sha256(manifest), "packages": records],
            to: destination.appendingPathComponent("\(group)-sources.json")
        )
    }

    public static func curl(_ address: String, _ to: URL) throws {
        try run([
            "/usr/bin/curl", "--fail", "--location", "--show-error", "--proto", "=https", "--proto-redir", "=https",
            "--output", to.path, address
        ])
    }

    /// The checkout's tracked files (working-tree content, tracked deletions kept) copied into a fresh `destination`,
    /// with a record of the commit and the uncommitted diff. Untracked source refuses: it would silently go missing.
    public static func stageGit(source: URL, destination: URL, record: URL) throws {
        let source = source.resolvingSymlinksInPath()
        guard !files.fileExists(atPath: destination.path) else {
            throw ToolError("use a fresh source destination: \(destination.path)")
        }
        func git(_ arguments: String...) throws -> String {
            try output(["/usr/bin/git", "-C", source.path] + arguments)
        }
        func list(_ text: String) -> [String] { text.split(separator: "\0").map(String.init) }
        let untracked = list(try git("ls-files", "--others", "--exclude-standard", "-z")).filter {
            ($0 as NSString).lastPathComponent != ".DS_Store"
        }
        guard untracked.isEmpty else {
            throw ToolError(
                "\(source.path): untracked files would be omitted; add source to Git first: \(untracked.prefix(10).joined(separator: ", "))"
            )
        }
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        for name in list(try git("ls-files", "-z")).sorted() where (name as NSString).lastPathComponent != ".DS_Store" {
            let original = source.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            // a tracked deletion
            guard let attributes = try? files.attributesOfItem(atPath: original.path) else { continue }
            guard original.resolvingSymlinksInPath().path.hasPrefix(source.path + "/") else {
                throw ToolError("tracked source escapes repository: \(original.path)")
            }
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                throw ToolError("submodule requires an explicit source recipe: \(original.path)")
            }
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: original, to: target)
            let mode = (try files.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) ?? 0
            records.append(["path": name, "sha256": try sha256(target), "executable": mode & 0o111 != 0])
        }
        let diff = try git("diff", "--binary", "HEAD", "--", ".", ":(exclude).DS_Store")
        try writeJSON(
            [
                "schema_version": 1, "source": source.path, "staged_source": destination.path,
                "commit": try git("rev-parse", "HEAD"),
                "tracked_diff_sha256": sha256Hex(Data(diff.utf8)), "modified": !diff.isEmpty, "files": records
            ],
            to: record
        )
    }

    /// SOURCE.txt for a shipped build of a manifest package: the archive, its hash and the patches applied.
    public static func note(manifest: URL, name: String, patches: [String]) throws -> String {
        guard
            let package = (try readJSON(manifest)["packages"] as? [[String: Any]] ?? []).first(where: {
                $0["name"] as? String == name
            })
        else {
            throw ToolError("no package \(name) in \(manifest.path)")
        }
        let applied =
            patches.isEmpty ? "none" : patches.joined(separator: ", ") + " (in this directory), applied with patch -p1"
        return
            "\(name) \(package["version"] ?? ""): \(package["url"] ?? "")\nSHA256: \(package["sha256"] ?? "")\nPatches: \(applied)"
    }
}
