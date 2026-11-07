import Foundation
import Testing

@testable import LightTouchCore

/// Where a capture is saved: the chosen folder (created), named in local time without a random suffix, " 2" on a
/// collision, and a failure when the folder can't be made.
struct CaptureDestinationTests {
    @Test func localTimeNames() {
        let at = Date(timeIntervalSince1970: 1_791_330_134)  // 2026-10-06 23:42:14 UTC
        let local = DateFormatter()
        local.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        local.locale = Locale(identifier: "en_US_POSIX")
        #expect(
            CapturePreferences.captureName("Screenshot", at: at) == "Light Touch Screenshot " + local.string(from: at)
        )
        let zone = NSTimeZone.default
        defer { NSTimeZone.default = zone }
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        #expect(
            CapturePreferences.captureName("Screenshot", at: at) == "Light Touch Screenshot 2026-10-06 at 19.42.14",
            "local time"
        )
    }

    @Test func destinationsCreateFoldersAndAvoidTakenNames() throws {
        let domain = "ltm-capture-destination-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try withTemporaryDirectory { base in
            let preferences = CapturePreferences(defaults: defaults)
            preferences.saveLocation = base.appendingPathComponent("nested")
            let at = Date()
            let first = try preferences.captureDestination("Screenshot", extension: "png", at: at)
            #expect(
                first.lastPathComponent == CapturePreferences.captureName("Screenshot", at: at) + ".png",
                "no random suffix"
            )
            #expect(
                FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path),
                "the folder is made"
            )
            try Data([1, 2, 3]).write(to: first, options: .atomic)
            let second = try preferences.captureDestination("Screenshot", extension: "png", at: at)
            #expect(
                second.deletingPathExtension().lastPathComponent == first.deletingPathExtension().lastPathComponent
                    + " 2",
                "a taken name is not reused"
            )
            #expect(try Data(contentsOf: first) == Data([1, 2, 3]))
            let taken = first.deletingLastPathComponent().appendingPathComponent("Light Touch Screenshot X.png")
            try Data().write(to: taken)
            #expect(taken.unused.lastPathComponent == "Light Touch Screenshot X 2.png")
            try Data().write(to: taken.unused)
            #expect(taken.unused.lastPathComponent == "Light Touch Screenshot X 3.png")
            let blocker = base.appendingPathComponent("file")
            try Data().write(to: blocker)
            preferences.saveLocation = blocker.appendingPathComponent("child")
            #expect(throws: (any Error).self, "an unwritable folder") {
                try preferences.captureDestination("Recording", extension: "mov")
            }
        }
    }
}
