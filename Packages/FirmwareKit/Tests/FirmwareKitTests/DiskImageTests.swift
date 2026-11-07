import Foundation
import Testing

@testable import FirmwareKit

/// DiskImage: the argv of both backends on every host; the real operations on each backend this host has
/// (hdiutil everywhere; `diskutil image` on macOS 27+), and that both produce the same grown volume and raw disk.
/// (Editing through a diskutil attach lays files out differently, the solid-state allocation policy: DiskImage.backend.)
@Suite(.serialized, .detachesItsImages) struct DiskImageTests {
    static func backends() async throws -> [DiskImage.Backend] {
        let hasDiskutilImage = try await DiskImage.exec(["/usr/sbin/diskutil", "image"]).0 == 0
        return [.hdiutil] + (hasDiskutilImage ? [.diskutil] : [])
    }

    @Test func argv() {
        let img = URL(fileURLWithPath: "/tmp/v.img")
        let raw = ["-imagekey", "diskimage-class=CRawDiskImage"]
        #expect(
            DiskImage.attachCommand(img, readOnly: false, backend: .hdiutil)
                == ["/usr/bin/hdiutil", "attach", "-plist"] + raw + ["-nomount", "-nobrowse", "/tmp/v.img"]
        )
        #expect(
            DiskImage.attachCommand(img, readOnly: true, backend: .hdiutil)
                == ["/usr/bin/hdiutil", "attach", "-plist"] + raw + [
                    "-readonly", "-nomount", "-nobrowse", "/tmp/v.img"
                ]
        )
        #expect(
            DiskImage.attachCommand(img, readOnly: false, backend: .diskutil)
                == ["/usr/sbin/diskutil", "image", "attach", "--plist", "--noMount", "--nobrowse", "/tmp/v.img"]
        )
        #expect(
            DiskImage.attachCommand(img, readOnly: true, backend: .diskutil)
                == [
                    "/usr/sbin/diskutil", "image", "attach", "--plist", "--readOnly", "--noMount", "--nobrowse",
                    "/tmp/v.img"
                ]
        )
        #expect(
            DiskImage.detachCommand("/dev/disk9", force: false, backend: .hdiutil) == [
                "/usr/bin/hdiutil", "detach", "/dev/disk9"
            ]
        )
        #expect(
            DiskImage.detachCommand("/dev/disk9", force: true, backend: .hdiutil) == [
                "/usr/bin/hdiutil", "detach", "/dev/disk9", "-force"
            ]
        )
        #expect(
            DiskImage.detachCommand("/dev/disk9", force: false, backend: .diskutil) == [
                "/usr/sbin/diskutil", "eject", "/dev/disk9"
            ]
        )
        #expect(
            DiskImage.detachCommand("/dev/disk9", force: true, backend: .diskutil) == [
                "/usr/sbin/diskutil", "unmountDisk", "force", "/dev/disk9"
            ]
        )
        #expect(
            DiskImage.resizeCommand(img, bytes: 1 << 30, slack: 4096, backend: .hdiutil) == [
                "/usr/bin/hdiutil", "resize", "-sectors", "2097152"
            ] + raw + ["/tmp/v.img"]
        )
        #expect(
            DiskImage.resizeCommand(img, bytes: 1 << 30, slack: 0, backend: .diskutil) == [
                "/usr/sbin/diskutil", "image", "resize", "--size", "1073741824", "/tmp/v.img"
            ]
        )
        #expect(
            DiskImage.resizeCommand(img, bytes: 1 << 30, slack: 4096, backend: .diskutil) == [
                "/usr/sbin/diskutil", "image", "resize", "--size", "1073737728", "/tmp/v.img"
            ]
        )
        let dmg = URL(fileURLWithPath: "/tmp/a.dmg")
        let out = URL(fileURLWithPath: "/tmp/w/raw")
        #expect(
            DiskImage.convertCommand(dmg, raw: out, backend: .hdiutil) == [
                "/usr/bin/hdiutil", "convert", "/tmp/a.dmg", "-format", "UDTO", "-quiet", "-o", "/tmp/w/raw"
            ]
        )
        #expect(
            DiskImage.convertCommand(dmg, raw: out, backend: .diskutil) == [
                "/usr/sbin/diskutil", "image", "create", "from", "--format", "RAW", "/tmp/a.dmg", "/tmp/w/raw.raw"
            ]
        )
    }

    /// Both tools' attach plists: dev-entry with or without /dev/, the whole disk chosen, the mount point if any.
    @Test func attachPlist() {
        let diskutil = """
            <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>system-entities</key><array>
            <dict><key>dev-entry</key><string>disk6</string><key>filesystem-type</key><string>hfs</string></dict>
            </array></dict></plist>
            """
        #expect(DiskImage.parseAttach(diskutil) == .init(device: "/dev/disk6", mountPoint: nil))
        let hdiutil = """
            <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>system-entities</key><array>
            <dict><key>dev-entry</key><string>/dev/disk8s2</string><key>mount-point</key><string>/Volumes/Data</string></dict>
            <dict><key>dev-entry</key><string>/dev/disk8</string></dict>
            </array></dict></plist>
            """
        #expect(
            DiskImage.parseAttach("noise before\n" + hdiutil)
                == .init(device: "/dev/disk8", mountPoint: "/Volumes/Data")
        )
        #expect(DiskImage.parseAttach("not a plist") == nil)
    }

    /// Each backend this host has: attach/detach a raw volume (listed while attached, gone after), grow it, and the
    /// grown volumes of both backends are byte-identical, for 4 KiB and 8 KiB allocation blocks (iOS's two sizes)
    /// with 0, 4 and 8 KiB of file slack past the volume (the iPad IPSW volumes carry 4 KiB; hdiutil then stops a
    /// block short).
    @Test(arguments: [(4096, 0), (8192, 0), (8192, 4096), (4096, 4096), (8192, 8192)]) func backendsAgree(
        blockSize: Int,
        slack: Int
    ) async throws {
        try await Oracle.withTemp { dir in
            let base = dir.appendingPathComponent("base.img")
            #expect(
                FileManager.default.createFile(atPath: base.path, contents: nil) && truncate(base.path, 32 << 20) == 0
            )
            let dev0 = try await DiskImage.attach(base)
            try await DiskImage.run(["/sbin/newfs_hfs", "-s", "-J", "-b", String(blockSize), "-v", "Data", dev0.device])
            try await DiskImage.detach(dev0.device)
            #expect(truncate(base.path, off_t((32 << 20) + slack)) == 0)
            var grown: [DiskImage.Backend: Data] = [:]
            for b in try await Self.backends() {
                let img = dir.appendingPathComponent("\(b.rawValue).img")
                try FileManager.default.copyItem(at: base, to: img)
                let a = try await DiskImage.attach(img, backend: b)
                #expect(a.device.hasPrefix("/dev/disk") && a.mountPoint == nil, "\(b)")
                // A loaded host lists a just-attached image in `hdiutil info` a moment later (seen under parallel builds).
                #expect(
                    try await Self.eventually {
                        try await DiskImage.attachedImages().contains { $0.image == img.path && $0.device == a.device }
                    },
                    "\(b): listed while attached"
                )
                try await DiskImage.detach(a.device, backend: b)
                #expect(
                    !(try await DiskImage.attachedImages()).contains { $0.image == img.path },
                    "\(b): gone after detach"
                )
                // resize, then the pad + alternate header move
                try await VolumeMount.grow(img, toBytes: 64 << 20, backend: b)
                let v = try HFSPlusVolume(img)
                #expect(
                    v.blockSize == blockSize && v.totalBlocks == ((64 << 20) - slack % blockSize) / blockSize,
                    "\(b): \(v.totalBlocks) x \(v.blockSize)"
                )
                let dev = try await DiskImage.attach(img, backend: b).device
                let fsck = try await VolumeMount.check(dev)
                try await DiskImage.detach(dev, backend: b)
                #expect(fsck.ok, "\(b): \(fsck.output.suffix(300))")
                grown[b] = try Data(contentsOf: img)
            }
            if let h = grown[.hdiutil], let d = grown[.diskutil] {
                #expect(
                    h == d,
                    "hdiutil and diskutil image resize differ: first byte \(zip(h, d).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1)"
                )
            }
        }
    }

    /// True once `condition` holds, polling for up to five seconds.
    static func eventually(_ condition: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<50 {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try await condition()
    }

    /// detachAll(under:) takes the images whose files are under the root (a killed preparer's) and no others.
    @Test func detachAllUnderRoot() async throws {
        try await Oracle.withTemp { dir in
            let inside = dir.appendingPathComponent("Preparing/job")
            let outside = dir.appendingPathComponent("kept")
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let (a, b) = (inside.appendingPathComponent("a.img"), outside.appendingPathComponent("b.img"))
            for img in [a, b] {
                #expect(
                    FileManager.default.createFile(atPath: img.path, contents: nil) && truncate(img.path, 1 << 20) == 0
                )
            }
            _ = try await DiskImage.attach(a)
            let kept = try await DiskImage.attach(b)
            try await DiskImage.detachAll(under: dir.appendingPathComponent("Preparing"))
            // One hdiutil info read can leave an attached image out while others attach or detach: b is polled for.
            let attached = try await DiskImage.attachedImages().map(\.image)
            let keptSeen = try await Self.eventually {
                try await DiskImage.attachedImages().contains { $0.image == b.path }
            }
            try await DiskImage.detach(kept.device)
            #expect(!attached.contains(a.path) && keptSeen, "\(attached)")
        }
    }

    /// Each backend converts a UDIF (zlib) image to the same raw disk.
    @Test func convertToRaw() async throws {
        try await Oracle.withTemp { dir in
            let src = dir.appendingPathComponent("src")
            let dmg = dir.appendingPathComponent("a.dmg")
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try Data("hello\n".utf8).write(to: src.appendingPathComponent("f"))
            try await DiskImage.run([
                "/usr/bin/hdiutil", "create", "-quiet", "-format", "UDZO", "-fs", "HFS+", "-layout", "SPUD",
                "-srcfolder", src.path, "-o", dmg.path
            ])
            var raws: [Data] = []
            for b in try await Self.backends() {
                let out = dir.appendingPathComponent("\(b.rawValue).raw")
                try await DiskImage.convertToRaw(dmg, to: out, backend: b)
                raws.append(try Data(contentsOf: out))
                #expect(
                    raws.last!.count > 0 && (try? APM.hfsSlice(raws.last!.prefix(64 * 512))) != nil,
                    "\(b): an Apple partition map with an HFS slice"
                )
            }
            if raws.count == 2 {
                let (o1, o2) = (try APM.hfsSlice(raws[0].prefix(64 * 512)), try APM.hfsSlice(raws[1].prefix(64 * 512)))
                #expect(
                    o1 == o2
                        && raws[0][o1.offset..<o1.offset + o1.length] == raws[1][o2.offset..<o2.offset + o2.length],
                    "the backends' HFS slices differ (\(raws[0].count) vs \(raws[1].count) bytes, first difference at \(zip(raws[0], raws[1]).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1))"
                )
            }
        }
    }
}
