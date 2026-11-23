import Foundation
import SwiftUI

/// Legacy Store's downloads: what is downloading or installing now, what is waiting its turn, and what came down
/// before, as the store's Downloads tab lists them. It outlives the store sheet, so closing the store doesn't stop
/// a download, and the IPAs stay in the Downloads cache (Library.downloads/ipa-N) so an app can go onto another
/// device, or back onto this one, without fetching it again. Finished entries are remembered across launches.
@MainActor
final class StoreDownloads: ObservableObject {
    static let shared = StoreDownloads()

    struct Entry: Codable, Identifiable, Equatable {
        enum State: String, Codable { case waiting, downloading, installing, installed, downloaded, failed }
        let id: UUID
        let ipaID: Int
        let name: String
        let developer: String?
        let version: String?
        let iconURL: URL?
        let size: Int64?
        var state: State
        var progress: Double = 0
        var status: String = ""
        var file: String?            // the IPA, relative to Library.downloads, once it is down
        var date = Date()

        var isActive: Bool { state == .waiting || state == .downloading || state == .installing }
        /// The IPA on disk, if it is still there (the system may clear the cache).
        var fileURL: URL? {
            guard let file else { return nil }
            let url = Library.downloads.appendingPathComponent(file)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    @Published private(set) var entries: [Entry] = []
    /// The catalog entries waiting their turn (the download address and checksum aren't remembered across launches).
    private var pending: [UUID: (app: CatalogApp, agent: GuestAgent?, install: Bool)] = [:]
    private var worker: Task<Void, Never>?
    private static let key = "storeDownloads"
    private static let keep = 60

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           var saved = try? JSONDecoder().decode([Entry].self, from: data) {
            // Anything that was mid-way when the app last quit didn't finish.
            for i in saved.indices where saved[i].isActive {
                saved[i].state = .failed
                saved[i].status = "Stopped when Halcyon closed."
            }
            entries = saved
        }
    }

    var activeCount: Int { entries.filter(\.isActive).count }
    func activeEntry(ipaID: Int) -> Entry? { entries.first { $0.ipaID == ipaID && $0.isActive } }
    /// The newest entry with this app's IPA still on disk.
    func downloadedFile(ipaID: Int) -> URL? { entries.first { $0.ipaID == ipaID && $0.fileURL != nil }?.fileURL }

    /// Queues a download, and an install onto `agent`'s device when there is one. Returns false if it's already queued.
    @discardableResult
    func enqueue(_ app: CatalogApp, store: LegacyStoreClient, agent: GuestAgent?) -> Bool {
        guard activeEntry(ipaID: app.ipaID) == nil else { return false }
        let entry = Entry(id: UUID(), ipaID: app.ipaID, name: app.name, developer: app.developer, version: app.version,
                          iconURL: app.iconURL, size: app.size, state: .waiting, status: "Waiting\u{2026}")
        entries.insert(entry, at: 0)
        pending[entry.id] = (app, agent, agent != nil)
        self.store = store
        save()
        pump()
        return true
    }

    /// Installs an IPA that is already down onto a running device.
    func reinstall(_ entry: Entry, agent: GuestAgent) {
        guard let file = entry.fileURL, activeEntry(ipaID: entry.ipaID) == nil else { return }
        var fresh = entry
        fresh.state = .waiting
        fresh.status = "Waiting\u{2026}"
        fresh.progress = 0
        fresh.date = Date()
        update(entry.id) { $0 = fresh }
        Task { await self.installStep(entry.id, file: file, agent: agent) }
    }

    func remove(_ entry: Entry) {
        guard !entry.isActive else { return }
        entries.removeAll { $0.id == entry.id }
        // The IPA goes with the last entry that names it (a reinstall or a second download shares the file).
        if let file = entry.fileURL, !entries.contains(where: { $0.file == entry.file }) {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        save()
    }

    /// Forgets the finished entries and deletes their IPAs.
    func clearFinished() {
        for entry in entries where !entry.isActive { remove(entry) }
    }

    var downloadedBytes: Int64 {
        entries.reduce(0) { total, entry in
            guard let url = entry.fileURL,
                  let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return total }
            return total + Int64(size)
        }
    }

    // MARK: - The queue: one download at a time, oldest first

    private weak var store: LegacyStoreClient?

    private func pump() {
        guard worker == nil else { return }
        worker = Task {
            while let next = entries.last(where: { $0.state == .waiting && pending[$0.id] != nil }) {
                await run(next.id)
            }
            worker = nil
        }
    }

    private func run(_ id: UUID) async {
        guard let job = pending.removeValue(forKey: id) else { return }
        let client = store ?? LegacyStoreClient()
        update(id) { $0.state = .downloading; $0.status = "Downloading\u{2026}"; $0.progress = 0 }
        let file: URL
        do {
            if let kept = entries.first(where: { $0.id != id && $0.ipaID == job.app.ipaID && $0.fileURL != nil })?.fileURL {
                // Already down from an earlier time: straight to the install.
                file = kept
            } else {
                file = try await client.downloadIPA(job.app) { fraction in
                    Task { @MainActor in self.update(id) { $0.progress = max(0, fraction) } }
                }
            }
        } catch {
            update(id) {
                $0.state = .failed
                $0.status = error is CancellationError ? "Cancelled." : error.localizedDescription
            }
            return
        }
        let relative = file.path.replacingOccurrences(of: Library.downloads.path + "/", with: "")
        update(id) { $0.file = relative; $0.progress = 1 }
        if job.install, let agent = job.agent {
            await installStep(id, file: file, agent: agent)
        } else {
            update(id) { $0.state = .downloaded; $0.status = "Downloaded. Install it from here once a device is running." }
        }
    }

    private func installStep(_ id: UUID, file: URL, agent: GuestAgent) async {
        update(id) { $0.state = .installing; $0.status = "Installing\u{2026}"; $0.progress = 0 }
        do {
            let installed = try await agent.installApp(ipa: file) { fraction, status in
                Task { @MainActor in self.update(id) { $0.progress = fraction; $0.status = status } }
            }
            update(id) {
                $0.state = .installed
                $0.progress = 1
                $0.status = installed.needsRestart
                    ? "Installed. Restart the device to see its icon."
                    : "Installed. Find it on the Home screen."
            }
        } catch {
            update(id) {
                $0.state = .failed
                $0.status = error is CancellationError ? "Cancelled." : error.localizedDescription
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = entries[i].isActive
        change(&entries[i])
        // Progress ticks are many; the list on disk only needs the state changes.
        if wasActive != entries[i].isActive || !entries[i].isActive { save() }
    }

    private func save() {
        let kept = Array(entries.prefix(Self.keep))
        if let data = try? JSONEncoder().encode(kept) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// The store's Downloads tab: the queue on top, then what came down before, in the store's iPhone OS 3 rows.
struct StoreDownloadsList: View {
    @ObservedObject var downloads: StoreDownloads
    let agent: GuestAgent?

    var body: some View {
        let active = downloads.entries.filter(\.isActive)
        let done = downloads.entries.filter { !$0.isActive }
        ScrollView {
            LazyVStack(spacing: 0) {
                if downloads.entries.isEmpty {
                    Text("Nothing downloaded yet.\nApps you get from the store show up here.")
                        .font(Classic.font(14, bold: true))
                        .foregroundStyle(Classic.hex(0x8A929C))
                        .multilineTextAlignment(.center)
                        .padding(.top, 60)
                }
                if !active.isEmpty {
                    header("Downloading")
                    ForEach(Array(active.enumerated()), id: \.element.id) { i, entry in row(entry, shaded: i % 2 == 1) }
                }
                if !done.isEmpty {
                    HStack {
                        header("Downloaded")
                        Button("Clear") { downloads.clearFinished() }
                            .font(Classic.font(12, bold: true))
                            .foregroundStyle(Classic.hex(0x3A6FB0))
                            .padding(.trailing, 12)
                    }
                    .background(Classic.hex(0xE3E6EA))
                    ForEach(Array(done.enumerated()), id: \.element.id) { i, entry in row(entry, shaded: i % 2 == 1) }
                    let bytes = downloads.downloadedBytes
                    if bytes > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of apps kept for installing again")
                            .font(Classic.font(11))
                            .foregroundStyle(Classic.hex(0x8A929C))
                            .padding(12)
                    }
                }
            }
        }
        .background(Color.white)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(Classic.font(13, bold: true))
            .foregroundStyle(Classic.hex(0x4C5663))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Classic.hex(0xE3E6EA))
    }

    private func row(_ entry: StoreDownloads.Entry, shaded: Bool) -> some View {
        HStack(spacing: 10) {
            StoreIcon(url: entry.iconURL, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(Classic.font(14, bold: true)).foregroundStyle(.black).lineLimit(1)
                if entry.isActive && entry.state != .waiting {
                    ProgressView(value: min(1, max(0, entry.progress)))
                        .tint(entry.state == .installing ? Classic.installTop : Classic.hex(0x3A6FB0))
                }
                Text(statusLine(entry))
                    .font(Classic.font(11))
                    .foregroundStyle(entry.state == .failed ? Classic.hex(0xC0502A) : Classic.hex(0x6B737D))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            trailing(entry)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(shaded ? Classic.hex(0xF4F5F7) : Color.white)
        .overlay(alignment: .bottom) { Classic.separator.frame(height: 1) }
        .contextMenu {
            if !entry.isActive {
                Button(role: .destructive) { downloads.remove(entry) } label: { Label("Remove", systemImage: "trash") }
            }
        }
    }

    private func statusLine(_ entry: StoreDownloads.Entry) -> String {
        var parts: [String] = []
        switch entry.state {
        case .downloading:
            if let size = entry.size, size > 0 {
                let got = Int64(Double(size) * min(1, max(0, entry.progress)))
                parts.append("\(ByteCountFormatter.string(fromByteCount: got, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
            } else {
                parts.append("Downloading\u{2026}")
            }
        case .waiting, .installing, .failed:
            parts.append(entry.status)
        case .installed, .downloaded:
            parts.append(entry.status)
            parts.append(entry.date.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder private func trailing(_ entry: StoreDownloads.Entry) -> some View {
        if entry.isActive {
            EmptyView()
        } else if let agent, entry.fileURL != nil {
            ClassicPriceButton(enabled: true, armed: true, title: entry.state == .installed ? "INSTALL AGAIN" : "INSTALL") {
                downloads.reinstall(entry, agent: agent)
            }
        } else if entry.fileURL == nil && entry.state != .failed {
            Text("Cleared").font(Classic.font(10, bold: true)).foregroundStyle(Classic.hex(0xA0A7B0))
        }
    }
}
