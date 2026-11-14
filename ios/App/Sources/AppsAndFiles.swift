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

// MARK: - Carrier, calls and messages (the emulated baseband)

/// The iPhones carry a fake cellular modem the emulator drives by property name, so the carrier in the status bar,
/// the signal, an incoming call and an incoming text are all real to the guest rather than a picture of one. An
/// iPod touch has no modem, which is why this screen only appears for a phone.
struct CarrierEditor: View {
    let agent: GuestAgent?
    let modem: ModemController
    let onDismiss: () -> Void

    @State private var carrier = UserDefaults.standard.string(forKey: "carrier") ?? "Light Touch"
    @State private var bars = UserDefaults.standard.object(forKey: "carrierBars") as? Int ?? 4
    @State private var callNumber = UserDefaults.standard.string(forKey: "callNumber") ?? "+15551234567"
    @State private var textNumber = UserDefaults.standard.string(forKey: "textNumber") ?? "+15551234567"
    @State private var textBody = "Sent from the other side."
    @State private var message = ""
    @State private var busy = false
    @StateObject private var keyboard = KeyboardInset()

    var body: some View {
        NavigationView {
            ZStack {
                LTBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        header
                        networkCard
                        if modem.isAvailable {
                            callCard
                            textCard
                        } else {
                            unavailableCard
                        }
                        if !message.isEmpty {
                            Text(message)
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Theme.secondaryText)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        Spacer(minLength: 24)
                    }
                    .padding(.top, 12)
                    .padding(.bottom, keyboard.height)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Carrier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }.foregroundStyle(Theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { modem.startPolling() }
        .onDisappear { modem.stopPolling() }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Theme.accentGlow).frame(width: 80, height: 80).blur(radius: 26)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 32, weight: .thin))
                    .foregroundStyle(.white.opacity(0.9))
            }
            Text(modem.status?.summary ?? "No modem on this device")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var networkCard: some View {
        card("NETWORK", icon: "dot.radiowaves.up.forward") {
            field("Name in the status bar", text: $carrier)
            HStack {
                Text("Signal")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                ForEach(1...5, id: \.self) { step in
                    Button {
                        bars = step
                        UserDefaults.standard.set(step, forKey: "carrierBars")
                        if modem.isAvailable { _ = modem.setSignal(bars: step) }
                    } label: {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(step <= bars ? Color.white.opacity(0.9) : Color.white.opacity(0.16))
                            .frame(width: 7, height: CGFloat(6 + step * 3))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
            Button {
                apply()
            } label: {
                Text(busy ? "Applying\u{2026}" : "Apply")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(busy || carrier.isEmpty)
            .padding(.top, 4)
        }
    }

    private var callCard: some View {
        card("CALLING", icon: "phone.fill") {
            field("Calling from", text: $callNumber, keyboard: .phonePad)
            HStack(spacing: 10) {
                action("Ring the device", icon: "phone.arrow.down.left", tint: Theme.accent) {
                    UserDefaults.standard.set(callNumber, forKey: "callNumber")
                    message = modem.call(from: callNumber)
                }
                action("Hang up", icon: "phone.down.fill", tint: Color.white.opacity(0.12)) {
                    message = modem.hangUpRemotely()
                }
            }
            action("Answer from the other end", icon: "phone.fill", tint: Color.white.opacity(0.12)) {
                message = modem.answerRemotely()
            }
            Text("The device has to be on the network before it can ring. Answer on the device itself, or use the button above to have the caller pick up.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var textCard: some View {
        card("TEXTING", icon: "message.fill") {
            field("From", text: $textNumber, keyboard: .phonePad)
            field("Message", text: $textBody)
            action("Send to the device", icon: "paperplane.fill", tint: Theme.accent) {
                UserDefaults.standard.set(textNumber, forKey: "textNumber")
                message = modem.text(from: textNumber, body: textBody)
            }
        }
    }

    private var unavailableCard: some View {
        card("CALLS AND MESSAGES", icon: "exclamationmark.circle") {
            Text("This device has no modem, so calls and texts aren\u{2019}t available. The name above is still written to the device for its status bar.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: Building blocks

    @ViewBuilder
    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
            content()
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 18)
    }

    private func field(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(.white)
                .padding(10)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func action(_ title: String, icon: String, tint: Color, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(tint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!modem.isAvailable)
    }

    // MARK: Applying the carrier

    /// Sets it on the modem now (the status bar changes within a second) and, where the agent can write files,
    /// also leaves it in the device's preferences so it survives a reboot.
    private func apply() {
        UserDefaults.standard.set(carrier, forKey: "carrier")
        if modem.isAvailable, modem.setCarrier(carrier) {
            _ = modem.setSignal(bars: bars)
            _ = modem.setRegistered(true)
            modem.refresh()
            message = "Applied. The status bar updates in a moment."
        } else {
            message = "Saved. The new carrier shows up after the next reboot."
        }
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
                }
                busy = false
            }
        }
    }
}

/// Lifts a scrolling form above the software keyboard.
@MainActor
final class KeyboardInset: ObservableObject {
    @Published var height: CGFloat = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            let screen = UIScreen.main.bounds.height
            let visible = max(0, screen - frame.origin.y)
            Task { @MainActor in self.height = visible }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.height = 0 }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
