// The guest-package formats, one implementation for FirmwareKit (which seeds a package at preparation) and the
// app (which offers one each boot): the .itpack qemu-ios's contrib/guest-package/mkpkg.py packs, and the
// `ltpkg 1` offer contrib/it-boot/it_boot.c reads.

import Foundation

public enum GuestPack {
    public static let magic = Data("ITPACK01".utf8)
    /// The offer wire this side writes (it_boot's `ltpkg 1`).
    public static let packageProtocol = 1

    /// One package's manifest.json.
    public struct Manifest: Codable, Sendable, Equatable {
        public struct Requires: Codable, Sendable, Equatable {
            public var boards: [String]
            public var builds: [String]
            public var host: [String: [Int]]?
            /// "legacy": a legacy-linked family, which takes the arch's legacy loader (mkpkg.LEGACY_LOADER).
            public var link: String?
        }
        public struct File: Codable, Sendable, Equatable {
            public var name: String
            public var mode: String
            public var size: Int
            public var sha256: String
        }
        public struct Hook: Codable, Sendable, Equatable {
            public var file: String
            public var target: String
            public var respring: Bool
        }
        public var serial: Int64
        public var version: String
        public var family: String
        public var arch: String
        public var stub: Bool?
        public var requires: Requires
        public var files: [File]
        public var jobs: [String]
        public var hooks: [Hook]
        /// The GL targets' stock paths (mkpkg GL_TARGETS: MBX, OPENGLES, the GL front end's): their hooks exist
        /// only where the preparer installed the front end.
        public static let glTargets: Set<String> = [
            "/System/Library/Frameworks/OpenGLES.framework/MBXGLEngine.bundle/MBXGLEngine",
            "/System/Library/Frameworks/OpenGLES.framework/OpenGLES"
        ]

        /// Drop hooks (and their payload files) by file name.
        public mutating func dropHooks(_ files: Set<String>) {
            hooks.removeAll { files.contains($0.file) }
            self.files.removeAll { files.contains($0.name) }
        }
    }

    /// "ITPACK01", a little-endian u32 index length, the JSON index, then one zlib stream; entries in index order.
    public static func read(_ url: URL) throws -> [(name: String, data: Data)] {
        func invalid(_ why: String) -> Error {
            CocoaError(
                .fileReadCorruptFile,
                userInfo: [
                    NSFilePathErrorKey: url.path,
                    NSLocalizedDescriptionKey: "\(url.lastPathComponent): \(why)"
                ]
            )
        }
        let blob = try Data(contentsOf: url)
        guard blob.count >= 12, blob.prefix(8) == magic else { throw invalid("not an .itpack") }
        let n =
            Int(blob[blob.startIndex + 8]) | Int(blob[blob.startIndex + 9]) << 8
            | Int(blob[blob.startIndex + 10]) << 16 | Int(blob[blob.startIndex + 11]) << 24
        guard blob.count >= 12 + n + 2 else { throw invalid("truncated") }
        struct Index: Decodable {
            struct Entry: Decodable {
                var name: String
                var size: Int
            }
            var entries: [Entry]
        }
        let index = try JSONDecoder().decode(Index.self, from: blob.subdata(in: 12..<12 + n))
        // zlib's 2-byte header off: Compression's zlib is raw deflate (the adler trailer is ignored).
        let stream = try (blob.subdata(in: 12 + n + 2..<blob.count) as NSData).decompressed(using: .zlib) as Data
        var entries: [(String, Data)] = []
        var offset = 0
        for e in index.entries {
            guard !e.name.hasPrefix("/"), !e.name.split(separator: "/").contains(".."), e.size >= 0,
                e.size <= stream.count - offset
            else { throw invalid("bad entry \(e.name)") }
            entries.append((e.name, stream.subdata(in: offset..<offset + e.size)))
            offset += e.size
        }
        guard offset == stream.count else { throw invalid("the index does not cover the stream") }
        return entries
    }

    /// mkpkg's requires.builds: an exact build id, or "<major>*" for every build of that iOS major (2.x = 5*,
    /// 3.x = 7*, 4.x = 8*).
    public static func buildMatches(_ builds: [String], _ build: String) -> Bool {
        let major = build.prefix { $0.isNumber }
        return builds.contains { $0 == build || ($0.hasSuffix("*") && $0.dropLast() == major) }
    }

    /// The packages in `entries` whose builds take `build` (and `board`, when given), with their family directory
    /// and payloads by package path; stubs (a family with nothing to run yet) only with `stubs`.
    public static func packages(
        _ entries: [(name: String, data: Data)],
        board: String? = nil,
        build: String,
        stubs: Bool = false
    ) throws
        -> [(family: String, manifest: Manifest, payloads: [String: Data])]
    {
        var found: [(String, Manifest, [String: Data])] = []
        for (name, data) in entries where name.hasSuffix("/manifest.json") {
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard board.map(manifest.requires.boards.contains) ?? true, buildMatches(manifest.requires.builds, build),
                stubs || manifest.stub != true
            else { continue }
            let prefix = String(name.dropLast("manifest.json".count))
            var payloads: [String: Data] = [:]
            for (entry, bytes) in entries where entry.hasPrefix(prefix) && entry != name {
                payloads[String(entry.dropFirst(prefix.count))] = bytes
            }
            found.append((String(prefix.dropLast()), manifest, payloads))
        }
        return found
    }

    /// The offer text it_boot reads (mkpkg.py offer_text): payload lines indexed in manifest order, after the
    /// verdicts. `serial` other than the manifest's (0: the built-in package) carries no payload lines.
    public static func offerText(
        _ m: Manifest,
        build: String,
        serial: Int64? = nil,
        good: [Int64] = [],
        bad: [Int64] = []
    ) -> String {
        var lines = ["ltpkg \(packageProtocol)", "build \(build)", "serial \(serial ?? m.serial) \(m.version)"]
        lines += good.map { "verdict good \($0)" } + bad.map { "verdict bad \($0)" }
        if serial == nil || serial == m.serial {
            let hooks = Dictionary(m.hooks.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
            for (i, f) in m.files.enumerated() {
                let kind = hooks[f.name] != nil ? "hook" : m.jobs.contains(f.name) ? "job" : "file"
                var line = "\(kind) \(i) \(f.name) \(f.mode) \(f.size) \(f.sha256)"
                if let hook = hooks[f.name] { line += " \(hook.target)" + (hook.respring ? " respring" : "") }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
