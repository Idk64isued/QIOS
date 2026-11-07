// The Carrier panel: the fake cellular network of a running iPhone (M68, N88, N90), its calls and its SMS, and where
// a modem with a GPS receiver (the 3GS's) says the phone is.
// Network settings are the device's (EmulatorController.carrierSettings, applied at every boot); calls and SMS go
// straight to the modem (qemu-ios ios-baseband's actions), and its state is polled once a second while visible.

import Cocoa
import CoreLocation
import HostRuntime
import LightTouchCore
import MapKit
import SwiftUI

extension EmulatorController: CarrierBackend {}

struct CarrierPanel: View {
    @Bindable var model: CarrierPanelModel
    @State private var camera = MapCameraPosition.automatic
    @State private var macLocation = MacLocation()

    var body: some View {
        Form {
            Section {
                TextField("Carrier", text: $model.carrierName)
                LabeledContent("MCC / MNC") {
                    HStack {
                        TextField("MCC", text: $model.mcc, prompt: Text("001")).labelsHidden().frame(width: 56)
                        Text("/").foregroundStyle(.secondary)
                        TextField("MNC", text: $model.mnc, prompt: Text("01")).labelsHidden().frame(width: 56)
                        Button("Apply") { model.applyNetwork() }
                            .disabled(!model.networkEdited || !model.networkValid)
                    }
                }
                if model.applyingNetwork {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Applying…").foregroundStyle(.secondary)
                    }
                }
                Toggle(
                    "Registered",
                    isOn: Binding(get: { model.settings.registered }, set: { model.set(registered: $0) })
                )
                Toggle(
                    "SIM Present",
                    isOn: Binding(get: { model.settings.simPresent }, set: { model.set(simPresent: $0) })
                )
                LabeledContent("Signal") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(model.settings.bars) },
                                set: { model.set(bars: Int($0.rounded())) }
                            ),
                            in: 0...5,
                            step: 1
                        )
                        Text("\(model.settings.bars) bars").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Network")
            } footer: {
                Text("Signal indicator may take a moment to update.")
            }
            Section("Calls") {
                HStack {
                    TextField("Caller", text: $model.callNumber)
                    Button("Ring") { model.ring() }.disabled(!model.canRing)
                }
                HStack {
                    Button("Answer") { model.answer() }.disabled(!model.canAnswer)
                        .help("The other end picks up the call the phone is making")
                    Button("Hang Up") { model.hangUp() }.disabled(!model.canHangUp)
                        .help("The other end ends the call, ringing or connected")
                }
                LabeledContent(
                    "State",
                    value: model.callState.capitalized + (model.status?.emergencyCall == true ? " (Emergency)" : "")
                )
                LabeledContent(
                    "Last Dialed",
                    value: (model.status?.lastDialed).flatMap { $0.isEmpty ? nil : $0 } ?? "—"
                )
            }
            Section("SMS") {
                TextField("From", text: $model.smsNumber)
                HStack(alignment: .bottom) {
                    TextField("Message", text: $model.smsText, prompt: Text("Type your SMS…"), axis: .vertical)
                        .labelsHidden().lineLimit(3...6).onSubmit { model.sendSMS() }
                    Button("Send") { model.sendSMS() }.disabled(!model.smsValid)
                }
                if model.sent.isEmpty {
                    Text("Messages the phone sends appear here.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.sent) { sms in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("To \(sms.number)").font(.caption).foregroundStyle(.secondary)
                            Text(sms.text).textSelection(.enabled)
                        }
                    }
                }
            }
            if model.status?.hasGPS == true {
                Section("Location") {
                    MapReader { map in
                        Map(position: $camera) { Marker("GPS", coordinate: model.reportedLocation.coordinate) }
                            .frame(height: 180)
                            .onTapGesture(coordinateSpace: .local) { point in
                                if let c = map.convert(point, from: .local) {
                                    model.set(location: GPSLocation(latitude: c.latitude, longitude: c.longitude))
                                }
                            }
                    }
                    .onAppear { center(on: model.settings.location) }
                    .onChange(of: model.settings.location) { center(on: model.settings.location) }
                    LabeledContent("Coordinates") {
                        HStack {
                            TextField("Latitude", text: $model.latitude).labelsHidden()
                            TextField("Longitude", text: $model.longitude).labelsHidden()
                            Button("Set") { model.applyLocation() }.disabled(model.typedLocation == nil)
                        }
                    }
                    HStack {
                        Menu("Go To") {
                            Button("Apple Park") { model.set(location: .applePark) }
                            Button("This Mac’s Location") {
                                macLocation.request { location in
                                    guard let location else {
                                        return model.notice("This Mac’s location isn’t available.")
                                    }
                                    model.set(location: location)
                                }
                            }
                        }
                        .fixedSize()
                        Spacer()
                        Button(model.walking ? "Stop Walking" : "Walk") { model.toggleWalk() }
                            .help("Walk a circle 100 m across from here, at 1.4 m/s")
                    }
                }
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, idealWidth: 380, minHeight: 520)
        .task {
            // ~1 Hz while the panel is on screen; SwiftUI cancels it when the view goes away.
            while !Task.isCancelled {
                model.poll()
                try? await Task.sleep(for: .seconds(1))
            }
            if model.walking { model.toggleWalk() }  // the walk steps with the poll: it ends with it
        }
    }
}

extension CarrierPanel {
    fileprivate func center(on location: GPSLocation) {
        camera = .region(
            MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500)
        )
    }
}

extension GPSLocation {
    fileprivate var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// The Mac's own position, asked for only when the user picks it (Core Location prompts the first time).
@MainActor final class MacLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var done: ((GPSLocation?) -> Void)?

    /// `done` gets the position, or nil when Core Location has none to give (denied, no fix).
    func request(_ done: @escaping (GPSLocation?) -> Void) {
        self.done = done
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        MainActor.assumeIsolated {
            done?(GPSLocation(latitude: c.latitude, longitude: c.longitude))
            done = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            done?(nil)
            done = nil
        }
    }
}

/// A Carrier panel per running device: a utility panel that floats above the device window.
@MainActor final class CarrierWindowController: NSWindowController {
    let model: CarrierPanelModel
    init(emulator: EmulatorController) {
        model = CarrierPanelModel(backend: emulator)
        let hosting = NSHostingController(rootView: CarrierPanel(model: model))
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable, .resizable, .utilityWindow]
        panel.title = "Carrier — \(emulator.instance.name)"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.setFrameAutosaveName("CarrierPanel")
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

#if DEBUG
    @MainActor private final class PreviewBackend: CarrierBackend {
        var carrierSettings = CarrierSettings()
        func setCarrierSettings(_ settings: CarrierSettings) -> Bool {
            carrierSettings = settings
            return true
        }
        func modem(_ property: String, _ value: String, done: @escaping @MainActor (Bool) -> Void) { done(true) }
        func modemStatus(_ done: @escaping @MainActor (ModemStatus?) -> Void) {
            done(
                ModemStatus(
                    json:
                        #"{"carrier": "Light Touch", "mcc-mnc": "00101", "call-state": "incoming", "last-dialed": "15555550123", "#
                        + #""last-mo-sms": "15555550100|On my way", "registered": true, "sim-present": true, "signal-dbm": -63, "mo-sms-count": 1}"#
                )
            )
        }
    }

    #Preview("Carrier") {
        CarrierPanel(model: CarrierPanelModel(backend: PreviewBackend()))
            .frame(width: 380, height: 640)
    }
#endif
