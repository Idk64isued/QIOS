import Foundation

// Why installd turns down an app on a device that has AppSync.
//
// Update 63 asked the device instead of assuming, and the answer closed off the explanation this project had been
// carrying for four updates:
//
//     AppSync on this device: libappsync.dylib present (134624 bytes), installd's job names it
//
// Both halves of the bake are correct. The dylib is on the system volume and installd's launchd job names it in
// DYLD_INSERT_LIBRARIES. installd refuses anyway — so it is not loading the library it is told to load.
//
// dyld drops every DYLD_* variable for a process it considers restricted, and one of the things that makes a
// process restricted is an empty __RESTRICT/__restrict section in its executable. That is exactly what Apple put in
// installd, and FirmwareKit already knows about it: SideloadInsertion.installationServiceAllowingHelper renames the
// marker so the insertion survives. Preparation only calls it for iOS 8 and later ("Older profiles are intact"),
// and on this iOS 6 device the evidence says that assumption does not hold.
//
// So this checks the device's own installd. If it carries the marker, the same rename FirmwareKit does is applied
// here, through the agent, to the file in place: the section is renamed, nothing else is touched, no byte moves and
// no size changes. The original is kept beside it. If the marker is not there, nothing is changed and the log says
// so, which rules the theory out rather than leaving it to be assumed again.
//
// No re-signing: every prepared device boots with cs_enforcement_disable=1 and amfi_allow_any_signature=1, and the
// kernel log confirms it ("signature enforcement disabled by boot-arg"), so the edited binary runs as it is. That
// is also why this can be done to a device already built instead of only to one prepared again.

enum InstallDRestriction {
    static let path = "/usr/libexec/installd"
    static let backup = path + ".ltm-old"
    /// What FirmwareKit renames the marker to, reused so a device carries one spelling either way.
    static let marker = "__qemu_appsync"

    enum Finding {
        /// The marker is there, at this offset of the section name (16 bytes).
        case restricted(at: Int)
        /// No marker: dyld is not dropping the insertion, and the refusal is something else.
        case notRestricted
        /// Already renamed by this, or by preparation.
        case alreadyFixed
        case unreadable(String)
    }

    /// Looks for the empty __RESTRICT/__restrict section in a 32-bit ARM Mach-O, the way
    /// SideloadInsertion.installationServiceAllowingHelper does: one thin image, and a marker with no size at all.
    static func find(in image: Data) -> Finding {
        func word(_ at: Int) -> UInt32? {
            guard at >= 0, at + 4 <= image.count else { return nil }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(image[image.startIndex + at + $1]) << ($1 * 8) }
        }
        func name(_ at: Int) -> String? {
            guard at >= 0, at + 16 <= image.count else { return nil }
            let bytes = image[(image.startIndex + at)..<(image.startIndex + at + 16)]
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        // MH_MAGIC, 32-bit little-endian, CPU_TYPE_ARM.
        guard let magic = word(0) else { return .unreadable("installd is too short to be a program") }
        guard magic == 0xfeed_face else {
            // A fat header is stored big-endian, so read little-endian it comes back byte-swapped.
            let fat = magic == 0xcafe_babe || magic == 0xbeba_feca
            return .unreadable(fat
                ? "installd is a fat binary, which this does not edit"
                : String(format: "installd does not start like a 32-bit ARM program (0x%08x)", magic))
        }
        guard word(4) == 12 else { return .unreadable("installd is not an ARM program") }
        guard let ncmds = word(16), ncmds < 4096 else { return .unreadable("installd has no load commands") }

        var offset = 28  // past the 32-bit Mach-O header
        var renamed = false
        for _ in 0..<ncmds {
            guard let cmd = word(offset), let size = word(offset + 4), size >= 8,
                offset + Int(size) <= image.count
            else { return .unreadable("installd's load commands do not add up") }
            defer { offset += Int(size) }
            guard cmd == 1 /* LC_SEGMENT */, size >= 56 else { continue }
            guard let segment = name(offset + 8) else { continue }
            if segment == marker { renamed = true; continue }
            guard segment == "__RESTRICT" else { continue }
            guard let nsects = word(offset + 48), nsects <= (size - 56) / 68 else { continue }
            for index in 0..<Int(nsects) {
                let section = offset + 56 + index * 68
                guard name(section) == "__restrict", name(section + 16) == "__RESTRICT" else {
                    if name(section) == marker { renamed = true }
                    continue
                }
                // Empty, as the marker is: a segment and section with no size at all. Anything else is a real
                // __RESTRICT with contents, and renaming it would change what the program does.
                guard word(offset + 28) == 0, word(offset + 36) == 0, word(section + 36) == 0 else {
                    return .unreadable("installd's __RESTRICT section is not the empty dyld marker")
                }
                return .restricted(at: section)
            }
        }
        return renamed ? .alreadyFixed : .notRestricted
    }

    /// The same image with the marker renamed. Nothing moves: 16 bytes are overwritten in place.
    static func renamed(_ image: Data, at section: Int) -> Data {
        var out = image
        var bytes = Data(marker.utf8)
        bytes.append(contentsOf: repeatElement(0, count: 16 - bytes.count))
        out.replaceSubrange((out.startIndex + section)..<(out.startIndex + section + 16), with: bytes)
        return out
    }
}

extension GuestAgent {
    /// Checks this device's installd for the dyld restriction marker and, if it is there, renames it so the
    /// AppSync insertion is honoured. True when something changed and installd is worth trying again.
    func fixInstalldRestriction() async -> Bool {
        guard ops.contains("get"), ops.contains("getrange"), ops.contains("unlink"),
            ops.contains("put") || ops.contains("putpart")
        else { return false }
        guard let image = await getFile(InstallDRestriction.path), !image.isEmpty else {
            log("installd: couldn\u{2019}t read \(InstallDRestriction.path) to check why it refused")
            return false
        }

        switch InstallDRestriction.find(in: image) {
        case .notRestricted:
            log("installd: carries no dyld restriction marker, so the AppSync insertion is not being dropped for "
                + "that reason \u{2014} it refused for something else. Send this log.")
            return false
        case .alreadyFixed:
            log("installd: its dyld restriction marker was already renamed, so AppSync should be loading. "
                + "It refused for something else. Send this log.")
            return false
        case .unreadable(let why):
            log("installd: \(why); left alone")
            return false
        case .restricted(let section):
            log("installd: it carries dyld\u{2019}s restriction marker (an empty __RESTRICT section), which makes "
                + "dyld drop DYLD_INSERT_LIBRARIES \u{2014} so AppSync was never loading, whatever the job said. "
                + "Renaming the marker, as preparation does for iOS 8 and later\u{2026}")
            // Keep the original once, so a device can always be put back.
            if await getFile(InstallDRestriction.backup) == nil {
                guard await putData(image, guestPath: InstallDRestriction.backup, mode: "0755") else {
                    log("installd: couldn\u{2019}t save the original; left alone. \(lastLog)")
                    return false
                }
            }
            let patched = InstallDRestriction.renamed(image, at: section)
            // Unlink first: installd is running and has its own text mapped. A fresh file leaves that copy alone
            // until launchd starts it again.
            guard await unlink(path: InstallDRestriction.path) else {
                log("installd: couldn\u{2019}t replace it; left alone. \(lastLog)")
                return false
            }
            guard await putData(patched, guestPath: InstallDRestriction.path, mode: "0755"),
                let check = await getFile(InstallDRestriction.path), check == patched
            else {
                _ = await unlink(path: InstallDRestriction.path)
                let back = await putData(image, guestPath: InstallDRestriction.path, mode: "0755")
                log("installd: the edit didn\u{2019}t write correctly; "
                    + (back ? "the original is back" : "PUTTING THE ORIGINAL BACK FAILED, rebuild the device"))
                return false
            }
            await sync()
            // It has to start again to be re-inserted: the running one is the unpatched text.
            _ = await run(["/bin/launchctl", "stop", "com.apple.mobile.installd"], timeout: 20)
            log("installd: marker renamed and installd restarted; AppSync should load into it now")
            return true
        }
    }
}

// MARK: - Making installd say why

// Three explanations for installd's refusal have now died on evidence: AppSync is baked in and named in its job
// (update 63), the dyld restriction marker that would drop that insertion is not there (update 64), and the .ipa
// reaches the device intact. What is left is `code -1` from MobileInstallationInstall, which is the API saying no
// without saying why.
//
// installd is not silent, though — it writes to its own stderr, and its launchd job sends that nowhere. That job is
// a plist on the system volume, which the agent can read and write, so the fix is to give it somewhere to write and
// then read it back after a refusal. No guest binary to rebuild and no emulator change: installd's own words, in
// the log, next to the code.
//
// This matters most on a device that is NOT jailbroken. There, the hand-install fallback can place the app and list
// it and still not get an icon drawn, because SpringBoard was never told, and `uicache` — the tool that would tell
// it — comes from Cydia and so does not exist. Making installd do the install is the only route on such a device,
// which makes knowing why it refuses the thing everything else waits on.

enum InstallDLog {
    /// Where installd's stderr is pointed. On the data volume, which is writable on every prepared device.
    static let path = "/var/mobile/Media/LightTouch/installd.log"
    static let jobs = [
        "/System/Library/LaunchDaemons/com.apple.mobile.installd.plist",
        "/System/Library/LaunchDaemons/com.apple.installd.plist"
    ]
}

extension GuestAgent {
    /// Points installd's stderr at a file we can read, once per boot. Quiet if it is already pointed there.
    /// The job plist is backed up first and put back if it will not load again.
    func ensureInstalldLogging() async {
        guard !installdLoggingReady, ops.contains("get"), ops.contains("spawn"),
            ops.contains("put") || ops.contains("putpart")
        else { return }
        installdLoggingReady = true   // once per boot either way: a failure here must not retry every install

        for job in InstallDLog.jobs {
            guard let data = await getFile(job),
                var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            if plist["StandardErrorPath"] as? String == InstallDLog.path { return }

            plist["StandardErrorPath"] = InstallDLog.path
            plist["StandardOutPath"] = InstallDLog.path
            guard let edited = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            else { return }
            // Keep the original: if the edited job will not load, installd must come back as it was.
            let backup = job + ".ltm-old"
            if await getFile(backup) == nil { _ = await putData(data, guestPath: backup, mode: "0644") }
            guard await putData(edited, guestPath: job, mode: "0644") else {
                log("installd: couldn\u{2019}t point its log anywhere. \(lastLog)")
                return
            }
            _ = await run(["/bin/launchctl", "unload", job], timeout: 20)
            let loaded = await run(["/bin/launchctl", "load", job], timeout: 20)
            if (loaded?.status ?? -1) != 0 {
                log("installd: it would not start with its log redirected; putting its job back")
                _ = await putData(data, guestPath: job, mode: "0644")
                _ = await run(["/bin/launchctl", "load", job], timeout: 20)
                return
            }
            log("installd: its messages now go to \(InstallDLog.path), so a refusal can say why")
            return
        }
    }

    /// How much installd has written so far, so only what a given install adds is read back.
    func installdLogSize() async -> Int { await getFile(InstallDLog.path)?.count ?? 0 }

    /// What installd wrote past `since`, trimmed for the log.
    func installdLogTail(since: Int) async -> String {
        guard let data = await getFile(InstallDLog.path), data.count > since else { return "" }
        let text = String(decoding: data.dropFirst(since), as: UTF8.self)
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(8).joined(separator: " / ")
    }

    /// What iOS puts in an app's entry that this app's hand-written one does not.
    ///
    /// On iOS 6 a hand-written installation-cache entry gets the app listed — reading the cache back finds it — and
    /// still leaves the Home screen without an icon. Either SpringBoard is not reading that file, or it is reading
    /// it and rejecting the entry. The device already holds entries iOS wrote itself, so the two can be compared
    /// instead of guessed at: if a key is missing, this says which.
    func compareInstallationEntry(bundleID: String) async {
        guard let data = await getFile(Self.installationCache),
            let cache = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }
        let ours = (cache["User"] as? [String: Any])?[bundleID] as? [String: Any]
        guard let ours else { return }
        // iOS wrote every System entry itself, so their shape is this firmware's own.
        guard let system = cache["System"] as? [String: Any],
            let theirs = system.values.compactMap({ $0 as? [String: Any] })
                .max(by: { $0.keys.count < $1.keys.count })
        else { return }

        // Keys that only make sense for one kind of app are not evidence of anything.
        let expected: Set<String> = ["ApplicationType", "Container", "Path", "EnvironmentVariables",
                                     "SequenceNumber", "CFBundleIdentifier"]
        let missing = Set(theirs.keys).subtracting(ours.keys).subtracting(expected).sorted()
        let extra = Set(ours.keys).subtracting(theirs.keys).subtracting(expected).sorted()
        log("App list entry: ours has \(ours.keys.count) keys, one iOS wrote has \(theirs.keys.count)."
            + (missing.isEmpty ? " Nothing iOS writes is missing from ours."
                               : " Missing from ours: " + missing.prefix(12).joined(separator: ", ") + ".")
            + (extra.isEmpty ? "" : " Only in ours: " + extra.prefix(8).joined(separator: ", ") + "."))
    }
}
