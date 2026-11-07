// LZSS: Apple's LZSS (4 KiB window, 18-byte matches), the complzss kernelcache wrapper, Adler-32, and
// the iBootIm boot logo. Ports ipad1_fw.lzss/complzss and ipad1_kboot.lzss/logo_segments.
//
//   LZSS.decompress(bytes, windowFill: 0x20)    // raw LZSS stream
//   try LZSS.complzss(payload)                  // "complzss" header; length and Adler-32 checked
//   Adler32.checksum(data)
//   try BootLogo.segments(iBootIm: blob, framebufferPA: KBoot.vramPA)   // [KBoot.Segment], centered on black

import BinaryParsing
import Foundation

public enum LZSS {
    /// `windowFill` is the window's initial byte: spaces for kernelcaches (ipad1_fw), zeros for iBootIm
    /// (ipad1_kboot); it shows through only when a match reaches back before the first output byte.
    public static func decompress<C: Collection>(_ src: C, windowFill: UInt8 = 0x20) -> Data where C.Element == UInt8 {
        let s = Array(src)
        var ring = [UInt8](repeating: windowFill, count: 4096)
        var r = 4096 - 18
        var out: [UInt8] = []
        var flags = 0
        var i = 0
        out.reserveCapacity(s.count * 2)
        while i < s.count {
            flags >>= 1
            if flags & 0x100 == 0 {
                flags = Int(s[i]) | 0xFF00
                i += 1
            }
            if flags & 1 != 0, i < s.count {
                let c = s[i]
                i += 1
                out.append(c)
                ring[r] = c
                r = (r + 1) & 0xFFF
            } else if flags & 1 == 0, i + 1 < s.count {
                let pos = Int(s[i]) | (Int(s[i + 1]) & 0xF0) << 4
                let n = (Int(s[i + 1]) & 0x0F) + 3
                i += 2
                for k in 0..<n {  // byte by byte: a match may overlap what it is writing
                    let c = ring[(pos + k) & 0xFFF]
                    out.append(c)
                    ring[r] = c
                    r = (r + 1) & 0xFFF
                }
            } else {
                break
            }
        }
        return Data(out)
    }

    /// A complzss payload (decrypted kernelcache): header "complzss", adler32, ulen, clen (big-endian); data at 0x180.
    public static func complzss(_ payload: Data) throws -> Data {
        let (adler, ulen, clen) = try parsing(payload.prefix(0x180), "complzss header") { s in
            guard try s.bytes(at: 0, 8).elementsEqual("complzss".utf8) else {
                throw FirmwareError(.unsupported, "not complzss")
            }
            try s.seek(toRelativeOffset: 8)
            return (
                try UInt32(parsingBigEndian: &s), Int(try UInt32(parsingBigEndian: &s)),
                Int(try UInt32(parsingBigEndian: &s))
            )
        }
        let body = payload.dropFirst(0x180).prefix(clen)
        let out = decompress(body)
        guard out.count == ulen, Adler32.checksum(out) == adler else {
            throw FirmwareError(.unsupported, "kernelcache checksum mismatch")
        }
        return out
    }
}

public enum Adler32 {
    public static func checksum(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var i = 0
            while i < buf.count {
                let end = Swift.min(i + 5552, buf.count)  // zlib's NMAX: no UInt32 overflow before the modulo
                while i < end {
                    a &+= UInt32(buf[i])
                    b &+= a
                    i += 1
                }
                a %= 65521
                b %= 65521
            }
        }
        return b << 16 | a
    }
}

public enum BootLogo {
    /// Framebuffer segments that put an iBootIm logo where iBoot puts it: centered on black.
    ///
    /// iBootIm: "iBootIm\0", adler32, "lzss", format tag (only "grey": gray + inverted alpha, composited
    /// over black), u16 width, height; LZSS data at 0x40. On a landscape panel (`turn`, K48) the portrait UI
    /// arrives turned a quarter counter-clockwise into it (its top along the panel's left edge; the app turns
    /// the panel a quarter clockwise to stand it up), so the logo is turned the same way.
    public static func segments(
        iBootIm blob: Data,
        framebufferPA fb: UInt32,
        width fbW: Int = KBoot.fbWidth,
        height fbH: Int = KBoot.fbHeight,
        turn: Bool = true
    ) throws -> [KBoot.Segment] {
        let b = [UInt8](blob)
        // "iBootIm\0", the Adler-32, the compression and format tags (stored reversed), width and height
        // (little-endian u16s); the LZSS data at 0x40
        let (w, h) = try parsing(b, "iBootIm") { s -> (Int, Int) in
            guard s.count >= 0x40, try s.bytes(at: 0, 8).elementsEqual("iBootIm\0".utf8),
                try s.bytes(at: 12, 4).elementsEqual("sszl".utf8)
            else { throw FirmwareError(.unsupported, "not an LZSS iBootIm") }
            guard try s.bytes(at: 16, 4).elementsEqual("yerg".utf8) else {
                throw FirmwareError(.unsupported, "only the grey iBootIm format is handled")
            }
            try s.seek(toRelativeOffset: 20)
            return (Int(try UInt16(parsingLittleEndian: &s)), Int(try UInt16(parsingLittleEndian: &s)))
        }
        let px = [UInt8](LZSS.decompress(b[0x40...], windowFill: 0))
        guard px.count >= w * h * 2 else { throw FirmwareError(.unsupported, "short iBootIm") }
        let (lw, lh) = turn ? (h, w) : (w, h)  // the logo as it lands on the panel
        let x0 = (fbW - lw) / 2
        let y0 = (fbH - lh) / 2
        let stride = fbW * 4
        guard x0 >= 0, y0 >= 0 else { throw FirmwareError(.unsupported, "iBootIm larger than the framebuffer") }
        var rows = [UInt8](repeating: 0, count: stride * lh)
        for ly in 0..<h {
            for lx in 0..<w {
                let gray = UInt32(px[(ly * w + lx) * 2])
                let clear = UInt32(px[(ly * w + lx) * 2 + 1])
                let v = gray * (255 - clear) / 255
                let pixel = 0xFF00_0000 | v * 0x010101
                let at = turn ? (w - 1 - lx) * stride + (x0 + ly) * 4 : ly * stride + (x0 + lx) * 4
                rows[at] = UInt8(pixel & 0xFF)
                rows[at + 1] = UInt8(pixel >> 8 & 0xFF)
                rows[at + 2] = UInt8(pixel >> 16 & 0xFF)
                rows[at + 3] = 0xFF
            }
        }
        return [
            KBoot.Segment(pa: fb, length: UInt32(stride * fbH), data: nil),
            KBoot.Segment(pa: fb + UInt32(y0 * stride), length: UInt32(rows.count), data: Data(rows))
        ]
    }
}
