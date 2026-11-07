// GuestPackage: the guest-package loader and seed package a prepared device starts with (qemu-ios
// contrib/guest-package/mkpkg.py seed). The .itpack and offer formats are HostRuntime's GuestPack.
//
//   let (written, record) = try GuestPackage.seed(volume: mnt, itpack: helpers/armv7.itpack, gles: true)
//   // written: volume-relative paths to make root-owned; record: the lock's guest_package

import Crypto
import Foundation
import HostRuntime

public enum GuestPackage {
    static let root = "usr/local/lighttouch"
    static let loader = ("usr/local/bin/it_boot", "System/Library/LaunchDaemons/com.qemu.it-boot.plist")
    static let systemVersion = "System/Library/CoreServices/SystemVersion.plist"
    /// The GL engines' stock paths (mkpkg GL_TARGETS: MBX, GLENGINE, GLD, and 2.x's OPENGLES front end): hooks kept
    /// only when the preparer installed the shim or the front end.
    static let glTargets = GuestPack.Manifest.glTargets

    /// What was baked: device.lock.json's guest_package (the same keys as the Python preparers').
    public struct Record: Sendable, Equatable {
        public var family: String, seed: Int, version: String, gles: Bool
        public var itpackPath: String, itpackSHA256: String
        public var hooks: [String], jobs: [String]
        public var object: [String: Any] {
            [
                "family": family, "seed": seed, "version": version, "gles": gles,
                "itpack": ["path": itpackPath, "sha256": itpackSHA256], "hooks": hooks, "jobs": jobs
            ]
        }
    }

    /// Preserve the original file or its absence before any installer changes it.
    /// Existing provenance is immutable; callers root-own the returned relative path.
    static func preserveHook(
        volume v: any VolumeFiles,
        target: String,
        write: ((String, Data, mode_t) throws -> Void)? = nil
    ) throws -> String {
        let baked = target + ".baked"
        let absent = target + ".baked-absent"
        let haveBaked = try v.item(at: baked)
        let haveAbsent = try v.item(at: absent)
        guard haveBaked == nil || haveAbsent == nil else {
            throw FirmwareError(.internal, "conflicting hook provenance for \(target)")
        }
        if let marker = haveAbsent {
            guard marker.kind == .file, marker.size == 0 else {
                throw FirmwareError(.internal, "invalid absent hook marker for \(target)")
            }
            return absent
        }
        if haveBaked != nil { return baked }
        let put =
            write ?? { rel, data, mode in
                try v.makeDirectory((rel as NSString).deletingLastPathComponent)
                try v.put(data, at: rel, mode: UInt16(mode))
            }
        if v.exists(target) {
            let mode = try v.item(at: target)?.mode ?? 0o644
            try put(baked, try v.contents(at: target), mode_t(mode & 0o7777))
            return baked
        }
        try put(absent, Data(), 0o644)
        return absent
    }

    /// Bakes the loader and the seed package into the system volume mounted at `volume` (mkpkg.seed): the
    /// itpack's package for the volume's ProductBuildVersion as it_boot installs one (pkgs/<serial>/ with its
    /// `offer`, `current` -> it, `state` with "seed N" and installed hook lines); the hooks whose target is on the volume (the GL engines' only
    /// when the preparer installed the shim: `gles`), target with the package's bytes and <target>.baked with what the volume had; the baked jobs the package provides
    /// removed. Returns (volume-relative paths written, all root-owned; the lock's guest_package record).
    /// Every Mach-O it bakes (the loader, the package's binaries and hooks) is first proven to load on this firmware
    /// (FitCheck.loads, recorded in `fit`; one that does not fails the seed), except the GL engines' and AppSync's
    /// hooks, which their own installers check.
    /// A hook whose target is not on the volume is dropped; unless the preparer left that target out on purpose
    /// (`omitted`) or it is a GL engine's, the drop is a recorded misfit (a warning), never silent.
    public static func seed(
        volume v: any VolumeFiles,
        itpack: URL,
        gles: Bool,
        omitted: Set<String> = [],
        fit: FitCheck.Log = FitCheck.Log()
    ) throws -> (written: [String], record: Record) {
        let list = try GuestPack.read(itpack)
        let entries = Dictionary(list.map { ($0.name, $0.data) }, uniquingKeysWith: { a, _ in a })
        guard let build = v.plist(at: systemVersion)?["ProductBuildVersion"] as? String else {
            throw FirmwareError(.unsupported, "no ProductBuildVersion in /\(systemVersion)")
        }
        let families = try GuestPack.packages(list, build: build, stubs: true)
        guard families.count == 1 else {
            throw FirmwareError(
                .unsupported,
                "\(itpack.lastPathComponent): \(families.count) packages for build \(build)"
            )
        }
        let family = families[0].family
        var man = families[0].manifest
        let hooks = man.hooks.filter { h in
            (gles || !glTargets.contains(h.target)) && v.exists(String(h.target.dropFirst()))
        }
        let needsAbsence = hooks.contains { h in
            v.exists(String(h.target.dropFirst()) + ".baked-absent")
        }
        if needsAbsence && entries["loader/hook-provenance"] != Data("file-or-absence 1\n".utf8) {
            throw FirmwareError(
                .unsupported,
                "guest loader cannot restore absent hook originals; rebuild the guest exports"
            )
        }
        let dropped = Set(man.hooks.map(\.file)).subtracting(hooks.map(\.file))
        for h in man.hooks where dropped.contains(h.file) {
            guard !glTargets.contains(h.target), !omitted.contains(h.target) else { continue }
            try fit.check(
                FitCheck.Fit(
                    "\(family)/\(h.file) (hook)",
                    fits: false,
                    "its target \(h.target) is not on this firmware: the hook is dropped"
                ),
                required: false
            )
        }
        man.dropHooks(dropped)
        let files = man.files
        var written: [String] = []

        // the loader and the package's own binaries must load on this firmware's dyld, with this firmware's images
        let fw = FitCheck.Firmware(volume: v, arch: itpack.deletingPathExtension().lastPathComponent)
        // a legacy-linked family's loader where the arch's own is modern (armv7.itpack's k48-ios30; mkpkg.LEGACY_LOADER)
        let legacyLoader = man.requires.link == "legacy" && entries["loader/it_boot-legacy"] != nil
        let loaderName = legacyLoader ? "loader/it_boot-legacy" : "loader/it_boot"
        guard let loaderBytes = entries[loaderName] else {
            throw FirmwareError(.internal, "\(itpack.lastPathComponent): no \(loaderName)")
        }
        try fit.check(FitCheck.loads("it_boot (guest-package loader)", loaderBytes, on: fw), required: true)
        let hookTargets = Dictionary(hooks.map { ($0.file, $0.target) }, uniquingKeysWith: { a, _ in a })
        for f in files {
            let name = f.name
            let target = hookTargets[name]
            guard let bytes = entries[family + "/" + name], FitCheck.isMachO(bytes),
                !(target.map { glTargets.contains($0) || $0 == "/" + SystemEdits.appsyncPath } ?? false)
            else { continue }
            try fit.check(
                FitCheck.loads(
                    "\(family)/\(name)",
                    bytes,
                    on: fw,
                    host: target.flatMap { FitCheck.host(of: $0, on: fw) }
                ),
                required: true
            )
        }

        func payload(_ n: String) throws -> Data {
            guard let d = entries[n] else { throw FirmwareError(.internal, "\(itpack.lastPathComponent): no \(n)") }
            return d
        }
        func put(_ rel: String, _ data: Data, _ mode: mode_t) throws {
            var missing: [String] = []
            var parent = (rel as NSString).deletingLastPathComponent
            while !parent.isEmpty, !v.isDirectory(parent) {
                missing.insert(parent, at: 0)
                parent = (parent as NSString).deletingLastPathComponent
            }
            for d in missing { try v.makeDirectory(d) }
            try v.put(data, at: rel, mode: UInt16(mode))  // in place: an existing file keeps its catalog record
            written += missing + [rel]
        }
        let mode = { (s: String) in mode_t(strtoul(s, nil, 8)) }

        try put(loader.0, loaderBytes, 0o755)
        try put(loader.1, payload("loader/com.qemu.it-boot.plist"), 0o644)
        let serial = Int(man.serial)
        let pkg = "\(root)/pkgs/\(serial)"
        for f in files { try put(pkg + "/" + f.name, payload(family + "/" + f.name), mode(f.mode)) }
        try put(pkg + "/offer", Data(GuestPack.offerText(man, build: build).utf8), 0o644)
        try v.makeSymlink(root + "/current", to: "pkgs/\(serial)")
        var state = "seed \(serial)\n"
        try put(root + "/state", Data(state.utf8), 0o644)
        written.append(root + "/current")
        let modes = Dictionary(files.map { ($0.name, mode($0.mode)) }, uniquingKeysWith: { a, _ in a })
        for h in hooks {
            let file = h.file
            let target = String(h.target.dropFirst())
            // <target>.baked keeps what the volume had (the stock file, or what the preparer put there), so a
            // package without the hook puts it back
            let backup = try preserveHook(volume: v, target: target, write: put)
            if !written.contains(backup) { written.append(backup) }
            try put(target, payload(family + "/" + file), modes[file] ?? 0o755)
            // A first offer without this hook must restore .baked even before
            // the loader has read the seed offer. Failed copies are not claimed.
            state += "hook \(h.respring ? 1 : 0) \(h.target)\n"
            try put(root + "/state", Data(state.utf8), 0o644)
        }
        let jobs = man.jobs.map { ($0 as NSString).lastPathComponent }
        for j in jobs {
            let rel = "System/Library/LaunchDaemons/" + j
            if v.exists(rel) { try v.remove(rel) }
        }
        let sha = SHA256.hash(data: try Data(contentsOf: itpack)).hexString
        return (
            written,
            Record(
                family: family,
                seed: serial,
                version: man.version,
                gles: gles,
                itpackPath: itpack.path,
                itpackSHA256: sha,
                hooks: hooks.map(\.target),
                jobs: jobs
            )
        )
    }
}
