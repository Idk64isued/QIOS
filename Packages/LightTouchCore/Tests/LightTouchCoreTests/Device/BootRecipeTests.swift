import DeviceRuntime
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// HostRuntime's boot recipe as the app uses it: the iPad's boot strategies and their inputs, the machine options a
/// unit's identity provisions, and 5.x Setup offline (slirp restrict until Setup is over, then networking in place).
struct BootRecipeTests {
    static func info(_ machine: String, _ board: String) -> DeviceInfo {
        DeviceInfo(
            machine: machine,
            board: board,
            screenWidth: 320,
            screenHeight: 480,
            screenScale: 1,
            defaultOrientation: 0,
            hasCellular: false,
            hasUSBHost: false,
            hasCompass: false,
            panelMin: 64,
            panelMaxWidth: 1024,
            panelMaxHeight: 511,
            panelWidthStep: 2,
            panelMaxPixels: 0
        )
    }
    static func machine(_ boot: BootRecipe.IPadBoot) -> String {
        BootRecipe.iPad(
            .init(boot: boot, nand: "nand", overlay: "overlay", dieID: "1:2", usbAddress: nil, wifi: false),
            hardware: info("ipad1", "k48ap"),
            serial: "null",
            audio: [],
            netdev: nil,
            restore: []
        ).argv[2]
    }

    @Test func strategiesOwnTheirRequiredInputs() throws {
        let kernel = Self.machine(.kernel(image: "kernel", writableNOR: nil))
        let iboot = Self.machine(.iBoot(image: "iboot", writableNOR: "nor", gidBlobs: "keys"))
        let rom = Self.machine(.secureROM(image: "rom", writableNOR: "nor", gidBlobs: "keys", developmentFuses: false))
        #expect(kernel.contains("kboot=kernel") && !kernel.contains("iboot="))
        #expect(iboot.contains("iboot=iboot") && iboot.contains("gid-blobs=keys") && !iboot.contains("kboot="))
        #expect(rom.contains("bootrom=rom") && rom.contains("development-fuses=off") && !rom.contains("iboot="))
        for strategy in ["iboot", "bootrom"] {
            #expect(throws: (any Error).self, "\(strategy) without its NOR") {
                _ = try BootRecipe.preparedIPadBoot(
                    strategy: strategy,
                    image: "image",
                    writableNOR: nil,
                    gidBlobs: "keys"
                )
            }
            #expect(throws: (any Error).self, "\(strategy) without its keys") {
                _ = try BootRecipe.preparedIPadBoot(
                    strategy: strategy,
                    image: "image",
                    writableNOR: "nor",
                    gidBlobs: nil
                )
            }
        }
        #expect(throws: (any Error).self, "an unknown strategy") {
            _ = try BootRecipe.preparedIPadBoot(strategy: "typo", image: "image", writableNOR: nil, gidBlobs: nil)
        }
        #expect(
            try BootRecipe.preparedIPadBoot(strategy: nil, image: "image", writableNOR: nil, gidBlobs: "stray keys")
                == .kernel(image: "image", writableNOR: nil),
            "a legacy lock defaults to kernel, independent of keys"
        )
    }

    @Test func aUnitsIdentityProvisionsItsMachineOptions() throws {
        try withTemporaryDirectory { dir in
            let lock = dir.appendingPathComponent("device.lock.json")
            let identity = dir.appendingPathComponent("identity.json")
            func writeLock(_ board: String, _ machine: [String: String]) throws {
                try JSONSerialization.data(withJSONObject: ["board": board, "machine": machine]).write(to: lock)
            }
            func writeIdentity(_ values: [String: String]) throws {
                try JSONSerialization.data(withJSONObject: values).write(to: identity)
            }
            func options() throws -> [String: String] {
                try #require(try DeviceLock.read(lock)).machineOptions(base: dir)
            }

            try writeIdentity(["wifi-mac": "02:11:22:33:44:66", "bt-mac": "02:11:22:33:44:67"])
            try writeLock("n72ap", ["aes-uid": "engine"])
            #expect(
                try options() == ["aes-uid": "engine", "wifi-mac": "02:11:22:33:44:66", "bt-mac": "02:11:22:33:44:67"],
                "an existing N72 unit provisions its card from its identity"
            )
            try writeLock("n72ap", ["wifi-mac": "02:11:22:33:44:88"])
            #expect(try options()["wifi-mac"] == "02:11:22:33:44:88", "explicit card provisioning wins")
            try writeIdentity(["seed": "ipad1-7B500-default"])
            try writeLock("n72ap", [:])
            #expect(try options()["ecid"] == "0x6bb6bf76e7", "a legacy unit's ECID comes from the frozen seed identity")
            try writeIdentity(["seed": "ipad1-7B500-default", "unique-chip-id": "0xa86437a9d7"])
            #expect(try options()["ecid"] == "0xa86437a9d7", "a stored unit ECID wins over the seed")
            try writeLock("n72ap", ["ecid": "0x123"])
            #expect(try options()["ecid"] == "0x123", "an explicit board ECID wins")
            let pod = BootRecipe.iPod(
                .init(
                    bootArgs: "",
                    iBoot: "",
                    bootrom: "rom",
                    nand: "nand",
                    nor: "nor",
                    writableNOR: "rw",
                    overlay: "overlay",
                    usbAddress: nil,
                    wifi: false,
                    machineOptions: try options()
                ),
                hardware: Self.info("iPod-Touch", "n72ap"),
                serial: "null",
                audio: [],
                netdev: nil,
                restore: []
            )
            #expect(pod.argv[2].contains(",ecid=0x123"), "the unit ECID reaches the boot argv")
            try writeLock("k48ap", [:])
            #expect(try options().isEmpty, "K48 takes no N72 ECID option")
            try writeIdentity([
                "wifi-mac": "02:11:22:33:44:66", "bt-mac": "02:11:22:33:44:67", "unique-chip-id": "0x234"
            ])
            #expect(try options() == ["wifi-mac": "02:11:22:33:44:66"], "an existing K48 unit provisions its card")
            try writeLock("k48ap", ["wifi-mac": "02:11:22:33:44:88"])
            #expect(try options()["wifi-mac"] == "02:11:22:33:44:88", "explicit K48 card provisioning wins")
            try writeLock("n45ap", [:])
            #expect(try options().isEmpty, "other boards acquire no card option")
            try writeLock("n72ap", [:])
            try FileManager.default.removeItem(at: identity)
            #expect(try options().isEmpty, "a legacy N72 with no identity keeps the default")
        }
    }

    @Test func onlyFiveXRunsSetupOffline() {
        for v in ["5.0", "5.0.1", "5.1", "5.1.1"] {
            #expect(BootRecipe.setupPhonesHome(iosVersion: v), "\(v) boots restricted")
        }
        for v in ["3.2", "3.2.2", "4.2.1", "4.3", "4.3.5", "3.1.3"] {
            #expect(!BootRecipe.setupPhonesHome(iosVersion: v), "\(v) boots unrestricted")
        }
    }

    @Test func theWifiNetdevBothWaysAndWhatTheHelperReadsFromIt() {
        let fwd = ",guestfwd=tcp:10.0.2.100:3128-unix-connect:/tmp/p.sock"
        #expect(
            BootRecipe.wifiNetdev(guestForward: fwd, restricted: false) == "user,id=wifi0" + fwd + ",lan=off",
            "the default refuses the LAN"
        )
        #expect(
            BootRecipe.wifiNetdev(guestForward: fwd, restricted: false, localNetwork: true) == "user,id=wifi0" + fwd
        )
        let r = BootRecipe.wifiNetdev(guestForward: fwd, restricted: true, localNetwork: true)
        #expect(r.hasPrefix("user,id=wifi0" + fwd) && r.hasSuffix(",restrict=on"), "\(r)")
        func argv(_ netdev: String?) -> BootConfig {
            BootConfig(
                argv: ["LightTouchMac", "-M", "ipad1"] + (netdev.map { ["-netdev", $0] } ?? []),
                machine: "ipad1"
            )
        }
        #expect(argv(r).wifiRestricted)
        #expect(!argv(BootRecipe.wifiNetdev(guestForward: fwd, restricted: false)).wifiRestricted)
        #expect(!argv(nil).wifiRestricted)
        #expect(
            !argv(BootRecipe.wifiNetdev(guestForward: fwd, restricted: true)).wifiLocalNetwork,
            "lan=off: the proxy refuses the LAN too"
        )
        #expect(argv(BootRecipe.wifiNetdev(guestForward: fwd, restricted: false, localNetwork: true)).wifiLocalNetwork)
        #expect(
            !argv("user,id=wifi0,guestfwd=tcp:10.0.2.100:3128-unix-connect:/tmp/restrict=on").wifiRestricted,
            "a path containing restrict=on"
        )
    }

    /// An iPhone's cell0 follows wifi0's lan=, and with no wifi0 given (networking off) still starts off the LAN.
    @Test func anIPhonesCell0StaysOffTheLANLikeWifi0() {
        let fwd = ",guestfwd=tcp:10.0.2.100:3128-unix-connect:/tmp/p.sock"
        let m68 = DeviceInfo(
            machine: "iphone2g",
            board: "m68ap",
            screenWidth: 320,
            screenHeight: 480,
            screenScale: 1,
            defaultOrientation: 0,
            hasCellular: true,
            hasUSBHost: false,
            hasCompass: false,
            panelMin: 0,
            panelMaxWidth: 0,
            panelMaxHeight: 0,
            panelWidthStep: 0,
            panelMaxPixels: 0
        )
        let phone = BootRecipe.IPod1G(bootrom: "b", iBoot: "i", nand: "n", writableNOR: "w", overlay: "o")
        func cell(_ netdev: String?) -> String? {
            let a = BootRecipe.iPod1G(phone, hardware: m68, serial: "null", audio: [], netdev: netdev).argv
            return zip(a, a.dropFirst()).first { $0 == "-netdev" && $1.hasPrefix("user,id=cell0") }?.1
        }
        #expect(cell(nil) == "user,id=cell0,lan=off", "cell0 without wifi0 reaches the LAN")
        #expect(cell(BootRecipe.wifiNetdev(guestForward: fwd, restricted: false)) == "user,id=cell0" + fwd + ",lan=off")
        #expect(
            cell(BootRecipe.wifiNetdev(guestForward: fwd, restricted: false, localNetwork: true)) == "user,id=cell0"
                + fwd
        )
    }

    typealias Poll = (String?, String?)
    static let springBoard = "com.apple.springboard", purpleBuddy = "com.apple.purplebuddy"
    func lifts(_ seq: [Poll]) -> Int? {
        var gate = BootRecipe.SetupNetworkGate()
        for (i, p) in seq.enumerated() where gate.observe(bundleID: p.0, name: p.1) { return i }
        return nil
    }

    @Test func theSetupGateLiftsOnlyPastSetupAndTheLockScreen() throws {
        let springBoard = Self.springBoard
        let purpleBuddy = Self.purpleBuddy
        let fresh: [Poll] = [
            (nil, nil), (nil, nil), (springBoard, "Lock Screen"), (springBoard, "Lock Screen"),
            (springBoard, "Lock Screen"),
            (purpleBuddy, "Setup"), (purpleBuddy, "Setup"), (purpleBuddy, "Setup"), (springBoard, "Home Screen"),
            (springBoard, "Home Screen")
        ]
        #expect(lifts(fresh) == 9, "a fresh 5.x lifts at the second Home poll")
        #expect(lifts(Array(repeating: (springBoard, "Lock Screen"), count: 20)) == nil, "never on the lock screen")
        #expect(lifts(Array(repeating: (purpleBuddy, "Setup"), count: 20)) == nil, "never during Setup")
        #expect(
            lifts([
                (springBoard, "Lock Screen"), (springBoard, "Home Screen"), (purpleBuddy, "Setup"),
                (purpleBuddy, "Setup")
            ]) == nil,
            "one stray unlocked poll"
        )
        #expect(
            lifts([(purpleBuddy, "Setup"), (springBoard, "Home Screen"), (nil, nil), (springBoard, "Home Screen")])
                == nil,
            "a failed poll breaks the streak"
        )
        let reused: [Poll] = [
            (springBoard, "Lock Screen"), (springBoard, "Lock Screen"), ("com.apple.mobilesafari", "Safari"),
            ("com.apple.mobilesafari", "Safari")
        ]
        #expect(lifts(reused) == 3, "a device past Setup with no mark lifts at its first unlocked screen")
        var once = BootRecipe.SetupNetworkGate()
        _ = once.observe(bundleID: springBoard, name: "Home Screen")
        let first = once.observe(bundleID: springBoard, name: "Home Screen")
        let again = once.observe(bundleID: springBoard, name: "Home Screen")
        #expect(first && !again && once.lifted, "answers true once")

        // Recorded by the net-restrict-live gate (9B206), one "bundle\tname" per poll.
        let text = try String(
            contentsOf: repositoryRoot.appendingPathComponent("tests/fixtures/frontmost-9B206-setup.tsv"),
            encoding: .utf8
        )
        let seq: [Poll] = text.split(separator: "\n").map {
            let f = $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return (f[0].isEmpty ? nil : f[0], f.count > 1 && !f[1].isEmpty ? f[1] : nil)
        }
        let firstHome = try #require(seq.firstIndex { $0.0 == springBoard && $0.1 == "Home Screen" })
        let lastSetup = try #require(seq.lastIndex { $0.0 == purpleBuddy })
        let at = try #require(lifts(seq))
        #expect(
            at > lastSetup && at == firstHome + 1,
            "recorded: lifted at \(at), last Setup \(lastSetup), first Home \(firstHome)"
        )
    }

    @Test func theSetupMarkIsADotFileInTheOverlayAndTheLiftCrossesTheWire() throws {
        try withTemporaryDirectory { overlay in
            let mark = BootRecipe.setupDoneMark(overlay: overlay)
            #expect(
                mark.deletingLastPathComponent().resolvingSymlinksInPath().path
                    == overlay.resolvingSymlinksInPath().path
            )
            #expect(mark.lastPathComponent.hasPrefix("."), "pinOverlay reads the overlay's contents")
        }
        let data = try JSONEncoder().encode(AppMessage.command(.netRestrict(false)))
        guard case .command(.netRestrict(let on)) = try JSONDecoder().decode(AppMessage.self, from: data) else {
            Issue.record("netRestrict didn't round-trip")
            return
        }
        #expect(on == false)
    }
}
