// dyld_v1 shared caches (iOS 3.x/4.x, armv6/armv7): mappings, cached images, each image's own
// LC_SYMTAB (cache file offsets: the old caches keep an unslid linkedit), and the AppSync patch.
// Port of imgtools/appsync_cachepatch.py and ipad1_rootfs.cache_images/image_strings.
import BinaryParsing
import Foundation

public struct DyldSharedCache: @unchecked Sendable {
    public struct Mapping: Sendable { public let address: UInt64, size: UInt64, fileOffset: UInt64 }
    public struct Image: Sendable {
        public let path: String
        public let address: UInt64
        public let headerOffset: Int
    }
    public struct Symbol: Sendable {
        public let name: String
        public let type: UInt8
        public let desc: UInt16
        public let value: UInt32
    }

    /// The whole cache, memory-mapped (never copied).
    public let data: Data
    public let mappings: [Mapping]
    public let images: [Image]

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        self.data = data
        guard data.count >= 0x20, data.prefix(7) == Data("dyld_v1".utf8) else {
            throw FirmwareError(.unsupported, "not a dyld_v1 shared cache")
        }
        // dyld_cache_header: the magic, then mappingOffset, mappingCount, imagesOffset, imagesCount at 0x10; each
        // mapping is address, size, fileOffset (u64s) and two protections, each image address, modTime, inode (u64s),
        // the path's file offset and a pad. Every record has to be in the file.
        let (maps, imgs) = try parsing(data, "dyld_v1 shared cache") { s in
            func table<T>(_ at: Int, _ body: (inout ParserSpan) throws -> T) throws -> [T] {
                var h = try s.seeking(toAbsoluteOffset: at)
                var t = try s.seeking(toAbsoluteOffset: try UInt32(parsingLittleEndian: &h))
                return try [T](parsing: &t, count: Int(try UInt32(parsingLittleEndian: &h))) { r in
                    var record = try r.sliceSpan(byteCount: 32)
                    return try body(&record)
                }
            }
            let maps = try table(0x10) { r in
                Mapping(
                    address: try UInt64(parsingLittleEndian: &r),
                    size: try UInt64(parsingLittleEndian: &r),
                    fileOffset: try UInt64(parsingLittleEndian: &r)
                )
            }
            let imgs = try table(0x18) { r in
                let address = try UInt64(parsingLittleEndian: &r)
                try r.seek(toRelativeOffset: 16)
                return (address, try s.latin1(at: Int(try UInt32(parsingLittleEndian: &r))))
            }
            return (maps, imgs)
        }
        mappings = maps
        images = imgs.map { Image(path: $1, address: $0, headerOffset: Self.offset(of: $0, in: maps) ?? -1) }
    }

    /// The file offset of `address` in `maps`; nil outside them (or past what an Int holds).
    static func offset(of address: UInt64, in maps: [Mapping]) -> Int? {
        maps.first { $0.address <= address && address - $0.address < $0.size }.flatMap {
            let (sum, overflow) = $0.fileOffset.addingReportingOverflow(address - $0.address)
            return overflow ? nil : Int(exactly: sum)
        }
    }

    public func fileOffset(of address: UInt64) -> Int? { Self.offset(of: address, in: mappings) }

    public func image(_ path: String) -> Image? { images.first { $0.path == path } }

    /// Walks an image's load commands (its mach_header: magic, cputype, cpusubtype, filetype, ncmds, …): `body` gets
    /// each command's cmd and the command (cmd, cmdsize, its body: at least 8 bytes, all in the cache), positioned at
    /// its start, offsets the cache file's. A command can't be shorter than its header, so the walk always moves on.
    func loadCommands(_ img: Image, _ body: (UInt32, inout ParserSpan) throws -> Void) throws {
        let h = img.headerOffset
        guard h >= 0 else { return }
        try parsing(data, "\(img.path): load commands") { s in
            try s.seek(toAbsoluteOffset: h)
            guard try UInt32(parsingLittleEndian: &s) == 0xFEED_FACE else { return }
            try s.seek(toRelativeOffset: 12)
            let ncmds = try UInt32(parsingLittleEndian: &s)
            try s.seek(toRelativeOffset: 8)
            for _ in 0..<ncmds {
                var head = try s.seeking(toRelativeOffset: 0)
                let cmd = try UInt32(parsingLittleEndian: &head)
                let size = try UInt32(parsingLittleEndian: &head)
                guard size >= 8 else {
                    throw FirmwareError(.unsupported, "\(img.path): load command \(cmd) of \(size) bytes")
                }
                var command = try s.sliceSpan(byteCount: size)
                try body(cmd, &command)
            }
        }
    }

    /// LC_SYMTAB's symoff, nsyms and stroff (after cmd and cmdsize).
    func symbolTable(_ img: Image) throws -> (symoff: UInt32, nsyms: UInt32, stroff: UInt32)? {
        var tab: (UInt32, UInt32, UInt32)?
        try loadCommands(img) { cmd, c in
            guard cmd == 2 else { return }
            try c.seek(toRelativeOffset: 8)
            tab = (
                try UInt32(parsingLittleEndian: &c), try UInt32(parsingLittleEndian: &c),
                try UInt32(parsingLittleEndian: &c)
            )
        }
        return tab
    }

    /// Each nlist of the image's symbol table: its name's string offset, type, sect, desc and value; `body` returns
    /// false to stop. The table must be in the cache; a name past it is an error when read.
    func forEachNlist(
        _ img: Image,
        _ body: (_ name: UInt32, _ type: UInt8, _ desc: UInt16, _ value: UInt32, _ strings: borrowing ParserSpan) throws
            -> Bool
    ) throws {
        guard let (symoff, nsyms, stroff) = try symbolTable(img) else { return }
        try parsing(data, "\(img.path): symbol table") { s in
            let strings = try s.seeking(toAbsoluteOffset: stroff)
            var t = try s.seeking(toAbsoluteOffset: symoff)
            for _ in 0..<nsyms {
                var e = try t.sliceSpan(byteCount: 12)
                let name = try UInt32(parsingLittleEndian: &e)
                let type = try UInt8(parsing: &e)
                try e.seek(toRelativeOffset: 1)
                let desc = try UInt16(parsingLittleEndian: &e)
                if try !body(name, type, desc, try UInt32(parsingLittleEndian: &e), strings) { return }
            }
        }
    }

    /// The image's LC_SYMTAB entries in table order; `body` returns false to stop.
    public func forEachSymbol(in img: Image, _ body: (Symbol) throws -> Bool) throws {
        try forEachNlist(img) { name, type, desc, value, strings in
            try body(Symbol(name: try strings.latin1(at: Int(name)), type: type, desc: desc, value: value))
        }
    }

    public func symbolNames(in img: Image) throws -> [String] {
        var out: [String] = []
        try forEachSymbol(in: img) {
            out.append($0.name)
            return true
        }
        return out
    }

    /// The C strings of one of the image's sections (e.g. "__cstring"), as image_strings(section=) gives them.
    public func cStrings(in img: Image, section: String) throws -> [String] {
        var out: [String] = []
        try loadCommands(img) { cmd, c in
            guard cmd == 1 else { return }
            // LC_SEGMENT: cmd, cmdsize, segname, four addresses and sizes, two protections, nsects at 48, flags; then
            // its 68-byte sections (sectname, segname, addr, size, …) within the command
            try c.seek(toRelativeOffset: 48)
            let nsects = try UInt32(parsingLittleEndian: &c)
            try c.seek(toRelativeOffset: 4)
            for _ in 0..<nsects {
                var sect = try c.sliceSpan(byteCount: 68)
                let name = try [UInt8](parsing: &sect, byteCount: 16).prefix { $0 != 0 }
                try sect.seek(toRelativeOffset: 16)
                let addr = try UInt32(parsingLittleEndian: &sect)
                let size = try UInt32(parsingLittleEndian: &sect)
                guard String(decoding: name, as: UTF8.self) == section, let start = fileOffset(of: UInt64(addr)) else {
                    continue
                }
                let bytes = try parsing(data, "\(img.path): \(section)") { s in
                    try s.bytes(at: start, Int(size))
                }
                out += bytes.split(separator: 0).map { String($0.map { Character(Unicode.Scalar($0)) }) }
            }
        }
        return out
    }

    /// (address, Thumb) of an N_SECT symbol with a non-zero value, searching every image's symbol table in
    /// cache order (appsync_cachepatch.find_symbol).
    public func findSymbol(_ name: String) throws -> (address: UInt64, thumb: Bool) {
        let want = Array(name.utf8)
        for img in images {
            guard img.headerOffset >= 0 else {
                throw FirmwareError(.internal, "VA \(hex(img.address)) not in any mapping")
            }
            var hit: (UInt64, Bool)?
            try forEachNlist(img) { name, type, desc, value, strings in
                guard value != 0, type & 0x0e == 0x0e, try strings.cBytes(at: Int(name)).elementsEqual(want) else {
                    return true
                }
                hit = (UInt64(value), desc & 0x0008 != 0)  // N_ARM_THUMB_DEF
                return false
            }
            if let (a, t) = hit { return (a, t) }
        }
        throw FirmwareError(.unsupported, "\(name) not found in cache image symbol tables")
    }
}

func hex<T: BinaryInteger>(_ v: T) -> String { "0x" + String(v, radix: 16) }

/// The amfid half of AppSync: MISValidateSignature -> `movs r0,#0; bx lr`, located by symbol and
/// byte-checked (a Thumb `push {..., lr}` entry) before anything is written.
public enum AppSyncCachePatch {
    public static let target = "_MISValidateSignature"
    public static let patch: [UInt8] = [0x00, 0x20, 0x70, 0x47]

    static func looksLikeThumbEntry(_ b: [UInt8]) -> Bool {
        let hw = UInt16(b[0]) | UInt16(b[1]) << 8
        let hw2 = UInt16(b[2]) | UInt16(b[3]) << 8
        if hw & 0xFF00 == 0xB500 { return true }  // push {..., lr}  (3.x/4.x, 5.0 beta 9A5220p)
        if hw == 0xE92D { return hw2 & 0x4000 != 0 }  // push.w with LR
        // iOS 5.x libmis exports MISValidateSignature as a tail-thunk `movs rN,#imm ; b.w <impl>`
        // (9A5288d..9B206: 0022 fff7). Overwriting its first word with `movs r0,#0 ; bx lr` returns
        // success just as patching a framed entry does. Recognized by shape, not by build.
        if hw & 0xF800 == 0x2000 { return hw2 & 0xF800 == 0xF000 }  // movs rN,#imm then a 32-bit branch
        return false
    }

    /// Locates and (with `apply`) patches the cache in place. Returns appsync_cachepatch's status line;
    /// throws on a prologue that is not a Thumb function entry.
    /// The patch target in `cache`: its VA, file offset and current first word; throws where it is not a Thumb
    /// function entry (or already the patch).
    public static func locate(_ cache: DyldSharedCache) throws -> (va: UInt64, offset: Int, word: [UInt8]) {
        let (va, thumb) = try cache.findSymbol(target)
        guard let foff = cache.fileOffset(of: va) else {
            throw FirmwareError(.internal, "VA \(hex(va)) not in any mapping")
        }
        let cur = try parsing(cache.data, "\(target) prologue") { s in try s.bytes(at: foff, 4) }
        guard cur == patch || (thumb && looksLikeThumbEntry(cur)) else {
            let curHex = cur.hexString
            throw FirmwareError(
                .unsupported,
                "\(target) prologue \(curHex) at \(hex(foff)) is not a Thumb function entry — refusing to patch"
            )
        }
        return (va, foff, cur)
    }

    @discardableResult
    public static func patchCache(at url: URL, apply: Bool = true) throws -> String {
        let (va, foff, cur) = try locate(DyldSharedCache(contentsOf: url))
        let curHex = cur.hexString
        let patchHex = "00207047"
        if cur == patch { return "\(target) already patched (VA \(hex(va)) off \(hex(foff)))" }
        if !apply { return "would patch \(target) \(curHex) -> \(patchHex) at \(hex(foff))" }
        let fh = try FileHandle(forUpdating: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: UInt64(foff))
        try fh.write(contentsOf: Data(patch))
        return "patched \(target) \(curHex) -> \(patchHex) (VA \(hex(va)) off \(hex(foff)))"
    }
}
