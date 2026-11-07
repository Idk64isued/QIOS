import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// Help ▸ Copy Bug Report Info's block: what it says with no device, a stopped one and a running one with apps, the
/// recent errors it picks from app.log, and that no identity survives it.
struct BugReportInfoTests {
    let system = "Light Touch 1.2 (345)\nmacOS Version 27.0 (Build 27A100)\narm64 on Mac16,10, Apple M4"
    let identity = DiagnosticsExport.HostIdentity(home: "/Users/jappleseed", names: ["jappleseed", "Johnny Appleseed"])

    func iPhone(_ state: String) -> BugReportInfo.Device {
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

    @Test func noDevice() {
        let text = BugReportInfo.text(system: system, devices: [], recentErrors: [], identity: identity)
        #expect(text == "```text\n" + system + "\n\nNo device\n```\n")
    }

    @Test func stoppedDevice() {
        var device = iPhone("Not running")
        device.recipeVersion = 3
        device.skipSetup = true
        device.guestTools = "last serial 19, not running"
        device.carrier = CarrierSettings()
        let text = BugReportInfo.text(
            system: system,
            bezel: "flat",
            devices: [device],
            recentErrors: ["2026-10-08T04:23:40Z boot: readiness failed"],
            identity: identity
        )
        #expect(
            text == """
                ```text
                \(system)
                Device bezels: flat

                iPhone 4 (n90ap), iOS 7.1.2 (11D257), catalog n90ap-11D257
                  State: Not running
                  Local Network: off
                  Guest tools: last serial 19, not running
                  Prepared base: recipe 3, Skip Setup
                  Carrier: Light Touch (00101), registered, SIM in, 5 bars

                Recent errors:
                  2026-10-08T04:23:40Z boot: readiness failed
                ```

                """
        )
    }

    @Test func runningDeviceWithApps() {
        var device = iPhone("Running")
        device.zoom = "physical"
        device.panel = "1280x720"
        device.internet = true
        device.localNetwork = true
        device.guestTools = "Up to date (current(serial: 19))"
        device.emulatorBuild = "1538771e7dcf3b9c933d599ef98c04ce"
        device.recipeVersion = 2
        device.skipSetup = false
        device.apps = [InstalledApp(id: "com.example.flappy", name: "Flappy", version: "1.3")]
        var stopped = iPhone("Not running")
        stopped.marketingName = "iPod touch (4th generation)"
        let text = BugReportInfo.text(system: system, devices: [device, stopped], recentErrors: [], identity: identity)
        #expect(
            text.contains(
                """
                iPhone 4 (n90ap), iOS 7.1.2 (11D257), catalog n90ap-11D257
                  State: Running
                  Zoom: physical
                  Free-form screen: 1280x720
                  Internet: on; Local Network: on
                  Guest tools: Up to date (current(serial: 19))
                  Emulator build: 1538771e7dcf3b9c933d599ef98c04ce
                  Prepared base: recipe 2
                  Apps (1):
                    com.example.flappy — Flappy 1.3

                iPod touch (4th generation)
                """
            )
        )
        #expect(!text.contains("Recent errors"))
    }

    /// Every kind of identity the block could pick up (from the app's log, a device's name or its record) is gone;
    /// what a report needs (build IDs, iOS builds, the Mac model, dates) stays.
    @Test func noIdentityLeaks() {
        let leaks = [
            "/Users/jappleseed", "jappleseed", "Johnny Appleseed", "Johnny-Appleseeds-MacBook-Pro",
            "johnny@icloud.com", "00:1e:c2:aa:bb:cc", "00-1E-C2-AA-BB-CC",
            "6f1ed002ab5595859014ebf0951522d9a1b2c3d4", "00008020-001A2B3C4D5E6F70",
            "8874EC96-6945-4F6F-AD3D-96DDEBB6F52B", "012345678901237", "89014103211118510720", "C02XK1ZQJGH5",
            "seed-4f8a2c"
        ]
        var device = iPhone("Running — Couldn’t connect to 00:1e:c2:aa:bb:cc")
        device.marketingName = "Johnny Appleseed’s iPhone"
        device.guestTools = "UDID 6f1ed002ab5595859014ebf0951522d9a1b2c3d4, seed seed-4f8a2c"
        device.apps = [InstalledApp(id: "com.example.mail", name: "Mail for johnny@icloud.com", version: "1.0")]
        let errors = [
            "2026-10-08T04:23:40Z Couldn’t open /Users/jappleseed/Library/Application Support/x/Devices/"
                + "8874EC96-6945-4F6F-AD3D-96DDEBB6F52B/base on Johnny-Appleseeds-MacBook-Pro",
            "2026-10-08T04:23:41Z modem failed: imei 012345678901237 iccid 89014103211118510720",
            "2026-10-08T04:23:42Z lockdown failed: 00008020-001A2B3C4D5E6F70 serial C02XK1ZQJGH5 "
                + "mac 00-1E-C2-AA-BB-CC user jappleseed"
        ]
        let host = DiagnosticsExport.HostIdentity(
            home: identity.home,
            names: identity.names + ["Johnny-Appleseeds-MacBook-Pro"]
        )
        let text = BugReportInfo.text(
            system: system,
            devices: [device],
            recentErrors: errors,
            secrets: ["seed-4f8a2c"],
            identity: host
        )
        for leak in leaks { #expect(!text.localizedCaseInsensitiveContains(leak), "\(leak)") }
        for kept in ["~/Library/Application Support", "Mac16,10", "11D257", "2026-10-08T04:23:41Z", "com.example.mail"]
        {
            #expect(text.contains(kept), "\(kept)")
        }
    }

    @Test func recentErrorsAreTheLastFailuresCut() throws {
        try withTemporaryDirectory { dir in
            let log = dir.appendingPathComponent("app.log")
            let lines =
                (1...8).map { "t\($0) boot: readiness failed \($0)" } + [
                    "t9 guest package: serial 19 judged good",
                    "t10 Couldn’t save to disk " + String(repeating: "x", count: 300)
                ]
            try lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
            let errors = BugReportInfo.recentErrors(log: log, limit: 3, width: 40)
            #expect(errors.count == 3 && errors[0].hasPrefix("t7 ") && errors[1].hasPrefix("t8 "))
            #expect(errors[2].hasPrefix("t10 ") && errors[2].count == 40 && errors[2].hasSuffix("…"))
            #expect(BugReportInfo.recentErrors(log: dir.appendingPathComponent("missing.log")).isEmpty)

            // A device that died is the failure a bug report most needs (DeviceProcess.reason's .unexpected).
            let died = "t11 device helper 93799: exited(1), QEMU exit none — The iPhone stopped unexpectedly."
            try (lines + [died, "t12 stop: device halted"]).joined(separator: "\n").write(
                to: log,
                atomically: true,
                encoding: .utf8
            )
            #expect(BugReportInfo.recentErrors(log: log, width: 200).last == died)
        }
    }
}
