import SwiftUI
import UIKit

// MARK: - Springboard (Settings › Interface › Springboard)

/// The home screen as iOS 4–6's SpringBoard: each device an icon on a wallpaper, pages of them with dots, and a glass
/// dock holding Add Device, the Legacy Store, Settings and Storage. Tapping a device starts it; holding one gives
/// Start and Erase content. Light and dark follow the app's appearance.
struct SpringboardHome: View {
    let devices: [DeviceFolder]
    let failure: String?
    let actions: HomeActions

    @State private var page = 0
    @State private var bannerHidden = false
    @Environment(\.colorScheme) private var scheme

    private static let perPage = 20
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    private enum Item: Identifiable {
        case device(DeviceFolder)
        case console, report
        var id: String {
            switch self {
            case .device(let d): return d.url.path
            case .console: return "console"
            case .report: return "report"
            }
        }
    }

    private var items: [Item] { devices.map(Item.device) + [.console, .report] }

    private var pages: [[Item]] {
        let all = items
        return stride(from: 0, to: all.count, by: Self.perPage).map { Array(all[$0..<min($0 + Self.perPage, all.count)]) }
    }

    var body: some View {
        ZStack {
            SpringboardWallpaper(dark: scheme == .dark)
            VStack(spacing: 0) {
                if let banner = bannerText, !bannerHidden {
                    SpringboardBanner(title: banner.0, message: banner.1) {
                        withAnimation(.easeIn(duration: 0.2)) { bannerHidden = true }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, items in
                        grid(items, first: index == 0).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                pageDots
                dock
            }
        }
    }

    private var bannerText: (String, String)? {
        if let failure { return ("Couldn\u{2019}t start", failure) }
        if !JIT.ready {
            return ("JIT is off", "Enable JIT first: StikDebug with universal.js, then open Light Touch. In LiveContainer, use Launch with JIT.")
        }
        return nil
    }

    private func grid(_ items: [Item], first: Bool) -> some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items) { item in icon(item) }
            }
            .padding(.horizontal, 12)
            .padding(.top, 18)
            if first && devices.isEmpty {
                Text("Tap Add Device in the dock to set up your first device.")
                    .font(Six.font(15, bold: true))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 1, y: 1)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 30)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func icon(_ item: Item) -> some View {
        switch item {
        case .device(let device):
            SpringboardIcon(label: device.name, badge: device.hasSavedState ? SpringboardBadge.resume : nil) {
                actions.boot(device)
            } art: {
                DeviceIconArt(model: device.model ?? DeviceModel(board: "n72ap"))
            }
            .contextMenu {
                Button { actions.boot(device) } label: { Label("Start", systemImage: "play.fill") }
                Button(role: .destructive) { actions.erase(device) } label: {
                    Label("Erase content", systemImage: "arrow.counterclockwise")
                }
            } preview: {
                VStack(spacing: 8) {
                    DeviceThumbnail(model: device.model ?? DeviceModel(board: "n72ap"), height: 150)
                    Text(device.name).font(Six.font(16, bold: true))
                    Text(device.subtitle).font(Six.font(12)).foregroundStyle(.secondary)
                    if device.hasSavedState {
                        Text("Picks up where it left off").font(Six.font(12, bold: true)).foregroundStyle(Six.green)
                    }
                }
                .padding(20)
            }
        case .console:
            SpringboardIcon(label: "Console", action: actions.console) {
                SixIcon(symbol: "terminal.fill", colors: [Six.ui(0x4A4A4A).swiftUI, Six.ui(0x0C0C0C).swiftUI], size: 60)
            }
        case .report:
            SpringboardIcon(label: "Feedback", action: actions.report) {
                SixIcon(symbol: "paperplane.fill", colors: [Six.ui(0xF7C04A).swiftUI, Six.ui(0xE07A12).swiftUI], size: 60)
            }
        }
    }

    private var pageDots: some View {
        HStack(spacing: 9) {
            ForEach(0..<max(1, pages.count), id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(i == page ? 0.95 : 0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .frame(height: 20)
        .opacity(pages.count > 1 ? 1 : 0)
    }

    private var dock: some View {
        HStack(spacing: 0) {
            dockIcon("Add Device", "plus", [Six.ui(0x8EDB5F).swiftUI, Six.ui(0x2F9A1E).swiftUI], actions.addDevice)
            dockIcon("Store", "bag.fill", [Six.ui(0x74B6F7).swiftUI, Six.ui(0x1858C9).swiftUI], actions.store)
            dockIcon("Settings", "gearshape.fill", [Six.ui(0xC4C8CE).swiftUI, Six.ui(0x5E636B).swiftUI], actions.settings)
            dockIcon("Storage", "internaldrive.fill", [Six.ui(0xF5A25A).swiftUI, Six.ui(0xC85412).swiftUI], actions.storage)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(alignment: .bottom) { DockShelf().frame(height: 62) }
        .padding(.bottom, 6)
    }

    private func dockIcon(_ label: String, _ symbol: String, _ colors: [Color], _ action: @escaping () -> Void) -> some View {
        SpringboardIcon(label: label, action: action) {
            SixIcon(symbol: symbol, colors: colors, size: 60)
        }
        .frame(maxWidth: .infinity)
    }
}

/// An icon with its label: dims while held, as SpringBoard's did.
enum SpringboardBadge { case resume }

struct SpringboardIcon<Art: View>: View {
    let label: String
    var badge: SpringboardBadge? = nil
    let action: () -> Void
    @ViewBuilder let art: () -> Art

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                art()
                    .frame(width: 60, height: 60)
                    .overlay(alignment: .topTrailing) {
                        if badge == .resume {
                            Image(systemName: "arrow.uturn.forward")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(
                                    LinearGradient(colors: [Six.ui(0x6FB0FF).swiftUI, Six.ui(0x1A5FD0).swiftUI],
                                                   startPoint: .top, endPoint: .bottom),
                                    in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                                .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
                                .offset(x: 8, y: -8)
                        }
                    }
                Text(label)
                    .font(Six.font(11, bold: true))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.85), radius: 1, y: 1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 76)
            }
        }
        .buttonStyle(SpringboardPress())
    }
}

struct SpringboardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.35 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

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

/// The dock of iOS 4–6: a glass shelf seen from above, lit along its front edge.
struct DockShelf: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let inset: CGFloat = 22
            let top = Path { p in
                p.move(to: CGPoint(x: inset, y: 0))
                p.addLine(to: CGPoint(x: w - inset, y: 0))
                p.addLine(to: CGPoint(x: w, y: h - 14))
                p.addLine(to: CGPoint(x: 0, y: h - 14))
                p.closeSubpath()
            }
            ZStack(alignment: .topLeading) {
                top.fill(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.16)], startPoint: .top, endPoint: .bottom))
                top.stroke(Color.white.opacity(0.55), lineWidth: 1)
                // The front edge.
                Rectangle()
                    .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                    .frame(width: w, height: 14)
                    .offset(y: h - 14)
                Rectangle().fill(Color.white.opacity(0.9)).frame(width: w, height: 1).offset(y: h - 14)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 4, y: -1)
    }
}

/// The wallpaper: deep blue with soft lights (black and blue at night), drawn rather than shipped.
struct SpringboardWallpaper: View {
    let dark: Bool

    var body: some View {
        Canvas { context, size in
            let colors: [Color] = dark
                ? [Six.ui(0x0B1020).swiftUI, Six.ui(0x05070E).swiftUI, Six.ui(0x000000).swiftUI]
                : [Six.ui(0x2C5EA8).swiftUI, Six.ui(0x173D7A).swiftUI, Six.ui(0x0B1F45).swiftUI]
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: colors), startPoint: .zero,
                                               endPoint: CGPoint(x: size.width * 0.3, y: size.height)))
            // Soft lights at fixed places, so the wallpaper doesn't change between launches.
            let lights: [(CGFloat, CGFloat, CGFloat, Double)] = [
                (0.15, 0.12, 0.55, 0.20), (0.85, 0.22, 0.45, 0.16), (0.45, 0.42, 0.70, 0.10),
                (0.10, 0.70, 0.50, 0.14), (0.80, 0.78, 0.60, 0.12), (0.55, 0.95, 0.40, 0.10),
            ]
            for (x, y, r, a) in lights {
                let center = CGPoint(x: size.width * x, y: size.height * y)
                let radius = size.width * r
                let tint = dark ? Six.ui(0x3A63B8).swiftUI : Six.ui(0x9CCBFF).swiftUI
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                             with: .radialGradient(Gradient(colors: [tint.opacity(dark ? a * 0.8 : a), tint.opacity(0)]),
                                                   center: center, startRadius: 0, endRadius: radius))
            }
        }
        .ignoresSafeArea()
    }
}

/// A notification banner of iOS 5–6: a black glossy strip with a title and a line of text.
struct SpringboardBanner: View {
    let title: String
    let message: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SixIcon(symbol: "exclamationmark", colors: [Six.ui(0xF7C04A).swiftUI, Six.ui(0xE07A12).swiftUI], size: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Six.font(14, bold: true)).foregroundStyle(.white)
                Text(message).font(Six.font(13)).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            ZStack(alignment: .top) {
                LinearGradient(colors: [Six.ui(0x3A3A3A).swiftUI, Six.ui(0x0A0A0A).swiftUI], startPoint: .top, endPoint: .bottom)
                Color.white.opacity(0.08).frame(height: 18)
            },
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.black, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
    }
}

// MARK: - The original layout in iOS 6 (Settings › Interface › Original (iOS 6))

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
        SixScreen(title: "Light Touch", right: ("Settings", actions.settings)) {
            header
            if let failure {
                SixSection {
                    SixRow(icon: AnyView(SixIcon(symbol: "exclamationmark.triangle.fill", colors: [Six.ui(0xF06A5F).swiftUI, Six.ui(0xC8160D).swiftUI])),
                           title: "Couldn\u{2019}t start", subtitle: failure, chevron: false)
                }
            }
            SixSection(header: "Status", footer: JIT.ready ? nil : "Enable JIT first: StikDebug with universal.js, then open Light Touch. In LiveContainer, use Launch with JIT.") {
                SixRow(title: "JIT", value: JIT.ready ? "Enabled" : "Off", chevron: false,
                       titleColor: JIT.ready ? nil : Six.red)
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
                SixRow(title: "Export Log", action: actions.exportLog)
                SixSeparator()
                SixRow(title: "Send Report", action: actions.report)
                SixSeparator()
                SixRow(title: "Console", action: actions.console)
                SixSeparator()
                SixRow(title: "Clear Log", chevron: false, titleColor: Six.red, centered: true, action: actions.clearLog)
            }
            Text("Light Touch for iOS\nGPL-2.0 \u{00B7} github.com/Idk64isued/QIOS")
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
                Text("Light Touch").font(Six.font(22, bold: true)).foregroundStyle(Six.text)
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

/// Springboard's Settings icon, and the Original (iOS 6) list's Settings button: the interface, the appearance, the
/// settings the original home screen carries, and the way to every other setting, as iOS 6's Settings app.
struct SixHomeSettings: View {
    let actions: HomeActions
    let onDismiss: () -> Void
    @AppStorage("homeInterface") private var interface = HomeInterface.springboard.rawValue
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("bezel") private var bezel = true
    @AppStorage("rect2d") private var rect2d = true
    @AppStorage("fastGL") private var fastGL = false
    @AppStorage("diag") private var diag = true
    @AppStorage("enableUSB") private var enableUSB = false
    @AppStorage("codeCacheMB") private var codeCacheMB = 512
    @State private var note = ""

    var body: some View {
        SixScreen(title: "Settings", right: ("Done", onDismiss)) {
            SixSection(header: "Home Screen", footer: (HomeInterface(rawValue: interface) ?? .springboard).detail) {
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
            SixSection(header: "Display & Graphics") {
                SixToggleRow(title: "Show the Device", subtitle: "The device around its screen.", isOn: $bezel)
                SixSeparator()
                SixToggleRow(title: "Rectangle Textures \u{2192} 2D", isOn: $rect2d)
                SixSeparator()
                SixToggleRow(title: "Skip GL Error Checks", isOn: $fastGL)
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
