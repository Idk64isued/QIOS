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
