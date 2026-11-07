// App-compatibility survey: `LTM_APPS_LIST=FILE sessions single BASE --no-install`, FILE's lines "ipa<TAB>bundleID"
// ("-" for the ipa: an app the firmware has, launched without an install). Each app is installed, launched through the
// guest agent and shot at 10 s and 30 s (app<n>-10s/-30s.png); up to three of the guest's own prompts are answered by
// the label Vision reads on them (OK first); a tap mid-screen (app<n>-tapped.png), then Home. One `app` event an app.
// The guest's syslog (syslog.txt) and its crash reports (crash/) land in the device directory, through libimobiledevice's
// idevicesyslog and idevicecrashreport on PATH.

import Foundation
import LightTouchCore

@MainActor func appsSurvey(_ d: Device, list: String) async {
    let lines = ((try? String(contentsOfFile: list, encoding: .utf8)) ?? "").split(separator: "\n")
    let socket = d.mux.clientSocket
    let env = ProcessInfo.processInfo.environment.merging(["USBMUXD_SOCKET_ADDRESS": socket]) { $1 }
    let syslog = Process()
    syslog.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    syslog.arguments = ["idevicesyslog", "--no-colors"]
    syslog.environment = env
    FileManager.default.createFile(atPath: d.dir.appendingPathComponent("syslog.txt").path, contents: nil)
    syslog.standardOutput = FileHandle(forWritingAtPath: d.dir.appendingPathComponent("syslog.txt").path)
    syslog.standardError = FileHandle.nullDevice
    try? syslog.run()
    let agent = GuestAgent(link: d.process.link, cache: GuestAgentCache())
    for (n, line) in lines.enumerated() {
        let parts = line.split(separator: "\t").map(String.init)
        guard parts.count == 2 else { continue }
        let (ipa, id) = (URL(fileURLWithPath: parts[0]), parts[1])
        var event: [String: Any] = ["device": d.name, "bundleID": id, "ipa": ipa.lastPathComponent]
        let start = Date()
        if parts[0] != "-" {
            do {
                let staged = try await d.services.stage(ipa) { _ in }
                try await d.services.install(ipa, staged: staged, bundleID: id) { _, _ in }
                event["installSeconds"] = Date().timeIntervalSince(start)
            } catch {
                event["installError"] = "\(error)"
                emit("app", event)
                continue
            }
        }
        do { try await agent.launch(id) } catch { event["launchError"] = "\(error)" }
        var tapped: [String] = []
        for (label, wait) in [("10s", 10), ("30s", 20)] {
            try? await Task.sleep(for: .seconds(wait))
            if let p = d.screenshot("app\(n)-\(label)") { event["shot" + label] = p }
            if let f = try? await agent.frontmost() { event["front" + label] = f.bundleID }
            // The guest's own prompts (Game Center, push, location): answer up to 3, as a user would.
            for i in 0..<(label == "10s" ? 3 : 0) {
                guard let shot = d.screenshot("app\(n)-prompt\(i)") else { break }
                let found = SetupPhone.labels(shot)
                guard
                    let key = ["OK", "Not Now", "Later", "No Thanks", "Close", "Cancel", "Don't Allow"].first(where: {
                        found[$0] != nil
                    }), let at = found[key]
                else { break }
                tapped.append(key)
                await d.tap(at.x, at.y)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        event["prompts"] = tapped
        await d.tap(0.5, 0.5)
        try? await Task.sleep(for: .seconds(5))
        if let p = d.screenshot("app\(n)-tapped") { event["shotTapped"] = p }
        if let f = try? await agent.frontmost() { event["frontTapped"] = f.bundleID }
        emit("app", event)
        d.process.link.send(.button(0, down: true))
        try? await Task.sleep(for: .milliseconds(150))
        d.process.link.send(.button(0, down: false))
        try? await Task.sleep(for: .seconds(4))
    }
    let crash = Process()
    crash.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    crash.arguments = ["idevicecrashreport", "-e", "-k", d.dir.appendingPathComponent("crash").path]
    crash.environment = env
    try? FileManager.default.createDirectory(
        at: d.dir.appendingPathComponent("crash"),
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: d.dir.appendingPathComponent("crash.log").path, contents: nil)
    crash.standardOutput = FileHandle(forWritingAtPath: d.dir.appendingPathComponent("crash.log").path)
    crash.standardError = crash.standardOutput
    try? crash.run()
    for _ in 0..<60 where crash.isRunning { try? await Task.sleep(for: .seconds(1)) }
    if crash.isRunning { crash.terminate() }
    syslog.terminate()
    emit("appsDone", ["device": d.name])
}
