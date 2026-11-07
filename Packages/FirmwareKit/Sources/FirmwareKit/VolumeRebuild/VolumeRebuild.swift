// VolumeRebuild: a stopped device's logical HFS+ volumes, rebuilt from its read-only base plus its NAND
// overlay into sparse raw images. Nothing here opens a store for writing.
//
//   let vols = try VolumeRebuild.rebuild(base: nand, overlay: ovl, into: dir)          // every volume
//   try VolumeRebuild.rebuild(base: nand, overlay: ovl, into: dir, only: ["system"])
//
// iPod (n72, base = an image store, N72NANDImage, or cs<N>/<page>.page): the emulator stores every guest write where
// its logical block lives in the generated layout (ipod_touch_fmss.c fmss_generated_layout, ftlmap.predict), so the
// volume is dumpvol.py over the store as the guest reads it: an image's live clone (overlay/nand) or the image alone;
// overlay/cs<N>/<page>.page over a page directory, blk<B>.erased markers (written and honored only under FMSS_ERASE)
// reading as blank.
// One volume, "system" (the generated image keeps /private/var on it).
//
// legacy (n45/m68, base = an image store, PageNANDImage.s5l8900, or bank<N>/<page>.page): iPhone OS 1.x's FTL as the guest left it (N45FTL: its context's
// map and log blocks over base + overlay). One volume, "system". A device not shut down cleanly is refused.
//
// iPad (k48 and the other kboot boards, base = geometry.json + bus<b>-ce<c>.pages; the S5L8920 boards' meta unwhitened,
// as their NANDDRIVERSIGN flags say): a YaFTL read-only restore over base + overlay
// (the .dirty bitmap picks the source): every vblock is walked through the VFL until its first blank
// page; each user page's copy with the highest (USN, vpn) wins; index pages, BTOCs and the control
// vblocks (the CX01 context) are ignored. MBR partition 1 is "system", 2 is "data".

import Foundation

public enum VolumeRebuild {
    public struct Volume: Sendable, Codable, Equatable {
        public let name: String
        public let image: URL
        public let bytes: Int
        /// 4 KiB pages written into the (otherwise sparse) image.
        public let pagesWritten: Int
    }

    public enum Board: String, Sendable { case ipod, ipad, legacy }

    public static func board(of base: URL) throws -> Board {
        let fm = FileManager.default
        if let image = PageNANDImage.of(base) { return image == .n72 ? .ipod : .legacy }
        if fm.fileExists(atPath: base.appendingPathComponent("geometry.json").path) { return .ipad }
        if fm.fileExists(atPath: base.appendingPathComponent("cs0").path) { return .ipod }
        if fm.fileExists(atPath: base.appendingPathComponent("bank0").path) { return .legacy }
        throw FirmwareError(
            .unsupported,
            "\(base.path): neither an iPad store (geometry.json) nor an iPod page directory (cs0/ or bank0/)"
        )
    }

    /// Rebuilds the volumes named in `only` (all when nil) into `<dir>/<name>.img`.
    public static func rebuild(base: URL, overlay: URL?, into dir: URL, only: Set<String>? = nil) throws -> [Volume] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        switch try board(of: base) {
        case .ipod: return try iPod(base: base, overlay: overlay, into: dir, only: only)
        case .ipad: return try iPad(base: base, overlay: overlay, into: dir, only: only)
        case .legacy: return try legacy(base: base, overlay: overlay, into: dir, only: only)
        }
    }

    // MARK: iPod

    static let page = 4096

    /// ftlmap.predict: HFS+ allocation block n (device LBA n + 3) -> physical (cs, page).
    static func predict(_ n: Int) -> (cs: Int, page: Int) {
        let (r, cs) = (n + 3).quotientAndRemainder(dividingBy: 4)
        let eb = 2 * (r / 256) + 2 + (r % 2)
        return (cs, eb * 128 + (r % 256) / 2)
    }

    static func iPod(base: URL, overlay: URL?, into dir: URL, only: Set<String>?) throws -> [Volume] {
        guard only.map({ $0.contains("system") }) ?? true else {
            throw FirmwareError(.unsupported, "the iPod has one volume, system (/private/var is on it)")
        }
        let store = try N72NANDImage.reader(base: base, overlay: overlay)
        /// Block `n` into `buf`; false for a blank or absent page.
        @Sendable func read(_ n: Int, into buf: inout [UInt8]) throws -> Bool {
            let (cs, pg) = predict(n)
            let record = try store(N72NAND.Page(cs: cs, page: pg))
            buf.replaceSubrange(0..<page, with: record[0..<page])
            return buf.contains { $0 != 0 }
        }

        // The volume's own size, not a legacy overlong GPT partition's: macOS looks for the
        // alternate volume header 1 KiB before the end of the device.
        var header = [UInt8](repeating: 0, count: page)
        guard try read(0, into: &header), let bytes = try HFSPlusVolume.headerBytes(header, at: 1024) else {
            throw FirmwareError(.unsupported, "\(base.path): no HFS+ volume header at block 0")
        }
        let blocks = bytes / page
        // the guest's header says the size: its last block must be one the FTL lays out below the bad-block table
        guard blocks == 0 || N72NAND.predict(blocks - 1).page < N72NAND.bbtPage else {
            throw FirmwareError(.unsupported, "\(base.path): the volume header claims \(bytes) bytes, past the NAND")
        }

        let out = dir.appendingPathComponent("system.img")
        let fd = try create(out, bytes: blocks * page)
        defer { close(fd) }
        // A page directory is one small file per page: the open/read/close per block is the cost, so blocks are read in parallel
        // (each worker its own buffer; pwrite at distinct offsets).
        let workers = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        final class Tally: @unchecked Sendable {
            let lock = NSLock()
            var written = 0
            var failure: Error?
        }
        let tally = Tally()
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            var buf = [UInt8](repeating: 0, count: page)
            var count = 0
            do {
                for n in stride(from: w, to: blocks, by: workers) where try read(n, into: &buf) {
                    try pwriteAll(fd, buf, n * page, out)
                    count += 1
                }
            } catch { tally.lock.withLock { tally.failure = tally.failure ?? error } }
            tally.lock.withLock { tally.written += count }
        }
        if let failure = tally.failure { throw failure }
        let written = tally.written
        return [Volume(name: "system", image: out, bytes: blocks * page, pagesWritten: written)]
    }

    // MARK: legacy (1.x)

    static func legacy(base: URL, overlay: URL?, into dir: URL, only: Set<String>?) throws -> [Volume] {
        guard only.map({ $0.contains("system") }) ?? true else {
            throw FirmwareError(.unsupported, "a 1.x device has one volume, system (/private/var is on it)")
        }
        let ftl = try N45FTL(base: base, overlay: overlay)
        let first = N45NAND.firstLBA
        let ps = N45NAND.page
        guard let vh = ftl.read(lpn: first)?.data, let bytes = try HFSPlusVolume.headerBytes(vh, at: 1024) else {
            throw FirmwareError(.unsupported, "\(base.path): no HFS+ volume header at logical page \(first)")
        }
        // the guest's header says the size: it must be what the FTL maps from the volume's first page
        guard bytes <= (ftl.logicalPages - first) * ps else {
            throw FirmwareError(
                .unsupported,
                "\(base.path): the volume header claims \(bytes) bytes, past the \((ftl.logicalPages - first) * ps) the FTL maps"
            )
        }
        let out = dir.appendingPathComponent("system.img")
        let fd = try create(out, bytes: bytes)
        defer { close(fd) }
        var written = 0
        for i in 0..<bytes / ps {
            guard let d = ftl.read(lpn: first + i)?.data, d.contains(where: { $0 != 0 }) else { continue }
            try pwriteAll(fd, d, i * ps, out)
            written += 1
        }
        return [Volume(name: "system", image: out, bytes: bytes, pagesWritten: written)]
    }

    // MARK: iPad

    static func iPad(base: URL, overlay: URL?, into dir: URL, only: Set<String>?) throws -> [Volume] {
        let geo = try K48NAND.geometry(store: base)
        let st = try K48NAND.StoreReader(base, geo: geo, overlay: overlay)
        let map = yaftlMap(st)
        func data(_ lpn: Int) -> [UInt8]? {
            guard lpn < map.count, map[lpn] != 0 else { return nil }
            let (cs, pp) = geo.vpnToPhys(Int(map[lpn] - 1))
            return st.read(cs, pp)?.data
        }
        guard let mbr = data(0), mbr[510] == 0x55, mbr[511] == 0xAA else {
            throw FirmwareError(.unsupported, "\(base.path): LBA 0 carries no MBR")
        }
        let parts = try K48NAND.partitions(mbr: mbr)
        var vols: [Volume] = []
        for (name, p) in [("system", parts[0]), ("data", parts[1])]
        where p.type != 0 && only.map({ $0.contains(name) }) ?? true {
            // the guest's MBR places the partition: it must lie in the pages the FTL exports
            guard p.lba + p.count <= geo.exportedPages else {
                throw FirmwareError(
                    .unsupported,
                    "\(base.path): the \(name) partition (LBA \(p.lba), \(p.count) pages) runs past the \(geo.exportedPages) exported"
                )
            }
            let out = dir.appendingPathComponent("\(name).img")
            let fd = try create(out, bytes: p.count * geo.pageSize)
            defer { close(fd) }
            var written = 0
            for i in 0..<p.count {
                guard let d = data(p.lba + i), d.contains(where: { $0 != 0 }) else { continue }
                try pwriteAll(fd, d, i * geo.pageSize, out)
                written += 1
            }
            vols.append(Volume(name: name, image: out, bytes: p.count * geo.pageSize, pagesWritten: written))
        }
        return vols
    }

    /// lpn -> vpn + 1 (0 = unmapped) of the newest copy of every user page.
    static func yaftlMap(_ st: K48NAND.StoreReader) -> [UInt32] {
        let geo = st.geo
        var vpnOf = [UInt32](repeating: 0, count: geo.totalPages)
        var usnOf = [UInt32](repeating: 0, count: geo.totalPages)
        for v in 0..<geo.numBlocks where !geo.ctrlBlocks.contains(v) {
            for j in 0..<geo.ppsublk {
                let vpn = v * geo.ppsublk + j
                let (cs, pp) = geo.vpnToPhys(vpn)
                guard let m = st.meta(cs, pp) else { break }  // pages of a vblock are programmed in order
                let typ = m[9]
                guard typ & K48NAND.tUser != 0, typ & (K48NAND.tIndex | K48NAND.tClosed) == 0 else { continue }
                // the spare's lpn and usn, little-endian u32s
                guard let lpn = (try? le32(m, 0)).map(Int.init), let usn = try? le32(m, 4), lpn < geo.totalPages else {
                    continue
                }
                // equal USN: the later vpn (a later page of the same block) wins
                if vpnOf[lpn] == 0 || usn > usnOf[lpn] || (usn == usnOf[lpn] && UInt32(vpn + 1) > vpnOf[lpn]) {
                    vpnOf[lpn] = UInt32(vpn + 1)
                    usnOf[lpn] = usn
                }
            }
        }
        return vpnOf
    }

    // MARK: helpers

    /// A new sparse file of `bytes`, open for writing.
    static func create(_ u: URL, bytes: Int) throws -> Int32 {
        let fd = open(u.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0, ftruncate(fd, off_t(bytes)) == 0 else {
            if fd >= 0 { close(fd) }
            throw FirmwareError(
                errno == ENOSPC ? .diskFull : .internal,
                "\(u.path): \(String(cString: strerror(errno)))"
            )
        }
        return fd
    }

    static func pwriteAll(_ fd: Int32, _ b: [UInt8], _ off: Int, _ u: URL) throws {
        let n = b.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(off)) }
        guard n == b.count else {
            throw FirmwareError(
                errno == ENOSPC ? .diskFull : .internal,
                "\(u.path): \(String(cString: strerror(errno)))"
            )
        }
    }
}
