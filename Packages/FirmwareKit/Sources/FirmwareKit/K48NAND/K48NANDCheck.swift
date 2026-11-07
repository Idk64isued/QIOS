// ipad1_nand.py check: reads a store back the way the kernel would (special pages, VFL contexts, a
// YaFTL R/O-restore walk over every vblock, the index pages, then the MBR and HFS headers).
import BinaryParsing
import Foundation

extension K48NAND {
    /// A store read the way the IOP serves it: with an overlay (s5l8930_iop.c "nand-overlay"), a page whose
    /// bit is set in bus<b>-ce<c>.dirty comes from the overlay's .pages file (a hole there = erased), else the base.
    /// An image store (StoreFormat.image) whose overlay holds its live clone (`overlay/nand`, PreparedDeviceBoot.liveNAND)
    /// is read from that clone alone: it is the device's NAND.
    final class StoreReader {
        let geo: Geometry, stride: Int
        let files: [Data], overlay: [Data], dirty: [Data]
        /// Records are stored XOR 0xFF (StoreFormat.image), so a hole reads as the erased page.
        let xorFF: Bool
        /// From the signature's flags (plainSigFlags: an S5L8920 store).
        var plain = false
        init(_ dir: URL, geo: Geometry, overlay: URL? = nil) throws {
            guard try K48NAND.geometry(store: dir).json == geo.json else {
                throw FirmwareError(.unsupported, "\(dir.path): reader geometry does not match geometry.json")
            }
            let format = try K48NAND.storeFormat(dir)
            var dir = dir
            var overlay = overlay
            if format == .image, let live = overlay?.appendingPathComponent("nand"),
                FileManager.default.fileExists(atPath: live.path)
            {
                guard try K48NAND.storeFormat(live) == .image, try K48NAND.geometry(store: live).json == geo.json else {
                    throw FirmwareError(.unsupported, "\(live.path): the live NAND is not its base's format")
                }
                dir = live
                overlay = nil
            }
            if let overlay {
                let marker = overlay.appendingPathComponent("storage-format")
                if FileManager.default.fileExists(atPath: marker.path) {
                    let saved = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard saved == format.rawValue else {
                        throw FirmwareError(
                            .unsupported,
                            "\(overlay.path): NAND overlay format \(saved) is not its base's"
                        )
                    }
                }
            }
            self.geo = geo
            xorFF = format == .image
            stride = geo.pageSize + geo.spareBytes
            func each(_ d: URL, _ ext: String) throws -> [Data] {
                try (0..<geo.buses).flatMap { b in
                    try (0..<geo.cePerBus).map { c in
                        try Data(contentsOf: d.appendingPathComponent("bus\(b)-ce\(c).\(ext)"), options: .alwaysMapped)
                    }
                }
            }
            let pageFileBytes = geo.blocksPerCE * geo.pagesPerBlock * stride
            func validate(_ data: [Data], bytes: Int, at directory: URL, kind: String) throws {
                guard data.allSatisfy({ $0.count == bytes }) else {
                    throw FirmwareError(.unsupported, "\(directory.path): invalid \(kind) file size for NAND geometry")
                }
            }
            files = try each(dir, "pages")
            try validate(files, bytes: pageFileBytes, at: dir, kind: "pages")
            if let overlay {
                let entries = try FileManager.default.contentsOfDirectory(atPath: overlay.path)
                if entries.contains(where: { $0.hasSuffix(".pages") || $0.hasSuffix(".dirty") }),
                    !entries.contains("bus0-ce0.dirty")
                {
                    throw FirmwareError(
                        .unsupported,
                        "\(overlay.path): NAND overlay has page data without its dirty bitmap"
                    )
                }
            }
            let o = overlay.flatMap {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("bus0-ce0.dirty").path) ? $0 : nil
            }
            self.overlay = try o.map { try each($0, "pages") } ?? []
            dirty = try o.map { try each($0, "dirty") } ?? []
            if let o {
                try validate(self.overlay, bytes: pageFileBytes, at: o, kind: "overlay pages")
                try validate(dirty, bytes: (geo.blocksPerCE * geo.pagesPerBlock + 7) / 8, at: o, kind: "dirty bitmap")
            }
            plain = signature().map { $0.flags & 0x10000 == 0 } ?? false
        }

        /// NANDDRIVERSIGN's payload, as `writeMetadata` lays it out on cs0's signature block.
        func signature() -> (epoch: UInt8, flags: UInt32, kernelVersion: [UInt8])? {
            guard let (d, _) = read(0, geo.ppage(geo.cand[0][4], 0)), d.starts(with: "NANDDRIVERSIGN".utf8) else {
                return nil
            }
            // nSig (its low byte the epoch's digit) and the flags at 0x38, the kernel version (NUL-padded) at 0x40
            return try? parsing(d, "NANDDRIVERSIGN") { s in
                try s.seek(toAbsoluteOffset: 0x38)
                let sig = try UInt32(parsingLittleEndian: &s)
                let flags = try UInt32(parsingLittleEndian: &s)
                let version = try [UInt8](parsing: &s, byteCount: 0x100)
                return (UInt8(truncatingIfNeeded: sig) &- 0x30, flags, Array(version.prefix { $0 != 0 }))
            }
        }

        /// The file serving (cs, ppage).
        func file(_ cs: Int, _ ppage: Int) -> Data {
            let (b, c) = geo.busCE(cs)
            let i = b * geo.cePerBus + c
            if !dirty.isEmpty, ppage / 8 < dirty[i].count,
                dirty[i][dirty[i].startIndex + ppage / 8] >> (ppage % 8) & 1 != 0
            {
                return overlay[i]
            }
            return files[i]
        }

        /// The un-whitened 12-byte meta of (cs, ppage), nil if the page is blank. Reads only the spare.
        func meta(_ cs: Int, _ ppage: Int) -> [UInt8]? {
            let f = file(cs, ppage)
            let o = f.startIndex + ppage * stride + geo.pageSize
            guard o + K48NAND.meta <= f.endIndex else { return nil }
            var m = [UInt8](f[o..<o + K48NAND.meta])
            if xorFF { for i in m.indices { m[i] ^= 0xFF } }
            if m.allSatisfy({ $0 == 0 }) || m.allSatisfy({ $0 == 0xFF }) { return nil }
            return plain ? m : K48NAND.whiten(m, ppage)
        }

        /// (data, 12-byte meta, un-whitened unless raw), nil if the page is blank.
        func read(_ cs: Int, _ ppage: Int, raw: Bool = false) -> (data: [UInt8], meta: [UInt8])? {
            let f = file(cs, ppage)
            let o = ppage * stride
            guard o + stride <= f.count else { return nil }
            var rec = [UInt8](f[o..<o + stride])
            if xorFF { K48NANDImage.invert(&rec) }
            let sp = rec[geo.pageSize...]
            if sp.allSatisfy({ $0 == 0 })
                || (sp.allSatisfy { $0 == 0xFF } && rec[..<geo.pageSize].allSatisfy { $0 == 0xFF })
            {
                return nil
            }
            let m = Array(sp.prefix(K48NAND.meta))
            return (Array(rec[..<geo.pageSize]), raw || plain ? m : K48NAND.whiten(m, ppage))
        }
        func readVPN(_ vpn: Int) -> (data: [UInt8], meta: [UInt8])? {
            let (cs, p) = geo.vpnToPhys(vpn)
            return read(cs, p)
        }
    }

    /// How a store's records sit in its files (geometry.json "storage_format", which qemu-ios's IOP reads too).
    public enum StoreFormat: String, Sendable {
        /// As programmed; a hole, and an all-zero record, read as the erased page. No key, or this one.
        case legacy = "legacy-zero-blank-v1"
        /// XOR 0xFF, so a hole is the erased page and every programmed record reads back as written (format 2).
        case image = "nand-xor-ff-v2"
    }

    /// geometry.json's "layout" on a store FirmwareKit laid out (build, the image migration): the generated VFL this
    /// reader follows. A store qemu-ios's restore wrote is also nand-xor-ff-v2 but physical: it needs the native
    /// VFL/crypto mapping, and reading it as this layout loses data.
    static let generatedLayout = "generated"

    static func storeFormat(_ value: Any?, layout: Any?, at dir: URL) throws -> StoreFormat {
        if value == nil || value as? String == StoreFormat.legacy.rawValue { return .legacy }
        if value as? String == StoreFormat.image.rawValue, layout as? String == generatedLayout { return .image }
        throw FirmwareError(
            .unsupported,
            "\(dir.path): unsupported NAND storage_format \(String(describing: value)); physical NAND export requires native VFL/crypto mapping; use guest filesystem services"
        )
    }

    public static func storeFormat(_ dir: URL) throws -> StoreFormat {
        let g = try geometryObject(dir)
        return try storeFormat(g["storage_format"], layout: g["layout"], at: dir)
    }

    static func geometryObject(_ dir: URL) throws -> [String: Any] {
        guard
            let g = try JSONSerialization.jsonObject(
                with: Data(contentsOf: dir.appendingPathComponent("geometry.json"))
            ) as? [String: Any]
        else {
            throw FirmwareError(.unsupported, "\(dir.path): geometry.json must contain an object")
        }
        return g
    }

    /// The known geometry a store's geometry.json describes.
    static func geometry(store dir: URL) throws -> Geometry {
        let g = try geometryObject(dir)
        _ = try storeFormat(g["storage_format"], layout: g["layout"], at: dir)
        guard
            let geo = Geometry.known.first(where: {
                ($0.buses, $0.cePerBus, $0.blocksPerCE, $0.pagesPerBlock, $0.pageSize)
                    == (
                        g["buses"] as? Int, g["ce_per_bus"] as? Int, g["blocks_per_ce"] as? Int,
                        g["pages_per_block"] as? Int, g["page_bytes"] as? Int
                    )
                    && g["spare_bytes"] as? Int == $0.spareBytes
                    && (g["vendor_type"] as? Int ?? 0x100014) == Int($0.vendorType)
                    && (g["chip_id"] as? String).flatMap {
                        UInt32($0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0, radix: 16)
                    } == $0.chipID
            })
        else { throw FirmwareError(.unsupported, "\(dir.path): no known geometry matches geometry.json") }
        return geo
    }

    /// A DEVICEINFOBBT page's eight candidate blocks (u32s at 0x14) and its bad-block table (the length at 0x34, the
    /// table at 0x38); nil when the table runs past the page.
    static func deviceInfoBBT(_ d: [UInt8]) -> (cands: [Int], bbt: [UInt8])? {
        try? parsing(d, "DEVICEINFOBBT") { s in
            try s.seek(toAbsoluteOffset: 0x14)
            let cands = try [UInt32](parsing: &s, count: 8) { try UInt32(parsingLittleEndian: &$0) }
            let n = try UInt32(parsingLittleEndian: &s)
            return (cands.map { Int($0) }, try [UInt8](parsing: &s, byteCount: Int(n)))
        }
    }

    /// Checks a store; `log` gets every "ok"/"FAIL" line. Returns true when nothing failed.
    public static func check(store dir: URL, mbr: URL? = nil, system: URL? = nil, log: (String) -> Void = { _ in })
        throws -> Bool
    {
        let geo = try geometry(store: dir)
        let st = try StoreReader(dir, geo: geo)
        var fails: [String] = []
        func ok(_ cond: Bool, _ what: @autoclosure () -> String) {
            if cond { log("ok   " + what()) } else { fails.append("FAIL " + what()) }
        }
        func bit(_ bbt: [UInt8], _ b: Int) -> Bool { bbt[b / 8] >> (b % 8) & 1 != 0 }
        func magic(_ d: [UInt8], _ m: String) -> Bool {
            Array(d.prefix(16)) == Array(m.utf8) + [UInt8](repeating: 0, count: 16 - m.utf8.count)
        }

        // special pages: _ReadSpecialBlock's scan window, top block down
        var sigBlock: Int?
        for cs in 0..<geo.numCS {
            var found: (blk: Int, cands: [Int], bbt: [UInt8])?
            for blk in stride(from: geo.blocksPerCE - 1, to: geo.blocksPerCE - geo.blocksPerCE / 10 - 1, by: -1) {
                if let (d, _) = st.read(cs, geo.ppage(blk, 0)), magic(d, "DEVICEINFOBBT") {
                    found = deviceInfoBBT(d).map { (blk, $0.cands, $0.bbt) }
                    break
                }
            }
            ok(found?.bbt.count == geo.bbtLen, "cs\(cs) DEVICEINFOBBT at block \(hex(found?.blk ?? 0))")
            guard let (_, c, bbt) = found, bbt.count == geo.bbtLen else { continue }
            ok(
                !bit(bbt, 0) && geo.cand[cs].allSatisfy { !bit(bbt, $0) },
                "cs\(cs) BBT marks block 0 and candidates bad"
            )
            ok(bit(bbt, geo.vflBlocks[0]), "cs\(cs) BBT block 1 good")
            let d2 = st.read(cs, geo.ppage(c[1], 0))
            ok(d2.map { magic($0.data, "DEVICEINFOBBT") } ?? false, "cs\(cs) second BBT copy at \(hex(c[1]))")
            if cs == 0 { sigBlock = c[4] }
        }
        let sig = st.read(0, geo.ppage(sigBlock ?? 0, 0))
        ok(
            sig.map { magic($0.data, "NANDDRIVERSIGN") } ?? false,
            "NANDDRIVERSIGN at cs0 block \(hex(sigBlock ?? 0)) (BBT hdr+0x24)"
        )
        if let (d, _) = sig {
            let ns = try le32(d, 0x38)
            let flags = try le32(d, 0x3c)
            st.plain = flags & 0x10000 == 0  // 0x5, or a recipe's nand_sig_flags (3.1.x: 4)
            ok(
                ns >> 8 == nsigBase >> 8 && (0x31...0x39).contains(ns & 0xff)
                    && (flags == sigFlags || (st.plain && (4...5).contains(flags))),
                "signature nSig=\(String(format: "%08x", ns)) flags=\(String(format: "%08x", flags)) (VSVFL, epoch \(ns & 0xf), whitening \(st.plain ? "off" : "on"))"
            )
        }

        // VFL contexts
        for cs in 0..<geo.numCS {
            let copies = (0..<8).map { st.read(cs, geo.ppage(geo.vflBlocks[0], $0)) }
            guard let first = copies[0] else {
                fails.append("FAIL cs\(cs) VFLCxt missing")
                continue
            }
            let ctx = Array(first.data.prefix(0x800))
            ok(
                copies.allSatisfy { $0.map { Array($0.data.prefix(0x800)) == ctx } ?? false },
                "cs\(cs) VFLCxt 8 identical copies"
            )
            ok(ctx == vflChecksum(ctx), "cs\(cs) VFLCxt checksums")
            ok(
                copies.allSatisfy { $0.map { $0.meta[8] == 0 && $0.meta[9] == tVFL } ?? false },
                "cs\(cs) VFLCxt spare type 0x80"
            )
            func u16(_ o: Int) throws -> Int { Int(try le16(ctx, o)) }
            let ver = try le32(ctx, 0x7f4)
            let ftlType = try le32(ctx, 8)
            let usable = try u16(0x696)
            let pstart = try u16(0x698)
            let cb = [try u16(0x69a), try u16(0x69c), try u16(0x69e)]
            ok(
                ver <= 2 && ftlType == 2 && usable == geo.usable && pstart == geo.usable && cb == geo.ctrlBlocks,
                "cs\(cs) VFLCxt version \(ver) ftl_type \(ftlType) usable \(usable) ctrl \(cb)"
            )
            ok(
                try geo.remap.allSatisfy { pbn, r in try u16(0x26 + 2 * (r.bank * geo.pool + r.slot)) == pbn },
                "cs\(cs) pool map remaps blocks \(geo.remap.keys.sorted())"
            )
        }

        // FTL walk: every vblock's page 0 classifies it
        var tocFromIndex: [Int: [UInt32]] = [:]
        var tocFromUser: [Int: Int] = [:]
        var nuser = 0
        var nindex = 0
        var nfree = 0
        for v in 0..<geo.numBlocks {
            let base = v * geo.ppsublk
            guard let (_, m) = st.readVPN(base) else {
                nfree += 1
                continue
            }
            let typ = m[9]
            if geo.ctrlBlocks.contains(v) { fails.append("FAIL ctrl vblock \(v) is programmed") }
            if typ == tIndex {
                nindex += 1
            } else if typ == tUser {
                nuser += 1
            } else {
                fails.append("FAIL vblock \(v) page 0 has spare type \(hex(typ))")
                continue
            }
            var lpns: [UInt32] = []
            for j in 0..<geo.ppsublk {
                guard let (pd, pm) = st.readVPN(base + j), pm[9] & tClosed == 0 else { break }
                let lpn = try le32(pm, 0)
                lpns.append(lpn)
                if typ == tIndex {
                    tocFromIndex[Int(lpn)] = try (0..<geo.tocEntries).map { try le32(pd, 4 * $0) }
                } else {
                    tocFromUser[Int(lpn)] = base + j
                }
            }
            if lpns.count == geo.dataPages {
                let table = (0..<geo.toc).flatMap { st.readVPN(base + geo.dataPages + $0)?.data ?? [] }
                let got = try (0..<geo.dataPages).map { 4 * $0 + 4 <= table.count ? try le32(table, 4 * $0) : 0 }
                if v % 25 == 0 || got != lpns {
                    ok(got == lpns, "vblock \(v) closed, BTOC matches \(lpns.count) page spares")
                }
            }
        }
        log("ok    \(nuser) user, \(nindex) index, \(nfree) free vblocks")
        var rebuilt: [Int: Int] = [:]
        for (t, arr) in tocFromIndex {
            for (i, vpn) in arr.enumerated() where vpn != unmapped { rebuilt[t * geo.tocEntries + i] = Int(vpn) }
        }
        ok(rebuilt == tocFromUser, "index pages map exactly the \(tocFromUser.count) user pages")
        func lpnData(_ lpn: Int) -> [UInt8]? { rebuilt[lpn].flatMap { st.readVPN($0)?.data } }

        let m0 = lpnData(0)
        ok(m0.map { $0[510] == 0x55 && $0[511] == 0xAA } ?? false, "LBA 0 carries an MBR")
        if let m0 {
            let parts = try partitions(mbr: m0)
            for (i, p) in parts.enumerated() where p.type != 0 {
                ok(
                    p.lba + p.count <= geo.exportedPages,
                    "partition \(i + 1) type \(String(format: "%02x", p.type)) lba \(p.lba) count \(p.count) inside exported size"
                )
                if p.type == 0xAF && p.count > 256 {
                    let sig = lpnData(p.lba).map { Array($0[1024..<1026]) }
                    ok(
                        sig == Array("H+".utf8) || sig == Array("HX".utf8),
                        "partition \(i + 1) has an HFS+ volume header"
                    )
                }
            }
            if let mbr {
                let src = [UInt8](try Data(contentsOf: mbr).prefix(512))
                let srcParts = try partitions(mbr: src)  // refuses a file shorter than an MBR
                ok(
                    Array(m0[..<0x1be]) == Array(src[..<0x1be]) && parts[0] == srcParts[0],
                    "LBA 0 matches \(mbr.lastPathComponent) (boot code + partition 1)"
                )
            }
            if let system {
                let (lba, cnt) = (parts[0].lba, parts[0].count)
                let f = try FileHandle(forReadingFrom: system)
                defer { try? f.close() }
                let sample = Array(0..<64) + Array(stride(from: 0, to: cnt, by: max(1, cnt / 512)))
                var bad = 0
                for n in sample {
                    try f.seek(toOffset: UInt64(n * geo.pageSize))
                    var want = [UInt8](try f.read(upToCount: geo.pageSize) ?? Data())
                    want += [UInt8](repeating: 0, count: geo.pageSize - want.count)
                    let got = lpnData(lba + n)
                    if got != want && !(got.map { Data($0).range(of: Data("/dev/disk0s2".utf8)) != nil } ?? false) {
                        bad += 1
                    }
                }
                ok(bad == 0, "\(sample.count) sampled system pages match \(system.lastPathComponent)")
            }
        }
        fails.forEach(log)
        log("\(dir.path): " + (fails.isEmpty ? "all checks passed" : "FAILED (\(fails.count))"))
        return fails.isEmpty
    }
}
