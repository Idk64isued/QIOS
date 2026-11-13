import Foundation
import SwiftUI

// MARK: - Catalog Model (matches legacystore.app API)

struct CatalogApp: Codable, Identifiable, Sendable {
    let bundleID: String?
    let name: String
    let developer: String?
    let version: String?
    let minOS: String?
    let size: Int64?
    let ipaID: Int
    let iconURL: URL?
    let downloadURL: URL
    let appURL: URL?
    let md5: String?
    let compat: Compat?

    var id: Int { ipaID }

    struct Compat: Codable, Sendable {
        let compatible: Bool
        let reasons: [String]
        let deviceFamily: [String]?

        enum CodingKeys: String, CodingKey {
            case compatible, reasons
            case deviceFamily = "device_family"
        }
    }

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case name, developer, version
        case minOS = "min_os"
        case size
        case ipaID = "ipa_id"
        case iconURL = "icon_url"
        case downloadURL = "download_url"
        case appURL = "app_url"
        case md5, compat
    }

    var subtitle: String {
        if let compat, !compat.compatible, let reason = compat.reasons.first {
            return incompatibilityText(reason)
        }
        var parts: [String] = []
        if let developer { parts.append(developer) }
        if let size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        return parts.isEmpty ? (version ?? "") : parts.joined(separator: " · ")
    }

    var isCompatible: Bool { compat?.compatible ?? true }

    private func incompatibilityText(_ reason: String) -> String {
        if reason == "armv6_slice_contains_armv7_code" || (reason.hasPrefix("no_") && reason.hasSuffix("_slice")) {
            return "Needs a newer processor"
        }
        if reason.hasPrefix("requires_ios_") { return "Requires iOS \(reason.dropFirst("requires_ios_".count))" }
        if reason.hasPrefix("capability:!") || reason.hasSuffix("device_family") || reason == "family_not_requested" {
            return "Not made for this device"
        }
        if reason.hasPrefix("capability:") { return "Needs hardware this device doesn\u{2019}t have" }
        switch reason {
        case "encrypted": return "Encrypted \u{2014} can\u{2019}t open in Light Touch"
        case "unavailable": return "Download no longer available"
        case "not_analyzed": return "Not checked for compatibility yet"
        default: return "Not compatible with this device"
        }
    }
}

// MARK: - Versions (GET /api/v1/apps/<bundle id>/versions)

/// One version of an app in the archive, and the copies of it the archive holds.
struct CatalogVersion: Decodable, Identifiable {
    struct Copy: Decodable, Identifiable {
        let ipaID: String
        let size: Int64?
        let installStatus: String?
        let architectures: [String]?
        let machOMinOS: String?
        var id: String { ipaID }

        enum CodingKeys: String, CodingKey {
            case ipaID = "ipa_id"
            case size
            case installStatus = "install_status"
            case architectures
            case machOMinOS = "macho_min_os"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // The id is text here and a number in the search results; take either.
            if let text = try? c.decode(String.self, forKey: .ipaID) {
                ipaID = text
            } else {
                ipaID = String(try c.decode(Int.self, forKey: .ipaID))
            }
            size = try? c.decodeIfPresent(Int64.self, forKey: .size)
            installStatus = try? c.decodeIfPresent(String.self, forKey: .installStatus)
            architectures = try? c.decodeIfPresent([String].self, forKey: .architectures)
            machOMinOS = try? c.decodeIfPresent(String.self, forKey: .machOMinOS)
        }
    }

    let version: String?
    let minimumOSVersion: String?
    let copies: [Copy]
    var id: String { (version ?? "?") + "-" + (copies.first?.ipaID ?? "none") }

    enum CodingKeys: String, CodingKey {
        case version
        case minimumOSVersion = "minimum_os_version"
        case copies
    }
}

/// The device the store judges apps for: its model ("iPod2,1"), its system version and its processor.
struct StoreTarget: Equatable {
    var productType = "iPod2,1"
    var os = "3.1.3"
    var arch = "armv6"
    var name = "iPod touch 2G"

    /// `true` when version `a` is newer than `b` ("3.1.3" vs "3.0").
    static func newer(_ a: String, than b: String) -> Bool { a.compare(b, options: .numeric) == .orderedDescending }

    /// Why this copy cannot run on the device, or nil when it can.
    func problem(with copy: CatalogVersion.Copy, minimumOS: String?) -> String? {
        if let status = copy.installStatus, status != "installable" {
            return status == "encrypted" ? "Encrypted" : "Not installable"
        }
        if let archs = copy.architectures, !archs.isEmpty,
            !archs.contains(where: { $0 == arch || (arch == "armv7" && $0 == "armv6") })
        {
            return "Needs a newer processor"
        }
        for wanted in [minimumOS, copy.machOMinOS] {
            if let wanted, !wanted.isEmpty, Self.newer(wanted, than: os) { return "Requires iOS \(wanted)" }
        }
        return nil
    }
}

// MARK: - Store Client

@MainActor
final class LegacyStoreClient: ObservableObject {
    static let baseURL = URL(string: "https://legacystore.app")!

    @Published var results: [CatalogApp] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var query = ""
    var target = StoreTarget()

    private var searchTask: Task<Void, Never>?

    private func appsURL(_ items: [URLQueryItem]) -> URL? {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("api/emulator/apps"), resolvingAgainstBaseURL: false)
        components?.queryItems = items + [
            URLQueryItem(name: "device", value: target.productType), URLQueryItem(name: "os", value: target.os)
        ]
        return components?.url
    }

    private static func message(for error: Error) -> String {
        if error is DecodingError { return "Legacy Store sent a response Light Touch couldn\u{2019}t read." }
        return error.localizedDescription
    }

    /// Search the catalog for this device. An empty query is the store's suggested list.
    func search() {
        searchTask?.cancel()
        isLoading = true
        error = nil
        let query = self.query.trimmingCharacters(in: .whitespaces)
        searchTask = Task {
            if !query.isEmpty {
                try? await Task.sleep(nanoseconds: 300_000_000)  // wait for the typing to stop
                guard !Task.isCancelled else { return }
            }
            var items = [URLQueryItem(name: "limit", value: "50")]
            if !query.isEmpty {
                items.append(URLQueryItem(name: "q", value: query))
                items.append(URLQueryItem(name: "incompatible", value: "include"))
            }
            guard let url = appsURL(items) else {
                isLoading = false
                return
            }
            do {
                struct Envelope: Decodable { let apps: [CatalogApp] }
                let data = try await Transfer.data(url)
                guard !Task.isCancelled else { return }
                results = try JSONDecoder().decode(Envelope.self, from: data).apps
                error = nil
            } catch {
                guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
                self.error = Self.message(for: error)
            }
            isLoading = false
        }
    }

    /// Every archived version of `app`, newest first.
    func versions(for app: CatalogApp) async throws -> [CatalogVersion] {
        guard let key = app.bundleID ?? app.appURL?.lastPathComponent, !key.isEmpty else {
            throw Transfer.Failure(message: "This app has no catalog identifier.")
        }
        struct Envelope: Decodable { let data: [CatalogVersion] }
        let url = Self.baseURL.appendingPathComponent("api/v1/apps").appendingPathComponent(key).appendingPathComponent("versions")
        do {
            let list = try JSONDecoder().decode(Envelope.self, from: try await Transfer.data(url)).data
            return list.sorted { StoreTarget.newer($0.version ?? "0", than: $1.version ?? "0") }
        } catch {
            throw Transfer.Failure(message: Self.message(for: error))
        }
    }

    /// The search-result form of one archived copy (it carries the download address), judged for this device.
    func copy(ipaID: String, of app: CatalogApp) async throws -> CatalogApp {
        guard let url = appsURL([URLQueryItem(name: "ipa_id", value: ipaID)]) else { throw URLError(.badURL) }
        struct Envelope: Decodable { let apps: [CatalogApp] }
        let apps: [CatalogApp]
        do { apps = try JSONDecoder().decode(Envelope.self, from: try await Transfer.data(url)).apps } catch {
            throw Transfer.Failure(message: "This copy is no longer available for \(target.name).")
        }
        guard let copy = apps.first, String(copy.ipaID) == ipaID, copy.compat?.compatible != false else {
            throw Transfer.Failure(message: "This copy is no longer available for \(target.name).")
        }
        return copy
    }

    /// Legacy Store links to the Internet Archive; nothing else is accepted as a download.
    static func acceptsDownload(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), scheme == "https" else { return false }
        return host == baseURL.host || host == "archive.org" || host.hasSuffix(".archive.org")
    }

    /// Downloads an IPA to a temporary file (streamed to disk) and checks it against the archive's checksum.
    func downloadIPA(_ app: CatalogApp, progress: @escaping (Double) -> Void) async throws -> URL {
        guard Self.acceptsDownload(app.downloadURL) else {
            throw Transfer.Failure(message: "Legacy Store named a download Light Touch doesn\u{2019}t accept.")
        }
        let folder = Library.downloads.appendingPathComponent("ipa-\(app.ipaID)", isDirectory: true)
        Library.ensure(folder)
        let safeName = String(app.name.map { "/:\0".contains($0) ? "-" : $0 }.prefix(80))
        let file = folder.appendingPathComponent("\(safeName.isEmpty ? "App" : safeName).ipa")
        do {
            try await Transfer.download(app.downloadURL, to: file, expectedBytes: app.size, progress: progress)
            if let md5 = app.md5?.lowercased(), md5.count == 32 {
                let actual = try await Task.detached { try Transfer.md5(of: file) }.value
                guard actual == md5 else {
                    throw Transfer.Failure(message: "The downloaded IPA failed its checksum check. Try downloading it again.")
                }
            }
            return file
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

// MARK: - Legacy Store View

struct LegacyStoreView: View {
    @StateObject private var store = LegacyStoreClient()
    /// The running device's agent; nil when no device is running (the store can still be browsed).
    let agent: GuestAgent?
    let target: StoreTarget
    let onDismiss: () -> Void

    @State private var busy: Int?  // the ipa_id being downloaded or installed
    @State private var progress: Double = 0
    @State private var message = ""
    @State private var messageIsGood = false
    @State private var details: CatalogApp?

    var body: some View {
        NavigationView {
            ZStack {
                LTBackground()
                VStack(spacing: 0) {
                    searchBar
                    if agent == nil {
                        banner("Start a device to install apps. You can browse meanwhile.", Theme.warning)
                    }
                    content
                    if !message.isEmpty { banner(message, messageIsGood ? Theme.success : Theme.warning) }
                }
            }
            .navigationTitle("Legacy Store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }.foregroundStyle(Theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            store.target = target
            store.search()
        }
        .sheet(item: $details) { app in
            AppVersionsView(app: app, store: store, canInstall: agent != nil && busy == nil) { copy in
                details = nil
                install(copy)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
            TextField("Search apps for \(target.name)", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(.white)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { store.search() }
                .onChange(of: store.query) { _ in store.search() }
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder private var content: some View {
        if store.isLoading && store.results.isEmpty {
            Spacer()
            ProgressView().tint(Theme.accent)
            Spacer()
        } else if let error = store.error {
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.system(size: 32)).foregroundStyle(Theme.warning)
            Text(error)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 8)
            Button("Retry") { store.search() }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .padding(.top, 12)
            Spacer()
        } else if store.results.isEmpty {
            Spacer()
            Text(store.query.isEmpty ? "Nothing to show yet." : "No apps found for \u{201C}\(store.query)\u{201D}.")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(store.results) { app in appRow(app) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
        }
    }

    private func banner(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    private func appRow(_ app: CatalogApp) -> some View {
        HStack(spacing: 12) {
            // The row opens the app's versions; GET installs the copy the store picked for this device.
            Button { details = app } label: {
                HStack(spacing: 12) {
                    StoreIcon(url: app.iconURL)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(app.isCompatible ? .white : .white.opacity(0.45))
                            .lineLimit(1)
                        Text(app.subtitle)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(app.isCompatible ? Theme.secondaryText : Theme.danger.opacity(0.7))
                            .lineLimit(1)
                        if let version = app.version, !version.isEmpty {
                            Text("Version \(version) \u{203A}")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.accent.opacity(0.9))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if busy == app.ipaID {
                ProgressView(value: progress).frame(width: 50).tint(Theme.accent)
            } else if app.isCompatible {
                Button { install(app) } label: {
                    Text("GET")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(agent == nil || busy != nil)
                .opacity(agent == nil ? 0.4 : 1)
            } else {
                Image(systemName: "xmark.circle").foregroundStyle(Theme.danger.opacity(0.5))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func install(_ app: CatalogApp) {
        guard let agent, busy == nil else { return }
        busy = app.ipaID
        progress = 0
        messageIsGood = false
        message = "Downloading \(app.name)\u{2026}"
        Task {
            defer { busy = nil }
            do {
                let file = try await store.downloadIPA(app) { fraction in
                    Task { @MainActor in progress = max(0, fraction) }
                }
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                message = "Installing \(app.name)\u{2026}"
                let ok = await agent.installIPA(localURL: file)
                messageIsGood = ok
                message = ok ? (agent.hasShell ? "Installed \(app.name)." : "\(app.name) was copied to the device, but only a jailbroken device can finish installing it for now.")
                    : "Could not install \(app.name). See the log."
            } catch {
                message = error is CancellationError ? "Cancelled." : error.localizedDescription
            }
        }
    }
}

/// An app icon from the store, or a placeholder while it loads.
struct StoreIcon: View {
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(Image(systemName: "app").foregroundStyle(Theme.secondaryText))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

// MARK: - Version picker

/// Every archived version of one app. Pick the one to install: an older version often runs where the newest
/// one needs a newer system.
struct AppVersionsView: View {
    let app: CatalogApp
    @ObservedObject var store: LegacyStoreClient
    let canInstall: Bool
    let onInstall: (CatalogApp) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var versions: [CatalogVersion] = []
    @State private var loading = true
    @State private var error: String?
    @State private var resolving: String?

    var body: some View {
        NavigationView {
            ZStack {
                LTBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        header
                        if loading {
                            ProgressView().tint(Theme.accent).padding(.top, 30)
                        } else if let error {
                            Text(error)
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(Theme.warning)
                                .multilineTextAlignment(.center)
                            Button("Retry") { load() }.foregroundStyle(Theme.accent)
                        } else if versions.isEmpty {
                            Text("The archive lists no versions for this app.")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(Theme.secondaryText)
                        } else {
                            ForEach(versions) { version in versionCard(version) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("Versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.foregroundStyle(Theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { load() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            StoreIcon(url: app.iconURL, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if let developer = app.developer {
                    Text(developer).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.secondaryText)
                }
                Text("For \(store.target.name), \(store.target.os)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer(minLength: 0)
        }
    }

    private func versionCard(_ version: CatalogVersion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Version \(version.version ?? "unknown")")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                if let minimum = version.minimumOSVersion, !minimum.isEmpty {
                    Text("iOS \(minimum)+")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            if version.copies.isEmpty {
                Text("No archived copy").font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.tertiaryText)
            }
            ForEach(version.copies) { copy in copyRow(copy, of: version) }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func copyRow(_ copy: CatalogVersion.Copy, of version: CatalogVersion) -> some View {
        let problem = store.target.problem(with: copy, minimumOS: version.minimumOSVersion)
        var facts: [String] = []
        if let size = copy.size { facts.append(Transfer.format(size)) }
        if let archs = copy.architectures, !archs.isEmpty { facts.append(archs.joined(separator: ", ")) }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(facts.isEmpty ? "Archived copy" : facts.joined(separator: " \u{00B7} "))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(problem == nil ? .white.opacity(0.8) : .white.opacity(0.4))
                if let problem {
                    Text(problem).font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.danger.opacity(0.75))
                }
            }
            Spacer(minLength: 0)
            if resolving == copy.ipaID {
                ProgressView().tint(Theme.accent)
            } else if problem == nil {
                Button { choose(copy) } label: {
                    Text("GET")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canInstall || resolving != nil)
                .opacity(canInstall ? 1 : 0.4)
            }
        }
    }

    private func load() {
        loading = true
        error = nil
        Task {
            do { versions = try await store.versions(for: app) } catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private func choose(_ copy: CatalogVersion.Copy) {
        resolving = copy.ipaID
        Task {
            do {
                let resolved = try await store.copy(ipaID: copy.ipaID, of: app)
                resolving = nil
                onInstall(resolved)
            } catch {
                resolving = nil
                self.error = error.localizedDescription
            }
        }
    }
}
