import SwiftUI
import UIKit

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

enum Theme {
    static let card = Color(white: 0.11)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.36, green: 0.62, blue: 1.0)
}

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke))
    }
}

struct Chip: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.15), in: Capsule())
    }
}

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
            logNote = "No log yet. Boot a device first; the log is kept until the next boot."
        }
    }

    private var home: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                statusCard
                devicesCard
                packedCard
                speedCard
                logCard
                if case .failed(let message) = emulator.state {
                    Card("Problem", symbol: "exclamationmark.triangle.fill") {
                        Text(message).font(.footnote).foregroundStyle(Color.red)
                    }
                }
            }
            .padding(16)
        }
        .background(Color.black.ignoresSafeArea())
        .refreshable { reload() }
        .onAppear {
            reload()
            emulator.load()
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "ipodtouch").font(.system(size: 34)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Light Touch").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Old iPhone OS on your iPhone").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private var statusCard: some View {
        Card("Status", symbol: "bolt.horizontal.circle") {
            HStack(spacing: 8) {
                Chip(text: JIT.ready ? "JIT on" : "JIT off", symbol: JIT.ready ? "bolt.fill" : "bolt.slash.fill",
                    color: JIT.ready ? Color.green : Color.orange)
                Chip(text: emulator.engine, symbol: "cpu", color: Theme.accent)
            }
            Text(JIT.summary).font(.caption).foregroundStyle(.secondary)
            if !JIT.ready {
                Text("Turn JIT on first: StikDebug with universal.js, then open Light Touch (in LiveContainer, use Launch with JIT).")
                    .font(.footnote).foregroundStyle(Color.orange)
            }
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                Text("Low Power Mode is on. It slows the emulator a lot: turn it off.").font(.footnote).foregroundStyle(Color.orange)
            }
            if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                Text("The phone is throttling because it is hot. Let it cool, and unplug it while the emulator runs.")
                    .font(.footnote).foregroundStyle(Color.orange)
            }
        }
    }

    private var devicesCard: some View {
        Card("Devices", symbol: "externaldrive") {
            if devices.isEmpty {
                Text("No device yet. Unpack the ready-made iPod touch below, or copy a prepared device folder into Files › LightTouch › Devices, then pull down to refresh.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(devices) { d in
                Button {
                    boot(d)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "ipodtouch")
                        Text(d.name).fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "play.fill")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var packedCard: some View {
        Card("Packed devices", symbol: "shippingbox") {
            if packed.isEmpty {
                Text("For the ready-made iPod touch: copy the Mac app's Contents/Resources/Device folder into Files › LightTouch › Device, then pull down to refresh.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(packed, id: \.self) { url in
                Button {
                    importer.unpack(url) { reload() }
                } label: {
                    Label("Unpack \(url.deletingPathExtension().lastPathComponent)", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(importer.busy)
            }
            if importer.busy { ProgressView(value: importer.fraction) }
            if !importer.message.isEmpty { Text(importer.message).font(.footnote) }
            Text("Boot ROMs go in the same Device folder (bootrom_240_4, and ipod1g/bootrom_s5l8900).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var speedCard: some View {
        Card("Speed", symbol: "speedometer") {
            Toggle("Graphics fix: rectangle textures as 2D (experimental)", isOn: $rect2d)
            Toggle("Faster graphics (skips GL error checks)", isOn: $fastGL)
            Toggle("Write diagnostics to the log", isOn: $diag)
            Picker("Code cache", selection: $codeCacheMB) {
                Text("256 MB").tag(256)
                Text("512 MB").tag(512)
                Text("1 GB").tag(1024)
            }
            Text("Save & quit only works when the device is not using live graphics state, which the home screen does on iOS for now.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var logCard: some View {
        Card("Log", symbol: "doc.text.magnifyingglass") {
            Text("The emulator's messages and speed numbers go to lighttouch.log. Export it to send it anywhere: Files, AirDrop, Mail, a cloud drive.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    exportLog()
                } label: {
                    Label("Export log", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                Button(role: .destructive) {
                    try? FileManager.default.removeItem(at: LTMLog.url)
                    logNote = "Log deleted."
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
            if !logNote.isEmpty { Text(logNote).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

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
                .background(Color.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white)
    }
}

struct EmulatorScreen: View {
    @EnvironmentObject var emulator: Emulator
    let device: DeviceFolder
    @State private var shareItem: ShareItem?

    var body: some View {
        VStack(spacing: 14) {
            DisplayView(qemu: emulator.qemu)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
                .padding(.horizontal, 10)
            controls
            if !emulator.saveMessage.isEmpty, emulator.state == .running {
                Text(emulator.saveMessage).font(.footnote).foregroundStyle(Color.orange)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.black.ignoresSafeArea())
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
                    .background(Color.white.opacity(0.12), in: Circle())
                    .foregroundStyle(Color.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder private var savingOverlay: some View {
        if emulator.state == .saving || emulator.state == .saved {
            ZStack {
                Color.black.opacity(0.75).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView().tint(Color.white)
                    Text(emulator.saveMessage).foregroundStyle(Color.white)
                }
            }
        }
    }
}
