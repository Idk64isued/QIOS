import FirmwareKit
import FirmwareSchema
import Foundation

func developerOfferCommand(_ command: FirmwareCommand.DeveloperOffer) -> Never {
    do {
        guard let id = UUID(uuidString: command.instance) else {
            throw FirmwareError(.unsupported, "developer-offer --instance takes a UUID")
        }
        let result = try DeveloperTools.augment(
            offer: URL(fileURLWithPath: command.offer),
            payload: URL(fileURLWithPath: command.payload),
            state: URL(fileURLWithPath: command.state),
            instance: id,
            authorizedPublicKey: try command.publicKey.map {
                try String(contentsOfFile: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            },
            serial: command.serial
        )
        FileHandle.standardOutput.write(try JSONEncoder().encode(result) + Data("\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("developer-offer: \(error)\n".utf8))
        exit(1)
    }
}

func developerAuditCommand(_ command: FirmwareCommand.DeveloperAudit) -> Never {
    do {
        try DeveloperTools.audit(payload: URL(fileURLWithPath: command.payload), redistribution: true)
        print("PASS: qualified developer binaries, sources and notices; no instance state")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("developer-audit: \(error)\n".utf8))
        exit(1)
    }
}
