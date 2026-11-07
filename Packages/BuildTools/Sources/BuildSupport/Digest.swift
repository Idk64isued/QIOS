import CryptoKit
import Foundation

/// `data`'s SHA-256 as lowercase hex (the release checks' and the build tools' one copy).
public func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
