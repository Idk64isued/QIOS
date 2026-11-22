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
    /// installd's job, whose stderr update 64 pointed at a file we could read. Kept only so a device that still
    /// carries that edit can be put back (see restoreInstalldJob).
    static let jobs = [
        "/System/Library/LaunchDaemons/com.apple.mobile.installd.plist",
        "/System/Library/LaunchDaemons/com.apple.installd.plist"
    ]
    /// Where that edit pointed it. Nothing reads this any more; installd reports through ASL, never stderr.
    static let path = "/var/mobile/Media/LightTouch/installd.log"
    /// Where ASL keeps its store. installd's own words are in here and nowhere else.
    static let asl = "/var/log/asl"
}

extension GuestAgent {
    /// Puts installd's job back the way the device shipped it.
    ///
    /// Update 64 rewrote that job to point installd's stderr at a file, so that a refusal could say why. It never
    /// said anything: installd reports through ASL and not stderr, which three updates' worth of empty log files
    /// established. What the edit did do was unload and reload a system daemon two seconds before asking it to
    /// install something — the guest's own syslog shows installd being SIGKILLed — and leave it running from a job
    /// this app had rewritten. That is the last thing in the install path that this app changes and does not
    /// control, so it is going back, whether or not it was the reason installd said no.
    func restoreInstalldJob() async {
        guard !installdJobChecked, ops.contains("get"), ops.contains("put") || ops.contains("putpart") else { return }
        installdJobChecked = true
        for job in InstallDLog.jobs {
            let backup = job + ".ltm-old"
            guard let original = await getFile(backup), !original.isEmpty else { continue }
            guard await putData(original, guestPath: job, mode: "0644") else {
                log("installd: couldn\u{2019}t put its job back. \(lastLog)")
                continue
            }
            _ = await unlink(path: backup)
            _ = await unlink(path: InstallDLog.path)
            await sync()
            log("installd: its job is back the way the device shipped it (update 64 had rewritten it to capture a "
                + "stderr that installd never writes to). Reboot the device so launchd reloads it.")
            return
        }
    }

    /// What installd itself said, out of ASL.
    ///
    /// This is the one place installd's refusal reason has ever been. It reports through ASL, so pointing its
    /// stderr at a file caught nothing, and `syslog` only exists on a jailbroken device. The store itself is a
    /// plain file on every device: `/var/log/asl/<date>.asl`, plus a per-uid store for messages only root may read,
    /// which is where a daemon's are. The names are made from the date rather than listed, because listing needs a
    /// shell that stock iOS 6 has not got.
    ///
    /// The format is a record stream, but every value in it is a NUL-terminated string, so the messages can be
    /// recovered by reading the printable runs — enough to see what installd said, which is all this is for.
    func installdSaid(onOrAfter when: Date) async -> String {
        guard ops.contains("get") else { return "" }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyy.MM.dd"
        // Today and yesterday in the guest's own reckoning, since its clock is set from ours but the store rolls
        // over at UTC midnight.
        var names: [String] = []
        for back in 0...1 {
            let day = stamp.string(from: when.addingTimeInterval(TimeInterval(-86400 * back)))
            names += ["\(day).asl", "\(day).U0.asl", "\(day).G80.asl", "\(day).U501.asl"]
        }
        for name in names {
            guard let data = await getFile(InstallDLog.asl + "/" + name), data.count > 16 else { continue }
            let said = Self.aslMessages(in: data, mentioning: "install")
            if !said.isEmpty {
                return "ASL \(name): " + said.suffix(6).joined(separator: " / ")
            }
        }
        return ""
    }

    /// The printable runs in an ASL store that mention `needle`, longest-last, de-duplicated.
    static func aslMessages(in data: Data, mentioning needle: String) -> [String] {
        var runs: [String] = []
        var current: [UInt8] = []
        for byte in data {
            if byte >= 0x20, byte < 0x7f {
                current.append(byte)
                continue
            }
            if current.count >= 12, let text = String(bytes: current, encoding: .utf8),
                text.lowercased().contains(needle.lowercased())
            {
                runs.append(text)
            }
            current.removeAll(keepingCapacity: true)
        }
        if current.count >= 12, let text = String(bytes: current, encoding: .utf8),
            text.lowercased().contains(needle.lowercased())
        {
            runs.append(text)
        }
        var seen = Set<String>()
        return runs.filter { seen.insert($0).inserted }
    }
}

extension GuestAgent {
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
