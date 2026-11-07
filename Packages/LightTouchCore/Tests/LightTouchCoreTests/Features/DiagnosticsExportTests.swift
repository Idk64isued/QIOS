import Darwin
import Foundation
import Testing

@testable import LightTouchCore

/// Diagnostics export: the app's own crash reports, the system summary, and an atomic archive that a failing,
/// empty, missing or cancelled archiver never half-writes, with concurrent exports keeping their own scratch.
struct DiagnosticsExportTests {
    let fm = FileManager.default

    nonisolated func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    nonisolated func children(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    @Test func crashReportsAreTheAppsOwnNewestFirstWithinThirtyDays() throws {
        try withTemporaryDirectory { reports in
            for (name, age) in [
                ("LightTouch-2026-10-07-101010.ips", 60.0), ("LightTouchDevice-2026-10-07-101011.ips", 30.0),
                ("Safari-2026-10-07-101012.ips", 10.0), ("LightTouchServices-2026-08-01-101010.ips", 40 * 86_400.0),
                ("LightTouchDevice-notes.txt", 5.0)
            ] {
                let url = reports.appendingPathComponent(name)
                try Data("report".utf8).write(to: url)
                try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
            }
            let found = DiagnosticsExport.crashReports(
                executables: ["LightTouch", "LightTouchDevice", "LightTouchServices"],
                in: reports
            )
            #expect(
                found.map(\.lastPathComponent) == [
                    "LightTouchDevice-2026-10-07-101011.ips", "LightTouch-2026-10-07-101010.ips"
                ]
            )
        }
    }

    @Test func systemSummaryNamesTheOSAndArchitecture() {
        let summary = DiagnosticsExport.systemSummary()
        #expect(summary.contains("macOS ") && summary.contains(ProcessInfo.processInfo.operatingSystemVersionString))
        #expect(summary.contains("arm64") || summary.contains("x86_64"))
    }

    /// An archiver stand-in: `fail` writes a partial archive and exits 9, `empty` an empty one, `cancel` records its
    /// pid in staging/ready and sleeps until killed. ($5 is the staging directory, $6 the archive.)
    func archiver(in directory: URL) throws -> URL {
        try LibraryFixtures.script(
            directory.appendingPathComponent("archive-helper"),
            """
            case "$(cat "$5/info.txt")" in
                fail) printf incomplete > "$6"; exit 9 ;;
                empty) : > "$6"; exit 0 ;;
                cancel) printf '%s\\n' "$$" > "$5/ready"; exec /bin/sleep 60 ;;
            esac
            exit 1

            """
        )
    }

    @Test func exportIsAtomicAndCancellable() async throws {
        try await LibraryFixtures.withScratch { root in
            let scratch = root.appendingPathComponent("diagnostic temp")
            let exports = root.appendingPathComponent("exports")
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            try fm.createDirectory(at: exports, withIntermediateDirectories: true)
            let log = root.appendingPathComponent("app.log")
            try Data("sample events".utf8).write(to: log)
            let report = root.appendingPathComponent("LightTouchDevice-2026-10-07-101011.ips")
            try Data("report".utf8).write(to: report)

            // A real ditto archive: valid, with the info and the crash report, and no scratch left.
            let success = exports.appendingPathComponent("success.zip")
            try await DiagnosticsExport.write(
                to: success,
                logs: [log],
                info: "real ditto archive",
                crashReports: [report],
                temporaryRoot: scratch
            )
            #expect(try children(scratch).isEmpty)
            try LibraryFixtures.run("/usr/bin/unzip", ["-tq", success.path])
            #expect(
                try LibraryFixtures.run("/usr/bin/unzip", ["-p", success.path, "LightTouchMac-diagnostics/info.txt"])
                    == "real ditto archive"
            )
            let listing = try LibraryFixtures.run("/usr/bin/unzip", ["-Z1", success.path]).split(separator: "\n")
            #expect(listing.contains("LightTouchMac-diagnostics/CrashReports/LightTouchDevice-2026-10-07-101011.ips"))

            // A failing, empty or missing archiver: an error, the existing archive kept, nothing left behind.
            let helper = try archiver(in: root)
            let preserved = exports.appendingPathComponent("preserved.zip")
            try Data("existing user archive".utf8).write(to: preserved)
            func untouched() throws {
                #expect(try text(preserved) == "existing user archive")
                #expect(try children(scratch).isEmpty)
                #expect(try children(exports).allSatisfy { !$0.lastPathComponent.hasPrefix(".LightTouch-") })
            }
            for (info, executable) in [
                ("fail", helper), ("empty", helper), ("missing", root.appendingPathComponent("no-archiver"))
            ] {
                await #expect(throws: (any Error).self, "\(info)") {
                    try await DiagnosticsExport.write(
                        to: preserved,
                        logs: [log],
                        info: info,
                        temporaryRoot: scratch,
                        archiver: executable
                    )
                }
                try untouched()
            }

            // One export's archiver still running while another completes: neither deletes the other's scratch.
            let cancelled = Task {
                try await DiagnosticsExport.write(
                    to: preserved,
                    logs: [log],
                    info: "cancel",
                    temporaryRoot: scratch,
                    archiver: helper
                )
            }
            var ready: URL?
            let deadline = Date().addingTimeInterval(10)
            while ready == nil, Date() < deadline {
                ready = try children(scratch).map { $0.appendingPathComponent("LightTouchMac-diagnostics/ready") }
                    .first { !((try? text($0))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
                if ready == nil { try await Task.sleep(for: .milliseconds(10)) }
            }
            guard let ready else {
                cancelled.cancel()
                Issue.record("the archiver did not start")
                return
            }
            let pid = try #require(Int32(text(ready).trimmingCharacters(in: .whitespacesAndNewlines)))
            let concurrent = exports.appendingPathComponent("concurrent.zip")
            try await DiagnosticsExport.write(
                to: concurrent,
                logs: [log],
                info: "concurrent real archive",
                temporaryRoot: scratch
            )
            #expect(try fm.fileExists(atPath: ready.path) && children(scratch).count == 1)
            #expect(try text(ready.deletingLastPathComponent().appendingPathComponent("info.txt")) == "cancel")
            #expect(
                try LibraryFixtures.run(
                    "/usr/bin/unzip",
                    ["-p", concurrent.path, "LightTouchMac-diagnostics/info.txt"]
                ) == "concurrent real archive"
            )

            // Cancelled: CancellationError, the child gone, nothing written.
            let cancelledAt = Date()
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(
                Date().timeIntervalSince(cancelledAt) < 10,
                "the cancel waited for the archiver instead of stopping it"
            )
            #expect(kill(pid, 0) != 0, "the cancelled archiver is still running")
            try untouched()
            #expect(try text(log) == "sample events")
        }
    }

    /// What firmwarekit says on stderr while it admits a boot (a storage migration's steps and failures) is kept in
    /// the device's firmwarekit.log, appended, for the export and Copy Bug Report Info to read.
    @Test func bootAdmissionKeepsTheWorkersLog() async throws {
        try await LibraryFixtures.withScratch { root in
            let worker = try LibraryFixtures.script(
                root.appendingPathComponent("firmwarekit"),
                """
                echo "NAND image migration: needs 9000 bytes free; the device stays in format 1" >&2
                echo '{"event":"admitted","changed":false}'

                """
            )
            let log = root.appendingPathComponent("logs/firmwarekit.log")
            for _ in 0..<2 {
                _ = try await FirmwareTool.admitBoot(device: root, managed: true, executable: worker, log: log)
            }
            #expect(
                try text(log)
                    == String(
                        repeating: "NAND image migration: needs 9000 bytes free; the device stays in format 1\n",
                        count: 2
                    )
            )
        }
    }

    /// A log over the cap keeps its newest bytes, after a line saying earlier ones were cut; one under it is whole.
    @Test func longLogsKeepTheirNewestContent() async throws {
        try await LibraryFixtures.withScratch { root in
            let long = root.appendingPathComponent("native.log")
            let old = String(repeating: "oldest line\n", count: 100_000)
            let new = String(repeating: "newest line\n", count: DiagnosticsExport.logLimit / 12)
            try (old + new).write(to: long, atomically: true, encoding: .utf8)
            let short = root.appendingPathComponent("serial.log")
            try "boot\n".write(to: short, atomically: true, encoding: .utf8)
            let archive = root.appendingPathComponent("capped.zip")
            try await DiagnosticsExport.write(to: archive, logs: [short], deviceLogs: [long], info: "")
            let kept = try LibraryFixtures.run(
                "/usr/bin/unzip",
                ["-p", archive.path, "LightTouchMac-diagnostics/Device/native.log"]
            )
            #expect(kept.hasPrefix("(earlier lines cut)\n") && kept.hasSuffix(new) && !kept.contains("oldest"))
            #expect(kept.utf8.count <= DiagnosticsExport.logLimit + "(earlier lines cut)\n".utf8.count)
            #expect(
                try LibraryFixtures.run("/usr/bin/unzip", ["-p", archive.path, "LightTouchMac-diagnostics/serial.log"])
                    == "boot\n"
            )
        }
    }

    /// The archive's logs, info and crash reports carry no identity: the home folder, the user's and the Mac's
    /// names, the device's own identifiers and anything shaped like one are gone from the text, and a crash report
    /// loses its identifying members while its stacks and binary images stay byte for byte.
    @Test func exportIsScrubbed() async throws {
        try await LibraryFixtures.withScratch { root in
            let identity = DiagnosticsExport.HostIdentity(
                home: "/Users/jappleseed",
                names: ["jappleseed", "Johnny Appleseed", "Johnnys-MacBook-Pro"]
            )
            let leaks = [
                "/Users/jappleseed", "jappleseed", "Johnny Appleseed", "Johnnys-MacBook-Pro", "johnny@icloud.com",
                "00:1e:c2:aa:bb:cc", "6f1ed002ab5595859014ebf0951522d9a1b2c3d4", "00008020-001A2B3C4D5E6F70",
                "8874EC96-6945-4F6F-AD3D-96DDEBB6F52B", "012345678901237", "C02XK1ZQJGH5", "seed-4f8a2c"
            ]
            let log = root.appendingPathComponent("serial.log")
            try """
            2026-10-08T04:23:40Z opened /Users/jappleseed/Library/Devices/8874EC96-6945-4F6F-AD3D-96DDEBB6F52B
            lockdown: UDID 6f1ed002ab5595859014ebf0951522d9a1b2c3d4 (00008020-001A2B3C4D5E6F70) seed seed-4f8a2c
            wifi 00:1e:c2:aa:bb:cc imei 012345678901237 serial C02XK1ZQJGH5 on Johnnys-MacBook-Pro
            Apple ID johnny@icloud.com, user jappleseed (Johnny Appleseed)
            emulator build 1538771e7dcf3b9c933d599ef98c04ce
            """.write(to: log, atomically: true, encoding: .utf8)
            let rotated = root.appendingPathComponent("serial.log.1")
            try "older: Johnny Appleseed’s iPhone at /Users/jappleseed".write(
                to: rotated,
                atomically: true,
                encoding: .utf8
            )
            let stacks = """
                  "threads" : [{"id" : 1234,"frames" : [{"imageOffset" : 16588,"symbol" : "main","imageIndex" : 0}]}],
                  "usedImages" : [{"uuid" : "59d15082-65eb-3584-a2a3-77fe117b8dec","base" : 4294967296,
                  "path" : "/Applications/Light Touch.app/Contents/MacOS/LightTouch","name" : "LightTouch"}]
                """
            let report = root.appendingPathComponent("LightTouch-2026-10-08-101010.ips")
            try """
            {"app_name":"LightTouch","incident_id":"8231277F-99CB-4CC0-BC6A-EC990F9904ED","os_version":"macOS 27.0"}
            {
              "procPath" : "/Users/jappleseed/Applications/Light Touch.app/Contents/MacOS/LightTouch",
              "crashReporterKey" : "4CE2ED4F-7491-7733-6730-2843A1FD34AD",
              "bootSessionUUID" : "B69885FD-2DD0-4563-A355-7844D18BF0A6",
              "sleepWakeUUID" : "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9",
              "incident" : "8231277F-99CB-4CC0-BC6A-EC990F9904ED",
              "Hardware UUID" : "11111111-2222-3333-4444-555555555555",
              "responsibleProc" : "Johnnys-MacBook-Pro helper",
            \(stacks)
            }
            """.write(to: report, atomically: true, encoding: .utf8)
            // the device's own logs: a storage migration's failure in firmwarekit's, the helper's and the preparation's
            let device = root.appendingPathComponent("Devices/8874EC96-6945-4F6F-AD3D-96DDEBB6F52B")
            try fm.createDirectory(at: device, withIntermediateDirectories: true)
            let firmwareLog = device.appendingPathComponent("firmwarekit.log")
            try """
            NAND image migration: couldn't read /Users/jappleseed/Library/Devices/8874EC96-6945-4F6F-AD3D-96DDEBB6F52B/overlay (UDID 6f1ed002ab5595859014ebf0951522d9a1b2c3d4, serial C02XK1ZQJGH5); the device stays in format 1
            """.write(to: firmwareLog, atomically: true, encoding: .utf8)
            let native = device.appendingPathComponent("native.log")
            try "helper: lease /Users/jappleseed/x on Johnnys-MacBook-Pro, wifi 00:1e:c2:aa:bb:cc".write(
                to: native,
                atomically: true,
                encoding: .utf8
            )
            let preparing = root.appendingPathComponent("n90ap-11D257.log")
            try "[1/8] Verifying /Users/jappleseed/Downloads/x.ipsw\nout: UDID 00008020-001A2B3C4D5E6F70".write(
                to: preparing,
                atomically: true,
                encoding: .utf8
            )
            let archive = root.appendingPathComponent("scrubbed.zip")
            try await DiagnosticsExport.write(
                to: archive,
                logs: [log, rotated, root.appendingPathComponent("absent.log")],
                deviceLogs: [firmwareLog, native, preparing, device.appendingPathComponent("serial.log")],
                info: "device: Johnny Appleseed’s iPhone 8874EC96-6945-4F6F-AD3D-96DDEBB6F52B base /Users/jappleseed/x",
                crashReports: [report],
                secrets: ["seed-4f8a2c"],
                identity: identity
            )
            func member(_ name: String) throws -> String {
                try LibraryFixtures.run("/usr/bin/unzip", ["-p", archive.path, "LightTouchMac-diagnostics/" + name])
            }
            let names = [
                "serial.log", "serial.log.1", "info.txt", "Device/firmwarekit.log", "Device/native.log",
                "Device/n90ap-11D257.log"
            ]
            let texts = try names.map(member)
            for (name, text) in zip(names, texts) {
                for leak in leaks { #expect(!text.localizedCaseInsensitiveContains(leak), "\(name): \(leak)") }
            }
            #expect(
                texts[3] == "NAND image migration: couldn't read ~/Library/Devices/<uuid>/overlay (UDID <udid>, serial "
                    + "<serial>); the device stays in format 1"
            )
            // what's there, under names that say nothing of the device
            let listing = try LibraryFixtures.run("/usr/bin/unzip", ["-Z1", archive.path]).split(separator: "\n")
                .map(String.init).filter { !$0.hasSuffix("/") && !$0.hasPrefix("__MACOSX/") }.sorted()
            #expect(
                listing
                    == (names + ["CrashReports/LightTouch-2026-10-08-101010.ips"]).map {
                        "LightTouchMac-diagnostics/" + $0
                    }
                    .sorted()
            )
            #expect(texts[0].contains("emulator build 1538771e7dcf3b9c933d599ef98c04ce"))
            #expect(texts[1] == "older: <redacted>’s iPhone at ~")
            #expect(texts[2] == "device: <redacted>’s iPhone <uuid> base ~/x")

            let crash = try member("CrashReports/LightTouch-2026-10-08-101010.ips")
            for leak in [
                "/Users/jappleseed", "Johnnys-MacBook-Pro", "8231277F-99CB-4CC0-BC6A-EC990F9904ED",
                "4CE2ED4F-7491-7733-6730-2843A1FD34AD", "B69885FD-2DD0-4563-A355-7844D18BF0A6",
                "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9", "11111111-2222-3333-4444-555555555555"
            ] {
                #expect(!crash.contains(leak), "\(leak)")
            }
            #expect(crash.contains(stacks), "the stacks and images are untouched")
            #expect(crash.contains(#""procPath" : "~/Applications/Light Touch.app/Contents/MacOS/LightTouch""#))
            #expect(crash.contains(#""crashReporterKey" : "<redacted>""#))
            // Still a header line and a JSON report.
            let parts = crash.split(separator: "\n", maxSplits: 1).map { Data($0.utf8) }
            #expect(parts.count == 2 && parts.allSatisfy { (try? JSONSerialization.jsonObject(with: $0)) != nil })
        }
    }
}
