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

// MARK: - The look: iPhone OS 3's App Store

/// The colours and pieces of the store as it looked on iPhone OS 3: a blue-grey glossy bar on top, a black tab bar
/// below, white rows, glossy icons, a grey-blue price button that turns into a green INSTALL, pinstripes behind the
/// detail page. Fixed, not light/dark: that look only ever came in one.
enum Classic {
    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
    static let navTop = hex(0xB2BFD0)
    static let navMid = hex(0x8A9DB8)
    static let navBottom = hex(0x6D84A2)
    static let navLine = hex(0x2D3642)
    static let searchTop = hex(0xCDD5DF)
    static let searchBottom = hex(0xA5B3C5)
    static let rowText = Color.black
    static let rowDetail = hex(0x7A7A7A)
    static let separator = hex(0xE0E0E0)
    static let priceText = hex(0x3B5A82)
    static let priceFill = hex(0xE3E9F1)
    static let priceBorder = hex(0x8EA0B5)
    static let installTop = hex(0x7AD35A)
    static let installBottom = hex(0x3D9A2B)
    static let pinstripeBase = hex(0xC5CCD4)
    static let pinstripeLine = hex(0xCBD2D8)
    static let groupBorder = hex(0xABABAB)
    static let tabTop = hex(0x3B3B3B)
    static let tabBottom = hex(0x0B0B0B)
    static let tabIdle = hex(0x8F8F8F)
    static let warning = hex(0xB23B2B)

    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "Helvetica-Bold" : "Helvetica", size: size)
    }

    /// The navigation bar's gloss: a lighter top half over the gradient.
    static var navGradient: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [navTop, navMid, navBottom], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
                .frame(height: 22)
        }
    }

    /// Vertical pinstripes, the grouped-table background of the time.
    struct Pinstripes: View {
        var body: some View {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(pinstripeBase))
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: 0, width: 3, height: size.height)), with: .color(pinstripeLine))
                    x += 7
                }
            }
        }
    }
}

/// A bar button of the time: a small bordered rounded rectangle, white bold text.
struct ClassicBarButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Classic.font(12, bold: true))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 0, y: -1)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    LinearGradient(colors: [Classic.hex(0x8EA2BD), Classic.hex(0x4D6789)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Classic.hex(0x3A4C66), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// The blue-grey bar with an embossed title.
struct ClassicNavBar: View {
    let title: String
    var left: (String, () -> Void)?
    var right: (String, () -> Void)?

    var body: some View {
        ZStack {
            Text(title)
                .font(Classic.font(20, bold: true))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 0, y: -1)
                .lineLimit(1)
                .padding(.horizontal, 80)
            HStack {
                if let left { ClassicBarButton(title: left.0, action: left.1) }
                Spacer()
                if let right { ClassicBarButton(title: right.0, action: right.1) }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(Classic.navGradient.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Classic.navLine.frame(height: 1) }
    }
}

/// The price button: FREE, and on the first tap a green INSTALL that the second tap confirms — as the store did it.
struct ClassicPriceButton: View {
    let enabled: Bool
    let armed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(armed ? "INSTALL" : "FREE")
                .font(Classic.font(11, bold: true))
                .foregroundStyle(armed ? .white : Classic.priceText)
                .shadow(color: armed ? .black.opacity(0.35) : .clear, radius: 0, y: -1)
                .padding(.horizontal, armed ? 10 : 12)
                .frame(height: 24)
                .background {
                    if armed {
                        LinearGradient(colors: [Classic.installTop, Classic.installBottom], startPoint: .top, endPoint: .bottom)
                    } else {
                        LinearGradient(colors: [.white, Classic.priceFill], startPoint: .top, endPoint: .bottom)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(armed ? Classic.hex(0x2E7A20) : Classic.priceBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.15), value: armed)
    }
}

// MARK: - Legacy Store View

struct LegacyStoreView: View {
    @StateObject private var store = LegacyStoreClient()
    /// The running device's agent; nil when no device is running (the store can still be browsed).
    let agent: GuestAgent?
    let target: StoreTarget
    let onDismiss: () -> Void

    enum Tab: Hashable { case featured, top, search }

    @State private var tab: Tab = .featured
    @State private var busy: Int?  // the ipa_id being downloaded or installed
    @State private var progress: Double = 0
    @State private var message = ""
    @State private var messageIsGood = false
    @State private var details: CatalogApp?
    @State private var armed: Int?  // the row whose FREE has turned into INSTALL
    @State private var suggested: [CatalogApp] = []

    var body: some View {
        VStack(spacing: 0) {
            ClassicNavBar(title: title, left: nil, right: ("Done", onDismiss))
            if tab == .search { searchBar }
            if agent == nil {
                notice("Start a device to install apps. You can browse meanwhile.")
            }
            content
            if busy != nil || !message.isEmpty { statusStrip }
            tabBar
        }
        .background(Color.white.ignoresSafeArea())
        .environment(\.colorScheme, .light)
        .onAppear {
            store.target = target
            store.search()
        }
        .onChange(of: store.results.map(\.ipaID)) { _ in
            if store.query.isEmpty { suggested = store.results }
        }
        .sheet(item: $details) { app in
            AppVersionsView(app: app, store: store, canInstall: agent != nil && busy == nil) { copy in
                details = nil
                install(copy)
            }
        }
    }

    private var title: String {
        switch tab {
        case .featured: return "Featured"
        case .top: return "Top 25"
        case .search: return "Search"
        }
    }

    // MARK: Pieces

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Classic.rowDetail)
            TextField("Search apps for \(target.name)", text: $store.query)
                .textFieldStyle(.plain)
                .font(Classic.font(15))
                .foregroundStyle(.black)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { store.search() }
                .onChange(of: store.query) { _ in store.search() }
            if !store.query.isEmpty {
                Button { store.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Classic.hex(0xA8A8A8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.white, in: Capsule())
        .overlay(Capsule().stroke(Classic.hex(0x8796AA), lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(LinearGradient(colors: [Classic.searchTop, Classic.searchBottom], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .bottom) { Classic.hex(0x8796AA).frame(height: 1) }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(Classic.font(12, bold: true))
            .foregroundStyle(Classic.hex(0x4C566C))
            .shadow(color: .white.opacity(0.8), radius: 0, y: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Classic.hex(0xDDE3EA))
            .overlay(alignment: .bottom) { Classic.separator.frame(height: 1) }
    }

    private var rows: [CatalogApp] {
        switch tab {
        case .featured: return suggested.isEmpty ? store.results : suggested
        case .top: return Array((suggested.isEmpty ? store.results : suggested).filter(\.isCompatible).prefix(25))
        case .search: return store.query.isEmpty ? [] : store.results
        }
    }

    @ViewBuilder private var content: some View {
        if store.isLoading && rows.isEmpty {
            centred { ProgressView().tint(Classic.rowDetail) }
        } else if let error = store.error, rows.isEmpty {
            centred {
                VStack(spacing: 10) {
                    Text(error).font(Classic.font(14)).foregroundStyle(Classic.rowDetail).multilineTextAlignment(.center)
                    ClassicBarButton(title: "Retry") { store.search() }
                }
                .padding(.horizontal, 30)
            }
        } else if tab == .search && store.query.isEmpty {
            centred {
                Text("Search for apps that run on \(target.name), \(target.os).")
                    .font(Classic.font(15, bold: true))
                    .foregroundStyle(Classic.hex(0x9AA3AE))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
        } else if rows.isEmpty {
            centred {
                Text(tab == .search ? "No Results" : "Nothing to show yet.")
                    .font(Classic.font(18, bold: true))
                    .foregroundStyle(Classic.hex(0x9AA3AE))
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, app in
                        appRow(app, rank: tab == .top ? index + 1 : nil, shaded: index % 2 == 1)
                    }
                }
            }
            .background(Color.white)
        }
    }

    private func centred<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }.frame(maxWidth: .infinity).background(Color.white)
    }

    private func appRow(_ app: CatalogApp, rank: Int?, shaded: Bool) -> some View {
        HStack(spacing: 10) {
            Button { details = app } label: {
                HStack(spacing: 10) {
                    if let rank {
                        Text("\(rank)")
                            .font(Classic.font(15, bold: true))
                            .foregroundStyle(Classic.rowDetail)
                            .frame(width: 24, alignment: .trailing)
                    }
                    StoreIcon(url: app.iconURL, size: 57)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .font(Classic.font(15, bold: true))
                            .foregroundStyle(app.isCompatible ? Classic.rowText : Classic.rowText.opacity(0.4))
                            .lineLimit(2)
                        Text(app.developer ?? "")
                            .font(Classic.font(12))
                            .foregroundStyle(Classic.rowDetail)
                            .lineLimit(1)
                        if !app.isCompatible {
                            Text(app.subtitle).font(Classic.font(11)).foregroundStyle(Classic.warning).lineLimit(1)
                        } else {
                            let facts = [app.version.map { "Version \($0)" }, app.size.map { Transfer.format($0) }].compactMap { $0 }
                            Text(facts.joined(separator: "  \u{00B7}  "))
                                .font(Classic.font(11))
                                .foregroundStyle(Classic.rowDetail)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if busy == app.ipaID {
                VStack(spacing: 4) {
                    ProgressView(value: progress).frame(width: 60).tint(Classic.hex(0x3D6EBF))
                    Text(progress < 0.999 ? "Loading" : "Installing").font(Classic.font(10)).foregroundStyle(Classic.rowDetail)
                }
            } else if app.isCompatible {
                ClassicPriceButton(enabled: agent != nil && busy == nil, armed: armed == app.ipaID) {
                    if armed == app.ipaID {
                        armed = nil
                        install(app)
                    } else {
                        armed = app.ipaID
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(shaded ? Classic.hex(0xF4F5F7) : Color.white)
        .overlay(alignment: .bottom) { Classic.separator.frame(height: 1) }
    }

    /// What is downloading or installing, and the last result, above the tab bar like the store's download strip.
    private var statusStrip: some View {
        HStack(spacing: 8) {
            if busy != nil {
                ProgressView().tint(.white).scaleEffect(0.8)
            } else {
                Image(systemName: messageIsGood ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(messageIsGood ? Classic.installTop : Classic.hex(0xF0A050))
            }
            Text(message)
                .font(Classic.font(12, bold: true))
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Classic.hex(0x26303D).opacity(0.95))
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabItem(.featured, "Featured", "star.fill")
            tabItem(.top, "Top 25", "list.number")
            tabItem(.search, "Search", "magnifyingglass")
        }
        .frame(height: 49)
        .background(
            ZStack(alignment: .top) {
                LinearGradient(colors: [Classic.tabTop, Classic.tabBottom], startPoint: .top, endPoint: .bottom)
                Color.white.opacity(0.06).frame(height: 24)
            }
            .ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Color.black.frame(height: 1) }
    }

    private func tabItem(_ which: Tab, _ label: String, _ symbol: String) -> some View {
        let selected = tab == which
        return Button {
            tab = which
            armed = nil
            if which != .search, !store.query.isEmpty {
                store.query = ""
                store.search()
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(selected
                        ? AnyShapeStyle(LinearGradient(colors: [Classic.hex(0xD8F0FF), Classic.hex(0x2E9BF0)], startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(Classic.tabIdle))
                Text(label)
                    .font(Classic.font(10, bold: true))
                    .foregroundStyle(selected ? Color.white : Classic.tabIdle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? Color.white.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
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
                let installed = try await agent.installApp(ipa: file) { fraction, status in
                    Task { @MainActor in
                        progress = fraction
                        message = status
                    }
                }
                messageIsGood = true
                message = installed.needsRestart
                    ? "\(installed.name) is installed. Restart the device to see its icon."
                    : "\(installed.name) is installed. Find it on the Home screen."
            } catch {
                message = error is CancellationError ? "Cancelled." : error.localizedDescription
            }
        }
    }
}

/// An app icon as the store drew it: rounded, with the gloss across its top half.
struct StoreIcon: View {
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Classic.hex(0xE6E9ED), Classic.hex(0xC9CED6)], startPoint: .top, endPoint: .bottom)
                    .overlay(Image(systemName: "app").foregroundStyle(Classic.hex(0x9AA3AE)))
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .top) {
            // The gloss: a soft white ellipse over the top half.
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 1.5, height: size * 0.9)
                .offset(y: -size * 0.38)
        }
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous).stroke(.black.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1.5)
    }
}

// MARK: - The app's page: its versions

/// One app's page: the header the store showed, then every archived version on pinstripes. Pick the one to
/// install: an older version often runs where the newest one needs a newer system.
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
    @State private var armed: String?

    var body: some View {
        VStack(spacing: 0) {
            ClassicNavBar(title: "Info", left: ("Back", { dismiss() }), right: nil)
            ScrollView {
                VStack(spacing: 14) {
                    header
                    if loading {
                        ProgressView().tint(Classic.rowDetail).padding(.top, 30)
                    } else if let error {
                        group {
                            Text(error).font(Classic.font(13)).foregroundStyle(Classic.warning).padding(12)
                        }
                        ClassicBarButton(title: "Retry") { load() }
                    } else if versions.isEmpty {
                        Text("The archive lists no versions for this app.")
                            .font(Classic.font(14, bold: true))
                            .foregroundStyle(Classic.hex(0x4C566C))
                            .shadow(color: .white.opacity(0.7), radius: 0, y: 1)
                    } else {
                        sectionTitle("Versions")
                        ForEach(versions) { version in versionGroup(version) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
            .background(Classic.Pinstripes().ignoresSafeArea())
        }
        .environment(\.colorScheme, .light)
        .onAppear { load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            StoreIcon(url: app.iconURL, size: 57)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(Classic.font(17, bold: true)).foregroundStyle(.black).lineLimit(2)
                if let developer = app.developer {
                    Text(developer).font(Classic.font(13)).foregroundStyle(Classic.hex(0x4C566C))
                }
                Text("For \(store.target.name), iPhone OS \(store.target.os)")
                    .font(Classic.font(11))
                    .foregroundStyle(Classic.rowDetail)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Classic.groupBorder, lineWidth: 1))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Classic.font(17, bold: true))
            .foregroundStyle(Classic.hex(0x4C566C))
            .shadow(color: .white.opacity(0.8), radius: 0, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
    }

    private func group<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack(spacing: 0) { inner() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Classic.groupBorder, lineWidth: 1))
    }

    private func versionGroup(_ version: CatalogVersion) -> some View {
        group {
            HStack {
                Text("Version \(version.version ?? "unknown")").font(Classic.font(15, bold: true)).foregroundStyle(.black)
                Spacer()
                if let minimum = version.minimumOSVersion, !minimum.isEmpty {
                    Text("Requires \(minimum)").font(Classic.font(12)).foregroundStyle(Classic.hex(0x385487))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            if version.copies.isEmpty {
                Classic.separator.frame(height: 1)
                Text("No archived copy").font(Classic.font(13)).foregroundStyle(Classic.rowDetail).padding(12)
            }
            ForEach(version.copies) { copy in
                Classic.separator.frame(height: 1)
                copyRow(copy, of: version)
            }
        }
    }

    private func copyRow(_ copy: CatalogVersion.Copy, of version: CatalogVersion) -> some View {
        let problem = store.target.problem(with: copy, minimumOS: version.minimumOSVersion)
        var facts: [String] = []
        if let size = copy.size { facts.append(Transfer.format(size)) }
        if let archs = copy.architectures, !archs.isEmpty { facts.append(archs.joined(separator: ", ")) }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(facts.isEmpty ? "Archived copy" : facts.joined(separator: "  \u{00B7}  "))
                    .font(Classic.font(13))
                    .foregroundStyle(problem == nil ? Color.black : Classic.rowDetail)
                if let problem {
                    Text(problem).font(Classic.font(11)).foregroundStyle(Classic.warning)
                }
            }
            Spacer(minLength: 0)
            if resolving == copy.ipaID {
                ProgressView().tint(Classic.rowDetail)
            } else if problem == nil {
                ClassicPriceButton(enabled: canInstall && resolving == nil, armed: armed == copy.ipaID) {
                    if armed == copy.ipaID {
                        armed = nil
                        choose(copy)
                    } else {
                        armed = copy.ipaID
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
