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
    /// SpringBoard's own record of which icons sit on which page. Only SpringBoard writes it.
    static let iconState = "/var/mobile/Library/SpringBoard/IconState.plist"

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
        // The App Store's own copy of the app's icon, beside Payload in most .ipa files, as a PNG with no
        // extension. The last resort for a bundle whose icons live in an asset catalog no iOS here can read.
        let artwork: URL? = ["iTunesArtwork@2x", "iTunesArtwork"]
            .map { work.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }

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
        // Every icon the bundle names, newest form first: CFBundleIcons is iOS 5 and up, CFBundleIconFiles is
        // iPhone OS 3.2 and up, CFBundleIconFile is the original. Used to give the icon a classic name (step 5b)
        // and to say in the log what was declared against what landed (step 8).
        var declaredIcons: [String] = []
        if let icons = info["CFBundleIcons"] as? [String: Any],
            let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let files = primary["CFBundleIconFiles"] as? [String] { declaredIcons += files }
        if let files = info["CFBundleIconFiles"] as? [String] { declaredIcons += files }
        if let one = info["CFBundleIconFile"] as? String { declaredIcons.append(one) }
        declaredIcons = declaredIcons.filter { !$0.isEmpty }
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
            if ops.contains("dlicon") {
                _ = await request("dlicon cancel \(placeholder)")
                // Installs before update 52 tagged the placeholder with the bundle ID itself; one of those left
                // standing shadows the app's real icon (a white box, sometimes with a stuck badge), so it goes too.
                if safe == bundleID { _ = await request("dlicon cancel \(bundleID)") }
            }
        } else if ops.contains("dlicon"), let reply = await request("dlicon add \(placeholder)" + (safe == bundleID ? " \(bundleID)" : "")) {
            raised = reply.status == 0
        }
        defer {
            if raised { Task { @MainActor in _ = await self.request("dlicon cancel \(placeholder)") } }
        }

        // 1b. iOS 4 and up: the device's own installer, which is how the Mac app installs and how iTunes did.
        //
        // Everything from step 2 on writes the app in by hand: its folders, its files, and an entry in the app list
        // (or, on 5 and 6, the app list rebuilt from disk). That got apps listed, but on iOS 4 and 5 their icons stayed
        // blank through every fix aimed at them, with the icon files present, readable and uncached, and the app list
        // rebuilt by iOS itself. Upstream never does any of this: "User applications are installed after boot by
        // native MobileInstallation" (FirmwareKit's README), with AppSync baked into installd by preparation so an
        // unsigned app is accepted, which every iOS 4-capable recipe does (appsync: true). So the .ipa goes to installd
        // through lt-install, and installd unpacks, places and registers the app and tells SpringBoard, which draws
        // the icon as it does for any other app. The hand-written path stays below for iOS 2 and 3, where it has
        // always worked, and as the fallback when installd refuses (a device prepared without AppSync, say).
        if major >= 4, ops.contains("spawn"), !installdRefuses {
            if let installed = try await installThroughInstalld(
                ipa: ipa, bundleID: bundleID, display: display, progress: progress)
            {
                return InstalledApp(name: display, bundleID: bundleID, path: installed, needsRestart: false)
            }
            // installd turned it down. Update 63's report showed AppSync present on the device and named in
            // installd's job, which rules out the explanation this code carried for four updates and points at
            // dyld dropping the insertion instead. If that is what happened, it is fixable here and now, so the
            // marker is renamed and installd gets one more chance before the app is copied in by hand.
            if installdRefuses, !installdRestrictionTried, !installdNeverReached {
                installdRestrictionTried = true
                if await fixInstalldRestriction() {
                    installdRefuses = false
                    progress(0.06, "Trying the device\u{2019}s installer again\u{2026}")
                    if let installed = try await installThroughInstalld(
                        ipa: ipa, bundleID: bundleID, display: display, progress: progress)
                    {
                        log("installd took \(display) once dyld stopped dropping AppSync")
                        return InstalledApp(name: display, bundleID: bundleID, path: installed, needsRestart: false)
                    }
                }
            }
            progress(0.06, "Copying \(display) in by hand\u{2026}")
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
            let entry = user?[bundleID] as? [String: Any]
            var existing = entry?["Container"] as? String
            // Since iOS 5 and 6 write the list themselves (step 6), the entry is in MobileInstallation's shape, and
            // that shape carries Path without always carrying Container. Reading only Container therefore missed an
            // app that was already installed, and a reinstall landed in a brand-new container: two bundles with one
            // bundle ID on disk, which is what put the white box back on iOS 5 after the first install had worked.
            // The container is the bundle's own parent folder, so take it from Path when Container isn't there.
            if existing == nil, let path = entry?["Path"] as? String {
                let root = "/var/mobile/Applications/"
                if path.hasPrefix(root), let slash = path.lastIndex(of: "/") {
                    let parent = String(path[path.startIndex..<slash])
                    if parent.count > root.count { existing = parent }
                }
            }
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

        // 5b. An icon under a name this iOS knows how to look for.
        //
        // The blank white tile has outlived three fixes aimed at SpringBoard's icon cache, and the asymmetry says
        // why: the apps that came through with real icons (on iOS 6) are old ones that ship Icon.png, and the ones
        // that stayed blank are modern builds. iOS 4 has never heard of CFBundleIcons (iOS 5 and up) or of
        // asset-catalog names like AppIcon60x60@2x, so for those bundles SpringBoard falls back to looking for
        // Icon.png, doesn't find it, and draws the blank tile — with nothing wrong with the cache at all.
        //
        // So the app's own icon is also copied to the classic names when they are missing. Two small uploads, and
        // the icon becomes resolvable on every version this installs to. Nothing is overwritten: a bundle that
        // already has Icon.png keeps it.
        if container != nil {
            let top = appPath + "/"
            var onDisk: [String: URL] = [:]
            for file in files where file.guest.hasPrefix(top) {
                let name = String(file.guest.dropFirst(top.count))
                // Top level of the .app only: a Resources/Icon.png is not the one SpringBoard reads.
                if name.isEmpty || name.firstIndex(of: "/") != nil { continue }
                onDisk[name] = file.local
            }
            // Prefer what the bundle actually declares, in the order it declares it, and keep the Retina copy
            // for the Retina name. An app that declares one icon gets it under both names; iOS picks the size.
            func bytes(_ name: String) -> Int {
                guard let url = onDisk[name] else { return 0 }
                return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
            func pick(retina: Bool) -> URL? {
                // Every file the bundle's declared names point at, that actually landed.
                var declared: Set<String> = []
                for name in declaredIcons {
                    let stem = name.hasSuffix(".png") ? String(name.dropLast(4)) : name
                    for candidate in [name, stem + ".png", stem + "@2x.png"] where onDisk[candidate] != nil {
                        declared.insert(candidate)
                    }
                }
                // Biggest wins, not first. This used to walk declaredIcons in order and take the first name that
                // was on disk, and CFBundleIcons lists its files smallest first — so a modern bundle declaring
                // AppIcon29x29, AppIcon40x40, AppIcon57x57, AppIcon60x60 had its 29-point icon copied to Icon.png
                // and the Home screen drew a 29-pixel picture scaled up to 57, which looks like a bug and is one.
                // These names are all the same artwork at different sizes, so the largest file is the best source
                // whichever name iOS ends up reading, and on a Retina device it is what the @2x name wants.
                let (double, single) = (declared.filter { $0.contains("@2x") }, declared.filter { !$0.contains("@2x") })
                let order = retina ? [double, single] : [single, double]
                for group in order {
                    if let best = group.max(by: { bytes($0) < bytes($1) }), let url = onDisk[best] { return url }
                }
                // Nothing the bundle names is there as a file. A build new enough to keep its icons in an asset
                // catalog (Assets.car) has no loose icon at all, and no iOS this old can read one, so the names in
                // Info.plist point at nothing on any of these devices. Two places still hold a real picture of the
                // app: an icon-looking PNG left at the top of the bundle, and the artwork the App Store wrapped the
                // IPA in. Largest first, since these names are all sizes of the same icon.
                let looksLikeIcon = onDisk.keys.filter {
                    let lower = $0.lowercased()
                    return lower.hasSuffix(".png") && lower.contains("icon")
                }
                if let best = looksLikeIcon.max(by: { bytes($0) < bytes($1) }), let url = onDisk[best] { return url }
                if let art = artwork { return art }
                return nil
            }
            for (classic, retina) in [("Icon.png", false), ("Icon@2x.png", true)] where onDisk[classic] == nil {
                guard let source = pick(retina: retina) else { continue }
                if await putFile(localURL: source, guestPath: top + classic, mode: "0644") {
                    try? await runHelper(uid: uid, gid: gid, paths: [top + classic], what: "set the icon\u{2019}s owner")
                    log("Copied \(source.lastPathComponent) to \(classic) so this iOS can find the icon")
                }
            }
        }

        // 6. Register it. iPhone OS 2 and 3 take our word for it: an entry written into the cache by hand is listed
        // and drawn. iOS 4, 5 and 6 don't. iOS 5 drew the icon blank, iOS 6 never put the app on the Home screen at
        // all, and iOS 4 listed the app under its right name and drew the blank tile beside it — however the entry
        // was shaped (placeholders skipped, sequence numbers bumped, icon caches cleared).
        //
        // iOS 4 took four updates to place because the obvious causes were all ruled out one at a time, each by its
        // own evidence: the bundle declares Icon.png, both Icon.png and Icon@2x.png are in the guest at full size,
        // and the device has no SpringBoard icon cache to have gone stale (the install says so now). An app whose
        // icon is right there, readable and uncached, and which still draws blank, is not an app with an icon
        // problem — it is an app iOS never really registered, exactly as on 5 and 6. The entry is enough to get a
        // name onto the Home screen and not enough to get an icon drawn.
        //
        // From iOS 4 up this used to take the cache away and let MobileInstallation rebuild it from the app folders
        // as the Home screen started (the jailbreak-era "delete the plist" fix), on the theory that only an entry
        // iOS had written itself would draw an icon. It did get icons drawn — and on iOS 6 it bricked the session.
        //
        // The order was the problem. The cache went, then SpringBoard was restarted, and only then did step 9 wait
        // half a minute for the rebuild. On a device where MobileInstallation doesn't rebuild (iOS 6 here: "No
        // rebuilt app list after 30 seconds"), SpringBoard came up with no app list at all, fell over, was restarted
        // by launchd, fell over again — the boot loop after an install, with the app never arriving. Putting the old
        // cache back thirty seconds later was far too late: the Home screen was already looping.
        //
        // The icons were never the cache's doing anyway. Step 5b — the app's own icon copied to Icon.png and
        // Icon@2x.png, the names every one of these iOS versions actually looks for — is what put real icons on the
        // Home screen, and it runs whichever way the app was registered. So the gamble is gone: the entry is written
        // by hand, the device always has a complete, valid app list, and there is no window in which it has none.
        var needsRestart = false
        if major >= 2, let container {
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
        // icon caches have to go while SpringBoard is not running: it holds the same cache in memory and writes it
        // back out, so deleting the files under a live SpringBoard (as this did) bought nothing — an icon it had once
        // drawn blank came back blank. Unload keeps launchd from restarting it, the files stay gone, and the Home
        // screen that comes back up has nothing cached and draws every icon from the app bundles.
        // What the bundle says its icon is, and what of that actually reached the guest. A blank icon is either
        // a stale cache (cleared below), an icon iOS can't find, or one that never got copied, and nothing in
        // the log has ever said which.
        if major >= 4 {
            // What SpringBoard looks for when the bundle names nothing.
            let declared = declaredIcons.isEmpty ? ["Icon"] : declaredIcons + ["Icon"]
            log("Icon names in Info.plist: " + (declaredIcons.isEmpty ? "none declared" : declaredIcons.joined(separator: ", ")))
            var found: [String] = []
            for name in Set(declared).sorted() {
                let stem = name.hasSuffix(".png") ? String(name.dropLast(4)) : name
                for candidate in Set([name, stem + ".png", stem + "@2x.png"]).sorted() {
                    if let data = await getFile(appPath + "/" + candidate) {
                        found.append("\(candidate) (\(data.count) B)")
                    }
                }
            }
            log(found.isEmpty
                ? "None of those icon files is in the installed bundle — that is why the icon is blank"
                : "Icon files in the guest: " + found.joined(separator: ", "))
        }

        // 7b. uicache, where the device has it.
        //
        // On iOS 6 an entry written into the installation cache by hand gets the app listed — reading the cache back
        // finds it — and still leaves the Home screen without an icon, because SpringBoard builds its icon list from
        // its own record of what is installed rather than from that file, and nothing has told it to look again.
        // uicache is the jailbreak tool for exactly that: it walks the installed apps and rebuilds the record. It
        // only exists on a jailbroken device, which is also the only kind that can be checked for here, so it is
        // used where it is present and skipped quietly where it isn't.
        if major >= 4, hasShell {
            var found = false
            defer {
                if !found {
                    log("uicache isn\u{2019}t on this device (it comes with uikittools from Cydia). Without it the "
                        + "app is installed and listed but the Home screen may not draw its icon until a restart.")
                }
            }
            for tool in ["/usr/bin/uicache", "/usr/bin/uikittools-uicache"] {
                guard let listed = await spawn(argv: ["/bin/ls", tool]),
                    String(decoding: listed, as: UTF8.self).contains(tool)
                else { continue }
                found = true
                progress(0.96, "Rebuilding the Home screen\u{2019}s app list\u{2026}")
                let r = await run([tool], timeout: 240)
                log(r?.status == 0
                    ? "uicache rebuilt the Home screen\u{2019}s app list"
                    : "uicache did not finish (\(r.map { "exit \($0.status)" } ?? "no answer")); "
                      + "the icon may not appear until the device restarts")
                break
            }
        }

        progress(0.97, "Restarting the Home screen\u{2026}")
        _ = await sync()
        if major >= 2 { _ = await run(["/bin/launchctl", "stop", "com.apple.mobile.installd"], timeout: 15) }
        var cleared = false
        if major >= 4 {
            let plist = "/System/Library/LaunchDaemons/com.apple.SpringBoard.plist"
            let unloaded = await run(["/bin/launchctl", "unload", plist], timeout: 20)
            cleared = (unloaded?.status ?? -1) == 0
            if !cleared { log("Could not hold the Home screen down to clear its icon caches; clearing them anyway") }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // Every name SpringBoard uses across iOS 4-6: on a Retina device (the iPhone 4) the caches are the
            // @2x files, which is why deleting only the plain names left once-blank icons blank forever.
            var removed: [String] = []
            for base in ["icons", "smallicons", "spotlight"] {
                for scale in ["", "@2x"] {
                    for ext in ["", ".plist"] {
                        let name = "com.apple.springboard-imagecache-" + base + scale + ext
                        if await unlink(path: "/var/mobile/Library/Caches/" + name) { removed.append(name) }
                    }
                }
            }
            // Which caches were actually there. A blank icon that survives this says the cache was not the
            // culprit (or is not under one of these names), and that is worth knowing from the log rather
            // than from another round of guessing.
            log(removed.isEmpty
                ? "No SpringBoard icon cache to clear (the blank icon is not a stale cache)"
                : "Cleared \(removed.count) icon cache file(s): " + removed.joined(separator: ", "))
            _ = await sync()
            if cleared {
                let loaded = await run(["/bin/launchctl", "load", plist], timeout: 20)
                if (loaded?.status ?? -1) != 0 {
                    log("The Home screen did not start again by itself; restart the device to bring it back")
                    needsRestart = true
                }
            }
        }
        if !cleared {
            let respring = await run(["/bin/launchctl", "stop", "com.apple.SpringBoard"], timeout: 15)
            if respring == nil || (respring?.status ?? -1) < 0 { needsRestart = true }
        }

        // 9. The app list, read back now that the Home screen has restarted. Nothing is being waited for here — the
        // entry was written before the restart — so this only confirms it survived, and says so plainly if it
        // didn't, which is the one case worth a rebuild of the device rather than another install.
        if major >= 2, container != nil {
            progress(0.98, "Checking \(display) is listed\u{2026}")
            var listed = false
            for attempt in 0..<5 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                guard let data = await getFile(Self.installationCache),
                    let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
                else { continue }
                if (plist["User"] as? [String: Any])?[bundleID] != nil {
                    listed = true
                    break
                }
            }
            if listed {
                log("\(display) is in the device\u{2019}s app list")
                // Listed and still no icon is the other half of "installs don't work", and on a device with no
                // jailbreak there is no uicache to fall back on. If SpringBoard is rejecting the entry we wrote,
                // the entries iOS wrote itself say what it wants.
                if major >= 4 { await compareInstallationEntry(bundleID: bundleID) }
                // And whether SpringBoard put it anywhere. IconState is SpringBoard's own record of what sits on
                // which page; it writes it, nothing else does. An app that is in the installation cache and never
                // reaches IconState is one SpringBoard read and declined to place — which is a different problem
                // from one it never heard about, and the Home screen looks identical either way.
                if major >= 4, let state = await getFile(Self.iconState) {
                    let placed = state.range(of: Data(bundleID.utf8)) != nil
                    log(placed
                        ? "SpringBoard has \(display) in its icon layout"
                        : "SpringBoard\u{2019}s icon layout does NOT mention \(display), so it read the app list and "
                          + "declined to place it \u{2014} the entry is what it is objecting to, not the files")
                }
            } else {
                log("\(display) is on the device at \(appPath) but its app list no longer has the entry "
                    + "(iOS rewrote the list). Restart the device; if the icon is still missing, send this log.")
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
        var user = cache["User"] as? [String: Any] ?? [:]

        // Shape the entry the way THIS iOS shapes its own.
        //
        // Until now the app's whole Info.plist went in: 47 keys against the 19 iOS writes, carrying things no app
        // list has any use for (BuildMachineOSBuild, CFBundleSignature, CFBundleDocumentTypes). The app was listed —
        // reading the cache back always found it — and the Home screen stayed empty even once uicache had run,
        // which is the tool whose entire job is to make SpringBoard look again. An entry that is found but drawn by
        // nothing is an entry SpringBoard is reading and rejecting, and the only shape known to be right is the one
        // iOS used itself, on this device, for its own apps. So that is the template: the keys an entry iOS wrote
        // actually has, plus the handful SpringBoard needs to name and draw a third-party app, plus the four only
        // an installer can know. Everything else is dropped.
        var info = Self.shapedEntry(info, like: cache, log: { self.log($0) })
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


    /// Keys SpringBoard needs for a third-party app whether or not iOS's own entries carry them: its identity, its
    /// name, and where its icon is. A System app's entry has no CFBundleIcons because system icons come from
    /// elsewhere, and dropping them from a User entry would trade a missing app for a blank one.
    static let entryCoreKeys: Set<String> = [
        "CFBundleIdentifier", "CFBundleExecutable", "CFBundleName", "CFBundleDisplayName",
        "CFBundleVersion", "CFBundleShortVersionString", "CFBundleIconFile", "CFBundleIconFiles",
        "CFBundleIcons", "CFBundleSupportedPlatforms", "MinimumOSVersion", "UIDeviceFamily"
    ]

    /// `info` cut down to the keys an entry on this device actually carries.
    ///
    /// The template is an entry iOS wrote itself — a User one if installd has ever placed an app here, otherwise
    /// the richest System one, which is every device. With no template at all (an empty or unreadable cache)
    /// nothing is dropped, because a guess at the shape is worse than the shape we have been using.
    static func shapedEntry(_ info: [String: Any], like cache: [String: Any], log: (String) -> Void) -> [String: Any] {
        func richest(_ section: Any?) -> [String: Any]? {
            (section as? [String: Any])?.values.compactMap { $0 as? [String: Any] }
                .max(by: { $0.keys.count < $1.keys.count })
        }
        guard let template = richest(cache["User"]) ?? richest(cache["System"]), template.count >= 6 else {
            log("App list entry: no entry of iOS's own to copy the shape from; writing the Info.plist as it is")
            return info
        }
        let wanted = Set(template.keys).union(entryCoreKeys)
        let kept = info.filter { wanted.contains($0.key) }
        log("App list entry: shaped like iOS's own (\(template.keys.count) keys: "
            + template.keys.sorted().joined(separator: ", ") + "). Ours: \(info.count) keys in, \(kept.count) kept.")
        return kept
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

    /// Where an .ipa waits for installd.
    ///
    /// PublicStaging is iOS's own staging directory — the one AFC exposes and the one every tool that has ever
    /// driven this API (ideviceinstaller, iTunes) copies a package into before asking for it by name. This used to
    /// use a folder of our own under /var/mobile/Media, which is the same volume and the same owner, and installd
    /// refused every time. Update 66's timing is what made that suspicious: the refusal came **one second** after
    /// lt-install started, on a 21 MB package that cannot even be unzipped in a second on an emulated CPU, so
    /// installd was turning it down before looking inside it — the shape of a path check, not a signature check.
    static let installStaging = "/var/mobile/Media/PublicStaging"
    /// What AFC (and so installation_proxy) calls that folder: paths there are relative to /var/mobile/Media.
    static let mediaRoot = "/var/mobile/Media/"
    /// Where lt-install looks for the path when argv reaches it empty. lt-install.S has this spelled out as a
    /// string, so the two must agree: change one and change the other.
    static let installPathFile = installStaging + "/lt-install.path"

    /// Hands the .ipa to installd (lt-install: MobileInstallationInstall). The app's path once installd has listed
    /// it, or nil when this way didn't work, after saying why, so the caller can install it by hand instead.
    private func installThroughInstalld(
        ipa: URL, bundleID: String, display: String, progress: @escaping (Double, String) -> Void
    ) async throws -> String? {
        progress(0.06, "Preparing the device\u{2026}")
        guard (try? await ensureHelper()) != nil,
            (try? await runHelper(uid: 501, gid: 501, paths: [Self.installStaging],
                what: "make the install folder")) != nil,
            await ensureInstaller()
        else {
            log("installd: the install helpers didn\u{2019}t go in; installing \(display) by hand")
            return nil
        }
        let staged = Self.installStaging + "/" + UUID().uuidString + ".ipa"
        let sent = await putFile(localURL: ipa, guestPath: staged, mode: "0644") { done, total in
            let fraction = Double(done) / Double(max(total, 1))
            progress(0.08 + 0.72 * fraction, "Copying \(display)\u{2026} " + String(format: "%.0f%%", fraction * 100))
        }
        defer {
            Task { @MainActor in
                _ = await self.unlink(path: staged)
                _ = await self.unlink(path: Self.installPathFile)
            }
        }
        guard sent else {
            log("installd: the .ipa didn\u{2019}t copy in; installing \(display) by hand")
            return nil
        }
        try? await runHelper(uid: 501, gid: 501, paths: [staged], what: "hand the .ipa to mobile")
        try Task.checkCancellation()

        // installd unzips, checks (AppSync answers the signature check), places and registers the app. A big app
        // takes it a while on an emulated CPU, so the wait is long; the agent's spawn reports when it has finished.
        progress(0.82, "Installing \(display)\u{2026}")
        // Give installd somewhere to write before asking it for anything, so a refusal leaves its own words behind.
        // installd's job goes back the way the device shipped it before we ask it for anything. Update 64 had
        // rewritten it to capture a stderr installd never writes to, and left a system daemon running from our
        // edit; that is the last thing in this path this app changed and did not control.
        await restoreInstalldJob()
        let started = Date()
        // Two spellings of the same file. installd is handed an absolute path here, but the API has always been
        // driven through installation_proxy, which passes a path relative to /var/mobile/Media ("PublicStaging/
        // foo.ipa") — and a path check that only accepts the relative form would look exactly like what update 66
        // saw. A refusal costs about a second, so both are tried rather than guessed between.
        // The same path, written where lt-install can read it for itself. lt-install takes the path on the command
        // line when it has one, and reads this file when it doesn't: whether argv survives dyld's hand-off into a
        // dynamically linked program with an LC_UNIXTHREAD entry is the one thing in this path nobody has measured,
        // and a one-line file costs nothing next to a refusal that costs an update. If argv does arrive this file is
        // never opened; if it doesn't, the install still happens and lt-install prints a line saying so.
        _ = await putData(Data((staged + "\n").utf8), guestPath: Self.installPathFile, mode: "0644")
        var result = await run([GuestInstallBinary.guestPath, staged], timeout: 900)
        var output = result.map { String(decoding: $0.output, as: UTF8.self) } ?? ""
        func answer(_ text: String) -> Int? {
            text.split(separator: "\n").last { $0.hasPrefix("lt-install: ") }
                .flatMap { Int($0.dropFirst("lt-install: ".count).trimmingCharacters(in: .whitespaces)) }
        }
        // Codes lt-install prints when it never got as far as installd. Separating them from -1 is the whole point
        // of update 69: MobileInstallationInstall returns -1 for a refusal, and lt-install used to print -1 for a
        // missing argument too, so five updates read "installd turned it down" off a line that may have meant
        // "lt-install was handed no path". Nothing downstream of these codes is worth doing.
        let neverReachedInstalld: Set<Int> = [-2, -3, -4, -5, -6, -7, -8]
        // Then as mobile, if root was refused.
        //
        // The same lt-install, the same .ipa and the same options install fine on iOS 4 and 5 and are refused on
        // 6 — so none of the marshalling is wrong, and the one thing this has never varied is who is asking. The
        // agent spawns as root; iTunes installs through installation_proxy as mobile, which owns the staged
        // package and its container. iOS 6 is the release that tightened installd. Root is tried first because
        // that is what 4 and 5 already accept, so nothing that works today changes.
        if let first = answer(output), first != 0, !neverReachedInstalld.contains(first) {
            log("installd: turned it down as root (\(first)); asking again as mobile, which is who "
                + "installation_proxy is when iTunes installs")
            let asMobile = await run([GuestInstallBinary.guestPath, staged, "501"], timeout: 900)
            let mobileText = asMobile.map { String(decoding: $0.output, as: UTF8.self) } ?? ""
            if answer(mobileText) == 0 {
                log("installd took it as mobile. Root was the whole problem.")
                result = asMobile
                output = mobileText
            } else if let code = answer(mobileText) {
                log("installd: and turned it down as mobile too (\(code))")
            }
        }
        if let first = answer(output), first != 0, !neverReachedInstalld.contains(first),
            staged.hasPrefix(Self.mediaRoot)
        {
            let relative = String(staged.dropFirst(Self.mediaRoot.count))
            log("installd: turned down the absolute path (\(answer(output).map(String.init) ?? "?")); "
                + "asking again as \(relative), the way installation_proxy does")
            _ = await putData(Data((relative + "\n").utf8), guestPath: Self.installPathFile, mode: "0644")
            let again = await run([GuestInstallBinary.guestPath, relative], timeout: 900)
            let againText = again.map { String(decoding: $0.output, as: UTF8.self) } ?? ""
            if answer(againText) == 0 {
                result = again
                output = againText
            } else if answer(againText) != nil {
                log("installd: and turned down the relative path too (\(answer(againText).map(String.init) ?? "?"))")
            }
        }
        let code = answer(output)
        guard let code else {
            log("installd: no answer from lt-install (\(result.map { "status \($0.status)" } ?? "timed out")"
                + (output.isEmpty ? "" : ": " + output.trimmingCharacters(in: .whitespacesAndNewlines))
                + "); installing \(display) by hand")
            return nil
        }
        guard code == 0 else {
            let why: String
            switch code {
            case -2, -3: why = "a system framework it needs would not load"
            case -4, -5: why = "this iOS has no MobileInstallationInstall"
            case -6: why = "the path could not be passed on"
            case -7: why = "lt-install was started with no path at all \u{2014} installd was never called, so every "
                + "earlier refusal that read as installd\u{2019}s may have been this instead. argv is not reaching "
                + "the program through dyld\u{2019}s hand-off"
            case -8: why = "lt-install was handed a null path \u{2014} installd was never called"
            default: why = "installd turned it down (the usual reason is an unsigned app on a device whose installd "
                + "didn\u{2019}t get AppSync, but installd does not say which)"
            }
            // Everything lt-install printed, not just the code: installd's own words are the only way to tell a
            // signature refusal from a malformed .ipa or a full disk, and without them every failure has read as
            // "no AppSync" whether or not that was true.
            let detail = output
                .split(separator: "\n")
                .filter { !$0.hasPrefix("lt-install: ") }
                .joined(separator: " / ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // installd's own words, out of ASL — the one place they have ever been. Pointing its stderr at a file
            // caught nothing across three updates because installd does not use stderr.
            let said = await installdSaid(onOrAfter: started.addingTimeInterval(-120))
            log("installd: \(display) not installed, code \(code): \(why)"
                + (detail.isEmpty ? "" : " — lt-install said: " + detail)
                + (said.isEmpty ? " — and nothing in ASL mentions it, so either installd never ran at all or its "
                                + "store is somewhere this build doesn\u{2019}t look"
                                : " — ASL has this: " + said)
                + "; installing it by hand instead")
            // Whether AppSync is actually on this device, since "no AppSync" is the thing everyone assumes and
            // nobody has checked. Preparation is supposed to put libappsync.dylib on the system volume and name it
            // in installd's job so dyld inserts it. Both halves are files the agent can read, so read them: if the
            // dylib is missing, preparation didn't bake it; if it is there and the job doesn't name it, the job
            // edit didn't take; if both are right, AppSync is innocent and installd refused for some other reason
            // entirely — which is worth knowing before another update is spent on the wrong suspect.
            if !neverReachedInstalld.contains(code) {
                let dylib = await getFile("/usr/lib/libappsync.dylib")
                var named = false
                var jobFound = false
                for job in ["com.apple.mobile.installd", "com.apple.installd"] {
                    guard let data = await getFile("/System/Library/LaunchDaemons/\(job).plist"),
                        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                    else { continue }
                    jobFound = true
                    let env = plist["EnvironmentVariables"] as? [String: String] ?? [:]
                    if (env["DYLD_INSERT_LIBRARIES"] ?? "").contains("libappsync") { named = true }
                    break
                }
                log("AppSync on this device: libappsync.dylib \(dylib == nil ? "MISSING" : "present (\(dylib!.count) bytes)"), "
                    + "installd's job \(jobFound ? (named ? "names it" : "does NOT name it") : "could not be read")"
                    + (dylib != nil && named
                       ? " \u{2014} so AppSync is baked in and installd refused for another reason; send this log."
                       : " \u{2014} that is why it was refused. Rebuilding the device should fix it."))
            }
            // Don't pay for this twice. The next app this session goes straight to the hand install instead of
            // copying a whole .ipa in first only to be turned down again — that upload is half the time a big
            // install takes, and it was being spent on a refusal that never changes within a boot.
            installdRefuses = true
            if neverReachedInstalld.contains(code) { installdNeverReached = true }
            return nil
        }
        // installd has written the app list before it answers: the entry says where the app went.
        var path = "(installed by installd)"
        if let data = await getFile(Self.installationCache),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let entry = (plist["User"] as? [String: Any])?[bundleID] as? [String: Any],
            let listed = entry["Path"] as? String
        {
            path = listed
        }
        log("installd installed \(display) (\(bundleID)) at \(path) in \(Int(Date().timeIntervalSince(started))) s")
        progress(1, "Installed \(display)")
        return path
    }

    /// Puts lt-install into the guest once per session; false if it can't.
    func ensureInstaller() async -> Bool {
        if installReady { return true }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lt-install")
        guard (try? GuestInstallBinary.data.write(to: tmp)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard await putFile(localURL: tmp, guestPath: GuestInstallBinary.guestPath, mode: "0755") else {
            log("Could not put lt-install into the device")
            return false
        }
        installReady = true
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
