import BuildSupport
import Foundation
import zlib

/// What a shipped bundle may not contain and what it must carry for what it ships: every Mach-O attributed to a
/// component with its license (and its source named, for copyleft), every Swift package licensed, Help.txt naming
/// every component, no local paths (also inside the packed built-in device and the guest archive), the packed device
/// carrying only the placeholder identity, host binaries stripped, no dSYM, nothing shipped twice, no Mach-O loose
/// under Resources.
public enum BundleHygiene {
    /// component: (licenses/<dir>, the name Help.txt uses, needs SOURCE.txt)
    public static let components: [String: (directory: String, helpName: String, copyleft: Bool)] = [
        "qemu": ("qemu", "QEMU", true), "usbmuxd": ("usbmuxd", "usbmuxd", true),
        "inetcat": ("inetcat", "inetcat", true),
        "libimobiledevice": ("libimobiledevice", "libimobiledevice", true),
        "libimobiledevice-glue": ("libimobiledevice-glue", "libimobiledevice-glue", true),
        "libusbmuxd": ("libusbmuxd", "libusbmuxd", true), "libtatsu": ("libtatsu", "libtatsu", true),
        "libplist": ("libplist", "libplist", true), "glib": ("glib", "GLib", true),
        "proxy-libintl": ("proxy-libintl", "proxy-libintl", true), "ffmpeg": ("ffmpeg", "FFmpeg", true),
        "iBoot32Patcher": ("iBoot32Patcher", "iBoot32Patcher", true), "libslirp": ("libslirp", "libslirp", true),
        "openssl": ("openssl", "OpenSSL", false), "nettle": ("nettle", "Nettle", true),
        "pcre2": ("pcre2", "PCRE2", false), "pixman": ("pixman", "pixman", false),
        "angle": ("angle", "ANGLE", false)
    ]
    /// Where each shipped Mach-O comes from (bundle-relative glob: the components linked into it). Light Touch's own
    /// binaries list only what they link in; their Swift packages are checked against the Package.resolved files.
    public static let binaries: [(pattern: String, components: [String])] = [
        ("Contents/MacOS/LightTouch", []), ("Contents/MacOS/LightTouchDevice", []),
        ("Contents/MacOS/LightTouchServices", []),
        ("Contents/MacOS/inetcat", ["inetcat", "libusbmuxd", "libimobiledevice-glue", "libplist"]),
        ("Contents/MacOS/firmwarekit", []), ("Contents/MacOS/ipod-helper", ["qemu"]),
        ("Contents/MacOS/usbmuxd", ["usbmuxd", "libimobiledevice-glue"]),
        ("Contents/MacOS/iBoot32Patcher", ["iBoot32Patcher"]),
        (
            "Contents/Frameworks/libqemu-arm.dylib",
            ["qemu", "glib", "proxy-libintl", "pcre2", "pixman", "libslirp", "openssl", "nettle"]
        ),
        ("Contents/Frameworks/libavcodec*.dylib", ["ffmpeg"]), ("Contents/Frameworks/libavutil*.dylib", ["ffmpeg"]),
        (
            "Contents/Frameworks/libimobiledevice-1.0*.dylib",
            ["libimobiledevice", "openssl", "libimobiledevice-glue", "libusbmuxd", "libtatsu"]
        ),
        ("Contents/Frameworks/libplist-2.0*.dylib", ["libplist"]),
        // ANGLE (with Abseil and zlib linked in, their texts in licenses/angle): the experimental ANGLE renderer's
        ("Contents/Frameworks/libEGL.dylib", ["angle"]), ("Contents/Frameworks/libGLESv2.dylib", ["angle"]),
        // a Swift package (licensed through Package.resolved), with its helpers and XPC services
        ("Contents/Frameworks/Sparkle.framework/*", []),
        // the toolchain's Span back-deployment, which Xcode embeds for BinaryParsing below macOS 26 (the Swift
        // runtime: Apache-2.0 with the Runtime Library Exception, no notice to carry)
        ("Contents/Frameworks/libswiftCompatibilitySpan.dylib", []),
        // the guest tools: qemu-ios contrib, built for the guest
        ("Contents/Resources/Guest/guest.aar/guest-tools/*", ["qemu"]),
        ("Contents/Resources/Guest/guest.aar/tools/*", ["qemu"])
    ]
    public static let guest = "Contents/Resources/Guest/guest.aar"
    /// scripts/vendor's SEED: the identity a packed base carries until the app unpacks it with a seed of its own.
    public static let placeholderSeed = "lighttouch-built-in"
    static let licenseTexts = ["LICENSE*", "LICENCE*", "COPYING*", "COPYRIGHT*", "GPL-*.txt"]

    static func matches(_ name: String, _ pattern: String) -> Bool { fnmatch(pattern, name, 0) == 0 }

    static func hasLicense(_ directory: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { name in
            let url = directory.appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]))
            return size?.isRegularFile == true && (size?.fileSize ?? 0) > 0
                && licenseTexts.contains { matches(name, $0) }
        }
    }

    /// The Swift packages Package.resolved files pin (their identities), but those `unlinked` (build-inputs.json's
    /// swift_packages_unlinked: resolved, never linked, as scripts/vendor found them).
    public static func swiftPackages(resolved: [URL], unlinked: [String] = []) throws -> [String] {
        var names: Set<String> = []
        for file in resolved {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            for pin in json?["pins"] as? [[String: Any]] ?? [] {
                if let identity = pin["identity"] as? String { names.insert(identity) }
            }
        }
        return names.subtracting(unlinked).sorted()
    }

    /// Every problem with `app`; empty when it may ship.
    public static func problems(app: URL, packages: [String], localMarkers: [String] = ["/Users/", NSHomeDirectory()])
        throws -> [String]
    {
        let app = app.resolvingSymlinksInPath()
        var files = try walk(app, prefix: "")
        let unpacked = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ltm-hygiene-guest-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: unpacked) }
        // what the app unpacks at use, as if loose
        if FileManager.default.fileExists(atPath: app.appendingPathComponent(guest).path) {
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            let extracted = try Shell.run([
                "aa", "extract", "-i", app.appendingPathComponent(guest).path, "-d", unpacked.path
            ])
            guard extracted.succeeded else { return ["could not extract \(guest): \(extracted.error)"] }
            files += try walk(unpacked.resolvingSymlinksInPath(), prefix: guest + "/")
        }
        return try fileProblems(app: app, files: files, packages: packages, local: localMarkers.map { Data($0.utf8) })
    }

    static func walk(_ root: URL, prefix: String) throws -> [(name: String, url: URL)] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.map { url in
            (prefix + String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1)), url)
        }.sorted { $0.name < $1.name }
    }

    static func fileProblems(app: URL, files: [(name: String, url: URL)], packages: [String], local: [Data]) throws
        -> [String]
    {
        let licenses = app.appendingPathComponent("Contents/Resources/licenses")
        var found: [String] = []
        var needed: Set<String> = []
        var seen: [String: String] = [:]
        if let developer = files.first(where: { $0.name == "\(guest)/developer-tools" }) {
            let audited = try Shell.run([
                app.appendingPathComponent("Contents/MacOS/firmwarekit").path, "developer-audit", "--payload",
                developer.url.path
            ])
            if !audited.succeeded {
                found.append(
                    "developer source/license/binary audit failed: "
                        + audited.error.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
        for (name, url) in files {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            if values?.isDirectory == true, url.pathExtension == "dSYM" { found.append("a dSYM ships: \(name)") }
            if values?.isDirectory == true, url.pathExtension == "itbase" {
                found += packedProblems(url, name: name, local: local)
                continue
            }
            guard values?.isSymbolicLink != true, values?.isRegularFile == true else { continue }
            // a packed device's chunks are zlib streams, which packedProblems inflates; its whole files are checked here
            if name.contains(".itbase/"), url.pathExtension == "z" { continue }
            let data = try Data(contentsOf: url)
            if local.contains(where: { data.range(of: $0) != nil }) { found.append("names a local path: \(name)") }
            guard MachOClosure.isMachO(url) else { continue }
            if name.hasPrefix("Contents/Resources/"), !name.hasPrefix(guest + "/") {
                found.append("nested code under Resources (pack it into \(guest)): \(name)")
            }
            if name.hasPrefix("\(guest)/developer-tools/") { continue }  // certified by the audit above
            let owners = binaries.filter { matches(name, $0.pattern) }
            if owners.isEmpty { found.append("unattributed Mach-O (add it to binaries with its licenses): \(name)") }
            for owner in owners { needed.formUnion(owner.components) }
            let digest = sha256Hex(data)
            if let first = seen[digest] {
                found.append("ships twice: \(first) and \(name)")
            } else {
                seen[digest] = name
            }
            if !name.hasPrefix("Contents/Resources/") {  // host binaries; the guest tools are the guest's
                if try Shell.run(["nm", "-ap", url.path]).output.contains(" OSO ") {
                    found.append("not stripped (has a debug map): \(name)")
                }
            }
        }
        for component in needed.sorted() {
            guard let facts = components[component] else { continue }
            let directory = licenses.appendingPathComponent(facts.directory)
            if !hasLicense(directory) {
                found.append("no license text for \(component) in licenses/\(facts.directory)/")
            }
            let source = directory.appendingPathComponent("SOURCE.txt")
            if facts.copyleft, !((try? String(contentsOf: source, encoding: .utf8))?.contains("https://") ?? false) {
                found.append("no SOURCE.txt naming the source of \(component) (licenses/\(facts.directory)/SOURCE.txt)")
            }
        }
        let swift = licenses.appendingPathComponent("swift")
        let shipped = Dictionary(
            ((try? FileManager.default.contentsOfDirectory(atPath: swift.path)) ?? []).map { ($0.lowercased(), $0) },
            uniquingKeysWith: { a, _ in a }
        )
        for package in packages
        where !hasLicense(swift.appendingPathComponent(shipped[package.lowercased()] ?? package)) {
            found.append("no license text for the Swift package \(package) (licenses/swift/\(package)/)")
        }
        let help =
            (try? String(contentsOf: app.appendingPathComponent("Contents/Resources/Help.txt"), encoding: .utf8)) ?? ""
        for component in needed.sorted() {
            if let name = components[component]?.helpName, !help.contains(name) {
                found.append("Help.txt does not name \(name)")
            }
        }
        return found
    }

    /// A packed device (firmwarekit pack-base, a directory: index.json, files/ whole, each NAND image as 1 MiB zlib
    /// chunks): no local path in any chunk (the whole files are checked as any other), and only the placeholder
    /// identity.
    static func packedProblems(_ url: URL, name: String, local: [Data]) -> [String] {
        guard
            let index = (try? Data(contentsOf: url.appendingPathComponent("index.json")))
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
            index["format"] as? Int == 2
        else { return ["not a packed device: \(name)"] }
        var found: [String] = []
        func scan(_ data: Data) {
            if found.isEmpty, local.contains(where: { data.range(of: $0) != nil }) {
                found.append("names a local path: \(name) (packed)")
            }
        }
        for image in index["images"] as? [[String: Any]] ?? [] {
            let stem = ((image["name"] as? String ?? "") as NSString).deletingPathExtension
            for number in (image["chunks"] as? [String: Any] ?? [:]).keys.sorted() {
                guard let handle = try? FileHandle(forReadingFrom: url.appendingPathComponent("\(stem)/\(number).z"))
                else { return found + ["\(name): missing chunk \(stem)/\(number)"] }
                defer { try? handle.close() }
                var raw = Data()
                guard inflate(handle, { raw.append($0) }) else {
                    return found + ["\(name): unreadable chunk \(stem)/\(number)"]
                }
                scan(raw)
            }
        }
        func json(_ file: String) -> [String: Any]? {
            (try? Data(contentsOf: url.appendingPathComponent("files/\(file)")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        guard let identity = json("identity.json")?["seed"] as? String,
            let lock = (json("device.lock.json")?["identity"] as? [String: Any])?["seed"] as? String
        else {
            return found + ["\(name): no readable identity.json and lock"]
        }
        if Set([identity, lock]) != [placeholderSeed] {
            found.append(
                "\(name) carries a unit identity (seed \([identity, lock].sorted())), not the placeholder \(placeholderSeed)"
            )
        }
        return found
    }

    /// Inflates the rest of `handle` (a zlib stream), handing each decompressed chunk to `body`. False on a bad stream.
    static func inflate(_ handle: FileHandle, _ body: (Data) -> Void) -> Bool {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return false }
        defer { inflateEnd(&stream) }
        var status = Z_OK
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while status == Z_OK, let input = try? handle.read(upToCount: 1 << 20), !input.isEmpty {
            input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(raw.count)
                repeat {
                    buffer.withUnsafeMutableBufferPointer { out in
                        stream.next_out = out.baseAddress
                        stream.avail_out = uInt(out.count)
                        status = zlib.inflate(&stream, Z_NO_FLUSH)
                        let produced = out.count - Int(stream.avail_out)
                        if produced > 0 { body(Data(out.prefix(produced))) }
                    }
                } while status == Z_OK && stream.avail_out == 0
            }
        }
        return status == Z_STREAM_END
    }
}
