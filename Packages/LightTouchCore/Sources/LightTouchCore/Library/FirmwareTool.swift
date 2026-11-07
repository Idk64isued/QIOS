import FirmwareSchema
import Foundation
import HostRuntime
import HostServiceWire
import Subprocess
import System

/// Narrow host boundary: the GUI requests operations; FirmwareKit owns formats.
public nonisolated enum FirmwareTool {
    /// FirmwareKit validates/migrates stopped storage and releases ownership
    /// before DeviceRuntime spawns the helper. No live NOR writer is hosted here.
    /// The worker's report: whether the storage changed, and a quiet notice for the window, if any. What it says on
    /// stderr (a storage migration's steps and failures) goes to `log`.
    public static func admitBoot(device: URL, managed: Bool, executable: URL, log: URL? = nil) async throws
        -> FirmwareWire.BootAdmission
    {
        let data = try await run(
            FirmwareCommand.BootAdmit(
                device: device,
                recordPolicy: managed ? .managed : .standalone,
                allowRaw: !managed
            ),
            executable: executable,
            log: log
        )
        let report = try JSONDecoder().decode(FirmwareWire.BootAdmission.self, from: data)
        guard report.event == "admitted" else {
            throw DeviceToolsError.failed("The firmware worker did not admit this device.")
        }
        return report
    }

    /// A stopped device's boot admission as Start runs it (EmulatorController.start; sessions single --managed):
    /// admitBoot under the managed policy, then the record it left, which must still be this device, and the
    /// storage proof the helper checks before it boots.
    public static func admitStart(_ instance: DeviceInstance, executable: URL, log: URL? = nil) async throws
        -> (instance: DeviceInstance, report: FirmwareWire.BootAdmission, proof: StorageBootProof)
    {
        let report = try await admitBoot(
            device: instance.paths.directory,
            managed: true,
            executable: executable,
            log: log
        )
        try Task.checkCancellation()
        let recordBytes = try Data(contentsOf: DeviceRecord.url(instance.paths.directory))
        let refreshed = try DeviceInstance.decoder.decode(DeviceInstance.self, from: recordBytes)
        guard refreshed.format <= DeviceInstance.currentFormat else { throw DeviceInstance.NewerFormat() }
        guard refreshed.id == instance.id, refreshed.board == instance.board else {
            throw DeviceToolsError.failed("The device identity changed while preparing to start.")
        }
        return (refreshed, report, try StorageBootProof.capture(recordBytes: recordBytes))
    }

    /// iPhone OS 1.x: `certificate` (DER) as a system anchor in the stopped device (`firmwarekit edit --action
    /// trust-anchor`, a stopped edit through the 1.x FTL). Nothing when the device already trusts it.
    public static func trustAnchor(device: URL, certificate: URL, executable: URL) async throws -> Bool {
        let data = try await run(
            FirmwareCommand.Edit(device: device, action: .trustAnchor, recordPolicy: .managed, cert: certificate),
            executable: executable
        )
        struct Report: Decodable { let changed: Bool }
        return try JSONDecoder().decode(Report.self, from: data).changed
    }

    /// iPhone OS 1.x: `changes` into the stopped device's preferences (`firmwarekit edit --action preferences`, a
    /// stopped edit through the 1.x FTL). False when the device holds them already.
    public static func writePreferences(device: URL, changes: [GuestDefault], executable: URL) async throws -> Bool {
        let plist = changes.map { d -> [String: Any] in
            var entry: [String: Any] = ["domain": d.domain, "key": d.key]
            entry["value"] = d.value?.object
            return entry
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("prefs-\(UUID().uuidString).plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = try await run(
            FirmwareCommand.Edit(device: device, action: .preferences, recordPolicy: .managed, prefs: file),
            executable: executable
        )
        struct Report: Decodable { let changed: Bool }
        return try JSONDecoder().decode(Report.self, from: data).changed
    }

    /// `log`: where the worker's stderr is kept (appended, rotated), whether it succeeds or not.
    public static func run(_ command: some FirmwareCommandLine, executable: URL, log: URL? = nil) async throws -> Data {
        let child = try await Subprocess.run(
            .path(FilePath(executable.path)),
            arguments: Arguments(command.arguments),
            input: .none,
            output: .string(limit: 65536),
            error: .string(limit: 65536)
        )
        if let log, !child.standardError.isEmpty { RotatingLog(url: log).append(Data(child.standardError.utf8)) }
        guard child.terminationStatus == .exited(0) else {
            throw DeviceToolsError.failed(child.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Data(child.standardOutput.utf8)
    }
}
