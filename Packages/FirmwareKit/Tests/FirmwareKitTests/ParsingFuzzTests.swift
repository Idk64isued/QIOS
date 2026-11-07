import Compression
import Foundation
import Testing

@testable import FirmwareKit

/// The parsers over firmware files against cut-short and bit-flipped inputs: each throws or returns, never traps
/// (a trap ends the test run). The inputs are made here; the flips are seeded, the same on every run.
@Suite(.serialized) struct ParsingFuzzTests {
    typealias Seeded = HFSPlusWriterTests.Seeded

    /// `count` sets of one to three bit flips in `region`: (offset, the bit).
    static func flips(in region: Range<Int>, count: Int, seed: UInt64) -> [[(at: Int, bit: UInt8)]] {
        var rng = Seeded(state: seed)
        return (0..<count).map { _ in
            (0..<Int.random(in: 1...3, using: &rng)).map { _ in
                (Int.random(in: region, using: &rng), 1 << UInt8.random(in: 0..<8, using: &rng))
            }
        }
    }

    /// `count` copies of `bytes`, each with one to three bits flipped in `region`.
    static func flipped(_ bytes: [UInt8], in region: Range<Int>, count: Int, seed: UInt64) -> [[UInt8]] {
        flips(in: region, count: count, seed: seed).map { f in
            var b = bytes
            for (at, bit) in f { b[at] ^= bit }
            return b
        }
    }

    /// `bytes` cut at `cuts` evenly spaced lengths.
    static func cut(_ bytes: [UInt8], _ cuts: Int) -> [[UInt8]] {
        (0..<cuts).map { Array(bytes.prefix(bytes.count * $0 / cuts)) }
    }

    /// A writer-made volume's volume header and B-tree nodes, flipped, through HFSPlusVolume's listing and the
    /// writer's open and reads; and the volume cut short.
    @Test func hfsVolumesThrowOnCorruption() throws {
        try Oracle.withTemp { dir in
            let img = dir.appendingPathComponent("v.img")
            try HFSPlusWriter.makeHFS(img, size: 8 << 20, journaled: false)
            let w = try HFSPlusWriter(img)
            var paths: [String] = []
            for d in 0..<6 {
                try w.makeDirectory("d\(d)")
                for f in 0..<40 {
                    try w.put(Data(repeating: UInt8(f), count: 100 * f), at: "d\(d)/a long file name \(f)")
                    paths.append("d\(d)/a long file name \(f)")
                }
                try w.makeSymlink("d\(d)/s", to: "../d0")
                try w.link("d\(d)/h", to: "d0/a long file name 3")
            }
            try w.close()
            let clean = [UInt8](try Data(contentsOf: img))
            let v = try HFSPlusVolume(img)
            #expect(try v.listing().count > 240)
            // the volume header; the catalog's and extents tree's first 8 nodes whole, and their descriptors and
            // record offsets (a node's first 14 bytes and last 64)
            var regions = [1024..<1536]
            for (fork, id) in [(v.catalogFork, HFSPlusVolume.catalogID), (v.extentsFork, HFSPlusVolume.extentsID)] {
                let at = Int(fork.extents[0].start) * v.blockSize
                let size = try v.btree(fork, fileID: id).nodeSize
                let nodes = min(Int(fork.logicalSize) / size, 8)
                regions.append(at..<at + nodes * size)
                for n in 0..<nodes {
                    regions += [at + n * size..<at + n * size + 14, at + (n + 1) * size - 64..<at + (n + 1) * size]
                }
            }
            func survive() {
                if let v = try? HFSPlusVolume(img) { _ = try? v.listing() }
                if let w = try? HFSPlusWriter(img) {
                    for p in paths.prefix(20) { _ = try? w.item(at: p) }
                    _ = try? w.item(at: "d1/h")
                }
            }
            let file = try FileHandle(forUpdating: img)
            defer { try? file.close() }
            func flip(_ f: [(at: Int, bit: UInt8)]) throws {
                for (at, bit) in f {
                    try file.seek(toOffset: UInt64(at))
                    let b = try file.read(upToCount: 1)![0] ^ bit
                    try file.seek(toOffset: UInt64(at))
                    try file.write(contentsOf: [b])
                }
            }
            for (i, r) in regions.enumerated() {
                for f in Self.flips(in: r, count: 80, seed: UInt64(i)) {
                    try flip(f)
                    survive()
                    try flip(f)  // and back
                }
            }
            for b in Self.cut(clean, 64) {
                try Data(b).write(to: img)
                survive()
            }
        }
    }

    /// decmpfs headers and type 4 resource forks (zlib blocks), flipped and cut, through HFSPlusVolume.decmpfs.
    @Test func decmpfsThrowsOnCorruption() throws {
        let content = [UInt8]((0..<200_000).map { UInt8(truncatingIfNeeded: $0 * 7 / 3) })
        func zlib(_ b: ArraySlice<UInt8>) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: b.count + 1024)
            let n = Array(b).withUnsafeBufferPointer {
                compression_encode_buffer(&out, out.count, $0.baseAddress!, b.count, nil, COMPRESSION_ZLIB)
            }
            return [0x78, 0x9C] + out.prefix(n)
        }
        func header(_ type: UInt32, _ size: Int) -> [UInt8] {
            var h = [UInt8](repeating: 0, count: 16)
            put32(&h, 0, 0x636D_7066)
            put32(&h, 4, type)
            put32(&h, 8, UInt32(size))
            return h
        }
        // inline (type 3)
        let inline = header(3, 4000) + zlib(content.prefix(4000))
        // resource fork (type 4): its header's data offset (256), then there the length, the block count and
        // (offset, length) from the length field on
        let blocks = stride(from: 0, to: content.count, by: 1 << 16).map {
            zlib(content[$0..<min($0 + (1 << 16), content.count)])
        }
        var table = [UInt8](repeating: 0, count: 8 + 8 * blocks.count)
        put32(&table, 4, UInt32(blocks.count))
        var off = table.count
        for (i, b) in blocks.enumerated() {
            put32(&table, 8 + 8 * i, UInt32(off - 4))
            put32(&table, 12 + 8 * i, UInt32(b.count))
            off += b.count
        }
        var fork = [UInt8](repeating: 0, count: 256)
        putBE32(&fork, 0, 256)
        fork += table + blocks.joined()
        let forked = header(4, content.count)
        #expect(try HFSPlusVolume.decmpfs(inline, name: "t") { [] } == Array(content.prefix(4000)))
        #expect(try HFSPlusVolume.decmpfs(forked, name: "t") { fork } == content)
        for x in Self.flipped(inline, in: 0..<inline.count, count: 400, seed: 1) + Self.cut(inline, 32) {
            _ = try? HFSPlusVolume.decmpfs(x, name: "t") { [] }
        }
        for x in Self.flipped(forked, in: 0..<16, count: 200, seed: 2) {
            _ = try? HFSPlusVolume.decmpfs(x, name: "t") { fork }
        }
        for f in Self.flipped(fork, in: 0..<256 + table.count, count: 400, seed: 3) + Self.cut(fork, 32) {
            _ = try? HFSPlusVolume.decmpfs(forked, name: "t") { f }
        }
    }

    /// A UDIF image's trailer and block tables, flipped, and the image cut short, through UDIFReader.
    @Test func udifImagesThrowOnCorruption() async throws {
        try await Oracle.withTemp { dir in
            let src = dir.appendingPathComponent("src")
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try Data(String(repeating: "hello\n", count: 100_000).utf8).write(to: src.appendingPathComponent("t"))
            let dmg = dir.appendingPathComponent("t.dmg")
            try await DiskImage.run([
                "/usr/bin/hdiutil", "create", "-quiet", "-srcfolder", src.path, "-fs", "HFS+", "-volname", "T",
                "-format", "UDZO", dmg.path
            ])
            let clean = [UInt8](try Data(contentsOf: dmg))
            let koly = Array(clean.suffix(512))
            let xmlAt = Int(try be64(koly, 0xD8))
            let plist = try #require(
                try PropertyListSerialization.propertyList(
                    from: Data(clean[xmlAt..<xmlAt + Int(try be64(koly, 0xE0))]),
                    format: nil
                ) as? [String: Any]
            )
            var fork = try #require(plist["resource-fork"] as? [String: Any])
            let blkx = try #require(fork["blkx"] as? [[String: Any]])
            let tables = blkx.compactMap { $0["Data"] as? Data }.map { [UInt8]($0) }
            let out = dir.appendingPathComponent("raw")
            func survive(_ bytes: [UInt8]) throws {
                try Data(bytes).write(to: dmg)
                _ = try? UDIFReader.convertToRaw(dmg, to: out)
            }
            /// The image with block table `k` replaced by `table`.
            func image(_ k: Int, _ table: [UInt8]) throws -> [UInt8] {
                var entries = blkx
                entries[k]["Data"] = Data(table)
                fork["blkx"] = entries
                var p = plist
                p["resource-fork"] = fork
                let xml = [UInt8](try PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0))
                var k = koly
                putBE64(&k, 0xE0, UInt64(xml.count))
                return Array(clean[..<xmlAt]) + xml + k
            }
            try survive(try image(0, tables[0]))
            #expect(FileManager.default.fileExists(atPath: out.path))
            for b in Self.flipped(clean, in: clean.count - 512..<clean.count, count: 300, seed: 4) { try survive(b) }
            for (k, t) in tables.enumerated() {
                for f in Self.flipped(t, in: 0..<t.count, count: 150, seed: 5 + UInt64(k)) {
                    try survive(try image(k, f))
                }
            }
            for b in Self.cut(clean, 32) { try survive(b) }
        }
    }

    /// A tar archive's headers, flipped, and the archive cut short, through TarArchive.
    @Test func tarArchivesThrowOnCorruption() async throws {
        try await Oracle.withTemp { dir in
            let src = dir.appendingPathComponent("src")
            try FileManager.default.createDirectory(
                at: src.appendingPathComponent("d"),
                withIntermediateDirectories: true
            )
            for i in 0..<6 {
                try Data(repeating: UInt8(i), count: 700 * i).write(to: src.appendingPathComponent("d/f\(i)"))
            }
            try FileManager.default.createSymbolicLink(
                atPath: src.appendingPathComponent("l").path,
                withDestinationPath: "d"
            )
            let tar = dir.appendingPathComponent("t.tar")
            try await DiskImage.run(["/usr/bin/tar", "--format", "ustar", "-cf", tar.path, "-C", src.path, "."])
            let clean = [UInt8](try Data(contentsOf: tar))
            #expect(try TarArchive(Data(clean)).members.count == 9)
            // and a negative size (a header's octal field is text)
            var negative = clean
            negative.replaceSubrange(124..<136, with: Array("-0000001000\0".utf8))
            for b in Self.flipped(clean, in: 0..<min(clean.count, 8192), count: 600, seed: 6) + Self.cut(clean, 64)
                + [negative]
            {
                _ = try? TarArchive(Data(b))
            }
        }
    }

    /// A thin armv6 Mach-O: dyld info naming an export trie, a linked image, and (last, so a cut can end inside it)
    /// a symbol table of two symbols.
    static func machO() -> [UInt8] {
        func word(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        let dylib = Array("/usr/lib/libSystem.B.dylib".utf8) + [0, 0]
        let strings = Array("\0_main\0_printf\0".utf8)
        let symtab = 28 + 48 + 24 + dylib.count + 24
        let trie = symtab + 24 + strings.count
        var cmds = word(0x8000_0022) + word(48) + [UInt8](repeating: 0, count: 32) + word(UInt32(trie)) + word(8)
        cmds += word(0xC) + word(UInt32(24 + dylib.count)) + word(24) + word(0) + word(0) + word(0) + dylib
        cmds += word(2) + word(24) + word(UInt32(symtab)) + word(2) + word(UInt32(symtab + 24))
        cmds += word(UInt32(strings.count))
        let header = [0xFEED_FACE, 12, 6, 2, 3, UInt32(cmds.count), 0x85].flatMap(word)
        let symbols = word(1) + [0x0F, 1, 0, 0] + word(0x1000) + word(7) + [0x01, 0, 0, 1] + word(0)  // _main, _printf
        return header + cmds + symbols + strings + [0, 1, 0x5F, 0, 5, 0, 0, 0]
    }

    /// FitCheck's in-memory Mach-O reader over the Mach-O above, flipped and cut: its load commands, linked
    /// images, re-exports, symbols and dyld info.
    @Test func machOImagesThrowOnCorruption() throws {
        let clean = Self.machO()
        let m = try #require(MachO32(clean))
        #expect(m.dylibs().map(\.name) == ["/usr/lib/libSystem.B.dylib"])
        #expect(m.symbols().map(\.name) == ["_main", "_printf"])
        for b in Self.flipped(clean, in: 0..<clean.count, count: 3000, seed: 7) + Self.cut(clean, clean.count) {
            guard let m = MachO32.slice(Data(b), arch: "armv6")?.image else { continue }
            _ = (m.dylibs(), m.reexported(), m.symbols())
            for c in m.commands where c.cmd == MachO32.lcDyldInfoOnly {
                _ = try? (m.u32(c.off + 40), m.u32(c.off + 44))
            }
        }
    }

    /// TrustStore1xTests' certificate, flipped and cut, and one whose empty TBSCertificate ends the data, through
    /// TrustStore1x.normalizedSubject's DER walk.
    @Test func certificatesThrowOnCorruption() throws {
        let clean = [UInt8](TrustStore1xTests.certificate)
        #expect(try TrustStore1x.normalizedSubject(Data(clean)).count == TrustStore1xTests.subjectContent.count)
        for b in Self.flipped(clean, in: 0..<clean.count, count: 3000, seed: 8) + Self.cut(clean, clean.count)
            + [[0x30, 0x02, 0x30, 0x00]]
        {
            _ = try? TrustStore1x.normalizedSubject(Data(b))
        }
    }

    /// MalformedInputTests' one-image shared cache, its header, tables, Mach-O and nlists flipped and the whole cut,
    /// through the cache's image list, sections, symbols and the AppSync patch's locate, and FitCheck's export trie
    /// over it.
    @Test func sharedCachesThrowOnCorruption() {
        let clean = MalformedInputTests.sharedCache()
        let regions = [0..<0x20, 0x40..<0x80, 0x100..<0x1B0, 0x500..<0x518]
        let flipped = regions.enumerated().flatMap { Self.flipped(clean, in: $1, count: 600, seed: 20 + UInt64($0)) }
        for b in flipped + Self.cut(clean, 128) {
            guard let cache = try? DyldSharedCache(data: Data(b)) else { continue }
            for img in cache.images {
                _ = try? cache.cStrings(in: img, section: "__cstring")
                _ = try? cache.symbolNames(in: img)
            }
            _ = try? AppSyncCachePatch.locate(cache)
            _ = MachO32.trieReexports(b, at: 0x400, size: 0x20)
        }
    }

    /// KBootTests' kernelcache, its header and load commands flipped and the whole cut, through MachO (segments,
    /// entry, the boot_args version scan), the keybag one-shot's entry and the sandbox patch's locate.
    @Test func kernelcachesThrowOnCorruption() {
        let clean = [UInt8](KBootTests.kernel(at: 0x8000_0000))
        let commands = 0..<28 + 56 * 2 + 80
        for b in Self.flipped(clean, in: commands, count: 3000, seed: 14) + Self.cut(clean, 128) {
            if let m = try? MachO(Data(b)) {
                _ = try? m.entry()
                _ = m.bootArgsVersion()
            }
            _ = try? N72Keybag.kernelEntry(Data(b))
            _ = try? SandboxPatch.locate(b)
        }
    }

    /// KBootTests' device tree, flipped and cut, through DeviceTree's parse and its edits (each reparses).
    @Test func deviceTreesThrowOnCorruption() {
        let clean = [UInt8](KBootTests.dtBlob)
        for b in Self.flipped(clean, in: 0..<clean.count, count: 3000, seed: 11) + Self.cut(clean, 64) {
            guard var dt = try? DeviceTree(Data(b)) else { continue }
            _ = try? dt.set("chosen", "firmware-version", .string("iBoot-1"))
            _ = try? dt.add("arm-io", "x")
            _ = try? dt.addNode("arm-io", "y")
        }
    }

    /// A plain 8900 container around an IMG2 of 50 bytes padded to 64, its headers flipped and the whole cut, through
    /// Apple8900.body and IMG2's header and payload.
    @Test func img2ContainersThrowOnCorruption() throws {
        func word(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        var img2 = Array("2gmIobi".utf8) + [0x62] + word(0) + word(0x1800_0000) + word(64) + word(50)
        img2 += [UInt8](repeating: 0, count: IMG2.headerSize - img2.count) + [UInt8](repeating: 0x5A, count: 64)
        var container = Array("89001.0".utf8) + [4] + word(0) + word(img2.count)
        container += [UInt8](repeating: 0, count: Apple8900.headerSize - container.count)
        let clean = container + img2
        #expect(try IMG2.payload(Apple8900.body(Data(clean))) == Data(repeating: 0x5A, count: 50))
        let headers =
            Self.flipped(clean, in: 0..<16, count: 600, seed: 12)
            + Self.flipped(clean, in: 0x800..<0x818, count: 600, seed: 13)
        for b in headers + Self.cut(clean, 64) {
            guard let body = try? Apple8900.body(Data(b)) else { continue }
            _ = try? IMG2.payload(body)
        }
    }

    /// An img3 of a 4-byte TYPE tag and `last` (magic as stored, data), its header's sizeNoPack covering both.
    static func img3(_ last: (String, [UInt8])) -> [UInt8] {
        func word(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        func tag(_ magic: String, _ data: [UInt8]) -> [UInt8] {
            Array(magic.utf8) + word(12 + data.count) + word(data.count) + data
        }
        let tags = tag("EPYT", Array("illb".utf8)) + tag(last.0, last.1)
        return [0x33, 0x67, 0x6D, 0x49] + word(0x14 + tags.count) + word(tags.count) + word(0) + word(0) + tags
    }

    /// N72NOR.wrapSHSH's walk to an LLB's SHSH tag, and N72Board.productionKBAG's read of a KBAG tag, over img3s
    /// flipped and cut.
    @Test func img3TagsThrowOnCorruption() throws {
        let key = Data(count: 16)
        var signed = Self.img3(("HSHS", [UInt8](repeating: 7, count: 128)))
        #expect(try N72NOR.wrapSHSH(&signed, key: key))
        let clean = Self.img3(("HSHS", [UInt8](repeating: 7, count: 128)))
        for var b in Self.flipped(clean, in: 0..<clean.count, count: 2000, seed: 9) + Self.cut(clean, clean.count) {
            _ = try? IMG3.payload(Data(b))
            _ = try? IMG3.decrypt(Data(b), iv: key, key: key)
            _ = try? SandboxPatch.rebuildIMG3(Data(b), data: [1, 2, 3])
            _ = try? N72NOR.type(of: Data(b))
            _ = try? N72NOR.wrapSHSH(&b, key: key)
        }
        let kbag = Self.img3(("GABK", [1, 0, 0, 0, 128, 0, 0, 0] + [UInt8](repeating: 9, count: 32)))
        let t = try #require(try IMG3.tags(Data(kbag))["KBAG"])
        #expect(try N72Board.productionKBAG(Data(kbag), t, name: "t") == [UInt8](repeating: 9, count: 32))
        for b in Self.flipped(kbag, in: 0..<kbag.count, count: 2000, seed: 10) + Self.cut(kbag, kbag.count) {
            guard let t = try? IMG3.tags(Data(b))["KBAG"], t.dataLength >= 40 else { continue }
            _ = try? N72Board.productionKBAG(Data(b), t, name: "t")
        }
    }
}
