import Cocoa
import HostRuntime
import LightTouchCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Capture: capture-specific choices, shared with the toolbar's Save/Open actions.
struct CaptureOptionsView: View {
    let preferences: CapturePreferences
    /// After any change (the toolbar's Open Screenshot names the app).
    var onChange: () -> Void = {}

    /// CapturePreferences reads user defaults; bumped on every change so the form reads them again.
    @State private var revision = 0
    @State private var applications: [URL] = []
    /// Other… asks for this; `isChoosing` while the open panel is up.
    @State private var choice = Choice.folder
    @State private var isChoosing = false

    private enum Choice { case folder, application }
    /// The pop-ups' last item, which asks for a folder or an app.
    private static let other = URL(fileURLWithPath: "/dev/null/other")

    var body: some View {
        let _ = revision
        Form {
            Section {
                Picker("Save location", selection: saveLocation) {
                    ForEach(preferences.saveLocations, id: \.self) { url in
                        Label {
                            Text(folderName(url))
                        } icon: {
                            Image(nsImage: Self.icon(url))
                        }.tag(url)
                    }
                    Divider()
                    Text("Other…").tag(Self.other)
                }
                Picker("Open screenshots in", selection: application) {
                    ForEach(applications, id: \.self) { url in
                        Label {
                            Text(applicationTitle(url))
                        } icon: {
                            Image(nsImage: Self.icon(url))
                        }.tag(Optional(url))
                    }
                    Divider()
                    Text("Other…").tag(Optional(Self.other))
                }
            }
            Section {
                Toggle("Show captures in Finder", isOn: binding(\.openFinderAfterCapture))
                Toggle("Copy screenshots to the clipboard", isOn: binding(\.copyOnCapture))
                Toggle("Play sound effects", isOn: binding(\.soundEffectsEnabled))
            }
        }
        .fileImporter(
            isPresented: $isChoosing,
            allowedContentTypes: choice == .application ? [.application] : [.folder]
        ) { result in
            guard let url = try? result.get() else { return }
            if choice == .application { preferences.openInApplicationURL = url } else { preferences.saveLocation = url }
            changed()
        }
        .fileDialogDefaultDirectory(
            choice == .application ? URL(fileURLWithPath: "/Applications") : preferences.saveLocation
        )
        .task(id: revision) { applications = Self.applications(selected: preferences.openInApplicationURL) }
    }

    private func changed() {
        revision += 1
        onChange()
    }

    private func binding<T>(_ key: WritableKeyPath<CapturePreferences, T>) -> Binding<T> {
        Binding(
            get: {
                _ = revision
                return preferences[keyPath: key]
            },
            set: {
                var preferences = preferences
                preferences[keyPath: key] = $0
                changed()
            }
        )  // nonmutating setters
    }

    /// The save location pop-up: Other… asks for a folder instead of being chosen.
    private var saveLocation: Binding<URL> {
        let plain = binding(\.saveLocation)
        return Binding(
            get: { plain.wrappedValue },
            set: {
                if $0 == Self.other {
                    choice = .folder
                    isChoosing = true
                } else {
                    plain.wrappedValue = $0
                }
            }
        )
    }

    /// The screenshot app pop-up: Other… asks for an app.
    private var application: Binding<URL?> {
        let plain = binding(\.openInApplicationURL)
        return Binding(
            get: { plain.wrappedValue },
            set: {
                if $0 == Self.other {
                    choice = .application
                    isChoosing = true
                } else {
                    plain.wrappedValue = $0
                }
            }
        )
    }

    private func folderName(_ url: URL) -> String {
        let locations = preferences.saveLocations
        var name = FileManager.default.displayName(atPath: url.path)
        if locations.filter({ $0.lastPathComponent == url.lastPathComponent }).count > 1 {
            name += " — " + url.deletingLastPathComponent().lastPathComponent
        }
        return name
    }

    private func applicationTitle(_ url: URL) -> String {
        CapturePreferences.applicationName(url) + (url == CapturePreferences.previewApplicationURL ? " (default)" : "")
    }

    /// Preview first, then the apps that open a PNG and the chosen one, by name.
    static func applications(selected: URL?) -> [URL] {
        let preview = CapturePreferences.previewApplicationURL
        var seen = Set<String>()
        let others =
            (NSWorkspace.shared.urlsForApplications(toOpen: URL(fileURLWithPath: "/Screenshot.png"))
            + [selected].compactMap { $0 })
            .filter { $0 != preview && CapturePreferences.isApplication($0) && seen.insert($0.path).inserted }
            .sorted {
                CapturePreferences.applicationName($0).localizedStandardCompare(CapturePreferences.applicationName($1))
                    == .orderedAscending
            }
        return [preview].compactMap { $0 } + others
    }

    static func icon(_ url: URL) -> NSImage {
        let shared = NSWorkspace.shared.icon(forFile: url.path)
        // A copy, so the 16-point size doesn't resize the workspace's shared icon.
        guard let icon = shared.copy() as? NSImage else { return shared }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}
