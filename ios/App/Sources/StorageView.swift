import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Storage: what Light Touch keeps on the phone and how much room each thing takes: devices, firmware, the Mac
/// files, caches and logs. Like the Mac app's Storage settings.
struct StorageView: View {
    let onClose: () -> Void

    @State private var devices: [DeviceFolder] = []
    @State private var firmware: [(file: URL, entry: CatalogFirmware?)] = []
    @State private var packed: [URL] = []
    @State private var sizes: [URL: Int64] = [:]
    @State private var free: Int64 = 0
    @State private var pendingDelete: PendingDelete?
    @State private var showIPSWPicker = false
    @State private var note = ""
    @State private var macTask: Task<Void, Never>?
    @State private var macProgress: (text: String, fraction: Double?)?

    private struct PendingDelete: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let button: String
        let urls: [URL]
    }

    private var cacheURLs: [URL] { [Library.caches, URL(fileURLWithPath: NSTemporaryDirectory()), Library.preparing] }
    private var logURLs: [URL] { [LTMLog.url, Library.documents.appendingPathComponent("prepare.log")] }

    var body: some View {
        NavigationView {
            ZStack {
                LTBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        summary
                        devicesCard
                        firmwareCard
                        macFilesCard
                        cachesCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onClose() }.foregroundStyle(Theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { reload() }
        .onDisappear { macTask?.cancel() }
        .alert(item: $pendingDelete) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                primaryButton: .destructive(Text(item.button)) { remove(item.urls) },
                secondaryButton: .cancel())
        }
        .sheet(isPresented: $showIPSWPicker) {
            DocumentPickerView(types: [UTType(filenameExtension: "ipsw") ?? .data, .zip, .data]) { url in
                showIPSWPicker = false
                if let url { importIPSW(url) }
            }
        }
    }

    // MARK: - Sections

    private var summary: some View {
        let used = allTracked.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
        return HStack(spacing: 14) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 26))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Light Touch uses \(Transfer.format(used))")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("\(Transfer.format(free)) free on this iPhone")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var devicesCard: some View {
        GlassCard("Devices", symbol: "externaldrive") {
            if devices.isEmpty { emptyText("No devices") }
            ForEach(devices) { device in
                let overlay = device.url.appendingPathComponent("overlay", isDirectory: true)
                let hasData = FileManager.default.fileExists(atPath: overlay.path)
                row(
                    symbol: device.model?.symbol ?? "ipodtouch",
                    title: device.name,
                    detail: device.subtitle,
                    size: sizes[device.url]
                ) {
                    if hasData {
                        Button {
                            pendingDelete = PendingDelete(
                                title: "Erase \(device.name)?",
                                message: "Everything done on the device since it was created (apps, settings, saved state) is removed. The device itself stays.",
                                button: "Erase", urls: [overlay])
                        } label: { Label("Erase Content", systemImage: "arrow.counterclockwise") }
                    }
                    Button(role: .destructive) {
                        pendingDelete = PendingDelete(
                            title: "Delete \(device.name)?",
                            message: "The device and everything on it are removed from this iPhone.",
                            button: "Delete", urls: [device.url])
                    } label: { Label("Delete Device", systemImage: "trash") }
                }
            }
        }
    }

    private var firmwareCard: some View {
        GlassCard("Firmware", symbol: "arrow.down.doc") {
            if firmware.isEmpty { emptyText("No downloaded or imported IPSWs") }
            ForEach(firmware, id: \.file) { item in
                row(
                    symbol: "doc.zipper",
                    title: item.entry.map { "\(DeviceModel(board: $0.board).shortName) \u{00B7} \($0.systemName)" } ?? item.file.lastPathComponent,
                    detail: item.entry.map { "Build \($0.build)" } ?? "Not in the catalog",
                    size: sizes[item.file]
                ) {
                    Button(role: .destructive) {
                        pendingDelete = PendingDelete(
                            title: "Remove this IPSW?",
                            message: "Devices already made from it keep working. It is downloaded again if you make another one.",
                            button: "Remove", urls: [item.file])
                    } label: { Label("Remove IPSW", systemImage: "trash") }
                }
            }
            smallButton("Add IPSW…", symbol: "plus") { showIPSWPicker = true }
            Text("A device no longer needs its IPSW once it is prepared.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private var macFilesCard: some View {
        GlassCard("Mac files", symbol: "desktopcomputer") {
            statusRow("Boot ROMs", present: MacFiles.hasAnyBootROM, missing: "Needed to start any device")
            statusRow("Guest tools", present: MacFiles.hasGuestTools, missing: "Needed to prepare firmware",
                size: sizes[MacFiles.folder])
            ForEach(packed, id: \.self) { item in
                row(
                    symbol: "shippingbox",
                    title: "Ready-made \(item.deletingPathExtension().lastPathComponent)",
                    detail: "Packed device. Only needed to add another copy of it.",
                    size: sizes[item]
                ) {
                    Button(role: .destructive) {
                        pendingDelete = PendingDelete(
                            title: "Remove the packed device?",
                            message: "Devices already unpacked from it keep working. Getting the Mac files again brings it back.",
                            button: "Remove", urls: [item])
                    } label: { Label("Remove", systemImage: "trash") }
                }
            }
            if let progress = macProgress {
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = progress.fraction { ProgressView(value: fraction).tint(Theme.accent) } else { ProgressView().tint(Theme.accent) }
                    Text(progress.text).font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.secondaryText)
                }
                smallButton("Cancel", symbol: "xmark") { macTask?.cancel() }
            } else {
                smallButton(
                    MacFiles.hasGuestTools && MacFiles.hasAnyBootROM ? "Download again" : "Get the Mac files (\(Transfer.format(MacFiles.approximateBytes)))",
                    symbol: "arrow.down.circle"
                ) { getMacFiles() }
            }
            Text("From the Mac release \(MacFiles.releaseTag) on GitHub, the one that matches this app's emulator.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.tertiaryText)
            if !note.isEmpty {
                Text(note).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.warning)
            }
        }
    }

    private var cachesCard: some View {
        let caches = cacheURLs.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
        let logs = logURLs.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
        return GlassCard("Caches and logs", symbol: "trash.slash") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Caches \(Transfer.format(caches)) \u{00B7} Logs \(Transfer.format(logs))")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("Unfinished downloads, decrypted firmware, unpacked guest tools. All of it is made again when needed.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                smallButton("Clear", symbol: "trash") { clearCaches() }
            }
        }
    }

    // MARK: - Rows

    private func emptyText(_ text: String) -> some View {
        Text(text).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.secondaryText)
    }

    private func row<Actions: View>(
        symbol: String, title: String, detail: String, size: Int64?, @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Text(size.map { Transfer.format($0) } ?? "…")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
            Menu {
                actions()
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func statusRow(_ title: String, present: Bool, missing: String, size: Int64? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: present ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(present ? Theme.success : Theme.danger)
            Text(title).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text(present ? (size.map { Transfer.format($0) } ?? "Installed") : missing)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func smallButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.accent.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Work

    private var allTracked: [URL] {
        devices.map(\.url) + firmware.map(\.file) + packed + [MacFiles.folder] + cacheURLs + logURLs
    }

    private func reload() {
        devices = Library.scan()
        firmware = IPSWStore.stored()
        packed = PackedDevice.find()
        free = Transfer.freeSpace()
        let urls = allTracked
        Task {
            let measured: [URL: Int64] = await Task.detached(priority: .utility) {
                var result: [URL: Int64] = [:]
                for url in urls { result[url] = Transfer.diskUsage(url) }
                return result
            }.value
            sizes = measured
        }
    }

    private func remove(_ urls: [URL]) {
        for url in urls { Library.removeTree(url) }
        reload()
    }

    private func clearCaches() {
        for url in cacheURLs + logURLs {
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            if items.isEmpty { try? FileManager.default.removeItem(at: url) }
            for item in items { Library.removeTree(item) }
        }
        reload()
    }

    private func importIPSW(_ file: URL) {
        note = "Checking \(file.lastPathComponent)…"
        Task {
            let result: Result<CatalogFirmware, Error> = await Task.detached(priority: .userInitiated) {
                defer { try? FileManager.default.removeItem(at: file) }
                return Result { try IPSWStore.importFile(file) { _ in } }
            }.value
            switch result {
            case .success: note = ""
            case .failure(let error): note = error.localizedDescription
            }
            reload()
        }
    }

    private func getMacFiles() {
        note = ""
        macProgress = ("Connecting to GitHub", nil)
        UIApplication.shared.isIdleTimerDisabled = true
        macTask = Task {
            do {
                var last = Date.distantPast
                try await MacFiles.install { stage, fraction in
                    let now = Date()
                    guard now.timeIntervalSince(last) > 0.15 else { return }
                    last = now
                    let text: String
                    switch stage {
                    case .downloading: text = "Downloading the Mac release"
                    case .checking: text = "Checking the download"
                    case .unpacking: text = "Unpacking the boot ROMs and guest tools"
                    }
                    Task { @MainActor in macProgress = (text, fraction < 0 ? nil : fraction) }
                }
            } catch is CancellationError {
                note = "Cancelled."
            } catch {
                note = (error as? URLError)?.code == .cancelled ? "Cancelled." : error.localizedDescription
            }
            UIApplication.shared.isIdleTimerDisabled = false
            // Progress updates queued before the end land first; then the bar goes away.
            try? await Task.sleep(nanoseconds: 300_000_000)
            macProgress = nil
            reload()
        }
    }
}
