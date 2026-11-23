import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct LTMiOSApp: App {
    @StateObject private var emulator = Emulator()
    /// "system" (the default), "light" or "dark", from Settings.
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(emulator).preferredColorScheme(scheme)
        }
    }

    /// nil follows the phone's own setting.
    private var scheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

struct DeviceFolder: Identifiable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    /// A saved state (Save & quit, or the app going to the background) that the next start restores.
    var hasSavedState: Bool {
        let snaps = Snapshots(overlay: url.appendingPathComponent("overlay", isDirectory: true))
        return FileManager.default.fileExists(atPath: snaps.file.path) && FileManager.default.fileExists(atPath: snaps.meta.path)
    }
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
///
/// Every colour follows the system's light or dark setting (or the one chosen in Settings). Dark is the Mac app's
/// navy gradient; light is the same layout washed out to near-white, with the ink inverted. The emulator's own
/// screen stays dark either way — a running device looks wrong on a white stage.
enum Theme {
    /// A colour with a light and a dark version, resolved against whichever appearance the view is in.
    static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: r, green: g, blue: b, alpha: a)
    }

    // Background gradient: the Mac app's deep blue-indigo in dark, a cool near-white in light
    static let gradientTop = adaptive(light: rgb(0.96, 0.97, 1.0), dark: rgb(0.06, 0.07, 0.18))
    static let gradientMid = adaptive(light: rgb(0.92, 0.94, 0.99), dark: rgb(0.04, 0.05, 0.14))
    static let gradientBot = adaptive(light: rgb(0.86, 0.89, 0.97), dark: rgb(0.02, 0.02, 0.08))

    /// The colour of thin things — fills, dividers, outlines. White on dark, black on light. Always used with a
    /// low opacity, so one value does both appearances.
    static let ink = adaptive(light: .black, dark: .white)

    // Cards: frosted glass
    static let cardFill = adaptive(light: rgb(1, 1, 1, 0.72), dark: rgb(1, 1, 1, 0.06))
    static let cardBorder = adaptive(light: rgb(0, 0, 0, 0.07), dark: rgb(1, 1, 1, 0.08))
    static let cardHighlight = adaptive(light: rgb(1, 1, 1, 0.85), dark: rgb(1, 1, 1, 0.10))
    static let shadow = adaptive(light: rgb(0.10, 0.15, 0.35, 0.10), dark: rgb(0, 0, 0, 0.30))

    // Accent: the Mac app's signature blue, a shade deeper on light so it holds its contrast
    static let accent = adaptive(light: rgb(0.16, 0.44, 0.93), dark: rgb(0.36, 0.62, 1.0))
    static let accentGlow = adaptive(light: rgb(0.16, 0.44, 0.93, 0.18), dark: rgb(0.36, 0.62, 1.0, 0.25))
    /// Text sitting on the accent colour: white in both appearances.
    static let onAccent = Color.white

    // Text
    static let primaryText = adaptive(light: rgb(0.07, 0.08, 0.12), dark: .white)
    static let secondaryText = adaptive(light: rgb(0.33, 0.36, 0.44), dark: rgb(1, 1, 1, 0.55))
    static let tertiaryText = adaptive(light: rgb(0.55, 0.58, 0.66), dark: rgb(1, 1, 1, 0.32))

    // Semantic
    static let success = adaptive(light: rgb(0.13, 0.60, 0.32), dark: rgb(0.30, 0.78, 0.47))
    static let warning = adaptive(light: rgb(0.80, 0.47, 0.0), dark: rgb(1.0, 0.72, 0.28))
    static let danger = adaptive(light: rgb(0.85, 0.20, 0.20), dark: rgb(1.0, 0.38, 0.38))
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
                .foregroundStyle(Theme.primaryText.opacity(0.75))
                .textCase(.uppercase)
                .tracking(0.5)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.cardBorder, lineWidth: 0.5)
        )
        .shadow(color: Theme.shadow, radius: 12, y: 6)
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
    @AppStorage("glCapture") private var glCapture = false
    @AppStorage("rect2d") private var rect2d = true
    @AppStorage("diag") private var diag = true
    @AppStorage("bezel") private var bezel = true
    @AppStorage("enableUSB") private var enableUSB = false
    @AppStorage("codeCacheMB") private var codeCacheMB = 512
    @State private var showLegacyStore = false
    @State private var showReport = false
    @State private var showAddDevice = false
    @State private var showStorage = false
    @State private var showWhatsNew = false
    @State private var showAllSettings = false
    @State private var showSixSettings = false
    @State private var showConsole = false
    /// What the iOS 6 Settings sheet opens over itself.
    @State private var sixAllSettings = false
    @State private var sixReport = false
    @State private var sixConsole = false
    @State private var sixShare: ShareItem?
    @State private var swept = false
    /// Settings › Home Screen: the original list in iOS 6's look, or in the glass look. (A stored "springboard", from
    /// the update that had one, reads as the iOS 6 list.)
    @AppStorage("homeInterface") private var interfaceRaw = HomeInterface.classic.rawValue

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

    private func addDeviceClosed(_ device: DeviceFolder?, _ start: Bool) {
        showAddDevice = false
        reload()
        if let device, start { boot(device) }
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

    private var interface: HomeInterface { HomeInterface(rawValue: interfaceRaw) ?? .classic }

    private var failure: String? {
        if case .failed(let msg) = emulator.state { return msg }
        return nil
    }

    private var actions: HomeActions {
        HomeActions(
            boot: { boot($0) },
            erase: { device in
                Library.removeTree(device.url.appendingPathComponent("overlay", isDirectory: true))
                devices = Library.scan()
            },
            addDevice: { showAddDevice = true },
            store: { showLegacyStore = true },
            storage: { showStorage = true },
            settings: { showSixSettings = true },
            allSettings: { showAllSettings = true },
            console: { showConsole = true },
            report: { showReport = true },
            exportLog: { exportLog() },
            clearLog: {
                try? FileManager.default.removeItem(at: LTMLog.url)
                logNote = "Log cleared."
            },
            whatsNew: { showWhatsNew = true })
    }

    /// The same, for the iOS 6 Settings sheet: what it opens goes over it.
    private var sixActions: HomeActions {
        let base = actions
        return HomeActions(
            boot: base.boot, erase: base.erase, addDevice: base.addDevice, store: base.store, storage: base.storage,
            settings: {},
            allSettings: { sixAllSettings = true },
            console: { sixConsole = true },
            report: { sixReport = true },
            exportLog: {
                if let url = LTMLog.exportCopy() { sixShare = ShareItem(url: url) }
            },
            clearLog: base.clearLog,
            whatsNew: base.whatsNew)
    }

    @ViewBuilder private var homeInterface: some View {
        switch interface {
        case .classic:
            ClassicHome(devices: devices, failure: failure, engine: emulator.engine, actions: actions,
                        bezel: $bezel, rect2d: $rect2d, fastGL: $fastGL, diag: $diag, enableUSB: $enableUSB,
                        codeCacheMB: $codeCacheMB, logNote: logNote)
                .refreshable { reload() }
        case .modern:
            modernHome
        }
    }

    private var home: some View {
        homeInterface
        .onAppear {
            if HomeInterface(rawValue: interfaceRaw) == nil { interfaceRaw = HomeInterface.classic.rawValue }
            if !swept {
                swept = true
                Library.sweepPreparing()  // a preparation the last launch did not finish
            }
            reload()
            // After an update, say what changed once, without being asked.
            if ChangeLog.shouldShowForNewBuild() { showWhatsNew = true }
            emulator.load()
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(deviceName: nil, deviceDetails: nil, screen: nil) { showReport = false }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .fullScreenCover(isPresented: $showLegacyStore) {
            LegacyStoreView(agent: nil, target: devices.first?.storeTarget ?? StoreTarget()) { showLegacyStore = false }
        }
        // The Setup Assistant for every interface: iOS 6's look, or with the glass home screen the glass one.
        //
        // How it arrives matters as much as how it is drawn. A sheet — a rounded card that stops short of the top,
        // with the home screen showing behind it — is the modern way, and under the iOS 6 interface it was the one
        // thing giving the game away: iOS 6's own Setup Assistant owned the whole screen, which is what every page
        // of this one is drawn for. So there it comes up full screen, and only the glass interface gets a sheet.
        .sheet(isPresented: Binding(
            get: { showAddDevice && interface == .modern },
            set: { if !$0 { showAddDevice = false } })
        ) {
            SetupAssistantView { device, start in addDeviceClosed(device, start) }
                .environment(\.glassStyle, true)
        }
        .fullScreenCover(isPresented: Binding(
            get: { showAddDevice && interface != .modern },
            set: { if !$0 { showAddDevice = false } })
        ) {
            SetupAssistantView { device, start in addDeviceClosed(device, start) }
                .environment(\.glassStyle, false)
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView()
        }
        .sheet(isPresented: $showStorage, onDismiss: { reload() }) {
            StorageView { showStorage = false }
        }
        .sheet(isPresented: $showAllSettings) {
            DeviceSettingsView { showAllSettings = false }
        }
        .sheet(isPresented: $showSixSettings) {
            SixHomeSettings(actions: sixActions) { showSixSettings = false }
                // Sheets of their own, over this one.
                .sheet(isPresented: $sixAllSettings) { DeviceSettingsView { sixAllSettings = false } }
                .sheet(isPresented: $sixReport) {
                    ReportSheet(deviceName: nil, deviceDetails: nil, screen: nil) { sixReport = false }
                }
                .sheet(isPresented: $sixConsole) { ConsoleView { sixConsole = false } }
                .sheet(item: $sixShare) { item in ActivityView(items: [item.url]) }
        }
        .sheet(isPresented: $showConsole) { ConsoleView { showConsole = false } }
    }

    private var modernHome: some View {
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
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Theme.accentGlow)
                    .frame(width: 120, height: 120)
                    .blur(radius: 45)
                // The app's logo (its icon), or the Mac app's picture of the iPod touch in a build without it.
                if let logo = UIImage(named: "Logo") {
                    Image(uiImage: logo)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 124, height: 124)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                } else {
                    DeviceThumbnail(model: DeviceModel(board: "n72ap"), height: 132)
                }
            }
            .frame(height: 140)
            .padding(.top, 14)

            Text("Light Touch")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.primaryText)

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
                    text: JIT.usable ? "JIT Enabled" : "JIT Off",
                    symbol: JIT.usable ? "bolt.fill" : "bolt.slash.fill",
                    color: JIT.usable ? Theme.success : Theme.warning
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
                    .foregroundStyle(devices.isEmpty ? Theme.primaryText : Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        devices.isEmpty ? Theme.accent : Theme.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            if !JIT.usable {
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
                    .foregroundStyle(Theme.primaryText.opacity(0.7))
                Text("Add Device downloads what it needs and sets one up on this iPhone. Nothing to copy over.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func deviceRow(_ device: DeviceFolder) -> some View {
        Button { boot(device) } label: {
            HStack(spacing: 12) {
                DeviceThumbnail(model: device.model ?? DeviceModel(board: "n72ap"), height: 46)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(device.subtitle)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                    if device.hasSavedState {
                        Label("Picks up where it left off", systemImage: "arrow.uturn.forward.circle.fill")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.success)
                            .lineLimit(1)
                    }
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
        // A device that was not shut down cleanly spends its next boot repairing its storage, which on hardware
        // this slow can take longer than anyone will wait. This puts it back to how it was prepared, without
        // building the whole thing again.
        .contextMenu {
            Button(role: .destructive) {
                Library.removeTree(device.url.appendingPathComponent("overlay", isDirectory: true))
                devices = Library.scan()
            } label: {
                Label("Erase content", systemImage: "arrow.counterclockwise")
            }
        }
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
                    .foregroundStyle(Theme.primaryText.opacity(0.85))
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
            // The whole settings sheet, the one a running device's gear opens: graphics, network, keyboard, mic...
            Button { showAllSettings = true } label: {
                HStack {
                    Label("All settings\u{2026}", systemImage: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(QemuRuntime.angleBundled ? "Graphics: \(QemuRuntime.renderer.rawValue)" : "")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            VStack(spacing: 0) {
                settingToggle("Show the device around the screen", icon: "iphone", isOn: $bezel)
                Divider().overlay(Theme.ink.opacity(0.04))
                settingToggle("Rectangle textures \u{2192} 2D", icon: "rectangle.on.rectangle", isOn: $rect2d)
                Divider().overlay(Theme.ink.opacity(0.04))
                settingToggle("Skip GL error checks", icon: "bolt.trianglebadge.exclamationmark", isOn: $fastGL)
                Divider().overlay(Theme.ink.opacity(0.04))
                settingToggle("Graphics capture (next boot)", icon: "camera.metering.matrix", isOn: $glCapture)
                Divider().overlay(Theme.ink.opacity(0.04))
                settingToggle("Diagnostics in log", icon: "stethoscope", isOn: $diag)
                Divider().overlay(Theme.ink.opacity(0.04))
                settingToggle("USB bridge (experimental)", icon: "cable.connector", isOn: $enableUSB)
            }
            .background(Theme.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.ink.opacity(0.04), lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Code Cache")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.primaryText.opacity(0.8))

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
            Text("USB bridge turns on the Mac-style IPA install path. It can confuse the guest at boot on some devices; leave it off for normal use and turn it on just to install an IPA.")
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
                .foregroundStyle(Theme.primaryText.opacity(0.85))
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
            // Four buttons are wider than a phone in portrait: they scroll sideways rather than squeeze.
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    exportLog()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.accent, in: Capsule())
                        .shadow(color: Theme.accent.opacity(0.2), radius: 6, y: 2)
                }
                .buttonStyle(.plain)

                Button {
                    showReport = true
                } label: {
                    Label("Report", systemImage: "paperplane")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    showConsole = true
                } label: {
                    Label("Console", systemImage: "terminal")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    showWhatsNew = true
                } label: {
                    Label("What\u{2019}s New", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
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
                .foregroundStyle(Theme.ink.opacity(0.18))
        }
        .padding(.top, 10)
    }
}

// MARK: - IPA Picker

/// An .ipa waiting on the "Install anyway?" question.
struct InstallWarning: Identifiable {
    let url: URL
    let message: String
    var id: String { url.path }
}

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
                        .foregroundStyle(Theme.primaryText.opacity(0.85))
                }

                Text("Install an IPA")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryText)

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
                    .foregroundStyle(Theme.onAccent)
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
    @State private var installNote = ""
    @State private var toast = ""
    /// An .ipa that looks like it can't run on this device, waiting on "Install anyway?" (performInstall).
    @State private var installWarning: InstallWarning?
    @StateObject private var volume = VolumeWatcher()
    /// Settings › Volume buttons. Off (the default) leaves this phone's volume buttons to this phone. On, every
    /// press was swallowed and sent to the guest, which threw its own volume overlay up over whatever was running,
    /// and there was no way to turn the actual sound down while a device was open.
    @AppStorage("passVolumeButtons") private var passVolumeButtons = false
    @StateObject private var modem = ModemController()
    @StateObject private var controls = DeviceControls()
    @State private var showSettings = false
    @State private var showDeviceReport = false
    @State private var showMusic = false
    @State private var showMedia = false
    @State private var showTweaks = false
    @State private var microphone: Microphone?
    @State private var micOn = false
    /// The mic was turned on by hand from the menu; followGuest then leaves it alone instead of switching it off
    /// when the guest doesn't seem to be reading it. Lets the user test the mic even if the "is the guest
    /// listening?" detection is wrong on a board.
    @State private var micForced = false
    /// The Console sheet: the device's serial console and Light Touch's log, live (ConsoleView).
    @State private var showConsole = false
    @State private var recorder: ScreenRecorder?
    @State private var reportScreen: CGImage?
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardBridge: KeyboardBridge?
    @State private var firstFrameSeen = false
    @State private var bootIsSlow = false

    private var mode: ViewMode { ViewMode(rawValue: viewModeRaw) ?? .bezel }

    var body: some View {
        ZStack {
            stageBackground

            // Hidden input helpers — the keyboard bridge takes hardware-keyboard keys, the volume watcher
            // notices iPhone volume changes and turns them into emulator button presses.
            Color.clear.frame(width: 0, height: 0)
                .overlay(
                    KeyboardBridgeView(agent: emulator.agent, qemu: emulator.qemu) { bridge in
                        Task { @MainActor in
                            keyboardBridge = bridge
                            bridge?.becomeFirstResponder()
                        }
                    }
                )
                .overlay { if passVolumeButtons { VolumeWatcherView(watcher: volume) } }
                // Turning it off mid-session lets go of this phone's volume at once: the view goes, but the audio
                // session observation it started would otherwise keep swallowing presses until the device closed.
                .onChange(of: passVolumeButtons) { on in if !on { volume.stop() } }

            switch mode {
            case .bezel, .plain, .model:
                windowed
            case .immersive:
                immersive
            }

            savingOverlay
        }
        // The stage is always dark, whatever the rest of the app is doing: a running device on a white stage
        // looks wrong. Applied here, inside the sheets below, so Settings and the rest still follow the system.
        .environment(\.colorScheme, .dark)
        .environmentObject(controls)
        .task { await followGuestMicrophone() }
        .task {
            // No lit screen after two minutes usually means the filesystem is being repaired, not that the app
            // is broken. Say so, with the way out.
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if PerfStats.frames < 30 { bootIsSlow = true }
        }
        .onAppear {
            details = device.details
            modem.qemu = emulator.qemu
            controls.hasGPS = details.board?.hasGPS ?? false
            // No receiver, but iOS 5 or later: the location goes in through iOS's own simulation (GuestLocation).
            controls.simulatesLocation = !controls.hasGPS
                && (Int((details.version ?? "").prefix { $0 != "." }) ?? 0) >= 5
            controls.agent = emulator.agent
            controls.start(qemu: emulator.qemu)
            AutoCool.shared.start(qemu: emulator.qemu)
            if let agent = emulator.agent { controls.watchGuestOrientation(agent: agent) }
            volume.onVolumeUp = { emulator.press(2) }
            volume.onVolumeDown = { emulator.press(3) }
            // The device usually starts before this view appears, so its state has already changed by now: the
            // tone never played when it waited for that change alone.
            if emulator.state == .running { playStartupTone() }
        }
        .onDisappear {
            volume.stop()
            controls.stop()
            AutoCool.shared.stop()
            microphone?.stop()
            recorder?.stop { _ in }
        }
        // Stop the emulated CPU while this app is in the background: an old iPhone running in a pocket is just
        // this phone's battery going down for nothing.
        .onChange(of: scenePhase) { phase in
            // Only a real trip to the background pauses it. .inactive is Control Centre, Notification Centre, a
            // screen recording starting — pausing on those made the device stutter for nothing.
            switch phase {
            case .active: emulator.enterForeground(controls: controls)
            case .background: emulator.enterBackground(controls: controls)
            default: break
            }
        }
        .onChange(of: controls.storageFailed) { failed in
            if failed { toast = "The device\u{2019}s storage stopped answering. Its log has the details." }
        }
        .onChange(of: controls.guestWantsShutdown) { confirmed in
            if confirmed { toast = "The device has shut itself down. Save & quit, or shut the emulator down." }
        }
        .onReceive(NotificationCenter.default.publisher(for: GuestAgent.crashNotification)) { note in
            guard let message = note.object as? String else { return }
            toast = message
            Task {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if toast == message { toast = "" }
            }
        }
        .alert(item: $installWarning) { warning in
            Alert(title: Text("Install anyway?"), message: Text(warning.message),
                  primaryButton: .default(Text("Install Anyway")) {
                      Task { await performInstall(url: warning.url, checked: true) }
                  },
                  secondaryButton: .cancel { try? FileManager.default.removeItem(at: warning.url) })
        }
        .onChange(of: emulator.state) { state in
            if state == .running { playStartupTone() }
        }
        .sheet(item: $shareItem) { item in ActivityView(items: [item.url]) }
        .sheet(isPresented: $showConsole) { ConsoleView { showConsole = false } }
        .sheet(isPresented: $showDeviceReport) {
            ReportSheet(deviceName: device.name, deviceDetails: device.subtitle, screen: reportScreen) {
                showDeviceReport = false
            }
        }
        .fullScreenCover(isPresented: $showStore) {
            LegacyStoreView(agent: emulator.agent, target: device.storeTarget) { showStore = false }
        }
        .sheet(isPresented: $showIPAPicker) { ipaPickerSheet }
        .sheet(isPresented: $showApps) {
            if let agent = emulator.agent { AppsBrowserView(agent: agent) { showApps = false } }
        }
        .sheet(isPresented: $showMusic) {
            if let agent = emulator.agent { MusicImportView(agent: agent) { showMusic = false } }
        }
        .sheet(isPresented: $showMedia) {
            if let agent = emulator.agent {
                MediaImportView(agent: agent, hd: Self.playsHD(details.board?.rawValue)) { showMedia = false }
            }
        }
        .sheet(isPresented: $showTweaks) {
            if let agent = emulator.agent { TweaksView(agent: agent) { showTweaks = false } }
        }
        .sheet(isPresented: $showFiles) {
            if let agent = emulator.agent { FilesBrowserView(agent: agent) { showFiles = false } }
        }
        .sheet(isPresented: $showCarrier) {
            CarrierEditor(agent: emulator.agent, modem: modem) { showCarrier = false }
        }
        .sheet(isPresented: $showHelp) { HelpView { showHelp = false } }
        .sheet(isPresented: $showSettings) {
            DeviceSettingsView(
                device: device, details: details, controls: controls, usb: emulator.usb,
                onProbeUSB: {
                    guard let session = emulator.usb else { return }
                    Task {
                        installNote = "Asking the device over USB\u{2026}"
                        let answer = await session.probe()
                        installNote = answer ?? "The device did not answer over USB. See the log."
                    }
                },
                onShowHelp: { showSettings = false; showHelp = true },
                onDismiss: { showSettings = false })
        }
    }

    // MARK: - Layouts

    /// Plain and bezel modes: the Mac app's plain view. A floating top bar (back / name / Console) and a floating
    /// bottom pill (settings · Home · sliders). The … menu is behind the sliders icon.
    private var windowed: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 2)
            // The device stays upright; only the picture inside its screen turns (DisplayUIView.turns).
            DeviceStage(board: details.board, qemu: emulator.qemu, mode: mode, keyboardBridge: keyboardBridge) {
                emulator.press(0)
            }
            Spacer(minLength: 2)
            // The device turned its own screen off. Worth saying, because a black screen and a wedged device look
            // identical otherwise.
            if bootIsSlow, !controls.screenAsleep {
                Text("Still starting. A device that was closed while running repairs its storage first, which takes a long while here \u{2014} hold its row on the home screen and Erase content to put it back to how it was prepared.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.warning)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
            }
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

    /// Immersive: the device's screen and its Home button, and nothing else — the phone as it would sit in your
    /// hand. Laid out by proportion rather than pinned to the top, so it sits the same way on every phone: the screen
    /// in the band from roughly an eighth of the way down to four-fifths, the Home button centred in what is left
    /// below it. Everything else is behind the dot in the corner, which opens a menu and covers nothing.
    private var immersive: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            // The guest's screen shape, from the device art (320x480 on these phones, 4:3 on an iPad).
            let art = details.board?.facts.art
            let aspect = art.map { $0.screenCutout.height / max($0.screenCutout.width, 1) } ?? 1.5
            // The band the screen lives in, and the Home button below it.
            // As big as the phone allows: a 6-point margin at the sides, the dot's row above, the Home button below.
            let bandTop = height * 0.085
            let bandBottom = height * 0.845
            let bandHeight = bandBottom - bandTop
            let margin: CGFloat = 12
            let sideways = controls.quarterTurns % 2 != 0
            // Upright: as tall as the band allows. Turned: as wide as the band allows (the long side across).
            let screenHeight = sideways
                ? min(width - margin, bandHeight * aspect) / aspect
                : min(bandHeight, (width - margin) * aspect)
            let screenWidth = sideways ? screenHeight * aspect : screenHeight / aspect
            let home = min(max(height * 0.08, 52), 72)
            let homeCentre = bandBottom + (height - bandBottom) * 0.5

            ZStack {
                Color.black.ignoresSafeArea()

                // Sideways the frame goes wide, and the picture turns inside it (DisplayUIView.turns).
                GuestScreen(qemu: emulator.qemu, keyboardBridge: keyboardBridge)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .frame(width: screenWidth, height: screenHeight)
                    .animation(.spring(duration: 0.45), value: controls.quarterTurns)
                .position(x: width / 2, y: bandTop + bandHeight / 2)

                homeButton(diameter: home)
                    .position(x: width / 2, y: homeCentre)

                // The dot. A menu, nothing more.
                VStack {
                    HStack {
                        Spacer()
                        Menu {
                            emulatorMenuContents
                            // Immersive has no gear: Settings live in its one menu.
                            Button { showSettings = true } label: { Label("Settings\u{2026}", systemImage: "gearshape") }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial, in: Circle())
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .padding(.trailing, 14)
                    }
                    Spacer()
                }

                if bootIsSlow, !controls.screenAsleep {
                    Text("Still starting \u{2014} if it was closed while running, it is repairing its storage. Hold its row on the home screen and Erase content to reset it.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.warning)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .position(x: width / 2, y: bandTop / 2)
                }
            }
        }
    }

    /// The Home button: a ring with the rounded square inside it, the way the device's own is drawn.
    private func homeButton(diameter: CGFloat) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            emulator.press(0)
        } label: {
            Circle()
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 2.5)
                .background(Circle().fill(Color.white.opacity(0.04)))
                .frame(width: diameter, height: diameter)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.white.opacity(0.75), lineWidth: 2)
                        .frame(width: diameter * 0.3, height: diameter * 0.3)
                )
        }
        .buttonStyle(.plain)
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
                showConsole = true
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

    /// What the controls offer in the moment: actions, not settings. Anything you set once lives in Settings.
    /// The actions menu: what you reach for most at the top level (the Legacy Store, the iPhone's carrier, power),
    /// everything else one level down, by what it's for. Settings are the gear beside it.
    @ViewBuilder private var emulatorMenuContents: some View {
        Section {
            Button { showStore = true } label: { Label("Legacy Store", systemImage: "bag") }
            if details.isPhone {
                Button { showCarrier = true } label: {
                    Label("Carrier, calls and texts\u{2026}", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
        }
        Section {
            if emulator.agent != nil {
                Menu {
                    Button { showMusic = true } label: { Label("Add music\u{2026}", systemImage: "music.note") }
                    Button { showMedia = true } label: { Label("Add photos & videos\u{2026}", systemImage: "photo.on.rectangle") }
                } label: { Label("Media", systemImage: "photo.stack") }
            }
            Menu {
                if emulator.agent != nil {
                    Button { showApps = true } label: { Label("Apps on the device", systemImage: "square.grid.2x2") }
                    Button { showFiles = true } label: { Label("Files on the device", systemImage: "folder") }
                }
                Button { showIPAPicker = true } label: { Label("Install an IPA\u{2026}", systemImage: "doc.zipper") }
            } label: { Label("Apps & files", systemImage: "square.grid.2x2") }
            Menu {
                Button { controls.rotate(clockwise: false) } label: { Label("Rotate left", systemImage: "rotate.left") }
                Button { controls.rotate(clockwise: true) } label: { Label("Rotate right", systemImage: "rotate.right") }
                if controls.orientation != 1 || controls.quarterTurns != 0 {
                    Button { controls.upright() } label: { Label("Upright", systemImage: "iphone") }
                }
                Button { controls.shake() } label: { Label("Shake", systemImage: "waveform") }
                Button { emulator.press(1) } label: { Label("Sleep / Wake", systemImage: "power.circle") }
                if DeviceModel3D.url(for: details.board) != nil {
                    if mode == .model {
                        Button { NotificationCenter.default.post(name: DeviceModel3D.specialTrick, object: nil) } label: {
                            Label("Special trick", systemImage: "figure.skateboarding")
                        }
                        Button { viewModeRaw = ViewMode.bezel.rawValue } label: { Label("Show flat", systemImage: "iphone") }
                    } else {
                        Button { viewModeRaw = ViewMode.model.rawValue } label: { Label("Show in 3D", systemImage: "cube") }
                    }
                }
                Button {
                    toast = controls.pasteIntoDevice() ? "Pasted into the device." : "Nothing on the clipboard."
                } label: { Label("Paste into the device", systemImage: "doc.on.clipboard") }
                if controls.guestCopied != nil {
                    Button {
                        toast = controls.copyFromDevice() ? "Copied from the device." : "Nothing copied there yet."
                    } label: { Label("Copy from the device", systemImage: "doc.on.doc") }
                }
                if micOn {
                    Button { toggleMicrophone() } label: { Label("Stop the microphone now", systemImage: "mic.slash") }
                } else if Microphone.supported(board: details.board?.rawValue) {
                    Button { toggleMicrophone() } label: { Label("Turn the microphone on", systemImage: "mic") }
                }
                if emulator.agent != nil {
                    Button { showTweaks = true } label: { Label("Tweaks\u{2026}", systemImage: "wand.and.stars") }
                }
            } label: { Label("Device", systemImage: "iphone") }
            Menu {
                Button { takeScreenshot() } label: { Label("Save screenshot", systemImage: "camera") }
                Button { toggleRecording() } label: {
                    Label(recorder == nil ? "Record the screen" : "Stop recording",
                          systemImage: recorder == nil ? "record.circle" : "stop.circle")
                }
                Button { openReport() } label: { Label("Send report\u{2026}", systemImage: "paperplane") }
                Button {
                    if let url = LTMLog.exportCopy() { shareItem = ShareItem(url: url) }
                } label: { Label("Export log", systemImage: "square.and.arrow.up") }
            } label: { Label(recorder == nil ? "Capture" : "Capture (recording)", systemImage: "camera.viewfinder") }
        }
        Section("Power") {
            Button { controls.restartDevice() } label: { Label("Restart the device", systemImage: "arrow.clockwise") }
            // Both of these leave the device able to start again. Closing the app on a running device does not:
            // its next boot is spent repairing the filesystem.
            Button { emulator.saveAndQuit() } label: { Label("Save & quit", systemImage: "tray.and.arrow.down") }
            Button { emulator.powerOffCleanly() } label: { Label("Shut down properly", systemImage: "power") }
        }
    }

    /// Floating pill: Settings on the left, Home in the middle, and the actions menu on the right.
    private var bottomPill: some View {
        HStack(spacing: 18) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.08), in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

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
                emulatorMenuContents
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

    /// Install an IPA through the guest agent (no jailbreak needed); the USB bridge is the fallback when the agent
    /// isn't there.
    private func performInstall(url: URL, checked: Bool = false) async {
        // Can this device run it at all? Asked before anything is copied, and only asked: an app built only for a
        // newer iPhone or a newer iOS quits the moment it opens, but whether to try is the user's call.
        if !checked, let agent = emulator.agent, agent.status == .alive {
            let version = agent.guestVersion
            let problem = await Task.detached(priority: .userInitiated) {
                GuestAgent.installProblem(ipa: url, iosVersion: version)
            }.value
            if let problem {
                installWarning = InstallWarning(url: url, message: problem)
                return
            }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        installNote = "Installing \(url.lastPathComponent)\u{2026}"
        if let agent = emulator.agent, agent.status == .alive {
            do {
                let app = try await agent.installApp(ipa: url) { fraction, status in
                    Task { @MainActor in installNote = status }
                }
                installNote = app.needsRestart
                    ? "\(app.name) is installed. Restart the device to see its icon."
                    : "\(app.name) is installed."
            } catch {
                installNote = error.localizedDescription
            }
            clearInstallNote()
            return
        }
        if let session = emulator.usb, case .ready = session.state {
            do {
                try await session.install(ipa: url) { fraction, status in
                    Task { @MainActor in installNote = "\(status) " + String(format: "%.0f%%", fraction * 100) }
                }
                installNote = "Installed."
            } catch {
                installNote = "USB install failed: \(error)"
            }
            clearInstallNote()
            return
        }
        installNote = "The device is not ready to take apps yet. Wait for the Home screen, then try again."
        clearInstallNote()
    }

    private func clearInstallNote() {
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            installNote = ""
        }
    }

    /// The report sheet, with the device's screen as it is now.
    private func openReport() {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        reportScreen = window.flatMap { DisplaySnapshot.latestFrame(inside: $0) }
        showDeviceReport = true
    }

    /// The A4 boards' Videos app plays 720p; the rest want 640×480.
    static func playsHD(_ board: String?) -> Bool { ["n81ap", "n90ap", "k48ap"].contains(board ?? "") }

    /// The phone's microphone follows the device's: on while something on it records (Voice Memos, a voice app),
    /// off three seconds after it stops, so the phone's orange dot only shows when the device is really listening.
    /// Only the boards whose emulated hardware has a microphone input, and only with Settings › Microphone on.
    /// The startup tone, once per boot of this device (Settings › Startup tone).
    private func playStartupTone() {
        guard startupTone, !firstFrameSeen else { return }
        firstFrameSeen = true
        StartupTone.play()
    }

    private func followGuestMicrophone() async {
        guard Microphone.supported(board: details.board?.rawValue) || Microphone.supported(board: device.details.board?.rawValue)
        else { return }
        var quietSince: Date?
        var refused = false
        var wasListening = false
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let qemu = emulator.qemu, let listening = qemu.micListening else { continue }
            // Forced on from the menu: hold the mic open and let followGuest leave it alone.
            if micForced { continue }
            // Log when the guest starts or stops reading the microphone, so a mic that never engages is visible.
            let hears = listening()
            if hears != wasListening {
                wasListening = hears
                LTMLog.note("microphone: guest \(hears ? "started" : "stopped") reading the mic input")
            }
            let wanted = UserDefaults.standard.object(forKey: "microphone") as? Bool ?? true
            if wanted, !refused, hears {
                quietSince = nil
                if !micOn {
                    guard let mic = microphone ?? Microphone(qemu: qemu) else { return }
                    microphone = mic
                    if let why = await mic.start() {
                        refused = true
                        toast = why
                    } else {
                        micOn = true
                        toast = "The device is listening through this phone\u{2019}s microphone."
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        toast = ""
                    }
                }
            } else if micOn {
                if !wanted { quietSince = .distantPast }
                if quietSince == nil { quietSince = Date() }
                if let since = quietSince, Date().timeIntervalSince(since) > 3 {
                    microphone?.stop()
                    micOn = false
                    quietSince = nil
                }
            }
        }
    }

    private func toggleMicrophone() {
        if micOn {
            microphone?.stop()
            micOn = false
            micForced = false
            toast = "Microphone off."
            return
        }
        guard let qemu = emulator.qemu, let mic = microphone ?? Microphone(qemu: qemu) else { return }
        microphone = mic
        Task {
            if let why = await mic.start() {
                toast = why
            } else {
                micOn = true
                micForced = true   // held open until turned off by hand, whatever the guest seems to be doing
                toast = "Microphone forced on. Record something and check the log."
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            toast = ""
        }
    }

    private func toggleRecording() {
        if let active = recorder {
            recorder = nil
            toast = "Finishing the movie\u{2026}"
            active.stop { url in
                guard let url else {
                    toast = "The recording couldn\u{2019}t be saved."
                    return
                }
                Task {
                    let result = await Screenshot.save(video: url)
                    switch result {
                    case .saved, .savedFile: toast = "Recording saved to Photos (Light Touch album)."
                    default:
                        toast = "Photos wouldn\u{2019}t take it; share it instead."
                        shareItem = ShareItem(url: url)
                    }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    toast = ""
                }
            }
            return
        }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
            let frame = DisplaySnapshot.latestFrame(inside: window)
        else {
            toast = "No screen to record yet."
            return
        }
        do {
            recorder = try ScreenRecorder.start(width: frame.width, height: frame.height)
            toast = "Recording. Choose Stop recording in the menu to finish."
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if toast.hasPrefix("Recording.") { toast = "" }
            }
        } catch {
            toast = error.localizedDescription
        }
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
