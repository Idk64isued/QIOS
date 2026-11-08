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
    @State private var running: DeviceFolder?

    var body: some View {
        if let running, case .running = emulator.state {
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
                    Section("Devices") {
                        if devices.isEmpty {
                            Text("None yet. Copy a prepared device folder (it contains base/device.lock.json) into Files > LightTouch > Devices, then pull to refresh.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(devices) { d in
                            Button(d.name) { running = d; emulator.boot(directory: d.url) }
                        }
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
                .refreshable { devices = Library.scan() }
                .onAppear { devices = Library.scan(); emulator.load() }
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
                Button("Shut down") { emulator.quit() }.tint(.red)
            }
            .buttonStyle(.bordered).padding(.vertical, 8)
        }
        .background(Color.black)
    }
}
