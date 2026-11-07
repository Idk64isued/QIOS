// Device ▸ Tweaks…: Apple's own hidden switches, each applied the stock way and only on the firmware where it works
// (the research: device-expansion-handoff review/tweaks.md, issues 41 and 42).
//
// A switch is a preference key in the guest user's domain (GuestServices.writeDefaults, through the agent), a stock API
// the agent calls (Core Animation's debug colors, UIKit's status bar overrides), a Developer Disk Image mounted through
// lockdown, or a machine option of the next start (Time Machine). iPhone OS 1.x runs no agent: its keys are written
// into the stopped device before its next start (DeviceTweaks.writeStopped). What a device asks for is its TweakSettings
// (DeviceSettings.tweaks); TweakSettings.defaults says which keys that means on its firmware, and
// TweakSettings.written which keys it has put there, so turning a tweak off removes only what it wrote.

import Foundation
import HostServiceWire

public nonisolated enum Tweak: String, Codable, CaseIterable, Sendable {
    case signalNumbers, keynoteClock, cleanStatusBar
    case slowAnimations, coreAnimationColors, emojiEverywhere
    case safariDebug, developerSettings
    case timeMachine

    public enum Section: String, CaseIterable, Sendable {
        case statusBar = "Status Bar"
        case interface = "Interface"
        case developer = "Developer"
        case time = "Time"
    }

    public var title: String {
        switch self {
        case .signalNumbers: "Signal as Numbers"
        case .keynoteClock: "Keynote Clock"
        case .cleanStatusBar: "Marketing Status Bar"
        case .slowAnimations: "Slow Animations"
        case .coreAnimationColors: "Core Animation Colors"
        case .emojiEverywhere: "Emoji Keyboard Everywhere"
        case .safariDebug: "Safari Debugging"
        case .developerSettings: "Developer Settings"
        case .timeMachine: "Time Machine"
        }
    }

    public var section: Section {
        switch self {
        case .signalNumbers, .keynoteClock, .cleanStatusBar: .statusBar
        case .slowAnimations, .coreAnimationColors, .emojiEverywhere: .interface
        case .safariDebug, .developerSettings: .developer
        case .timeMachine: .time
        }
    }

    /// The firmware it works on, first and last version (nil: every version the emulator runs). Each range is where
    /// the decrypted root filesystems (1.0 to 7.1.2) carry the reader.
    public var versions: (first: String, last: String)? {
        switch self {
        // SpringBoard reads both on every build from 1.0 to 7.1.2.
        case .signalNumbers: ("1.0", "7.1.2")
        // SpringBoard's status bar draws "9:42 AM" for SBFakeTime with no SBFakeTimeString from 1.0 to 4.0; 4.2.1
        // has neither the string nor SBFakeTimeString.
        case .keynoteClock: ("1.0", "4.0.2")
        // SpringBoard's demo keys to 4.1 (1.0's has no SBFakeCarrier, 1.1.4's has), then UIKit's
        // +[UIStatusBarServer postStatusBarOverrideData:] from 4.2.1 (StatusBarOverride has both).
        case .cleanStatusBar: ("1.0", "7.1.2")
        // UIKit reads com.apple.UIKit UIAnimationDragCoefficient from 3.0; 1.x and 2.x have the function and no key.
        case .slowAnimations: ("3.0", "7.1.2")
        // QuartzCore's CARenderServerSetDebugFlags, with the same CA_COLOR_* bits from 3.1.3 to 7.1.2.
        case .coreAnimationColors: ("3.1", "7.1.2")
        // UIKit reads it from 2.2 (2.1.1 doesn't), beside SoftBank's carrier and the Emoji regions, and 4.x
        // KeyboardSettings too; from 5.0 it is only a name in UIKit's (7.x TextInput's) list of keyboard preferences.
        case .emojiEverywhere: ("2.2", "4.3.5")
        // MobileSafariSettings' Developer.plist: com.apple.mobilesafari ConsoleEnabled from 1.1 (1.0's MobileSafari
        // has no console) to 5.1.1, then com.apple.webinspectord RemoteInspectorEnabled (webinspectord, 6.1.6 and 7.x).
        case .safariDebug: ("1.1", "7.1.2")
        // Preferences shows Developer while /Developer/Library/PreferenceBundles/Developer Settings.bundle exists
        // (4.0 to 7.1.2); the Developer Disk Images carry that bundle from 4.2. DeviceTweaks also needs the app's
        // image for the version (DeveloperDiskImage).
        case .developerSettings: ("4.2", "7.1.2")
        case .timeMachine: nil
        }
    }

    /// Whether a device with `version` can have it.
    public func isAvailable(version: String, guestTools: Bool, clockPinned: Bool) -> Bool {
        unavailable(version: version, guestTools: guestTools, clockPinned: clockPinned) == nil
    }

    /// Why a device with `version` can't have it, in a line; nil where it can.
    public func unavailable(version: String, guestTools: Bool, clockPinned: Bool) -> String? {
        if self == .timeMachine { return clockPinned ? "This beta keeps its own clock." : nil }
        if let (first, last) = versions {
            if TweakSettings.before(version, first) { return "Needs \(Self.system(first)) \(first) or later." }
            if version.compare(last, options: .numeric) == .orderedDescending {
                return "Only up to \(Self.system(last)) \(last)."
            }
        }
        if self == .cleanStatusBar, !StatusBarStyle.takesKeys(version: version),
            StatusBarOverride.layout(version: version) == nil
        {
            return "Not mapped for this version’s status bar."
        }
        // 1.x runs no guest tools: every switch it has is a preference key, written into the stopped device
        // (DeviceTweaks.writeStopped).
        return guestTools || Self.writtenWhileStopped(version: version) ? nil : "Needs the guest tools."
    }

    /// What the row says under its caption on `version`: why it's off, or when a change takes effect where that
    /// isn't right away.
    public func note(version: String, guestTools: Bool, clockPinned: Bool) -> String? {
        if let why = unavailable(version: version, guestTools: guestTools, clockPinned: clockPinned) { return why }
        return self != .timeMachine && Self.writtenWhileStopped(version: version)
            ? "Takes effect at the next start." : nil
    }

    /// iPhone OS 1.x: no agent, so the keys go into the device while it is stopped.
    public static func writtenWhileStopped(version: String) -> Bool { TweakSettings.before(version, "2.0") }

    static func system(_ version: String) -> String { TweakSettings.before(version, "4.0") ? "iPhone OS" : "iOS" }

    /// The row's caption on `version`: exactly what it changes.
    public func caption(version: String) -> String {
        switch self {
        case .signalNumbers: "SBShowRSSI, SBShowGSMRSSI"
        case .keynoteClock: "SBFakeTime"
        case .cleanStatusBar:
            !TweakSettings.before(version, "4.2")
                ? "+[UIStatusBarServer postStatusBarOverrideData:]"
                : StatusBarStyle.takesCarrier(version: version)
                    ? "SBFakeTime, SBFakeTimeString, SBFakeCarrier, SBFakeBars"
                    : "SBFakeTime, SBFakeTimeString, SBFakeBars"
        case .slowAnimations: "UIAnimationDragCoefficient"
        case .coreAnimationColors: "CARenderServerSetDebugFlags"
        case .emojiEverywhere: "KeyboardEmojiEverywhere"
        case .safariDebug:
            TweakSettings.before(version, "6.0")
                ? "com.apple.mobilesafari ConsoleEnabled" : "com.apple.webinspectord RemoteInspectorEnabled"
        case .developerSettings: "DeveloperDiskImage.dmg on /Developer"
        // The machine's clock, and its network's: qemu-ios answers NTP in it, so timed keeps it with network time on.
        case .timeMachine: "rtc-epoch"
        }
    }

    /// Slow Animations' UIAnimationDragCoefficient: the Simulator's Slow Animations, 10 (UIKit's
    /// UIAnimationDragCoefficient() returns 10.0 while com.apple.UIKit.SimulatorSlowMotionAnimationState is set).
    public static let slowAnimationFactor = 10

    /// Domains whose reader is SpringBoard (or UIKit in it): a change there resprings (GuestServices.respring).
    static let respringDomains: Set = ["com.apple.springboard", "com.apple.UIKit"]
}

/// Core Animation's debug colors, the CA_COLOR_* bits (the agent's cadebug op).
public nonisolated enum CoreAnimationColor: UInt32, Codable, CaseIterable, Sendable {
    case blendedLayers = 0x4
    case copiedImages = 0x2
    case misalignedImages = 0x4000
    case offscreenRendered = 0x20000
    case flashUpdatedRegions = 0x1

    public var title: String {
        switch self {
        case .blendedLayers: "Blended Layers"
        case .copiedImages: "Copied Images"
        case .misalignedImages: "Misaligned Images"
        case .offscreenRendered: "Offscreen-Rendered"
        case .flashUpdatedRegions: "Flash Updated Regions"
        }
    }

    /// Every color bit the panel sets: what turning them off clears.
    static let mask = allCases.reduce(UInt32(0)) { $0 | $1.rawValue }
}

/// One device's tweaks: DeviceSettings.tweaks.
public nonisolated struct TweakSettings: Codable, Equatable, Sendable {
    public init() {}

    /// The switches that are on.
    public var on: Set<Tweak> = []
    /// Core Animation Colors' color.
    public var coreAnimationColor = CoreAnimationColor.blendedLayers
    /// Marketing Status Bar's status bar.
    public var statusBar = StatusBarStyle()
    /// Time Machine's moment: each start begins there and the clock runs on.
    public var clock: Date = TweakSettings.macworld2007
    /// The preference keys ("domain key") these settings have written into the device, so turning a tweak off removes
    /// only what it set.
    public var written: [String] = []

    /// January 9, 2007, 9:41 AM: the iPhone's introduction at Macworld, on the clock as the device shows it (its zone
    /// follows the Mac's).
    public static var macworld2007: Date {
        Calendar.current.date(from: DateComponents(year: 2007, month: 1, day: 9, hour: 9, minute: 41))
            ?? Date(timeIntervalSince1970: 1_168_364_460)
    }

    public func isOn(_ tweak: Tweak) -> Bool { on.contains(tweak) }

    /// Time Machine's moment when it's on and the device can take it.
    public func clock(clockPinned: Bool) -> Date? {
        isOn(.timeMachine) && !clockPinned ? clock : nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = Set((try c.decodeIfPresent([String].self, forKey: .on) ?? []).compactMap(Tweak.init(rawValue:)))
        coreAnimationColor =
            (try c.decodeIfPresent(UInt32.self, forKey: .coreAnimationColor)).flatMap(CoreAnimationColor.init)
            ?? .blendedLayers
        statusBar = try c.decodeIfPresent(StatusBarStyle.self, forKey: .statusBar) ?? StatusBarStyle()
        clock = try c.decodeIfPresent(Date.self, forKey: .clock) ?? Self.macworld2007
        written = try c.decodeIfPresent([String].self, forKey: .written) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(on.map(\.rawValue).sorted(), forKey: .on)
        try c.encode(coreAnimationColor.rawValue, forKey: .coreAnimationColor)
        try c.encode(statusBar, forKey: .statusBar)
        try c.encode(clock, forKey: .clock)
        try c.encode(written, forKey: .written)
    }

    enum CodingKeys: String, CodingKey {
        case on, coreAnimationColor, statusBar, clock, written
    }

    /// Whether `tweak` is on and works on `version` (with the guest tools: the device is running them).
    func applies(_ tweak: Tweak, version: String) -> Bool {
        isOn(tweak) && tweak.isAvailable(version: version, guestTools: true, clockPinned: false)
    }

    static func before(_ version: String, _ other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedAscending
    }

    /// The preference keys the switches that are on (and work on `version`) set.
    public func defaults(version: String) -> [GuestDefault] {
        var keys: [GuestDefault] = []
        if applies(.signalNumbers, version: version) {
            // SBShowRSSI: Wi-Fi's bars as dBm; SBShowGSMRSSI: the cellular bars as dBm (Field Test's numbers).
            keys += ["SBShowRSSI", "SBShowGSMRSSI"].map { GuestDefault("com.apple.springboard", $0, .bool(true)) }
        }
        let marketing = applies(.cleanStatusBar, version: version) && StatusBarStyle.takesKeys(version: version)
        if marketing { keys += statusBar.keys(version: version) }
        if applies(.keynoteClock, version: version), !keys.contains(where: { $0.key == "SBFakeTime" }) {
            keys.append(GuestDefault("com.apple.springboard", "SBFakeTime", .bool(true)))
        }
        if applies(.slowAnimations, version: version) {
            // UIAnimationDragCoefficient() reads it with CFPreferencesGetAppIntegerValue, which takes a real as 0
            // (no slow-down): an integer (5.1.1 to 7.1.2 UIKit, CoreFoundation's CFNumberIsFloatType check).
            keys.append(
                GuestDefault("com.apple.UIKit", "UIAnimationDragCoefficient", .int(Tweak.slowAnimationFactor))
            )
        }
        if applies(.emojiEverywhere, version: version) {
            keys.append(GuestDefault("com.apple.Preferences", "KeyboardEmojiEverywhere", .bool(true)))
        }
        if applies(.safariDebug, version: version) {
            // Settings' own switches (MobileSafariSettings' Developer.plist): 1.1 to 5.1.1, then 6.1.6 and 7.x.
            keys.append(
                Self.before(version, "6.0")
                    ? GuestDefault("com.apple.mobilesafari", "ConsoleEnabled", .bool(true))
                    : GuestDefault("com.apple.webinspectord", "RemoteInspectorEnabled", .bool(true))
            )
        }
        return keys
    }

    /// What to write so the device has `defaults(version:)`: those keys, and the removal of every key it wrote before
    /// that is no longer asked for.
    public func changes(version: String) -> [GuestDefault] {
        let wanted = defaults(version: version)
        let kept = Set(wanted.map(\.id))
        let removed = written.filter { !kept.contains($0) }.compactMap { id -> GuestDefault? in
            let parts = id.split(separator: " ", maxSplits: 1).map(String.init)
            return parts.count == 2 ? GuestDefault(parts[0], parts[1], nil) : nil
        }
        return wanted + removed
    }

    /// What the agent's live ops are told: the status bar's override data (cleared when off) and the debug color bits.
    public func live(version: String) -> (statusBar: Data?, colors: UInt32?) {
        let layout = StatusBarOverride.layout(version: version)
        let bar = layout.map { applies(.cleanStatusBar, version: version) ? $0.data(statusBar) : $0.cleared }
        let colorsWork = Tweak.coreAnimationColors.isAvailable(version: version, guestTools: true, clockPinned: false)
        return (bar, colorsWork ? (isOn(.coreAnimationColors) ? coreAnimationColor.rawValue : 0) : nil)
    }

    /// What one apply sends: the keys and the live state, so a change made since is told apart.
    public func applied(version: String) -> Applied {
        let live = live(version: version)
        return Applied(changes: changes(version: version), statusBar: live.statusBar, colors: live.colors)
    }

    public struct Applied: Equatable, Sendable {
        var changes: [GuestDefault]
        var statusBar: Data?
        var colors: UInt32?
    }
}

/// The Developer Disk Images the app ships (scripts/vendor, from build-support/developer-disk-images.json): one per
/// iOS minor version, as Xcode's DeviceSupport folders had them, in the guest archive's
/// developer-disk-images/<major.minor>/.
public nonisolated enum DeveloperDiskImage {
    /// The DeveloperDiskImage.dmg (its .signature beside it) for `version` under `guestRoot` (Bundled.guestRoot);
    /// nil where none fits.
    public static func image(version: String, in guestRoot: URL?) -> URL? {
        guard let guestRoot else { return nil }
        let minor = version.split(separator: ".").prefix(2).joined(separator: ".")
        let dmg = guestRoot.appendingPathComponent("developer-disk-images/\(minor)/DeveloperDiskImage.dmg")
        let fm = FileManager.default
        return fm.fileExists(atPath: dmg.path) && fm.fileExists(atPath: dmg.path + ".signature") ? dmg : nil
    }
}

nonisolated extension GuestDefault {
    /// "domain key": how TweakSettings.written names it.
    var id: String { "\(domain) \(key)" }
}

/// Writes a device's tweaks into its running guest: the preference keys (restarting SpringBoard when one of its
/// domains changed), then the agent's live ops.
public nonisolated enum TweakApplier {
    /// Between asking a restarting SpringBoard whether it's back (tests shorten it).
    nonisolated(unsafe) static var respringPause: Duration = .seconds(2)

    /// The keys now written (TweakSettings.written), whether SpringBoard was restarted, and the live ops the agent
    /// lacks (an older guest package). `again`: an earlier apply of this boot may have left a live op on, so one
    /// that is off now is turned off (a fresh SpringBoard starts with neither).
    public static func apply(
        _ settings: TweakSettings,
        version: String,
        guest: GuestServices,
        again: Bool
    ) async throws -> (written: [String], resprung: Bool, missing: [Tweak]) {
        let changed = try await guest.writeDefaults(settings.changes(version: version))
        let respring = changed.contains { Tweak.respringDomains.contains($0) }
        if respring {
            try await guest.respring()
            try await springBoardBack(guest)
        }
        // timed reads its switches when it starts: removing those an earlier Time Machine wrote (network time off,
        // which also dropped every zone change) holds once launchd starts it again on demand.
        if changed.contains("com.apple.timed") {
            _ = try? await guest.agent.spawn([GuestServices.launchctl, "stop", "com.apple.timed"])
        }
        // SpringBoard (or backboardd) forgets both when it restarts: they go again after every respring and start.
        let live = settings.live(version: version)
        let ops = try await guest.agent.capabilities()
        var missing: [Tweak] = []
        if let bar = live.statusBar, again || settings.isOn(.cleanStatusBar) {
            if ops.has("statusbar") {
                try await guest.agent.perform("statusbar", body: bar)
            } else if settings.isOn(.cleanStatusBar) {
                missing.append(.cleanStatusBar)
            }
        }
        if let colors = live.colors, again || settings.isOn(.coreAnimationColors) {
            if ops.has("cadebug") {
                try await guest.agent.perform("cadebug", "\(CoreAnimationColor.mask) \(colors)")
            } else if settings.isOn(.coreAnimationColors) {
                missing.append(.coreAnimationColors)
            }
        }
        return (settings.defaults(version: version).map(\.id), respring, missing)
    }

    /// SpringBoard forgets posted overrides when it restarts (a respring from elsewhere, a crash): what its status bar
    /// server holds, read back (the agent's statusbarget), is posted again where it isn't what the apply sent.
    /// Whether it posted; never with an older agent, which can't read it back.
    public static func restoreStatusBar(
        _ settings: TweakSettings,
        version: String,
        guest: GuestServices
    ) async throws -> Bool {
        guard settings.applies(.cleanStatusBar, version: version), let bar = settings.live(version: version).statusBar,
            try await guest.agent.capabilities().has("statusbarget"),
            try await guest.agent.perform("statusbarget", "override \(bar.count)") != bar
        else { return false }
        try await guest.agent.perform("statusbar", body: bar)
        return true
    }
}

/// A restarted SpringBoard answers the agent's frontmost again (SpringBoardServices is its); a minute at most.
private nonisolated func springBoardBack(_ guest: GuestServices) async throws {
    try await Task.sleep(for: TweakApplier.respringPause)
    for _ in 0..<30 {
        if let front = try? await guest.agent.frontmost(), !front.bundleID.isEmpty { return }
        try await Task.sleep(for: TweakApplier.respringPause)
    }
}

/// Apple's apps every build carries but SpringBoard hides (SBAppTags hidden), which the agent's launch op opens: the
/// ones a curious user would want, by the bundle each build ships them in (decrypted root filesystems 1.0 to 7.1.2).
public nonisolated struct HiddenApp: Equatable, Sendable, Identifiable {
    public var id: String { bundleID }
    public let name: String
    public let bundleID: String
    /// Its bundle under /Applications.
    public let bundle: String

    public static let candidates: [HiddenApp] = [
        HiddenApp(name: "Field Test", bundleID: "com.apple.fieldtest", bundle: "FieldTest"),
        HiddenApp(name: "Diagnostics", bundleID: "com.apple.iosdiagnostics", bundle: "iOS Diagnostics"),
        HiddenApp(name: "Demo", bundleID: "com.apple.DemoApp", bundle: "DemoApp"),
        HiddenApp(name: "Setup Assistant", bundleID: "com.apple.purplebuddy", bundle: "Setup"),
        HiddenApp(name: "Data Activation", bundleID: "com.apple.DataActivation", bundle: "DataActivation"),
        HiddenApp(name: "iPod Out", bundleID: "com.apple.iphoneos.iPodOut", bundle: "iPodOut"),
        HiddenApp(name: "TrustMe", bundleID: "com.apple.TrustMe", bundle: "TrustMe"),
        HiddenApp(name: "WebSheet", bundleID: "com.apple.WebSheet", bundle: "WebSheet"),
        HiddenApp(name: "iAd Opt Out", bundleID: "com.apple.iad.iAdOptOut", bundle: "iAdOptOut"),
        HiddenApp(name: "Copilot", bundleID: "com.apple.Copilot", bundle: "Copilot")
    ]

    /// The candidates this guest has: its bundle there under the same identifier.
    public static func present(on guest: GuestServices) async throws -> [HiddenApp] {
        var found: [HiddenApp] = []
        for app in candidates {
            guard let data = try await guest.agent.get("/Applications/\(app.bundle).app/Info.plist", limit: 1 << 20),
                let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                info["CFBundleIdentifier"] as? String == app.bundleID
            else { continue }
            found.append(app)
        }
        return found
    }
}
