import Foundation
import HostRuntime
import Testing

struct DeviceLockTests {
    /// What FirmwareKit wrote with JSONSerialization comes back byte for byte through DeviceLock, members it doesn't
    /// name included (qemu-ios's Python reads the same file).
    @Test func roundTripKeepsTheFormat() throws {
        let record: [String: Any] = [
            "format": 1, "board": "n90ap", "build": "8A293", "product_type": "iPhone3,1", "product_version": "4.0",
            "boot_strategy": "kboot", "machine": ["imei": "000000008926131", "rtc-epoch": "1293840000"],
            "identity": ["die_id": "0x9346762c:0x3d3225e5", "seed": "4EF6C1AA", "udid": "748c"],
            "entry": [
                "id": "n90ap-8A293", "sha256": "ab",
                "content": [
                    "board": "n90ap", "recipe": ["version": 2, "storage": "16g"],
                    "keys": ["iBSS": "a", "iBEC": "b", "iBoot": "c", "kernelcache": "d"]
                ]
            ],
            "inputs": [
                "ipsw": ["path": "/a/b c/iPhone.ipsw", "sha1": "00"], "activation": NSNull(), "lockdown": NSNull()
            ],
            "guest_package": ["family": "k48-ios4", "gles": true, "seed": 7, "hooks": ["/usr/lib/libappsync.dylib"]],
            "outputs": ["nand": ["listing_sha256": "cd", "pages": 12_345_678_901]], "gid_components": NSNull(),
            "fit": ["ratio": 0.5, "warnings": [] as [Any], "ok": false], "created": "2026-10-06T22:07:58Z"
        ]
        let written = try JSONSerialization.data(
            withJSONObject: record,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let lock = try JSONDecoder().decode(DeviceLock.self, from: written)
        #expect(try lock.data() == written)
        #expect(try DeviceLock(json: record).data() == written)
        #expect(lock.recipeVersion == 2 && lock.entryID == "n90ap-8A293" && lock.entryBoard == "n90ap")
        #expect(lock.pinsClock && !lock.activated && lock.bootStrategy == "kboot")
        #expect(
            lock.machineOptions(base: URL(fileURLWithPath: "/nonexistent")) == [
                "imei": "000000008926131", "rtc-epoch": "1293840000"
            ]
        )
    }

    /// The recipe's options say how the base was prepared: Skip Setup boots to the Home screen, so the app doesn't wait
    /// for Setup on it.
    @Test func recipeOptions() throws {
        func lock(_ options: [String: Any]) throws -> DeviceLock {
            try DeviceLock(json: ["entry": ["content": ["recipe": ["version": 2, "options": options]]]])
        }
        #expect(try lock(["skip_setup": true]).skippedSetup)
        #expect(try !lock(["skip_setup": false]).skippedSetup)
        #expect(try !lock([:]).skippedSetup)
        #expect(try lock(["jailbreak": true]).jailbroken && !lock(["jailbreak": true]).skippedSetup)
        #expect(try !lock([:]).jailbroken)
        // Jailbroken since it was prepared (a stopped edit's generation lock)
        #expect(
            try DeviceLock(json: ["jailbroken": true, "entry": ["content": ["recipe": ["version": 2]]]]).jailbroken
        )
    }

    /// Decoded once while the file is unchanged; a rewrite is read again.
    @Test func readIsCachedUntilTheFileChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(DeviceLock.fileName)
        #expect(try DeviceLock.read(url) == nil)
        try Data(#"{"board": "n72ap"}"#.utf8).write(to: url)
        #expect(try DeviceLock.read(url)?.board == "n72ap")
        try Data(#"{"board": "k48ap", "boot_strategy": "iboot"}"#.utf8).write(to: url, options: .atomic)
        #expect(try DeviceLock.read(url)?.bootStrategy == "iboot")
        try Data(#"{"board": "k48ap", "boot_strategy": null}"#.utf8).write(to: url, options: .atomic)
        #expect(throws: CocoaError.self) { _ = try DeviceLock.read(url) }
    }
}
