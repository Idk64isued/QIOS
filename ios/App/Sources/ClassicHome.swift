import SwiftUI
import UIKit

/// A device's icon: its photo on a brushed-silver tile, with the gloss every icon of the time had.
struct DeviceIconArt: View {
    let model: DeviceModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            LinearGradient(colors: [Six.ui(0xF4F6F8).swiftUI, Six.ui(0xA9B0BA).swiftUI], startPoint: .top, endPoint: .bottom)
            DeviceThumbnail(model: model, height: 50)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                .frame(width: 92, height: 52)
                .offset(y: -24)
        }
        .frame(width: 60, height: 60)
        .clipShape(shape)
        .overlay(shape.stroke(Color.black.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 2, y: 2)
    }
}

// MARK: - The original layout in iOS 6 (Settings › Home Screen › Original (iOS 6))

/// Settings \u{25B8} Graphics Capture, as a row of its own: it keeps its own setting, so ClassicHome's memberwise
/// initialiser (used from RootView) stays as it was.
struct GraphicsCaptureRow: View {
    @AppStorage("glCapture") private var glCapture = false
    var body: some View { SixToggleRow(title: "Graphics Capture", isOn: $glCapture) }
}

/// The original home screen, section for section, drawn as iOS 6's grouped tables.
struct ClassicHome: View {
    let devices: [DeviceFolder]
    let failure: String?
    let engine: String
    let actions: HomeActions
    @Binding var bezel: Bool
    @Binding var rect2d: Bool
    @Binding var fastGL: Bool
    @Binding var diag: Bool
    @Binding var enableUSB: Bool
    @Binding var codeCacheMB: Int
    let logNote: String

    var body: some View {
        SixScreen(title: "Halcyon", right: ("Settings", actions.settings)) {
            header
            if let failure {
                SixSection {
                    SixRow(icon: AnyView(SixIcon(symbol: "exclamationmark.triangle.fill", colors: [Six.ui(0xF06A5F).swiftUI, Six.ui(0xC8160D).swiftUI])),
                           title: "Couldn\u{2019}t start", subtitle: failure, chevron: false)
                }
            }
            SixSection(header: "Status", footer: JIT.usable ? nil : "Enable JIT first: StikDebug with universal.js, then open Halcyon. In LiveContainer, use Launch with JIT.") {
                SixRow(title: "JIT", value: JIT.usable ? "Enabled" : "Off", chevron: false,
                       titleColor: JIT.usable ? nil : Six.red)
                SixSeparator()
                SixRow(title: "Engine", value: engine, chevron: false)
                if !OnDevicePrep.available {
                    SixSeparator()
                    SixRow(title: "Firmware preparer", value: "Missing", chevron: false)
                }
                if ProcessInfo.processInfo.isLowPowerModeEnabled {
                    SixSeparator()
                    SixRow(title: "Low Power Mode", value: "On", chevron: false)
                }
            }
            SixSection(header: "Devices", footer: devices.isEmpty ? "Add Device downloads what it needs and sets one up on this iPhone. Nothing to copy over." : "Hold a device to erase its content.") {
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { SixSeparator() }
                    deviceRow(device)
                }
                if !devices.isEmpty { SixSeparator() }
                SixRow(icon: AnyView(SixIcon(symbol: "plus", colors: [Six.ui(0x8EDB5F).swiftUI, Six.ui(0x2F9A1E).swiftUI])),
                       title: devices.isEmpty ? "Add Your First Device" : "Add Device\u{2026}", titleColor: Six.blue,
                       action: actions.addDevice)
            }
            SixSection(header: "Library", footer: "Apps are installed while a device is running; ones you get with no device running wait in the store\u{2019}s Downloads.") {
                SixRow(icon: AnyView(SixIcon(symbol: "bag.fill", colors: [Six.ui(0x74B6F7).swiftUI, Six.ui(0x1858C9).swiftUI])),
                       title: "Legacy Store", action: actions.store)
                SixSeparator()
                SixRow(icon: AnyView(SixIcon(symbol: "internaldrive.fill", colors: [Six.ui(0xF5A25A).swiftUI, Six.ui(0xC85412).swiftUI])),
                       title: "Storage", action: actions.storage)
            }
            SixSection(header: "Settings", footer: "USB bridge turns on the Mac-style IPA install path. It can confuse the guest at boot on some devices; leave it off for normal use.") {
                SixRow(icon: AnyView(SixIcon(symbol: "slider.horizontal.3", colors: [Six.ui(0xC4C8CE).swiftUI, Six.ui(0x5E636B).swiftUI])),
                       title: "All Settings", value: QemuRuntime.angleBundled ? QemuRuntime.renderer.rawValue : nil,
                       action: actions.allSettings)
                SixSeparator()
                SixToggleRow(title: "Show the Device", isOn: $bezel)
                SixSeparator()
                SixToggleRow(title: "Rectangle Textures \u{2192} 2D", isOn: $rect2d)
                SixSeparator()
                SixToggleRow(title: "Skip GL Error Checks", isOn: $fastGL)
                SixSeparator()
                GraphicsCaptureRow()
                SixSeparator()
                SixToggleRow(title: "Diagnostics in Log", isOn: $diag)
                SixSeparator()
                SixToggleRow(title: "USB Bridge", isOn: $enableUSB)
                SixSeparator()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Code Cache").font(Six.font(16, bold: true)).foregroundStyle(Six.text)
                    SixSegments(options: [(256, "256 MB"), (512, "512 MB"), (1024, "1 GB")], selection: $codeCacheMB)
                }
                .padding(10)
            }
            SixSection(header: "Log", footer: logNote.isEmpty ? nil : logNote) {
                SixRow(title: "What\u{2019}s New", action: actions.whatsNew)
                SixSeparator()
                SixRow(title: "Export Log", action: actions.exportLog)
                SixSeparator()
                SixRow(title: "Send Report", action: actions.report)
                SixSeparator()
                SixRow(title: "Console", action: actions.console)
                SixSeparator()
                SixRow(title: "Clear Log", chevron: false, titleColor: Six.red, centered: true, action: actions.clearLog)
            }
            Text("Halcyon \u{2014} formerly Light Touch for iOS (QIOS)\nOn samhenrigold\u{2019}s LightTouchMac \u{00B7} GPL-2.0 \u{00B7} github.com/Idk64isued/QIOS")
                .font(Six.font(13))
                .foregroundStyle(Six.header)
                .shadow(color: Six.headerShadow, radius: 0, y: 1)
                .multilineTextAlignment(.center)
                .padding(.top, 22)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let logo = UIImage(named: "Logo") {
                Image(uiImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 57, height: 57)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 2)
            } else {
                DeviceIconArt(model: DeviceModel(board: "n72ap")).frame(width: 57, height: 57)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Halcyon").font(Six.font(22, bold: true)).foregroundStyle(Six.text)
                    .shadow(color: Six.headerShadow, radius: 0, y: 1)
                Text("Old iPhone OS, on your iPhone").font(Six.font(14)).foregroundStyle(Six.header)
                    .shadow(color: Six.headerShadow, radius: 0, y: 1)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.top, 18)
    }

    private func deviceRow(_ device: DeviceFolder) -> some View {
        SixRow(icon: AnyView(DeviceIconArt(model: device.model ?? DeviceModel(board: "n72ap")).scaleEffect(0.75).frame(width: 45, height: 45)),
               title: device.name,
               subtitle: device.hasSavedState ? "\(device.subtitle)\nPicks up where it left off" : device.subtitle,
               action: { actions.boot(device) })
            .contextMenu {
                Button { actions.boot(device) } label: { Label("Start", systemImage: "play.fill") }
                Button(role: .destructive) { actions.erase(device) } label: {
                    Label("Erase content", systemImage: "arrow.counterclockwise")
                }
            }
    }
}

// MARK: - Settings for the iOS 6 interfaces

/// The Original (iOS 6) list's Settings button: the interface, the appearance, the
/// settings the original home screen carries, and the way to every other setting, as iOS 6's Settings app.
struct SixHomeSettings: View {
    let actions: HomeActions
    let onDismiss: () -> Void
    @AppStorage("homeInterface") private var interface = HomeInterface.classic.rawValue
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("bezel") private var bezel = true
    @AppStorage("rect2d") private var rect2d = true
    @AppStorage("fastGL") private var fastGL = false
    @AppStorage("glCapture") private var glCapture = false
    @AppStorage("diag") private var diag = true
    @AppStorage("enableUSB") private var enableUSB = false
    @AppStorage("codeCacheMB") private var codeCacheMB = 512
    @State private var note = ""

    var body: some View {
        SixScreen(title: "Settings", right: ("Done", onDismiss)) {
            SixSection(header: "Home Screen", footer: (HomeInterface(rawValue: interface) ?? .classic).detail) {
                ForEach(Array(HomeInterface.allCases.enumerated()), id: \.element) { index, option in
                    if index > 0 { SixSeparator() }
                    SixRow(title: option.title, chevron: false, checked: interface == option.rawValue) {
                        interface = option.rawValue
                    }
                }
            }
            SixSection(header: "Appearance", footer: "Dark is iOS 6 at night: black bars and slate pinstripes. A device\u{2019}s own screen is never changed.") {
                ForEach(Array([("system", "Same as This iPhone"), ("light", "Light"), ("dark", "Dark")].enumerated()), id: \.offset) { index, option in
                    if index > 0 { SixSeparator() }
                    SixRow(title: option.1, chevron: false, checked: appearance == option.0) { appearance = option.0 }
                }
            }
            SixSection {
                SixRow(icon: AnyView(SixIcon(symbol: "slider.horizontal.3", colors: [Six.ui(0xC4C8CE).swiftUI, Six.ui(0x5E636B).swiftUI])),
                       title: "All Settings", subtitle: "Graphics, network, sound, the keyboard\u{2026}",
                       action: actions.allSettings)
            }
            SixSection(header: "Display & Graphics", footer: "Graphics Capture records what a game draws, every ten seconds, into the next report you share. It starts with the next boot and slows games down; turn it off when you\u{2019}re done.") {
                SixToggleRow(title: "Show the Device", subtitle: "The device around its screen.", isOn: $bezel)
                SixSeparator()
                SixToggleRow(title: "Rectangle Textures \u{2192} 2D", isOn: $rect2d)
                SixSeparator()
                SixToggleRow(title: "Skip GL Error Checks", isOn: $fastGL)
                SixSeparator()
                SixToggleRow(title: "Graphics Capture", isOn: $glCapture)
            }
            SixSection(header: "Code Cache", footer: "More holds more of a device\u{2019}s translated code, at the cost of memory.") {
                SixSegments(options: [(256, "256 MB"), (512, "512 MB"), (1024, "1 GB")], selection: $codeCacheMB)
                    .padding(10)
            }
            SixSection(header: "Advanced", footer: "USB bridge turns on the Mac-style IPA install path. It can confuse the guest at boot on some devices; leave it off for normal use.") {
                SixToggleRow(title: "Diagnostics in Log", isOn: $diag)
                SixSeparator()
                SixToggleRow(title: "USB Bridge", isOn: $enableUSB)
            }
            SixSection(header: "Log", footer: note.isEmpty ? nil : note) {
                SixRow(title: "What\u{2019}s New", action: actions.whatsNew)
                SixSeparator()
                SixRow(title: "Export Log", action: actions.exportLog)
                SixSeparator()
                SixRow(title: "Send Report", action: actions.report)
                SixSeparator()
                SixRow(title: "Console", action: actions.console)
                SixSeparator()
                SixRow(title: "Clear Log", chevron: false, titleColor: Six.red, centered: true) {
                    actions.clearLog()
                    note = "Log cleared."
                }
            }
        }
    }
}
