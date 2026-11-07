import FirmwareSchema
import Foundation
import Testing

/// What the app spawns firmwarekit with is what the CLI parses: each command's `arguments` parse back to themselves.
struct FirmwareCommandTests {
    @Test func everyCommandsArgumentsParseBackToTheSameCommand() throws {
        let url = URL(fileURLWithPath: "/tmp/a b")
        // The commands the app and the harness build.
        let built: [any FirmwareCommandLine] = [
            FirmwareCommand.Create(
                entry: url,
                ipsw: url,
                out: url,
                seed: "S",
                helper: url,
                cache: url,
                guestTools: url,
                sibling: (url, url),
                skipSetup: true,
                language: "fr-FR",
                hfs: .writer
            ),
            FirmwareCommand.UnpackBase(blob: url, out: url, seed: "S", hfs: .writer),
            FirmwareCommand.PackBase(base: url, out: url),
            FirmwareCommand.BootAdmit(device: url, recordPolicy: .standalone, allowRaw: true),
            FirmwareCommand.Edit(
                device: url,
                action: .trustAnchor,
                session: UUID(),
                recordPolicy: .managed,
                cert: url,
                mountPoint: url
            ),
            FirmwareCommand.Mount(device: url, recordPolicy: .managed, out: url, root: url),
            FirmwareCommand.Unmount(out: url),
            FirmwareCommand.CachePrune(root: url),
            FirmwareCommand.DetachImages(root: url),
            FirmwareCommand.Unwrap(entry: url, archive: url, out: url)
        ]
        // The ones only people and scripts type, in `arguments`' order.
        let typed = [
            [
                "create", "--catalog", "c", "--id", "x", "--ipsw", "i", "--out", "o", "--stop-after", "volumes",
                "--gl-test"
            ],
            ["export", "--device", "/d", "--volume", "data", "--out", "/o", "--record-policy", "managed"],
            ["verify-keys", "--entry", "/e", "--ipsw", "/i"],
            ["fit", "--root", "/r", "--arch", "armv6", "--host", "h", "/x", "/y"],
            ["fetch", "--entry", "/e", "--out", "/o"],
            [
                "developer-offer", "--offer", "/o", "--payload", "/p", "--state", "/s", "--instance", "U",
                "--public-key", "/k", "--serial", "3"
            ],
            ["developer-audit", "--payload", "/p"]
        ]
        var covered: Set<String> = []
        for arguments in built.map(\.arguments) + typed {
            let type = try #require(FirmwareCommand.all.first { $0.configuration.commandName == arguments.first })
            let parsed = try type.parse(Array(arguments.dropFirst()))
            #expect(parsed.arguments == arguments)
            covered.insert(arguments[0])
        }
        #expect(covered == Set(FirmwareCommand.all.compactMap { $0.configuration.commandName }))
    }

    /// The app's Skip Setup Assistant choice reaches the preparer as --skip-setup, and only when chosen.
    @Test func createPassesSkipSetupOnlyWhenChosen() {
        let url = URL(fileURLWithPath: "/tmp/x")
        #expect(
            FirmwareCommand.Create(entry: url, ipsw: url, out: url, skipSetup: true).arguments.last == "--skip-setup")
        #expect(!FirmwareCommand.Create(entry: url, ipsw: url, out: url).arguments.contains("--skip-setup"))
    }

    /// The app's Jailbreak choice reaches the preparer as --jailbreak, and only when chosen.
    @Test func createPassesJailbreakOnlyWhenChosen() {
        let url = URL(fileURLWithPath: "/tmp/x")
        #expect(
            FirmwareCommand.Create(entry: url, ipsw: url, out: url, jailbreak: true).arguments.last == "--jailbreak")
        #expect(!FirmwareCommand.Create(entry: url, ipsw: url, out: url).arguments.contains("--jailbreak"))
    }

    @Test func createTakesAnEntryOrACatalogWithAnID() {
        #expect(throws: (any Error).self) { try FirmwareCommand.Create.parse(["--ipsw", "i", "--out", "o"]) }
        #expect(throws: (any Error).self) {
            try FirmwareCommand.Create.parse([
                "--entry", "e", "--catalog", "c", "--id", "x", "--ipsw", "i", "--out", "o"
            ])
        }
        #expect(throws: (any Error).self) {
            try FirmwareCommand.Create.parse(["--catalog", "c", "--ipsw", "i", "--out", "o"])
        }
        #expect(throws: Never.self) {
            try FirmwareCommand.Create.parse(["--catalog", "c", "--id", "x", "--ipsw", "i", "--out", "o"])
        }
    }
}
