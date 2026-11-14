import Foundation

// installation_proxy: install a .ipa that has already been uploaded via AFC. Plist messages framed with a 4-byte
// big-endian length (same framing as lockdown). Replies come back one per status update until Status=Complete.

enum InstallError: Error, CustomStringConvertible {
    case failed(String)
    case protocolMismatch(String)
    var description: String {
        switch self {
        case .failed(let m): return "install: \(m)"
        case .protocolMismatch(let m): return "install: \(m)"
        }
    }
}

final class InstallProxyClient {
    let pipe: USBMuxPipe
    init(pipe: USBMuxPipe) { self.pipe = pipe }

    /// Installs the IPA at `afcPath` (the path on the device, as the AFC path, under PublicStaging usually).
    /// `onProgress` is called with 0...1 and an optional status message as the daemon reports it.
    func install(afcPath: String, timeout: TimeInterval = 300, onProgress: @escaping (Double, String?) -> Void) throws {
        let request: [String: Any] = [
            "Command": "Install",
            "PackagePath": afcPath,
            "ClientOptions": [
                "PackageType": "Developer",
                "SkipUninstall": true,
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)
        var frame = Data(count: 4)
        let length = UInt32(data.count).bigEndian
        frame.withUnsafeMutableBytes { $0.storeBytes(of: length, as: UInt32.self) }
        frame.append(data)
        try pipe.write(frame)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let reply = try LockdownClient.readReply(pipe, timeout: 30)
            if let error = reply["Error"] as? String {
                let description = (reply["ErrorDescription"] as? String) ?? ""
                throw InstallError.failed(description.isEmpty ? error : "\(error): \(description)")
            }
            let status = (reply["Status"] as? String) ?? ""
            let percent = (reply["PercentComplete"] as? Int) ?? ((reply["PercentComplete"] as? NSNumber)?.intValue ?? 0)
            onProgress(min(1.0, Double(percent) / 100.0), status.isEmpty ? nil : status)
            if status == "Complete" { return }
        }
        throw InstallError.failed("install timed out")
    }
}
