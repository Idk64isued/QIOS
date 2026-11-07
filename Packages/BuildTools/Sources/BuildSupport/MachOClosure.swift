import Foundation

/// Every architecture slice's complete macOS load closure (`scripts/ltm-build check-macho` for the native builds):
/// each dependency resolves (through the binary's rpaths and its loaders'), none needs a newer macOS than the app
/// supports, and inside an app none escapes the bundle; optionally, native code has no weak imports.
public enum MachOClosure {
    /// Whether `url` starts with a Mach-O or universal magic number.
    public static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 4) else {
            return false
        }
        try? handle.close()
        return [
            [0xcf, 0xfa, 0xed, 0xfe], [0xce, 0xfa, 0xed, 0xfe], [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca]
        ].contains(Array(head))
    }

    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    public static func architectures(_ path: URL) throws -> [String] {
        let result = try Shell.run(["lipo", "-archs", path.path])
        guard result.succeeded else {
            throw Failure("\(path.path): lipo: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.output.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    struct Metadata { var dependencies: [String] = [], rpaths: [String] = [], minimum: String? }

    static func metadata(_ path: URL, arch: String) throws -> Metadata {
        guard try architectures(path).contains(arch) else { throw Failure("\(path.path): missing \(arch) slice") }
        let listing = try Shell.run(["otool", "-arch", arch, "-l", path.path]).output
        var found = Metadata()
        var other: String?
        for block in listing.components(separatedBy: "Load command ").dropFirst() {
            func field(_ name: String) -> String? {
                block.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { $0.hasPrefix(name + " ") }.map { String($0.dropFirst(name.count + 1)) }
            }
            func named(_ name: String) -> String? { field(name).map { $0.components(separatedBy: " (offset").first! } }
            switch field("cmd") ?? "" {
            case "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB":
                if let name = named("name") { found.dependencies.append(name) }
            case "LC_RPATH":
                if let rpath = named("path") { found.rpaths.append(rpath) }
            case "LC_BUILD_VERSION":
                // a zippered binary (the toolchain's Swift compatibility libraries) also carries Mac Catalyst's
                let platform = field("platform") ?? ""
                if platform == "1" || platform == "MACOS" { found.minimum = field("minos") } else { other = platform }
            case "LC_VERSION_MIN_MACOSX":
                found.minimum = field("version")
            default: break
            }
        }
        if found.minimum == nil, let other { throw Failure("\(path.path): not a macOS binary (platform \(other))") }
        guard found.minimum != nil else { throw Failure("\(path.path): missing macOS deployment target") }
        return found
    }

    static func version(_ text: String) -> [Int] {
        let parts = text.split(separator: ".").map { Int($0) ?? 0 }
        return parts + Array(repeating: 0, count: max(0, 3 - parts.count))
    }

    static func expand(_ path: String, loader: URL, executable: URL) -> URL {
        URL(
            fileURLWithPath: path.replacingOccurrences(of: "@loader_path", with: loader.path)
                .replacingOccurrences(of: "@executable_path", with: executable.path)
        )
    }

    /// The binary's own rpaths for `arch`, as written (scripts/vendor's relink edits them).
    public static func rpaths(_ path: URL, arch: String) throws -> [String] { try metadata(path, arch: arch).rpaths }

    /// The binary's non-system dependencies for `arch`, each with the file it resolves to through the binary's own
    /// rpaths (@loader_path and @executable_path both its directory).
    public static func dependencies(_ path: URL, arch: String) throws -> [(name: String, file: URL)] {
        let meta = try metadata(path, arch: arch)
        let dir = path.deletingLastPathComponent()
        let search = meta.rpaths.map { expand($0, loader: dir, executable: dir) }
        return try meta.dependencies.filter { !$0.hasPrefix("/usr/lib/") && !$0.hasPrefix("/System/Library/") }.map {
            dependency in
            let candidates =
                dependency.hasPrefix("@rpath/")
                ? search.map { $0.appendingPathComponent(String(dependency.dropFirst("@rpath/".count))) }
                : [expand(dependency, loader: dir, executable: dir)]
            guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw Failure("\(path.path): unresolved dependency \(dependency)")
            }
            return (dependency, file.resolvingSymlinksInPath())
        }
    }

    /// Checks `path` and everything it loads for `arch`. `executable`: the directory @executable_path means (an app's
    /// Contents/MacOS for a dylib in it). Returns every binary in the closure.
    @discardableResult
    public static func check(
        _ path: URL,
        minimum target: String,
        arch: String,
        bundle: URL? = nil,
        executable: URL? = nil,
        noWeakImports: Bool = false
    ) throws -> [URL] {
        var seen: Set<String> = []
        try check(
            path.resolvingSymlinksInPath(),
            target: target,
            arch: arch,
            bundle: bundle?.resolvingSymlinksInPath(),
            inherited: [],
            executable: executable ?? path.resolvingSymlinksInPath().deletingLastPathComponent(),
            seen: &seen,
            noWeakImports: noWeakImports
        )
        return seen.sorted().map { URL(fileURLWithPath: $0) }
    }

    private static func check(
        _ path: URL,
        target: String,
        arch: String,
        bundle: URL?,
        inherited: [URL],
        executable: URL,
        seen: inout Set<String>,
        noWeakImports: Bool
    ) throws {
        guard seen.insert(path.path).inserted else { return }
        if noWeakImports {
            let imports = try Shell.run(["nm", "-arch", arch, "-m", path.path]).output
            // but @available's runtime check, which libSystem has had since macOS 10.15 (ANGLE's Metal backend uses it)
            let weak = imports.split(separator: "\n").filter {
                $0.contains("(undefined)") && $0.contains("weak external")
                    && !$0.contains("weak external __availability_version_check ")
            }
            .compactMap { $0.split(separator: " ").last.map(String.init) }
            if !weak.isEmpty {
                throw Failure(
                    "\(path.path): unexpected weak imports in native code: \(weak.sorted().joined(separator: ", "))"
                )
            }
        }
        let meta = try metadata(path, arch: arch)
        let minimum = meta.minimum!
        if version(target).lexicographicallyPrecedes(version(minimum)) {
            throw Failure("\(path.path): requires macOS \(minimum), app supports \(target)")
        }
        let search =
            meta.rpaths.map { expand($0, loader: path.deletingLastPathComponent(), executable: executable) } + inherited
        for dependency in meta.dependencies
        where !dependency.hasPrefix("/usr/lib/") && !dependency.hasPrefix("/System/Library/") {
            let candidates =
                dependency.hasPrefix("@rpath/")
                ? search.map { $0.appendingPathComponent(String(dependency.dropFirst("@rpath/".count))) }
                : [expand(dependency, loader: path.deletingLastPathComponent(), executable: executable)]
            guard
                let resolved = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })?
                    .resolvingSymlinksInPath()
            else {
                throw Failure("\(path.path): unresolved dependency \(dependency)")
            }
            if let bundle, dependency.hasPrefix("/") || !resolved.path.hasPrefix(bundle.path + "/") {
                throw Failure("\(path.path): dependency escapes relocatable bundle: \(dependency)")
            }
            try check(
                resolved,
                target: target,
                arch: arch,
                bundle: bundle,
                inherited: search,
                executable: executable,
                seen: &seen,
                noWeakImports: noWeakImports
            )
        }
    }
}
