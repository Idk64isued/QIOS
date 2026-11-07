// HFSUnicode: names as HFS+ stores and orders them (TN1150 "Unicode Subtleties"). A catalog name is UTF-16,
// canonically decomposed except in the ranges Apple leaves composed (U+2000-2FFF, U+F900-FAFF, U+2F800-2FAFF),
// and HFSX compares names as binary UTF-16 code units. (Case-insensitive HFS+ volumes, compared case-folded, are
// not written: every IPSW root filesystem and every volume FirmwareKit makes is HFSX.)

import Foundation

enum HFSUnicode {
    /// `name` as the catalog stores it: decomposed, UTF-16.
    static func catalogName(_ name: String) -> [UInt16] {
        var out: [UInt16] = []
        var run = ""
        func flush() {
            out += run.decomposedStringWithCanonicalMapping.utf16
            run = ""
        }
        for s in name.unicodeScalars {
            if keptComposed(s.value) {
                flush()
                out += String(s).utf16
            } else {
                run.unicodeScalars.append(s)
            }
        }
        flush()
        return out
    }

    static func keptComposed(_ v: UInt32) -> Bool {
        (0x2000...0x2FFF).contains(v) || (0xF900...0xFAFF).contains(v) || (0x2F800...0x2FAFF).contains(v)
    }
}
