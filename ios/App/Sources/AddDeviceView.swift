import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Add Device: pick a model and a version (or the ready-made iPod touch), see what it will take, and let the phone
/// download and prepare it. The Mac app's Add Device sheet, as one flow.
struct AddDeviceView: View {
    /// The new device (nil if nothing was added) and whether to start it right away.
    let onClose: (DeviceFolder?, Bool) -> Void

    private enum Page { case pick, confirm, working }

    @StateObject private var creator = DeviceCreator()
    @State private var page: Page = .pick
    @State private var model = FirmwareCatalog.models.first ?? DeviceModel(board: "n72ap")
    @State private var showExperimental = false
    @State private var plan: DevicePlan?
    @State private var name = ""
    @State private var showIPSWPicker = false
    @State private var importNote = ""
    @State private var importing = false

    var body: some View {
        NavigationView {
            ZStack {
                LTBackground()
                switch page {
                case .pick: pickPage
                case .confirm: confirmPage
                case .working: workingPage
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if page == .confirm {
                        Button("Back") { page = .pick }.foregroundStyle(Theme.accent)
                    } else if page == .pick {
                        Button("Cancel") { onClose(nil, false) }.foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(page == .working && creator.running)
        .sheet(isPresented: $showIPSWPicker) {
            DocumentPickerView(types: [UTType(filenameExtension: "ipsw") ?? .data, .zip, .data]) { url in
                showIPSWPicker = false
                if let url { importIPSW(url) }
            }
        }
    }

    private var title: String {
        switch page {
        case .pick: return "Add Device"
        case .confirm: return "New Device"
        case .working: return creator.finished != nil ? "Ready" : "Creating"
        }
    }

    // MARK: - 1. Pick

    private var pickPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                readyMadeCard
                firmwareCard
                ownIPSWCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var readyMadeCard: some View {
        let ready = DevicePlan(kind: .readyMade, name: "iPod touch")
        return GlassCard("Quick start", symbol: "bolt.fill") {
            Button {
                choose(ready)
            } label: {
                HStack(spacing: 14) {
                    DeviceThumbnail(model: DeviceModel(board: "n72ap"), height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ready-made iPod touch")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("iPhone OS 3.1.3, already set up. The same device the Mac app starts with.")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(ready.needsMacFiles ? "\(Transfer.format(MacFiles.approximateBytes)) download" : "No download needed")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(Theme.tertiaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var firmwareCard: some View {
        GlassCard("From firmware", symbol: "square.stack.3d.down.right") {
            if !OnDevicePrep.available {
                noticeRow("exclamationmark.triangle.fill", Theme.warning,
                    "This build cannot prepare firmware yet. You can still download IPSWs here; use the ready-made iPod touch to get going.")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FirmwareCatalog.models) { item in
                        Button { model = item } label: {
                            Text(item.shortName)
                                .font(.system(size: 12, weight: model == item ? .bold : .medium, design: .rounded))
                                .foregroundStyle(model == item ? .white : Theme.secondaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(model == item ? Theme.accent.opacity(0.28) : Color.white.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 12) {
                DeviceThumbnail(model: model, height: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(modelNote)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: $showExperimental) {
                Text("Show experimental")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .tint(Theme.accent)

            let rows = visibleFirmwares
            if rows.isEmpty {
                Text(showExperimental ? "Nothing in the catalog for this model yet." : "Only experimental versions for this model. Turn on Show experimental to see them.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                VStack(spacing: 6) {
                    ForEach(rows) { entry in firmwareRow(entry) }
                }
            }
        }
    }

    private var modelNote: String {
        let all = FirmwareCatalog.firmwares(for: model)
        let here = all.filter { $0.support == .onDevice }.count
        if here == 0 { return "Devices of this model have to be prepared in the Mac app for now." }
        return "\(here) version\(here == 1 ? "" : "s") can be prepared on this iPhone."
    }

    private var visibleFirmwares: [CatalogFirmware] {
        FirmwareCatalog.firmwares(for: model).filter { entry in
            entry.support != .comingSoon && (showExperimental || !entry.isExperimental)
        }
    }

    private func firmwareRow(_ entry: CatalogFirmware) -> some View {
        let support = entry.support
        let usable = support == .onDevice
        let stored = IPSWStore.has(entry)
        return Button {
            choose(DevicePlan(kind: .firmware(entry), name: "\(DeviceModel(board: entry.board).shortName) \(entry.version)"))
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.systemName)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(usable ? .white : .white.opacity(0.45))
                        Text(entry.build)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.tertiaryText)
                        if entry.isExperimental { badge(entry.status == "untested" ? "Untested" : "Experimental", Theme.warning) }
                    }
                    Text(rowDetail(entry, support: support, stored: stored))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(usable ? Theme.secondaryText : Theme.warning.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: usable ? "chevron.right" : "desktopcomputer")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
    }

    private func rowDetail(_ entry: CatalogFirmware, support: CatalogFirmware.Support, stored: Bool) -> String {
        if case .needsMac(let why) = support { return why }
        if stored { return "IPSW downloaded" }
        return entry.source.bytes.map { "\(Transfer.format($0)) IPSW" } ?? "IPSW"
    }

    private var ownIPSWCard: some View {
        GlassCard("Your own IPSW", symbol: "doc.badge.plus") {
            Text("Already have a restore file? Add it and Light Touch matches it to the catalog, so it does not download it again.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
            Button {
                showIPSWPicker = true
            } label: {
                Label(importing ? "Checking…" : "Choose an IPSW…", systemImage: "folder")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(importing)
            if !importNote.isEmpty {
                Text(importNote)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.warning)
            }
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
                    choose(DevicePlan(kind: .firmware(entry), name: "\(model.shortName) \(entry.version)"))
                } else {
                    importNote = "Added \(entry.systemName) for \(model.shortName), but that one has to be prepared in the Mac app."
                }
            case .failure(let error):
                importNote = error.localizedDescription
            }
        }
    }

    private func choose(_ chosen: DevicePlan) {
        plan = chosen
        name = chosen.name
        page = .confirm
    }

    // MARK: - 2. Confirm

    private var confirmPage: some View {
        ScrollView {
            if let plan {
                VStack(spacing: 16) {
                    DeviceThumbnail(model: plan.model, height: 190)
                        .padding(.top, 8)
                    VStack(spacing: 4) {
                        Text(plan.model.name)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(planSubtitle(plan))
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    GlassCard("Name", symbol: "pencil") {
                        TextField("Device name", text: $name)
                            .font(.system(size: 15, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .autocorrectionDisabled()
                    }
                    GlassCard("What happens", symbol: "list.bullet") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(planSteps(plan).enumerated()), id: \.offset) { _, step in
                                noticeRow(step.symbol, Theme.accent, step.text)
                            }
                        }
                        Divider().overlay(Color.white.opacity(0.08))
                        spaceRow(plan)
                    }
                    Button {
                        var chosen = plan
                        chosen.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? plan.name : name
                        page = .working
                        creator.start(chosen)
                    } label: {
                        Text("Create Device")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCreate(plan))
                    .opacity(canCreate(plan) ? 1 : 0.45)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
    }

    private func canCreate(_ plan: DevicePlan) -> Bool {
        if case .firmware = plan.kind { return OnDevicePrep.available }
        return true
    }

    private func planSubtitle(_ plan: DevicePlan) -> String {
        switch plan.kind {
        case .firmware(let entry): return "\(entry.systemName) (\(entry.build))"
        case .readyMade: return "iPhone OS 3.1.3 (7E18), ready-made"
        }
    }

    private func planSteps(_ plan: DevicePlan) -> [(symbol: String, text: String)] {
        var steps: [(symbol: String, text: String)] = []
        if plan.needsMacFiles {
            steps.append(("arrow.down.circle", "Download the Mac release (\(Transfer.format(MacFiles.approximateBytes))) from GitHub and take the boot ROMs, the ready-made iPod and the guest tools out of it. Only needed once."))
        }
        switch plan.kind {
        case .firmware(let entry):
            if plan.needsIPSW {
                let host = entry.source.url?.host ?? "its archive"
                steps.append(("arrow.down.doc", "Download the \(entry.systemName) IPSW (\(Transfer.format(entry.source.bytes ?? 0))) from \(host) and check it against the catalog."))
            } else {
                steps.append(("checkmark.circle", "Use the \(entry.systemName) IPSW that is already here."))
            }
            steps.append(("hammer", "Prepare the device on this iPhone: decrypt the firmware, build its storage, add the guest tools. A minute or two."))
            if let note = entry.statusNote, !note.isEmpty { steps.append(("info.circle", note)) }
            if entry.isExperimental { steps.append(("flask", "This version is \(entry.status == "untested" ? "untested" : "experimental"): it may not start or may misbehave.")) }
            if !OnDevicePrep.available { steps.append(("exclamationmark.triangle", "This build cannot prepare firmware, so this device cannot be created here yet.")) }
        case .readyMade:
            steps.append(("shippingbox", "Unpack the ready-made iPod touch into a new device. Under a minute."))
        }
        return steps
    }

    private func spaceRow(_ plan: DevicePlan) -> some View {
        let free = Transfer.freeSpace()
        let needed = plan.spaceNeeded
        let enough = free == 0 || free >= needed
        return HStack(spacing: 8) {
            Image(systemName: enough ? "internaldrive" : "exclamationmark.triangle.fill")
                .foregroundStyle(enough ? Theme.secondaryText : Theme.danger)
            Text("Needs about \(Transfer.format(needed)) free while it works; \(Transfer.format(free)) available.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(enough ? Theme.secondaryText : Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 3. Working

    private var workingPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let plan {
                    DeviceThumbnail(model: plan.model, height: 150)
                        .opacity(creator.finished != nil ? 1 : 0.6)
                        .padding(.top, 8)
                }
                GlassCard(creator.finished != nil ? "Done" : "Progress", symbol: "checklist") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(creator.stages) { stage in stageRow(stage) }
                    }
                }
                if !creator.warnings.isEmpty {
                    GlassCard("Notes from the preparer", symbol: "text.bubble") {
                        ForEach(Array(creator.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let failure = creator.failure {
                    noticeRow("xmark.octagon.fill", Theme.danger, failure)
                        .padding(14)
                        .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                workingButtons
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    @ViewBuilder private var workingButtons: some View {
        if let device = creator.finished {
            VStack(spacing: 10) {
                bigButton("Start \(device.name)", filled: true) { onClose(device, true) }
                bigButton("Done", filled: false) { onClose(device, false) }
            }
        } else if creator.running {
            Text("Keep Light Touch open until this finishes. iOS pauses it in the background.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
            bigButton("Cancel", filled: false) { creator.cancel() }
        } else {
            VStack(spacing: 10) {
                bigButton("Try Again", filled: true) {
                    if var again = plan {
                        again.name = name.isEmpty ? again.name : name
                        creator.start(again)
                    }
                }
                bigButton("Close", filled: false) { onClose(nil, false) }
            }
        }
    }

    private func stageRow(_ stage: DeviceCreator.Stage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                switch stage.state {
                case .waiting: Image(systemName: "circle").foregroundStyle(Theme.tertiaryText)
                case .running: ProgressView().tint(Theme.accent)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(stage.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(stage.state == .waiting ? Theme.secondaryText : .white)
                if stage.state == .running, let fraction = stage.fraction {
                    ProgressView(value: fraction).tint(Theme.accent)
                }
                if !stage.detail.isEmpty {
                    Text(stage.detail)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Pieces

    private func bigButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(filled ? .white : Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(filled ? Theme.accent : Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func noticeRow(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 18)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
