// IMG3: tag parsing and AES-CBC payload decryption, ported from ipad1_fw.py.
//
//   try IMG3.tags(data)["DATA"]                            // (offset, dataLength) per tag, last wins
//   try IMG3.decrypt(data, iv: iv, key: key)               // 3.x+: the final partial block is encrypted
//                                                          //   into the tag's padding (decrypt it whole)
//   try IMG3.decrypt(data, iv: iv, key: key, plainTail: true)  // 2.x: the final partial block is plaintext
//   try AESCBC.crypt(buf, iv: iv, key: key, decrypt: true) // no padding; 16/24/32-byte keys
//   Data(hex: "00ff")
//
// Which tail convention a firmware uses is decided once, on the kernelcache (the one component with a
// checksum): see FirmwareDecryptor.

import BinaryParsing
import Crypto
import Foundation

#if canImport(CommonCrypto)
    import CommonCrypto
#else
    import CryptoExtras
#endif

public enum IMG3 {
    public struct Tag: Equatable, Sendable {
        /// Magic as read ("DATA", "KBAG"; stored reversed).
        public var magic: String = ""
        /// The tag header's offset in the file.
        public var offset: Int
        /// The tag's whole length (header, data and padding) and its data's.
        public var total: Int = 0
        public var dataLength: Int
        /// The data's offsets in the file.
        public var data: Range<Int> { offset + 12..<offset + 12 + dataLength }
    }

    static let headerSize = 0x14

    /// The tags in file order. The header ("Img3" stored reversed, then fullSize, sizeNoPack, sigCheckArea, ident) is
    /// followed by tags up to fullSize, each a magic, its total length, its data length and the data: a tag must hold
    /// its header and data and end within fullSize, and fullSize within the file. A zero total ends the tags.
    public static func tagList(_ data: some ParserSpanProvider) throws -> [Tag] {
        try parsing(data, "img3") { s in
            guard try UInt32(parsingLittleEndian: &s) == 0x496D_6733 else {
                throw FirmwareError(.unsupported, "not an img3")
            }
            let full = try Int(parsing: &s, storedAsLittleEndian: UInt32.self)
            var body = try s.seeking(toAbsoluteOffset: headerSize)
            guard full >= headerSize else {
                throw FirmwareError(.unsupported, "img3 fullSize \(full) is below its header")
            }
            body = try body.sliceSpan(byteCount: full - headerSize)
            var tags: [Tag] = []
            while body.count >= 12 {
                let offset = body.startPosition
                var head = try body.seeking(toRelativeOffset: 0)
                let magic = String(decoding: try [UInt8](parsing: &head, byteCount: 4).reversed(), as: UTF8.self)
                let total = try Int(parsing: &head, storedAsLittleEndian: UInt32.self)
                let dataLength = try Int(parsing: &head, storedAsLittleEndian: UInt32.self)
                if total == 0 { break }
                guard total >= 12, dataLength <= total - 12, total <= body.count else {
                    throw FirmwareError(
                        .unsupported,
                        "img3 tag \(magic) at \(offset): \(total) bytes with \(dataLength) of data in the \(body.count) left"
                    )
                }
                _ = try body.sliceSpan(byteCount: total)
                tags.append(Tag(magic: magic, offset: offset, total: total, dataLength: dataLength))
            }
            return tags
        }
    }

    /// Tag magic (as read, e.g. "DATA", "KBAG") -> its header offset and data length; a later tag of a magic wins.
    public static func tags(_ data: Data) throws -> [String: Tag] {
        Dictionary(try tagList(data).map { ($0.magic, $0) }, uniquingKeysWith: { $1 })
    }

    /// The DATA payload as stored (an unencrypted img3's plaintext, else the ciphertext).
    public static func payload(_ data: Data) throws -> Data {
        guard let tag = try tags(data)["DATA"] else { throw FirmwareError(.unsupported, "img3 has no DATA tag") }
        let start = data.startIndex + tag.offset + 12
        return data[start..<start + tag.dataLength]  // within the tag, which tagList holds within the file
    }

    public static func decrypt(_ data: Data, iv: Data, key: Data, plainTail: Bool = false) throws -> Data {
        guard let tag = try tags(data)["DATA"] else { throw FirmwareError(.unsupported, "img3 has no DATA tag") }
        let start = data.startIndex + tag.offset + 12
        let dlen = tag.dataLength
        if plainTail {
            let n = dlen & ~15
            return try AESCBC.crypt(data[start..<start + n], iv: iv, key: key) + data[start + n..<start + dlen]
        }
        let n = (dlen + 15) & ~15
        guard start + n <= data.endIndex else {
            throw FirmwareError(.unsupported, "img3 DATA padding runs past the file")
        }
        return try AESCBC.crypt(data[start..<start + n], iv: iv, key: key).prefix(dlen)
    }
}

/// CommonCrypto where the host has it; elsewhere swift-crypto's CryptoExtras (BoringSSL), which an Apple build leaves
/// out: BoringSSL's error macros put each C source's absolute build path in the binary (__FILE__), which the release
/// check refuses (it would ship the builder's home folder).
public enum AESCBC {
    /// AES-CBC without padding; `buf` must be a multiple of 16 bytes.
    public static func crypt(_ buf: Data, iv: Data, key: Data, decrypt: Bool = true) throws -> Data {
        guard [16, 24, 32].contains(key.count), iv.count == 16, buf.count % 16 == 0 else {
            throw FirmwareError(.unsupported, "AES: key \(key.count) B, iv \(iv.count) B, data \(buf.count) B")
        }
        guard !buf.isEmpty else { return Data() }
        #if canImport(CommonCrypto)
            var out = Data(count: buf.count)
            var moved = 0
            let status = out.withUnsafeMutableBytes { o in
                buf.withUnsafeBytes { i in
                    key.withUnsafeBytes { k in
                        iv.withUnsafeBytes { v in
                            CCCrypt(
                                CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                k.baseAddress, key.count, v.baseAddress, i.baseAddress, buf.count, o.baseAddress,
                                buf.count, &moved)
                        }
                    }
                }
            }
            guard status == kCCSuccess, moved == buf.count else {
                throw FirmwareError(.internal, "CCCrypt failed (\(status))")
            }
            return out
        #else
            let key = SymmetricKey(data: key)
            let iv = try AES._CBC.IV(ivBytes: iv)
            return decrypt
                ? try AES._CBC.decrypt(buf, using: key, iv: iv, noPadding: true)
                : try AES._CBC.encrypt(buf, using: key, iv: iv, noPadding: true)
        #endif
    }
}

extension Data {
    /// Bytes from a hex string (no separators); nil if it isn't hex.
    public init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(b)
        }
        self.init(out)
    }

    /// Bytes from a hex literal written in the source (a key, an IV, a magic value); a malformed literal is a
    /// programmer error.
    init(hexLiteral hex: StaticString) {
        guard let data = Data(hex: "\(hex)") else { preconditionFailure("not a hex literal: \(hex)") }
        self = data
    }
}
