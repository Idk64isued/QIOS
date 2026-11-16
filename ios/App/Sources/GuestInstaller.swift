import Foundation
import ZIPFoundation

/// Installs an .ipa on a stock guest — no jailbreak, no USB pairing — through the guest agent.
///
/// The Mac app installs over USB (lockdown, AFC, installation_proxy), which on a stock device needs a paired, SSL
/// session this app can't open yet. The agent, though, runs as root inside the guest and can write any file; what a
/// stock image lacks is a way to make folders. So the app brings one: lt-mkdirs (ios/guest-helper), a 456-byte static
/// armv6 program that makes folders and sets their owner. With it the install is done the way installd would leave it:
///
///  - iPhone OS 2 and 3: a container /var/mobile/Applications/<UUID>/ (Documents, Library, tmp, Foo.app) owned by
///    mobile, and the app's entry in MobileInstallation's cache, which SpringBoard and installd list apps from.
///  - iPhone OS 1: Foo.app in /Applications, which SpringBoard scans at start.
///
/// then SpringBoard restarts and shows the icon. Every prepared device boots with cs_enforcement_disable=1 and
/// amfi_allow_any_signature=1, so a decrypted app runs with whatever signature it has.
extension GuestAgent {
    struct InstallFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct InstalledApp {
        let name: String
        let bundleID: String
        let path: String
        let needsRestart: Bool
    }

    static let installationCache = "/var/mobile/Library/Caches/com.apple.mobile.installation.plist"

    /// Unpacks `ipa` here, copies its app into the guest, registers it and restarts SpringBoard.
    func installApp(ipa: URL, progress: @escaping (Double, String) -> Void) async throws -> InstalledApp {
        if isInstalling { progress(0, "Waiting for the install before it\u{2026}") }
        return try await oneAtATime { try await self.installAppNow(ipa: ipa, progress: progress) }
    }

    private func installAppNow(ipa: URL, progress: @escaping (Double, String) -> Void) async throws -> InstalledApp {
        guard status == .alive else { throw InstallFailure(message: "The device\u{2019}s agent isn\u{2019}t running yet. Give it a minute after the Home screen appears.") }
        guard ops.contains("spawn"), ops.contains("chown"), ops.contains("put") || ops.contains("putpart") else {
            throw InstallFailure(message: "This device\u{2019}s guest tools are too old to install apps (agent \(version.isEmpty ? "unknown" : version)). Rebuild the device to update them.")
        }
        isInstalling = true
        defer { isInstalling = false }
        let major = Int((guestVersion ?? "3").prefix { $0 != "." }) ?? 3

        // 1. Unpack and read the app.
        progress(0.02, "Unpacking\u{2026}")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("install-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let bundle = try await Task.detached(priority: .userInitiated) { () -> URL in
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: ipa, to: work)
            let payload = work.appendingPathComponent("Payload", isDirectory: true)
            let apps = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
            guard let app = apps.first(where: { $0.pathExtension == "app" }) else {
                throw InstallFailure(message: "There is no app inside this .ipa (no Payload/*.app).")
            }
            return app.resolvingSymlinksInPath()
        }.value
        let infoData = try Data(contentsOf: bundle.appendingPathComponent("Info.plist"))
        guard var info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
            let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty
        else { throw InstallFailure(message: "The app\u{2019}s Info.plist has no bundle identifier.") }
        let executable = info["CFBundleExecutable"] as? String ?? ""
        let appName = bundle.lastPathComponent
        let display = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? (appName as NSString).deletingPathExtension
        guard !appName.contains("\n") else { throw InstallFailure(message: "The app\u{2019}s name has a line break in it.") }
        if let minimum = info["MinimumOSVersion"] as? String, let need = Int(minimum.prefix { $0 != "." }), need > major {
            log("\(display) asks for iPhone OS \(minimum); this device runs \(guestVersion ?? "?"). Installing anyway.")
        }
        // The Home screen's "Waiting…" icon while the app is copied in (the agent's dlicon, SpringBoard's own download
        // placeholder), as the Mac app raises it; dropped when the install ends, and the real icon takes its place.
        let safe = bundleID.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        let placeholder = "qemu-install-" + safe
        var raised = false
        // iOS 4 and later keep a download placeholder tied to a bundle ID, and an app that arrives our way (no
        // installd, so no "download finished" for SpringBoard) took the placeholder's blank white icon for good:
        // Doodle Jump on iOS 4, Subway Surfers and Netflix on iOS 5. There the placeholder is skipped, and one left by
        // an earlier install is taken down first.
        if major >= 4 {
            if ops.contains("dlicon") { _ = await request("dlicon cancel \(placeholder)") }
        } else if ops.contains("dlicon"), let reply = await request("dlicon add \(placeholder)" + (safe == bundleID ? " \(bundleID)" : "")) {
            raised = reply.status == 0
        }
        defer {
            if raised { Task { @MainActor in _ = await self.request("dlicon cancel \(placeholder)") } }
        }

        // 2. Where it goes, and who owns it.
        var cache: [String: Any]?
        var cacheFormat = PropertyListSerialization.PropertyListFormat.binary
        if major >= 2, let data = await getFile(Self.installationCache) {
            cache = try? PropertyListSerialization.propertyList(from: data, options: [], format: &cacheFormat) as? [String: Any]
        }
        let uid = major >= 2 ? 501 : 0, gid = major >= 2 ? 501 : 0
        let container: String?
        let appPath: String
        if major >= 2 {
            // An update keeps the app's container, and with it the app's documents and settings.
            let user = cache?["User"] as? [String: Any]
            let existing = (user?[bundleID] as? [String: Any])?["Container"] as? String
            let c = existing ?? "/var/mobile/Applications/" + UUID().uuidString
            container = c
            appPath = c + "/" + appName
        } else {
            container = nil
            appPath = "/Applications/" + appName
        }

        // 3. Everything in the bundle: folders first (parents before children), then files with their sizes.
        var folders: [String] = []
        if let c = container { folders += [c, c + "/Documents", c + "/Library", c + "/Library/Preferences", c + "/Library/Caches", c + "/tmp"] }
        folders.append(appPath)
        let walked = Self.walk(bundle: bundle, appPath: appPath, executable: executable)
        folders += walked.folders
        let files = walked.files
        let skipped = walked.skipped
        if skipped > 0 { log("Skipped \(skipped) link(s) in the bundle") }
        let totalBytes = max(1, files.reduce(0) { $0 + $1.size })

        // 4. The helper.
        progress(0.06, "Preparing the device\u{2026}")
        try await ensureHelper()

        // 5. The bundle: one archive and lt-unpack where it can (a few large uploads and one call), else file by
        // file. The agent serves one request and sleeps a quarter of a second, and each put fsyncs, so an app of a
        // few hundred files took minutes the old way.
        let packed = await installByArchive(
            folders: folders, files: files, uid: uid, gid: gid, display: display, progress: progress)
        if !packed {
            try await runHelper(uid: uid, gid: gid, paths: folders, what: "make the app\u{2019}s folders")
            var sent = 0
            for file in files {
                let label = "Copying \(display)\u{2026} " + String(format: "%.0f%%", Double(sent) / Double(totalBytes) * 100)
                progress(0.08 + 0.80 * Double(sent) / Double(totalBytes), label)
                guard await putFile(localURL: file.local, guestPath: file.guest, mode: file.executable ? "0755" : "0644") else {
                    throw InstallFailure(message: "Copying \((file.guest as NSString).lastPathComponent) into the device failed. \(lastLog)")
                }
                sent += file.size
            }
            // The agent writes files as root: give them to the app's owner (a path that exists only gets its owner set).
            progress(0.9, "Setting permissions\u{2026}")
            try await runHelper(uid: uid, gid: gid, paths: files.map { $0.guest }, what: "set the app\u{2019}s owner")
        }

        // 6. Register it. iPhone OS 2 to iOS 4 take our word for it: an entry written into the cache by hand is
        // listed and drawn. iOS 5 and 6 don't — however the entry was shaped (placeholders skipped, sequence
        // numbers bumped, icon caches cleared), iOS 5 drew the icon blank and iOS 6 never put the app on the Home
        // screen, full restart included. So there iOS writes the entry itself: the cache is taken away, and
        // MobileInstallation rebuilds it from the app folders on disk as the Home screen starts (the jailbreak-era
        // "delete the plist" fix), this app included, every entry in exactly the shape that iOS wants. Step 9
        // checks the rebuild happened; if it didn't, the cache read in step 2 goes back (with the hand-made
        // entry), so the device is never left without its app list.
        var needsRestart = false
        var verifyRebuild = false
        if major >= 5, container != nil {
            progress(0.94, "Registering \(display)\u{2026}")
            _ = await unlink(path: Self.installationCache)
            verifyRebuild = true
        } else if major >= 2, let container {
            progress(0.94, "Registering \(display)\u{2026}")
            if let cache {
                try await registerByHand(cache: cache, format: cacheFormat, info: info, bundleID: bundleID,
                    appPath: appPath, container: container, work: work)
            } else {
                // No cache to add to: installd builds a new one from the folders at its next start.
                log("No installation cache on this device; the next start rebuilds it")
                needsRestart = true
            }
        }

        // 7. The "Waiting…" placeholder goes now, while this SpringBoard is still the one that raised it. Dropped
        // only after the restart (as it was), it reached a SpringBoard that was still starting: iOS 4 keeps a
        // download placeholder for that bundle ID across the restart, and showed it in place of the app's own icon,
        // blank, from then on.
        if raised {
            _ = await request("dlicon cancel \(placeholder)")
            raised = false
        }

        // 8. SpringBoard (and installd, which keeps its own copy of the cache) start again and list it. SpringBoard's
        // icon caches go first, as uicache clears them: an icon it once drew blank (above) stays blank from its cache
        // across a restart, and a reinstall would not bring the real one back.
        progress(0.97, "Restarting the Home screen\u{2026}")
        if major >= 4 {
            for name in ["icons", "icons.plist", "smallicons", "smallicons.plist", "spotlight", "spotlight.plist"] {
                _ = await unlink(path: "/var/mobile/Library/Caches/com.apple.springboard-imagecache-" + name)
            }
        }
        _ = await sync()
        if major >= 2 { _ = await run(["/bin/launchctl", "stop", "com.apple.mobile.installd"], timeout: 15) }
        let respring = await run(["/bin/launchctl", "stop", "com.apple.SpringBoard"], timeout: 15)
        if respring == nil || (respring?.status ?? -1) < 0 { needsRestart = true }

        // 9. iOS 5 and 6: wait for the rebuilt cache and check this app is in it. MobileInstallation writes it as
        // the Home screen starts, so half a minute is plenty when it is coming at all.
        if verifyRebuild {
            progress(0.98, "Waiting for iOS to list \(display)\u{2026}")
            var state = "missing"
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let data = await getFile(Self.installationCache) else { continue }
                state = "rebuilt"
                if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                    (plist["User"] as? [String: Any])?[bundleID] != nil
                {
                    state = "listed"
                    break
                }
            }
            switch state {
            case "listed":
                log("iOS rebuilt its app list with \(display) in it")
            case "rebuilt":
                log("iOS rebuilt its app list WITHOUT \(display): it read \(appPath) and left the app out. Send this log.")
                needsRestart = true
            default:
                log("No rebuilt app list after 30 seconds; putting the old one back, \(display) added by hand")
                if let cache, let container {
                    try? await registerByHand(cache: cache, format: cacheFormat, info: info, bundleID: bundleID,
                        appPath: appPath, container: container, work: work)
                }
                needsRestart = true
            }
        }
        log("Installed \(display) (\(bundleID)) at \(appPath)")
        progress(1, "Installed")
        return InstalledApp(name: display, bundleID: bundleID, path: appPath, needsRestart: needsRestart)
    }

    /// The pre-iOS-5 registration: the app's entry, built from its Info.plist, written into the installation
    /// cache by hand (and, where the cache counts its changes, the next SequenceNumber and a fresh CacheGUID,
    /// as installd would). Also the safety net when iOS 5/6 doesn't rebuild a taken-away cache.
    private func registerByHand(
        cache: [String: Any], format: PropertyListSerialization.PropertyListFormat, info: [String: Any],
        bundleID: String, appPath: String, container: String, work: URL
    ) async throws {
        var cache = cache
        var info = info
        var user = cache["User"] as? [String: Any] ?? [:]
        info["Path"] = appPath
        info["Container"] = container
        info["ApplicationType"] = "User"
        info["EnvironmentVariables"] = ["CFFIXED_USER_HOME": container, "HOME": container, "TMPDIR": container + "/tmp"]
        if let sequence = (cache["SequenceNumber"] as? NSNumber)?.intValue {
            let next = sequence + 1
            cache["SequenceNumber"] = next
            info["SequenceNumber"] = next
            log("Installation cache sequence \(sequence) \u{2192} \(next)")
        }
        if cache["CacheGUID"] != nil { cache["CacheGUID"] = UUID().uuidString }
        user[bundleID] = info
        cache["User"] = user
        let data = try PropertyListSerialization.data(
            fromPropertyList: cache, format: format == .xml ? .xml : .binary, options: 0)
        let tmp = work.appendingPathComponent("installation.plist")
        try data.write(to: tmp)
        guard await putFile(localURL: tmp, guestPath: Self.installationCache, mode: "0644") else {
            throw InstallFailure(message: "The app is on the device but could not be registered. \(lastLog)")
        }
        _ = await chown(uid: 501, gid: 501, path: Self.installationCache)
    }

    typealias BundleFile = (local: URL, guest: String, size: Int, executable: Bool)

    /// The bundle's folders and files, as guest paths under `appPath` (links are skipped: the agent can't make them).
    nonisolated static func walk(bundle: URL, appPath: String, executable: String)
        -> (folders: [String], files: [BundleFile], skipped: Int)
    {
        var folders: [String] = []
        var files: [BundleFile] = []
        var skipped = 0
        let base = bundle.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: keys) else {
            return ([], [], 0)
        }
        while let url = walker.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(base) else { continue }
            let relative = String(full.dropFirst(base.count))
            if relative.isEmpty { continue }
            if relative.contains("\n") || values?.isSymbolicLink == true {
                skipped += 1
                continue
            }
            if values?.isDirectory == true {
                folders.append(appPath + relative)
            } else {
                let isExec = relative == "/" + executable || FileManager.default.isExecutableFile(atPath: url.path)
                files.append((url, appPath + relative, values?.fileSize ?? 0, isExec))
            }
        }
        return (folders, files, skipped)
    }

    /// Where the archive waits in the guest while lt-unpack reads it (it unlinks it when done).
    static let archiveGuestPath = "/tmp/lt-install.ltpk"

    /// The fast path: the bundle packed here (InstallPack), sent as one file, written by lt-unpack in the guest with
    /// the owner set and one sync. false (after cleaning up) if any step fails, and the caller goes file by file.
    func installByArchive(
        folders: [String], files: [BundleFile], uid: Int, gid: Int, display: String,
        progress: @escaping (Double, String) -> Void
    ) async -> Bool {
        guard ops.contains("putpart"), ops.contains("spawn"), await ensureUnpacker() else { return false }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("lt-install-\(UUID().uuidString).ltpk")
        defer { try? FileManager.default.removeItem(at: local) }
        progress(0.08, "Packing \(display)\u{2026}")
        do {
            try await Task.detached(priority: .userInitiated) {
                try InstallPack.write(folders: folders, files: files, to: local)
            }.value
        } catch {
            log("Packing failed (\(error.localizedDescription)); copying file by file")
            return false
        }
        let started = Date()
        let sent = await putFile(localURL: local, guestPath: Self.archiveGuestPath, mode: "0600") { done, total in
            let fraction = Double(done) / Double(max(total, 1))
            progress(0.1 + 0.75 * fraction, "Copying \(display)\u{2026} " + String(format: "%.0f%%", fraction * 100))
        }
        guard sent else {
            log("Sending the archive failed; copying file by file")
            _ = await request("unlink \(Self.archiveGuestPath)")
            return false
        }
        progress(0.86, "Unpacking \(display)\u{2026}")
        guard let r = await run([GuestUnpackBinary.guestPath, String(uid), String(gid), Self.archiveGuestPath], timeout: 600)
        else {
            log("lt-unpack didn\u{2019}t answer; copying file by file")
            _ = await request("unlink \(Self.archiveGuestPath)")
            return false
        }
        guard r.status == 0 else {
            log("lt-unpack failed (exit \(r.status): \(r.status == 2 ? "bad archive" : r.status == 3 ? "a file could not be written" : "error")); copying file by file")
            _ = await request("unlink \(Self.archiveGuestPath)")
            return false
        }
        log("Installed \(files.count) files and \(folders.count) folders from one archive in \(Int(Date().timeIntervalSince(started))) s")
        return true
    }

    /// Puts lt-unpack into the guest once per session; false if it can't.
    func ensureUnpacker() async -> Bool {
        if unpackReady { return true }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lt-unpack")
        guard (try? GuestUnpackBinary.data.write(to: tmp)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard await putFile(localURL: tmp, guestPath: GuestUnpackBinary.guestPath, mode: "0755") else {
            log("Could not put lt-unpack into the device; copying file by file")
            return false
        }
        unpackReady = true
        return true
    }

    /// Puts lt-mkdirs into the guest once per session.
    func ensureHelper() async throws {
        if helperReady { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lt-mkdirs")
        try GuestHelperBinary.data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard await putFile(localURL: tmp, guestPath: GuestHelperBinary.guestPath, mode: "0755") else {
            throw InstallFailure(message: "Could not put the install helper into the device. \(lastLog)")
        }
        helperReady = true
    }

    /// lt-mkdirs UID GID PATH..., in batches the agent takes: its spawn holds at most 64 arguments (agent-ops.h
    /// MAXARGS, the helper and its two numbers included) and a request at most 256 KiB.
    func runHelper(uid: Int, gid: Int, paths: [String], what: String) async throws {
        var batch: [String] = []
        var bytes = 0
        func flush() async throws {
            guard !batch.isEmpty else { return }
            guard let r = await run([GuestHelperBinary.guestPath, String(uid), String(gid)] + batch, timeout: 60) else {
                throw InstallFailure(message: "The device couldn\u{2019}t \(what): the helper didn\u{2019}t answer.")
            }
            guard r.status == 0 else {
                let reason = r.status < 0 ? String(cString: strerror(Int32(-r.status))) : "exit \(r.status)"
                log("lt-mkdirs failed: \(reason)")
                throw InstallFailure(message: "The device couldn\u{2019}t \(what) (\(reason)).")
            }
            batch.removeAll()
            bytes = 0
        }
        for path in paths {
            batch.append(path)
            bytes += path.utf8.count + 1
            if batch.count >= 60 || bytes > 96 * 1024 { try await flush() }
        }
        try await flush()
    }

    /// The user apps the device lists, from MobileInstallation's cache (iPhone OS 2 and later; no jailbreak needed).
    func installedUserApps() async -> [GuestApp] {
        guard let data = await getFile(Self.installationCache),
            let cache = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let user = cache["User"] as? [String: Any]
        else { return [] }
        return user.compactMap { id, value in
            guard let entry = value as? [String: Any] else { return nil }
            let path = entry["Path"] as? String ?? ""
            let name = entry["CFBundleDisplayName"] as? String ?? entry["CFBundleName"] as? String
                ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return GuestApp(bundleID: id, name: name, path: path)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// The archive lt-unpack reads (ios/guest-helper/lt-unpack.S), little-endian: "LTPK1\0\0\0", then records of type
/// (1 folder, 2 file, 0 end), mode, path length, data length, the NUL-terminated path padded to 4 bytes and a file's
/// bytes padded to 4 bytes. Folders come first, parents before children, as the walk lists them. Streamed to disk, so
/// a large app is never in memory whole.
enum InstallPack {
    static let magic = Data("LTPK1\u{0}\u{0}\u{0}".utf8)

    static func write(folders: [String], files: [GuestAgent.BundleFile], to url: URL) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw GuestAgent.InstallFailure(message: "Couldn\u{2019}t make the install archive.")
        }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        func u32(_ v: Int) -> Data {
            var x = UInt32(truncatingIfNeeded: v).littleEndian
            return Data(bytes: &x, count: 4)
        }
        func record(_ type: Int, _ mode: Int, _ path: String, _ length: Int) throws {
            var p = Data(path.utf8)
            p.append(0)
            while p.count % 4 != 0 { p.append(0) }
            guard p.count <= 1024 else {
                throw GuestAgent.InstallFailure(message: "A path in the app is too long for the device: \(path)")
            }
            try out.write(contentsOf: u32(type) + u32(mode) + u32(p.count) + u32(length) + p)
        }
        try out.write(contentsOf: magic)
        for folder in folders { try record(1, 0o755, folder, 0) }
        for file in files {
            let size = (try fm.attributesOfItem(atPath: file.local.path)[.size] as? NSNumber)?.intValue ?? 0
            try record(2, file.executable ? 0o755 : 0o644, file.guest, size)
            let input = try FileHandle(forReadingFrom: file.local)
            defer { try? input.close() }
            var copied = 0
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
                copied += chunk.count
            }
            guard copied == size else {
                throw GuestAgent.InstallFailure(message: "\(file.local.lastPathComponent) changed while it was packed.")
            }
            let pad = (4 - size % 4) % 4
            if pad > 0 { try out.write(contentsOf: Data(count: pad)) }
        }
        try out.write(contentsOf: u32(0) + u32(0) + u32(0) + u32(0))
    }
}
