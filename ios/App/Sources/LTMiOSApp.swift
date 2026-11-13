import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct LTMiOSApp: App {
    @StateObject private var emulator = Emulator()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(emulator).preferredColorScheme(.dark)
        }
    }
}

struct DeviceFolder: Identifiable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum Library {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var devices: URL { documents.appendingPathComponent("Devices", isDirectory: true) }

    /// Every folder under Documents/Devices that holds base/device.lock.json.
    static func scan() -> [DeviceFolder] {
        try? FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: documents.appendingPathComponent("Device"), withIntermediateDirectories: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)) ?? []
        return items.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("base/device.lock.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.map(DeviceFolder.init)
    }
}

// MARK: - Theme

/// The visual language matches the Mac app: deep gradients, subtle glass, rounded type.
enum Theme {
    // Gradient background matching the Mac app's "gradient" asset — a deep blue-indigo
    static let gradientTop = Color(red: 0.06, green: 0.07, blue: 0.18)
    static let gradientMid = Color(red: 0.04, green: 0.05, blue: 0.14)
    static let gradientBot = Color(red: 0.02, green: 0.02, blue: 0.08)

    // Cards: frosted glass effect
    static let cardFill = Color.white.opacity(0.06)
    static let cardBorder = Color.white.opacity(0.08)
    static let cardHighlight = Color.white.opacity(0.10)

    // Accent: the Mac app's signature blue
    static let accent = Color(red: 0.36, green: 0.62, blue: 1.0)
    static let accentGlow = Color(red: 0.36, green: 0.62, blue: 1.0).opacity(0.25)

    // Text
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.32)

    // Semantic
    static let success = Color(red: 0.30, green: 0.78, blue: 0.47)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.28)
    static let danger = Color(red: 1.0, green: 0.38, blue: 0.38)
}

// MARK: - Background Gradient (matches Mac Light Touch gradient asset)

struct LTBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Theme.gradientTop, location: 0),
                    .init(color: Theme.gradientMid, location: 0.45),
                    .init(color: Theme.gradientBot, location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            // Subtle radial glow near top, like the Mac app's ambient light
            RadialGradient(
                colors: [Theme.accent.opacity(0.08), .clear],
                center: .init(x: 0.5, y: 0.08),
                startRadius: 0,
                endRadius: UIScreen.main.bounds.height * 0.5
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Glass Card

struct GlassCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .textCase(.uppercase)
                .tracking(0.5)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.cardBorder, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }
}

// MARK: - Status Pill

struct StatusPill: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.2), lineWidth: 0.5))
    }
}

// MARK: - Root View

struct RootView: View {
    @EnvironmentObject var emulator: Emulator
    @State private var devices: [DeviceFolder] = []
    @State private var packed: [URL] = []
    @State private var running: DeviceFolder?
    @State private var shareItem: ShareItem?
    @State private var logNote = ""
    @StateObject private var importer = Importer()
    @AppStorage("fastGL") private var fastGL = false
    @AppStorage("rect2d") private var rect2d = true
    @AppStorage("diag") private var diag = true
    @AppStorage("codeCacheMB") private var codeCacheMB = 512
    @State private var showIPAPicker = false
    @State private var ipaInstallMessage = ""

    var body: some View {
        if let running, emulator.showsScreen {
            EmulatorScreen(device: running)
        } else {
            home
        }
    }

    private func reload() {
        devices = Library.scan()
        packed = PackedDevice.find()
    }

    private func boot(_ device: DeviceFolder) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        running = device
        emulator.boot(directory: device.url)
    }

    private func exportLog() {
        if let url = LTMLog.exportCopy() {
            logNote = ""
            shareItem = ShareItem(url: url)
        } else {
            logNote = "No log yet. Boot a device first."
        }
    }

    // MARK: - Home

    private var home: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                heroSection
                statusRow
                devicesSection
                appsSection
                packedSection
                settingsSection
                logSection
                if case .failed(let msg) = emulator.state {
                    errorBanner(msg)
                }
                footer
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background { LTBackground() }
        .refreshable { reload() }
        .onAppear { reload(); emulator.load() }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .sheet(isPresented: $showIPAPicker) {
            IPAPickerView { url in
                showIPAPicker = false
                guard let agent = emulator.agent, let url else { return }
                Task {
                    ipaInstallMessage = "Installing…"
                    let ok = await agent.installIPA(localURL: url)
                    ipaInstallMessage = ok ? "Installed successfully" : "Install failed — check log"
                }
            }
        }
    }

    // MARK: - Hero (like the Mac app's device content area)

    private var heroSection: some View {
        VStack(spacing: 6) {
            // Device illustration glow
            ZStack {
                // Ambient glow behind device
                Circle()
                    .fill(Theme.accentGlow)
                    .frame(width: 100, height: 100)
                    .blur(radius: 40)

                // Device icon — the iOS stand-in for the Mac app's 3D RealityKit model
                Image(systemName: "ipodtouch")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white.opacity(0.9), .white.opacity(0.5)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .shadow(color: Theme.accent.opacity(0.4), radius: 20)
            }
            .frame(height: 110)
            .padding(.top, 12)

            Text("Light Touch")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Old iPhone OS, on your iPhone")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
                .padding(.bottom, 4)
        }
    }

    // MARK: - Status Row (horizontal pills, like the Mac app's toolbar chips)

    private var statusRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                StatusPill(
                    text: JIT.ready ? "JIT Enabled" : "JIT Off",
                    symbol: JIT.ready ? "bolt.fill" : "bolt.slash.fill",
                    color: JIT.ready ? Theme.success : Theme.warning
                )
                StatusPill(text: emulator.engine, symbol: "cpu", color: Theme.accent)
                if let agent = emulator.agent {
                    StatusPill(
                        text: agent.status == .alive ? "Agent Ready" : "No Agent",
                        symbol: agent.status == .alive ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash",
                        color: agent.status == .alive ? Theme.success : Theme.secondaryText
                    )
                }
                if ProcessInfo.processInfo.isLowPowerModeEnabled {
                    StatusPill(text: "Low Power", symbol: "battery.25", color: Theme.warning)
                }
                if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                    StatusPill(text: "Throttling", symbol: "thermometer.sun.fill", color: Theme.danger)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Devices (like the Mac app's source list sidebar, but vertical)

    private var devicesSection: some View {
        GlassCard("Devices", symbol: "externaldrive") {
            if devices.isEmpty {
                emptyDevicesHint
            } else {
                VStack(spacing: 8) {
                    ForEach(devices) { d in
                        deviceRow(d)
                    }
                }
            }

            // JIT hint (below devices, less prominent)
            if !JIT.ready {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                        .padding(.top, 1)
                    Text("Enable JIT first: StikDebug with universal.js, then open Light Touch. In LiveContainer, use Launch with JIT.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.warning.opacity(0.8))
                }
                .padding(10)
                .background(Theme.warning.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var emptyDevicesHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 20))
                .foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 3) {
                Text("No device yet")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Unpack an iPod touch below, or add a prepared device to Files \u{203A} LightTouch \u{203A} Devices.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func deviceRow(_ device: DeviceFolder) -> some View {
        Button { boot(device) } label: {
            HStack(spacing: 12) {
                // Device icon with subtle accent ring (echoing the Mac 3D model display)
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accent.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: "ipodtouch")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("iPhone OS · Tap to boot")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.accent)
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6)
            }
            .padding(12)
            .background(Theme.cardHighlight, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.accent.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Apps & Legacy Store

    private var appsSection: some View {
        GlassCard("Apps", symbol: "square.stack.3d.up") {
            Text("Install your own legally owned IPAs into the emulated device, or browse the legacy store.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.secondaryText)

            // IPA Install
            VStack(alignment: .leading, spacing: 10) {
                Label("Install IPA", systemImage: "doc.zipper")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))

                if emulator.state == .running {
                    Button {
                        showIPAPicker = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.badge.plus")
                            Text("Choose IPA file")
                        }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Theme.accent, in: Capsule())
                        .shadow(color: Theme.accent.opacity(0.3), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .disabled(emulator.agent?.isBusy ?? false)
                } else {
                    Text("Boot a device first, then install apps here.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                }

                if !ipaInstallMessage.isEmpty {
                    Text(ipaInstallMessage)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(ipaInstallMessage.contains("success") ? Theme.success : Theme.warning)
                }

                if let agent = emulator.agent {
                    if !agent.hasShell {
                        Text("A jailbroken guest lets the app install IPAs automatically. Without it, IPAs upload to /tmp for manual install.")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    if !agent.lastLog.isEmpty {
                        Text(agent.lastLog)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(2)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Legacy Store
            VStack(alignment: .leading, spacing: 8) {
                Label("Legacy Store", systemImage: "storefront")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))

                Text("Coming soon — free, open-source, and abandonware apps compatible with old iPhone OS.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                    Text("Only freely distributable apps will be listed. Your own IPAs stay private.")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Packed Devices

    private var packedSection: some View {
        GlassCard("Setup", symbol: "shippingbox") {
            if packed.isEmpty {
                Text("Copy the Mac app's Device folder into Files \u{203A} LightTouch \u{203A} Device, then pull down to refresh.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(packed, id: \.self) { url in
                Button {
                    importer.unpack(url) { reload() }
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.accent.opacity(0.12))
                                .frame(width: 36, height: 36)
                            Image(systemName: "shippingbox.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.accent)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Unpack \(url.deletingPathExtension().lastPathComponent)")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.white)
                            Text("Prepare for first boot")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(10)
                    .background(Theme.cardHighlight, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(importer.busy)
            }
            if importer.busy {
                ProgressView(value: importer.fraction)
                    .tint(Theme.accent)
                    .padding(.top, 4)
            }
            if !importer.message.isEmpty {
                Text(importer.message)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
            }
            Text("Boot ROMs: bootrom_240_4 and ipod1g/bootrom_s5l8900 in the Device folder.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    // MARK: - Settings (Speed & Graphics)

    private var settingsSection: some View {
        GlassCard("Settings", symbol: "gearshape") {
            VStack(spacing: 0) {
                settingToggle("Rectangle textures \u{2192} 2D", icon: "rectangle.on.rectangle", isOn: $rect2d)
                Divider().overlay(Color.white.opacity(0.04))
                settingToggle("Skip GL error checks", icon: "bolt.trianglebadge.exclamationmark", isOn: $fastGL)
                Divider().overlay(Color.white.opacity(0.04))
                settingToggle("Diagnostics in log", icon: "stethoscope", isOn: $diag)
            }
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
            )

            // Code cache picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Code Cache")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))

                Picker("", selection: $codeCacheMB) {
                    Text("256 MB").tag(256)
                    Text("512 MB").tag(512)
                    Text("1 GB").tag(1024)
                }
                .pickerStyle(.segmented)
            }

            Text("Save & quit is limited while the device uses live GL state (home screen).")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private func settingToggle(_ label: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            Text(label)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Log

    private var logSection: some View {
        GlassCard("Log", symbol: "doc.text.magnifyingglass") {
            HStack(spacing: 10) {
                Button {
                    exportLog()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.accent, in: Capsule())
                        .shadow(color: Theme.accent.opacity(0.2), radius: 6, y: 2)
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    try? FileManager.default.removeItem(at: LTMLog.url)
                    logNote = "Log cleared."
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.danger.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.danger.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()
            }
            if !logNote.isEmpty {
                Text(logNote).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Theme.danger)
            Text(message)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Theme.danger.opacity(0.9))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.danger.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 3) {
            Text("Light Touch for iOS")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.tertiaryText)
            Text("GPL-2.0 \u{00B7} github.com/Idk64isued/QIOS")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.18))
        }
        .padding(.top, 10)
    }
}

// MARK: - IPA Picker

struct IPAPickerView: View {
    let onPick: (URL?) -> Void
    @State private var showPicker = false

    var body: some View {
        NavigationView {
            VStack(spacing: 22) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Theme.accentGlow)
                        .frame(width: 80, height: 80)
                        .blur(radius: 25)
                    Image(systemName: "doc.zipper")
                        .font(.system(size: 44, weight: .thin))
                        .foregroundStyle(.white.opacity(0.85))
                }

                Text("Install an IPA")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Choose a decrypted .ipa from your files. It will be installed into the running emulated device.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)

                Button {
                    showPicker = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                        Text("Browse Files")
                    }
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.4), radius: 12, y: 4)
                }
                .buttonStyle(.plain)

                Spacer()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { LTBackground() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onPick(nil) }
                        .foregroundStyle(Theme.accent)
                }
            }
            .sheet(isPresented: $showPicker) {
                DocumentPickerView { url in
                    showPicker = false
                    onPick(url)
                }
            }
        }
    }
}

struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types = [UTType(filenameExtension: "ipa") ?? .archive]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onPick(nil); return }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tmp)
            guard url.startAccessingSecurityScopedResource() else { onPick(nil); return }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                try FileManager.default.copyItem(at: url, to: tmp)
                onPick(tmp)
            } catch {
                onPick(nil)
            }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onPick(nil) }
    }
}

// MARK: - Controls

struct ControlButton: View {
    let symbol: String
    var size: CGFloat = 46
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white)
    }
}

// MARK: - Emulator Screen (matches the Mac app's continuous scene view)

struct EmulatorScreen: View {
    @EnvironmentObject var emulator: Emulator
    let device: DeviceFolder
    @State private var shareItem: ShareItem?

    var body: some View {
        ZStack {
            // Background: same deep gradient, the "stage" for the device
            LTBackground()

            VStack(spacing: 0) {
                Spacer(minLength: 8)

                // The emulator display — clipped like the Mac app's screen-clips-to-bounds
                DisplayView(qemu: emulator.qemu)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
                    .padding(.horizontal, 12)

                Spacer(minLength: 10)

                // Controls bar — floating glass capsule like the Mac app's bottom bar
                controls

                if !emulator.saveMessage.isEmpty, emulator.state == .running {
                    Text(emulator.saveMessage)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.warning)
                        .padding(.top, 6)
                }
            }
            .padding(.bottom, 10)
        }
        .overlay { savingOverlay }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            ControlButton(symbol: "speaker.minus.fill") { emulator.press(3) }
            ControlButton(symbol: "speaker.plus.fill") { emulator.press(2) }
            ControlButton(symbol: "circle", size: 58) { emulator.press(0) }
            ControlButton(symbol: "power") { emulator.press(1) }
            Menu {
                Button {
                    if let url = LTMLog.exportCopy() { shareItem = ShareItem(url: url) }
                } label: {
                    Label("Export log", systemImage: "square.and.arrow.up")
                }
                Button {
                    emulator.saveAndQuit()
                } label: {
                    Label("Save & quit", systemImage: "tray.and.arrow.down")
                }
                Button(role: .destructive) {
                    emulator.quit()
                } label: {
                    Label("Shut down", systemImage: "power")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
                    .foregroundStyle(Color.white)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }

    @ViewBuilder private var savingOverlay: some View {
        if emulator.state == .saving || emulator.state == .saved {
            ZStack {
                Color.black.opacity(0.8).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text(emulator.saveMessage)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
    }
}
