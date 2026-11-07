// What the app (HostServiceClient) and the services helper (its engine) share about one device's host
// services: the endpoint, the device paths both sides validate and the staging names the startup sweep keys
// on, and the Home screen layout's shape.

import Foundation

public nonisolated struct DeviceServices: Sendable {
    public static let session = UUID()
    public let clientSocket: String
    public let endpoint: HostServiceEndpoint
    /// The Files browser's listing, export and copy go through afc2 (a jailbroken device's AFC at "/") instead of
    /// AFC's media folder. Installs and media staging always use the media folder.
    public var wholeFileSystem = false
    /// The Files browser's listing, export, copy and edits go into this app's container (house_arrest) instead.
    public var app: String?
    public var afcRoot: AFCRoot { app.map(AFCRoot.app) ?? (wholeFileSystem ? .fileSystem : .media) }
    public init(clientSocket: String, udid: String? = nil, session: UUID = Self.session) {
        self.clientSocket = clientSocket
        self.endpoint = HostServiceEndpoint(socket: clientSocket, udid: udid, session: session)
    }
}

extension DeviceServices {
    public static func validateFilePath(_ path: String) throws {
        guard !path.hasPrefix("/"), !path.contains("\0"),
            path.isEmpty
                || path.split(separator: "/", omittingEmptySubsequences: false)
                    .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw DeviceError.preflight("Invalid device file path.")
        }
    }

    /// A stable device-side filename from the .ipa: staging paths must survive
    /// odd characters (`Super Monkey Ball [SEGA]`), so reduce to a safe set.
    /// Unique per upload. Collapsing punctuation to "_" made "Temple Run",
    /// "Temple-Run" and "Temple.Run" all stage to one path, so re-dropping a
    /// newer build landed on a file the device still held open from the last
    /// attempt — AFC refused it (the bare "File-transfer error: code 1") — and
    /// one install's fire-and-forget cleanup could delete the next install's
    /// upload out from under it. A unique suffix removes both.
    public static let stagingSession = HostServiceResources.stagingSession

    public static func stagingName(_ ipa: URL) -> String {
        let base = ipa.deletingPathExtension().lastPathComponent
        let safe = String(base.map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(48))
        return "\(safe)-\(stagingSession)-\(UUID().uuidString.prefix(8)).ipa"
    }

    /// Startup cleanup can run after a new upload begins. Session-tagged names
    /// protect every upload from this process, including ones not yet queued.
    /// Public for the engine's sweep.
    public static func isOrphanedStagingName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.contains("-\(stagingSession)-")
    }

    public static func isOrphanedMediaUpload(_ name: String) -> Bool {
        let parts = name.components(separatedBy: ".upload-")
        guard parts.count == 2,
            ["audio.mp3", "audio.m4a", "audio.aac", "audio.wav", "image.jpg"].contains(parts[0]),
            !parts[1].hasPrefix(stagingSession + "-")
        else { return false }
        let suffix = parts[1]
        if UUID(uuidString: suffix) != nil { return true }  // Earlier atomic uploads.
        return suffix.count == 73 && suffix[suffix.index(suffix.startIndex, offsetBy: 36)] == "-"
            && UUID(uuidString: String(suffix.prefix(36))) != nil
            && UUID(uuidString: String(suffix.suffix(36))) != nil
    }
}

/// The icon state's shape: flattened to bundle IDs and refilled from them.
public nonisolated enum HomeScreenLayout {
    /// Every displayIdentifier in the state, in layout order. Folders on later
    /// iOS keep their children in `iconLists`; flattening them keeps this
    /// honest on a device that has any, even though 3.1.3 cannot make one.
    public static func flatten(_ state: [Any]) -> [String] {
        var ids: [String] = []
        func walk(_ node: Any) {
            if let list = node as? [Any] {
                list.forEach(walk)
            } else if let icon = node as? [String: Any] {
                if let id = icon["displayIdentifier"] as? String { ids.append(id) }
                if let lists = icon["iconLists"] { walk(lists) }
            }
        }
        walk(state)
        return ids
    }

    /// The same page/dock structure, refilled from `order`. Slot counts are
    /// preserved, so nothing is pushed onto a page that cannot hold it — the
    /// device decides how many icons fit, and we are in no position to argue.
    public static func rebuild(_ state: [Any], order: [String]) -> [Any] {
        var remaining = order[...]
        func refill(_ node: Any) -> Any {
            if let list = node as? [Any] { return list.map(refill) }
            if var icon = node as? [String: Any] {
                if icon["displayIdentifier"] != nil, let next = remaining.first {
                    remaining = remaining.dropFirst()
                    icon["displayIdentifier"] = next
                }
                if let lists = icon["iconLists"] { icon["iconLists"] = refill(lists) }
                return icon
            }
            return node
        }
        return state.map(refill)
    }
}
