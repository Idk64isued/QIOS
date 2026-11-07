// What the phone remote's one port (PhoneRemoteController) makes of a connection's first request, and the HTTP it
// answers with: the page for a plain GET, the WebSocket's 101 for an upgrade that offers the token as its subprotocol,
// nothing for anything else. The connection's framer answers with this before NWProtocolWebSocket, its handshake
// skipped, takes the stream.

import Crypto
import Foundation

public nonisolated enum PhoneRemoteRequest: Equatable {
    /// The head hasn't all arrived.
    case incomplete
    /// `GET /`: `response` is the page with its head; the connection closes after it.
    case page(response: Data)
    /// The upgrade with the token, `length` bytes; `response` is the 101 to write.
    case socket(length: Int, response: Data)
    /// An oversized head, another path, a missing or wrong token.
    case refused

    /// A browser's request head is well under this.
    public static let maxLength = 8192

    public init(_ bytes: Data, token: String, page: Data) {
        guard let end = bytes.range(of: Data("\r\n\r\n".utf8)), end.upperBound <= Self.maxLength else {
            self = bytes.count < Self.maxLength ? .incomplete : .refused
            return
        }
        let lines = String(decoding: bytes[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            let field = line.split(separator: ":", maxSplits: 1)
            if field.count == 2 { fields[field[0].lowercased()] = field[1].trimmingCharacters(in: .whitespaces) }
        }
        let request = lines[0].split(separator: " ")
        guard request.count == 3, request[0] == "GET" else {
            self = .refused
            return
        }
        if request[1] == "/" {
            let head =
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.count)\r\n"
                + "Connection: close\r\n\r\n"
            self = .page(response: Data(head.utf8) + page)
        } else if request[1] == "/ws", let key = fields["sec-websocket-key"],
            let offered = fields["sec-websocket-protocol"], !token.isEmpty, Self.matches(offered, token)
        {
            let response =
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(Self.acceptKey(key))\r\nSec-WebSocket-Protocol: \(token)\r\n\r\n"
            self = .socket(length: end.upperBound, response: Data(response.utf8))
        } else {
            self = .refused
        }
    }

    /// Sec-WebSocket-Accept for the request's Sec-WebSocket-Key (RFC 6455).
    static func acceptKey(_ key: String) -> String {
        let hash = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(hash).base64EncodedString()
    }

    /// In constant time: how long it takes says nothing about how much of the token was right.
    static func matches(_ offered: String, _ token: String) -> Bool {
        let key = SymmetricKey(size: .bits256)
        let code = HMAC<SHA256>.authenticationCode(for: Data(token.utf8), using: key)
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: Data(offered.utf8), using: key)
    }

    // MARK: - The token and the certificate

    /// What a phone's page offers to open the socket: 128 random bits, made for one Play on Phone session and kept
    /// only in memory, so stopping revokes every phone that scanned its code.
    public static func newToken() -> String {
        // SystemRandomNumberGenerator: the platform's cryptographically secure generator.
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Where builds before per-session tokens kept theirs; Play on Phone removes it.
    public static let storedTokenKey = "phoneRemoteToken"

    /// The certificate's SHA-256 fingerprint as Safari's certificate details show it (uppercase pairs), to compare
    /// before continuing past the warning.
    public static func fingerprint(certificate der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
