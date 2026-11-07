// HFSPlusWriter's whole-volume operations: a fresh volume (what newfs_hfs -s [-J] makes) and growing one to fill a
// larger partition (what an attached resize does), both without a device.

import Foundation

extension HFSPlusWriter {
    /// A bare case-sensitive HFSX volume named `name` in a sparse raw file of `size` bytes (rounded down to 4 KiB):
    /// header, allocation bitmap, empty extents and attributes B-trees, a catalog of the root folder and, when
    /// `journaled`, an empty journal the device's kernel initializes at its first mount (kJIJournalNeedInitMask, as
    /// newfs_hfs leaves one) with its .journal and .journal_info_block files. Owned by this process's user, dated
    /// `date`, identified by `uuid` (the Finder-info volume identifier; newfs_hfs draws a random one).
    public static func makeHFS(
        _ image: URL,
        size: Int64,
        name: String = "Data",
        journaled: Bool = true,
        date: UInt32 = 0,
        uuid: [UInt8] = [UInt8](repeating: 0, count: 8)
    ) throws {
        let bs = 4096
        let bytes = Int(size) / bs * bs
        let total = bytes / bs
        guard total >= 1024 else { throw FirmwareError(.internal, "an HFS+ volume of \(bytes) bytes is too small") }
        guard FileManager.default.createFile(atPath: image.path, contents: nil), truncate(image.path, off_t(bytes)) == 0
        else { throw FirmwareError(.internal, "cannot create \(image.path)") }
        // ponytail: sizes chosen here, not newfs_hfs's tables; the kernel grows the B-trees and journal as needed
        let treeBytes = min(max(bytes / 2048, 512 << 10), 8 << 20) / 8192 * 8192
        let journalBytes = bytes >= 128 << 20 ? 8 << 20 : 512 << 10  // newfs_hfs's sizes
        let bitmapBlocks = ((total + 7) / 8 + bs - 1) / bs
        var next = 1
        func take(_ n: Int) -> (start: Int, count: Int) {
            defer { next += n }
            return (next, n)
        }
        let alloc = take(bitmapBlocks)
        let jib = journaled ? take(1) : (start: 0, count: 0)
        let journal = journaled ? take(journalBytes / bs) : (start: 0, count: 0)
        let ext = take(treeBytes / bs)
        let attr = take(treeBytes / bs)
        let cat = take(treeBytes / bs)

        var vh = [UInt8](repeating: 0, count: 512)
        vh[0] = 0x48
        vh[1] = 0x58
        putBE16(&vh, 2, 5)
        putBE32(&vh, 4, 0x8000_0100 | (journaled ? 1 << 13 : 0))  // kHFSUnusedNodeFix, unmounted, journaled
        vh.replaceSubrange(8..<12, with: Array("10.0".utf8))
        putBE32(&vh, 12, UInt32(jib.start))
        for o in [16, 20, 28] { putBE32(&vh, o, date) }
        putBE32(&vh, 32, journaled ? 2 : 0)
        putBE32(&vh, 40, UInt32(bs))
        putBE32(&vh, 44, UInt32(total))
        putBE32(&vh, 52, UInt32(next))
        putBE32(&vh, 56, 65536)
        putBE32(&vh, 60, 65536)
        putBE32(&vh, 64, journaled ? 18 : 16)
        putBE64(&vh, 72, 1)  // encodingsBitmap: MacRoman
        vh.replaceSubrange(104..<112, with: uuid.prefix(8))
        func fork(_ o: Int, _ e: (start: Int, count: Int), clump: Int) {
            putBE64(&vh, o, UInt64(e.count * bs))
            putBE32(&vh, o + 8, UInt32(clump))
            putBE32(&vh, o + 12, UInt32(e.count))
            putBE32(&vh, o + 16, UInt32(e.start))
            putBE32(&vh, o + 20, UInt32(e.count))
        }
        fork(112, alloc, clump: alloc.count * bs)
        fork(192, ext, clump: treeBytes)
        fork(272, cat, clump: treeBytes)
        fork(352, attr, clump: treeBytes)

        let fd = open(image.path, O_RDWR)
        guard fd >= 0 else { throw FirmwareError(.internal, "open \(image.path)") }
        defer { Darwin.close(fd) }
        func write(_ b: [UInt8], at: Int) throws {
            guard pwrite(fd, b, b.count, off_t(at)) == b.count else {
                throw FirmwareError(.internal, "write \(image.lastPathComponent) at \(at)")
            }
        }
        var bitmap = [UInt8](repeating: 0, count: bitmapBlocks * bs)
        for b in 0..<next { bitmap[b / 8] |= 0x80 >> UInt8(b % 8) }
        bitmap[(total - 1) / 8] |= 0x80 >> UInt8((total - 1) % 8)  // the alternate volume header's block
        try write(bitmap, at: alloc.start * bs)

        let extents = BTreeFile(
            nodeSize: 4096,
            maxKeyLength: 10,
            clumpSize: UInt32(treeBytes),
            attributes: BTreeFile.bigKeys,
            compare: BTreeFile.extentsOrder
        )
        try write(try extents.layout(totalNodes: treeBytes / 4096), at: ext.start * bs)
        let attributes = BTreeFile(
            nodeSize: 8192,
            maxKeyLength: 266,
            clumpSize: UInt32(treeBytes),
            attributes: BTreeFile.bigKeys | BTreeFile.variableIndexKeys,
            compare: BTreeFile.attributesOrder
        )
        try write(try attributes.layout(totalNodes: treeBytes / 8192), at: attr.start * bs)

        var catalog = BTreeFile(
            nodeSize: 8192,
            maxKeyLength: 516,
            clumpSize: UInt32(treeBytes),
            keyCompareType: 0xBC,
            attributes: BTreeFile.bigKeys | BTreeFile.variableIndexKeys,
            compare: BTreeFile.catalogOrder
        )
        func key(_ parent: UInt32, _ name: [UInt16]) -> [UInt8] {
            var k = [UInt8](repeating: 0, count: 8 + 2 * name.count)
            putBE16(&k, 0, UInt16(6 + 2 * name.count))
            putBE32(&k, 2, parent)
            putBE16(&k, 6, UInt16(name.count))
            for (i, u) in name.enumerated() { putBE16(&k, 8 + 2 * i, u) }
            return k
        }
        func thread(_ type: UInt16, _ parent: UInt32, _ name: [UInt16]) -> [UInt8] {
            var t = [UInt8](repeating: 0, count: 10 + 2 * name.count)
            putBE16(&t, 0, type)
            putBE32(&t, 4, parent)
            putBE16(&t, 8, UInt16(name.count))
            for (i, u) in name.enumerated() { putBE16(&t, 10 + 2 * i, u) }
            return t
        }
        let volumeName = HFSUnicode.catalogName(name)
        var root = [UInt8](repeating: 0, count: 88)
        putBE16(&root, 0, folderType)
        putBE16(&root, 2, hasFolderCount)
        putBE32(&root, 4, journaled ? 2 : 0)
        putBE32(&root, 8, rootID)
        for i in 0..<4 { putBE32(&root, 12 + 4 * i, date) }
        putBE32(&root, 32, getuid())
        putBE32(&root, 36, getgid())
        putBE16(&root, 42, 0o40755)
        putBE32(&root, 80, 126)  // kTextEncodingMacUnicode, as newfs_hfs writes the root's
        catalog[key(1, volumeName)] = root
        catalog[key(rootID, [])] = thread(folderThread, 1, volumeName)
        if journaled {
            for (id, file, e) in [(16, ".journal", journal), (17, ".journal_info_block", jib)] {
                var r = [UInt8](repeating: 0, count: 248)
                putBE16(&r, 0, fileType)
                putBE16(&r, 2, threadExists)
                putBE32(&r, 8, UInt32(id))
                // created and modified, as newfs_hfs dates them (attribute-modified and accessed stay 0)
                for i in 0..<2 { putBE32(&r, 12 + 4 * i, date) }
                putBE16(&r, 42, 0o100000)
                putBE32(&r, 44, 1)
                putBE32(&r, 48, 0x6A72_6E6C)  // 'jrnl'
                putBE32(&r, 52, 0x6866_732B)  // 'hfs+'
                putBE16(&r, 56, 0x5000)  // kIsInvisible + kNameLocked
                putBE64(&r, 88, UInt64(e.count * bs))
                putBE32(&r, 100, UInt32(e.count))
                putBE32(&r, 104, UInt32(e.start))
                putBE32(&r, 108, UInt32(e.count))
                catalog[key(rootID, Array(file.utf16))] = r
                catalog[key(UInt32(id), [])] = thread(fileThread, rootID, Array(file.utf16))
            }
            // the journal info block: in this volume, to be initialized; the journal's offset and size
            var info = [UInt8](repeating: 0, count: bs)
            putBE32(&info, 0, 1 | 4)
            putBE64(&info, 36, UInt64(journal.start * bs))
            putBE64(&info, 44, UInt64(journalBytes))
            try write(info, at: jib.start * bs)
        }
        try write(try catalog.layout(totalNodes: treeBytes / 8192), at: cat.start * bs)
        putBE32(&vh, 48, UInt32(total - next - 1))
        try write(vh, at: 1024)
        try write(vh, at: bytes - 1024)
    }

    /// Grows the volume in `image` to fill `bytes` (a multiple of 4096): the file padded, the allocation bitmap
    /// extended (its file grown when it must be), the volume's last whole block reserved for the alternate header,
    /// which moves to the new end - 1024. A volume already that size is left alone.
    public static func grow(_ image: URL, toBytes bytes: Int) throws {
        let w = try HFSPlusWriter(image)
        try w.grow(toBytes: bytes)
        try w.close()
    }
}
