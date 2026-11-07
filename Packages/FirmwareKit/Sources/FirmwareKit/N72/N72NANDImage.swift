// The iPod touch 2G's NAND as an image store (record format 2), which qemu-ios's FMSS writes in place
// (hw/arm/nand-image.c): PageNANDImage.n72, geometry.json and cs0.pages ... cs3.pages, the record of page p of a chip
// select at p * 4160, data then spare, stored XOR the generated layout's blank record (zero data, spare bytes 8 and 10
// 0xFF: ipod_touch_fmss.c fmss_blank_page), so a hole reads as the blank page. The layout is unchanged: pages sit
// where N72NAND's generated layout puts them, and the guest's writes at their logical homes.
//
// Format 1 is the page directory (cs<N>/<page>.page) under an overlay of the same layout; PageNANDImage reads it as
// the FMSS served it, and converts and verifies it for its migration (K48NANDMigration).
//
//   let store = try N72NANDImage.create(dir)                   // geometry.json and four sparse chip files
//   try store.write(page, record); try store.sync()
//   let reader = try N72NANDImage.reader(base: nand, overlay: overlay)   // either format, as the guest reads it

import Foundation

public enum N72NANDImage {
    static let image = PageNANDImage.n72
    public static let format = PageNANDImage.format, blank = image.blank
    static let chips = image.chips, stride = image.stride, pagesPerChip = image.pagesPerChip
    static let blankRecord = image.blankRecord

    /// Whether `nand` is an n72 image store.
    public static func isImage(_ nand: URL) -> Bool { PageNANDImage.of(nand) == image }

    /// `dir` (created, with its geometry and sized empty chip files) open for writing.
    static func create(_ dir: URL) throws -> PageNANDImage.Store { try PageNANDImage.Store(create: dir, image) }

    /// A store of either format read as the guest reads it (PageNANDImage.reader).
    static func reader(base: URL, overlay: URL?) throws -> @Sendable (N72NAND.Page) throws -> [UInt8] {
        let read = try image.reader(base: base, overlay: overlay)
        return { try read(.init(chip: $0.cs, page: $0.page)) }
    }
}

extension PageNANDImage.Store {
    func read(_ p: N72NAND.Page) throws -> [UInt8] { try read(p.cs, p.page) }
    func write(_ p: N72NAND.Page, _ record: [UInt8]) throws { try write(p.cs, p.page, record) }
}
