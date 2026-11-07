import FirmwareSchema
import Foundation
import HostRuntime

/// The 1.x admission step: a stopped edit writes the Wi-Fi known network and the PAC'd AirPort service where the
/// firmware's configd reads them, as the recipe does now (N45Board.seedSystemConfiguration: root's home, or
/// /private/var/preferences from 1.1.3), merged into the files configd has written there by then. It runs on
///   - a device whose base's recipe FirmwareWire.admissionRecipeSteps declares (n45 2 -> 3, m68 1 -> 2): prepared
///     before 8a54efd, with them under /private/var/preferences, where 1.0 to 1.1.2 never look;
///   - a 1.1.3 or later device whose base was prepared before 44b92c0b (preparation serial 15), with them in root's
///     home, where configd from 1.1.3 never looks; those copies are removed.
///
/// The edit lands in the overlay, so the overlay records it (`stamp`): an edit clones the overlay and keeps it, and
/// Erase removes the overlay, so an erased device takes the step again at its next start. A storage-key marker
/// would not do: Erase keeps the key, and every edit (the proxy's trust anchor among them) changes it.
public nonisolated enum N45Migration {
    /// -2: the set's global Proxies too (cellular through the web proxy); -3: from 1.1.3 in /private/var/preferences.
    /// A device stamped by an earlier version takes the step again (seedSystemConfiguration merges, so it only adds
    /// what is missing).
    static let stamp = ".n45-sc-prefs-3"
    /// The preparation serial (PreparationChanges) from which a base has them where 1.1.3 and later read them.
    static let placedSerial = 15

    /// Runs the step on a stopped 1.x device that needs it. True when it edited. The caller holds no lease.
    nonisolated(nonsending) public static func systemConfiguration(
        device: URL,
        policy: StorageRecordPolicy = .standalone,
        allowRaw: Bool = false,
        log: (String) -> Void = { _ in }
    ) async throws -> Bool {
        guard let step = try pending(device: device, policy: policy, allowRaw: allowRaw) else { return false }
        let session = try await StoppedVolumeEdit.begin(device: device, policy: policy, log: log)
        do {
            let point = session.image.deletingLastPathComponent().appendingPathComponent("sc-prefs-mount")
            try await VolumeMount.withVolume(session.image, at: point) { v in
                _ = try N45Board.seedSystemConfiguration(v)
                let rootHome = N45Board.rootLibrary + "/Preferences/SystemConfiguration"
                if N45Board.scPrefs(v) != rootHome { try? v.remove(rootHome) }
            }
            try await StoppedVolumeEdit.commit(device: device, id: session.id, policy: policy, log: log)
        } catch {
            try? await StoppedVolumeEdit.discard(device: device, id: session.id, policy: policy)
            throw error
        }
        log("SystemConfiguration preferences written (recipe \(step))")
        let owner = try OwnedStorageRecord.acquire(device: device, policy: policy)
        defer { withExtendedLifetime(owner) {} }
        if let overlay = owner.paths?.overlay {
            try N72NAND.writeDurably(Data(), to: overlay.appendingPathComponent(stamp))
        }
        try N72NAND.writeDurably(
            JSONSerialization.data(withJSONObject: ["recipe": step, "step": "n45-sc-prefs"], options: [.sortedKeys]),
            to: device.appendingPathComponent(FirmwareWire.migratedRecipeFile)
        )
        return true
    }

    /// The recipe the device has after the step (a declared step's, else its base's own), or nil: not 1.x, not
    /// misplaced, or already stamped.
    static func pending(device: URL, policy: StorageRecordPolicy, allowRaw: Bool = false) throws -> Int? {
        let owner = try OwnedStorageRecord.acquire(device: device, policy: policy, allowRaw: allowRaw)
        defer { withExtendedLifetime(owner) {} }
        guard let bytes = owner.bytes, let paths = owner.paths,
            let board = (try? DeviceRecord.object(bytes))?["board"] as? String,
            HostRuntime.Board(rawValue: board)?.soc == .s5l8900,
            let lock = (try? DeviceLock.read(base: paths.base)) ?? nil, let recipe = lock.recipeVersion,
            !FileManager.default.fileExists(atPath: paths.overlay.appendingPathComponent(stamp).path)  // host file
        else { return nil }
        if let step = FirmwareWire.admissionRecipeSteps[board]?[recipe] { return step }
        let version = lock.entry?["content"]?["version"]?.string ?? ""
        let misplaced =
            (lock.other["preparation"]?.int ?? 0) < placedSerial && version.hasPrefix("1.")
            && version.compare("1.1.3", options: .numeric) != .orderedAscending
        return misplaced ? recipe : nil
    }
}
