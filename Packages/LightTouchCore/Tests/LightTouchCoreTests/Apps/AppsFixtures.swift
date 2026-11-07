import Foundation
import HostServiceWire

@testable import LightTouchCore

/// Rows for the Apps inspector's tests: installed apps, Store results and install jobs in a given state.
enum Apps {
    static let deviceID = UUID()
    static func device(
        canQueueInstall: Bool = true,
        canReachDevice: Bool = true,
        installing: Bool = false,
        paused: Bool = false
    ) -> AppsDevice {
        AppsDevice(
            id: deviceID,
            canQueueInstall: canQueueInstall,
            canReachDevice: canReachDevice,
            installing: installing,
            transfersPaused: paused
        )
    }
    static func installed(_ id: String, version: String = "1.0") -> InstalledApp {
        InstalledApp(id: id, name: id.capitalized, version: version)
    }
    static func store(
        _ ipaID: Int,
        _ bundleID: String?,
        name: String? = nil,
        unavailable: Bool = false,
        page: Bool = true
    ) -> CatalogApp {
        CatalogApp(
            bundleID: bundleID,
            name: name ?? bundleID?.capitalized ?? "App \(ipaID)",
            developer: "Developer",
            size: 5_000_000,
            ipaID: ipaID,
            downloadURL: URL(string: "https://example.invalid/ipa/\(ipaID)")!,
            appURL: page ? URL(string: "https://example.invalid/app/\(ipaID)") : nil,
            compat: unavailable ? .init(compatible: false, reasons: ["requires_ios_4.1"]) : nil
        )
    }
    static func job(
        _ name: String = "Job",
        status: String = "Installing…",
        bundleID: String? = nil,
        catalog: Int? = nil,
        progress: Double? = nil,
        failed: Bool = false,
        finished: Bool = false,
        cancelled: Bool = false,
        cancellable: Bool = true,
        dismissed: Bool = false
    ) -> InstallJob {
        let job = InstallJob(name: name, device: deviceID)
        job.status = status
        job.bundleID = bundleID
        job.catalogIpaID = catalog
        job.downloadProgress = progress
        job.failed = failed
        job.isFinished = finished
        job.isCancellable = cancellable
        job.dismissed = dismissed
        if cancelled {
            job.task = Task {}
            job.cancel()
        }
        return job
    }
}
