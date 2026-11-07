import BuildSupport
import Foundation

/// Per-architecture native build roots (build-package-native.sh outputs, or a root whose prefix and static deps come
/// from another, QEMU built elsewhere) merged into one universal root for scripts/vendor. Each part is read from where
/// the root's native-build.json says it is; every Mach-O (dylibs, executables, static archives) is lipo'd; any other
/// file must match exactly once each slice's build paths are replaced with the output's. iBoot32Patcher is not
/// merged: scripts/vendor builds it for both slices.
public enum MergeNative {
    /// The parts of a native root packaging reads: output path <- native-build.json key (+ the file within it).
    static let parts: [(part: String, key: String, member: String)] = [
        ("prefix", "deps_prefix", ""), ("static/prefix", "static_deps", ""),
        ("qemu-build/libqemu-arm.dylib", "qemu_build", "libqemu-arm.dylib"),
        ("build/usbmuxd/src/usbmuxd", "usbmuxd_binary", "")
    ]

    /// Build-time metadata for compiling against one slice: never packaged, and cross-compiled slices legitimately
    /// differ (how Meson found zlib).
    static func skipped(_ name: String) -> Bool {
        name.hasPrefix("lib/pkgconfig/") || name.hasPrefix("share/pkgconfig/") || name.hasSuffix(".la")
    }

    /// A Mach-O, or a static archive (merged with lipo too).
    static func isMachO(_ file: URL) -> Bool {
        MachOClosure.isMachO(file)
            || (try? FileHandle(forReadingFrom: file).read(upToCount: 8)) == Data("!<arch>\n".utf8)
    }

    typealias Pairs = [(old: String, new: String)]

    /// (build path, output path) pairs for one slice, longest first: each part's recorded source (as recorded and
    /// resolved) becomes the output's part, then the slice's root (and the deps root it reused) the output root.
    static func relocations(root: URL, record: [String: Any], output: URL) -> Pairs {
        var pairs: Set<[String]> = []
        for (part, key, _) in parts {
            let source = record[key] as? String ?? ""
            for s in [source, real(source)] { pairs.insert([s, output.appendingPathComponent(part).path]) }
        }
        for source in [root.path, record["reused_native_deps"] as? String].compactMap({ $0 }) {
            pairs.insert([source, output.path])
            pairs.insert([real(source), output.path])
        }
        return pairs.sorted { $0[0].count > $1[0].count }.map { ($0[0], $0[1]) }
    }

    /// realpath(3): /private kept, unlike URL.resolvingSymlinksInPath.
    static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func relocated(_ data: Data, _ pairs: Pairs) -> Data {
        var data = data
        for (old, new) in pairs { data.replace(Data(old.utf8), with: Data(new.utf8)) }
        return data
    }
    static func relocated(_ text: String, _ pairs: Pairs) -> String {
        String(decoding: relocated(Data(text.utf8), pairs), as: UTF8.self)
    }

    /// A copy of a Mach-O whose install name, dependencies and rpaths name the output, not the slice's build paths.
    static func relink(_ file: URL, _ pairs: Pairs, scratch: URL) throws -> URL {
        if (try? FileHandle(forReadingFrom: file).read(upToCount: 8)) == Data("!<arch>\n".utf8) { return file }
        let copy = scratch.appendingPathComponent(
            "\(try files.contentsOfDirectory(atPath: scratch.path).count)-\(file.lastPathComponent)"
        )
        try files.copyItem(at: file, to: copy)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        var edits: [String] = []
        for line in try output(["otool", "-l", copy.path]).split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("name ") || line.hasPrefix("path ") else { continue }
            let rest = String(line.dropFirst(5))
            let old = rest.components(separatedBy: " (offset").first ?? rest
            let new = relocated(old, pairs)
            if new != old { edits += line.hasPrefix("path ") ? ["-rpath", old, new] : ["-change", old, new] }
        }
        if let id = try output(["otool", "-D", copy.path]).split(separator: "\n").dropFirst().first.map(String.init),
            relocated(id, pairs) != id
        {
            edits += ["-id", relocated(id, pairs)]
        }
        if !edits.isEmpty {
            try run(
                ["/usr/bin/install_name_tool"] + edits + [copy.path],
                log: scratch.appendingPathComponent("tools.log")
            )
        }
        return copy
    }

    /// One part of the output from every slice.
    static func merge(
        output: URL,
        part: (part: String, key: String, member: String),
        slices: [(root: URL, record: [String: Any])],
        scratch: URL
    ) throws {
        let targetRoot = output.appendingPathComponent(part.part)
        var trees: [(pairs: Pairs, tree: [String: URL])] = []
        for (root, record) in slices {
            var source = url(record[part.key] as? String ?? "")
            if !part.member.isEmpty { source.appendPathComponent(part.member) }
            let pairs = relocations(root: root, record: record, output: output)
            var isDirectory: ObjCBool = false
            files.fileExists(atPath: source.path, isDirectory: &isDirectory)
            var tree: [String: URL] = [:]
            if isDirectory.boolValue {
                for name in walk(source) where !skipped(name) {
                    tree[relocated(name, pairs)] = source.appendingPathComponent(name)
                }
            } else {
                tree[""] = source
            }
            trees.append((pairs, tree))
        }
        let names = Set(trees[0].tree.keys)
        for (_, tree) in trees.dropFirst() where Set(tree.keys) != names {
            throw ToolError(
                "\(part.part): file lists differ: \(names.symmetricDifference(tree.keys).sorted().prefix(5))"
            )
        }
        for name in names.sorted() {
            let inputs = try trees.map {
                guard let file = $0.tree[name] else { throw ToolError("\(part.part)/\(name): missing from a slice") }
                return ($0.pairs, file)
            }
            let target = name.isEmpty ? targetRoot : targetRoot.appendingPathComponent(name)
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let first = inputs[0].1
            let mode = (try files.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int) ?? 0o644
            if (try? files.destinationOfSymbolicLink(atPath: first.path)) != nil {
                let links = Set(inputs.map { (try? files.destinationOfSymbolicLink(atPath: $0.1.path)) ?? "" })
                guard links.count == 1, let link = links.first else {
                    throw ToolError("\(part.part)/\(name): symlink targets differ")
                }
                try files.createSymbolicLink(atPath: target.path, withDestinationPath: link)
            } else if isMachO(first) {
                let thin = try inputs.map { try relink($0.1, $0.0, scratch: scratch) }
                try run(["/usr/bin/lipo", "-create"] + thin.map(\.path) + ["-output", target.path])
                try files.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
                if thin[0] != first {  // relinked, so arm64 needs a fresh ad-hoc signature
                    try run(
                        ["/usr/bin/codesign", "-f", "-s", "-", target.path],
                        log: scratch.appendingPathComponent("tools.log")
                    )
                }
            } else {
                let contents = Set(try inputs.map { relocated(try Data(contentsOf: $0.1), $0.0) })
                guard contents.count == 1, let content = contents.first else {
                    throw ToolError("\(part.part)/\(name): differs between architectures and is not a Mach-O")
                }
                try content.write(to: target)
                try files.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
            }
        }
    }

    /// The universal root at a new `output` from `roots` (one per architecture); nothing is left behind on failure.
    public static func merge(output: URL, roots: [URL]) throws {
        guard !files.fileExists(atPath: output.path) else { throw ToolError("Output already exists: \(output.path)") }
        var slices: [String: (root: URL, record: [String: Any])] = [:]
        for root in roots {
            let record = try readJSON(root.appendingPathComponent("native-build.json"))
            let arch = record["architecture"] as? String ?? ""
            if let other = slices[arch] {
                throw ToolError("Two native roots for \(arch): \(other.root.path) and \(root.path)")
            }
            slices[arch] = (url(real(root.path)), record)
        }
        try files.createDirectory(at: output, withIntermediateDirectories: true)
        let out = url(real(output.path))
        let scratch = files.temporaryDirectory.appendingPathComponent("merge-native-\(UUID().uuidString)")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { remove(scratch) }
        let ordered = slices.sorted { $0.key < $1.key }.map(\.value)
        do {
            for part in parts { try merge(output: out, part: part, slices: ordered, scratch: scratch) }
        } catch {
            remove(output)
            throw error
        }
        try writeJSON(
            [
                "schema_version": 1, "architectures": slices.keys.sorted(),
                "static_deps": out.appendingPathComponent("static/prefix").path,
                "slices": slices.mapValues(\.record)
            ],
            to: out.appendingPathComponent("native-build.json")
        )
        print("Universal native root (\(slices.keys.sorted().joined(separator: ", "))): \(output.path)")
    }
}
