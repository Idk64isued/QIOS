import Foundation
import HostRuntime
import HostServiceWire

public enum WebProxyStatus: Equatable {
    case waiting, applying, ready, failed
    /// No guest agent to trust the proxy certificate silently: the profile was offered instead.
    case needsTap
    /// iPhone OS 1.x: the certificate is written into the stopped device (FirmwareTool.trustAnchor) at its next start.
    case needsRestart

    public func message(for profile: Board) -> String? {
        switch self {
        case .waiting: "Waiting for \(profile.shortName)…"
        case .applying: "Updating proxy…"
        case .ready: nil
        case .failed: "Couldn’t update the proxy. Try again."
        case .needsTap: "Tap Install on the \(profile.shortName) to trust the proxy certificate."
        case .needsRestart: "Restart the \(profile.shortName) to trust the proxy certificate."
        }
    }

    public var isWorking: Bool { self == .waiting || self == .applying }
}

/// Host routing is read once per guest connection. Changes need no VM restart.
public struct WebProxyConfiguration: Codable, Equatable {
    public init(mode: Mode = .direct, archiveDate: String = "") {
        self.mode = mode
        self.archiveDate = archiveDate
    }
    public enum Mode: String, Codable {
        case off, direct, archive
    }
    /// A device that never set its proxy goes through it to the live web.
    public var mode: Mode = .direct
    public var archiveDate = "20090909"
    public static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        formatter.isLenient = false
        return formatter
    }
    public var dateValue: Date { Self.dateFormatter.date(from: archiveDate) ?? Date() }
    /// Where a device's routing (web-proxy.conf), preferences (web-proxy.plist)
    /// and proxy CA (web-proxy.conf.ca.*) live. The device that kept the
    /// legacy pairing conf keeps the legacy state-directory files too, so the
    /// CA its guest already trusts is unchanged; every other device has its own.
    public static func directory(for instance: DeviceInstance) -> URL {
        instance.storage.usbmuxConf == "work/usbmuxd-conf" ? Bundled.stateDirectory : instance.paths.directory
    }
    public static func file(in directory: URL) -> URL { directory.appendingPathComponent("web-proxy.conf") }
    /// An XML property list; earlier builds kept web-proxy.json, converted on the first load.
    public static func preferencesFile(in directory: URL) -> URL { directory.appendingPathComponent("web-proxy.plist") }
    public static func load(from directory: URL) -> Self {
        (try? PropertyListFile.read(
            Self.self,
            from: preferencesFile(in: directory),
            legacyJSON: directory.appendingPathComponent("web-proxy.json")
        )) ?? Self()
    }
    public func validate() throws {
        if mode == .archive {
            guard archiveDate.count == 8, let date = Self.dateFormatter.date(from: archiveDate),
                Self.dateFormatter.string(from: date) == archiveDate
            else {
                throw DeviceToolsError.failed("Choose a valid archive date.")
            }
        }
    }
    public func writeRouting(in directory: URL) throws {
        try validate()
        let text = mode == .archive ? "archive\n\(archiveDate)\n" : "\(mode.rawValue)\n"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: Self.file(in: directory), options: .atomic)
    }
    public func save(in directory: URL) throws {
        try writeRouting(in: directory)
        try PropertyListFile.write(self, to: Self.preferencesFile(in: directory))
    }
    /// What the helper serves (BootConfig.webProxy): this directory's routing, and a socket named for it in the
    /// temporary directory (a Unix socket path stays under 104 bytes; the device directory may not). A sandboxed
    /// helper binds none: QEMU hands it each connection (guestfwd fdpass:, BootRecipe.replacingGuestForward).
    public static func endpoint(directory: URL) -> WebProxyEndpoint {
        let config = file(in: directory).path
        let hash = config.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return WebProxyEndpoint(
            config: config,
            socket: HelperSandbox.socketPath(
                "proxy-" + String(format: "%08x", UInt32(truncatingIfNeeded: hash)) + ".sock"
            )
        )
    }
    /// The guest's 10.0.2.100:3128: slirp, in the helper, connects each guest connection to the helper's proxy
    /// socket (WebProxy.swift); no process per connection. A comma in the path is doubled, as QEMU's options escape it.
    public static func guestForward(socket: String) -> String {
        ",guestfwd=tcp:10.0.2.100:3128-unix-connect:" + socket.replacingOccurrences(of: ",", with: ",,")
    }
}
