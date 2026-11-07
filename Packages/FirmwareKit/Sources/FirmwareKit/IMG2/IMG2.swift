// iPhone OS 1.x containers: every IPSW component is an 8900 container, and the all_flash images inside are IMG2.
//
//   try Apple8900.body(data)      // 8900 v1.0: format 3 is AES-128-CBC under the public key 0x837, format 4 plaintext
//   try IMG2.Header(body)         // "2gmI": type, load address, data length; body[0x400...] is the payload
//   try IMG2.payload(body)        // the plaintext image (iBoot-204 as the machine runs it)
//
// 2.0 moved to IMG3, so FirmwareDecryptor tells the two apart by the first four bytes.

import BinaryParsing
import Foundation

public enum Apple8900 {
    static let magic = Data("8900".utf8), headerSize = 0x800
    /// The S5L8900's key 0x837, what the bootrom's 8900 engine decrypts format-3 containers with.
    static let key837 = Data(hexLiteral: "188458A6D15034DFE386F23B61D43774")

    public static func isContainer(_ d: Data) -> Bool { d.prefix(4) == magic }

    /// The payload, decrypted when the container says so. A final partial block is stored in the clear.
    public static func body(_ d: Data) throws -> Data {
        // "8900", "1.0", the format byte, 4 bytes, the payload's size (little-endian); the payload at 0x800
        let (format, body) = try parsing(d, "8900 container") { s -> (UInt8, ParserRange) in
            guard try [UInt8](parsing: &s, byteCount: 7).elementsEqual("89001.0".utf8) else {
                throw FirmwareError(.unsupported, "not an 8900 v1.0 container")
            }
            let format = try UInt8(parsing: &s)
            try s.seek(toRelativeOffset: 4)
            let size = try UInt32(parsingLittleEndian: &s)
            try s.seek(toAbsoluteOffset: headerSize)
            return (format, try s.sliceRange(byteCount: size))
        }
        let payload = d[d.startIndex + body.lowerBound..<d.startIndex + body.upperBound]
        switch format {
        case 4: return Data(payload)
        case 3:
            let n = payload.count & ~15
            return try AESCBC.crypt(payload.prefix(n), iv: Data(count: 16), key: key837) + payload.dropFirst(n)
        default: throw FirmwareError(.unsupported, "8900 format \(format) (only 3, encrypted, and 4, plain, are known)")
        }
    }
}

public enum IMG2 {
    public static let headerSize = 0x400

    public struct Header: Equatable, Sendable {
        /// "ibot", "dtre", "logo", ... (stored reversed, as IMG3 types are).
        public var type: String
        public var loadAddress: UInt32
        public var paddedLength: Int, dataLength: Int
        /// "2gmI", the type, 4 bytes, the load address, the padded and data lengths (little-endian) in a 0x400-byte
        /// header; the padded data after it must be in the image.
        public init(_ body: Data) throws {
            (type, loadAddress, paddedLength, dataLength) = try parsing(body, "IMG2 image") { s in
                guard try [UInt8](parsing: &s, byteCount: 4).elementsEqual("2gmI".utf8) else {
                    throw FirmwareError(.unsupported, "not an IMG2 image")
                }
                let type = String(decoding: try [UInt8](parsing: &s, byteCount: 4).reversed(), as: UTF8.self)
                try s.seek(toRelativeOffset: 4)
                let load = try UInt32(parsingLittleEndian: &s)
                let padded = try Int(parsing: &s, storedAsLittleEndian: UInt32.self)
                let length = try Int(parsing: &s, storedAsLittleEndian: UInt32.self)
                try s.seek(toAbsoluteOffset: headerSize)
                guard length <= padded, padded <= s.count else {
                    throw FirmwareError(.unsupported, "IMG2 \(type) data runs past the image")
                }
                return (type, load, padded, length)
            }
        }
    }

    public static func payload(_ body: Data) throws -> Data {
        let h = try Header(body)
        let s = body.startIndex + headerSize
        return Data(body[s..<s + h.dataLength])
    }
}
