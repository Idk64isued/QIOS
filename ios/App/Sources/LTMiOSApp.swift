import SwiftUI

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

struct RootView: View {
    @EnvironmentObject var emulator: Emulator
    @State private var devices: [DeviceFolder] = []
    @State private var packed: [URL] = []
    @StateObject private var importer = Importer()
    @AppStorage("fastGL") private var fastGL = false
    @AppStorage("diag") private var diag = true
    @AppStorage("codeCacheMB") private var codeCacheMB = 512
    @State private var running: DeviceFolder?

    var body: some View {
        if let running, emulator.showsScreen {
            EmulatorScreen(device: running)
        } else {
            NavigationView {
                List {
                    Section("JIT") {
                        Text(JIT.summary).font(.footnote)
                        Text(JIT.ready
                             ? "JIT is on: the fast emulator will load."
                             : "JIT is off: the slow interpreter will load. Enable JIT with StikDebug first (for LiveContainer, use its Launch with JIT).")
                            .font(.footnote).foregroundStyle(JIT.ready ? Color.green : Color.orange)
                        Text("Engine: \(emulator.engine)").font(.footnote)
                    }
                    Section("Speed") {
                        Toggle("Faster graphics (skips GL error checks)", isOn: $fastGL)
        Toggle("Write diagnostics (lighttouch.log)", isOn: $diag)
                        Picker("Code cache", selection: $codeCacheMB) {
                            Text("256 MB").tag(256)
                            Text("512 MB").tag(512)
                            Text("1 GB").tag(1024)
                        }
                        if ProcessInfo.processInfo.isLowPowerModeEnabled {
                            Text("Low Power Mode is on. It slows the emulator a lot: turn it off.").font(.footnote).foregroundStyle(Color.orange)
                        }
                        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                            Text("The phone is hot and throttling. Let it cool down.").font(.footnote).foregroundStyle(Color.orange)
                        }
                        Text("Quit with Save & quit: the next launch restores the device in seconds instead of booting.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Devices") {
                        if devices.isEmpty {
                            Text("None yet. Copy a prepared device folder (it contains base/device.lock.json) into Files > LightTouch > Devices, then pull to refresh.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(devices) { d in
                            Button(d.name) { running = d; emulator.boot(directory: d.url) }
                        }
                    }
                    Section("Packed devices") {
                        if packed.isEmpty {
                            Text("To get the ready-made iPod touch: copy the Mac app's Contents/Resources/Device folder into Files > LightTouch > Device (it holds n72ap-7E18.itbase and the boot ROMs), then pull to refresh.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(packed, id: \.self) { url in
                            Button("Unpack \(url.deletingPathExtension().lastPathComponent)") {
                                importer.unpack(url) { devices = Library.scan(); packed = PackedDevice.find() }
                            }
                            .disabled(importer.busy)
                        }
                        if importer.busy { ProgressView(value: importer.fraction) }
                        if !importer.message.isEmpty { Text(importer.message).font(.footnote) }
                    }
                    Section("SecureROMs") {
                        Text("Put your boot ROM files in Files > LightTouch > Device (bootrom_240_4, and ipod1g/bootrom_s5l8900).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if case .failed(let message) = emulator.state {
                        Section("Error") { Text(message).font(.footnote).foregroundStyle(.red) }
                    }
                }
                .navigationTitle("Light Touch")
                .refreshable { devices = Library.scan(); packed = PackedDevice.find() }
                .onAppear { devices = Library.scan(); packed = PackedDevice.find(); emulator.load() }
            }
            .navigationViewStyle(.stack)
        }
    }
}

struct EmulatorScreen: View {
    @EnvironmentObject var emulator: Emulator
    let device: DeviceFolder

    var body: some View {
        VStack(spacing: 0) {
            DisplayView(qemu: emulator.qemu).ignoresSafeArea(edges: .top)
            HStack(spacing: 18) {
                Button("Home") { emulator.press(0) }
                Button("Power") { emulator.press(1) }
                Button("Vol +") { emulator.press(2) }
                Button("Vol -") { emulator.press(3) }
                Menu("Quit") {
                    Button("Save & quit") { emulator.saveAndQuit() }
                    Button("Shut down", role: .destructive) { emulator.quit() }
                }
            }
            .buttonStyle(.bordered).padding(.vertical, 8)
            if !emulator.saveMessage.isEmpty, emulator.state == .running {
                Text(emulator.saveMessage).font(.footnote).foregroundStyle(Color.orange).padding(.bottom, 6)
            }
        }
        .background(Color.black)
        .overlay {
            if emulator.state == .saving || emulator.state == .saved {
                ZStack {
                    Color.black.opacity(0.75).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(emulator.saveMessage).foregroundStyle(.white)
                    }
                }
            }
        }
    }
}
