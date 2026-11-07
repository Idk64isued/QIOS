import Cocoa
import LightTouchCore
import SwiftUI

/// A version picker backed by the public copy API; install eligibility is
/// rechecked by the emulator endpoint when the user chooses a copy.
final class CatalogDetailsViewController: NSHostingController<CatalogDetailsView> {
    let model: CatalogDetailsModel

    init(
        app: CatalogApp,
        device: String? = nil,
        deviceOS: String = "3.1.3",
        arch: String = "armv6",
        installedVersion: String? = nil,
        canInstall: @escaping () -> Bool,
        install: @escaping (CatalogApp) -> Void
    ) {
        model = CatalogDetailsModel(
            app: app,
            device: device,
            deviceOS: deviceOS,
            arch: arch,
            installedVersion: installedVersion,
            canInstall: canInstall,
            install: install
        )
        super.init(rootView: CatalogDetailsView(model: model))
        sizingOptions = .preferredContentSize
        model.close = { [weak self] in self.map { $0.dismiss($0) } }
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct CatalogDetailsView: View {
    @Bindable var model: CatalogDetailsModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if let rows = model.rows, !rows.isEmpty {
                        Picker("Version", selection: $model.selection) {
                            ForEach(rows, id: \.copy.ipaID) { Text(model.title($0)).tag(Optional($0.copy.ipaID)) }
                        }
                    } else {
                        LabeledContent("Version") {
                            if model.rows == nil { ProgressView().controlSize(.small) } else { Text("None") }
                        }
                    }
                    LabeledContent("Minimum iOS", value: minimumOS ?? "—")
                } header: {
                    Text(model.app.name).font(.headline)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let problem = model.problem {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                        }
                        if let note = model.downgradeNote { Text(note) }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Install This Version") { model.installSelection() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canInstallSelection)
                    .help(model.problem ?? "")
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        .task { await model.load() }
        .task(id: model.selection) { await model.check() }
    }

    /// What the copy needs: the listing's minimum, or the binary's own when it asks for more.
    private var minimumOS: String? {
        let listed = model.selectedRow?.version.minimumOSVersion
        guard let binary = model.details?.binary?.machOMinOS else { return listed }
        guard let listed else { return binary }
        return binary.compare(listed, options: .numeric) == .orderedDescending ? binary : listed
    }
}
