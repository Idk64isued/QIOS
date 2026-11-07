// N45FTL: the 1.x legacy FTL read back from a page store as the guest left it: an image store (PageNANDImage.s5l8900,
// the device's live clone in the overlay when there is one), or a format 1 bank<N>/<page>.page base plus the
// emulator's overlay of the same layout, blk<N>.erased markers honored. An erased page (every bit set) reads as none.
// The FTL's context is openiBoot's s5l8900 FTLCxt (the structure N45NAND.ftlMeta writes): the map's four 0x46 pages
// listed at +0x38, the log-offset pages at +0x110, the log table at +0x1A4 (20-byte entries: usn, vbn, lbn), the
// context blocks at +0x312. The context moves: the FTL takes new context blocks from its free pool (a booted M68 had it in
// virtual block 3), so the current one is found as the context-typed (0x43-0x4F) virtual block whose first page
// has the lowest usnDec, and its last written page must be the context itself (0x43); anything else is an
// unclean shutdown, which this reader refuses (that state needs FTL_Restore's scan).
//
//   let ftl = try N45FTL(base: nand, overlay: ovl)
//   ftl.read(lpn:)      // the logical page's 2048 bytes and spare, nil when it was never written
//   ftl.location(lpn:)  // where it lives now (a log block's page, or map[lbn] at the same offset)

import BinaryParsing
import Foundation

public struct N45FTL {
    static let logs = 17  // FTLCxt.pLog slots the FTL uses (the 18th is not)
    static let virtualBlocks = N45NAND.blocksPerBank - N45NAND.ftlStart

    public let banks: Int
    let page: @Sendable (N45NAND.Page) -> (data: [UInt8], spare: [UInt8])?
    let map: [UInt16]
    let logTable: [UInt16: (vbn: UInt16, slot: Int)]
    let offsets: [UInt16]

    public init(base: URL, overlay: URL?) throws {
        let image = try PageNANDImage.s5l8900(at: base)
        let banks = image.chips
        self.banks = banks
        let page = try Self.reader(image, base: base, overlay: overlay)
        self.page = page
        let sb = N45NAND.superblock(banks)
        let read = { (vpn: Int) in page(N45NAND.location(vpn: vpn, banks: banks)) }

        // A page's spare: the usn (a little-endian u32) at 0, the page type at 9.
        func spare(_ s: [UInt8]) throws -> (usn: UInt32, type: UInt8) {
            try parsing(s, "FTL spare") { p in (try p.le32(at: 0), try p.byte(at: 9)) }
        }
        var newest: (usn: UInt32, vb: Int)?
        for vb in 0..<Self.virtualBlocks {
            guard let (_, s) = read(vb * sb), case (let usn, let type) = try spare(s), (0x43...0x4F).contains(type)
            else {
                continue
            }
            if newest.map({ usn < $0.usn }) ?? true { newest = (usn, vb) }
        }
        guard let vb = newest?.vb else { throw FirmwareError(.unsupported, "\(base.path): no FTL context") }
        guard let last = (1..<sb).reversed().lazy.compactMap({ read(vb * sb + $0) }).first,
            try spare(last.spare).type == 0x43
        else {
            throw FirmwareError(
                .unsupported,
                "the 1.x FTL was not shut down cleanly (virtual block \(vb) does not end in its context); power the device off from the guest first"
            )
        }
        // The context page: the map pages' virtual page numbers at 0x38, the log-offset pages' at 0x110, the log
        // table at 0x1A4 (20-byte entries: usn, then the virtual and logical block numbers as u16s), the context
        // blocks at 0x312.
        let pages = (Self.logs * sb * 2 + N45NAND.page - 1) / N45NAND.page
        let (mapPages, offsetPages, logs, cxtBlocks) = try parsing(last.data, "FTL context") { s in
            func words(_ at: Int, _ n: Int) throws -> [Int] {
                var w = try s.seeking(toAbsoluteOffset: at)
                return try [UInt32](parsing: &w, count: n) { try UInt32(parsingLittleEndian: &$0) }.map(Int.init)
            }
            var table = try s.seeking(toAbsoluteOffset: 0x1A4)
            let logs = try (0..<Self.logs).map { _ in
                var entry = try table.sliceSpan(byteCount: 20)
                try entry.seek(toRelativeOffset: 4)
                return (vbn: try UInt16(parsingLittleEndian: &entry), lbn: try UInt16(parsingLittleEndian: &entry))
            }
            var blocks = try s.seeking(toAbsoluteOffset: 0x312)
            let cxt = try [UInt16](parsing: &blocks, count: 3) { try UInt16(parsingLittleEndian: &$0) }
            return (try words(0x38, N45NAND.mapTables), try words(0x110, pages), logs, cxt)
        }
        guard cxtBlocks.contains(where: { Int($0) == vb }) else {
            throw FirmwareError(
                .unsupported,
                "FTL context in virtual block \(vb) does not list itself as a context block"
            )
        }
        /// The little-endian u16s of the pages at these virtual page numbers.
        func halfwords(_ vpns: [Int], _ what: String) throws -> [UInt16] {
            var out: [UInt16] = []
            for (i, vpn) in vpns.enumerated() {
                guard let page = read(vpn)?.data else {
                    throw FirmwareError(.unsupported, "FTL \(what) page \(i) is missing")
                }
                out += try parsing(page, "FTL \(what) page") { s in
                    try [UInt16](parsing: &s, count: N45NAND.page / 2) { try UInt16(parsingLittleEndian: &$0) }
                }
            }
            return out
        }
        let map = try halfwords(mapPages, "map")
        var table: [UInt16: (UInt16, Int)] = [:]
        for (slot, log) in logs.enumerated() where log.vbn != 0xFFFF { table[log.lbn] = (log.vbn, slot) }
        var offsets: [UInt16] = []
        if !table.isEmpty {
            offsets = Array(try halfwords(offsetPages, "log-offset").prefix(Self.logs * sb))
            // a log block in use has its pages' offsets within the block, or 0xFFFF where a page was never logged
            let inUse = table.values.flatMap { offsets[$0.1 * sb..<($0.1 + 1) * sb] }
            guard inUse.allSatisfy({ $0 == 0xFFFF || Int($0) < sb }) else {
                throw FirmwareError(.unsupported, "FTL log offsets in virtual block \(vb) run past their log blocks")
            }
        }
        self.map = map
        self.logTable = table
        self.offsets = offsets
    }

    public var logBlocksInUse: Int { logTable.count }

    /// The logical pages the FTL's map covers.
    public var logicalPages: Int { map.count * N45NAND.superblock(banks) }

    /// Where logical page `lpn` lives now; nil past the map.
    public func location(lpn: Int) -> N45NAND.Page? {
        guard (0..<logicalPages).contains(lpn) else { return nil }
        let sb = N45NAND.superblock(banks)
        let (lbn, off) = lpn.quotientAndRemainder(dividingBy: sb)
        if let log = logTable[UInt16(lbn)] {
            let o = offsets[log.slot * sb + off]
            if o != 0xFFFF { return N45NAND.location(vpn: Int(log.vbn) * sb + Int(o), banks: banks) }
        }
        return N45NAND.location(vpn: Int(map[lbn]) * sb + off, banks: banks)
    }

    /// The logical page's 2048 bytes and spare; nil when it was never written or is past the map.
    public func read(lpn: Int) -> (data: [UInt8], spare: [UInt8])? { location(lpn: lpn).flatMap(page) }

    /// Pages as the guest reads them (PageNANDImage.reader); nil for an erased or unreadable page.
    static func reader(_ image: PageNANDImage, base: URL, overlay: URL?) throws
        -> @Sendable (N45NAND.Page) -> (data: [UInt8], spare: [UInt8])?
    {
        let read = try image.reader(base: base, overlay: overlay)
        let blank = image.blankRecord
        return { p in
            guard let record = try? read(.init(chip: p.bank, page: p.page)), record != blank else { return nil }
            return (Array(record[0..<N45NAND.page]), Array(record[N45NAND.page...]))
        }
    }
}
