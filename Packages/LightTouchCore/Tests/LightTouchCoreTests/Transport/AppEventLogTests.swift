import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// The app's event log (app.log): concurrent appends, private permissions, rotation at its limit, recovery from a
/// deleted file, bounded lines and a write failure that touches nothing.
struct AppEventLogTests {
    @Test func concurrentAppendsRotationRemovalBoundsAndFailure() async throws {
        try await withScratchDirectory { root in
            let directory = root.appendingPathComponent("events", isDirectory: true)
            let log = AppEventLog(directory: directory)
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<200 { group.addTask { log.append("event-\(i)") } }
            }
            await log.flush()
            let file = directory.appendingPathComponent("app.log")
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            #expect(lines.count == 200)
            for i in 0..<200 { #expect(lines.contains { $0.hasSuffix(" event-\(i)") }) }
            let permissions =
                try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
            #expect(permissions.intValue & 0o777 == 0o600)

            // Filled through the log itself (it tracks the size it wrote), then a line past the limit rotates it.
            var before = 0
            repeat {
                log.append(String(repeating: "A", count: 31_000))
                await log.flush()
                before = try Data(contentsOf: file).count
            } while before + 31_100 <= 1_000_000
            log.append("after rotation" + String(repeating: "B", count: 31_986))
            await log.flush()
            #expect(try Data(contentsOf: file.appendingPathExtension("1")).count == before)
            #expect(try String(contentsOf: file, encoding: .utf8).contains("after rotation"))

            try FileManager.default.removeItem(at: file)  // deleted under the open log: the next line recreates it
            log.append("after removal")
            await log.flush()
            #expect(try String(contentsOf: file, encoding: .utf8).contains("after removal"))
            let rotated = try Data(contentsOf: file).count
            log.append(String(repeating: "🦋", count: 100_000))
            await log.flush()
            #expect(try Data(contentsOf: file).count - rotated < 33_000)
            log.append("a" + String(repeating: "\u{301}", count: 100_000))
            await log.flush()
            #expect(try Data(contentsOf: file).count - rotated < 66_000)

            let blocked = root.appendingPathComponent("blocked")
            try Data("keep".utf8).write(to: blocked)
            let broken = AppEventLog(directory: blocked)
            broken.append("cannot write")
            broken.append("still cannot write")
            await broken.flush()
            #expect(try String(contentsOf: blocked, encoding: .utf8) == "keep")
        }
    }

    @Test func logEventTakesLiteralPercentAndFormats() async throws {
        let marker = UUID().uuidString
        logEvent("literal 100% \(marker)")
        logEvent("formatted %@ \(marker)", "value")
        await AppEventLog.shared.flush()
        let text = try String(contentsOf: Bundled.logsDirectory.appendingPathComponent("app.log"), encoding: .utf8)
        #expect(text.contains("literal 100% \(marker)") && text.contains("formatted value \(marker)"))
    }
}
