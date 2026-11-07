import Darwin
import FirmwareSchema
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// The old layout is erased once (its IPAs kept in the library, off the main actor), and a prepared base publishes
/// as an ordinary device; also the shipped catalog's shape. Every state directory is temporary; the IPA library is
/// the test process's isolated one.
@Suite struct LegacyStateTests {
    let fm = FileManager.default
    static let catalog = try! FirmwareCatalog.load(from: LibraryFixtures.shippedCatalog)
    var entry: FirmwareCatalog.Entry { Self.catalog.entry(id: "n72ap-7E18")! }
    init() { _ = LibraryFixtures.isolatedAppState }

    @Test func catalogShape() throws {
        let json =
            try JSONSerialization.jsonObject(with: Data(contentsOf: LibraryFixtures.shippedCatalog)) as! [String: Any]
        let entries = json["entries"] as! [[String: Any]]
        #expect(entries.allSatisfy { $0["bundled"] == nil }, "no entry ships prepared")
        let first = try #require(entries.first { $0["id"] as? String == json["first_run"] as? String })
        #expect(
            first["status"] as? String == "available"
                && ((first["source"] as! [String: Any])["url"] as! String).hasPrefix(
                    "https://secure-appldnld.apple.com/"
                ),
            "first run: an available build from Apple"
        )
        func hex(_ s: Any?, _ n: Int) -> Bool {
            (s as? String).map { $0.count == n && $0.allSatisfy(\.isHexDigit) && $0 == $0.lowercased() } ?? false
        }
        for e in entries {
            let id = e["id"] as! String
            let source = e["source"] as! [String: Any]
            let kind = source["kind"] as? String
            #expect(id == "\(e["board"]!)-\(e["build"]!)" && (kind == "ipsw" || kind == "rar"), "\(id)")
            if kind == "rar" {  // a beta's archive.org RAR: the archive's own hash and size, and the IPSW member
                #expect(
                    hex(source["archive_sha1"], 40) && (source["archive_bytes"] as? Int ?? 0) > 0
                        && (source["member"] as? String)?.hasSuffix(".ipsw") == true,
                    "\(id)"
                )
            }
            #expect(hex(source["sha1"], 40) && (source["bytes"] as? Int ?? 0) > 0, "\(id)")
            #expect(
                e["status"] as? String == "user_ipsw" || (source["url"] as? String)?.hasPrefix("https://") == true,
                "\(id)"
            )
            #expect(e["activation_hook"] == nil && source["resource"] == nil, "\(id)")
        }
    }

    /// A small base in the shape firmwarekit's n72 recipe makes.
    func base(_ root: URL) throws -> URL {
        let base = root.appendingPathComponent("base")
        try fm.createDirectory(at: base.appendingPathComponent("nand/cs0"), withIntermediateDirectories: true)
        try Data(repeating: 0xff, count: 4160).write(to: base.appendingPathComponent("nand/cs0/1.page"))
        for name in ["iBoot.bin", "gid-blobs.bin"] {
            try Data("boot".utf8).write(to: base.appendingPathComponent(name))
        }
        try Data(count: 1_048_576).write(to: base.appendingPathComponent("nor.bin"))
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: base.appendingPathComponent("nor.bin").path)
        let udid = String(repeating: "a", count: 40)
        try JSONSerialization.data(withJSONObject: ["udid": udid, "seed": "fixture"]).write(
            to: base.appendingPathComponent("identity.json")
        )
        try fm.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: base.appendingPathComponent("identity.json").path
        )
        try JSONSerialization.data(withJSONObject: [
            "format": 1, "entry": ["id": "n72ap-7E18"], "machine": ["aes-uid": "engine"],
            "identity": ["udid": udid, "seed": "fixture"],
            "inputs": ["activation": ["input_sha256": "0", "output_sha256": "0"]]
        ]).write(to: base.appendingPathComponent("device.lock.json"))
        return base
    }

    /// A preparation's last step: its output copied into Preparing/<id>/, published.
    func publishPrepared(_ base: URL, state: URL) throws -> DeviceInstance {
        try PreparationJob.publish(copyOf: base, entry: entry, state: state)
    }
    func mode(_ url: URL) throws -> Int {
        try (fm.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }

    @Test func malformedLocksRefuseBeforePublication() async throws {
        try await LibraryFixtures.withScratch { root in
            let base = try base(root)
            let state = root.appendingPathComponent("state")
            for json in [
                "{", "[]", #"{"boot_strategy":null}"#, #"{"boot_strategy":17}"#, #"{"boot_strategy":false}"#,
                #"{"boot_strategy":[]}"#, #"{"boot_strategy":{}}"#
            ] {
                let id = UUID()
                let staging = PreparationJob.preparing(state).appendingPathComponent(id.uuidString)
                try StorageLocations.privateDirectory(staging.deletingLastPathComponent())
                try fm.copyItem(at: base, to: staging)
                let lock = staging.appendingPathComponent("device.lock.json")
                try Data(json.utf8).write(to: lock)
                let error = #expect(throws: CocoaError.self, "\(json)") {
                    try PreparationJob.publish(staging: staging, entry: entry, id: id, state: state)
                }
                #expect(error?.code == .fileReadCorruptFile, "\(json)")
                #expect(try Data(contentsOf: lock) == Data(json.utf8), "the staging lock stays intact")
                #expect(fm.fileExists(atPath: staging.appendingPathComponent("nand").path), "staging not moved")
                #expect(!fm.fileExists(atPath: DeviceInstance.directory(id, state: state).path), "no record published")
                try fm.removeItem(at: staging)
            }
        }
    }

    /// `sessions single --managed`'s device: a copy published as a preparation is, its record one boot admission's
    /// managed policy owns, the base left as it was; format 1 over a page store, 2 over an image store.
    @Test func aCopyOfABasePublishesAsADeviceAndLeavesTheBase() async throws {
        try await LibraryFixtures.withScratch { root in
            let state = root.appendingPathComponent("state")
            let base = try base(root)
            let tree = { (url: URL) in
                (fm.subpaths(atPath: url.path) ?? []).sorted().map {
                    "\($0) \(fm.contents(atPath: url.appendingPathComponent($0).path)?.count ?? -1)"
                }
            }
            let before = tree(base)
            for imageStore in [false, true] {
                if imageStore {
                    try JSONSerialization.data(withJSONObject: ["storage_format": "nand-xor-blank-v2"])
                        .write(to: base.appendingPathComponent("nand/geometry.json"))
                }
                let instance = try PreparationJob.publish(copyOf: base, entry: entry, state: state)
                let device = DeviceInstance.directory(instance.id, state: state)
                #expect(try DeviceInstance.read(device) == instance)
                #expect(instance.format == (imageStore ? DeviceRecord.imageFormat : 1))
                #expect(instance.base.path == "Devices/\(instance.id.uuidString)/base")
                let paths = instance.paths(state: state, logs: root)
                #expect(tree(paths.base) == tree(base), "the device's base is the base's copy")
                let record = try StorageRecordPaths(
                    bytes: Data(contentsOf: DeviceRecord.url(device)),
                    relativeRoot: state
                )
                try record.validate(.managedDeviceDirectory(device), device: device)
                if !imageStore { #expect(tree(base) == before, "the base is where it was, unchanged") }
            }
            #expect(fm.subpaths(atPath: PreparationJob.preparing(state).path)?.isEmpty ?? true, "no staging left")
        }
    }

    @Test func aPreparedBasePublishesAsADevice() async throws {
        try await LibraryFixtures.withScratch { root in
            let state = root.appendingPathComponent("state")
            let logs = root.appendingPathComponent("logs")
            #expect(LegacyState.find(state: state, applicationSupport: nil) == nil, "a fresh state has nothing legacy")
            #expect(DeviceInstance.all(state: state).isEmpty)
            let instance = try publishPrepared(try base(root), state: state)
            let id = instance.id.uuidString
            #expect(
                DeviceInstance.all(state: state) == [instance] && instance.firmware == entry.id
                    && instance.board == "n72ap"
            )
            #expect(instance.base.kind == .prepared && instance.base.path == "Devices/\(id)/base")
            #expect(
                instance.storage.writableNOR == "Devices/\(id)/nor.bin"
                    && instance.storage.usbmuxConf == "Devices/\(id)/usbmuxd-conf"
            )
            #expect(
                instance.identity?.udid != nil && instance.provenance?.sha256 != nil
                    && instance.storage.key.count == 16,
                "identity and provenance from the lock"
            )
            let paths = instance.paths(state: state, logs: logs)
            let boot = try Board.n72.requiredFiles(strategy: DeviceLock.read(base: paths.base)?.bootStrategy)
            let files = try BootRecipe.preparedFiles(
                base: paths.base,
                overlay: paths.overlay,
                writableNOR: paths.writableNOR,
                boot: boot.boot,
                also: boot.files
            )
            #expect(
                files.boot.lastPathComponent == "iBoot.bin"
                    && fm.fileExists(atPath: files.nand.appendingPathComponent("cs0/1.page").path)
            )
            let nor = try #require(files.writableNOR)
            #expect(try fm.fileExists(atPath: nor.path) && mode(nor) & 0o200 != 0, "a writable NOR clone on first boot")
            #expect(
                try mode(paths.base.appendingPathComponent("identity.json")) == 0o600
                    && mode(paths.base.appendingPathComponent("nor.bin")) == 0o444
            )
            #expect(
                try DeviceStateStorage.pinOverlay(paths.overlay, toBase: instance.storage.key),
                "the overlay is pinned to the base"
            )
            #expect(
                (try? fm.removeItem(at: paths.base.appendingPathComponent("gid-blobs.bin"))) == nil,
                "the base is locked"
            )
            #expect((try? fm.contentsOfDirectory(atPath: PreparationJob.preparing(state).path))?.isEmpty == true)
            #expect(DeviceInstance.lockLacksActivation(paths.base.appendingPathComponent("device.lock.json")) == false)
            // A library of prepared devices has nothing to erase.
            #expect(LegacyState.find(state: state, applicationSupport: root.appendingPathComponent("nowhere")) == nil)
        }
    }

    // MARK: - The old layout

    /// Ticks on the main actor every 10 ms and keeps the longest gap: `worst` in wall time and `worstBusy` in the
    /// main thread's own CPU time. A main actor held by work burns CPU through its gap; one the host just didn't
    /// schedule burns none, so `worstBusy` is the verdict.
    @MainActor final class Heartbeat {
        var beats = 0, worst = 0.0, worstBusy = 0.0
        var onBeat: () -> Void = {}
        private var task: Task<Void, Never>?
        private var last = Date(), lastBusy = 0.0
        private func busy() -> Double {
            var t = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
            return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
        }
        private func gap() {
            let now = Date()
            let nowBusy = busy()
            worst = max(worst, now.timeIntervalSince(last))
            worstBusy = max(worstBusy, nowBusy - lastBusy)
            last = now
            lastBusy = nowBusy
        }
        func start() {
            last = Date()
            lastBusy = busy()
            task = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                    gap()
                    beats += 1
                    onBeat()
                }
            }
        }
        /// The gap up to now counts too: work that held the main actor until the awaited call returned never lets a tick in.
        func stop() {
            gap()
            task?.cancel()
        }
    }

    /// The 1.0 root and a multidevice state with an adopted (legacyBundled) iPod. `big`: a 160 MB retained IPA and
    /// 24,000 old pages (about 260 MB), so the erase takes a while. Bundle IDs carry `tag` (the IPA library is shared).
    nonisolated static func oldLayout(support: URL, state: URL, tag: String, big: Bool) throws -> UUID {
        let fm = FileManager.default
        func put(_ data: Data, _ path: String, in root: URL) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let old = support.appendingPathComponent("LightTouchMac")
        try put(Data("old ipa \(tag)".utf8), "IPAs/com.example.\(tag).old.ipa", in: old)
        try put(Data("paired".utf8), "work/usbmuxd-conf/device.plist", in: old)
        let digest = String(repeating: "b", count: 64)
        let page = Data(repeating: 0xff, count: 4160)
        try put(page, "device/nand-ultimate-\(digest)/cs0/0.page", in: state)
        try put(
            JSONSerialization.data(withJSONObject: [
                "key": "nand-ultimate-\(digest)", "directory": "device/nand-ultimate-\(digest)"
            ]),
            "device/active-nand-ultimate.json",
            in: state
        )
        try put(Data(count: 16), "nandrw-nand-ultimate/nor.bin", in: state)
        try put(Data("ram".utf8), "snapshot-nand-ultimate", in: state)
        try put(Data("shared ipa \(tag)".utf8), "IPAs/com.example.\(tag).shared.ipa", in: state)
        try fm.createDirectory(at: state.appendingPathComponent("AppCache"), withIntermediateDirectories: true)
        try put(Data("events".utf8), "app.log", in: state)
        try put(Data("1\n".utf8), "work/usbmuxd.pid", in: state)
        try put(Data("SOCK=x\n".utf8), "work/session.env", in: state)
        try put(Data("paired".utf8), "work/usbmuxd-conf/device.plist", in: state)
        try put(Data("host".utf8), "work/usbmuxd-conf/SystemConfiguration.plist", in: state)
        try put(Data("{}".utf8), "Library/IPAs/index.json", in: state)
        let record = UUID()
        try put(
            big ? LibraryFixtures.randomData(160 << 20) : Data("retained \(tag)".utf8),
            "Devices/\(record.uuidString)/IPAs/com.example.\(tag).retained.ipa",
            in: state
        )
        if big {
            for (tree, count) in [("device/nand-ultimate-\(digest)", 18000), ("nandrw-nand-ultimate", 6000)] {
                for i in 0..<count { try put(page, "\(tree)/cs\(i % 4)/\(i + 1).page", in: state) }
            }
        }
        try put(
            JSONSerialization.data(withJSONObject: [
                "format": 1, "id": record.uuidString, "name": "iPod touch", "board": "n72ap", "firmware": "n72ap-7E18",
                "created": "2026-09-01T00:00:00Z",
                "base": ["kind": "legacyBundled", "path": "device/nand-ultimate-\(digest)"],
                "storage": [
                    "key": "nand-ultimate", "overlay": "nandrw-nand-ultimate",
                    "writableNOR": "nandrw-nand-ultimate/nor.bin",
                    "snapshot": "snapshot-nand-ultimate", "usbmuxConf": "work/usbmuxd-conf"
                ],
                "legacy": ["filesRoot": "/x", "nand": "nand-ultimate", "pointer": "device/active-nand-ultimate.json"]
            ]),
            "Devices/\(record.uuidString)/device.json",
            in: state
        )
        return record
    }

    /// Erase and Continue: the IPAs into the library and everything else of the old layout gone, the old root with its
    /// pairing included, off the main actor; then nothing legacy is left and a device published afterwards is the only one.
    @Test @MainActor func theOldLayoutIsErasedOnceAndItsIPAsKept() async throws {
        try #require(
            IPALibrary.directory.path.hasPrefix(LibraryFixtures.isolatedAppState.path),
            "the IPA library isn't this test process's isolated one; not adopting test IPAs into it"
        )
        try await LibraryFixtures.withScratch { root in
            let support = root.appendingPathComponent("Library/Application Support")
            let state = support.appendingPathComponent("gold.samhenri.LightTouchMac")
            let tag = String(UUID().uuidString.prefix(8)).lowercased()
            _ = try await Task.detached { try Self.oldLayout(support: support, state: state, tag: tag, big: true) }
                .value

            let legacy = try #require(LegacyState.find(state: state, applicationSupport: support))
            #expect(!legacy.resuming, "a first run asks")
            #expect(legacy.records.count == 1 && legacy.oldRoot != nil, "the legacy record and the old root are found")
            let names = Set(legacy.items.map(\.lastPathComponent))
            #expect(
                names.isSuperset(of: [
                    "device", "nandrw-nand-ultimate", "snapshot-nand-ultimate", "IPAs", "app.log", "usbmuxd.pid",
                    "session.env", "AppCache"
                ])
            )
            #expect(
                names.isDisjoint(with: ["Library", "Devices", "work", ".app-lock"]),
                "the library and the devices stay: \(names)"
            )
            #expect(DeviceInstance.all(state: state).isEmpty, "the legacy record does not decode as a device")

            // Hundreds of MB go without holding the main actor; midway (the shared IPA adopted, the big one hashing)
            // the marker is down and the old trees are still there.
            let heart = Heartbeat()
            var midway = false
            heart.onBeat = {
                guard !midway, heart.beats >= 20,
                    IPALibrary.index.values.contains(where: { $0.bundleID == "com.example.\(tag).shared" })
                else { return }
                midway = true
                #expect(
                    fm.fileExists(atPath: LegacyState.marker(state).path)
                        && fm.fileExists(atPath: state.appendingPathComponent("device").path),
                    "marked, and not done yet"
                )
            }
            heart.start()
            let started = Date()
            try await legacy.erase()
            heart.stop()
            let took = Date().timeIntervalSince(started)
            #expect(midway, "the erase finished before the shared IPA was adopted and 20 beats passed")
            #expect(
                took > 0.5 && heart.worstBusy < 1 && heart.beats > 20,
                "the main actor kept running: worst gap \(heart.worstBusy) s of main-thread CPU (\(heart.worst) s wall) over \(took) s, \(heart.beats) beats"
            )

            #expect(!fm.fileExists(atPath: LegacyState.marker(state).path), "the marker goes with the erase")
            for name in [
                "device", "nandrw-nand-ultimate", "snapshot-nand-ultimate", "IPAs", "app.log", "AppCache",
                "work/usbmuxd.pid", "work/session.env"
            ] {
                #expect(!fm.fileExists(atPath: state.appendingPathComponent(name).path), "\(name) erased")
            }
            #expect(!fm.fileExists(atPath: support.appendingPathComponent("LightTouchMac").path), "the old root erased")
            #expect(
                (try? fm.contentsOfDirectory(atPath: state.appendingPathComponent("Devices").path))?.isEmpty == true,
                "the legacy record's directory erased"
            )
            let kept = Set(IPALibrary.index.values.map(\.bundleID))
            #expect(
                kept.isSuperset(of: ["retained", "shared", "old"].map { "com.example.\(tag).\($0)" }),
                "every retained IPA is in the library"
            )
            #expect(
                fm.fileExists(atPath: IPALibrary.directory.appendingPathComponent("index.plist").path),
                "the library index"
            )
            #expect(
                LegacyState.find(state: state, applicationSupport: support) == nil,
                "erased once: nothing legacy left"
            )

            // A quit after the last removal but before the marker went: the next launch finishes quietly.
            fm.createFile(atPath: LegacyState.marker(state).path, contents: nil)
            let leftover = LegacyState.find(state: state, applicationSupport: support)
            #expect(leftover?.resuming == true && leftover?.items.isEmpty == true, "a lone marker resumes")
            try await leftover?.erase()
            #expect(LegacyState.find(state: state, applicationSupport: support) == nil, "and then nothing is left")
            let instance = try publishPrepared(try base(root), state: state)
            #expect(
                DeviceInstance.all(state: state).map(\.id) == [instance.id],
                "one device: the one prepared after the erase"
            )
        }
    }

    /// A launch after an erase the app quit midway (the marker down, the old trees still here) carries on without asking.
    @Test @MainActor func anEraseQuitMidwayResumesWithoutAsking() async throws {
        try #require(
            IPALibrary.directory.path.hasPrefix(LibraryFixtures.isolatedAppState.path),
            "the IPA library isn't this test process's isolated one; not adopting test IPAs into it"
        )
        try await LibraryFixtures.withScratch { root in
            let support = root.appendingPathComponent("Library/Application Support")
            let state = support.appendingPathComponent("gold.samhenri.LightTouchMac")
            let tag = String(UUID().uuidString.prefix(8)).lowercased()
            let record = try Self.oldLayout(support: support, state: state, tag: tag, big: false)
            // How far the quit got: the shared IPA adopted and the record gone; the old trees and the old root still here.
            await IPALibrary.adopt(copies: state.appendingPathComponent("IPAs"))
            try DeviceStateStorage.removeDevice(record, state: state)
            fm.createFile(atPath: LegacyState.marker(state).path, contents: nil)

            let legacy = try #require(LegacyState.find(state: state, applicationSupport: support))
            #expect(legacy.resuming, "the launch after the quit resumes without asking")
            #expect(
                legacy.oldRoot != nil && legacy.items.contains { $0.lastPathComponent == "device" },
                "what the quit left is found"
            )
            try await legacy.erase()
            #expect(LegacyState.find(state: state, applicationSupport: support) == nil)
            #expect(
                !fm.fileExists(atPath: state.appendingPathComponent("device").path)
                    && !fm.fileExists(atPath: support.appendingPathComponent("LightTouchMac").path)
            )
            #expect(
                Set(IPALibrary.index.values.map(\.bundleID)).isSuperset(
                    of: ["shared", "old"].map { "com.example.\(tag).\($0)" }
                )
            )
        }
    }

    /// An erase that fails takes its marker down: the next launch asks again, where it resumed without asking, failed
    /// the same way and quit, at every launch.
    @Test func aFailedEraseAsksAgainAtTheNextLaunch() async throws {
        try await LibraryFixtures.withScratch { root in
            let state = root.appendingPathComponent("state")
            let outside = root.appendingPathComponent("outside")
            try fm.createDirectory(at: state, withIntermediateDirectories: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            // Not the state's to remove: the erase refuses it.
            try fm.createSymbolicLink(at: state.appendingPathComponent("device"), withDestinationURL: outside)
            let legacy = try #require(LegacyState.find(state: state, applicationSupport: nil))
            #expect(!legacy.resuming)
            await #expect(throws: (any Error).self) { try await legacy.erase() }
            #expect(fm.fileExists(atPath: outside.path))
            #expect(LegacyState.find(state: state, applicationSupport: nil)?.resuming == false)
        }
    }

    /// An IPA the library can't take (here unreadable) stops the erase before anything goes: the alert promised
    /// the saved apps survive.
    @Test func anIPAThatCantBeKeptErasesNothing() async throws {
        try #require(
            IPALibrary.directory.path.hasPrefix(LibraryFixtures.isolatedAppState.path),
            "the IPA library isn't this test process's isolated one; not adopting test IPAs into it"
        )
        try await LibraryFixtures.withScratch { root in
            let state = root.appendingPathComponent("state")
            let ipas = state.appendingPathComponent("IPAs")
            try fm.createDirectory(at: ipas, withIntermediateDirectories: true)
            try fm.createDirectory(at: state.appendingPathComponent("device"), withIntermediateDirectories: true)
            let ipa = ipas.appendingPathComponent("com.example.\(UUID().uuidString.prefix(8)).unreadable.ipa")
            try Data(UUID().uuidString.utf8).write(to: ipa)
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: ipa.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ipa.path) }
            let legacy = try #require(LegacyState.find(state: state, applicationSupport: nil))
            let error = await #expect(throws: CocoaError.self) { try await legacy.erase() }
            #expect(error?.userInfo[NSFilePathErrorKey] as? String == ipa.path, "the alert can show the IPA")
            #expect(fm.fileExists(atPath: ipa.path), "the IPA stays")
            #expect(fm.fileExists(atPath: state.appendingPathComponent("device").path), "nothing else goes either")
            #expect(LegacyState.find(state: state, applicationSupport: nil)?.resuming == false)
        }
    }
}
