import FirmwareKit
import FirmwareSchema
import Foundation

@concurrent func bootAdmissionCommand(_ command: FirmwareCommand.BootAdmit) async -> Int32 {
    do {
        let device = fileURL(command.device)
        let admitted = try await FirmwareBootAdmission.admit(
            device: device,
            policy: try VolumeRecordPolicy(command.recordPolicy, device: device),
            allowRaw: command.allowRaw
        )
        commandOutput.write(try admitted.jsonData() + Data("\n".utf8))
        return 0
    } catch {
        if Task.isCancelled { return 143 }
        let message = String(describing: error)
        FirmwareDiagnostics.write(Data("firmwarekit boot-admit: \(message)\n".utf8))
        if let output = try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys]) {
            commandOutput.write(output + Data("\n".utf8))
        }
        return 1
    }
}

extension VolumeRecordPolicy {
    /// The command line's --record-policy for `device`.
    init(_ policy: RecordPolicy, device: URL) throws {
        switch policy {
        case .standalone: self = .standalone
        case .managed: self = try .managedDeviceDirectory(device)
        }
    }
}
