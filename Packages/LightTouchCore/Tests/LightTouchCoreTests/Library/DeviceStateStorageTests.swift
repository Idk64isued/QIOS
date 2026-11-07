import Darwin
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// Overlay pinning, the writable NOR, erase, the stopped-device lease and the managed boot-path authority
/// (DeviceStateStorage with DeviceInstance's paths). No helper, guest or real state.
struct DeviceStateStorageTests {
    let fm = FileManager.default

    @Test func overlayIsPinnedToItsBase() throws {
        try withTemporaryDirectory { root in
            // Adopted when empty, kept for its base, refused for another base and for an unstamped overlay with pages.
            let overlay = root.appendingPathComponent("nandrw-pin")
            #expect(try DeviceStateStorage.pinOverlay(overlay, toBase: "base-a"))
            try Data([1]).write(to: overlay.appendingPathComponent("bus0-ce0.pages"))
            #expect(try DeviceStateStorage.pinOverlay(overlay, toBase: "base-a"))
            #expect(try !DeviceStateStorage.pinOverlay(overlay, toBase: "base-b"))
            try fm.removeItem(at: overlay.appendingPathComponent(".base-identity"))
            #expect(try !DeviceStateStorage.pinOverlay(overlay, toBase: "base-a"))
        }
    }

    @Test func writableNORIsAPrivateCompleteCopy() throws {
        try withTemporaryDirectory { root in
            let base = root.appendingPathComponent("base-nor")
            let overlay = root.appendingPathComponent("nor-overlay")
            try Data(repeating: 0xff, count: 1_048_576).write(to: base)
            let writable = try DeviceStateStorage.writableNOR(base: base, overlay: overlay)
            var changed = try Data(contentsOf: writable)
            changed[0] = 0x12
            try changed.write(to: writable)
            // An existing copy is kept, not re-cloned; the base never changes.
            #expect(try DeviceStateStorage.writableNOR(base: base, overlay: overlay) == writable)
            #expect(try Data(contentsOf: writable)[0] == 0x12 && Data(contentsOf: base)[0] == 0xff)
            // A corrupt copy is refused rather than replaced; a short base is refused and leaves nothing.
            try Data([0]).write(to: writable)
            #expect(throws: (any Error).self) { try DeviceStateStorage.writableNOR(base: base, overlay: overlay) }
            try fm.removeItem(at: overlay)
            try Data([0]).write(to: base)
            #expect(throws: (any Error).self) { try DeviceStateStorage.writableNOR(base: base, overlay: overlay) }
            #expect(try fm.contentsOfDirectory(atPath: overlay.path).isEmpty)
        }
    }

    @Test func eraseRemovesTheOverlayAndSnapshotsButNotTheBase() throws {
        try withTemporaryDirectory { root in
            let device = root.appendingPathComponent("erase-device")
            let overlay = device.appendingPathComponent("nandrw")
            let snapshot = device.appendingPathComponent("snapshot")
            try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
            for url in [overlay.appendingPathComponent("nor.bin"), snapshot, snapshot.appendingPathExtension("meta")] {
                try Data("device".utf8).write(to: url)
            }
            let base = device.appendingPathComponent("base-image")
            try Data("base".utf8).write(to: base)
            try DeviceStateStorage.erase(overlay: overlay, snapshots: [snapshot], state: root, owner: nil)
            #expect(
                !fm.fileExists(atPath: overlay.path) && !fm.fileExists(atPath: snapshot.path)
                    && !fm.fileExists(atPath: snapshot.appendingPathExtension("meta").path)
            )
            #expect(try String(contentsOf: base, encoding: .utf8) == "base")
            // idempotent
            try DeviceStateStorage.erase(overlay: overlay, snapshots: [snapshot], state: root, owner: nil)
        }
    }

    /// The private NOR goes under the erase's own lease (state audit A-9), checked with the overlay before anything is
    /// removed: one that isn't this device's storage leaves the overlay too.
    @Test func eraseRemovesThePrivateNORUnderItsLeaseOrNothing() throws {
        try withTemporaryDirectory { state in
            let id = UUID()
            let device = state.appendingPathComponent("Devices/\(id.uuidString)")
            let overlay = device.appendingPathComponent("overlay")
            let nor = device.appendingPathComponent("nor.bin")
            try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
            try Data("pages".utf8).write(to: overlay.appendingPathComponent("pages"))
            try Data("nvram".utf8).write(to: nor)
            let outside = state.deletingLastPathComponent().appendingPathComponent("nor-\(id.uuidString).bin")
            try Data("not the device's".utf8).write(to: outside)
            defer { try? fm.removeItem(at: outside) }
            #expect(throws: CocoaError.self) {
                try DeviceStateStorage.erase(
                    overlay: overlay,
                    snapshots: [],
                    preparedNOR: outside,
                    state: state,
                    owner: id
                )
            }
            #expect(fm.fileExists(atPath: overlay.path) && fm.fileExists(atPath: outside.path), "nothing removed")
            try DeviceStateStorage.erase(overlay: overlay, snapshots: [], preparedNOR: nor, state: state, owner: id)
            #expect(!fm.fileExists(atPath: overlay.path) && !fm.fileExists(atPath: nor.path))
        }
    }

    /// Erase is atomic (state audit B-8): the overlay is renamed aside before anything in it goes, so one whose removal
    /// fails part way (here a page that can't be unlinked; a crash does the same) is already gone from its path, never
    /// half there with its base identity removed; the launch sweep finishes it.
    @Test func eraseRenamesTheOverlayAsideFirstAndTheLaunchSweepFinishesIt() throws {
        try withTemporaryDirectory { state in
            let id = UUID()
            let device = state.appendingPathComponent("Devices/\(id.uuidString)")
            let overlay = device.appendingPathComponent("overlay")
            try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
            try Data("base-a".utf8).write(to: overlay.appendingPathComponent(".base-identity"))
            let page = overlay.appendingPathComponent("bus0-ce0.pages")
            try Data([1]).write(to: page)
            #expect(chflags(page.path, UInt32(UF_IMMUTABLE)) == 0)
            let doomed = device.appendingPathComponent(".erasing-overlay")
            defer { chflags(doomed.appendingPathComponent("bus0-ce0.pages").path, 0) }
            try DeviceStateStorage.erase(overlay: overlay, snapshots: [], state: state, owner: id)
            #expect(!fm.fileExists(atPath: overlay.path), "the device boots erased")
            #expect(fm.fileExists(atPath: doomed.path), "the stuck page waits for the sweep")
            chflags(doomed.appendingPathComponent("bus0-ce0.pages").path, 0)
            DeviceStateStorage.sweepDeleting(state: state)
            #expect(!fm.fileExists(atPath: doomed.path) && fm.fileExists(atPath: device.path))
        }
    }

    /// Erase after saved file system edits (Save Changes, then Jailbreak…) returns the device to how it was prepared:
    /// the record selects Devices/<uuid>/base and fresh storage again, the generations and the storage the first edit
    /// left (the old overlay, NOR and saved state) are gone, and the record's own fields stay. The generations are laid
    /// out as StorageGeneration publishes them (StoppedVolumeEditTests checks original-device.plist on a real commit).
    @Test func eraseAfterSavedEditsReturnsToThePreparedBase() throws {
        try withTemporaryDirectory { state in
            let id = UUID()
            let device = DeviceInstance.directory(id, state: state)
            let relative = "Devices/\(id.uuidString)"
            func lock(_ jailbroken: Bool) -> Data { Data(#"{"jailbroken": \#(jailbroken)}"#.utf8) }
            func make(_ dir: String, files: [String: Data]) throws {
                let url = device.appendingPathComponent(dir)
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                for (name, data) in files { try data.write(to: url.appendingPathComponent(name)) }
            }
            // Prepared, then used: the overlay and NOR hold the user's data.
            try make("work", files: [:])
            try make("base", files: ["device.lock.json": lock(false), "nand": Data("prepared".utf8)])
            try make("overlay", files: ["app.page": Data("installed app".utf8)])
            try make("overlay/nand", files: ["bus0-ce0.pages": Data("live".utf8)])  // an image store's live NAND
            try Data("nvram".utf8).write(to: device.appendingPathComponent("nor.bin"))
            try Data("state".utf8).write(to: device.appendingPathComponent("snapshot"))
            var instance = DeviceInstance(
                id: id,
                name: "iPhone 4",
                board: "n90ap",
                firmware: "n90ap-8C148",
                created: DeviceInstance.now,
                base: .init(kind: .prepared, path: "\(relative)/base"),
                storage: .init(
                    key: "prepared-key",
                    overlay: "\(relative)/overlay",
                    writableNOR: "\(relative)/nor.bin",
                    snapshot: "\(relative)/snapshot",
                    usbmuxConf: "\(relative)/usbmuxd-conf"
                ),
                provenance: .init(lock: "\(relative)/base/device.lock.json", sha256: "prepared")
            )
            try instance.write(state: state)
            let prepared = instance
            // Two saved edits: a file added to the data volume, then a jailbreak. Each generation keeps the record it
            // replaced and holds its own base (with the edited volumes), overlay and NOR.
            for (generation, jailbroken) in [(UUID(), false), (UUID(), true)] {
                let g = "generations/\(generation.uuidString)"
                try make(g, files: [:])
                try fm.copyItem(
                    at: device.appendingPathComponent(DeviceInstance.recordName),
                    to: device.appendingPathComponent("\(g)/original-\(DeviceInstance.recordName)")
                )
                try make("\(g)/base", files: ["device.lock.json": lock(jailbroken), "nand": Data("edited".utf8)])
                try make("\(g)/overlay", files: ["app.page": Data("used since".utf8)])
                try Data("nvram".utf8).write(to: device.appendingPathComponent("\(g)/nor.bin"))
                instance.base.path = "\(relative)/\(g)/base"
                instance.storage.key = generation.uuidString
                instance.storage.overlay = "\(relative)/\(g)/overlay"
                instance.storage.writableNOR = "\(relative)/\(g)/nor.bin"
                instance.storage.snapshot = "\(relative)/\(g)/snapshot"
                instance.provenance = .init(lock: "\(relative)/\(g)/base/device.lock.json", sha256: "edited")
                instance.format = 2  // the edit laid out an image store (StoppedVolumeEdit)
                try instance.write(state: state)
            }
            instance.name = "Renamed"
            try instance.write(state: state)

            func erase(_ instance: DeviceInstance) throws {
                let paths = instance.paths(state: state, logs: state)
                try DeviceErase.Targets(
                    overlay: paths.overlay,
                    snapshots: [paths.snapshot],
                    preparedNOR: paths.writableNOR,
                    state: state,
                    owner: id
                ).remove()
            }
            try erase(instance)

            let erased = try DeviceInstance.read(device)
            var expected = prepared
            expected.name = "Renamed"
            #expect(erased == expected)
            let paths = erased.paths(state: state, logs: state)
            #expect(try Data(contentsOf: paths.base.appendingPathComponent("nand")) == Data("prepared".utf8))
            #expect(try DeviceLock.read(base: paths.base)?.jailbroken == false)
            for gone in [paths.overlay, paths.snapshot, device.appendingPathComponent("nor.bin")] {
                #expect(!fm.fileExists(atPath: gone.path), "\(gone.lastPathComponent)")
            }
            #expect(try fm.contentsOfDirectory(atPath: device.path).sorted() == ["base", "device.plist", "work"])
            // Erase again: nothing more to do.
            try erase(erased)
            #expect(try DeviceInstance.read(device) == expected)
        }
    }

    /// Erase and Delete Device refuse a device another process holds (its work/lease) or with a durable filesystem
    /// edit (work/edit.json), and change nothing.
    @Test func eraseAndDeleteRefuseAnExternalLeaseAndAPendingEdit() throws {
        try withTemporaryDirectory { state in
            let id = UUID()
            let device = state.appendingPathComponent("Devices/\(id.uuidString)")
            let work = device.appendingPathComponent("work")
            let overlay = device.appendingPathComponent("overlay")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
            let marker = overlay.appendingPathComponent("keep")
            try Data("unchanged".utf8).write(to: marker)
            try Data("<plist><dict/></plist>".utf8).write(to: device.appendingPathComponent("device.plist"))
            func refused() {
                #expect(throws: CocoaError.self) {
                    try DeviceStateStorage.erase(overlay: overlay, snapshots: [], state: state, owner: id)
                }
                #expect(throws: CocoaError.self) { try DeviceStateStorage.removeDevice(id, state: state) }
                #expect((try? Data(contentsOf: marker)) == Data("unchanged".utf8))
            }
            let owner = open(work.appendingPathComponent("lease").path, O_RDWR | O_CREAT, 0o600)
            #expect(owner >= 0 && flock(owner, LOCK_EX | LOCK_NB) == 0)
            refused()
            close(owner)
            try Data("{}".utf8).write(to: work.appendingPathComponent("edit.json"))
            refused()
        }
    }

    // MARK: - Managed boot paths

    /// A record under `state`, laid out like a published device; `own` is its directory.
    struct Library {
        let root: URL, state: URL, logs: URL, owner: UUID, other: UUID
        let ordinary: DeviceInstance, otherRecord: DeviceInstance, own: URL, external: URL, originalRecord: Data

        init(_ root: URL) throws {
            let fm = FileManager.default
            self.root = root
            state = root.appendingPathComponent("state")
            logs = root.appendingPathComponent("logs")
            owner = UUID()
            other = UUID()
            func record(_ id: UUID) -> DeviceInstance {
                let prefix = "Devices/\(id.uuidString)"
                return DeviceInstance(
                    id: id,
                    name: "fixture",
                    board: "n72ap",
                    firmware: "n72ap-7E18",
                    created: DeviceInstance.now,
                    base: .init(kind: .prepared, path: prefix + "/base"),
                    storage: .init(
                        key: "fixture",
                        overlay: prefix + "/overlay",
                        writableNOR: prefix + "/nor.bin",
                        snapshot: prefix + "/snapshot",
                        usbmuxConf: prefix + "/usbmuxd-conf"
                    )
                )
            }
            ordinary = record(owner)
            otherRecord = record(other)
            try ordinary.write(state: state)
            try otherRecord.write(state: state)
            own = ordinary.paths(state: state, logs: logs).directory
            try fm.createDirectory(at: own.appendingPathComponent("base"), withIntermediateDirectories: true)
            try Data("base-sentinel".utf8).write(to: own.appendingPathComponent("base/sentinel"))
            external = root.appendingPathComponent("external-base")
            try fm.createDirectory(at: external, withIntermediateDirectories: true)
            try Data("external-sentinel".utf8).write(to: external.appendingPathComponent("sentinel"))
            originalRecord = try Data(contentsOf: own.appendingPathComponent(DeviceInstance.recordName))
        }

        func validate(_ i: DeviceInstance, in selected: URL? = nil) throws {
            let selected = selected ?? state
            let p = i.paths(state: selected, logs: logs)
            try DeviceStateStorage.checkBootPaths(
                base: p.base,
                mutable: [
                    p.overlay, p.snapshot, p.snapshotMeta, p.snapshotTmp, p.snapshotBad, p.usbmuxConf, p.work, p.lease
                ]
                    + [p.writableNOR].compactMap { $0 },
                state: selected,
                owner: i.id
            )
        }

        /// Refused, read-only: no lease or work directory, private NOR or overlay made; record, base and external untouched.
        func refused(_ label: Comment, _ i: DeviceInstance) throws {
            let fm = FileManager.default
            #expect(throws: CocoaError.self, label) { try validate(i) }
            for name in ["work", "overlay", "nor.bin"] {
                #expect(!fm.fileExists(atPath: own.appendingPathComponent(name).path), label)
            }
            #expect(
                try Data(contentsOf: own.appendingPathComponent(DeviceInstance.recordName)) == originalRecord,
                label
            )
            #expect(
                try String(contentsOf: own.appendingPathComponent("base/sentinel"), encoding: .utf8) == "base-sentinel",
                label
            )
            #expect(
                try String(contentsOf: external.appendingPathComponent("sentinel"), encoding: .utf8)
                    == "external-sentinel",
                label
            )
        }
    }

    @Test func supportedLayoutsAreAccepted() throws {
        try withTemporaryDirectory { root in
            let lib = try Library(root)
            let own = lib.own
            let ordinary = lib.ordinary
            let state = lib.state
            try lib.validate(ordinary)
            var development = ordinary
            development.base.path = lib.external.path  // an external read-only base
            try lib.validate(development)
            var absolute = ordinary
            absolute.storage.overlay = own.appendingPathComponent("overlay").path
            absolute.storage.writableNOR = own.appendingPathComponent("nor.bin").path
            absolute.storage.snapshot = own.appendingPathComponent("snapshot").path
            absolute.storage.usbmuxConf = own.appendingPathComponent("usbmuxd-conf").path
            try lib.validate(absolute)
            // StorageGeneration records: relative or absolute generation descendants.
            var generation = ordinary
            let relative = "Devices/\(lib.owner.uuidString)/generations/\(UUID().uuidString)"
            generation.base.path = relative + "/base"
            generation.storage.overlay = relative + "/overlay"
            generation.storage.writableNOR = relative + "/nor.bin"
            generation.storage.snapshot = relative + "/snapshot"
            try lib.validate(generation)
            generation.base.path = DeviceInstance.url(generation.base.path, state: state).path
            generation.storage.overlay = DeviceInstance.url(generation.storage.overlay, state: state).path
            generation.storage.writableNOR = DeviceInstance.url(generation.storage.writableNOR!, state: state).path
            generation.storage.snapshot = DeviceInstance.url(generation.storage.snapshot, state: state).path
            try lib.validate(generation)
            // The state root through a link, and a moved copy of it.
            let alias = root.appendingPathComponent("state-link")
            try fm.createSymbolicLink(at: alias, withDestinationURL: state)
            try lib.validate(ordinary, in: alias)
            let moved = root.appendingPathComponent("moved-state")
            try fm.copyItem(at: state, to: moved)
            try lib.validate(ordinary, in: moved)
            // A resolvable alias inside owned storage: no blanket symlink ban.
            let privateStorage = own.appendingPathComponent("private")
            try fm.createDirectory(at: privateStorage, withIntermediateDirectories: true)
            let privateLink = own.appendingPathComponent("private-link")
            try fm.createSymbolicLink(at: privateLink, withDestinationURL: privateStorage)
            var linked = ordinary
            linked.storage.overlay = privateLink.appendingPathComponent("pages").path
            try lib.validate(linked)
        }
    }

    @Test func escapingAndSharedPathsAreRefusedWithoutMutation() throws {
        try withTemporaryDirectory { root in
            let lib = try Library(root)
            let own = lib.own
            let ordinary = lib.ordinary
            let owner = lib.owner
            var bad = ordinary
            bad.storage.overlay = "../outside-overlay"
            try lib.refused("relative escape", bad)
            bad = ordinary
            bad.storage.writableNOR = root.appendingPathComponent("outside-nor").path
            try lib.refused("external mutable NOR", bad)
            bad = ordinary
            bad.storage.overlay = lib.otherRecord.storage.overlay
            try lib.refused("other-record/shared overlay", bad)
            bad = ordinary
            bad.storage.snapshot = "Devices/\(owner.uuidString)"
            try lib.refused("whole record as snapshot", bad)
            bad = ordinary
            bad.storage.overlay = "Devices/\(owner.uuidString)/base/overlay"
            try lib.refused("mutable under base", bad)
            bad = ordinary
            bad.base.path = ordinary.storage.overlay + "/nested-base"
            try lib.refused("base under mutable", bad)
            try fm.createSymbolicLink(at: own.appendingPathComponent("escape-link"), withDestinationURL: lib.external)
            bad = ordinary
            bad.storage.overlay = "Devices/\(owner.uuidString)/escape-link/not-yet-created"
            try lib.refused("existing link with missing suffix", bad)
            bad = ordinary
            bad.storage.overlay = "Devices/\(owner.uuidString)/escape-link/../outside-pages"
            try lib.refused("parent traversal after symlink", bad)
            let dangling = own.appendingPathComponent("dangling")
            try fm.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing-external"))
            bad = ordinary
            bad.storage.overlay = dangling.appendingPathComponent("pages").path
            try lib.refused("dangling link with missing suffix", bad)
            let meta = own.appendingPathComponent("snapshot.meta")
            try fm.createSymbolicLink(at: meta, withDestinationURL: own.appendingPathComponent("base/sentinel"))
            try lib.refused("snapshot metadata aliases base", ordinary)
            try fm.removeItem(at: meta)
            // work/ (the lease's directory) linked outside: refused, and no lease appears there.
            let work = own.appendingPathComponent("work")
            try fm.createSymbolicLink(at: work, withDestinationURL: lib.external)
            #expect(throws: CocoaError.self) { try lib.validate(ordinary) }
            #expect(!fm.fileExists(atPath: lib.external.appendingPathComponent("lease").path))
            try fm.removeItem(at: work)
            let alias = DeviceInstance.directory(UUID(), state: lib.state)
            try fm.createSymbolicLink(at: alias, withDestinationURL: own)
            try lib.refused("other record directory alias", ordinary)
        }
    }
}
