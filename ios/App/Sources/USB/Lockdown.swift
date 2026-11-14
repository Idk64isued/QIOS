import Foundation

// lockdown on port 62078. Plist messages framed with a 4-byte big-endian length prefix.
//
// Minimum flow for an app install:
//   1. Connect to port 62078 via usbmux.
//   2. QueryType → Lockdown.
//   3. StartService Name="com.apple.afc" → get { Port, EnableServiceSSL }. Open afc over mux.
//   4. StartService Name="com.apple.mobile.installation_proxy" → open install_proxy over mux.
//
// SSL/pairing is skipped: on jailbroken iOS 3.x/4.x these services often accept unencrypted connections, which is
// what Legacy iOS Kit's installers rely on. If the server refuses, we report the EnableServiceSSL flag and fall back
// to the agent-based install path.

enum LockdownError: Error, CustomStringConvertible {
    case badReply(String)
    case wrongType(String)
    case serviceError(String)
    case requiresSSL(String)
    var description: String {
        switch self {
        case .badReply(let m): return "lockdown: \(m)"
        case .wrongType(let got): return "lockdown: not lockdown (type=\(got))"
        case .serviceError(let m): return "lockdown: service error: \(m)"
        case .requiresSSL(let name): return "lockdown: \(name) requires SSL (device pairing not supported here yet)"
        }
    }
}

struct ServiceInfo {
    let name: String
    let port: UInt16
    let enableSSL: Bool
}

final class LockdownClient {
    let pipe: USBMuxPipe
    init(pipe: USBMuxPipe) { self.pipe = pipe }

    func query(timeout: TimeInterval = 10) throws {
        let reply = try request(["Request": "QueryType"], timeout: timeout)
        guard let type = reply["Type"] as? String else { throw LockdownError.badReply("no Type") }
        guard type == "com.apple.mobile.lockdown" else { throw LockdownError.wrongType(type) }
    }

    func startService(_ name: String, timeout: TimeInterval = 10) throws -> ServiceInfo {
        let reply = try request(["Request": "StartService", "Service": name], timeout: timeout)
        if let err = reply["Error"] as? String { throw LockdownError.serviceError(err) }
        guard let port = (reply["Port"] as? Int) ?? (reply["Port"] as? NSNumber)?.intValue else {
            throw LockdownError.badReply("StartService returned no Port")
        }
        let enableSSL = (reply["EnableServiceSSL"] as? Bool) ?? false
        return ServiceInfo(name: name, port: UInt16(port), enableSSL: enableSSL)
    }

    // MARK: - plist framing (4-byte BE length prefix + XML plist)

    func request(_ plist: [String: Any], timeout: TimeInterval = 10) throws -> [String: Any] {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        var frame = Data(count: 4)
        let length = UInt32(data.count).bigEndian
        frame.withUnsafeMutableBytes { $0.storeBytes(of: length, as: UInt32.self) }
        frame.append(data)
        try pipe.write(frame, timeout: timeout)
        return try Self.readReply(pipe, timeout: timeout)
    }

    static func readReply(_ pipe: USBMuxPipe, timeout: TimeInterval = 10) throws -> [String: Any] {
        let header = try pipe.read(4, timeout: timeout)
        guard header.count == 4 else { throw LockdownError.badReply("short length") }
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let body = try pipe.read(Int(length), timeout: timeout)
        guard body.count == Int(length) else { throw LockdownError.badReply("short body") }
        guard let reply = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw LockdownError.badReply("not a plist dict")
        }
        return reply
    }
}
