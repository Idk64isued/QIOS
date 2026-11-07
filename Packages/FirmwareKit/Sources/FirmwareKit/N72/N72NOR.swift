// N72NOR: the iPod touch 2G (n72ap) 1 MiB SPI NOR, synthesized from an identity. Port of imgtools/build_nor.py
// (synth_base + build, --identity): IMG2 superblock, SysCfg (Mod#, Regn, SrNm, Batt), the IPSW's all_flash img3s
// packed at 0x8000 (padded to the 0x40 granularity, fullSize rewritten, SHSH wrapped under the emulated UID so
// iBoot's in-place unwrap recovers it), and an nvram bank at 0xfc000 (debug-uarts, btaddr, wifiaddr).
//
//   let nor = try N72NOR.build(identity: id, images: [(type, img3)], wrapTypes: nil)   // nil: wrap every image
//   N72NOR.order                       // the stock image set, in the stock order
//   try N72NOR.type(of: img3)          // "illb", "ibot", ...

import BinaryParsing
import Foundation
import zlib

public enum N72NOR {
    static let size = 0x100000, sysCfg = 0x4000, nvram = 0xFC000, nvramBank = 0x2000, img3Header = 0x14
    /// The image types the stock 5F138 NOR carries, in its order (build_nor.DEFAULT_ORDER).
    public static let order = ["illb", "ibot", "dtre", "logo", "nsrv", "bat0", "bat1", "recm", "glyC", "glyP"]
    /// What iBoot encrypts under the UID key to get the SHSH wrapping key (its first AES request: mode 6, | 1 for
    /// encrypt, | 8; the machine's aes-uid=hardware honors that bit, which the recipe's machine option selects).
    static let kdfConst = Data(hexLiteral: "db1f5b33606c5f1c1934aa66589c0661")
    /// The emulated S5L8720's UID (key_uid in hw/arm/ipod_touch_aes.h).
    static let uidKey = Data(hexLiteral: "0123456789ABCDEF0123456789ABCDEF")

    /// The SHSH wrapping key iBoot derives: kdfConst encrypted under the UID.
    static func wrappingKey() throws -> Data {
        try AESCBC.crypt(kdfConst, iv: Data(count: 16), key: uidKey, decrypt: false)
    }

    /// An img3's type tag ("illb", ...), as the header stores it reversed at 0x10.
    public static func type(of img3: Data) throws -> String {
        try parsing(img3, "img3 header") { s in
            guard try UInt32(parsingLittleEndian: &s) == 0x496D_6733 else {
                throw FirmwareError(.unsupported, "not an img3")
            }
            try s.seek(toRelativeOffset: 12)
            return String(decoding: try [UInt8](parsing: &s, byteCount: 4).reversed(), as: UTF8.self)
        }
    }

    /// build_nor.build over synth_base(identity): the whole NOR. `images` are the all_flash img3s by type;
    /// `wrapTypes` nil wraps every packed image's SHSH (3.x+), ["ibot"] only iBoot's (2.x).
    public static func build(identity id: UnitIdentity, images: [String: Data], types: [String], wrapTypes: [String]?)
        throws -> Data
    {
        var nor = try base(id)
        let gran = 0x40
        let start = gran * 0x200
        if let w = wrapTypes, !Set(w).isSubset(of: types) {
            throw FirmwareError(.internal, "SHSH wrap types must belong to the selected image set")
        }
        let key = try wrappingKey()
        var off = start
        for t in types {
            guard var img = images[t].map({ [UInt8]($0) }) else {
                throw FirmwareError(.unsupported, "all_flash has no img3 of type \(t)")
            }
            if wrapTypes?.contains(t) ?? true {
                guard try wrapSHSH(&img, key: key) else {
                    throw FirmwareError(
                        .unsupported,
                        "\(t): no SHSH tag to wrap, or its length is not a multiple of 16"
                    )
                }
            }
            let padded = (img.count + gran - 1) & ~(gran - 1)
            img += [UInt8](repeating: 0, count: padded - img.count)
            put32(&img, 4, UInt32(padded))
            guard off + padded <= nvram else {
                throw FirmwareError(.unsupported, "NOR image area overflows the nvram partition (\(t))")
            }
            nor.replaceSubrange(off..<off + padded, with: img)
            off += padded
        }
        put32(&nor, 0x10, UInt32((off + gran - 1) / gran))  // the stock span over-counts by image_start; kept
        put32(&nor, 0x30, crc(nor[0..<0x30]))
        return Data(nor)
    }

    /// `nor` (a build) as `build` would have made it for `id`: the SysCfg block and the nvram bank are the only
    /// identity-bearing bytes (the UID that wraps the SHSH is the machine's, not the unit's).
    public static func reidentify(_ nor: Data, identity id: UnitIdentity) throws -> Data {
        guard nor.count == size else { throw FirmwareError(.unsupported, "nor.bin is \(nor.count) bytes, not \(size)") }
        var b = [UInt8](nor)
        let fresh = try base(id)
        let imageStart = 0x40 * 0x200
        b.replaceSubrange(sysCfg..<imageStart, with: fresh[sysCfg..<imageStart])
        b.replaceSubrange(nvram..<size, with: fresh[nvram..<size])
        return Data(b)
    }

    /// Encrypts the SHSH tag (past sigCheckArea, so no digest covers it) under the UID-derived key.
    static func wrapSHSH(_ b: inout [UInt8], key: Data) throws -> Bool {
        guard let shsh = try IMG3.tagList(b).first(where: { $0.magic == "SHSH" && $0.dataLength % 16 == 0 })?.data
        else { return false }
        let enc = try AESCBC.crypt(Data(b[shsh]), iv: Data(count: 16), key: key, decrypt: false)
        b.replaceSubrange(shsh, with: enc)
        return true
    }

    /// synth_base: IMG2 + SysCfg + nvram for the identity, an empty image area.
    static func base(_ id: UnitIdentity) throws -> [UInt8] {
        var nor = [UInt8](repeating: 0, count: size)
        nor.replaceSubrange(0..<4, with: Array("2GMI".utf8))
        put32(&nor, 4, 0x40)
        put32(&nor, 8, 0)
        put32(&nor, 12, 0x200)
        try writeSysCfg(&nor, id)
        let bank = try nvramBank([
            ("debug-uarts", "1"), ("btaddr", (id["bt-mac"] ?? "").uppercased()),
            ("wifiaddr", (id["wifi-mac"] ?? "").uppercased())
        ])
        nor.replaceSubrange(nvram..<nvram + nvramBank, with: bank)
        put32(&nor, 0x30, crc(nor[0..<0x30]))
        return nor
    }

    /// SysCfg at 0x4000 (the 1G's generate_nor.c writes the same block): Mod#, Regn, SrNm, Batt from the identity.
    static func writeSysCfg(_ nor: inout [UInt8], _ id: UnitIdentity) throws {
        nor.replaceSubrange(sysCfg..<sysCfg + 4, with: Array("gfCS".utf8))
        for (i, v) in [0xC8, 0x2000, 0x0001_0001, 0, 4].enumerated() { put32(&nor, sysCfg + 4 + 4 * i, UInt32(v)) }
        for (i, (tag, key)) in [
            ("Mod#", "model-number"), ("Regn", "region-info"), ("SrNm", "serial-number"), ("Batt", "battery-serial")
        ].enumerated() {
            let value = Array((id[key] ?? "").utf8)
            guard value.count <= 16 else { throw FirmwareError(.unsupported, "\(key) is longer than a SysCfg value") }
            let o = sysCfg + 0x18 + i * 0x14
            nor.replaceSubrange(
                o..<o + 20,
                with: Array(tag.utf8).reversed() + value + [UInt8](repeating: 0, count: 16 - value.count)
            )
        }
    }

    /// A CHRP nvram partition header: signature, checksum, length in 16-byte units, 12-byte name.
    static func chrp(_ sig: UInt8, _ length: Int, _ name: String) -> [UInt8] {
        var h: [UInt8] =
            [sig, 0, UInt8((length / 16) & 0xFF), UInt8((length / 16) >> 8)] + Array(name.utf8)
            + [UInt8](repeating: 0, count: 12 - name.utf8.count)
        var s = 0
        for b in [h[0]] + h[2...] {
            s += Int(b)
            if s > 0xFF { s = (s & 0xFF) + 1 }
        }
        h[1] = UInt8(s)
        return h
    }

    /// One 8 KiB bank as iBoot writes it: "nvram" (adler32 of the rest, generation), "common", an empty
    /// "APL,OSXPanic" and the free-space partition.
    static func nvramBank(_ common: [(String, String)]) throws -> [UInt8] {
        var bank = [UInt8](repeating: 0, count: nvramBank)
        bank.replaceSubrange(0..<16, with: chrp(0x5A, 0x20, "nvram"))
        put32(&bank, 0x14, 0x10)
        let body: [UInt8] = common.flatMap { kv -> [UInt8] in Array("\(kv.0)=\(kv.1)".utf8) + [0] }
        guard body.count <= 0x800 - 16 else { throw FirmwareError(.unsupported, "nvram common partition overflows") }
        bank.replaceSubrange(0x20..<0x30, with: chrp(0x70, 0x800, "common"))
        bank.replaceSubrange(0x30..<0x30 + body.count, with: body)
        bank.replaceSubrange(0x820..<0x830, with: chrp(0xA1, 0x810, "APL,OSXPanic"))
        bank.replaceSubrange(0x1030..<0x1040, with: chrp(0x7F, nvramBank - 0x1030, String(repeating: "w", count: 12)))
        put32(&bank, 0x10, Adler32.checksum(Data(bank[0x14...])))
        return bank
    }
}
