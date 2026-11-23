import Foundation
import ZIPFoundation

// Why an app quits the moment it opens.
//
// FIFA 14 on iOS 6.1.3 shows its launch image and is gone within a second, and the log has nothing to say: it never
// creates a GL context, so the graphics layer never hears from it, and launchd doesn't log a crashed app. iOS itself
// does, though. ReportCrash writes every crash to /var/mobile/Library/Logs/CrashReporter and points LatestCrash.plist
// at the newest one: the process, the exception, the crashed thread's stack and, for an app that never got as far as
// main(), dyld's own message ("Symbol not found", "Library not loaded"). That file is read here, and the lines that
// matter go into the log the first time each crash is seen.
//
// The other reason an app can't start is that its code isn't for this CPU at all (an armv7s-only binary needs an
// iPhone 5; an iPhone 4 runs armv7). iOS refuses that without writing a crash report, so the installer says so at
// install time instead (binarySlices).
extension GuestAgent {
    static let crashReporter = "/var/mobile/Library/Logs/CrashReporter/"
    /// Posted with a one-line reason (the notification's object, a String) when an app on the device crashes, for
    /// the running-device screen to show.
    static let crashNotification = Notification.Name("LTMGuestCrash")

    /// Logs the device's newest crash report, once per distinct report. Called from the watch loop every 30 s.
    func reportNewCrash() async {
        guard ops.contains("get") else { return }
        guard let data = await getFile(Self.crashReporter + "LatestCrash.plist"), !data.isEmpty else {
            // Said once, so a log with no crash lines can be told from a session that never looked.
            if lastCrashSeen == nil {
                lastCrashSeen = "none"
                log("No crash report on the device yet (\(Self.crashReporter)LatestCrash.plist)")
            }
            return
        }
        let digest = String(data.count) + ":" + String(data.prefix(4096).hashValue)
        guard digest != lastCrashSeen else { return }
        let first = lastCrashSeen == nil
        lastCrashSeen = digest
        guard let lines = Self.crashSummary(data) else {
            log("Crash report on the device (LatestCrash.plist, \(data.count) bytes) could not be read as text")
            return
        }
        log((first ? "Newest crash report on the device" : "NEW crash report on the device")
            + " (LatestCrash.plist):")
        for line in lines { log("  " + line) }
        // A crash that happened while we watched gets a banner; one already there at boot is old news.
        if !first {
            NotificationCenter.default.post(name: Self.crashNotification, object: Self.crashHeadline(lines))
        }
    }

    /// One line a person can read: which app, and why, in the words that say the most.
    static func crashHeadline(_ lines: [String]) -> String {
        func value(_ key: String) -> String? {
            lines.first { $0.hasPrefix(key) }.map { $0.dropFirst(key.count).trimmingCharacters(in: .whitespaces) }
        }
        let process = value("Process:").map { $0.components(separatedBy: " [").first ?? $0 } ?? "An app"
        if let i = lines.firstIndex(where: { $0.hasPrefix("Dyld Error Message:") }), i + 1 < lines.count {
            let reason = lines[i + 1].trimmingCharacters(in: .whitespaces)
            if reason.contains("Symbol not found") || reason.contains("Library not loaded") {
                return "\(process) crashed: it needs something this iOS doesn\u{2019}t have (\(reason))."
            }
            return "\(process) crashed before it started: \(reason)"
        }
        if let exception = value("Exception Type:") {
            return "\(process) crashed (\(exception)). The log has the details."
        }
        return "\(process) crashed. The log has the details."
    }

    /// Why this device can't run the app in an .ipa, read from its Info.plist and the first bytes of its executable,
    /// or nil if nothing says it can't. For the question before an install; the installer logs the same findings.
    nonisolated static func installProblem(ipa: URL, iosVersion: String?) -> String? {
        guard let archive = try? ZIPFoundation.Archive(url: ipa, accessMode: .read) else { return nil }
        var infoEntry: ZIPFoundation.Entry?
        for entry in archive where entry.type == .file {
            let parts = entry.path.split(separator: "/")
            if parts.count == 3, parts[0] == "Payload", parts[1].hasSuffix(".app"), parts[2] == "Info.plist" {
                infoEntry = entry
                break
            }
        }
        guard let infoEntry else { return nil }
        var infoData = Data()
        _ = try? archive.extract(infoEntry, skipCRC32: true) { infoData.append($0) }
        guard let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        else { return nil }
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "This app"
        var problems: [String] = []
        if let executable = info["CFBundleExecutable"] as? String,
            let exeEntry = archive[infoEntry.path.replacingOccurrences(of: "Info.plist", with: executable)]
        {
            // The headers only: stop reading once there are 4 KB of them.
            struct Enough: Error {}
            var head = Data()
            _ = try? archive.extract(exeEntry, bufferSize: 4096, skipCRC32: true) { chunk in
                head.append(chunk)
                if head.count >= 4096 { throw Enough() }
            }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("lt-head-\(UUID().uuidString)")
            if (try? head.write(to: temp)) != nil {
                let slices = binarySlices(temp)
                try? FileManager.default.removeItem(at: temp)
                if !slices.isEmpty, !slices.contains(where: { ["armv6", "armv7"].contains($0) }) {
                    problems.append("its code is only for " + slices.joined(separator: " and ")
                        + ", which needs a newer iPhone than this device (it runs armv7), so it will quit as soon as it opens")
                }
            }
        }
        if let minimum = info["MinimumOSVersion"] as? String, let have = iosVersion,
            minimum.compare(have, options: .numeric) == .orderedDescending
        {
            problems.append("it needs iOS \(minimum) and this device runs iOS \(have)")
        }
        return problems.isEmpty ? nil : "\(name) probably won\u{2019}t run here: " + problems.joined(separator: "; ") + "."
    }

    /// The lines of a crash report worth reading: who crashed, when, how, dyld's reason if there is one, and the top
    /// of the crashed thread. Nil if the report isn't text (or a plist wrapping text).
    static func crashSummary(_ data: Data) -> [String]? {
        var text: String?
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            text = plist["description"] as? String ?? plist["SymbolicatedCrashReport"] as? String
        }
        if text == nil { text = String(data: data, encoding: .utf8) }
        guard let report = text, !report.isEmpty else { return nil }
        let lines = report.components(separatedBy: .newlines)
        let headers = ["Process:", "Path:", "Version:", "Date/Time:", "OS Version:", "Hardware Model:",
                       "Exception Type:", "Exception Codes:", "Crashed Thread:", "Termination Reason:"]
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if headers.contains(where: { trimmed.hasPrefix($0) }) {
                out.append(trimmed)
            } else if trimmed.hasPrefix("Dyld Error Message:") || trimmed.hasPrefix("Application Specific Information:") {
                // The reason itself is on the lines after the heading.
                out.append(trimmed)
                var k = i + 1
                while k < lines.count, k <= i + 4, !lines[k].trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append("  " + lines[k].trimmingCharacters(in: .whitespaces))
                    k += 1
                }
                i = k
                continue
            } else if trimmed.range(of: #"^Thread \d+ Crashed"#, options: .regularExpression) != nil {
                out.append(trimmed)
                var k = i + 1
                while k < lines.count, k <= i + 10, !lines[k].trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append("  " + lines[k].trimmingCharacters(in: .whitespaces))
                    k += 1
                }
                i = k
                continue
            }
            i += 1
        }
        return out.isEmpty ? Array(lines.prefix(20)) : out
    }

    /// The CPU types an app's executable carries, by name: ["armv7", "armv7s"] for a fat binary, ["armv7"] for a thin
    /// one. Empty if the file isn't Mach-O. Only the headers are read.
    nonisolated static func binarySlices(_ url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 8 else { return [] }
        let bytes = [UInt8](head)
        func be32(_ o: Int) -> UInt32 {
            guard o + 4 <= bytes.count else { return 0 }
            return UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3])
        }
        func le32(_ o: Int) -> UInt32 {
            guard o + 4 <= bytes.count else { return 0 }
            return UInt32(bytes[o + 3]) << 24 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o])
        }
        func name(_ type: UInt32, _ subtype: UInt32) -> String {
            let sub = subtype & 0x00FF_FFFF
            switch type {
            case 12:
                switch sub {
                case 5: return "armv4t"
                case 6: return "armv6"
                case 7: return "armv5"
                case 9: return "armv7"
                case 10: return "armv7f"
                case 11: return "armv7s"
                case 12: return "armv7k"
                default: return "arm(\(sub))"
                }
            case 0x0100_000C: return sub == 2 ? "arm64e" : "arm64"
            case 7: return "i386"
            case 0x0100_0007: return "x86_64"
            default: return "cpu(\(type))"
            }
        }
        let magic = be32(0)
        if magic == 0xCAFE_BABE || magic == 0xCAFE_BABF {
            let count = Int(be32(4))
            let entry = magic == 0xCAFE_BABE ? 20 : 32
            guard count > 0, count <= 16 else { return [] }
            return (0..<count).map { name(be32(8 + $0 * entry), be32(12 + $0 * entry)) }
        }
        if le32(0) == 0xFEED_FACE || le32(0) == 0xFEED_FACF {
            return [name(le32(4), le32(8))]
        }
        return []
    }
}
