import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Apps and Files on the running guest, over the guest agent (no USB). Works best on a jailbroken device, where the
// agent can read /Applications and /var; a stock device can still list what the agent sees and launch apps by id.

// MARK: - Apps

@MainActor
final class AppsModel: ObservableObject {
    @Published var apps: [GuestAgent.GuestApp] = []
    @Published var loading = false
    @Published var error: String?

    let agent: GuestAgent

    init(agent: GuestAgent) { self.agent = agent }

    func reload() {
        guard !loading else { return }
        loading = true
        error = nil
        Task {
            let list = await agent.listApps()
            self.apps = list
            if !agent.hasShell {
                self.error = "The guest doesn\u{2019}t have shell tools. Jailbreak it to see the full app list."
            } else if list.isEmpty {
                self.error = "No apps in /Applications."
            }
            self.loading = false
        }
    }

    func launch(_ app: GuestAgent.GuestApp) async {
        if app.bundleID.isEmpty {
            self.error = "This app has no bundle id; Light Touch can't launch it by name."
            return
        }
        _ = await agent.launchApp(bundleID: app.bundleID)
    }

    func delete(_ app: GuestAgent.GuestApp) async {
        _ = await agent.removeApp(at: app.path)
        reload()
    }
}

struct AppsBrowserView: View {
    @StateObject private var model: AppsModel
    let onDismiss: () -> Void

    init(agent: GuestAgent, onDismiss: @escaping () -> Void) {
        _model = StateObject(wrappedValue: AppsModel(agent: agent))
        self.onDismiss = onDismiss
    }

    var body: some View {
        NavigationView {
            ZStack {
                LTBackground()
                content
            }
            .navigationTitle("Apps on the Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }.foregroundStyle(Theme.accent)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { model.reload() }
    }

    @ViewBuilder private var content: some View {
        if model.loading && model.apps.isEmpty {
            VStack(spacing: 10) {
                ProgressView().tint(Theme.accent)
                Text("Reading /Applications\u{2026}").font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.secondaryText)
            }
        } else if model.apps.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(Theme.secondaryText)
                Text(model.error ?? "No apps found.").font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.apps) { app in appRow(app) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private func appRow(_ app: GuestAgent.GuestApp) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "app.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Text(app.bundleID.isEmpty ? app.path : app.bundleID)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Menu {
                Button {
                    Task { await model.launch(app) }
                } label: { Label("Launch", systemImage: "arrow.up.forward.app") }
                    .disabled(app.bundleID.isEmpty)
                Button(role: .destructive) {
                    Task { await model.delete(app) }
                } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 20)).foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Files

@MainActor
final class FilesModel: ObservableObject {
    @Published var path = "/"
    @Published var entries: [GuestAgent.GuestFile] = []
    @Published var loading = false
    @Published var error: String?

    let agent: GuestAgent

    init(agent: GuestAgent) { self.agent = agent }

    func load(_ path: String) {
        self.path = path
        loading = true
        error = nil
        Task {
            let list = await agent.listDirectory(path)
            entries = list
            if !agent.hasShell {
                error = "The guest doesn\u{2019}t have shell tools. Jailbreak it to browse its filesystem."
            } else if list.isEmpty {
                error = "Empty folder, or the agent couldn\u{2019}t read it."
            }
            loading = false
        }
    }

    func parent() {
        guard path != "/" else { return }
        let url = URL(fileURLWithPath: path)
        load(url.deletingLastPathComponent().path)
    }

    func open(_ entry: GuestAgent.GuestFile) {
        guard entry.isDirectory else { return }
        let next = (path as NSString).appendingPathComponent(entry.name)
        load(next)
    }

    func delete(_ entry: GuestAgent.GuestFile) async {
        let target = (path as NSString).appendingPathComponent(entry.name)
        _ = entry.isDirectory ? await agent.spawn(argv: ["/bin/rm", "-rf", target]) : nil
        if !entry.isDirectory { _ = await agent.unlink(path: target) }
        load(path)
    }
}

struct FilesBrowserView: View {
    @StateObject private var model: FilesModel
    let onDismiss: () -> Void

    init(agent: GuestAgent, onDismiss: @escaping () -> Void) {
        _model = StateObject(wrappedValue: FilesModel(agent: agent))
        self.onDismiss = onDismiss
    }

    var body: some View {
        NavigationView {
            ZStack {
                LTBackground()
                VStack(spacing: 0) {
                    pathBar
                    content
                }
            }
            .navigationTitle("Files on the Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }.foregroundStyle(Theme.accent)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.load(model.path) } label: { Image(systemName: "arrow.clockwise") }
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { model.load("/") }
    }

    private var pathBar: some View {
        HStack(spacing: 10) {
            Button { model.parent() } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.path == "/" ? Theme.tertiaryText : Theme.accent)
                    .padding(8).background(Color.white.opacity(0.08), in: Circle())
            }
            .disabled(model.path == "/")
            Text(model.path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1).truncationMode(.head)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if model.loading && model.entries.isEmpty {
            Spacer()
            ProgressView().tint(Theme.accent)
            Spacer()
        } else if model.entries.isEmpty {
            Spacer()
            Text(model.error ?? "Empty.").font(.system(size: 13, design: .rounded))
                .foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center).padding(.horizontal, 24)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.entries) { entry in entryRow(entry) }
                }
                .padding(.horizontal, 16).padding(.bottom, 20)
            }
        }
    }

    private func entryRow(_ entry: GuestAgent.GuestFile) -> some View {
        Button { model.open(entry) } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(entry.isDirectory ? Theme.accent : Theme.secondaryText)
                    .frame(width: 22)
                Text(entry.name).font(.system(size: 13, design: .rounded)).foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if !entry.isDirectory && entry.size > 0 {
                    Text(Transfer.format(entry.size))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                }
                if entry.isDirectory {
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await model.delete(entry) }
            } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

// MARK: - Help

struct HelpView: View {
    let onDismiss: () -> Void
    var body: some View {
        NavigationView {
            ZStack {
                LTBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        section("JIT", symbol: "bolt.fill",
                            "Light Touch runs the guest through a JIT translator. Enable it first with StikDebug "
                            + "(script universal.js) or in LiveContainer (Launch with JIT). Without it the app falls back to "
                            + "the interpreter, which is many times slower.")
                        section("Add a device", symbol: "plus.circle",
                            "Add Device downloads the Mac release once (about 390 MB) and takes the boot ROMs and the "
                            + "ready-made iPod touch out of it. From there you can either boot that iPod or prepare a "
                            + "different version from its catalog IPSW, on the phone.")
                        section("Running", symbol: "iphone",
                            "The emulator shows the device's screen. Tap the home circle to go home, the power icon to "
                            + "wake or sleep, and the \u{2026} menu for extra actions. iPhone volume buttons raise and lower "
                            + "the guest's volume; the hardware keyboard, if you have one, types into the focused field.")
                        section("Views", symbol: "square.on.square",
                            "Three ways to look at the device: with the device around the screen, a plain screen on a dark "
                            + "stage, or full-screen with only the home button (tap the \u{22EF} in the corner to bring back "
                            + "the rest). Switch in the \u{2026} menu.")
                        section("Apps", symbol: "bag",
                            "Legacy Store lists apps that run on this device and installs them. Apps on the device shows what "
                            + "is installed and can launch or remove them. Installing new apps from an IPA works best on a "
                            + "jailbroken device for now.")
                        section("Save & quit", symbol: "tray.and.arrow.down",
                            "The emulator can save its full state before closing; the next launch restores it in seconds. "
                            + "If the device uses live GL state (the home screen), save may refuse\u{2014}go into an app first.")
                        section("Known limits", symbol: "exclamationmark.triangle",
                            "Preparing iOS 4 or iPad firmware needs a helper process iOS can\u{2019}t start; those devices "
                            + "stay Mac-only. The USB install path for IPAs is still a probe\u{2014}on this phone they go in "
                            + "through the guest agent.")
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }.foregroundStyle(Theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func section(_ title: String, symbol: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(body)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Carrier editor (sends via the agent's write-prefs, where it works)

struct CarrierEditor: View {
    let agent: GuestAgent?
    let onDismiss: () -> Void
    @State private var carrier = UserDefaults.standard.string(forKey: "carrier") ?? "LightTouch"
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        NavigationView {
            ZStack {
                LTBackground()
                VStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Theme.accentGlow).frame(width: 90, height: 90).blur(radius: 28)
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 36, weight: .thin))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(.top, 24)
                    Text("Carrier Name")
                        .font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text("Shown in the status bar of the device. Takes effect on the next reboot.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    TextField("", text: $carrier)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, 24)
                    Button {
                        apply()
                    } label: {
                        Text(busy ? "Saving\u{2026}" : "Save")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .disabled(busy || carrier.isEmpty)
                    if !message.isEmpty {
                        Text(message).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center).padding(.horizontal, 32)
                    }
                    Spacer()
                }
            }
            .navigationTitle("Carrier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }.foregroundStyle(Theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func apply() {
        UserDefaults.standard.set(carrier, forKey: "carrier")
        message = "Saved. The new carrier shows up after the next reboot."
        // If the agent has shell tools we also write com.apple.carrier.plist right now.
        if let agent, agent.hasShell {
            busy = true
            Task {
                let plist = ["carrierName": carrier] as NSDictionary
                let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
                if let data {
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("carrier.plist")
                    try? data.write(to: tmp)
                    _ = await agent.putFile(
                        localURL: tmp,
                        guestPath: "/var/mobile/Library/Preferences/com.apple.carrier.plist")
                    try? FileManager.default.removeItem(at: tmp)
                    message = "Saved and uploaded. The status bar updates after the next reboot."
                }
                busy = false
            }
        }
    }
}
