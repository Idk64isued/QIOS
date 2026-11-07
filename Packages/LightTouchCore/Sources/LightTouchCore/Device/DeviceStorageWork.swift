// Deletions and erases of devices with no running session, by catalog entry id. Removing a prepared device's tree
// (its NAND, a read-only base) or its overlay takes seconds, so the work runs off the main actor; the row reads `busy`
// to show Deleting or Erasing and refuse Start until it's done. Foundation only, so tests/offline runs the real one.

import Foundation

@MainActor public final class DeviceStorageWork {
    public init() {}
    public private(set) var busy: [String: DeviceRow.Busy] = [:]
    /// After an id joins or leaves.
    public var onChange: () -> Void = {}

    public func contains(_ id: String) -> Bool { busy[id] != nil }
    /// Quit waits for these.
    public var isErasing: Bool { busy.values.contains(.erasing) }

    /// Marks `id` busy now, waits for `release` to let go of its session (a shut-down or dead one), then runs
    /// `work` on a background thread; the task finishes (or throws) when it has. A device still running is refused
    /// with DeviceInUse, its storage untouched.
    @discardableResult public func run(
        _ id: String,
        as kind: DeviceRow.Busy = .deleting,
        release: @escaping @MainActor () async -> Bool = { true },
        _ work: @escaping @Sendable () throws -> Void
    ) -> Task<Void, Error> {
        busy[id] = kind
        onChange()
        return Task {
            defer {
                busy[id] = nil
                onChange()
            }
            guard await release() else { throw DeviceInUse() }
            try await Task.detached(priority: .userInitiated) { try work() }.value
        }
    }
}

/// A device started again before its storage could change.
public struct DeviceInUse: LocalizedError {
    public init() {}
    public var errorDescription: String? { "This device is running. Shut it down, then try again." }
}
