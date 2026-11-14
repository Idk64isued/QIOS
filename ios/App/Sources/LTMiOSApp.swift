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
        try? FileManager.default.createDirectory(at: documents.appendingPathComponent("IPSW"), withIntermediateDirectories: true)
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
    @State private var running: DeviceFolder?
    @State private var shareItem: ShareItem?
    @State private var logNote = ""
    @AppStorage("fastGL") private var fastGL = false
    @AppStorage("rect2d") private var rect2d = true
    @AppStorage("diag") private var diag = true
    @AppStorage("bezel") private var bezel = true
    @AppStorage("codeCacheMB") private var codeCacheMB = 512
    @State private var showLegacyStore = false
    @State private var showAddDevice = false
    @State private var showStorage = false
    @State private var swept = false

    var body: some View {
        if let running, emulator.showsScreen {
            EmulatorScreen(device: running)
        } else {
            home
        }
    }

    private func reload() {
        devices = Library.scan()
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
                if case .failed(let msg) = emulator.state {
                    errorBanner(msg)
                }
                devicesSection
                librarySection
                settingsSection
                logSection
                footer
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background { LTBackground() }
        .refreshable { reload() }
        .onAppear {
            if !swept {
                swept = true
                Library.sweepPreparing()  // a preparation the last launch did not finish
            }
            reload()
            emulator.load()
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .sheet(isPresented: $showLegacyStore) {
            LegacyStoreView(agent: nil, target: devices.first?.storeTarget ?? StoreTarget()) { showLegacyStore = false }
        }
        .sheet(isPresented: $showAddDevice) {
            AddDeviceView { device, start in
                showAddDevice = false
                reload()
                if let device, start { boot(device) }
            }
        }
        .sheet(isPresented: $showStorage, onDismiss: { reload() }) {
            StorageView { showStorage = false }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Theme.accentGlow)
                    .frame(width: 120, height: 120)
                    .blur(radius: 45)
                // The Mac app's own picture of the iPod touch.
                DeviceThumbnail(model: DeviceModel(board: "n72ap"), height: 132)
            }
            .frame(height: 140)
            .padding(.top, 14)

            Text("Light Touch")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Old iPhone OS, on your iPhone")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
                .padding(.bottom, 4)
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                StatusPill(
                    text: JIT.ready ? "JIT Enabled" : "JIT Off",
                    symbol: JIT.ready ? "bolt.fill" : "bolt.slash.fill",
                    color: JIT.ready ? Theme.success : Theme.warning
                )
                StatusPill(text: emulator.engine, symbol: "cpu", color: Theme.accent)
                if !OnDevicePrep.available {
                    StatusPill(text: "No firmware preparer", symbol: "hammer", color: Theme.secondaryText)
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

    // MARK: - Devices

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

            Button {
                showAddDevice = true
            } label: {
                Label(devices.isEmpty ? "Add your first device" : "Add Device", systemImage: "plus")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(devices.isEmpty ? .white : Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        devices.isEmpty ? Theme.accent : Theme.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

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
            Image(systemName: "sparkles")
                .font(.system(size: 20))
                .foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 3) {
                Text("No device yet")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Add Device downloads what it needs and sets one up on this iPhone. Nothing to copy over.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func deviceRow(_ device: DeviceFolder) -> some View {
        Button { boot(device) } label: {
            HStack(spacing: 12) {
                DeviceThumbnail(model: device.model ?? DeviceModel(board: "n72ap"), height: 46)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(device.subtitle)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
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

    // MARK: - Library (apps and storage)

    private var librarySection: some View {
        GlassCard("Library", symbol: "square.stack.3d.up") {
            HStack(spacing: 10) {
                actionButton("Legacy Store", icon: "bag", color: Theme.accent) {
                    showLegacyStore = true
                }
                actionButton("Storage", icon: "internaldrive", color: Theme.success) {
                    showStorage = true
                }
            }
            Text("Apps are installed while a device is running: open the \u{2026} menu on its screen for the Legacy Store or your own IPA.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(color.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Settings

    private var settingsSection: some View {
        GlassCard("Settings", symbol: "gearshape") {
            VStack(spacing: 0) {
                settingToggle("Show the device around the screen", icon: "iphone", isOn: $bezel)
                Divider().overlay(Color.white.opacity(0.04))
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
                .fixedSize(horizontal: false, vertical: true)
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
                DocumentPickerView(types: [UTType(filenameExtension: "ipa") ?? .archive, .zip]) { url in
                    showPicker = false
                    onPick(url)
                }
            }
        }
    }
}

/// The Files picker. The chosen file is copied into the app's temporary folder (the original may live in another
/// app or in iCloud and is only readable while the picker's access lasts); the caller deletes the copy.
struct DocumentPickerView: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
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
            // Not every provider hands out a security scope (a file already inside this app has none): try either way.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
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

// MARK: - Emulator Screen
//
// Three ways to look at the running device:
//   .bezel      — the device around the screen (the shell photo with the live screen inside)
//   .plain      — the Mac app's plain view: a thin border around the screen on a dark stage,
//                 with a floating top bar (back / name / Console) and a floating bottom pill
//                 (settings · Home · sliders)
//   .immersive  — the screen fills the whole phone; only the Home button is visible; tap the
//                 small ⋯ in the corner to bring the rest back
//
// All three take the same input: touches go to the emulator, iPhone volume buttons to the guest's volume, and a
// hardware keyboard (over the hidden KeyboardBridge) to whatever text field has focus. The … menu is the same
// everywhere, so everything is one tap away in any mode.

enum ControlsPresentation { case floating, barAndPill, hidden }

struct EmulatorScreen: View {
    @EnvironmentObject var emulator: Emulator
    let device: DeviceFolder

    @AppStorage("viewMode") private var viewModeRaw = ViewMode.bezel.rawValue
    @AppStorage("startupTone") private var startupTone = true

    @State private var details = DeviceFolder.Details()
    @State private var shareItem: ShareItem?
    @State private var showStore = false
    @State private var showIPAPicker = false
    @State private var showApps = false
    @State private var showFiles = false
    @State private var showCarrier = false
    @State private var showHelp = false
    @State private var showAllControls = false   // immersive mode: the overlay that brings the rest back
    @State private var installNote = ""
    @State private var toast = ""
    @StateObject private var volume = VolumeWatcher()
    @State private var keyboardBridge: KeyboardBridge?
    @State private var firstFrameSeen = false

    private var mode: ViewMode { ViewMode(rawValue: viewModeRaw) ?? .bezel }

    var body: some View {
        ZStack {
            stageBackground

            // Hidden input helpers — the keyboard bridge takes hardware-keyboard keys, the volume watcher
            // notices iPhone volume changes and turns them into emulator button presses.
            Color.clear.frame(width: 0, height: 0)
                .overlay(
                    KeyboardBridgeView(agent: emulator.agent) { bridge in
                        Task { @MainActor in
                            keyboardBridge = bridge
                            bridge?.becomeFirstResponder()
                        }
                    }
                )
                .overlay(VolumeWatcherView(watcher: volume))

            switch mode {
            case .bezel, .plain:
                windowed
            case .immersive:
                immersive
            }

            savingOverlay
        }
        .onAppear {
            details = device.details
            volume.onVolumeUp = { emulator.press(2) }
            volume.onVolumeDown = { emulator.press(3) }
        }
        .onDisappear { volume.stop() }
        .onChange(of: emulator.state) { state in
            if state == .running && startupTone && !firstFrameSeen {
                firstFrameSeen = true
                StartupTone.play()
            }
        }
        .sheet(item: $shareItem) { item in ActivityView(items: [item.url]) }
        .sheet(isPresented: $showStore) {
            LegacyStoreView(agent: emulator.agent, target: device.storeTarget) { showStore = false }
        }
        .sheet(isPresented: $showIPAPicker) { ipaPickerSheet }
        .sheet(isPresented: $showApps) {
            if let agent = emulator.agent { AppsBrowserView(agent: agent) { showApps = false } }
        }
        .sheet(isPresented: $showFiles) {
            if let agent = emulator.agent { FilesBrowserView(agent: agent) { showFiles = false } }
        }
        .sheet(isPresented: $showCarrier) { CarrierEditor(agent: emulator.agent) { showCarrier = false } }
        .sheet(isPresented: $showHelp) { HelpView { showHelp = false } }
    }

    // MARK: - Layouts

    /// Plain and bezel modes: the Mac app's plain view. A floating top bar (back / name / Console) and a floating
    /// bottom pill (settings · Home · sliders). The … menu is behind the sliders icon.
    private var windowed: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 2)
            DeviceStage(board: details.board, qemu: emulator.qemu, mode: mode, keyboardBridge: keyboardBridge) {
                emulator.press(0)
            }
            Spacer(minLength: 2)
            bottomPill
            if !toastText.isEmpty {
                Text(toastText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.warning)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
            }
        }
        .padding(.bottom, 10)
    }

    /// Immersive: the display fills the screen, and only the Home button is up front. A small ⋯ in the top-right
    /// brings the rest back as an overlay — identical to the plain-mode controls.
    private var immersive: some View {
        ZStack {
            DeviceStage(board: details.board, qemu: emulator.qemu, mode: .immersive, keyboardBridge: keyboardBridge) {
                emulator.press(0)
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.spring(duration: 0.3)) { showAllControls.toggle() }
                    } label: {
                        Image(systemName: showAllControls ? "xmark" : "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                            .environment(\.colorScheme, .dark)
                            .foregroundStyle(.white)
                            .padding(.trailing, 16)
                            .padding(.top, 10)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()

                // The single Home button. Big, tappable, centred — the only thing on screen by default.
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    emulator.press(0)
                } label: {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 2.5)
                        .background(Circle().fill(Color.white.opacity(0.04)))
                        .frame(width: 72, height: 72)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.white.opacity(0.75), lineWidth: 2)
                                .frame(width: 22, height: 22)
                        )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            }

            // Overlay: when expanded, the top bar and bottom pill slide in over the device.
            if showAllControls {
                VStack {
                    topBar
                        .background(.ultraThinMaterial.opacity(0.6))
                        .environment(\.colorScheme, .dark)
                    Spacer()
                    bottomPill.padding(.bottom, 14)
                }
                .transition(.opacity)
                .onTapGesture { withAnimation(.spring(duration: 0.3)) { showAllControls = false } }
            }
        }
    }

    // MARK: - Pieces (shared by all layouts)

    /// Top bar: back arrow (does nothing destructive — it just sends a Home press), device name + state, and a
    /// Console button that opens the log share sheet. Matches the screenshot the user shared.
    private var topBar: some View {
        HStack {
            Button {
                emulator.press(0)   // Home
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.10), in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Spacer()
            VStack(spacing: 2) {
                Text(details.version.map { (Int($0.prefix { $0 != "." }) ?? 0) < 4 ? "iPhone OS \($0)" : "iOS \($0)" } ?? device.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(stateText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button {
                if let url = LTMLog.exportCopy() { shareItem = ShareItem(url: url) }
            } label: {
                Text("Console")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Floating pill: settings (view mode / startup tone / carrier / help), Home (big, centred), and sliders (the full
    /// menu of actions: Legacy Store, Apps, Files, IPA, Screenshot, Save & quit, Shut down).
    private var bottomPill: some View {
        HStack(spacing: 18) {
            Menu {
                Section("View") {
                    Picker("View mode", selection: $viewModeRaw) {
                        ForEach(ViewMode.allCases, id: \.self) { m in
                            Label(m.title, systemImage: m.symbol).tag(m.rawValue)
                        }
                    }
                }
                Section {
                    Toggle(isOn: $startupTone) { Label("Startup tone", systemImage: "speaker.wave.2") }
                    Button { showCarrier = true } label: { Label("Carrier name\u{2026}", systemImage: "antenna.radiowaves.left.and.right") }
                    Button { showHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.08), in: Circle())
                    .foregroundStyle(.white)
            }

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                emulator.press(0)
            } label: {
                Circle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .frame(width: 60, height: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.white.opacity(0.9), lineWidth: 2)
                            .frame(width: 18, height: 18))
            }
            .buttonStyle(.plain)

            Menu {
                Section("Apps") {
                    Button { showStore = true } label: { Label("Legacy Store", systemImage: "bag") }
                    if emulator.agent != nil {
                        Button { showApps = true } label: { Label("Apps on the device", systemImage: "square.grid.2x2") }
                        Button { showFiles = true } label: { Label("Files on the device", systemImage: "folder") }
                    }
                    Button { showIPAPicker = true } label: { Label("Install an IPA\u{2026}", systemImage: "doc.zipper") }
                }
                Section("Capture") {
                    Button { takeScreenshot() } label: { Label("Save screenshot", systemImage: "camera") }
                    Button {
                        if let url = LTMLog.exportCopy() { shareItem = ShareItem(url: url) }
                    } label: { Label("Export log", systemImage: "square.and.arrow.up") }
                }
                Section("Power") {
                    Button { emulator.press(1) } label: { Label("Sleep / Wake", systemImage: "power.circle") }
                    Button { emulator.saveAndQuit() } label: { Label("Save & quit", systemImage: "tray.and.arrow.down") }
                    Button(role: .destructive) { emulator.quit() } label: { Label("Shut down", systemImage: "power") }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.08), in: Circle())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }

    /// The Mac app's stage background: its black-to-blue gradient picture when the build carries it, else the app's
    /// own gradient. In immersive mode the display covers everything, so the background doesn't show.
    @ViewBuilder private var stageBackground: some View {
        if mode == .immersive {
            Color.black.ignoresSafeArea()
        } else if let gradient = UIImage(named: "gradient") {
            Color.black
                .overlay(Image(uiImage: gradient).resizable().aspectRatio(contentMode: .fill))
                .clipped()
                .ignoresSafeArea()
        } else {
            LTBackground()
        }
    }

    private var stateText: String {
        switch emulator.state {
        case .idle: return "Idle"
        case .running: return "Running"
        case .saving: return "Saving\u{2026}"
        case .saved: return "Saved"
        case .failed: return "Stopped"
        }
    }

    private var toastText: String {
        if !emulator.saveMessage.isEmpty, emulator.state == .running { return emulator.saveMessage }
        if !installNote.isEmpty { return installNote }
        return toast
    }

    @ViewBuilder private var savingOverlay: some View {
        if emulator.state == .saving || emulator.state == .saved {
            ZStack {
                Color.black.opacity(0.8).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(emulator.saveMessage).font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(.white)
                }
            }
        }
    }

    @ViewBuilder private var ipaPickerSheet: some View {
        IPAPickerView { url in
            showIPAPicker = false
            guard let url else { return }
            Task { await performInstall(url: url) }
        }
    }

    /// Install an IPA: USB path first (the Mac app's real way), else the guest agent as a fallback.
    private func performInstall(url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }
        installNote = "Installing \(url.lastPathComponent)\u{2026}"
        if let session = emulator.usb, case .enumerated = session.state {
            do {
                try await session.install(ipa: url) { fraction, status in
                    Task { @MainActor in installNote = "\(status) " + String(format: "%.0f%%", fraction * 100) }
                }
                installNote = "Installed."
                return
            } catch {
                installNote = "USB install failed: \(error). Trying the agent\u{2026}"
            }
        }
        guard let agent = emulator.agent else {
            installNote = "The device is not ready to take apps yet."
            return
        }
        let ok = await agent.installIPA(localURL: url)
        installNote = ok
            ? (agent.hasShell ? "Installed via the agent." : "Copied to the device. Only a jailbroken device can finish installing it for now.")
            : "Could not install it. See the log."
    }

    private func takeScreenshot() {
        // The display's view hierarchy holds the newest frame. Find it in the key window.
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
            let image = DisplaySnapshot.latestFrame(inside: window)
        else {
            toast = "No frame to capture yet."
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); toast = "" }
            return
        }
        Task {
            let result = await Screenshot.save(image: image)
            switch result {
            case .saved, .savedFile: toast = "Saved to Photos (Light Touch album)."
            case .noAccess: toast = "Photos access denied."
            case .noFrame: toast = "No frame to capture yet."
            case .failed(let m): toast = "Couldn\u{2019}t save: \(m)"
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            toast = ""
        }
    }
}
