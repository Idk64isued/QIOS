import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// Copy Bug Report Info's facts of a device's storage, preparation and live settings, and the app-wide ones: each
/// present when it applies, absent when it's the default. The two samples are an iPhone 4 on 7.1.2, migrated and
/// jailbroken, and an original iPhone on 1.0 whose storage migration failed.
struct BugReportInfoDeviceFactsTests {
    let system = "Light Touch 1.2 (345)\nmacOS Version 27.0 (Build 27A100)\narm64 on Mac16,10, Apple M4"
    let identity = DiagnosticsExport.HostIdentity(home: "/Users/jappleseed", names: ["jappleseed", "Johnny Appleseed"])
    /// 2026-10-12 at noon UTC.
    let prepared = Date(timeIntervalSince1970: 1_791_806_400)
    let applied = (true, "sb_evaluate at 0x80312abc (2de90f4f)")

    func iPhone4(_ state: String = "Not running") -> BugReportInfo.Device {
        BugReportInfo.Device(
            marketingName: "iPhone 4",
            board: "n90ap",
            iosVersion: "7.1.2",
            iosBuild: "11D257",
            entryID: "n90ap-11D257",
            state: state,
            localNetwork: false
        )
    }

    func lock(recipe: Int, jailbreak: Bool, skipSetup: Bool = false, sandbox: (Bool, String)?) throws -> DeviceLock {
        var json: [String: Any] = [
            "board": "n90ap",
            "entry": [
                "content": ["recipe": ["version": recipe, "options": ["jailbreak": jailbreak, "skip_setup": skipSetup]]]
            ]
        ]
        if let sandbox {
            json["fit"] = [
                ["piece": "boot-arg amfi_allow_any_signature", "fits": true, "proof": "read"],
                ["piece": "sandbox patch (sb_evaluate)", "fits": sandbox.0, "proof": sandbox.1]
            ]
        }
        return try DeviceLock(json: json)
    }

    /// A device folder under `root` with `paths` in it (a path ending in "/" a folder, else a file).
    func folder(_ root: URL, _ paths: [String]) throws -> URL {
        let fm = FileManager.default
        let device = root.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: device.appendingPathComponent("overlay"), withIntermediateDirectories: true)
        for path in paths {
            let url = device.appendingPathComponent(path)
            let directory = path.hasSuffix("/") ? url : url.deletingLastPathComponent()
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if !path.hasSuffix("/") { try Data("0.42".utf8).write(to: url) }
        }
        return device
    }

    func storage(_ root: URL, format: Int, migrates: Bool = true, _ paths: [String] = [], log: String? = nil) throws
        -> [String]
    {
        let device = try folder(root, paths)
        let firmwareLog = device.appendingPathComponent("firmwarekit.log")
        if let log { try log.write(to: firmwareLog, atomically: true, encoding: .utf8) }
        var d = iPhone4()
        d.readStorage(
            directory: device,
            format: format,
            migrates: migrates,
            overlay: device.appendingPathComponent("overlay"),
            firmwareLog: firmwareLog
        )
        return d.storage
    }

    @Test func storageLines() throws {
        try withTemporaryDirectory { root throws in
            #expect(try storage(root, format: 2) == ["Storage: image store (format 2)"])
            #expect(
                try storage(root, format: 2, ["legacy/"])
                    == ["Storage: image store (format 2), format 1 copy kept until a clean stop"]
            )
            #expect(try storage(root, format: 1) == ["Storage: page files (format 1), migrates at the next start"])
            #expect(try storage(root, format: 1, migrates: false) == ["Storage: page files (format 1)"])
            #expect(try storage(root, format: 3) == ["Storage: format 3, newer than this build"])
            #expect(
                try storage(root, format: 1, ["work/migration.json"]).last
                    == "Storage migration: cut short, the next start finishes or undoes it"
            )
            #expect(
                try storage(root, format: 1, ["work/migration.json", "work/migration-progress"]).last
                    == "Storage migration: in progress (42%)"
            )
            #expect(
                try storage(root, format: 2, ["overlay/kboot.bin"]).last
                    == "Audio clock: repaired kboot.bin in the overlay"
            )
            // the last failure while the device is still format 1; a format 2 device got past it
            let log = """
                NAND image migration: needs 9000 bytes free; the device stays in format 1
                NAND image migration: proof failed: page 12 differs; the device stays in format 1
                NAND image migration: rolled back an interrupted run

                """
            #expect(
                try storage(root, format: 1, log: log).last
                    == "Storage migration failed: proof failed: page 12 differs"
            )
            #expect(try storage(root, format: 2, log: log) == ["Storage: image store (format 2)"])
        }
    }

    @Test func preparationLine() throws {
        func line(_ lock: DeviceLock, prepared: Date? = nil) -> String? {
            var d = iPhone4()
            d.readPreparation(lock)
            d.prepared = prepared
            return BugReportInfo.text(system: "", devices: [d], recentErrors: [], identity: identity)
                .split(separator: "\n").first { $0.contains("Prepared base") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        #expect(
            try line(lock(recipe: 3, jailbreak: true, skipSetup: true, sandbox: applied), prepared: prepared)
                == "Prepared base: recipe 3, 2026-10-12, Skip Setup, Jailbreak (sandbox patch applied)"
        )
        #expect(
            try line(lock(recipe: 2, jailbreak: true, sandbox: (false, "sb_evaluate not found")))
                == "Prepared base: recipe 2, Jailbreak (sandbox patch not found)"
        )
        #expect(
            try line(lock(recipe: 2, jailbreak: true, sandbox: (true, "no Seatbelt sandbox kext: nothing to patch")))
                == "Prepared base: recipe 2, Jailbreak (sandbox patch not needed)"
        )
        // stock says nothing of the patch; a jailbroken lock without the record, nothing either
        #expect(try line(lock(recipe: 3, jailbreak: false, sandbox: applied)) == "Prepared base: recipe 3, stock")
        #expect(try line(lock(recipe: 3, jailbreak: true, sandbox: nil)) == "Prepared base: recipe 3, Jailbreak")
        // Settings ▸ General's experimental writer (firmwarekit --hfs writer) is said; the kernel route is not
        for (hfs, said) in [("writer", ", without mounting"), ("kernel", "")] {
            let stock = try lock(recipe: 3, jailbreak: false, sandbox: nil)
            var json = try JSONSerialization.jsonObject(with: stock.data()) as! [String: Any]
            json["inputs"] = ["hfs": hfs]
            #expect(try line(DeviceLock(json: json)) == "Prepared base: recipe 3\(said), stock")
        }
    }

    @Test func settingsLinesOnlyWhenNotTheDefault() {
        var d = iPhone4("Running")
        d.iosVersion = "5.1.1"
        d.readSettings(DeviceSettings(), proxy: WebProxyConfiguration(), accessibilityOn: nil)
        let plain = BugReportInfo.text(system: system, devices: [d], recentErrors: [], identity: identity)
        for absent in [
            "Notice", "Web proxy", "Tweaks", "Accessibility", "120 Hz", "ANGLE", "Clipboard", "Free space", "Storage"
        ] {
            #expect(!plain.contains(absent), "\(absent)")
        }
        #expect(!plain.contains("Skipped"))
        var settings = DeviceSettings()
        settings.deviceNotices = [.init(message: "Light Touch needs 2 GB of free space.", operation: "storageUpdate")]
        settings.tweaks = TweakSettings()
        settings.tweaks?.on = [.timeMachine, .signalNumbers]
        d.readSettings(settings, proxy: WebProxyConfiguration(mode: .off), accessibilityOn: [.invertColors, .voiceOver])
        let text = BugReportInfo.text(
            system: system,
            freeSpace: 5_000_000_000,
            refresh120: true,
            angle: true,
            shareClipboard: false,
            skippedAfterCrash: ["3D device", "starting a device at launch"],
            devices: [d],
            recentErrors: [],
            identity: identity
        )
        #expect(
            text.contains(
                """
                arm64 on Mac16,10, Apple M4
                Free space: \(Int64(5_000_000_000).formatted(.byteCount(style: .file))) on the library's volume
                120 Hz refresh: on
                ANGLE renderer: on
                Clipboard sharing: off
                Skipped after a crash: 3D device, starting a device at launch
                """
            )
        )
        #expect(
            text.contains(
                """
                  Notice: Light Touch needs 2 GB of free space.
                  Web proxy: off
                  Tweaks: Signal as Numbers, Time Machine
                  Accessibility: VoiceOver, White on Black
                """
            )
        )
        d.readSettings(
            DeviceSettings(),
            proxy: WebProxyConfiguration(mode: .archive, archiveDate: "20090909"),
            accessibilityOn: []
        )
        #expect(d.webProxy == "archive (20090909)" && d.tweaks.isEmpty && d.accessibility.isEmpty && d.notices.isEmpty)
    }

    /// An iPhone 4 on 7.1.2, migrated (its format 1 copy not yet removed) and jailbroken, running.
    @Test func sampleIPhone4Migrated() throws {
        try withTemporaryDirectory { root throws in
            let device = try folder(root, ["legacy/base-nand"])
            var d = iPhone4("Running")
            d.internet = true
            d.guestTools = "Up to date (current(serial: 28))"
            d.emulatorBuild = "1538771e7dcf3b9c933d599ef98c04ce"
            d.readPreparation(try lock(recipe: 3, jailbreak: true, skipSetup: true, sandbox: applied))
            d.prepared = prepared
            d.readStorage(
                directory: device,
                format: 2,
                migrates: true,
                overlay: device.appendingPathComponent("overlay"),
                firmwareLog: device.appendingPathComponent("firmwarekit.log")
            )
            var settings = DeviceSettings()
            settings.tweaks = TweakSettings()
            settings.tweaks?.on = [.cleanStatusBar]
            d.readSettings(
                settings,
                proxy: WebProxyConfiguration(mode: .archive, archiveDate: "20090909"),
                accessibilityOn: [.voiceOver]
            )
            d.carrier = CarrierSettings()
            let text = BugReportInfo.text(
                system: system,
                freeSpace: 48_200_000_000,
                refresh120: true,
                devices: [d],
                recentErrors: [],
                identity: identity
            )
            #expect(
                text == """
                    ```text
                    \(system)
                    Free space: \(Int64(48_200_000_000).formatted(.byteCount(style: .file))) on the library's volume
                    120 Hz refresh: on

                    iPhone 4 (n90ap), iOS 7.1.2 (11D257), catalog n90ap-11D257
                      State: Running
                      Internet: on; Local Network: off
                      Guest tools: Up to date (current(serial: 28))
                      Emulator build: 1538771e7dcf3b9c933d599ef98c04ce
                      Prepared base: recipe 3, 2026-10-12, Skip Setup, Jailbreak (sandbox patch applied)
                      Storage: image store (format 2), format 1 copy kept until a clean stop
                      Web proxy: archive (20090909)
                      Tweaks: Marketing Status Bar
                      Accessibility: VoiceOver
                      Carrier: Light Touch (00101), registered, SIM in, 5 bars
                    ```

                    """
            )
        }
    }

    /// An original iPhone on 1.0, stopped, whose storage migration failed: the failure's line from firmwarekit's log
    /// names the home folder, the device's folder, a UDID, a serial number and the user, all scrubbed.
    @Test func sampleOriginalIPhoneMigrationFailed() throws {
        try withTemporaryDirectory { root throws in
            let device = try folder(root, [])
            let log = device.appendingPathComponent("firmwarekit.log")
            try
                ("NAND image migration: couldn't read /Users/jappleseed/Library/Application Support/Light Touch/Devices/"
                + "8874EC96-6945-4F6F-AD3D-96DDEBB6F52B/overlay (UDID 6f1ed002ab5595859014ebf0951522d9a1b2c3d4, "
                + "serial C02XK1ZQJGH5, user jappleseed); the device stays in format 1\n").write(
                    to: log, atomically: true, encoding: .utf8)
            var d = BugReportInfo.Device(
                marketingName: "iPhone",
                board: "m68ap",
                iosVersion: "1.0",
                iosBuild: "1A543a",
                entryID: "m68ap-1A543a",
                state: "Not running",
                localNetwork: false
            )
            d.guestTools = "last serial 28, not running"
            d.readPreparation(try lock(recipe: 1, jailbreak: false, sandbox: nil))
            d.prepared = prepared
            d.readStorage(
                directory: device,
                format: 1,
                migrates: true,
                overlay: device.appendingPathComponent("overlay"),
                firmwareLog: log
            )
            var settings = DeviceSettings()
            settings.deviceNotices = [
                .init(
                    message: "Light Touch couldn’t update this device’s storage, so it starts as before. "
                        + "The details are in the log.",
                    operation: "storageUpdate"
                )
            ]
            d.readSettings(settings, proxy: WebProxyConfiguration(), accessibilityOn: nil)
            d.carrier = CarrierSettings()
            let text = BugReportInfo.text(
                system: system,
                freeSpace: 48_200_000_000,
                devices: [d],
                recentErrors: [],
                identity: identity
            )
            #expect(
                text == """
                    ```text
                    \(system)
                    Free space: \(Int64(48_200_000_000).formatted(.byteCount(style: .file))) on the library's volume

                    iPhone (m68ap), iOS 1.0 (1A543a), catalog m68ap-1A543a
                      State: Not running
                      Local Network: off
                      Guest tools: last serial 28, not running
                      Prepared base: recipe 1, 2026-10-12, stock
                      Storage: page files (format 1), migrates at the next start
                      Storage migration failed: couldn't read ~/Library/Application Support/Light Touch/Devices/<uuid>/overlay (UDID <udid>, serial <serial>, user <redacted>)
                      Notice: Light Touch couldn’t update this device’s storage, so it starts as before. The details are in the log.
                      Carrier: Light Touch (00101), registered, SIM in, 5 bars
                    ```

                    """
            )
            for leak in ["jappleseed", "8874EC96", "6f1ed002ab", "C02XK1ZQJGH5"] { #expect(!text.contains(leak)) }
        }
    }
}
