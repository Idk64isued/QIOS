import Foundation
import HostServiceWire

/// The services helper's stdout and stderr are pipes to the app. Once the app is gone they have no reader, and
/// FileHandle.write(_:) raises on EPIPE (an ObjC exception, an abort); a write that can't land is dropped instead.
nonisolated func writeDroppingClosedPipe(_ data: Data, to handle: FileHandle) {
    try? handle.write(contentsOf: data)
}

// Synchronous C progress callbacks and the command task share stdout. The
// lock serializes each entire encoded event, so callback bytes cannot interleave.
nonisolated final class EventWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    init(handle: FileHandle = .standardOutput) { self.handle = handle }
    func send(_ event: HostServiceEvent) {
        lock.withLock {
            if let bytes = try? JSONEncoder().encode(event) { writeDroppingClosedPipe(bytes + Data([10]), to: handle) }
        }
    }
}
