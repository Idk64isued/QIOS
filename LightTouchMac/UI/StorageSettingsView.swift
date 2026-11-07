import Cocoa
import FirmwareSchema
import LightTouchCore
import SwiftUI

/// Settings ▸ Storage: what each device and the app's stores take on disk
/// (allocated bytes: bases and overlays are sparse), with the actions that
/// give it back.
struct StorageSettingsView: View {
    let model: StorageUsage

    var body: some View {
        let usage = model.usage
        Form {
            Section("Devices") {
                if usage.devices.isEmpty { Text("No devices").foregroundStyle(.secondary) }
                // Every record, also one no sidebar row shows (its entry left the catalog, or a newer record for the
                // same entry is the row's): each deletes itself.
                ForEach(usage.devices, id: \.instance.id) { device in
                    StorageRow(
                        title: model.name(device.instance.firmware),
                        detail: "System \(size(device.base)), Data \(size(device.data + device.snapshot))",
                        action: "Delete Device…",
                        enabled: model.canDelete(device.instance)
                    ) { model.delete(device.instance) }
                }
            }
            Section("Firmware") {
                if usage.ipsws.isEmpty { Text("No downloaded or imported IPSWs").foregroundStyle(.secondary) }
                let inUse = model.jobs.ipswsInUse
                ForEach(usage.ipsws, id: \.url) { ipsw in
                    let busy = inUse.contains(ipsw.url.deletingPathExtension().lastPathComponent)
                    let kind = ipsw.url.path.hasPrefix(IPSWStore.shared.imports.path) ? "Imported" : "Downloaded"
                    // A referenced IPSW takes no space here; Remove IPSW leaves its file.
                    let file = ipsw.referenced.map { ($0.path as NSString).abbreviatingWithTildeInPath }
                    StorageRow(
                        title: model.name(ipsw.entry),
                        detail: file.map { "Not copied, \($0)" } ?? "\(kind), \(size(ipsw.bytes))",
                        action: "Remove IPSW",
                        enabled: !busy
                    ) { model.removeIPSW(ipsw.url) }
                }
            }
            Section("Caches and Logs") {
                let preparing = model.jobs.jobs.values.contains {
                    if case .preparing = $0 { true } else { false }
                }
                StorageRow(
                    title: "Decrypted firmware",
                    detail: size(usage.decrypted),
                    action: "Clear Caches",
                    enabled: usage.decrypted > 0 && !preparing
                ) { model.clearCaches() }
                StorageRow(title: "Logs", detail: size(usage.logs))
            }
            Section("Apps") {
                let unused = IPALibrary.unused(devices: DeviceLibrary.shared.instances)
                let unusedBytes = unused.values.reduce(0) { $0 + $1.size }
                StorageRow(
                    title: "Library",
                    detail: "\(IPALibrary.index.count) IPAs, \(size(usage.library))"
                        + (unused.isEmpty ? "" : ", \(size(unusedBytes)) unused"),
                    action: "Remove Unused Apps",
                    enabled: !unused.isEmpty
                ) { model.removeUnusedIPAs() }
            }
        }
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// One row: what it is and its size, and the button that gives the space back.
private struct StorageRow: View {
    let title: String
    let detail: String
    var action: String?
    var enabled = true
    var perform: () -> Void = {}

    var body: some View {
        LabeledContent {
            if let action { Button(action, action: perform).disabled(!enabled) }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

/// What Storage shows, measured off the main thread; measured again when its pane is shown, and while it is shown when
/// the devices, their sessions or the firmware jobs change (which also asks canDelete again).
@Observable final class StorageUsage {
    nonisolated struct DeviceUsage: Sendable {
        let instance: DeviceInstance
        let base: Int64, data: Int64, snapshot: Int64
    }
    nonisolated struct Usage: Sendable {
        var devices: [DeviceUsage] = []
        /// Entry id, file, allocated bytes, and the user's file an import from another volume refers to.
        var ipsws: [(entry: String, url: URL, bytes: Int64, referenced: URL?)] = []
        var decrypted: Int64 = 0
        var logs: Int64 = 0
        /// The IPA store's blobs (the device copies are clones of them).
        var library: Int64 = 0
    }

    private(set) var usage = Usage()
    @ObservationIgnored let catalog: FirmwareCatalog
    @ObservationIgnored let jobs: FirmwareJobs
    /// MainWindowController's Delete Device for one record (its confirmation included), and whether it may run now.
    @ObservationIgnored let delete: (DeviceInstance) -> Void
    @ObservationIgnored let canDelete: (DeviceInstance) -> Bool
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Whether Storage is on screen: changes measure again only then (a download changes its job many times a second).
    @ObservationIgnored var isShown: () -> Bool = { false }

    init(
        catalog: FirmwareCatalog = .bundled,
        jobs: FirmwareJobs,
        delete: @escaping (DeviceInstance) -> Void,
        canDelete: @escaping (DeviceInstance) -> Bool
    ) {
        self.catalog = catalog
        self.jobs = jobs
        self.delete = delete
        self.canDelete = canDelete
        observers = [
            DeviceLibrary.didChangeNotification, FirmwareJobs.didChangeNotification,
            DeviceSessionHost.didChangeNotification
        ].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.isShown() == true { self?.reload() } }
            }
        }
        reload()
    }

    func name(_ id: String) -> String {
        catalog.entry(id: id).map { "\($0.marketingName) iOS \($0.version)" } ?? id
    }

    func reload() {
        loading?.cancel()
        let instances = DeviceLibrary.shared.instances
        let catalog = catalog
        let store = IPSWStore.shared
        loading = Task { [weak self] in
            let usage = await Task.detached { Self.measure(instances, catalog: catalog, store: store) }.value
            guard !Task.isCancelled else { return }
            self?.usage = usage
        }
    }

    // MARK: - Measuring

    /// Allocated bytes of a file or a whole tree (links not followed).
    nonisolated static func allocated(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let item = walk?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    nonisolated static func measure(_ instances: [DeviceInstance], catalog: FirmwareCatalog, store: IPSWStore) -> Usage
    {
        var usage = Usage()
        for instance in instances {
            let paths = instance.paths
            let nor =
                paths.writableNOR.flatMap { $0.path.hasPrefix(paths.overlay.path + "/") ? nil : allocated($0) } ?? 0
            let snapshot = [paths.snapshot, paths.snapshotMeta, paths.snapshotTmp, paths.snapshotBad].map(allocated)
                .reduce(0, +)
            usage.devices.append(
                .init(
                    instance: instance,
                    base: allocated(paths.base),
                    data: allocated(paths.overlay) + nor,
                    snapshot: snapshot
                )
            )
        }
        for entry in catalog.entries {
            guard let sha1 = entry.source.sha1 else { continue }
            _ = store.existing(sha1)  // drops a reference whose file is gone or changed
            for url in [store.download(sha1), store.imported(sha1)]
            where FileManager.default.fileExists(atPath: url.path) {
                let referenced = url == store.imported(sha1) ? store.referenced(sha1) : nil
                usage.ipsws.append((entry.id, url, referenced == nil ? allocated(url) : 0, referenced))
            }
        }
        usage.decrypted = allocated(IPSWStore.cachesDirectory.appendingPathComponent("Decrypted", isDirectory: true))
        usage.logs = allocated(Bundled.logsDirectory)
        usage.library = allocated(IPALibrary.directory)
        return usage
    }

    // MARK: - Actions

    func removeIPSW(_ url: URL) {
        let sha1 = url.deletingPathExtension().lastPathComponent
        do {
            // A job that started since the pane was drawn may read it.
            guard !jobs.ipswsInUse.contains(sha1) else { return reload() }
            try IPSWStore.shared.remove(sha1)
            logEvent("storage: removed IPSW \(sha1)")
        } catch { NSApp.presentError(error) }
        reload()
    }

    func removeUnusedIPAs() {
        do {
            try IPALibrary.removeUnused(devices: DeviceLibrary.shared.instances)
            logEvent("storage: removed the IPAs no device has")
        } catch { NSApp.presentError(error) }
        reload()
    }

    /// Only between preparations: a running one reads its decrypt cache.
    func clearCaches() {
        guard let executable = FirmwareJobs.preparer else { return }
        Task {
            do {
                _ = try await FirmwareTool.run(
                    FirmwareCommand.CachePrune(root: IPSWStore.cachesDirectory.appendingPathComponent("Decrypted")),
                    executable: executable
                )
                logEvent("storage: cleared unused decrypt cache")
            } catch { NSApp.presentError(error) }
            reload()
        }
    }
}
