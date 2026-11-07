import Darwin
import FirmwareSchema
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// PreparationJob: the preparer's JSON Lines and messages, then runs against tests/fixtures/fake-firmwarekit
/// (publish, errors, cancel, the atomic publish), the removal guard, Delete Device and the launch sweeps.
@Suite(.serialized) struct PreparationJobTests {
    let fm = FileManager.default
    static let catalog = try! FirmwareCatalog.load(from: LibraryFixtures.shippedCatalog)
    var iPad32: FirmwareCatalog.Entry { Self.catalog.entry(id: "k48ap-7B367")! }
    init() { _ = LibraryFixtures.isolatedAppState }

    @Test func jsonLines() {
        typealias L = PreparationJob.Line
        #expect(L(#"{"event":"begin","steps":9}"#) == .begin(steps: 9))
        #expect(L(#"{"event":"begin","steps":2,"seconds":[1.5,70]}"#) == .begin(steps: 2, seconds: [1.5, 70]))
        #expect(
            L(#"{"event":"step","index":3,"name":"Building the system volume"}"#)
                == .step(index: 3, name: "Building the system volume")
        )
        #expect(L(#"{"event":"progress","fraction":0.42}"#) == .progress(0.42))
        #expect(
            L(#"{"event":"progress","fraction":0.5,"detail":"Starting iOS — 42 s"}"#)
                == .progress(0.5, detail: "Starting iOS — 42 s")
        )
        #expect(L(#"{"event":"warning","message":"slow disk"}"#) == .warning("slow disk"))
        #expect(L(#"{"event":"done","lock":"device.lock.json"}"#) == .done(lock: "device.lock.json"))
        #expect(
            L(#"{"event":"error","code":"activation_failed","message":"exit 2"}"#)
                == .error(code: "activation_failed", message: "exit 2")
        )
        for junk in [
            "", "not json", #"{"event":"step"}"#, #"{"event":"begin","steps":"x"}"#, #"{"event":"new"}"#, "[1]"
        ] {
            #expect(L(junk) == nil, "\(junk)")
        }
        // A required piece that doesn't fit (5.0 beta 1's OpenGLES front end in RC1): what, in plain words.
        #expect(
            L(
                #"{"event":"error","code":"unsupported","message":"OpenGLES front end (contrib/gles-public) does not fit this firmware: x","piece":"OpenGLES front end (contrib/gles-public)"}"#
            )
                == .error(
                    code: "unsupported",
                    message: "OpenGLES front end (contrib/gles-public) does not fit this firmware: x",
                    piece: "OpenGLES front end (contrib/gles-public)"
                )
        )
    }

    @Test func messages() throws {
        #expect(
            PreparationJob.message(code: "disk_full", detail: "") == "Not enough disk space to prepare this device."
        )
        // Under the placeholder's "Couldn’t prepare", the reason is said once, as a sentence.
        #expect(
            PreparationJob.message(code: "internal", detail: "guest helper it_agent missing from /x")
                == "Guest helper it_agent missing from /x."
        )
        #expect(PreparationJob.message(code: "internal", detail: "Boom!") == "Boom!")
        #expect(PreparationJob.message(code: "whatever", detail: "") == "No reason was given.")
        #expect(
            PreparationJob.message(
                code: "unsupported",
                detail: "OpenGLES front end (contrib/gles-public) does not fit this firmware: x",
                piece: "OpenGLES front end (contrib/gles-public)",
                beta: true
            )
                == "Light Touch can’t prepare this beta yet: its graphics library isn’t supported."
        )
        for (piece, words) in [
            ("kernelcache at the path iBoot loads", "the way it starts up isn’t supported"),
            ("boot-arg rd", "the way it starts up isn’t supported"),
            ("libappsync.dylib (in installd)", "installing apps on it isn’t supported"),
            ("iPhone OS 1.x boot chain", "only iPhone OS 1 runs on this device"),
            ("it_boot (guest-package loader)", "the guest tools don’t run on it"),
            (
                "HFSPlusWriter",
                "its disk images have to be mounted to prepare it (turn off Prepare devices without mounting disk images in Settings ▸ General)"
            )
        ] {
            #expect(
                PreparationJob.message(code: "unsupported", detail: "", piece: piece)
                    == "Light Touch can’t prepare this version yet: \(words)."
            )
        }
        #expect(
            PreparationJob.message(code: "unsupported", detail: "not a zip archive") == "This IPSW isn’t supported."
        )
        let lock = try JSONDecoder().decode(
            DeviceLock.self,
            from: Data(#"{"identity":{"seed":"s","udid":"u2","die_id":"0x3:0x4"}}"#.utf8)
        )
        #expect(
            PreparationJob.identity(
                identityJSON: Data(#"{"udid":"u1","die-id":["0x1","0x2"]}"#.utf8),
                lock: lock,
                seed: "x"
            )
                == .init(seed: "s", udid: "u1", dieID: "0x1:0x2")
        )
        #expect(
            PreparationJob.identity(identityJSON: nil, lock: lock, seed: "x")
                == .init(seed: "s", udid: "u2", dieID: "0x3:0x4")
        )
    }

    /// Collects a job's events until its last one.
    nonisolated final class Run: @unchecked Sendable {  // lock-protected
        private let lock = NSLock()
        private var events: [PreparationJob.Event] = []
        private var done: CheckedContinuation<Void, Never>?
        private var finished = false
        var job: PreparationJob!
        var cancelAfterStep: Int?
        func receive(_ event: PreparationJob.Event) {
            let resume: CheckedContinuation<Void, Never>? = lock.withLock {
                events.append(event)
                if case .step(let index, _, _) = event, index == cancelAfterStep { job.cancel() }
                switch event {
                case .published, .failed, .cancelled:
                    finished = true
                    defer { done = nil }
                    return done
                default: return nil
                }
            }
            resume?.resume()
        }
        func wait() async -> [PreparationJob.Event] {
            await withCheckedContinuation { c in
                let now = lock.withLock {
                    finished
                        ? true
                        : {
                            done = c
                            return false
                        }()
                }
                if now { c.resume() }
            }
            return lock.withLock { events }
        }
    }

    struct Fixture {
        let tmp: URL, state: URL, cache: URL, argv: URL
        init(_ tmp: URL) throws {
            self.tmp = tmp
            state = tmp.appendingPathComponent("PState")
            cache = tmp.appendingPathComponent("PCache/Decrypted")
            argv = tmp.appendingPathComponent("argv.json")
            try StorageLocations.privateDirectory(state)
        }
        var preparing: URL { PreparationJob.preparing(state) }
        var leftovers: [String] { (try? FileManager.default.contentsOfDirectory(atPath: preparing.path)) ?? [] }
        var devices: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: state.appendingPathComponent("Devices").path)) ?? []
        }

        func prepare(
            _ entry: FirmwareCatalog.Entry,
            mode: String,
            state: URL? = nil,
            ipsw: URL? = nil,
            cancelAfterStep: Int? = nil
        ) async throws -> (events: [PreparationJob.Event], job: PreparationJob) {
            let preparer = try LibraryFixtures.fakePreparer(in: tmp, mode: mode, argv: argv)
            let run = Run()
            run.cancelAfterStep = cancelAfterStep
            let job = PreparationJob(
                .init(
                    entry: entry,
                    ipsw: ipsw ?? tmp.appendingPathComponent("fake.ipsw"),
                    state: state ?? self.state,
                    preparer: preparer,
                    helper: URL(fileURLWithPath: "/nonexistent/LightTouchDevice"),
                    cache: cache,
                    log: tmp.appendingPathComponent("logs/\(entry.id).log")
                )
            ) { run.receive($0) }
            run.job = job
            let started = Date()
            job.start()
            let events = await run.wait()
            if cancelAfterStep != nil { #expect(Date().timeIntervalSince(started) < 5, "the cancel took too long") }
            return (events, job)
        }
    }

    func allocatedKiB(_ url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize! / 1024
    }

    @Test func publishesFailsAndCancelsAgainstTheFakePreparer() async throws {
        try await LibraryFixtures.withScratch { tmp in
            let f = try Fixture(tmp)
            let state = f.state
            let cache = f.cache
            var run = try await f.prepare(iPad32, mode: "ok")
            guard case .published(let device)? = run.events.last else {
                Issue.record("not published: \(run.events)")
                return
            }
            #expect(
                run.events.contains(.step(1, of: 3, name: "Decrypting"))
                    && run.events.contains(.step(3, of: 3, name: "Finishing setup"))
            )
            // begin's seconds first; per step a monotonic fraction with a detail, ending at 1.
            #expect(run.events.first == .begin(seconds: [5, 10, 70]))
            var sealing: [Double] = []
            var inSeal = false
            for event in run.events {
                if case .step(let index, _, _) = event { inSeal = index == 3 }
                if inSeal, case .progress(let fraction, let detail) = event {
                    #expect(detail?.hasPrefix("Starting iOS — ") == true)
                    sealing.append(fraction)
                }
            }
            #expect(sealing == [0, 0.25, 0.5, 0.75, 1])
            let argv = try JSONSerialization.jsonObject(with: Data(contentsOf: f.argv)) as! [String]
            func flag(_ name: String) -> String? { argv.firstIndex(of: name).map { argv[$0 + 1] } }
            #expect(!argv.contains("--activation-hook") && flag("--helper") == "/nonexistent/LightTouchDevice")
            #expect(flag("--cache") == cache.path && flag("--seed") == device.id.uuidString && flag("--out") != nil)
            let directory = DeviceInstance.directory(device.id, state: state)
            let base = directory.appendingPathComponent("base")
            let lockData = try Data(contentsOf: base.appendingPathComponent("device.lock.json"))
            let lockJSON = try JSONSerialization.jsonObject(with: lockData) as! [String: Any]
            #expect(DeviceInstance.all(state: state) == [device], "the record is on disk")
            #expect(
                device.base == .init(kind: .prepared, path: "Devices/\(device.id.uuidString)/base")
                    && device.firmware == iPad32.id
                    && device.board == "k48ap" && device.storage.writableNOR == nil
            )
            #expect(
                device.identity
                    == .init(
                        seed: device.id.uuidString,
                        udid: (lockJSON["identity"] as? [String: Any])?["udid"] as? String,
                        dieID: "0x00000123:0x00000456"
                    )
            )
            #expect(device.provenance?.sha256 == PreparationJob.sha256(lockData))
            let nand = base.appendingPathComponent("nand/store")
            #expect(
                try allocatedKiB(nand) < 1024 && (fm.attributesOfItem(atPath: nand.path)[.size] as! Int) == 1 << 30,
                "the NAND stays sparse"
            )
            #expect(f.leftovers.isEmpty, "Preparing/ is empty after a publish")
            #expect(
                fm.fileExists(atPath: cache.appendingPathComponent("decrypted-v2/\(iPad32.source.sha1!)").path),
                "the decrypt cache stays"
            )
            let listing = try fm.subpathsOfDirectory(atPath: directory.path).sorted()
            let record = try Data(contentsOf: directory.appendingPathComponent(DeviceInstance.recordName))

            // A writable-NOR recipe publishes its nor.bin; an iPod base has iBoot.bin, nor.bin and gid-blobs.bin, no kboot.bin.
            run = try await f.prepare(Self.catalog.entry(id: "k48ap-8C148")!, mode: "ok")
            guard case .published(let device4)? = run.events.last else {
                Issue.record("8C148: \(run.events)")
                return
            }
            #expect(
                device4.storage.writableNOR == "Devices/\(device4.id.uuidString)/nor.bin"
                    && fm.fileExists(
                        atPath: DeviceInstance.directory(device4.id, state: state).appendingPathComponent(
                            "base/nor.bin"
                        ).path
                    )
            )
            run = try await f.prepare(Self.catalog.entry(id: "n72ap-8C148")!, mode: "ok")
            guard case .published(let pod)? = run.events.last else {
                Issue.record("n72ap-8C148: \(run.events)")
                return
            }
            #expect(
                pod.board == "n72ap" && pod.storage.writableNOR == "Devices/\(pod.id.uuidString)/nor.bin"
                    && !fm.fileExists(
                        atPath: DeviceInstance.directory(pod.id, state: state).appendingPathComponent("base/kboot.bin")
                            .path
                    )
            )

            // Failures: nothing published, nothing left in Preparing/; the decrypt cache kept for coordinated maintenance.
            let before = Set(f.devices)
            let sha1 = iPad32.source.sha1!
            try StorageLocations.privateDirectory(cache.appendingPathComponent("\(sha1).tmp"))
            run = try await f.prepare(iPad32, mode: "error")
            #expect(run.events.last == .failed("Light Touch doesn’t have the keys for this firmware."))
            #expect(
                fm.fileExists(atPath: cache.appendingPathComponent("\(sha1).tmp").path)
                    && fm.fileExists(atPath: cache.appendingPathComponent("decrypted-v2/\(sha1)").path)
            )
            let ipsw = tmp.appendingPathComponent("fake.ipsw")  // an IPSW failing its SHA in the preparer is deleted
            try Data("ipsw".utf8).write(to: ipsw)
            run = try await f.prepare(iPad32, mode: "sha")
            #expect(
                run.events.last == .failed("This IPSW doesn’t match the one Light Touch knows.")
                    && !fm.fileExists(atPath: ipsw.path)
            )
            run = try await f.prepare(iPad32, mode: "crash")
            #expect(run.events.last == .failed("Preparation stopped unexpectedly."))
            run = try await f.prepare(iPad32, mode: "incomplete")
            #expect(
                run.events.last
                    == .failed(
                        "Couldn’t save the prepared device: The prepared device is incomplete (device.lock.json is missing)."
                    )
            )
            #expect(Set(f.devices) == before && f.leftovers.isEmpty)

            // Cancel: SIGTERM mid-way (a read-only nand/ in staging), staging removed, nothing published or touched.
            run = try await f.prepare(iPad32, mode: "slow", cancelAfterStep: 2)
            #expect(run.events.last == .cancelled)
            #expect(!fm.fileExists(atPath: run.job.staging.path) && f.leftovers.isEmpty)
            #expect(Set(f.devices) == before)
            #expect(
                try fm.subpathsOfDirectory(atPath: directory.path).sorted() == listing
                    && Data(contentsOf: directory.appendingPathComponent(DeviceInstance.recordName)) == record,
                "the published device is untouched by later failures and cancels"
            )

            // Publish is one rename: when it can't happen (Devices/ is a file), nothing appears and Preparing/ is empty.
            let blocked = tmp.appendingPathComponent("BlockedState")
            try StorageLocations.privateDirectory(blocked)
            try Data().write(to: blocked.appendingPathComponent("Devices"))
            run = try await f.prepare(iPad32, mode: "ok", state: blocked)
            #expect({ if case .failed? = run.events.last { true } else { false } }())
            #expect(
                ((try? fm.contentsOfDirectory(atPath: PreparationJob.preparing(blocked).path)) ?? []).isEmpty,
                "a failed publish leaves no .publish"
            )

            // A preparer that can't start leaves nothing.
            let missing = Run()
            let job = PreparationJob(
                .init(
                    entry: iPad32,
                    ipsw: ipsw,
                    state: state,
                    preparer: URL(fileURLWithPath: "/nonexistent/firmwarekit"),
                    helper: ipsw,
                    cache: cache,
                    log: tmp.appendingPathComponent("logs/x.log")
                )
            ) { missing.receive($0) }
            missing.job = job
            job.start()
            guard case .failed? = await missing.wait().last else {
                Issue.record("a missing preparer did not fail")
                return
            }
            #expect(f.leftovers.isEmpty)

            try removalAndSweeps(f, device: device, other: device4)
        }
    }

    /// Erase and Delete stay inside the device's own storage; Delete Device goes through .deleting-<uuid> with its
    /// read-only base; the launch sweeps finish torn deletes and Preparing/ leftovers.
    func removalAndSweeps(_ f: Fixture, device: DeviceInstance, other device4: DeviceInstance) throws {
        let state = f.state
        let otherDevice = DeviceInstance.directory(device4.id, state: state)
        let mine = DeviceInstance.directory(device.id, state: state)
        let outside = f.tmp.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: outside)
        try fm.createSymbolicLink(at: mine.appendingPathComponent("escape"), withDestinationURL: outside)
        for (path, why) in [
            (state, "the state root"), (state.appendingPathComponent("Devices"), "Devices/"),
            (otherDevice, "another record"), (otherDevice.appendingPathComponent("overlay"), "inside another record"),
            (outside, "outside the state root"), (state.appendingPathComponent("Devices/../../outside"), "a .. escape"),
            (mine.appendingPathComponent("escape"), "a symlink out")
        ] {
            #expect(throws: (any Error).self, "\(why) was removable") {
                try DeviceStateStorage.checkRemovable(path, state: state, owner: device.id)
            }
        }
        try DeviceStateStorage.checkRemovable(mine.appendingPathComponent("overlay"), state: state, owner: device.id)
        try DeviceStateStorage.checkRemovable(
            state.appendingPathComponent("nandrw-legacy"),
            state: state,
            owner: device.id
        )
        #expect(throws: (any Error).self, "erase reached another record") {
            try DeviceStateStorage.erase(
                overlay: otherDevice,
                snapshots: [mine.appendingPathComponent("snapshot")],
                state: state,
                owner: device.id
            )
        }
        #expect(
            fm.fileExists(atPath: otherDevice.appendingPathComponent(DeviceInstance.recordName).path)
                && fm.fileExists(atPath: outside.path)
        )
        try fm.removeItem(at: mine.appendingPathComponent("escape"))

        #expect(
            !fm.isWritableFile(atPath: mine.appendingPathComponent("base/nand").path),
            "the published base/nand is read-only"
        )
        try DeviceStateStorage.removeDevice(device.id, state: state)
        #expect(!fm.fileExists(atPath: mine.path) && !f.devices.contains { $0.hasPrefix(".deleting-") })
        #expect(
            !DeviceInstance.all(state: state).contains(device) && DeviceInstance.all(state: state).contains(device4)
        )
        // A delete interrupted after its rename: never listed, even with a valid record; finished by the launch sweep.
        let tornID = UUID()
        let torn = state.appendingPathComponent("Devices/.deleting-\(tornID.uuidString)")
        try fm.createDirectory(at: torn.appendingPathComponent("base/nand"), withIntermediateDirectories: true)
        let ghost = String(decoding: try DeviceInstance.encoder.encode(device4), as: UTF8.self)
            .replacingOccurrences(of: device4.id.uuidString, with: tornID.uuidString)
        try Data(ghost.utf8).write(to: torn.appendingPathComponent(DeviceInstance.recordName))
        chmod(torn.appendingPathComponent("base/nand").path, 0o555)
        #expect(!DeviceInstance.all(state: state).contains { $0.id == tornID })
        DeviceStateStorage.sweepDeleting(state: state)
        #expect(!fm.fileExists(atPath: torn.path))
        // A device recorded before device.plist: listed from its device.json, converted once, the JSON gone.
        let old = DeviceInstance.directory(device4.id, state: state)
        let json = JSONEncoder()
        json.dateEncodingStrategy = .iso8601
        try fm.removeItem(at: old.appendingPathComponent(DeviceInstance.recordName))
        try json.encode(device4).write(to: old.appendingPathComponent("device.json"))
        #expect(DeviceInstance.all(state: state).contains(device4))
        #expect(
            fm.fileExists(atPath: old.appendingPathComponent("device.plist").path)
                && !fm.fileExists(atPath: old.appendingPathComponent("device.json").path)
        )
        // Preparing/ leftovers, read-only ones and a torn .publish included.
        let stale = f.preparing.appendingPathComponent("\(UUID().uuidString)/nand")
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: f.preparing.appendingPathComponent("\(UUID().uuidString).publish/base"),
            withIntermediateDirectories: true
        )
        chmod(stale.path, 0o555)
        PreparationJob.sweep(state: state, preparer: nil)
        #expect(f.leftovers.isEmpty)
    }
}
