// A page-directory board's NAND as an image store (record format 2), which qemu-ios writes in place
// (hw/arm/nand-image.c): geometry.json and cs0.pages ... cs<N-1>.pages, the record of page p of a chip at p * stride,
// data then spare, stored XOR the board's blank record, so a hole reads as the blank page. Two boards keep their
// format 1 stores as page directories (<prefix><N>/<page>.page under an overlay of the same layout), and both move
// to this store with the same steps:
//
//   .n72                  the iPod touch 2G (ipod_touch_fmss.c): 4 chip selects of 4096 + 64-byte pages, the generated
//                         layout's blank (zero data, spare bytes 8 and 10 0xFF: fmss_blank_page); format 1 cs<N>/
//   .s5l8900(banks:)      the iPod touch 1G (8 banks) and the original iPhone (4) (s5l8900_fmc.c): 2048 + 64-byte
//                         pages, blank all 0xFF, as the chip erases; format 1 bank<N>/
//
// LegacyReader reads format 1 as the emulator served it; convert and verify are the halves of its migration
// (K48NANDMigration).
//
//   let store = try PageNANDImage.Store(create: dir, .n72)        // geometry.json and sparse chip files
//   try store.write(chip, page, record); try store.sync()
//   let read = try image.reader(base: nand, overlay: overlay)     // either format, as the guest reads it

import Darwin
import Foundation

public struct PageNANDImage: Sendable, Equatable {
    public static let format = "nand-xor-blank-v2"
    /// geometry.json's "board", "blank" and (n72) "layout".
    let board: String, blank: String, layout: String?
    /// The format 1 page directories' prefix: cs<N> or bank<N>.
    let prefix: String
    let chips: Int, page: Int, spare: Int, pagesPerBlock: Int, blocksPerChip: Int
    /// What a hole reads as, and the XOR key of every stored record.
    let blankRecord: [UInt8]

    var stride: Int { page + spare }
    var blockBytes: Int { pagesPerBlock * stride }
    var chipBytes: Int { blocksPerChip * blockBytes }
    var pagesPerChip: Int { blocksPerChip * pagesPerBlock }

    public static let n72 = PageNANDImage(
        board: "n72ap",
        blank: "n72-generated",
        layout: "n72-generated-v1",
        prefix: "cs",
        chips: 4,
        page: N72NAND.page,
        spare: N72NAND.spare,
        pagesPerBlock: N72NAND.pagesPerBlock,
        blocksPerChip: 4096,
        blankRecord: [UInt8](repeating: 0, count: N72NAND.page) + N72NAND.blankSpare
    )

    public static func s5l8900(banks: Int) -> PageNANDImage {
        PageNANDImage(
            board: "s5l8900",
            blank: "ff",
            layout: nil,
            prefix: "bank",
            chips: banks,
            page: N45NAND.page,
            spare: N45NAND.spare,
            pagesPerBlock: N45NAND.pagesPerBlock,
            blocksPerChip: N45NAND.blocksPerBank,
            blankRecord: [UInt8](repeating: 0xFF, count: N45NAND.page + N45NAND.spare)
        )
    }

    /// The 1.x store at `nand`: its image geometry, else as many banks as its format 1 page directories.
    static func s5l8900(at nand: URL) throws -> PageNANDImage {
        if let image = of(nand), image.board == "s5l8900" { return image }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: nand.path)) ?? []
        let banks = (0..<N45NAND.banks).prefix { names.contains("bank\($0)") }.count
        guard banks > 0 else { throw FirmwareError(.unsupported, "\(nand.path): no bank<N> page directories") }
        return s5l8900(banks: banks)
    }

    static func name(_ chip: Int) -> String { "cs\(chip).pages" }

    func geometry() throws -> Data {
        var g: [String: Any] = [
            "storage_format": Self.format, "blank": blank, "board": board, "chip_selects": chips, "page_bytes": page,
            "spare_bytes": spare, "pages_per_block": pagesPerBlock, "blocks_per_ce": blocksPerChip
        ]
        if let layout { g["layout"] = layout }
        return try JSONSerialization.data(withJSONObject: g, options: [.sortedKeys, .prettyPrinted])
    }

    /// The image store `nand` holds, by its geometry.json; nil for anything else.
    public static func of(_ nand: URL) -> PageNANDImage? {
        guard
            let g = (try? Data(contentsOf: nand.appendingPathComponent("geometry.json")))
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
            g["storage_format"] as? String == format
        else { return nil }
        let image: PageNANDImage? =
            switch (g["board"] as? String, g["blank"] as? String) {
            case ("n72ap", "n72-generated"): .n72
            case ("s5l8900", "ff"):
                (g["chip_selects"] as? Int).flatMap { [4, 8].contains($0) ? s5l8900(banks: $0) : nil }
            default: nil
            }
        guard let image, g["chip_selects"] as? Int == image.chips, g["page_bytes"] as? Int == image.page,
            g["spare_bytes"] as? Int == image.spare, g["pages_per_block"] as? Int == image.pagesPerBlock,
            g["blocks_per_ce"] as? Int == image.blocksPerChip
        else { return nil }
        return image
    }

    /// The nonzero 8-byte words of the blank record, by index: what XOR touches.
    var blankWords: [(Int, UInt64)] {
        blankRecord.withUnsafeBytes { raw in
            (0..<stride / 8).compactMap { i in
                let w = raw.loadUnaligned(fromByteOffset: 8 * i, as: UInt64.self)
                return w == 0 ? nil : (i, w)
            }
        }
    }

    /// Whole records in `buffer` XOR the blank record: stored to read, or back.
    func xor(_ buffer: inout [UInt8], words: [(Int, UInt64)]) {
        let per = stride / 8
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for r in Swift.stride(from: 0, to: raw.count / 8, by: per) {
                for (i, w) in words {
                    let at = base + 8 * (r + i)
                    at.storeBytes(of: at.loadUnaligned(as: UInt64.self) ^ w, as: UInt64.self)
                }
            }
        }
    }

    /// A page of a chip.
    struct Address: Hashable, Sendable {
        let chip: Int, page: Int
    }

    /// One store's chip files, open.
    final class Store: @unchecked Sendable {  // pread and pwrite at distinct offsets
        let image: PageNANDImage
        let fds: [Int32]
        let url: URL
        private let words: [(Int, UInt64)]

        /// `dir` (created, with its geometry and sized empty chip files) open for writing.
        convenience init(create dir: URL, _ image: PageNANDImage) throws {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            try image.geometry().write(to: dir.appendingPathComponent("geometry.json"))
            try self.init(dir, writable: true, create: true)
        }

        init(_ dir: URL, writable: Bool = false, create: Bool = false) throws {
            guard let image = PageNANDImage.of(dir) else {
                throw FirmwareError(.unsupported, "\(dir.path): not a NAND image store")
            }
            self.image = image
            words = image.blankWords
            url = dir
            var fds: [Int32] = []
            for chip in 0..<image.chips {
                let path = dir.appendingPathComponent(PageNANDImage.name(chip)).path
                let fd = Darwin.open(path, writable ? O_RDWR | (create ? O_CREAT | O_EXCL : 0) : O_RDONLY, 0o644)
                var st = stat()
                guard fd >= 0, !create || ftruncate(fd, off_t(image.chipBytes)) == 0, fstat(fd, &st) == 0 else {
                    let why = String(cString: strerror(errno))
                    if fd >= 0 { Darwin.close(fd) }
                    for fd in fds { Darwin.close(fd) }
                    throw FirmwareError(.internal, "\(path): \(why)")
                }
                fds.append(fd)
                guard Int(st.st_size) == image.chipBytes else {
                    for fd in fds { Darwin.close(fd) }
                    throw FirmwareError(.unsupported, "\(path): NAND file size differs from geometry")
                }
            }
            self.fds = fds
        }

        deinit { for fd in fds { Darwin.close(fd) } }

        /// The page's record as the emulator reads it.
        func read(_ chip: Int, _ page: Int) throws -> [UInt8] {
            var record = [UInt8](repeating: 0, count: image.stride)
            try K48NANDImage.read(fds[chip], &record, at: page * image.stride)
            image.xor(&record, words: words)
            return record
        }

        /// The records of one erase block as they read.
        func readBlock(_ chip: Int, _ block: Int, into buffer: inout [UInt8]) throws {
            try K48NANDImage.read(fds[chip], &buffer, at: block * image.blockBytes)
            image.xor(&buffer, words: words)
        }

        func write(_ chip: Int, _ page: Int, _ record: [UInt8]) throws {
            var stored = record
            image.xor(&stored, words: words)
            try K48NANDImage.write(fds[chip], stored[...], at: page * image.stride)
        }

        func sync() throws {
            for fd in fds where fsync(fd) != 0 {
                throw FirmwareError(.internal, "\(url.path): \(String(cString: strerror(errno)))")
            }
        }

        /// Gives back the zeros APFS filled in around `chip`'s writes (K48NANDImage.compact).
        func compact(_ chip: Int) throws {
            try K48NANDImage.compact(fds[chip], path: url.appendingPathComponent(PageNANDImage.name(chip)).path)
        }

        /// Erase blocks of `chip` holding data (SEEK_DATA; APFS zero-fills holes under 16 MiB, which read blank).
        func dataBlocks(_ chip: Int) -> Set<Int> { K48NANDImage.dataBlocks(fds[chip], blockBytes: image.blockBytes) }
    }

    // MARK: Format 1

    /// The page directory under its overlay, as the emulator read it: a page from the overlay's file when there is
    /// one, else blank when the overlay marks its block erased (blk<B>.erased), else the base's file, else blank. A
    /// short file reads zero-filled.
    struct LegacyReader {
        let image: PageNANDImage
        let base: URL
        let overlay: URL?
        let baseNames: [Set<String>]
        let overlayNames: [Set<String>]

        init(_ image: PageNANDImage, base: URL, overlay: URL?) {
            let fm = FileManager.default
            func names(_ d: URL?, _ chip: Int) -> Set<String> {
                guard let d else { return [] }
                return Set((try? fm.contentsOfDirectory(atPath: image.directory(d, chip).path)) ?? [])
            }
            self.image = image
            self.base = base
            self.overlay = overlay
            baseNames = (0..<image.chips).map { names(base, $0) }
            overlayNames = (0..<image.chips).map { names(overlay, $0) }
        }

        /// Every page some file names (in the base or the overlay), and every page of a marked block.
        var pages: Set<Address> {
            var out = Set<Address>()
            for chip in 0..<image.chips {
                for name in baseNames[chip].union(overlayNames[chip]) {
                    if let page = Self.page(name) { out.insert(Address(chip: chip, page: page)) }
                    if let block = Self.erased(name), overlayNames[chip].contains(name) {
                        for p in block * image.pagesPerBlock..<(block + 1) * image.pagesPerBlock {
                            out.insert(Address(chip: chip, page: p))
                        }
                    }
                }
            }
            return out
        }

        static func page(_ name: String) -> Int? {
            guard name.hasSuffix(".page"), !name.hasPrefix(".") else { return nil }
            return Int(name.dropLast(5))
        }

        static func erased(_ name: String) -> Int? {
            guard name.hasPrefix("blk"), name.hasSuffix(".erased") else { return nil }
            return Int(name.dropFirst(3).dropLast(7))
        }

        func file(_ a: Address) -> URL? {
            let name = "\(a.page).page"
            if let overlay, overlayNames[a.chip].contains(name) {
                return image.directory(overlay, a.chip).appendingPathComponent(name)
            }
            if overlayNames[a.chip].contains("blk\(a.page / image.pagesPerBlock).erased") { return nil }
            return baseNames[a.chip].contains(name) ? image.directory(base, a.chip).appendingPathComponent(name) : nil
        }

        /// The page's record (data and spare) as the guest read it.
        func read(_ a: Address) throws -> [UInt8] {
            guard let url = file(a) else { return image.blankRecord }
            var record = [UInt8](repeating: 0, count: image.stride)
            let fd = Darwin.open(url.path, O_RDONLY)
            guard fd >= 0 else { throw FirmwareError(.internal, "\(url.path): \(String(cString: strerror(errno)))") }
            defer { Darwin.close(fd) }
            let got = record.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
            guard got >= 0 else { throw FirmwareError(.internal, "\(url.path): \(String(cString: strerror(errno)))") }
            return record
        }
    }

    /// A format 1 chip's page directory under `root`.
    func directory(_ root: URL, _ chip: Int) -> URL { root.appendingPathComponent("\(prefix)\(chip)") }

    /// A store of either format read as the guest reads it: an image's live clone (`overlay/nand`) when there is
    /// one, else the image alone; a page directory under `overlay`.
    func reader(base: URL, overlay: URL?) throws -> @Sendable (Address) throws -> [UInt8] {
        if Self.of(base) == self {
            let live = overlay?.appendingPathComponent("nand")
            let store = try Store(live.map { Self.of($0) == self ? $0 : base } ?? base)
            // a page in no data extent is a hole: blank without a read (a volume is mostly holes)
            let data = (0..<chips).map { store.dataBlocks($0) }
            let blank = blankRecord
            let pagesPerBlock = pagesPerBlock
            return { data[$0.chip].contains($0.page / pagesPerBlock) ? try store.read($0.chip, $0.page) : blank }
        }
        let legacy = LegacyReader(self, base: base, overlay: overlay)
        return { try legacy.read($0) }
    }

    // MARK: Migration

    /// The overlay's page directories: what goes when a device leaves format 1.
    func overlayFiles(_ overlay: URL) -> [String] {
        (0..<chips).map { "\(prefix)\($0)" }.filter {
            FileManager.default.fileExists(atPath: overlay.appendingPathComponent($0).path)
        }
    }

    /// Whether `overlay` holds any page or erase marker, so the live NAND differs from the base.
    func overlayServes(_ overlay: URL?) -> Bool {
        guard let overlay else { return false }
        return LegacyReader(self, base: overlay, overlay: overlay).overlayNames.contains {
            $0.contains { LegacyReader.page($0) != nil || LegacyReader.erased($0) != nil }
        }
    }

    /// `base` (a page directory) as an image store at `baseOut`, and `liveOut` (when `overlay` serves pages): a clone
    /// of `baseOut` with the overlay applied, as the emulator read it. `step` after each chip (base, then live).
    func convert(base: URL, overlay: URL?, baseOut: URL, liveOut: URL?, step: () -> Void = {}) throws {
        let legacy = LegacyReader(self, base: base, overlay: nil)
        do {
            let store = try Store(create: baseOut, self)
            for chip in 0..<chips {
                defer { step() }  // a chip done: the migration's progress
                for name in legacy.baseNames[chip] {
                    guard let page = LegacyReader.page(name) else { continue }
                    guard page < pagesPerChip else {
                        throw FirmwareError(.unsupported, "\(base.path): \(prefix)\(chip)/\(name)")
                    }
                    let a = Address(chip: chip, page: page)
                    let record = try legacy.read(a)
                    if record != blankRecord { try store.write(chip, page, record) }  // a blank page stays a hole
                }
                try store.compact(chip)
            }
        }
        guard let liveOut, let overlay, overlayServes(overlay) else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: liveOut, withIntermediateDirectories: false)
        for file in try fm.contentsOfDirectory(atPath: baseOut.path) {  // file by file; baseOut isn't locked yet
            let source = baseOut.appendingPathComponent(file)
            guard clonefile(source.path, liveOut.appendingPathComponent(file).path, 0) == 0 else {
                throw FirmwareError(.internal, "clone \(source.path): \(String(cString: strerror(errno)))")
            }
        }
        let live = try Store(liveOut, writable: true)
        let guest = LegacyReader(self, base: base, overlay: overlay)
        let zeros = [UInt8](repeating: 0, count: blockBytes)
        for chip in 0..<chips {
            defer { step() }
            // marked blocks first (blank, as their stored zeros), then the overlay's pages over them
            for block in guest.overlayNames[chip].compactMap(LegacyReader.erased) {
                guard block < blocksPerChip else { throw FirmwareError(.unsupported, "\(overlay.path): blk\(block)") }
                try K48NANDImage.write(live.fds[chip], zeros[...], at: block * blockBytes)
            }
            for page in guest.overlayNames[chip].compactMap(LegacyReader.page) {
                guard page < pagesPerChip else {
                    throw FirmwareError(.unsupported, "\(overlay.path): \(prefix)\(chip)/\(page)")
                }
                try live.write(chip, page, try guest.read(Address(chip: chip, page: page)))
            }
            try live.compact(chip)  // a chip at a time, so the zeros APFS fills in never span the whole image
        }
    }

    /// Every page of `baseOut` reads as `base` alone did and of `liveOut` as `base` under `overlay` did, byte for byte,
    /// data and spare; a page no file names reads blank in all of them. Independent of `convert`: it reads both
    /// formats back.
    func verify(base: URL, overlay: URL?, baseOut: URL, liveOut: URL?, step: () -> Void = {}) throws {
        let serves = overlayServes(overlay)
        guard (liveOut != nil) == serves else {
            throw FirmwareError(.internal, "the live NAND must exist exactly when the overlay serves pages")
        }
        let legacyBase = LegacyReader(self, base: base, overlay: nil)
        let legacyGuest = LegacyReader(self, base: base, overlay: serves ? overlay : nil)
        let newBase = try Store(baseOut)
        let newLive = try liveOut.map { try Store($0) }
        guard newBase.image == self, newLive.map({ $0.image == self }) ?? true else {
            throw FirmwareError(.internal, "the image store's geometry differs from the format 1 store's")
        }
        let named = legacyGuest.pages
        var block = [UInt8](repeating: 0, count: blockBytes)
        for chip in 0..<chips {
            defer { step() }
            var blocks = newBase.dataBlocks(chip)
            if let newLive { blocks.formUnion(newLive.dataBlocks(chip)) }
            for a in named where a.chip == chip { blocks.insert(a.page / pagesPerBlock) }
            for b in blocks.sorted() {
                for (store, legacy, what) in [(newBase, legacyBase, "base")]
                    + (newLive.map { [($0, legacyGuest, "live")] } ?? [])
                {
                    try store.readBlock(chip, b, into: &block)
                    for i in 0..<pagesPerBlock {
                        let a = Address(chip: chip, page: b * pagesPerBlock + i)
                        guard K48NANDImage.same(block, i * stride, try legacy.read(a), 0, stride) else {
                            throw FirmwareError(.internal, "\(prefix)\(chip) page \(a.page): the \(what) image differs")
                        }
                    }
                }
            }
        }
    }
}
