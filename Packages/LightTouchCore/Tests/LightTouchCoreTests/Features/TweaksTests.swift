import Foundation
import Testing

@testable import LightTouchCore

/// Tweaks: which firmware each switch works on (and why not elsewhere), the keys it means there, what turning one off
/// removes, the status bar override's per-version layout, the settings' persistence, and the apply against a fake
/// guest: the plist written as mobile's, SpringBoard restarted only for its domains, the agent's live ops.
@Suite(.serialized) struct TweaksTests {
    init() { TweakApplier.respringPause = .milliseconds(1) }

    @Test func eachTweakWorksOnItsVersionsOnly() {
        func ok(_ t: Tweak, _ v: String, tools: Bool = true, pinned: Bool = false) -> Bool {
            t.isAvailable(version: v, guestTools: tools, clockPinned: pinned)
        }
        #expect(ok(.keynoteClock, "3.1.3") && ok(.keynoteClock, "4.0") && !ok(.keynoteClock, "4.2.1"))
        #expect(ok(.emojiEverywhere, "4.2.1") && !ok(.emojiEverywhere, "5.1.1") && !ok(.emojiEverywhere, "2.1"))
        #expect(ok(.slowAnimations, "3.0") && !ok(.slowAnimations, "2.2.1") && ok(.slowAnimations, "7.1.2"))
        #expect(ok(.developerSettings, "6.1.6") && ok(.developerSettings, "4.2.1") && !ok(.developerSettings, "4.0"))
        #expect(ok(.cleanStatusBar, "4.2.1") && ok(.cleanStatusBar, "7.1.2"))
        #expect(ok(.cleanStatusBar, "2.2.1") && ok(.cleanStatusBar, "4.1"), "SpringBoard's demo keys")
        #expect(ok(.cleanStatusBar, "5.0.1") && ok(.cleanStatusBar, "6.0") && ok(.cleanStatusBar, "7.0.4"))
        // 1.x: no guest tools, the keys its SpringBoard and MobileSafari read written while it is stopped
        for v in ["1.0", "1.1.4"] {
            #expect(ok(.signalNumbers, v, tools: false) && ok(.keynoteClock, v, tools: false), "\(v)")
            #expect(ok(.cleanStatusBar, v, tools: false) && ok(.timeMachine, v, tools: false), "\(v)")
            for t in [Tweak.slowAnimations, .coreAnimationColors, .emojiEverywhere, .developerSettings] {
                #expect(!ok(t, v, tools: false), "\(t) has no 1.x reader")
            }
        }
        #expect(!ok(.safariDebug, "1.0", tools: false) && ok(.safariDebug, "1.1.4", tools: false), "1.1's console")
        #expect(!ok(.signalNumbers, "3.1.3", tools: false), "past 1.x the agent writes them")
        #expect(!ok(.timeMachine, "6.0", pinned: true), "a beta's own pinned clock wins")
    }

    /// Each row's note: a disabled one says why in a line, a 1.x one that works when it takes effect.
    @Test func notesSayWhyAndWhen() {
        func note(_ t: Tweak, _ v: String, tools: Bool = true, pinned: Bool = false) -> String? {
            t.note(version: v, guestTools: tools, clockPinned: pinned)
        }
        let next = "Takes effect at the next start."
        for v in ["1.0", "1.1.4"] {
            for t in [Tweak.signalNumbers, .keynoteClock, .cleanStatusBar] { #expect(note(t, v, tools: false) == next) }
            #expect(note(.slowAnimations, v, tools: false) == "Needs iPhone OS 3.0 or later.")
            #expect(note(.coreAnimationColors, v, tools: false) == "Needs iPhone OS 3.1 or later.")
            #expect(note(.emojiEverywhere, v, tools: false) == "Needs iPhone OS 2.2 or later.")
            #expect(note(.developerSettings, v, tools: false) == "Needs iOS 4.2 or later.")
            #expect(note(.timeMachine, v, tools: false) == nil, "a machine option of every start")
        }
        #expect(note(.safariDebug, "1.0", tools: false) == "Needs iPhone OS 1.1 or later.")
        #expect(note(.safariDebug, "1.1.4", tools: false) == next)
        #expect(note(.signalNumbers, "3.1.3") == nil, "applied right away by the agent")
        #expect(note(.keynoteClock, "4.2.1") == "Only up to iOS 4.0.2.")
        #expect(note(.emojiEverywhere, "5.1.1") == "Only up to iOS 4.3.5.")
        #expect(note(.signalNumbers, "3.1.3", tools: false) == "Needs the guest tools.")
        #expect(note(.timeMachine, "6.0", pinned: true) == "This beta keeps its own clock.")
        #expect(Tweak.cleanStatusBar.caption(version: "1.0") == "SBFakeTime, SBFakeTimeString, SBFakeBars")
        #expect(
            Tweak.cleanStatusBar.caption(version: "1.1.4") == "SBFakeTime, SBFakeTimeString, SBFakeCarrier, SBFakeBars"
        )
    }

    /// 1.x: the same keys as 2.x, but for 1.0's SpringBoard, which has no SBFakeCarrier.
    @Test func iPhoneOS1TakesTheSameKeys() {
        var s = TweakSettings()
        s.on = [.signalNumbers, .keynoteClock, .cleanStatusBar, .safariDebug, .slowAnimations]
        s.statusBar.time = "9:41 AM"
        s.statusBar.carrier = "Light Touch"
        #expect(
            s.defaults(version: "1.1.4").map(\.id) == [
                "com.apple.springboard SBShowRSSI", "com.apple.springboard SBShowGSMRSSI",
                "com.apple.springboard SBFakeBars", "com.apple.springboard SBFakeTime",
                "com.apple.springboard SBFakeTimeString", "com.apple.springboard SBFakeCarrier",
                "com.apple.mobilesafari ConsoleEnabled"
            ]
        )
        #expect(
            s.defaults(version: "1.0").map(\.id) == [
                "com.apple.springboard SBShowRSSI", "com.apple.springboard SBShowGSMRSSI",
                "com.apple.springboard SBFakeBars", "com.apple.springboard SBFakeTime",
                "com.apple.springboard SBFakeTimeString"
            ]
        )
        #expect(s.live(version: "1.0") == (nil, nil) as (Data?, UInt32?), "no live ops: there is no agent")
    }

    /// A 1.x device's keys go into it while stopped, before its start: once each start, the removal of what it wrote
    /// and no longer wants with them, nothing when none is on or was written, and a failure kept for the panel while
    /// the device starts as it is.
    @Test func iPhoneOS1WritesTheKeysWhileStopped() async throws {
        try await withTemporaryDirectoryAsync { dir in
            let tweaks = DeviceTweaks(
                settings: DeviceSettingsFile(directory: dir),
                version: "1.0",
                guestTools: false,
                clockPinned: false
            )
            var sent: [[GuestDefault]] = []
            let write: ([GuestDefault]) async throws -> Bool = {
                sent.append($0)
                return true
            }
            await tweaks.writeStopped(write)
            #expect(sent.isEmpty, "nothing on, nothing written")
            let model = TweaksPanelModel(tweaks: tweaks, guest: nil)
            model.set(.keynoteClock, on: true)
            model.set(.signalNumbers, on: true)
            #expect(tweaks.settings.on == [.keynoteClock, .signalNumbers], "1.x takes them")
            await tweaks.writeStopped(write)
            #expect(
                sent.last?.map(\.id).sorted() == [
                    "com.apple.springboard SBFakeTime", "com.apple.springboard SBShowGSMRSSI",
                    "com.apple.springboard SBShowRSSI"
                ]
            )
            #expect(tweaks.settings.written.count == 3)
            model.set(.signalNumbers, on: false)
            await tweaks.writeStopped(write)
            #expect(sent.last?.filter { $0.value == nil }.map(\.key).sorted() == ["SBShowGSMRSSI", "SBShowRSSI"])
            #expect(tweaks.settings.written == ["com.apple.springboard SBFakeTime"])
            struct Refused: Error {}
            await tweaks.writeStopped { _ in throw Refused() }
            #expect(model.status?.hasPrefix("The tweaks weren’t written") == true)
            #expect(tweaks.settings.written == ["com.apple.springboard SBFakeTime"], "kept for the next start")
            await tweaks.writeStopped(write)
            #expect(model.status == nil)

            let agent = DeviceTweaks(
                settings: DeviceSettingsFile(directory: dir),
                version: "3.1.3",
                guestTools: true,
                clockPinned: false
            )
            let count = sent.count
            await agent.writeStopped(write)
            #expect(sent.count == count, "with guest tools the agent writes them while it runs")
        }
    }

    /// 1.x runs no agent: the panel never asks it for the hidden apps (no spinner, no error), and says why.
    @Test func iPhoneOS1PanelNeverWaitsOnAnAgent() async throws {
        try await withTemporaryDirectoryAsync { dir in
            let link = FakeGuestLink()
            link.files["/Applications/DemoApp.app/Info.plist"] = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": "com.apple.DemoApp"],
                format: .xml,
                options: 0
            )
            let guest = GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
            let tweaks = DeviceTweaks(
                settings: DeviceSettingsFile(directory: dir),
                version: "1.1.4",
                guestTools: false,
                clockPinned: false
            )
            let model = TweaksPanelModel(tweaks: tweaks, guest: guest)
            #expect(model.isRunning && !model.opensHiddenApps)
            await model.listHiddenApps()
            #expect(model.hiddenApps == nil && model.status == nil && link.ops.isEmpty)
            #expect(model.statusBarSetsCarrier && model.note(.cleanStatusBar) == "Takes effect at the next start.")
            let one = TweaksPanelModel(
                tweaks: DeviceTweaks(
                    settings: DeviceSettingsFile(directory: dir),
                    version: "1.0",
                    guestTools: false,
                    clockPinned: false
                ),
                guest: nil
            )
            #expect(!one.statusBarSetsCarrier, "1.0's SpringBoard has no SBFakeCarrier")
        }
    }

    /// A guest root holding a developer-disk-images/<minor>/ pair for each of `minors`.
    func developerImages(in dir: URL, _ minors: [String]) throws -> URL {
        let guest = dir.appendingPathComponent("guest")
        for minor in minors {
            let folder = guest.appendingPathComponent("developer-disk-images/\(minor)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["DeveloperDiskImage.dmg", "DeveloperDiskImage.dmg.signature"] {
                try Data().write(to: folder.appendingPathComponent(name))
            }
        }
        return guest
    }

    @Test func developerImagePicksTheVersionsMinor() throws {
        try withTemporaryDirectory { dir in
            let guest = try developerImages(in: dir, ["4.2", "5.1", "7.0", "7.1"])
            func pick(_ version: String) -> String? {
                DeveloperDiskImage.image(version: version, in: guest)?.deletingLastPathComponent().lastPathComponent
            }
            #expect(pick("4.2.1") == "4.2" && pick("4.2") == "4.2", "4.2.1 and the 4.2 betas")
            #expect(pick("5.1.1") == "5.1" && pick("7.0") == "7.0" && pick("7.1.2") == "7.1")
            #expect(pick("4.1") == nil && pick("6.1.6") == nil, "no image for the minor")
            #expect(DeveloperDiskImage.image(version: "7.1.2", in: nil) == nil, "a build without the guest archive")
            try FileManager.default.removeItem(
                at: guest.appendingPathComponent("developer-disk-images/5.1/DeveloperDiskImage.dmg.signature")
            )
            #expect(pick("5.1.1") == nil, "no signature beside it")
        }
    }

    @Test func captionsAreTheKeys() {
        #expect(Tweak.signalNumbers.caption(version: "3.1.3") == "SBShowRSSI, SBShowGSMRSSI")
        #expect(Tweak.emojiEverywhere.caption(version: "6.1.6") == "KeyboardEmojiEverywhere", "the same when disabled")
        #expect(Tweak.safariDebug.caption(version: "5.1.1") == "com.apple.mobilesafari ConsoleEnabled")
        #expect(Tweak.safariDebug.caption(version: "6.1.6") == "com.apple.webinspectord RemoteInspectorEnabled")
        #expect(Tweak.timeMachine.caption(version: "4.2.1") == "rtc-epoch")
        #expect(Tweak.timeMachine.caption(version: "7.1.2") == "rtc-epoch")
        #expect(
            Tweak.cleanStatusBar.caption(version: "3.1.3") == "SBFakeTime, SBFakeTimeString, SBFakeCarrier, SBFakeBars"
        )
        #expect(Tweak.cleanStatusBar.caption(version: "5.1.1") == "+[UIStatusBarServer postStatusBarOverrideData:]")
        #expect(
            Tweak.cleanStatusBar.caption(version: "4.1") == "SBFakeTime, SBFakeTimeString, SBFakeCarrier, SBFakeBars"
        )
    }

    @Test func theKeysFollowTheFirmware() {
        var s = TweakSettings()
        s.on = [.signalNumbers, .keynoteClock, .slowAnimations, .emojiEverywhere, .safariDebug]
        let ids = { (v: String) in s.defaults(version: v).map(\.id) }
        #expect(
            ids("4.0") == [
                "com.apple.springboard SBShowRSSI", "com.apple.springboard SBShowGSMRSSI",
                "com.apple.springboard SBFakeTime", "com.apple.UIKit UIAnimationDragCoefficient",
                "com.apple.Preferences KeyboardEmojiEverywhere", "com.apple.mobilesafari ConsoleEnabled"
            ]
        )
        #expect(
            ids("6.1.6") == [
                "com.apple.springboard SBShowRSSI", "com.apple.springboard SBShowGSMRSSI",
                "com.apple.UIKit UIAnimationDragCoefficient", "com.apple.webinspectord RemoteInspectorEnabled"
            ],
            "no keynote clock or emoji switch there; Safari's switch is the Web Inspector"
        )
        #expect(
            s.defaults(version: "6.1.6").first { $0.key == "UIAnimationDragCoefficient" }?.value == .int(10),
            "an integer: CFPreferencesGetAppIntegerValue reads a real as 0"
        )
    }

    @Test func timeMachineLeavesNetworkTimeOn() async throws {
        // The machine's network answers NTP in its clock: timed keeps automatic time and zone, so the zone follows.
        var s = TweakSettings()
        s.on = [.timeMachine]
        for version in ["4.3.3", "5.1.1", "6.1.6", "7.1.2"] {
            #expect(s.defaults(version: version).isEmpty, "\(version)")
        }
        // What an earlier Time Machine wrote goes, and timed restarts to read it.
        s.written = [
            "com.apple.timed TMAutomaticTimeEnabled", "com.apple.timed TMAutomaticTimeOnlyEnabled",
            "com.apple.timed DisableAutomaticTime"
        ]
        let changes = s.changes(version: "7.1.2")
        #expect(changes.map(\.id) == s.written && changes.allSatisfy { $0.value == nil })
        let link = FakeGuestLink()
        let timed = "/var/mobile/Library/Preferences/com.apple.timed.plist"
        link.files[timed] = try PropertyListSerialization.data(
            fromPropertyList: [
                "TMAutomaticTimeEnabled": false, "TMAutomaticTimeOnlyEnabled": false, "DisableAutomaticTime": true,
                "TMAutomaticTimeZoneEnabled": true
            ],
            format: .binary,
            options: 0
        )
        let guest = GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
        let applied = try await TweakApplier.apply(s, version: "7.1.2", guest: guest, again: false)
        #expect(applied.written.isEmpty && !applied.resprung)
        let left = try PropertyListSerialization.propertyList(from: link.files[timed]!, format: nil) as? [String: Bool]
        #expect(left == ["TMAutomaticTimeZoneEnabled": true], "only Time Machine's keys go")
        #expect(link.spawns == [["/bin/launchctl", "stop", "com.apple.timed"]], "timed rereads")
    }

    @Test func turningOffRemovesOnlyWhatItWrote() {
        var s = TweakSettings()
        s.on = [.signalNumbers]
        s.written = [
            "com.apple.springboard SBShowRSSI", "com.apple.springboard SBShowGSMRSSI",
            "com.apple.springboard SBFakeTime"
        ]
        let changes = s.changes(version: "3.1.3")
        #expect(changes.filter { $0.value == nil }.map(\.key) == ["SBFakeTime"])
        #expect(changes.filter { $0.value != nil }.map(\.key) == ["SBShowRSSI", "SBShowGSMRSSI"])
        s.on = []
        s.written = []
        #expect(s.changes(version: "3.1.3").isEmpty, "a key the user set some other way is left alone")
    }

    @Test func statusBarOverridesFollowEachUIKit() throws {
        // 7.1.2: 25 item switches, the bits at 25-26, values at 28 (UIKit's merge routine, 0x2fc7abd0).
        let d = try #require(StatusBarOverride.layout(version: "7.1.2")).data(StatusBarStyle())
        #expect(d.count == 2000)
        #expect(d[25] == 0b101 && d[26] == 0b0011_0110, "time and GSM bars; Wi-Fi bars, data network, battery")
        #expect(String(decoding: d[53..<60], as: UTF8.self) == "9:41 AM")
        func int(_ at: Int) -> Int32 { d[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) } }
        #expect(int(124) == 5 && int(1560) == 3 && int(1564) == 5 && int(1568) == 100 && int(1572) == 0)
        let five = try #require(StatusBarOverride.layout(version: "5.1.1")).data(StatusBarStyle())
        #expect(five.count == 2092 && five[23] == 0b101 && five[24] == 0b0110_1100)
        #expect(String(decoding: five[51..<58], as: UTF8.self) == "9:41 AM")
        #expect(StatusBarOverride.layout(version: "4.3.3")?.cleared == Data(count: 1892))
        #expect(StatusBarOverride.layout(version: "4.1") == nil, "4.1's UIKit has no postStatusBarOverrideData")
        // 5.0, 6.0 and 7.0 encode the struct as 5.1, 6.1 and 7.1 do, up to the bitfields at its end
        for (minor, next) in [("5.0.1", "5.1.1"), ("6.0", "6.1.6"), ("7.0.4", "7.1.2")] {
            let style = StatusBarStyle()
            #expect(
                StatusBarOverride.layout(version: minor)?.data(style)
                    == StatusBarOverride.layout(version: next)?.data(style)
            )
        }
    }

    @Test func theMarketingStatusBarSetsEachField() throws {
        var style = StatusBarStyle()
        style.time = "Tue 9:41 AM"
        style.carrier = "Light Touch"
        style.cellBars = 2
        style.wifiBars = 1
        style.battery = 42
        style.charging = true
        func int(_ d: Data, _ at: Int) -> Int32 { d[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) } }
        func text(_ d: Data, _ at: Int) -> String { String(decoding: d[at...].prefix { $0 != 0 }, as: UTF8.self) }
        // 7.1.2: the service string at 128 after the GSM bars at 124 (bit 3 beside time's 0 and the bars' 2); the
        // item table's Bluetooth 11, Alarm 13, Location 16, RotationLock 17, Activity 23.
        let seven = try #require(StatusBarOverride.layout(version: "7.1.2")).data(style)
        #expect(seven[25] == 0b1101 && text(seven, 53) == "Tue 9:41 AM" && text(seven, 128) == "Light Touch")
        #expect(int(seven, 124) == 2 && int(seven, 1560) == 1 && int(seven, 1568) == 42 && int(seven, 1572) == 1)
        #expect(seven.indices.prefix(25).filter { seven[$0] == 1 } == [11, 13, 16, 17, 23])
        #expect(seven[28..<53].allSatisfy { $0 == 0 }, "hidden: overridden, and not enabled")
        let shown = try #require(StatusBarOverride.layout(version: "7.1.2")).shown(seven.dropFirst(28))
        #expect(shown == ("Tue 9:41 AM", "Light Touch", 42), "the values read back as getStatusBarData's raw data")
        // 4.2.1: Bluetooth 10, Alarm 12, Location 15, RotationLock 16, Activity 20; the service string at 124.
        let four = try #require(StatusBarOverride.layout(version: "4.2.1")).data(style)
        #expect(four.indices.prefix(22).filter { four[$0] == 1 } == [10, 12, 15, 16, 20])
        #expect(text(four, 124) == "Light Touch" && four[22] == 0b1101 && four[23] == 0b11110)
        // the clamps, the C strings' capacity, and what isn't set
        style.time = ""
        style.carrier = String(repeating: "é", count: 60)
        style.cellBars = 9
        style.hidesIndicators = false
        let six = try #require(StatusBarOverride.layout(version: "6.1.6")).data(style)
        #expect(six[24] & 1 == 0 && six[52] == 0, "no time: the real one")
        #expect(text(six, 124).count == 49 && six[124 + 98] == 0, "99 bytes at most, whole characters")
        #expect(int(six, 120) == 5 && six.prefix(24).allSatisfy { $0 == 0 })
    }

    /// getStatusBarData's raw data comes from the guest: each C string is read within its field (timeString's 64
    /// bytes, serviceString's 100) though the guest leaves it unterminated, and a short buffer reads as what it holds,
    /// the battery as -1.
    @Test func statusBarRawDataIsReadWithinItsFields() throws {
        let layout = try #require(StatusBarOverride.layout(version: "7.1.2"))
        var raw = Data(repeating: 0x42, count: layout.rawSize)  // no NUL anywhere
        raw.replaceSubrange(25..<89, with: Data(repeating: 0x41, count: 64))  // timeString, at 53 - 28
        let shown = layout.shown(raw)
        #expect(shown.time == String(repeating: "A", count: 64))
        #expect(shown.carrier == String(repeating: "B", count: 100))
        #expect(shown.battery == 0x4242_4242)
        let short = layout.shown(raw.prefix(60))
        #expect(short == (String(repeating: "A", count: 35), "", -1))
        #expect(layout.shown(Data()) == ("", "", -1))
    }

    @Test func iOS2To4TakeSpringBoardsDemoKeys() {
        var s = TweakSettings()
        s.on = [.cleanStatusBar, .keynoteClock]
        s.statusBar.carrier = "Light Touch"
        let keys = s.defaults(version: "3.1.3")
        #expect(
            keys == [
                GuestDefault("com.apple.springboard", "SBFakeBars", .int(1)),
                GuestDefault("com.apple.springboard", "SBFakeTime", .bool(true)),
                GuestDefault("com.apple.springboard", "SBFakeTimeString", .string("9:41 AM")),
                GuestDefault("com.apple.springboard", "SBFakeCarrier", .string("Light Touch"))
            ],
            "the keynote clock's SBFakeTime once, under the string"
        )
        #expect(s.live(version: "3.1.3").statusBar == nil, "no overrides there")
        s.statusBar.carrier = ""
        s.statusBar.time = ""
        #expect(s.defaults(version: "4.0.2").map(\.key) == ["SBFakeBars", "SBFakeTime"], "the keynote clock's 9:42")
        #expect(!s.defaults(version: "4.2.1").contains { $0.key.hasPrefix("SBFake") }, "overrides from 4.2")
        #expect(s.defaults(version: "4.1").map(\.key) == ["SBFakeBars"], "4.1's SpringBoard reads them too")
        s.written = ["com.apple.springboard SBFakeCarrier", "com.apple.springboard SBFakeTimeString"]
        #expect(
            s.changes(version: "3.1.3").filter { $0.value == nil }.map(\.key) == ["SBFakeCarrier", "SBFakeTimeString"]
        )
    }

    @Test func aRestartedSpringBoardGetsTheOverridesAgain() async throws {
        let link = FakeGuestLink()
        link.v4 = true
        link.v5 = true
        let guest = GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
        var s = TweakSettings()
        s.on = [.cleanStatusBar]
        _ = try await TweakApplier.apply(s, version: "7.1.2", guest: guest, again: false)
        #expect(link.statusBars.count == 1)
        #expect(try await !TweakApplier.restoreStatusBar(s, version: "7.1.2", guest: guest), "still held")
        link.held = nil  // a respring
        #expect(try await TweakApplier.restoreStatusBar(s, version: "7.1.2", guest: guest))
        #expect(link.statusBars.count == 2 && link.held == link.statusBars[0])
        let old = FakeGuestLink()
        old.v4 = true
        #expect(
            try await !TweakApplier.restoreStatusBar(
                s,
                version: "7.1.2",
                guest: GuestServices(agent: GuestAgent(link: old, cache: GuestAgentCache()))
            ),
            "a v4 agent can't read it back"
        )
        s.on = []
        #expect(try await !TweakApplier.restoreStatusBar(s, version: "7.1.2", guest: guest), "off: nothing to keep")
    }

    @Test func settingsPersistAndOlderOnesDecode() throws {
        var s = DeviceSettings()
        var t = TweakSettings()
        t.on = [.timeMachine, .coreAnimationColors]
        t.clock = Date(timeIntervalSince1970: 1_183_100_400)
        t.coreAnimationColor = .offscreenRendered
        t.written = ["com.apple.UIKit UIAnimationDragCoefficient"]
        t.statusBar.carrier = "Light Touch"
        t.statusBar.battery = 50
        s.tweaks = t
        try withTemporaryDirectory { dir in
            try s.save(dir)
            #expect(DeviceSettings.load(dir).tweaks == t)
        }
        let old = try PropertyListDecoder().decode(
            TweakSettings.self,
            from: PropertyListSerialization.data(
                fromPropertyList: ["on": ["signalNumbers", "gone"], "developerImage": "/x/DeveloperDiskImage.dmg"],
                format: .xml,
                options: 0
            )
        )
        #expect(old.on == [.signalNumbers] && old.clock == TweakSettings.macworld2007)
        #expect(old.statusBar == StatusBarStyle() && StatusBarStyle().time == "9:41 AM")
        #expect(t.clock(clockPinned: false) == t.clock && t.clock(clockPinned: true) == nil)
        #expect(TweakSettings().clock(clockPinned: false) == nil, "off: no clock")
    }

    @Test func applyWritesMobilesPlistAndRespringsOnlyForSpringBoard() async throws {
        let link = FakeGuestLink()
        let guest = GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
        let sb = "/var/mobile/Library/Preferences/com.apple.springboard.plist"
        link.files[sb] = try PropertyListSerialization.data(
            fromPropertyList: ["SBHideACPower": true],
            format: .binary,
            options: 0
        )
        var s = TweakSettings()
        s.on = [.signalNumbers, .emojiEverywhere]
        let first = try await TweakApplier.apply(s, version: "4.2.1", guest: guest, again: false)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: link.files[sb]!, format: nil) as? [String: Bool]
        )
        #expect(plist == ["SBHideACPower": true, "SBShowRSSI": true, "SBShowGSMRSSI": true], "merged, not replaced")
        #expect(link.owners[sb] == "501:501" && link.modes[sb] == "600")
        #expect(first.resprung && link.spawns.contains(["/bin/launchctl", "stop", "com.apple.SpringBoard"]))
        #expect(first.written.count == 3)
        s.written = first.written
        link.spawns = []
        let again = try await TweakApplier.apply(s, version: "4.2.1", guest: guest, again: true)
        #expect(!again.resprung && link.spawns.isEmpty, "nothing changed: no respring")
        s.on = [.signalNumbers]
        let off = try await TweakApplier.apply(s, version: "4.2.1", guest: guest, again: true)
        #expect(!off.resprung, "Settings' domain: no respring")
        let prefs = try #require(link.files["/var/mobile/Library/Preferences/com.apple.Preferences.plist"])
        #expect(
            (try PropertyListSerialization.propertyList(from: prefs, format: nil) as? [String: Any])?.isEmpty == true
        )
    }

    @Test func liveOpsGoThroughTheAgentAndAnOldOneIsNamed() async throws {
        let link = FakeGuestLink()
        link.v4 = true
        let guest = GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
        var s = TweakSettings()
        s.on = [.cleanStatusBar, .coreAnimationColors]
        _ = try await TweakApplier.apply(s, version: "6.1.6", guest: guest, again: false)
        #expect(link.statusBars == [StatusBarOverride.layout(version: "6.1.6")!.data(StatusBarStyle())])
        #expect(link.caDebug == ["\(0x4 | 0x2 | 0x4000 | 0x20000 | 0x1) 4"])
        s.on = []
        _ = try await TweakApplier.apply(s, version: "6.1.6", guest: guest, again: true)
        #expect(link.statusBars.last == Data(count: 1992) && link.caDebug.last?.hasSuffix(" 0") == true, "off again")
        let fresh = FakeGuestLink()
        fresh.v4 = true
        _ = try await TweakApplier.apply(
            s,
            version: "6.1.6",
            guest: GuestServices(agent: GuestAgent(link: fresh, cache: GuestAgentCache())),
            again: false
        )
        #expect(fresh.statusBars.isEmpty && fresh.caDebug.isEmpty, "a fresh boot with them off: nothing to clear")
        let old = FakeGuestLink()
        s.on = [.cleanStatusBar]
        let result = try await TweakApplier.apply(
            s,
            version: "6.1.6",
            guest: GuestServices(agent: GuestAgent(link: old, cache: GuestAgentCache())),
            again: false
        )
        #expect(result.missing == [.cleanStatusBar] && !old.ops.contains("statusbar"))
    }

    @Test func hiddenAppsAreTheOnesTheGuestHas() async throws {
        let link = FakeGuestLink()
        let guest = GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
        func info(_ id: String) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
        }
        link.files["/Applications/FieldTest.app/Info.plist"] = try info("com.apple.fieldtest")
        link.files["/Applications/iOS Diagnostics.app/Info.plist"] = try info("com.apple.iosdiagnostics")
        link.files["/Applications/DemoApp.app/Info.plist"] = try info("com.example.notdemo")
        #expect(try await HiddenApp.present(on: guest).map(\.name) == ["Field Test", "Diagnostics"])
    }

    @Test func thePanelSavesPerDeviceAndRefusesWhatCantWork() throws {
        try withTemporaryDirectory { dir in
            let file = DeviceSettingsFile(directory: dir)
            let guest = try developerImages(in: dir, ["6.1"])
            let tweaks = DeviceTweaks(
                settings: file,
                version: "6.1.6",
                guestTools: true,
                clockPinned: false,
                guestRoot: guest
            )
            let model = TweaksPanelModel(tweaks: tweaks, guest: nil)
            model.set(.signalNumbers, on: true)
            model.set(.emojiEverywhere, on: true)
            model.set(.developerSettings, on: true)
            #expect(DeviceSettings.load(dir).tweaks?.on == [.signalNumbers, .developerSettings], "no emoji on 6.1.6")
            #expect(tweaks.developerImage?.path == guest.path + "/developer-disk-images/6.1/DeveloperDiskImage.dmg")
            let none = DeviceTweaks(
                settings: file,
                version: "5.1.1",
                guestTools: true,
                clockPinned: false,
                guestRoot: guest
            )
            #expect(!none.isAvailable(.developerSettings), "no 5.1 image: the row is disabled")
            #expect(tweaks.bootClock == nil)
            model.set(.timeMachine, on: true)
            #expect(tweaks.bootClock == TweakSettings.macworld2007)
        }
    }
}
