import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Add Device as iOS 6's Setup Assistant (the iOS 6 interfaces, Settings › Home Screen): slide to set up, choose a
/// device, choose its software, name it, watch it being set up, and "Welcome to your iPhone". The same plan and the
/// same DeviceCreator as AddDeviceView, page for page; only the look and the order of questions differ.
struct SetupAssistantView: View {
    let onClose: (DeviceFolder?, Bool) -> Void

    private enum Page: Int, Comparable {
        case hello, device, software, name, working
        static func < (a: Page, b: Page) -> Bool { a.rawValue < b.rawValue }
    }

    @StateObject private var creator = DeviceCreator()
    @State private var page: Page = .hello
    @State private var readyMade = false
    @State private var model = FirmwareCatalog.models.first ?? DeviceModel(board: "n72ap")
    @State private var firmware: CatalogFirmware?
    @State private var showExperimental = false
    @State private var name = ""
    @State private var skipSetup = false
    @State private var jailbreak = false
    @State private var softwareGraphics = false
    @State private var showIPSWPicker = false
    @State private var importing = false
    @State private var importNote = ""
    @State private var downloadingIPSW: CatalogFirmware?
    @State private var downloadFraction: Double = 0
    @State private var downloadMessage = ""
    @State private var forward = true

    var body: some View {
        ZStack {
            switch page {
            case .hello: hello.transition(.opacity)
            case .device: devicePage.transition(slide)
            case .software: softwarePage.transition(slide)
            case .name: namePage.transition(slide)
            case .working: workingPage.transition(slide)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: page)
        .interactiveDismissDisabled(page == .working && creator.running)
        .sheet(isPresented: $showIPSWPicker) {
            DocumentPickerView(types: [UTType(filenameExtension: "ipsw") ?? .data, .zip, .data]) { url in
                showIPSWPicker = false
                if let url { importIPSW(url) }
            }
        }
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: forward ? .trailing : .leading),
                    removal: .move(edge: forward ? .leading : .trailing))
    }

    private func go(_ next: Page) {
        forward = next > page
        page = next
    }

    private var plan: DevicePlan? {
        if readyMade { return DevicePlan(kind: .readyMade, name: "iPod touch") }
        guard let firmware else { return nil }
        return DevicePlan(kind: .firmware(firmware), name: "\(DeviceModel(board: firmware.board).shortName) \(firmware.version)")
    }

    // MARK: - Hello: slide to set up

    private var hello: some View {
        SetupHello(onSlide: { go(.device) }, onCancel: { onClose(nil, false) })
    }

    // MARK: - Choose a device

    private var devicePage: some View {
        SixScreen(title: "Device", left: ("Cancel", { onClose(nil, false) }), right: ("Next", { go(readyMade ? .name : .software) })) {
            SetupHeading(symbol: "iphone", title: "Choose a Device",
                         text: "Pick the iPhone or iPod touch to set up. The ready-made iPod touch starts in under a minute.")
            SixSection(header: "Quick Start") {
                SixRow(icon: AnyView(DeviceIconArt(model: DeviceModel(board: "n72ap")).scaleEffect(0.7).frame(width: 42, height: 42)),
                       title: "Ready-made iPod touch",
                       subtitle: readyMadeNote,
                       chevron: false, checked: readyMade) { readyMade = true }
            }
            SixSection(header: "From Firmware", footer: OnDevicePrep.available ? nil : "This build can\u{2019}t prepare firmware yet. You can still download IPSWs; use the ready-made iPod touch to get going.") {
                ForEach(Array(FirmwareCatalog.models.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { SixSeparator() }
                    SixRow(icon: AnyView(DeviceIconArt(model: item).scaleEffect(0.7).frame(width: 42, height: 42)),
                           title: item.name, subtitle: Self.modelNote(item),
                           chevron: false, checked: !readyMade && model == item) {
                        readyMade = false
                        if model != item { firmware = nil }
                        model = item
                    }
                }
            }
        }
    }

    private var readyMadeNote: String {
        let download = DevicePlan(kind: .readyMade, name: "").needsMacFiles
            ? "\(Transfer.format(MacFiles.approximateBytes)) download." : "No download needed."
        return "iPhone OS 3.1.3, already set up. " + download
    }

    static func modelNote(_ model: DeviceModel) -> String {
        let here = FirmwareCatalog.firmwares(for: model).filter { $0.support == .onDevice }.count
        if here == 0 { return "Prepared in the Mac app for now." }
        return "\(here) version\(here == 1 ? "" : "s") can be set up here."
    }

    // MARK: - Choose the software

    private var visibleFirmwares: [CatalogFirmware] {
        FirmwareCatalog.firmwares(for: model).filter { $0.support != .comingSoon && (showExperimental || !$0.isExperimental) }
    }

    private var softwarePage: some View {
        SixScreen(title: "Software", left: ("Back", { go(.device) }), leftIsBack: true,
                  right: softwareNext) {
            SetupHeading(symbol: "arrow.down.app", title: "Choose Software",
                         text: "Which version of iPhone OS should your \(model.shortName) run?")
            let rows = visibleFirmwares
            SixSection(header: model.name,
                       footer: rows.isEmpty ? (showExperimental ? "Nothing in the catalog for this model yet." : "Only experimental versions for this model. Turn on Experimental to see them.") : nil) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { SixSeparator() }
                    firmwareRow(entry)
                }
                if !rows.isEmpty { SixSeparator() }
                SixToggleRow(title: "Experimental", subtitle: "Versions that may not start or may misbehave.", isOn: $showExperimental)
            }
            SixSection(header: "Your Own IPSW",
                       footer: importNote.isEmpty ? "Light Touch matches it to the catalog, so it isn\u{2019}t downloaded again." : importNote) {
                SixRow(title: importing ? "Checking\u{2026}" : "Choose an IPSW\u{2026}", titleColor: Six.blue) {
                    if !importing { showIPSWPicker = true }
                }
            }
        }
    }

    /// Next, once a version is chosen.
    private var softwareNext: (String, () -> Void)? {
        if firmware == nil { return nil }
        return ("Next", { go(.name) })
    }

    private func setUpButton(_ plan: DevicePlan?) -> (String, () -> Void)? {
        guard let plan, AddDeviceView.canCreate(plan) else { return nil }
        return ("Set Up", { create(plan) })
    }

    private func firmwareRow(_ entry: CatalogFirmware) -> some View {
        let usable = entry.support == .onDevice
        let stored = IPSWStore.has(entry)
        let downloading = downloadingIPSW?.id == entry.id
        var subtitle = AddDeviceView.rowDetail(entry, support: entry.support, stored: stored)
        if let seed = entry.prereleaseLabel { subtitle += " \u{00B7} Developer " + (seed == "GM" ? "GM" : seed.capitalized) }
        if entry.isExperimental { subtitle += entry.status == "untested" ? " \u{00B7} Untested" : " \u{00B7} Experimental" }
        if downloading && !downloadMessage.isEmpty { subtitle += "\n" + downloadMessage }
        let value: String? = usable ? nil : (stored ? "Downloaded" : downloading ? "\(Int(downloadFraction * 100))%" : "Download")
        return SixRow(icon: AnyView(VersionBadge(firmware: entry, size: 40).padding(.trailing, 4)),
                      title: "\(entry.systemName) (\(entry.build))", subtitle: subtitle, value: value,
                      chevron: false, checked: usable && firmware?.id == entry.id,
                      titleColor: usable ? nil : Six.subtle) {
            if usable {
                firmware = entry
            } else if !stored && downloadingIPSW == nil {
                startIPSWDownload(entry)
            }
        }
    }

    private func startIPSWDownload(_ entry: CatalogFirmware) {
        downloadingIPSW = entry
        downloadFraction = 0
        downloadMessage = ""
        Task {
            do {
                try await IPSWStore.download(entry) { fraction, detail in
                    Task { @MainActor in
                        downloadFraction = fraction
                        downloadMessage = detail
                    }
                }
                importNote = "Saved to Files \u{203A} LightTouch \u{203A} IPSW."
            } catch is CancellationError {
                importNote = "Cancelled."
            } catch {
                importNote = error.localizedDescription
            }
            downloadingIPSW = nil
        }
    }

    private func importIPSW(_ file: URL) {
        importing = true
        importNote = ""
        Task {
            let result: Result<CatalogFirmware, Error> = await Task.detached(priority: .userInitiated) {
                defer { try? FileManager.default.removeItem(at: file) }
                return Result { try IPSWStore.importFile(file) { _ in } }
            }.value
            importing = false
            switch result {
            case .success(let entry):
                model = DeviceModel(board: entry.board)
                if entry.isExperimental { showExperimental = true }
                if entry.support == .onDevice {
                    firmware = entry
                    importNote = "Added \(entry.systemName)."
                } else {
                    importNote = "Added \(entry.systemName) for \(model.shortName), but that one has to be prepared in the Mac app."
                }
            case .failure(let error):
                importNote = error.localizedDescription
            }
        }
    }

    // MARK: - Name and options

    private var namePage: some View {
        let current = plan
        return SixScreen(title: "Name", left: ("Back", { go(readyMade ? .device : .software) }), leftIsBack: true,
                         right: setUpButton(current)) {
            if let current {
                VStack(spacing: 6) {
                    DeviceThumbnail(model: current.model, height: 140)
                    Text(current.model.name).font(Six.font(20, bold: true)).foregroundStyle(Six.text)
                        .shadow(color: Six.headerShadow, radius: 0, y: 1)
                    Text(AddDeviceView.planSubtitle(current)).font(Six.font(14)).foregroundStyle(Six.header)
                        .shadow(color: Six.headerShadow, radius: 0, y: 1)
                }
                .padding(.top, 16)
                SixSection(header: "Name Your Device") {
                    TextField(current.name, text: $name)
                        .font(Six.font(17))
                        .foregroundStyle(Six.text)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                }
                if case .firmware(let entry) = current.kind {
                    SixSection(header: "Options") {
                        // Only 3.x and later ship a Setup Assistant; 1.x and 2.x boot straight to SpringBoard.
                        if entry.major >= 3 {
                            SixToggleRow(title: "Skip Setup Assistant", subtitle: "Boot straight to the Home screen the first time.", isOn: $skipSetup)
                            SixSeparator()
                        }
                        SixToggleRow(title: "Jailbreak", subtitle: "Experimental: installs Cydia and MobileSubstrate.", isOn: $jailbreak)
                        SixSeparator()
                        SixToggleRow(title: "Software Graphics",
                                     subtitle: "Slower, but right if icons and text come out as blank white boxes (iPhone OS 1 on some builds).",
                                     isOn: $softwareGraphics)
                    }
                }
                SixSection(header: "What Happens", footer: spaceNote(current)) {
                    ForEach(Array(AddDeviceView.planSteps(current).enumerated()), id: \.offset) { index, step in
                        if index > 0 { SixSeparator() }
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: step.symbol).font(.system(size: 15)).foregroundStyle(Six.blue).frame(width: 22)
                            Text(step.text).font(Six.font(13)).foregroundStyle(Six.text).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                    }
                }
                SixBigButton(title: "Set Up \(current.model.shortName)", enabled: AddDeviceView.canCreate(current)) { create(current) }
                    .padding(.top, 20)
            }
        }
    }

    private func spaceNote(_ plan: DevicePlan) -> String {
        let free = Transfer.freeSpace()
        let enough = free == 0 || free >= plan.spaceNeeded
        return (enough ? "" : "Not enough space. ") +
            "Needs about \(Transfer.format(plan.spaceNeeded)) free while it works; \(Transfer.format(free)) available."
    }

    private func create(_ base: DevicePlan) {
        var chosen = base
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        chosen.name = trimmed.isEmpty ? base.name : trimmed
        chosen.skipSetup = skipSetup
        chosen.jailbreak = jailbreak
        chosen.softwareGraphics = softwareGraphics
        go(.working)
        creator.start(chosen)
    }

    // MARK: - Setting up, and welcome

    @ViewBuilder private var workingPage: some View {
        if let device = creator.finished {
            SetupWelcome(model: plan?.model ?? DeviceModel(board: "n72ap"), deviceName: device.name,
                         onStart: { onClose(device, true) }, onLater: { onClose(device, false) })
        } else {
            SixScreen(title: creator.failure == nil ? "Setting Up" : "Setup Failed") {
                VStack(spacing: 10) {
                    if creator.failure == nil {
                        ProgressView().controlSize(.large).tint(Six.header).padding(.top, 26)
                        Text("Setting up your \(plan?.model.shortName ?? "device")\u{2026}")
                            .font(Six.font(18, bold: true)).foregroundStyle(Six.text)
                            .shadow(color: Six.headerShadow, radius: 0, y: 1)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(Six.red).padding(.top, 26)
                    }
                }
                .frame(maxWidth: .infinity)
                SixSection(footer: creator.running ? "Keep Light Touch open until this finishes. iOS pauses it in the background." : nil) {
                    ForEach(Array(creator.stages.enumerated()), id: \.element.id) { index, stage in
                        if index > 0 { SixSeparator() }
                        stageRow(stage)
                    }
                }
                if let failure = creator.failure {
                    SixSection(header: "What Went Wrong") {
                        Text(failure).font(Six.font(13)).foregroundStyle(Six.text).fixedSize(horizontal: false, vertical: true).padding(10)
                    }
                }
                if !creator.warnings.isEmpty {
                    SixSection(header: "Notes") {
                        ForEach(Array(creator.warnings.enumerated()), id: \.offset) { index, warning in
                            if index > 0 { SixSeparator() }
                            Text(warning).font(Six.font(12)).foregroundStyle(Six.subtle).fixedSize(horizontal: false, vertical: true).padding(10)
                        }
                    }
                }
                VStack(spacing: 10) {
                    if creator.running {
                        SixBigButton(title: "Cancel", colors: [Six.ui(0xA6AEB8).swiftUI, Six.ui(0x5E6670).swiftUI], secondary: true) { creator.cancel() }
                    } else {
                        if let again = plan {
                            SixBigButton(title: "Try Again") { create(again) }
                        }
                        SixBigButton(title: "Close", colors: [Six.ui(0xA6AEB8).swiftUI, Six.ui(0x5E6670).swiftUI], secondary: true) { onClose(nil, false) }
                    }
                }
                .padding(.top, 20)
            }
        }
    }

    private func stageRow(_ stage: DeviceCreator.Stage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                switch stage.state {
                case .waiting: Image(systemName: "circle").foregroundStyle(Six.chevron)
                case .running: ProgressView().tint(Six.blue)
                case .done: Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Six.detail)
                case .failed: Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Six.red)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(stage.title).font(Six.font(15, bold: true))
                    .foregroundStyle(stage.state == .waiting ? Six.subtle : Six.text)
                if stage.state == .running, let fraction = stage.fraction {
                    ProgressView(value: fraction).tint(Six.blue)
                }
                if !stage.detail.isEmpty {
                    Text(stage.detail).font(Six.font(12)).foregroundStyle(Six.subtle).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }
}

/// A Setup Assistant page's heading: a big symbol, a title, a line of explanation, embossed on the pinstripes.
struct SetupHeading: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Six.header)
                .shadow(color: Six.headerShadow, radius: 0, y: 1)
            Text(title).font(Six.font(22, bold: true)).foregroundStyle(Six.text)
                .shadow(color: Six.headerShadow, radius: 0, y: 1)
            Text(text).font(Six.font(14)).foregroundStyle(Six.header)
                .shadow(color: Six.headerShadow, radius: 0, y: 1)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
    }
}

/// The first screen: dark linen, a greeting in turn in several languages, and the slider of the time.
struct SetupHello: View {
    let onSlide: () -> Void
    let onCancel: () -> Void

    private static let greetings = ["Hello", "Bonjour", "Hola", "Hallo", "Ciao", "\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}", "Ol\u{00E1}", "\u{4F60}\u{597D}"]
    @State private var index = 0
    private let timer = Timer.publish(every: 2.2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            SetupLinen()
            VStack(spacing: 0) {
                HStack {
                    Button("Cancel", action: onCancel)
                        .font(Six.font(15, bold: true))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                }
                .padding(16)
                Spacer()
                if let logo = UIImage(named: "Logo") {
                    Image(uiImage: logo)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 90, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.6), radius: 6, y: 3)
                } else {
                    DeviceThumbnail(model: DeviceModel(board: "n72ap"), height: 120)
                }
                Text(Self.greetings[index])
                    .font(.custom("Helvetica-Light", size: 52))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 0, y: -1)
                    .id(index)
                    .transition(.opacity)
                    .padding(.top, 24)
                Text("Let\u{2019}s set up a new device.")
                    .font(Six.font(16))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 6)
                Spacer()
                SlideToSetUp(label: "slide to set up", onComplete: onSlide)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
            }
        }
        .onReceive(timer) { _ in withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % Self.greetings.count } }
    }
}

/// iOS's slider of the time: a dark well, a glossy knob with an arrow, and text with a light passing over it.
struct SlideToSetUp: View {
    let label: String
    let onComplete: () -> Void
    @State private var offset: CGFloat = 0
    @State private var shimmer: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = 62
            let travel = max(1, geo.size.width - knob - 8)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color.black.opacity(0.75), Color(white: 0.12).opacity(0.85)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
                Text(label)
                    .font(.custom("Helvetica", size: 22))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .overlay(
                        LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 90)
                            .offset(x: shimmer * geo.size.width * 0.6)
                            .mask(Text(label).font(.custom("Helvetica", size: 22))))
                    .frame(maxWidth: .infinity)
                    .padding(.leading, knob * 0.7)
                    .opacity(Double(1 - offset / travel))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white, Color(white: 0.72)], startPoint: .top, endPoint: .bottom))
                    .overlay(Image(systemName: "arrow.right").font(.system(size: 24, weight: .bold)).foregroundStyle(Color(white: 0.45)))
                    .frame(width: knob, height: geo.size.height - 8)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .offset(x: 4 + offset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in offset = min(travel, max(0, value.translation.width)) }
                            .onEnded { _ in
                                if offset > travel * 0.85 {
                                    offset = travel
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    onComplete()
                                } else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
                                }
                            })
            }
        }
        .frame(height: 70)
        .onAppear {
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) { shimmer = 1 }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onComplete() }
    }
}

/// Dark linen, drawn: the cloth iOS 5–6 used behind its lock screen and setup.
struct SetupLinen: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [Color(white: 0.22), Color(white: 0.10)]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            // The weave: fine lines both ways at low contrast.
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.white.opacity(0.025)))
                y += 3
            }
            var x: CGFloat = 0
            while x < size.width {
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.black.opacity(0.06)))
                x += 3
            }
        }
        .ignoresSafeArea()
    }
}

/// The last screen: "Welcome to your iPod touch".
struct SetupWelcome: View {
    let model: DeviceModel
    let deviceName: String
    let onStart: () -> Void
    let onLater: () -> Void

    var body: some View {
        SixScreen(title: "Welcome") {
            VStack(spacing: 10) {
                DeviceThumbnail(model: model, height: 200).padding(.top, 26)
                Text("Welcome to your \(model.shortName)")
                    .font(Six.font(24, bold: true))
                    .foregroundStyle(Six.text)
                    .shadow(color: Six.headerShadow, radius: 0, y: 1)
                    .multilineTextAlignment(.center)
                Text("\(deviceName) is set up and ready to start.")
                    .font(Six.font(15))
                    .foregroundStyle(Six.header)
                    .shadow(color: Six.headerShadow, radius: 0, y: 1)
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 10) {
                SixBigButton(title: "Start Using \(model.shortName)", action: onStart)
                SixBigButton(title: "Later", colors: [Six.ui(0xA6AEB8).swiftUI, Six.ui(0x5E6670).swiftUI], secondary: true, action: onLater)
            }
            .padding(.top, 30)
        }
    }
}
