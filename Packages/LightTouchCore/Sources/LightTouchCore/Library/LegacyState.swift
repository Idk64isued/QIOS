// State from before devices were prepared from IPSWs: the unpacked
// image under State/device with its active-<nand>.json pointer, the
// nandrw-<key> overlay and snapshot-<key> files beside it, device records
// whose base was that image or a development checkout, and the older
// Application Support/LightTouchMac root. None of it can carry over (the
// overlay only fits the base it was made on), so the app offers once, at
// launch, to erase it and continue. What survives: every retained .ipa
// (into the library).

import Foundation
import HostRuntime

public nonisolated struct LegacyState: Sendable {
    public let state: URL
    /// The pre-library root, still in place.
    public let oldRoot: URL?
    /// What the old layout left in the state root.
    public let items: [URL]
    /// Records made on the old image or a development checkout (`base.kind` other than prepared).
    public let records: [UUID]

    public static let message = "The iPod from an earlier version of Light Touch can’t be used."
    public static let detail = "Erasing it keeps the apps you’ve saved."
    /// The progress window's words while the erase runs.
    public static let progressMessage = "Erasing the earlier iPod…"

    /// Written when Erase and Continue starts, removed once it has finished or failed: a launch that finds it (the
    /// app quit midway) carries on without asking again, and one after a failure asks again.
    public static func marker(_ state: URL) -> URL { state.appendingPathComponent(".legacy-erase") }
    /// The user already chose Erase and Continue; this launch finishes it.
    public var resuming: Bool { FileManager.default.fileExists(atPath: Self.marker(state).path) }

    /// Whether anything of the old layout is here. `applicationSupport` is
    /// nil for an isolated run (LTM_STATE_DIR), which has no old root.
    public static func find(state: URL, applicationSupport: URL?) -> LegacyState? {
        let fm = FileManager.default
        let oldRoot = applicationSupport.map { $0.appendingPathComponent("LightTouchMac", isDirectory: true) }
            .flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
        var items: [URL] = []
        for name in (try? fm.contentsOfDirectory(atPath: state.path)) ?? []
        where name == "device" || name == "AppCache" || name == "IPAs" || name.hasPrefix("nandrw-")
            || name.hasPrefix("snapshot-")
            || name.hasPrefix(".reset-") || name.hasPrefix("app.log") || name.hasPrefix("serial.log")
            || name.hasPrefix("web-proxy.")
        {
            items.append(state.appendingPathComponent(name))
        }
        for name in ["usbmuxd.log", "usbmuxd.log.1", "usbmuxd.pid", "session.env"] {
            let url = state.appendingPathComponent("work/\(name)")
            if fm.fileExists(atPath: url.path) { items.append(url) }
        }
        var records: [UUID] = []
        let devices = state.appendingPathComponent("Devices", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: devices.path)) ?? [] {
            guard let id = UUID(uuidString: name),
                let data = try? Data(contentsOf: DeviceRecord.url(devices.appendingPathComponent(name))),
                let json = try? DeviceRecord.object(data),
                let kind = (json["base"] as? [String: Any])?["kind"] as? String, kind != "prepared"
            else { continue }
            records.append(id)
        }
        guard oldRoot != nil || !items.isEmpty || !records.isEmpty || fm.fileExists(atPath: marker(state).path) else {
            return nil
        }
        return LegacyState(state: state, oldRoot: oldRoot, items: items, records: records)
    }

    /// The directories whose .ipa files go into the library first.
    public var ipaDirectories: [URL] {
        var dirs = [state.appendingPathComponent("IPAs")]
        dirs += records.map { DeviceInstance.directory($0, state: state).appendingPathComponent("IPAs") }
        if let oldRoot { dirs.append(oldRoot.appendingPathComponent("IPAs")) }
        return dirs
    }

    /// Erase and Continue: the .ipa files into the library, then everything
    /// else of the old layout removed, the old root included. Never a path outside `state` or the
    /// old root. Off the main actor (hashing the IPAs and removing the old
    /// trees takes a while), and idempotent: a run the app quit in the middle
    /// of is finished by the next launch (adopted IPAs aren't read again, a
    /// record goes by rename, whatever is still here is removed).
    @concurrent public func erase() async throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: Self.marker(state).path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: Self.marker(state).path])
        }
        do { try await removeAll() } catch {
            try? fm.removeItem(at: Self.marker(state))
            throw error
        }
    }

    @concurrent private func removeAll() async throws {
        let fm = FileManager.default
        var missed: [URL] = []
        for directory in ipaDirectories { missed += await IPALibrary.adopt(copies: directory) }
        // The alert promised the saved apps survive: nothing goes while one isn't in the library.
        if let first = missed.first {
            throw CocoaError(
                .fileReadUnknown,
                userInfo: [
                    NSFilePathErrorKey: first.path,
                    NSLocalizedDescriptionKey:
                        "\(missed.count == 1 ? "An app" : "\(missed.count) apps") you saved couldn’t be kept, so nothing was erased."
                ]
            )
        }
        for record in records {
            try DeviceStateStorage.removeDevice(record, state: state)
        }
        for item in items {
            try DeviceStateStorage.checkRemovable(item, state: state, owner: nil)
            try DeviceStateStorage.removeTree(item)
        }
        if let oldRoot { try DeviceStateStorage.removeTree(oldRoot) }
        try fm.removeItem(at: Self.marker(state))
        logEvent(
            "legacy: erased the pre-library state (\(items.count) items, \(records.count) records\(oldRoot == nil ? "" : ", the old root"))"
        )
    }
}
