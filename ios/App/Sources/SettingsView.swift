import SwiftUI

/// Everything that used to clutter the in-session menus, in one place.
///
/// The rule for what lives here: anything you set once and forget. Actions — Home, rotate, paste, power — stay on
/// the controls where you need them in the moment.
struct DeviceSettingsView: View {
    let device: DeviceFolder
    let details: DeviceFolder.Details
    @ObservedObject var controls: DeviceControls
    let usb: USBSession?
    let onProbeUSB: () -> Void
    let onShowHelp: () -> Void
    let onDismiss: () -> Void

    @AppStorage("viewMode") private var viewModeRaw = ViewMode.bezel.rawValue
    @AppStorage("startupTone") private var startupTone = true
    @AppStorage("keepState") private var keepState = true
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("passBattery") private var passBattery = true
    @AppStorage("reportCharger") private var reportCharger = true
    @AppStorage("mirrorVibration") private var mirrorVibration = true
    @AppStorage("passMotion") private var passMotion = false
    @AppStorage("cellularModem") private var cellularModem = true
    @AppStorage("enableUSB") private var enableUSB = false
    @AppStorage("netRestricted") private var netRestricted = false
    @AppStorage("netLAN") private var netLAN = false
    @AppStorage("wifiNetwork") private var wifiNetwork = false
    @AppStorage("debugPort") private var debugPort = false
    @AppStorage("rawKeyboard") private var rawKeyboard = true
    @AppStorage("codeCacheMB") private var codeCacheMB = 512

    var body: some View {
        NavigationView {
            ZStack {
                LTBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        GlassCard("View", symbol: "rectangle.on.rectangle") {
                            Picker("", selection: $viewModeRaw) {
                                ForEach(ViewMode.allCases, id: \.self) { mode in
                                    Text(mode.title).tag(mode.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            toggle("Startup tone", "The chime when a device starts.", isOn: $startupTone)
                            toggle(
                                "Survive closing the app",
                                "Saves the device each time Light Touch goes to the background, so swiping it away doesn\u{2019}t lose what was running. Devices drawing with hardware graphics can\u{2019}t be saved yet; they get their storage flushed instead, so they always start again cleanly.",
                                isOn: $keepState)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Appearance")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.primaryText)
                                Picker("", selection: $appearance) {
                                    Text("System").tag("system")
                                    Text("Light").tag("light")
                                    Text("Dark").tag("dark")
                                }
                                .pickerStyle(.segmented)
                                Text("The device's own screen stays dark either way.")
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }

                        GlassCard("This phone stands in for", symbol: "iphone.radiowaves.left.and.right") {
                            toggle(
                                "Battery", "The device's status bar shows this phone's battery.",
                                isOn: $passBattery)
                            toggle(
                                "Charger", "Report a plugged-in charger, which also stops the device idle-sleeping.",
                                isOn: $reportCharger, onChange: { _ in controls.applyPowerState() })
                            toggle(
                                "Vibration", "When the device buzzes, this phone buzzes.",
                                isOn: $mirrorVibration)
                            toggle(
                                "Tilt and compass",
                                "Tilting this phone tilts the device, and its compass follows yours.",
                                isOn: $passMotion, onChange: { controls.setMotion($0) })
                        }

                        GlassCard("Network", symbol: "network") {
                            toggle(
                                "Wi-Fi", "Gives the device a Wi-Fi card on this phone\u{2019}s internet connection. Plain web pages and most app servers work; sites that need modern encryption don\u{2019}t (old iOS can\u{2019}t speak it). Takes effect on the next boot.",
                                isOn: $wifiNetwork)
                            toggle(
                                "Restricted", "The device reaches nothing but this app's own services.",
                                isOn: $netRestricted,
                                onChange: { _ in controls.setNetwork(restricted: netRestricted, lanAllowed: netLAN) })
                            toggle(
                                "See this network", "Let the device reach other machines on your Wi-Fi.",
                                isOn: $netLAN,
                                onChange: { _ in controls.setNetwork(restricted: netRestricted, lanAllowed: netLAN) })
                        }

                        GlassCard("Hardware", symbol: "cpu") {
                            if details.isPhone {
                                toggle(
                                    "Cellular modem",
                                    "The fake modem that makes the carrier, calls and texts work. Takes effect on the next boot.",
                                    isOn: $cellularModem)
                            }
                            toggle(
                                "Hardware keyboard keys",
                                "On the iPad, iPhone 4 and iPod touch 4G, a keyboard connected to this phone is the device\u{2019}s own USB keyboard (arrows, Escape and all). Elsewhere, keys are typed into the focused text field.",
                                isOn: $rawKeyboard)
                            toggle(
                                "Debug port",
                                "QEMU\u{2019}s gdbstub on port 1234, for lldb or gdb on another computer on this Wi-Fi (gdb-remote <this phone\u{2019}s IP>:1234). Anyone on the network can reach it while it\u{2019}s on. Takes effect on the next boot.",
                                isOn: $debugPort)
                            toggle(
                                "USB bridge",
                                "Lets this app talk to the device the way a computer would. Experimental; takes effect on the next boot.",
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
                        }

                        GlassCard("Speed", symbol: "speedometer") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Translation cache: \(codeCacheMB) MB")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.primaryText)
                                Text("How much translated code the emulator keeps. More is faster and uses more memory. Takes effect on the next boot.")
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundStyle(Theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                Picker("", selection: $codeCacheMB) {
                                    Text("128").tag(128)
                                    Text("256").tag(256)
                                    Text("512").tag(512)
                                    Text("1024").tag(1024)
                                }
                                .pickerStyle(.segmented)
                            }
                        }

                        GlassCard("About this device", symbol: "info.circle") {
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

                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }.foregroundStyle(Theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Pieces

    private func toggle(
        _ title: String, _ note: String, isOn: Binding<Bool>, onChange: ((Bool) -> Void)? = nil
    ) -> some View {
        Toggle(isOn: Binding(get: { isOn.wrappedValue }, set: { value in
            isOn.wrappedValue = value
            onChange?(value)
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.primaryText)
                Text(note)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Theme.accent)
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
