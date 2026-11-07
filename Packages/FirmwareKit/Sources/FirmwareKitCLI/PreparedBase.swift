// firmwarekit pack-base --base DIR --out ITBASE [--reuse PREVIOUS]   a create output packed (the release build)
// firmwarekit unpack-base --blob ITBASE --out DIR --seed S            that as a device of its own, in the Mac's language
//   [--language TAG] [--keyboards IDS] [--hfs kernel|writer]          (or TAG's, as create) (the app, like create: JSON
//                                                                     Lines on stdout, done names the lock)

import FirmwareKit
import FirmwareSchema
import Foundation

func packBaseCommand(_ command: FirmwareCommand.PackBase) -> Never {
    do {
        try PreparedBase.pack(
            base: URL(fileURLWithPath: command.base),
            to: URL(fileURLWithPath: command.out),
            reuse: command.reuse.map { URL(fileURLWithPath: $0) }
        )
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("firmwarekit pack-base: \(error)\n".utf8))
        exit(1)
    }
}

func unpackBaseCommand(_ command: FirmwareCommand.UnpackBase) async -> Int32 {
    let staging = URL(fileURLWithPath: command.out)
    do {
        emit(.begin(steps: 3))
        emit(.step(index: 1, name: "Unpacking"))
        try PreparedBase.unpack(URL(fileURLWithPath: command.blob), into: staging) { fraction in
            try Task.checkCancellation()
            emit(.progress(fraction))
        }
        emit(.step(index: 2, name: "Writing the identity"))
        try PreparedBase.reseed(staging, seed: command.seed)
        emit(.step(index: 3, name: "Setting the language"))
        try await VolumeMount.$backend.withValue(command.hfs ?? VolumeMount.backend) {
            try await PreparedBase.seedLanguage(
                staging,
                tag: command.language,
                keyboards: command.keyboards.map { $0.split(separator: ",").map(String.init) }
            )
        }
        emit(.done(lock: "device.lock.json"))
        return 0
    } catch {
        if Task.isCancelled { return 143 }
        FirmwareDiagnostics.write(Data("firmwarekit: \(error)\n".utf8))
        emit(Preparer.errorEvent(error))
        return 1
    }
}
