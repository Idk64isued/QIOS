import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// Each device's proxy files: where they live, the routing the helper reads, the preferences (and an earlier build's
/// JSON), the per-device socket and the guest forward; the panel's status lines.
struct WebProxyConfigurationTests {
    func instance(usbmuxConf: String) -> DeviceInstance {
        DeviceInstance(
            id: UUID(),
            name: "iPod",
            board: "n72ap",
            firmware: "7E18",
            created: Date(),
            base: .init(kind: .prepared, path: "base"),
            storage: .init(key: "k", overlay: "o", snapshot: "s", usbmuxConf: usbmuxConf)
        )
    }

    /// The device that kept the legacy pairing conf keeps the legacy files (its guest trusts that CA).
    @Test func legacyDeviceKeepsTheStateDirectory() {
        #expect(
            WebProxyConfiguration.directory(for: instance(usbmuxConf: "work/usbmuxd-conf")) == Bundled.stateDirectory
        )
        let other = instance(usbmuxConf: "Devices/x/usbmuxd-conf")
        #expect(
            WebProxyConfiguration.directory(for: other) == other.paths.directory
                && other.paths.directory != Bundled.stateDirectory
        )
    }

    @Test func savedRoutingAndPreferences() throws {
        try withTemporaryDirectory { own in
            #expect(
                WebProxyConfiguration.load(from: own).mode == .direct,
                "a new device starts with the proxy on"
            )
            let saved = WebProxyConfiguration(mode: .archive, archiveDate: "20100101")
            try saved.save(in: own)
            #expect(WebProxyConfiguration.load(from: own) == saved)
            #expect(
                try String(contentsOf: WebProxyConfiguration.file(in: own), encoding: .utf8) == "archive\n20100101\n"
            )
            try WebProxyConfiguration(mode: .direct).save(in: own)
            #expect(try String(contentsOf: WebProxyConfiguration.file(in: own), encoding: .utf8) == "direct\n")
            #expect(throws: (any Error).self) {
                try WebProxyConfiguration(mode: .archive, archiveDate: "20101301").save(in: own)
            }
            #expect(
                try String(contentsOf: WebProxyConfiguration.file(in: own), encoding: .utf8) == "direct\n",
                "an invalid date writes nothing"
            )
        }
    }

    /// An earlier build's web-proxy.json is read once and becomes web-proxy.plist.
    @Test func earlierJSONBecomesAPropertyList() throws {
        try withTemporaryDirectory { earlier in
            try Data(#"{"mode":"direct","archiveDate":"20080808"}"#.utf8).write(
                to: earlier.appendingPathComponent("web-proxy.json")
            )
            #expect(
                WebProxyConfiguration.load(from: earlier)
                    == WebProxyConfiguration(mode: .direct, archiveDate: "20080808")
            )
            #expect(!FileManager.default.fileExists(atPath: earlier.appendingPathComponent("web-proxy.json").path))
            #expect(FileManager.default.fileExists(atPath: WebProxyConfiguration.preferencesFile(in: earlier).path))
        }
    }

    @Test func oneShortSocketPerDevice() {
        let own = URL(fileURLWithPath: "/" + String(repeating: "long-directory/", count: 12))
        let endpoint = WebProxyConfiguration.endpoint(directory: own)
        #expect(endpoint.config == WebProxyConfiguration.file(in: own).path && endpoint.socket.utf8.count < 104)
        #expect(
            endpoint != WebProxyConfiguration.endpoint(directory: own.appendingPathComponent("other")),
            "one socket per device"
        )
    }

    /// QEMU connects to the socket itself (no `cmd:`, which runs a program per guest connection); a comma is escaped.
    @Test func guestForwardConnectsToTheSocketWithoutAProgram() {
        let forward = WebProxyConfiguration.guestForward(socket: "/t/a,b's")
        #expect(forward == ",guestfwd=tcp:10.0.2.100:3128-unix-connect:/t/a,,b's")
        #expect(!forward.contains("cmd:"))
    }

    @Test func statusLines() {
        #expect(WebProxyStatus.waiting.message(for: .n72) == "Waiting for iPod…" && WebProxyStatus.waiting.isWorking)
        #expect(WebProxyStatus.applying.message(for: .n72) == "Updating proxy…" && WebProxyStatus.applying.isWorking)
        #expect(WebProxyStatus.ready.message(for: .n72) == nil && !WebProxyStatus.ready.isWorking)
        #expect(WebProxyStatus.failed.message(for: .k48)?.contains("Try again") == true)
    }
}
