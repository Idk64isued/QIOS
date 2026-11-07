// Help > Copy Bug Report Info: a short plain-text summary (the build, the Mac, the devices, recent errors) fenced as
// a Markdown code block, for the bug report form's "Light Touch info" field. Identity is scrubbed
// (DiagnosticsExport.scrub) before it reaches the clipboard.

import Foundation
import HostRuntime
import HostServiceWire

public nonisolated enum BugReportInfo {
    /// One device's facts, as the app knows them; nil members are left out of the block.
    public struct Device: Sendable {
        public var marketingName: String
        public var board: String
        public var iosVersion: String
        public var iosBuild: String
        public var entryID: String
        /// The window's status line ("Running", "Powered off", ...), or "Not running" without a session.
        public var state: String
        /// A zoom other than Fit (ZoomMode.defaultsValue).
        public var zoom: String?
        /// A free-form panel ("WxH").
        public var panel: String?
        public var internet: Bool?
        public var localNetwork: Bool
        public var guestTools: String?
        public var emulatorBuild: String?
        public var recipeVersion: Int?
        public var skipSetup: Bool?
        public var jailbreak: Bool?
        /// Prepared through the experimental volume writer (Settings ▸ General).
        public var withoutMounting = false
        /// Sandbox patch of a jailbroken base, from the lock's fit record: "applied", "not needed" or "not found".
        public var sandboxPatch: String?
        public var prepared: Date?
        /// readStorage's lines: the record's format, a storage migration under way, cut short or failed, the 3GS
        /// audio clock repair.
        public var storage: [String] = []
        /// The device's notices (DeviceNotices), as the window shows them.
        public var notices: [String] = []
        /// "off", or "archive (yyyyMMdd)"; nil is the default, direct.
        public var webProxy: String?
        /// The tweaks that are on (Tweak.title).
        public var tweaks: [String] = []
        /// The guest's Accessibility features that are on, when read this boot.
        public var accessibility: [String] = []
        public var carrier: CarrierSettings?
        /// The installed list, when the device has answered.
        public var apps: [InstalledApp]?

        public init(
            marketingName: String,
            board: String,
            iosVersion: String,
            iosBuild: String,
            entryID: String,
            state: String,
            localNetwork: Bool
        ) {
            self.marketingName = marketingName
            self.board = board
            self.iosVersion = iosVersion
            self.iosBuild = iosBuild
            self.entryID = entryID
            self.state = state
            self.localNetwork = localNetwork
        }

        /// The recipe, Skip Setup, jailbroken or stock and the sandbox patch, as the base's lock records them.
        public mutating func readPreparation(_ lock: DeviceLock) {
            recipeVersion = lock.recipeVersion
            skipSetup = lock.skippedSetup
            jailbreak = lock.jailbroken
            withoutMounting = lock.preparedWithoutMounting
            guard lock.jailbroken, case .array(let fits) = lock.other["fit"],
                let fit = fits.first(where: { $0["piece"]?.string == "sandbox patch (sb_evaluate)" }),
                let proof = fit["proof"]?.string
            else { return }
            sandboxPatch =
                fit["fits"]?.bool != true ? "not found" : proof.hasPrefix("sb_evaluate at") ? "applied" : "not needed"
        }

        /// The device's settings that change what it does: its notices, a web proxy other than direct, the tweaks
        /// that are on, and the Accessibility features the guest said are on this boot.
        public mutating func readSettings(
            _ settings: DeviceSettings,
            proxy: WebProxyConfiguration,
            accessibilityOn: Set<AccessibilityFeature>?
        ) {
            notices = (settings.deviceNotices ?? settings.deviceNotice.map { [$0] } ?? []).map(\.message)
            switch proxy.mode {
            case .direct: webProxy = nil
            case .off: webProxy = "off"
            case .archive: webProxy = "archive (\(proxy.archiveDate))"
            }
            tweaks = Tweak.allCases.filter { settings.tweaks?.isOn($0) == true }.map(\.title)
            accessibility = AccessibilityFeature.allCases.filter { accessibilityOn?.contains($0) == true }
                .map { $0.title(version: iosVersion) }
        }

        /// What the device's folder says of its storage (DeviceRecord's formats, K48NANDMigration's files): the
        /// format, a migration under way or cut short, the last one that failed (`firmwareLog`, firmwarekit's
        /// stderr), the format 1 copy kept until a clean stop, and a 3GS's repaired kboot.bin in the overlay.
        /// `migrates`: the base is the device's own, so a format 1 store migrates at the next start.
        public mutating func readStorage(
            directory: URL,
            format: Int,
            migrates: Bool,
            overlay: URL,
            firmwareLog: URL
        ) {
            let fm = FileManager.default
            func has(_ path: String) -> Bool { fm.fileExists(atPath: directory.appendingPathComponent(path).path) }
            let kind =
                switch format {
                case 1: "Storage: page files (format 1)" + (migrates ? ", migrates at the next start" : "")
                case DeviceRecord.imageFormat:
                    "Storage: image store (format 2)" + (has("legacy") ? ", format 1 copy kept until a clean stop" : "")
                default: "Storage: format \(format), newer than this build"
                }
            storage.append(kind)
            let progress = try? String(
                contentsOf: directory.appendingPathComponent("work/migration-progress"),
                encoding: .utf8
            )
            if let done = progress.flatMap(Double.init) {
                storage.append("Storage migration: in progress (\(Int(done * 100))%)")
            } else if has("work/migration.json") {
                storage.append("Storage migration: cut short, the next start finishes or undoes it")
            }
            let failure = DiagnosticsExport.tail(of: firmwareLog, limit: 262_144).text.split(separator: "\n").last {
                $0.hasPrefix("NAND image migration: ") && $0.hasSuffix("; the device stays in format 1")
            }
            if format == 1, let failure {
                let reason = failure.dropFirst("NAND image migration: ".count)
                    .dropLast("; the device stays in format 1".count)
                storage.append("Storage migration failed: " + reason)
            }
            if fm.fileExists(atPath: overlay.appendingPathComponent("kboot.bin").path) {
                storage.append("Audio clock: repaired kboot.bin in the overlay")
            }
        }
    }

    /// The block: `system` (DiagnosticsExport.systemSummary), the free space on the library's volume, the app-wide
    /// settings that aren't the default, the steps skipped since a run quit in them (CrashGuard), each device (the
    /// selected one first, as the caller orders them) and the recent errors, scrubbed with `secrets` besides the Mac's
    /// own identity.
    public static func text(
        system: String,
        freeSpace: Int64? = nil,
        bezel: String? = nil,
        refresh120: Bool = false,
        angle: Bool = false,
        shareClipboard: Bool = true,
        skippedAfterCrash: [String] = [],
        devices: [Device],
        recentErrors: [String],
        secrets: [String] = [],
        identity: DiagnosticsExport.HostIdentity = .current
    ) -> String {
        var lines = system.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let freeSpace {
            lines.append("Free space: \(freeSpace.formatted(.byteCount(style: .file))) on the library's volume")
        }
        if let bezel { lines.append("Device bezels: \(bezel)") }
        if refresh120 { lines.append("120 Hz refresh: on") }
        if angle { lines.append("ANGLE renderer: on") }
        if !shareClipboard { lines.append("Clipboard sharing: off") }
        if !skippedAfterCrash.isEmpty {
            lines.append("Skipped after a crash: " + skippedAfterCrash.joined(separator: ", "))
        }
        if devices.isEmpty { lines += ["", "No device"] }
        for d in devices {
            lines += ["", "\(d.marketingName) (\(d.board)), iOS \(d.iosVersion) (\(d.iosBuild)), catalog \(d.entryID)"]
            var facts = ["State: \(d.state)"]
            if let zoom = d.zoom { facts.append("Zoom: \(zoom)") }
            if let panel = d.panel { facts.append("Free-form screen: \(panel)") }
            facts.append(
                (d.internet.map { "Internet: \($0 ? "on" : "off"); " } ?? "")
                    + "Local Network: \(d.localNetwork ? "on" : "off")"
            )
            if let tools = d.guestTools { facts.append("Guest tools: \(tools)") }
            if let build = d.emulatorBuild { facts.append("Emulator build: \(build)") }
            if let recipe = d.recipeVersion {
                let jailbreak = d.jailbreak.map { $0 ? ", Jailbreak" : ", stock" } ?? ""
                facts.append(
                    "Prepared base: recipe \(recipe)"
                        + (d.prepared.map { ", \($0.formatted(.iso8601.year().month().day()))" } ?? "")
                        + (d.withoutMounting ? ", without mounting" : "")
                        + (d.skipSetup == true ? ", Skip Setup" : "") + jailbreak
                        + (d.sandboxPatch.map { " (sandbox patch \($0))" } ?? "")
                )
            }
            facts += d.storage + d.notices.map { "Notice: " + $0 }
            if let proxy = d.webProxy { facts.append("Web proxy: \(proxy)") }
            if !d.tweaks.isEmpty { facts.append("Tweaks: " + d.tweaks.joined(separator: ", ")) }
            if !d.accessibility.isEmpty { facts.append("Accessibility: " + d.accessibility.joined(separator: ", ")) }
            if let c = d.carrier {
                facts.append(
                    "Carrier: \(c.carrier) (\(c.mccMNC)), \(c.registered ? "registered" : "not registered"), "
                        + "SIM \(c.simPresent ? "in" : "out"), \(c.bars) bars"
                )
            }
            if let apps = d.apps {
                facts.append("Apps (\(apps.count)):")
                facts += apps.map { "  \($0.id) — \($0.name) \($0.version)" }
            }
            lines += facts.map { "  " + $0 }
        }
        if !recentErrors.isEmpty {
            lines += ["", "Recent errors:"] + recentErrors.map { "  " + $0 }
        }
        let body = DiagnosticsExport.scrub(lines.joined(separator: "\n"), secrets: secrets, identity: identity)
        return "```text\n" + body + "\n```\n"
    }

    /// The last `limit` lines of the app's event log that report a failure, each cut to `width` characters.
    public static func recentErrors(log: URL, limit: Int = 5, width: Int = 200) -> [String] {
        // ponytail: reads the log's last 256 KB; the rotated app.log.1 is left out.
        let text = DiagnosticsExport.tail(of: log, limit: 262_144).text
        let failure = /(?i)error|fail|couldn[’']t|can[’']t|crash|refused|didn[’']t|unexpected/
        return text.split(separator: "\n").filter { $0.contains(failure) }.suffix(limit).map {
            $0.count > width ? String($0.prefix(width - 1)) + "…" : String($0)
        }
    }
}
