import Foundation

/// Resources of the host service executable, independent of GUI and firmware
/// preparation. It links libimobiledevice from its bundle's Frameworks (Debug: the vendor directory or Homebrew).
public nonisolated enum HostServiceResources {
    public static let stagingSession =
        ProcessInfo.processInfo.environment["LTM_SERVICE_STAGING_SESSION"] ?? UUID().uuidString
    public static var udid: String? {
        ProcessInfo.processInfo.environment["LTM_SERVICE_UDID"].flatMap { $0.isEmpty ? nil : $0 }
    }
    /// The services worker beside this executable; in Debug (tests, the sessions drivers) LTM_HOST_SERVICE_WORKER
    /// names another. A Release build spawns only the bundled one.
    public static var executable: String? {
        #if DEBUG
            if let override = ProcessInfo.processInfo.environment["LTM_HOST_SERVICE_WORKER"] {
                return FileManager.default.isExecutableFile(atPath: override) ? override : nil
            }
        #endif
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(
            "LightTouchServices"
        ).path
        return sibling.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }
}
