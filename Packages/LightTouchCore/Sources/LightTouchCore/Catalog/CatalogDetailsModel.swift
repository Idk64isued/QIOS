// The Store's version sheet's state (CatalogDetailsView, the app's): the app's archived copies that run on this
// device, the chosen copy revalidated against the server, and what Install will fetch.

import Foundation
import Observation

@MainActor @Observable public final class CatalogDetailsModel {
    public typealias Row = (version: CatalogVersion, copy: CatalogVersion.Copy)
    public let app: CatalogApp
    /// The device's model, iOS version and executable slice (its catalog entry).
    public let device: String?, deviceOS: String, arch: String
    public let installedVersion: String?
    public let canInstall: () -> Bool
    public let install: (CatalogApp) -> Void
    public var close: () -> Void = {}

    /// nil while loading.
    public var rows: [Row]?
    /// The chosen copy's ipa_id.
    public var selection: String?
    public var details: CatalogCopy?
    /// Why the chosen copy can't be installed, or why nothing loaded.
    public var problem: String?
    /// The revalidated copy Install will fetch.
    public var candidate: CatalogApp?

    public init(
        app: CatalogApp,
        device: String?,
        deviceOS: String,
        arch: String,
        installedVersion: String?,
        canInstall: @escaping () -> Bool,
        install: @escaping (CatalogApp) -> Void
    ) {
        self.app = app
        self.device = device
        self.deviceOS = deviceOS
        self.arch = arch
        self.installedVersion = installedVersion
        self.canInstall = canInstall
        self.install = install
    }

    public var selectedRow: Row? { rows?.first { $0.copy.ipaID == selection } }

    public func title(_ row: Row) -> String {
        let size = row.copy.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        // Two archived copies of one version need their copy number to tell apart.
        let twin = (rows ?? []).filter { $0.version.version == row.version.version }.count > 1
        return [row.version.version ?? "Unknown", size, twin ? "Copy \(row.copy.ipaID)" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// Choosing an older version than the one installed: the only case where data is at risk.
    public var downgradeNote: String? {
        guard let installedVersion, let chosen = selectedRow?.version.version,
            chosen.compare(installedVersion, options: .numeric) == .orderedAscending
        else { return nil }
        return "Version \(installedVersion) is installed. An older version may not read its data."
    }

    public func load() async {
        guard rows == nil else { return }
        do {
            let records = try await CatalogClient.versions(for: app)
            let found: [Row] = records.flatMap { version in
                version.copies.filter { copy in
                    copy.ipaID == String(app.ipaID)
                        || (copy.installStatus == "installable" && CatalogCopy.runs(copy.architectures, on: arch)
                            && CatalogCopy.osIssue(version.minimumOSVersion, deviceOS: deviceOS) == nil
                            && CatalogCopy.osIssue(copy.machOMinOS, deviceOS: deviceOS) == nil)
                }.map { (version, $0) }
            }
            rows = found
            guard !found.isEmpty else {
                problem = "No version of this app runs on this device."
                return
            }
            selection = found.first { $0.copy.ipaID == String(app.ipaID) }?.copy.ipaID ?? found[0].copy.ipaID
        } catch {
            guard !Task.isCancelled else { return }
            rows = []
            problem = "Couldn’t load versions: \(error.localizedDescription)"
        }
    }

    /// Runs for each selection; the view cancels it when the selection changes.
    public func check() async {
        guard let row = selectedRow, row.copy.ipaID != details?.ipaID else { return }
        details = nil
        candidate = nil
        problem = nil
        do {
            guard let id = Int(row.copy.ipaID), id > 0 else {
                throw CatalogError.invalidCopy("The archive returned an invalid copy identifier.")
            }
            let copy = try await CatalogClient.copyDetails(id)
            try Task.checkCancellation()
            details = copy
            if let issue = copy.unavailableReason(
                minimumOS: row.version.minimumOSVersion,
                deviceOS: deviceOS,
                arch: arch
            ) {
                problem = issue
                return
            }
            let found = try await CatalogClient.compatibleCopy(id, device: device, os: deviceOS)
            try Task.checkCancellation()
            guard found.bundleID == app.bundleID else {
                throw CatalogError.invalidCopy("This copy belongs to a different app.")
            }
            candidate = found
        } catch {
            guard !Task.isCancelled else { return }
            problem = error.localizedDescription
        }
    }

    public var canInstallSelection: Bool { candidate != nil && canInstall() }

    public func installSelection() {
        guard let candidate, canInstall() else { return }
        install(candidate)
        close()
    }
}
