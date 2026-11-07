import FirmwareKit
import FirmwareSchema
import Foundation

func cacheCommand(_ command: FirmwareCommand.CachePrune) -> Never {
    do {
        try FirmwareCache.prune(root: URL(fileURLWithPath: command.root), ipsw: command.ipsw)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("firmwarekit cache-prune: \(error)\n".utf8))
        exit(1)
    }
}

/// `firmwarekit detach-images --root DIR`: the app's launch sweep of Preparing/.
@concurrent func detachImagesCommand(_ command: FirmwareCommand.DetachImages) async -> Int32 {
    do {
        try await DiskImage.detachAll(under: URL(fileURLWithPath: command.root))
        return 0
    } catch {
        FileHandle.standardError.write(Data("firmwarekit detach-images: \(error)\n".utf8))
        return 1
    }
}
