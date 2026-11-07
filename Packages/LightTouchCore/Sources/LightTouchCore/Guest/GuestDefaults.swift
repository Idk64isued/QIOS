// Preference keys in the guest user's own domains, as `defaults write` would set them, through the agent.
//
// No cfprefsd runs on any firmware the emulator boots (checked on 6.1.6, 7.0 beta and 7.1.2), so each process's
// CFPreferences reads its domain's plist straight from disk and reloads it when the file changes: writing the file
// (as its owner, mobile) is the stock way to change a key from outside the process. Readers that cache a key at launch
// take it at their next launch: SpringBoard at a respring. (6.x and 7.x SpringBoard also rereads its debugging
// defaults on SIGUSR1, but its status bar keeps what it drew until something else changes it: a respring it is.)
//
// Foundation only, so tests/sessions' drivers compile it as the app does.

import Foundation
import HostServiceWire

/// One plist value a preference key takes.
public nonisolated enum GuestDefaultValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    var object: Any {
        switch self {
        case .bool(let b): b
        case .int(let i): i
        case .double(let d): d
        case .string(let s): s
        }
    }
}

/// A key in a preference domain; a nil value removes it.
public nonisolated struct GuestDefault: Equatable, Sendable {
    public init(_ domain: String, _ key: String, _ value: GuestDefaultValue?) {
        self.domain = domain
        self.key = key
        self.value = value
    }
    public var domain: String
    public var key: String
    public var value: GuestDefaultValue?
}

extension GuestServices {
    /// Where the guest user's preferences live: mobile's home from 1.1.3 on (2.x+ here), uid 501.
    public static let preferences = "/var/mobile/Library/Preferences"

    /// Sets `defaults` in their domains' plists (binary, mobile's, mode 0600), reading each domain once and writing
    /// it only when a key changes. The domains whose files changed, in order.
    @discardableResult
    public func writeDefaults(_ defaults: [GuestDefault]) async throws -> [String] {
        var changed: [String] = []
        var domains: [String] = []
        for d in defaults where !domains.contains(d.domain) { domains.append(d.domain) }
        for domain in domains {
            let path = "\(Self.preferences)/\(domain).plist"
            let old: NSDictionary
            if let data = try await agent.get(path, limit: 8 << 20), !data.isEmpty {
                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
                else { throw DeviceToolsError.failed("The device’s \(domain) preferences aren’t readable.") }
                old = plist
            } else {
                old = [:]
            }
            let new = NSMutableDictionary(dictionary: old)
            for d in defaults where d.domain == domain {
                if let value = d.value { new[d.key] = value.object } else { new.removeObject(forKey: d.key) }
            }
            guard new != old else { continue }
            let data = try PropertyListSerialization.data(fromPropertyList: new, format: .binary, options: 0)
            try await agent.put(path, mode: 0o600, data)
            try await agent.chown(501, 501, path)
            changed.append(domain)
        }
        return changed
    }
}
