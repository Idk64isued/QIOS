import Foundation

/// Seconds a boot has spent toward its lit budget: none until boot admission ends, as in the app, since admission may
/// migrate the device's storage for minutes first.
public func litSeconds(admitted: Date?, now: Date = Date()) -> Double {
    admitted.map { now.timeIntervalSince($0) } ?? 0
}
