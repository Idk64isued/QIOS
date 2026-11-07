import Foundation
import Testing

@testable import LightTouchCore

/// The phone remote's first request: the page, the socket with the right token, and refusals of a wrong or missing
/// token, another path and an oversized head.
struct PhoneRemoteRequestTests {
    static let token = "00112233445566778899aabbccddeeff"
    static let page = Data("<html></html>".utf8)

    func upgrade(path: String = "/ws", protocol offered: String? = token) -> Data {
        var head = "GET \(path) HTTP/1.1\r\nHost: mac.local:9741\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        head += "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
        if let offered { head += "Sec-WebSocket-Protocol: \(offered)\r\n" }
        return Data((head + "\r\n").utf8)
    }

    @Test func thePageIsAPlainGet() {
        let get = Data("GET / HTTP/1.1\r\nHost: mac.local:9741\r\n\r\n".utf8)
        guard case .page(let response) = PhoneRemoteRequest(get, token: Self.token, page: Self.page) else {
            Issue.record("not the page")
            return
        }
        let text = String(decoding: response, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n") && text.contains("Content-Length: 13\r\n"))
        #expect(text.hasSuffix("\r\n\r\n<html></html>"))
    }

    @Test func theRightTokenOpensTheSocket() throws {
        let request = upgrade()
        guard case .socket(let length, let response) = PhoneRemoteRequest(request, token: Self.token, page: Self.page)
        else {
            Issue.record("not a socket")
            return
        }
        #expect(length == request.count)
        let text = String(decoding: response, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 101 "))
        #expect(text.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))  // RFC 6455's example
        #expect(text.contains("Sec-WebSocket-Protocol: \(Self.token)\r\n"))
    }

    @Test(arguments: ["00112233445566778899aabbccddeefe", "", "0011"])
    func aWrongTokenIsRefused(offered: String) {
        #expect(PhoneRemoteRequest(upgrade(protocol: offered), token: Self.token, page: Self.page) == .refused)
    }

    @Test func noTokenIsRefused() {
        #expect(PhoneRemoteRequest(upgrade(protocol: nil), token: Self.token, page: Self.page) == .refused)
    }

    @Test func anotherPathIsRefused() {
        #expect(PhoneRemoteRequest(upgrade(path: "/favicon.ico"), token: Self.token, page: Self.page) == .refused)
        #expect(PhoneRemoteRequest(upgrade(path: "/ws/"), token: Self.token, page: Self.page) == .refused)
    }

    /// Stopped, the framer's token is empty: a socket offering none opens nothing.
    @Test func anEmptyTokenOpensNothing() {
        #expect(PhoneRemoteRequest(upgrade(protocol: ""), token: "", page: Self.page) == .refused)
    }

    /// Each session's token is new and kept nowhere.
    @Test func eachSessionHasItsOwnToken() {
        let first = PhoneRemoteRequest.newToken()
        let second = PhoneRemoteRequest.newToken()
        #expect(first != second && first.count == 32 && second.count == 32)
        #expect(UserDefaults.standard.object(forKey: PhoneRemoteRequest.storedTokenKey) == nil)
    }

    /// The fingerprint the sheet shows is the certificate's SHA-256, as openssl gives it.
    @Test func theFingerprintIsTheCertificatesSHA256() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func openssl(_ arguments: [String]) throws -> String {
            let process = Process()
            let out = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return text
        }
        let der = dir.appendingPathComponent("certificate.der").path
        _ = try openssl([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=mac.local", "-keyout",
            dir.appendingPathComponent("key.pem").path, "-outform", "DER", "-out", der
        ])
        let printed = try openssl(["x509", "-inform", "DER", "-in", der, "-noout", "-fingerprint", "-sha256"])
        let expected = try #require(printed.split(separator: "=").last).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            PhoneRemoteRequest.fingerprint(certificate: try Data(contentsOf: URL(fileURLWithPath: der)))
                == expected.replacingOccurrences(of: ":", with: " ")
        )
    }

    @Test func anOversizedHeadIsRefusedAndAPartialOneWaits() {
        let partial = upgrade().prefix(40)
        #expect(PhoneRemoteRequest(Data(partial), token: Self.token, page: Self.page) == .incomplete)
        let long = Data("GET / HTTP/1.1\r\nX: ".utf8) + Data(repeating: 0x61, count: PhoneRemoteRequest.maxLength)
        #expect(PhoneRemoteRequest(long, token: Self.token, page: Self.page) == .refused)
        #expect(PhoneRemoteRequest(long + Data("\r\n\r\n".utf8), token: Self.token, page: Self.page) == .refused)
    }
}
