// firmwarekit mount | export | unmount (see main.swift).
import FirmwareKit
import FirmwareSchema
import Foundation

private func line(_ object: [String: Any]) {
    let data =
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
        ?? Data(#"{"error":"unencodable output"}"#.utf8)
    commandOutput.write(data + Data("\n".utf8))
}

private func failed(_ error: Error) -> Int32 {
    if Task.isCancelled { return 143 }
    FirmwareDiagnostics.write(Data("firmwarekit: \(error)\n".utf8))
    line(["error": "\(error)"])
    return 1
}

@concurrent func unmountCommand(_ command: FirmwareCommand.Unmount) async -> Int32 {
    do {
        try await VolumeExport.unmount(out: fileURL(command.out))
        line(["unmounted": fileURL(command.out).path])
        return 0
    } catch { return failed(error) }
}

/// mount, or with `export` export.
@concurrent func volumeCommand(
    device: String,
    volume: FirmwareCommand.Volume,
    out: String?,
    root: String?,
    recordPolicy: RecordPolicy,
    export: Bool = false
) async -> Int32 {
    do {
        let device = fileURL(device)
        let volumes: Set<String>? = volume == .all ? nil : [volume.rawValue]
        let out =
            out.map(fileURL)
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("firmwarekit-\(export ? "export" : "mount")-\(UUID().uuidString)")
        let src = try VolumeExport.Source(device: device, policy: VolumeRecordPolicy(recordPolicy, device: device))
        let log = { (s: String) in FirmwareDiagnostics.write(Data("firmwarekit: \(s)\n".utf8)) }
        let vols =
            export
            ? try await VolumeExport.export(src, volumes: volumes, out: out, log: log)
            : try await VolumeExport.mount(src, volumes: volumes, out: out, root: root.map(fileURL), log: log)
        for v in vols {
            let o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as? [String: Any] ?? [:]
            line(o.merging(["out": out.path]) { a, _ in a })
        }
        return 0
    } catch { return failed(error) }
}
