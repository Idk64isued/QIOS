import SwiftUI

/// Everything that used to clutter the in-session menus, in one place.
///
/// The rule for what lives here: anything you set once and forget. Actions — Home, rotate, paste, power — stay on
/// the controls where you need them in the moment.
///
/// From the device list (no device running) it shows the same settings for every device: `device` and `controls` are
/// nil, nothing is applied live, and each setting takes effect when a device next starts.
///
/// Every switch used to carry its full explanation underneath it — a paragraph each, twenty-odd of them, so the page
/// was a wall of small grey text you had to read through to find the one line you came for. The explanations are all
/// still here, a tap away behind each row's ⓘ; what you see at rest is the switch, its name, and a few words. The
/// settings most people never touch (the boot log, the debug port, the USB bridge, the translation cache) start
/// collapsed under Advanced.
struct DeviceSettingsView: View {
    var device: DeviceFolder?
    var details = DeviceFolder.Details()
    var controls: DeviceControls?
    var usb: USBSession?
    var onProbeUSB: () -> Void = {}
    var onShowHelp: () -> Void = {}
    let onDismiss: () -> Void

    @AppStorage("viewMode") private var viewModeRaw = ViewMode.bezel.rawValue
    @AppStorage("startupTone") private var startupTone = true
    @AppStorage("sharpPixels") private var sharpPixels = true
    @AppStorage("coolMode") private var coolMode = false
    @AppStorage("autoCool") private var autoCool = true
    @AppStorage("smoothSound") private var smoothSound = false
    @AppStorage("keepState") private var keepState = true
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("homeInterface") private var homeInterface = HomeInterface.classic.rawValue
    @AppStorage("passBattery") private var passBattery = true
    @AppStorage("reportCharger") private var reportCharger = true
    @AppStorage("mirrorVibration") private var mirrorVibration = true
    @AppStorage("passMotion") private var passMotion = false
    @AppStorage("tiltSensitivity") private var tiltSensitivity = 1.0
    @AppStorage("sixSettings") private var sixLook = true
    @AppStorage("passLocation") private var passLocation = true
    @AppStorage("passVolumeButtons") private var passVolumeButtons = false
    @AppStorage("cellularModem") private var cellularModem = true
    @AppStorage("enableUSB") private var enableUSB = false
    @AppStorage("netRestricted") private var netRestricted = false
    @AppStorage("netLAN") private var netLAN = false
    @AppStorage("wifiNetwork") private var wifiNetwork = false
    @AppStorage("debugPort") private var debugPort = false
    @AppStorage("verboseBoot") private var verboseBoot = false
    @AppStorage("kernelConsole") private var kernelConsole = false
    @AppStorage("rawKeyboard") private var rawKeyboard = true
    @AppStorage("microphone") private var microphone = true
    @AppStorage("glRenderer") private var glRenderer = "angle"
    @AppStorage("codeCacheMB") private var codeCacheMB = 512
    @AppStorage("glCapture") private var glCapture = false
    @AppStorage("pvrtcNative") private var pvrtcNative = false

    /// Rows whose ⓘ has been tapped, by title.
    @State private var expanded: Set<String> = []
    @State private var showAdvanced = false

    var body: some View {
        if sixLook {
            // Settings ▸ iOS 6 look: the same page the way iOS 6 drew its own -- pinstripes, a glossy bar, grouped cells.
            VStack(spacing: 0) {
                SixNavBar(title: device == nil ? "All Devices" : "Settings", right: ("Done", onDismiss))
                ScrollView { cards }
            }
            .background(Six.Pinstripes().ignoresSafeArea())
        } else {
            NavigationView {
                ZStack {
                    LTBackground()
                    ScrollView { cards }
                }
                .navigationTitle(device == nil ? "Settings for every device" : "Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onDismiss() }.foregroundStyle(Theme.accent)
                    }
                }
            }
            .navigationViewStyle(.stack)
        }
    }

    /// Every card on the page, in either look.
    private var cards: some View {
        VStack(spacing: 16) {
            SettingsCard("View", symbol: "rectangle.on.rectangle") {
                Picker("", selection: $viewModeRaw) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                segment("Appearance", selection: $appearance,
                        options: [("System", "system"), ("Light", "light"), ("Dark", "dark")],
                        note: "The device\u{2019}s own screen stays dark either way.")
                segment("Home screen", selection: $homeInterface,
                        options: [("iOS 6 list", HomeInterface.classic.rawValue),
                                  ("Glass", HomeInterface.modern.rawValue)],
                        note: (HomeInterface(rawValue: homeInterface) ?? .classic).detail)
                toggle("iOS 6 look", "This page drawn the way iOS 6 drew Settings.", isOn: $sixLook)
                toggle("Startup tone", "Chime when a device starts.", isOn: $startupTone)
                toggle("Sharp pixels", "Crisp squares, not smoothed.",
                       detail: "The device\u{2019}s pixels scaled up as crisp squares. Off smooths them instead.",
                       isOn: $sharpPixels)
                toggle("Survive closing the app", "Keep what was running.",
                       detail: "Saves the device each time Halcyon goes to the background, so swiping it away doesn\u{2019}t lose what was running. Devices drawing with hardware graphics can\u{2019}t be saved yet; they get their storage flushed instead, so they always start again cleanly.",
                       isOn: $keepState)
            }

            SettingsCard("This phone stands in for", symbol: "iphone.radiowaves.left.and.right") {
                toggle("Battery", "The device shows this phone\u{2019}s charge.", isOn: $passBattery)
                toggle("Charger", "Report a charger plugged in.",
                       detail: "Report a plugged-in charger, which also stops the device idle-sleeping.",
                       isOn: $reportCharger, onChange: { _ in controls?.applyPowerState() })
                toggle("Vibration", "When the device buzzes, this phone buzzes.",
                       isOn: $mirrorVibration)
                toggle("Tilt and compass", "Tilting this phone tilts the device.",
                       detail: "Tilting this phone tilts the device, and its compass follows yours.",
                       isOn: $passMotion, onChange: { controls?.setMotion($0) })
                if passMotion {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tilt sensitivity")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.primaryText)
                        note("How far the device tilts for each degree this phone does, from the way you were holding it when tilt came on. 100% is exactly this phone\u{2019}s tilt; lower is gentler, for games like Super Monkey Ball. Turn tilt off and on to re-centre.")
                        Picker("", selection: $tiltSensitivity) {
                            Text("40%").tag(0.4)
                            Text("60%").tag(0.6)
                            Text("80%").tag(0.8)
                            Text("100%").tag(1.0)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                toggle("Volume buttons", "Send presses to the device instead.",
                       detail: "On, this phone\u{2019}s volume buttons work the device\u{2019}s volume and this phone\u{2019}s own volume stays where it is — which also means you can\u{2019}t turn the sound down while a device is open, and the device throws its volume overlay up over whatever is running. Off (the default), the buttons belong to this phone.",
                       isOn: $passVolumeButtons)
                if device == nil || details.board?.hasGPS == true
                    || (Int((details.version ?? "").prefix { $0 != "." }) ?? 0) >= 5
                {
                    toggle("Location", "The device knows where you are.",
                           detail: "This phone\u{2019}s location becomes the device\u{2019}s, so Maps and location apps find you. On the iPhone 3GS it arrives through the GPS receiver in its modem. On iOS 5 and 6 (the iPhone 4) it goes in the way Xcode sets a location on a real iPhone, through iOS\u{2019}s own location simulation, updated whenever you\u{2019}ve moved 25 m. Older versions on other boards have neither, so Location Services there finds nothing.",
                           isOn: $passLocation, onChange: { controls?.setLocation($0) })
                }
            }

            SettingsCard("Network", symbol: "network") {
                toggle("Wi-Fi", "Gives the device a Wi-Fi card. Next boot.",
                       detail: "Gives the device a Wi-Fi card on this phone\u{2019}s internet connection. Plain web pages, Cydia\u{2019}s repositories and most app servers work; sites that need modern encryption don\u{2019}t (old iOS can\u{2019}t speak it). Takes effect on the next boot.",
                       isOn: $wifiNetwork)
                toggle("Restricted", "Nothing but this app\u{2019}s own services.",
                       isOn: $netRestricted,
                       onChange: { _ in controls?.setNetwork(restricted: netRestricted, lanAllowed: netLAN) })
                toggle("See this network", "Reach other machines on your Wi-Fi.",
                       isOn: $netLAN,
                       onChange: { _ in controls?.setNetwork(restricted: netRestricted, lanAllowed: netLAN) })
            }

            SettingsCard("Hardware", symbol: "cpu") {
                if device == nil || details.isPhone {
                    toggle("Cellular modem", "Carrier, calls and texts. Next boot.",
                           detail: "The fake modem that makes the carrier, calls and texts work. Takes effect on the next boot.",
                           isOn: $cellularModem)
                }
                if device == nil || Microphone.supported(board: details.board?.rawValue) {
                    toggle("Microphone", "The device hears through this phone.",
                           detail: "The device hears through this phone\u{2019}s microphone, which turns on only while something on the device records (Voice Memos, a voice app) and off right after.",
                           isOn: $microphone)
                }
                toggle("Hardware keyboard keys", "A connected keyboard types into the device.",
                       detail: "On the iPad, iPhone 4 and iPod touch 4G, a keyboard connected to this phone becomes the device\u{2019}s own USB keyboard from its first key (arrows, Escape and all); while it is, iOS 4 hides the on-screen keyboard. Elsewhere, keys are typed into the focused text field.",
                       isOn: $rawKeyboard)
            }

            SettingsCard("Graphics", symbol: "cube.transparent") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $glRenderer) {
                        Text("ANGLE").tag("angle")
                        Text("iPhone GL").tag("es3")
                        Text("Classic").tag("classic")
                    }
                    .pickerStyle(.segmented)
                    .disabled(!QemuRuntime.angleBundled)
                    note(QemuRuntime.angleBundled
                         ? "ANGLE is the default. Takes effect on the next boot."
                         : "This build has no ANGLE, so the device draws with the iPhone\u{2019}s own GL.")
                    if QemuRuntime.angleBundled {
                        moreButton("Graphics")
                        if expanded.contains("Graphics") {
                            note("ANGLE draws the device\u{2019}s graphics on Metal, newer devices\u{2019} shaders included. iPhone GL is a test: the same, on the phone\u{2019}s own OpenGL ES 3.0. Classic is the first renderer (OpenGL ES 1.1, no shaders: the iPhone 3GS, iPhone 4, iPod touch 3G/4G and iPad draw in software there); it has the iPod touch\u{2019}s texture fixes, so try it if something draws wrong. A newer device prepared under Classic keeps software drawing until it\u{2019}s prepared again.")
                        }
                    }
                }
                toggle("Cool mode", "30 frames a second. Next boot.",
                       detail: "Runs the device\u{2019}s screen at 30 frames a second instead of 60: about half the drawing work, so the phone stays cooler and its battery lasts longer. Games that count frames instead of time run slower. Takes effect the next time the device starts.",
                       isOn: $coolMode)
                toggle("Cool down automatically", "Drop to 30 when this phone gets hot.",
                       detail: "When this phone gets critically hot, the device\u{2019}s screen drops to 30 frames a second until it has cooled, then goes back to 60. Takes effect at once. For 30 all the time, use Cool mode.",
                       isOn: $autoCool)
                toggle("Smooth sound", "Never cut out; drift behind instead.",
                       detail: "Off keeps the device\u{2019}s sound in step with its screen, with a moment of silence when the emulator falls behind. On plays it a touch slower instead, so it never cuts out but drifts behind the picture. Takes effect the next time the device starts.",
                       isOn: $smoothSound)
            }

            SettingsCard("Advanced", symbol: "wrench.and.screwdriver") {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showAdvanced.toggle() }
                } label: {
                    HStack {
                        Text(showAdvanced ? "Hide" : "Graphics capture, boot log, debug port, USB")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.accent)
                        Spacer()
                        Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .buttonStyle(.plain)

                if showAdvanced {
                    toggle("Graphics capture", "Snapshots of what games draw. Next boot.",
                           detail: "Every ten seconds, one frame of what a game draws is saved together with each hidden layer it drew first, and a list of that frame\u{2019}s draws goes into the log. The newest four go into the next report you share. It slows games down, so turn it off when you\u{2019}re done. Takes effect on the next boot.",
                           isOn: $glCapture)
                    toggle("Smaller textures", "Experimental. Halves texture memory. Next boot.",
                           detail: "Games of this era store their artwork compressed. Unpacking it, which is what normally happens, turns every piece into four bytes a pixel \u{2014} about eight times what it arrived as. That memory is most of why the phone gets hot and why things stutter.\n\nThis takes the best route your graphics mode allows. On the iPhone\u{2019}s own OpenGL ES (Settings \u{25B8} Graphics) the artwork is handed over still compressed, which saves the most by far. On the default mode, which claims to accept it and then draws it black, the artwork is unpacked as usual but kept at two bytes a pixel instead of four \u{2014} half the memory, asking nothing of the driver.\n\nIt is experimental. The half-size route can show mild banding on smooth gradients. The compressed route trusts your driver to draw the artwork exactly as the unpacker would, so a game may show wrong colours, blocky edges, or look grainy in the distance. If a game looks wrong, turn this off and reopen it. Takes effect on the next boot.",
                           isOn: $pvrtcNative)
                    toggle("Verbose boot", "Kernel messages instead of the logo.",
                           detail: "The kernel\u{2019}s messages scroll on the device\u{2019}s screen instead of the Apple logo, so a slow or stuck boot shows where it is. Takes effect on the next boot.",
                           isOn: $verboseBoot)
                    toggle("Kernel console", "Kernel log to the serial port.",
                           detail: "The kernel writes its log to the device\u{2019}s serial port, which Console \u{203A} Device shows live and reports include. Takes effect on the next boot.",
                           isOn: $kernelConsole)
                    toggle("Debug port", "gdbstub on 1234. Next boot.",
                           detail: "QEMU\u{2019}s gdbstub on port 1234, for lldb or gdb on another computer on this Wi-Fi (gdb-remote <this phone\u{2019}s IP>:1234). Anyone on the network can reach it while it\u{2019}s on. Takes effect on the next boot.",
                           isOn: $debugPort)
                    toggle("USB bridge", "Talk to the device like a computer.",
                           detail: "Lets this app talk to the device the way a computer would. Experimental; takes effect on the next boot.",
                           isOn: $enableUSB)
                    if let usb {
                        HStack {
                            Text("USB: " + usb.state.text)
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Theme.secondaryText)
                            Spacer()
                            Button("Ask the device", action: onProbeUSB)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Translation cache: \(codeCacheMB) MB")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.primaryText)
                        note("How much translated code the emulator keeps. More is faster and uses more memory. Takes effect on the next boot.")
                        Picker("", selection: $codeCacheMB) {
                            Text("128").tag(128)
                            Text("256").tag(256)
                            Text("512").tag(512)
                            Text("1024").tag(1024)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }

            if let device {
                SettingsCard("About this device", symbol: "info.circle") {
                    row("Name", device.name)
                    row("System", details.version.map { ($0.hasPrefix("4") ? "iOS " : "iPhone OS ") + $0 } ?? "—")
                    row("Board", details.board?.rawValue ?? "—")
                    if let build = details.build { row("Build", build) }
                    Button(action: onShowHelp) {
                        Label("Help", systemImage: "questionmark.circle")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    // MARK: - Pieces

    /// A switch: its name, a few words, and — where there is more to say — an ⓘ that opens the rest.
    private func toggle(
        _ title: String, _ short: String, detail: String? = nil, isOn: Binding<Bool>,
        onChange: ((Bool) -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { isOn.wrappedValue }, set: { value in
                isOn.wrappedValue = value
                onChange?(value)
            })) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.primaryText)
                        Text(short)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(2)
                    }
                    if detail != nil { infoButton(title) }
                }
            }
            .toggleStyle(SettingsToggleStyle(six: sixLook))
            if let detail, expanded.contains(title) { note(detail) }
        }
    }

    /// The ⓘ beside a switch's name.
    private func infoButton(_ title: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if expanded.contains(title) { expanded.remove(title) } else { expanded.insert(title) }
            }
        } label: {
            Image(systemName: expanded.contains(title) ? "info.circle.fill" : "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("About \(title)"))
    }

    /// The same, as a line of its own, for a picker rather than a switch.
    private func moreButton(_ title: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if expanded.contains(title) { expanded.remove(title) } else { expanded.insert(title) }
            }
        } label: {
            Text(expanded.contains(title) ? "Less" : "What these mean")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
    }

    private func segment(
        _ title: String, selection: Binding<String>, options: [(String, String)], note text: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.primaryText)
            Picker("", selection: selection) {
                ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
            }
            .pickerStyle(.segmented)
            note(text)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.primaryText)
        }
    }
}

/// A card on the Settings page: Halcyon's frosted glass, or (Settings ▸ iOS 6 look) an iOS 6 grouped section --
/// an embossed header over one white rounded cell.
struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content
    @AppStorage("sixSettings") private var six = true

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.content = content()
    }

    var body: some View {
        if six {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(Six.font(17, bold: true))
                    .foregroundStyle(Six.header)
                    .shadow(color: Six.headerShadow, radius: 0, y: 1)
                    .padding(.horizontal, 10)
                VStack(alignment: .leading, spacing: 12) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Six.cell)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Six.cellBorder, lineWidth: 1))
                    .shadow(color: Six.headerShadow.opacity(0.6), radius: 0, y: 1)
            }
        } else {
            GlassCard(title, symbol: symbol) { content }
        }
    }
}

/// Settings' switches: iOS 6's ON/OFF capsule in the iOS 6 look, the system switch otherwise.
struct SettingsToggleStyle: ToggleStyle {
    let six: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if six {
            HStack(spacing: 8) {
                configuration.label
                Spacer(minLength: 6)
                SixSwitch(isOn: configuration.$isOn)
            }
        } else {
            Toggle(configuration).tint(Theme.accent)
        }
    }
}
