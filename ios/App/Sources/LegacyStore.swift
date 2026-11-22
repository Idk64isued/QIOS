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
    func copy(ipaID: String) async throws -> CatalogApp {
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
/// detail page.
///
/// That look only ever came in one shade, and the store was pinned to light to keep it honest. A white page in a
/// dark room at two in the morning is its own kind of wrong, though, so every colour here is a pair now and the
/// store picks between them (the moon button in its top bar). The light side is unchanged, to the hex digit; the
/// dark side keeps the same shapes, glosses and borders and only swaps what they are made of, so it still reads as
/// this store rather than a modern one. It follows a switch of its own, never this phone's appearance: someone
/// running their whole phone dark may still want the store the way it was.
enum Classic {
    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
    /// A colour that resolves to `light` or `dark` with the colour scheme the store is being drawn in.
    static func c(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
    private static func ui(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    static let navTop = c(0xB2BFD0, 0x5A5C62)
    static let navMid = c(0x8A9DB8, 0x2C2D31)
    static let navBottom = c(0x6D84A2, 0x0E0F11)
    static let navLine = c(0x2D3642, 0x000000)
    static let barButtonTop = c(0x8EA2BD, 0x5C5E64)
    static let barButtonBottom = c(0x4D6789, 0x202125)
    static let barButtonBorder = c(0x3A4C66, 0x000000)
    static let searchTop = c(0xCDD5DF, 0x3A3C42)
    static let searchBottom = c(0xA5B3C5, 0x232429)
    static let rowText = c(0x000000, 0xFFFFFF)
    static let rowDetail = c(0x7A7A7A, 0xB4B8C0)
    static let separator = c(0xE0E0E0, 0x3A3C42)
    static let priceText = c(0x3B5A82, 0xB4CCEC)
    static let priceFill = c(0xE3E9F1, 0x3A3C42)
    static let priceBorder = c(0x8EA0B5, 0x5A5C62)
    static let installTop = c(0x7AD35A, 0x6CC955)
    static let installBottom = c(0x3D9A2B, 0x2E7A20)
    static let pinstripeBase = c(0xC5CCD4, 0x18191D)
    static let pinstripeLine = c(0xCBD2D8, 0x1D1E23)
    static let groupBorder = c(0xABABAB, 0x0B0C0E)
    static let tabTop = c(0x3B3B3B, 0x303033)
    static let tabBottom = c(0x0B0B0B, 0x000000)
    static let tabIdle = c(0x8F8F8F, 0x8F8F8F)
    static let warning = c(0xB23B2B, 0xF0675C)
    /// The page behind the rows, and a row itself: white then, near-black now.
    static let page = c(0xFFFFFF, 0x121317)
    static let cell = c(0xFFFFFF, 0x2A2C31)
    /// Every other row in a list, a shade off the one above it.
    static let cellAlt = c(0xF4F5F7, 0x232429)
    static let link = c(0x3D6EBF, 0x6FA0E8)
    static let header = c(0x4C566C, 0xBCC3CE)
    static let detail = c(0x385487, 0xA8C0E4)
    static let bodyText = c(0x333333, 0xDDE0E5)
    static let chevron = c(0xB0B6BE, 0x8A8E96)
    static let faint = c(0x9AA3AE, 0x9499A2)
    static let fieldBorder = c(0x8796AA, 0x4A4C52)
    static let sectionBack = c(0xDDE3EA, 0x25272C)
    static let sectionBackLight = c(0xEEF1F5, 0x1C1D22)
    static let segmentBottom = c(0xE3E7EC, 0x2D2F34)
    static let placeholderTop = c(0xE6E9ED, 0x35373D)
    static let placeholderBottom = c(0xC9CED6, 0x25272C)
    static let shotPlaceholder = c(0xDDE2E8, 0x2D2F34)
    static let chartHeader = c(0x2E3D52, 0xB6BDC8)
    static let clearField = c(0xA8A8A8, 0x707479)

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
                    LinearGradient(colors: [Classic.barButtonTop, Classic.barButtonBottom], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Classic.barButtonBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// The blue-grey bar with an embossed title.
struct ClassicNavBar: View {
    let title: String
    var left: (String, () -> Void)?
    var right: (String, () -> Void)?
    /// The store's own light/dark switch, drawn as a moon beside the right-hand button. Only the store's top bar
    /// passes one; the pages below it inherit the choice and don't repeat the control.
    var dark: Binding<Bool>?

    var body: some View {
        ZStack {
            Text(title)
                .font(Classic.font(20, bold: true))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 0, y: -1)
                .lineLimit(1)
                .padding(.horizontal, 96)
            HStack(spacing: 6) {
                if let left { ClassicBarButton(title: left.0, action: left.1) }
                Spacer()
                if let dark {
                    Button {
                        dark.wrappedValue.toggle()
                    } label: {
                        Image(systemName: dark.wrappedValue ? "sun.max.fill" : "moon.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 0, y: -1)
                            .frame(width: 32, height: 30)
                            .background(
                                LinearGradient(colors: [Classic.barButtonTop, Classic.barButtonBottom],
                                               startPoint: .top, endPoint: .bottom),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Classic.barButtonBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(dark.wrappedValue ? "Light store" : "Dark store"))
                }
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
    /// In place of FREE / INSTALL (the Downloads tab's INSTALL AGAIN).
    var title: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title ?? (armed ? "INSTALL" : "FREE"))
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
                        .stroke(armed ? Classic.installBottom : Classic.priceBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.15), value: armed)
    }
}

// MARK: - Legacy Store View

/// The store, as iPhone OS 3's App Store was laid out: Featured, the charts as they stood on a given day, Categories
/// and Search, each app with its own page (screenshots, ratings, reviews, every archived version). Full screen.
struct LegacyStoreView: View {
    /// Legacy Store ▸ the moon in the top bar. Its own switch, not this phone's appearance.
    @AppStorage("storeDark") private var storeDark = false
    @StateObject private var store = LegacyStoreClient()
    @ObservedObject private var downloads = StoreDownloads.shared
    /// The running device's agent; nil when no device is running (the store can still be browsed).
    let agent: GuestAgent?
    let target: StoreTarget
    let onDismiss: () -> Void

    enum Tab: Hashable { case featured, charts, categories, search, downloads }
    enum FeaturedPart: Hashable { case forDevice, collections }

    /// A list opened from Featured or Categories.
    struct Drill: Identifiable {
        let id = UUID()
        let title: String
        var apps: [StoreApp]
        var loading = true
        var error: String?
    }

    @State private var tab: Tab = .featured
    @State private var featuredPart: FeaturedPart = .forDevice
    @State private var message = ""
    @State private var armed: Int?  // the row whose FREE has turned into INSTALL
    @State private var suggested: [CatalogApp] = []
    @State private var page: StoreApp?
    @State private var drill: Drill?

    // Charts
    @State private var chartTypes: [ChartType] = ChartType.defaults
    @State private var chartType = "top-free"
    @State private var chart: StoreChart?
    @State private var chartDate = LegacyStoreView.fifteenYearsAgo()
    @State private var chartLoading = false
    @State private var chartError: String?
    @State private var pickingDate = false

    // Featured collections and categories
    @State private var collections: [StoreCollection] = []
    @State private var genres: [StoreGenre] = []
    @State private var listError: String?

    var body: some View {
        VStack(spacing: 0) {
            ClassicNavBar(title: title, left: backButton, right: ("Done", onDismiss), dark: $storeDark)
            if tab == .search && drill == nil { searchBar }
            if agent == nil && tab != .downloads {
                notice("No device is running: apps you get are downloaded, ready to install from Downloads.")
            }
            Group {
                if let drill {
                    appList(drill)
                } else {
                    switch tab {
                    case .featured: featured
                    case .charts: charts
                    case .categories: categories
                    case .search: searchResults
                    case .downloads: StoreDownloadsList(downloads: downloads, agent: agent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !message.isEmpty || (downloads.activeCount > 0 && tab != .downloads) { statusStrip }
            tabBar
        }
        .background(Classic.page.ignoresSafeArea())
        .environment(\.colorScheme, storeDark ? .dark : .light)
        .onAppear {
            store.target = target
            store.search()
        }
        .onChange(of: store.results.map(\.ipaID)) { _ in
            if store.query.isEmpty { suggested = store.results }
        }
        .fullScreenCover(item: $page) { app in
            StoreAppPage(app: app, store: store, canInstall: true) { copy in
                page = nil
                install(copy)
            } onClose: { page = nil }
        }
        .sheet(isPresented: $pickingDate) { datePicker }
    }

    private var backButton: (String, () -> Void)? {
        guard drill != nil else { return nil }
        return ("Back", { self.drill = nil })
    }

    private var title: String {
        if let drill { return drill.title }
        switch tab {
        case .featured: return "Featured"
        case .charts: return chart?.type.name ?? "Top Charts"
        case .categories: return "Categories"
        case .search: return "Search"
        case .downloads: return "Downloads"
        }
    }

    static func fifteenYearsAgo() -> String {
        let date = Calendar.current.date(byAdding: .year, value: -15, to: Date()) ?? Date()
        return Self.day(date)
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func pretty(_ day: String) -> String {
        guard let date = StoreAPI.date(day) else { return day }
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    // MARK: Featured

    @ViewBuilder private var featured: some View {
        VStack(spacing: 0) {
            ClassicSegments(items: [("For \(target.name)", FeaturedPart.forDevice), ("Collections", .collections)],
                            selection: $featuredPart)
            if featuredPart == .forDevice {
                catalogList(suggested.isEmpty ? store.results : suggested, ranked: false)
            } else if collections.isEmpty {
                centred {
                    if let listError { errorText(listError) { loadCollections() } } else { ProgressView().tint(Classic.rowDetail) }
                }
                .onAppear(perform: loadCollections)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(collections.enumerated()), id: \.element.id) { index, c in
                            Button { openCollection(c) } label: {
                                plainRow(title: c.title, subtitle: [c.series, c.count.map { "\($0) apps" }].compactMap { $0 }.joined(separator: " \u{00B7} "),
                                         shaded: index % 2 == 1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func loadCollections() {
        listError = nil
        Task {
            do { collections = try await StoreAPI.collections() } catch { listError = error.localizedDescription }
        }
    }

    private func openCollection(_ c: StoreCollection) {
        drill = Drill(title: c.title, apps: [])
        Task {
            do {
                let apps = try await StoreAPI.collection(c.slug)
                if drill?.title == c.title { drill?.apps = apps; drill?.loading = false }
            } catch {
                drill?.loading = false
                drill?.error = error.localizedDescription
            }
        }
    }

    // MARK: Charts

    @ViewBuilder private var charts: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chartTypes) { t in
                        Button {
                            chartType = t.slug
                            loadChart()
                        } label: {
                            Text(t.name)
                                .font(Classic.font(12, bold: true))
                                .foregroundStyle(chartType == t.slug ? .white : Classic.header)
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(chartType == t.slug
                                    ? AnyShapeStyle(LinearGradient(colors: [Classic.hex(0x6D84A2), Classic.hex(0x4A6589)], startPoint: .top, endPoint: .bottom))
                                    : AnyShapeStyle(Classic.cell), in: Capsule())
                                .overlay(Capsule().stroke(Classic.fieldBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
            }
            .background(LinearGradient(colors: [Classic.searchTop, Classic.searchBottom], startPoint: .top, endPoint: .bottom))
            dateBar
            if chartLoading && chart == nil {
                centred { ProgressView().tint(Classic.rowDetail) }
            } else if let chartError, chart == nil {
                centred { errorText(chartError) { loadChart() } }
            } else if let chart {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(chart.entries) { entry in
                            Button { page = entry.app } label: { chartRow(entry) }
                                .buttonStyle(.plain)
                        }
                        Text("Titles in grey haven\u{2019}t been preserved in the archive yet. Charts from the archive of Legacy Store.")
                            .font(Classic.font(11))
                            .foregroundStyle(Classic.rowDetail)
                            .multilineTextAlignment(.center)
                            .padding(16)
                    }
                }
            }
        }
        .onAppear {
            if chart == nil { loadChart() }
            Task { chartTypes = await StoreAPI.chartTypes() }
        }
    }

    private var dateBar: some View {
        let dates = chart?.availableDates ?? []
        let index = chart.flatMap { c in dates.firstIndex(of: c.snapshotDate) }
        return HStack {
            Button { step(-1) } label: { Image(systemName: "arrowtriangle.backward.fill") }
                .disabled(index == nil || index == 0)
            Spacer()
            Button { pickingDate = true } label: {
                VStack(spacing: 1) {
                    Text(chart.map { Self.pretty($0.snapshotDate) } ?? Self.pretty(chartDate))
                        .font(Classic.font(15, bold: true))
                        .foregroundStyle(Classic.chartHeader)
                    Text("Top 50 on this day \u{00B7} change").font(Classic.font(10)).foregroundStyle(Classic.rowDetail)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button { step(1) } label: { Image(systemName: "arrowtriangle.forward.fill") }
                .disabled(index == nil || index == dates.count - 1)
        }
        .font(.system(size: 16))
        .foregroundStyle(Classic.link)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Classic.sectionBackLight)
        .overlay(alignment: .bottom) { Classic.separator.frame(height: 1) }
    }

    private func step(_ by: Int) {
        guard let chart, let i = chart.availableDates.firstIndex(of: chart.snapshotDate) else { return }
        let j = i + by
        guard chart.availableDates.indices.contains(j) else { return }
        chartDate = chart.availableDates[j]
        loadChart()
    }

    private func loadChart() {
        chartLoading = true
        chartError = nil
        let type = chartType, date = chartDate
        Task {
            do {
                let c = try await StoreAPI.chart(type: type, date: date)
                if type == chartType { chart = c }
            } catch {
                chartError = error.localizedDescription
            }
            chartLoading = false
        }
    }

    /// Every archived day, newest year first, to pick one.
    private var datePicker: some View {
        let dates = chart?.availableDates ?? []
        let years = Dictionary(grouping: dates) { String($0.prefix(4)) }
        return VStack(spacing: 0) {
            ClassicNavBar(title: "Pick a Day", left: nil, right: ("Done", { pickingDate = false }))
            if dates.isEmpty {
                centred { Text("No dates yet. Load a chart first.").font(Classic.font(14)).foregroundStyle(Classic.rowDetail) }
            } else {
                List {
                    ForEach(years.keys.sorted(by: >), id: \.self) { year in
                        Section(year) {
                            ForEach((years[year] ?? []).sorted(by: >), id: \.self) { day in
                                Button {
                                    chartDate = day
                                    pickingDate = false
                                    loadChart()
                                } label: {
                                    HStack {
                                        Text(Self.pretty(day)).foregroundStyle(Classic.rowText)
                                        Spacer()
                                        if day == chart?.snapshotDate { Image(systemName: "checkmark").foregroundStyle(Classic.link) }
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.grouped)
            }
        }
        .environment(\.colorScheme, storeDark ? .dark : .light)
    }

    private func chartRow(_ entry: ChartEntry) -> some View {
        HStack(spacing: 10) {
            Text("\(entry.position)")
                .font(Classic.font(15, bold: true))
                .foregroundStyle(Classic.rowDetail)
                .frame(width: 26, alignment: .trailing)
            StoreIcon(url: entry.app.iconURL, size: 57)
                .opacity(entry.preserved ? 1 : 0.35)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.app.name)
                    .font(Classic.font(15, bold: true))
                    .foregroundStyle(entry.preserved ? Classic.rowText : Classic.rowDetail.opacity(0.7))
                    .lineLimit(2)
                if let developer = entry.app.developer {
                    Text(developer).font(Classic.font(12)).foregroundStyle(Classic.rowDetail).lineLimit(1)
                }
                if !entry.preserved {
                    Text("Not in the archive yet").font(Classic.font(11)).foregroundStyle(Classic.rowDetail.opacity(0.7))
                } else if let note = Compatibility.note(for: entry.app.id) {
                    Label(note.verdict.title, systemImage: note.verdict.symbol).font(Classic.font(11)).foregroundStyle(Classic.detail)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Classic.chevron)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(entry.position % 2 == 0 ? Classic.cellAlt : Classic.cell)
        .overlay(alignment: .bottom) { Classic.separator.frame(height: 1) }
    }

    // MARK: Categories

    @ViewBuilder private var categories: some View {
        if genres.isEmpty {
            centred {
                if let listError { errorText(listError) { loadGenres() } } else { ProgressView().tint(Classic.rowDetail) }
            }
            .onAppear(perform: loadGenres)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(genres.enumerated()), id: \.element.id) { index, g in
                        Button { openGenre(g) } label: {
                            plainRow(title: g.name, subtitle: g.count.map { "\($0) apps" } ?? "", shaded: index % 2 == 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func loadGenres() {
        listError = nil
        Task {
            do { genres = try await StoreAPI.genres() } catch { listError = error.localizedDescription }
        }
    }

    private func openGenre(_ g: StoreGenre) {
        drill = Drill(title: g.name, apps: [])
        Task {
            do {
                let apps = try await StoreAPI.apps(genre: g.id)
                if drill?.title == g.name { drill?.apps = apps; drill?.loading = false }
            } catch {
                drill?.loading = false
                drill?.error = error.localizedDescription
            }
        }
    }

    private func appList(_ drill: Drill) -> some View {
        Group {
            if drill.loading {
                centred { ProgressView().tint(Classic.rowDetail) }
            } else if let error = drill.error {
                centred { errorText(error) { self.drill = nil } }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(drill.apps.enumerated()), id: \.element.id) { index, app in
                            Button { page = app } label: { storeRow(app, shaded: index % 2 == 1) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Classic.rowDetail)
            TextField("Search apps for \(target.name)", text: $store.query)
                .textFieldStyle(.plain)
                .font(Classic.font(15))
                .foregroundStyle(Classic.rowText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { store.search() }
                .onChange(of: store.query) { _ in store.search() }
            if !store.query.isEmpty {
                Button { store.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Classic.clearField)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Classic.cell, in: Capsule())
        .overlay(Capsule().stroke(Classic.fieldBorder, lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(LinearGradient(colors: [Classic.searchTop, Classic.searchBottom], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .bottom) { Classic.fieldBorder.frame(height: 1) }
    }

    @ViewBuilder private var searchResults: some View {
        if store.query.isEmpty {
            centred {
                Text("Search for apps that run on \(target.name), \(target.os).")
                    .font(Classic.font(15, bold: true))
                    .foregroundStyle(Classic.faint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
        } else {
            catalogList(store.results, ranked: false)
        }
    }

    // MARK: Rows

    @ViewBuilder private func catalogList(_ rows: [CatalogApp], ranked: Bool) -> some View {
        if store.isLoading && rows.isEmpty {
            centred { ProgressView().tint(Classic.rowDetail) }
        } else if let error = store.error, rows.isEmpty {
            centred { errorText(error) { store.search() } }
        } else if rows.isEmpty {
            centred { Text("No Results").font(Classic.font(18, bold: true)).foregroundStyle(Classic.faint) }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, app in
                        appRow(app, rank: ranked ? index + 1 : nil, shaded: index % 2 == 1)
                    }
                }
            }
            .background(Classic.page)
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(Classic.font(12, bold: true))
            .foregroundStyle(Classic.header)
            .shadow(color: .white.opacity(0.8), radius: 0, y: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Classic.sectionBack)
            .overlay(alignment: .bottom) { Classic.separator.frame(height: 1) }
    }

    private func centred<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }.frame(maxWidth: .infinity).background(Classic.page)
    }

    private func errorText(_ text: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Text(text).font(Classic.font(14)).foregroundStyle(Classic.rowDetail).multilineTextAlignment(.center)
            ClassicBarButton(title: "Retry", action: retry)
        }
        .padding(.horizontal, 30)
    }

    private func plainRow(title: String, subtitle: String, shaded: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Classic.font(16, bold: true)).foregroundStyle(Classic.rowText)
                if !subtitle.isEmpty { Text(subtitle).font(Classic.font(12)).foregroundStyle(Classic.rowDetail) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Classic.chevron)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(shaded ? Classic.cellAlt : Classic.cell)
        .overlay(alignment: .bottom) { Classic.separator.frame(height: 1) }
        .contentShape(Rectangle())
    }

    private func storeRow(_ app: StoreApp, shaded: Bool) -> some View {
        HStack(spacing: 10) {
            StoreIcon(url: app.iconURL, size: 57)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(Classic.font(15, bold: true)).foregroundStyle(Classic.rowText).lineLimit(2)
                if let developer = app.developer { Text(developer).font(Classic.font(12)).foregroundStyle(Classic.rowDetail).lineLimit(1) }
                if let label = app.label {
                    Text(label).font(Classic.font(11)).foregroundStyle(Classic.detail).lineLimit(1)
                } else if let count = app.versionCount {
                    Text("\(count) archived versions").font(Classic.font(11)).foregroundStyle(Classic.rowDetail)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Classic.chevron)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(shaded ? Classic.cellAlt : Classic.cell)
        .overlay(alignment: .bottom) { Classic.separator.frame(height: 1) }
        .contentShape(Rectangle())
    }

    /// A row from the device-aware catalog: it knows whether the app runs here, so it has a price button.
    private func appRow(_ app: CatalogApp, rank: Int?, shaded: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                if let key = app.appURL?.lastPathComponent ?? app.bundleID {
                    page = StoreApp(["app_store_id": key, "name": app.name, "developer": app.developer as Any,
                                     "icon_url": app.iconURL?.absoluteString as Any])
                }
            } label: {
                HStack(spacing: 10) {
                    if let rank {
                        Text("\(rank)").font(Classic.font(15, bold: true)).foregroundStyle(Classic.rowDetail).frame(width: 24, alignment: .trailing)
                    }
                    StoreIcon(url: app.iconURL, size: 57)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .font(Classic.font(15, bold: true))
                            .foregroundStyle(app.isCompatible ? Classic.rowText : Classic.rowText.opacity(0.4))
                            .lineLimit(2)
                        Text(app.developer ?? "").font(Classic.font(12)).foregroundStyle(Classic.rowDetail).lineLimit(1)
                        if !app.isCompatible {
                            Text(app.subtitle).font(Classic.font(11)).foregroundStyle(Classic.warning).lineLimit(1)
                        } else {
                            let facts = [app.version.map { "Version \($0)" }, app.size.map { Transfer.format($0) }].compactMap { $0 }
                            Text(facts.joined(separator: "  \u{00B7}  ")).font(Classic.font(11)).foregroundStyle(Classic.rowDetail).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let active = downloads.activeEntry(ipaID: app.ipaID) {
                VStack(spacing: 4) {
                    ProgressView(value: min(1, max(0, active.progress))).frame(width: 60).tint(Classic.link)
                    Text(active.state == .waiting ? "Waiting" : active.state == .installing ? "Installing" : "Loading")
                        .font(Classic.font(10)).foregroundStyle(Classic.rowDetail)
                }
            } else if app.isCompatible {
                ClassicPriceButton(enabled: true, armed: armed == app.ipaID) {
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
        .background(shaded ? Classic.cellAlt : Classic.cell)
        .overlay(alignment: .bottom) { Classic.separator.frame(height: 1) }
    }

    /// What is downloading or installing, and the last word, above the tab bar like the store's download strip; a tap
    /// opens Downloads.
    private var statusStrip: some View {
        let active = downloads.entries.first { $0.state == .downloading || $0.state == .installing }
            ?? downloads.entries.first(where: \.isActive)
        return HStack(spacing: 8) {
            if let active {
                ProgressView().tint(.white).scaleEffect(0.8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(downloads.activeCount > 1 ? "\(active.name) and \(downloads.activeCount - 1) more" : active.name)
                        .font(Classic.font(12, bold: true)).foregroundStyle(.white).lineLimit(1)
                    Text(active.status).font(Classic.font(11)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
            } else {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Classic.hex(0xF0A050))
                Text(message).font(Classic.font(12, bold: true)).foregroundStyle(.white).lineLimit(3)
            }
            Spacer(minLength: 0)
            if active == nil {
                Button { message = "" } label: { Image(systemName: "xmark").foregroundStyle(.white.opacity(0.7)) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Classic.hex(0x26303D).opacity(0.95))
        .contentShape(Rectangle())
        .onTapGesture {
            if active != nil {
                tab = .downloads
                drill = nil
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabItem(.featured, "Featured", "star.fill")
            tabItem(.charts, "Top 50", "list.number")
            tabItem(.categories, "Categories", "square.grid.2x2.fill")
            tabItem(.search, "Search", "magnifyingglass")
            tabItem(.downloads, "Downloads", "arrow.down.circle.fill", badge: downloads.activeCount)
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

    private func tabItem(_ which: Tab, _ label: String, _ symbol: String, badge: Int = 0) -> some View {
        let selected = tab == which
        return Button {
            tab = which
            drill = nil
            armed = nil
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(selected
                        ? AnyShapeStyle(LinearGradient(colors: [Classic.hex(0xD8F0FF), Classic.hex(0x2E9BF0)], startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(Classic.tabIdle))
                Text(label).font(Classic.font(10, bold: true)).foregroundStyle(selected ? Color.white : Classic.tabIdle)
            }
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    // The red badge of the time: a glossy oval with a white rim.
                    Text("\(badge)")
                        .font(Classic.font(12, bold: true))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(
                            LinearGradient(colors: [Classic.hex(0xF26A5F), Classic.hex(0xC8160D)], startPoint: .top, endPoint: .bottom),
                            in: Capsule())
                        .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
                        .offset(x: -10, y: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? Color.white.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    /// Into the Downloads queue: downloaded, then installed on the running device if there is one.
    private func install(_ app: CatalogApp) {
        if !downloads.enqueue(app, store: store, agent: agent) {
            message = "\(app.name) is already downloading."
        } else {
            message = ""
        }
    }
}

/// The store's segmented control of the time.
struct ClassicSegments<T: Hashable>: View {
    let items: [(String, T)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let on = selection == item.1
                Button { selection = item.1 } label: {
                    Text(item.0)
                        .font(Classic.font(12, bold: true))
                        .foregroundStyle(on ? .white : Classic.header)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(on
                            ? AnyShapeStyle(LinearGradient(colors: [Classic.hex(0x6D84A2), Classic.hex(0x4A6589)], startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(LinearGradient(colors: [Classic.cell, Classic.segmentBottom], startPoint: .top, endPoint: .bottom)))
                }
                .buttonStyle(.plain)
                if index < items.count - 1 { Classic.fieldBorder.frame(width: 1, height: 28) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Classic.fieldBorder, lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [Classic.searchTop, Classic.searchBottom], startPoint: .top, endPoint: .bottom))
    }
}

/// Stars as the store drew them: five, filled to the average (halves included).
struct ClassicStars: View {
    let rating: Double
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { i in
                let fill = rating - Double(i)
                Image(systemName: fill >= 0.75 ? "star.fill" : fill >= 0.25 ? "star.leadinghalf.filled" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(Classic.hex(0xF0A030))
            }
        }
    }
}

// MARK: - The app's page

/// One app's page, like the store's: the header with its rating and price button, archived screenshots (by the
/// version they were captured for), the description, information, customer reviews, every archived version, and a
/// place to note how it ran here.
struct StoreAppPage: View {
    @AppStorage("storeDark") private var storeDark = false
    let app: StoreApp
    @ObservedObject var store: LegacyStoreClient
    let canInstall: Bool
    let onInstall: (CatalogApp) -> Void
    let onClose: () -> Void

    @State private var detail: StoreAppDetail?
    @State private var screenshots: [ScreenshotSet] = []
    @State private var shotSet = 0
    @State private var ratings: [RatingCapture] = []
    @State private var reviews: [StoreReview] = []
    @State private var error: String?
    @State private var resolving: String?
    @State private var armed: String?
    @State private var headerArmed = false
    @State private var moreText = false
    @State private var reporting = false
    @State private var myNote: CompatibilityNote?

    private var shown: StoreApp { detail?.app ?? app }

    /// The newest copy this device can run, with its version.
    private var best: (version: CatalogVersion, copy: CatalogVersion.Copy)? {
        for v in detail?.versions ?? [] {
            for c in v.copies where store.target.problem(with: c, minimumOS: v.minimumOSVersion) == nil { return (v, c) }
        }
        return nil
    }

    /// The last capture that has an average.
    private var rating: RatingCapture? { ratings.last { $0.average != nil } ?? ratings.last }

    var body: some View {
        VStack(spacing: 0) {
            ClassicNavBar(title: "Info", left: ("Back", onClose), right: nil)
            ScrollView {
                VStack(spacing: 14) {
                    header
                    if let error {
                        Text(error).font(Classic.font(13)).foregroundStyle(Classic.warning).padding(8)
                    }
                    if !screenshots.isEmpty { screenshotSection }
                    if let text = detail?.description, !text.isEmpty { descriptionSection(text) }
                    informationSection
                    if !reviews.isEmpty { reviewsSection }
                    if let versions = detail?.versions, !versions.isEmpty {
                        sectionTitle("All versions")
                        ForEach(versions) { version in versionGroup(version) }
                    } else if detail == nil && error == nil {
                        ProgressView().tint(Classic.rowDetail).padding(.top, 20)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
            .background(Classic.Pinstripes().ignoresSafeArea())
        }
        .environment(\.colorScheme, storeDark ? .dark : .light)
        .task { await load() }
        .sheet(isPresented: $reporting) {
            CompatibilityReportView(app: shown, version: best?.version.version ?? detail?.versions.first?.version ?? "?",
                                    device: "\(store.target.name), \(store.target.os)") { saved in
                reporting = false
                if let saved { myNote = saved }
            }
        }
    }

    private func load() async {
        myNote = Compatibility.note(for: app.id)
        do { detail = try await StoreAPI.detail(app.id) } catch { self.error = error.localizedDescription }
        async let shots = StoreAPI.screenshots(app.id)
        async let rates = StoreAPI.ratings(app.id)
        async let revs = StoreAPI.reviews(app.id)
        screenshots = await shots
        ratings = await rates
        reviews = await revs
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                StoreIcon(url: shown.iconURL, size: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text(shown.name).font(Classic.font(17, bold: true)).foregroundStyle(Classic.rowText).lineLimit(3)
                    if let developer = shown.developer {
                        Text(developer).font(Classic.font(13)).foregroundStyle(Classic.header)
                    }
                    if let r = rating, let average = r.average {
                        HStack(spacing: 4) {
                            ClassicStars(rating: average)
                            if let count = r.count {
                                Text("\(count.formatted()) ratings").font(Classic.font(11)).foregroundStyle(Classic.rowDetail)
                            }
                        }
                    } else if let r = rating, let count = r.count {
                        Text("\(count.formatted()) ratings").font(Classic.font(11)).foregroundStyle(Classic.rowDetail)
                    }
                    if let best {
                        Text("Version \(best.version.version ?? "?") runs on \(store.target.name)")
                            .font(Classic.font(11)).foregroundStyle(Classic.detail)
                    } else if detail != nil {
                        Text("No archived copy runs on \(store.target.name), \(store.target.os)")
                            .font(Classic.font(11)).foregroundStyle(Classic.warning)
                    }
                }
                Spacer(minLength: 0)
                if let best {
                    if resolving == best.copy.ipaID {
                        ProgressView().tint(Classic.rowDetail)
                    } else {
                        ClassicPriceButton(enabled: canInstall && resolving == nil, armed: headerArmed) {
                            if headerArmed {
                                headerArmed = false
                                choose(best.copy)
                            } else {
                                headerArmed = true
                            }
                        }
                    }
                }
            }
            Classic.separator.frame(height: 1)
            HStack {
                if let myNote {
                    Label("You said: \(myNote.verdict.title)", systemImage: myNote.verdict.symbol)
                        .font(Classic.font(12, bold: true)).foregroundStyle(Classic.detail)
                } else {
                    Text("Tried it? Say how it runs.").font(Classic.font(12)).foregroundStyle(Classic.rowDetail)
                }
                Spacer()
                ClassicBarButton(title: myNote == nil ? "Report" : "Update") { reporting = true }
            }
        }
        .padding(12)
        .background(Classic.cell, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Classic.groupBorder, lineWidth: 1))
    }

    private var screenshotSection: some View {
        let set = screenshots[min(shotSet, screenshots.count - 1)]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Screenshots")
                Spacer()
                if screenshots.count > 1 {
                    Menu {
                        ForEach(Array(screenshots.enumerated()), id: \.element.id) { index, s in
                            Button(s.title.isEmpty ? "Set \(index + 1)" : s.title) { shotSet = index }
                        }
                    } label: {
                        Label(set.title.isEmpty ? "Other captures" : set.title, systemImage: "chevron.up.chevron.down")
                            .font(Classic.font(12, bold: true))
                            .foregroundStyle(Classic.link)
                    }
                    .padding(.trailing, 10)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(set.shots, id: \.url) { shot in
                        let height: CGFloat = 320
                        let width = height * CGFloat(shot.width) / CGFloat(max(shot.height, 1))
                        AsyncImage(url: shot.url) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fit)
                            } else {
                                Rectangle().fill(Classic.shotPlaceholder).overlay(ProgressView().tint(Classic.rowDetail))
                            }
                        }
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Classic.groupBorder, lineWidth: 1))
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func descriptionSection(_ text: String) -> some View {
        group {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(Classic.font(13))
                    .foregroundStyle(Classic.bodyText)
                    .lineLimit(moreText ? nil : 5)
                if !moreText && text.count > 220 {
                    Button("More \u{25BE}") { moreText = true }
                        .font(Classic.font(13, bold: true))
                        .foregroundStyle(Classic.link)
                }
            }
            .padding(12)
        }
    }

    private var informationSection: some View {
        let f = DateFormatter()
        f.dateStyle = .medium
        var rows: [(String, String)] = []
        if let price = detail?.price { rows.append(("Price", price)) }
        if let genre = detail?.genre { rows.append(("Category", genre)) }
        if let released = detail?.released { rows.append(("Released", f.string(from: released))) }
        if let count = detail?.versionCount ?? detail?.versions.count { rows.append(("Versions", "\(count) archived")) }
        if let best {
            if let minimum = best.version.minimumOSVersion, !minimum.isEmpty { rows.append(("Requires", "iPhone OS \(minimum) or later")) }
            if let size = best.copy.size { rows.append(("Size", Transfer.format(size))) }
        }
        if let bundle = shown.bundleID { rows.append(("Bundle ID", bundle)) }
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Information")
            group {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Classic.separator.frame(height: 1) }
                    HStack(alignment: .top) {
                        Text(row.0).font(Classic.font(13, bold: true)).foregroundStyle(Classic.header).frame(width: 90, alignment: .leading)
                        Text(row.1).font(Classic.font(13)).foregroundStyle(Classic.rowText)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }
        }
    }

    private var reviewsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Customer Reviews")
            group {
                ForEach(Array(reviews.prefix(12).enumerated()), id: \.element.id) { index, review in
                    if index > 0 { Classic.separator.frame(height: 1) }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(review.title.isEmpty ? "Review" : review.title).font(Classic.font(13, bold: true)).foregroundStyle(Classic.rowText)
                            Spacer()
                            ClassicStars(rating: Double(review.stars), size: 11)
                        }
                        if let author = review.author {
                            Text("by \(author)").font(Classic.font(11)).foregroundStyle(Classic.rowDetail)
                        }
                        Text(review.body).font(Classic.font(12)).foregroundStyle(Classic.bodyText)
                    }
                    .padding(12)
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Classic.font(17, bold: true))
            .foregroundStyle(Classic.header)
            .shadow(color: .white.opacity(0.8), radius: 0, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
    }

    private func group<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 0) { inner() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Classic.cell, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Classic.groupBorder, lineWidth: 1))
    }

    private func versionGroup(_ version: CatalogVersion) -> some View {
        group {
            HStack {
                Text("Version \(version.version ?? "unknown")").font(Classic.font(15, bold: true)).foregroundStyle(Classic.rowText)
                Spacer()
                if let minimum = version.minimumOSVersion, !minimum.isEmpty {
                    Text("Requires \(minimum)").font(Classic.font(12)).foregroundStyle(Classic.detail)
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
                    .foregroundStyle(problem == nil ? Classic.rowText : Classic.rowDetail)
                if let problem { Text(problem).font(Classic.font(11)).foregroundStyle(Classic.warning) }
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

    private func choose(_ copy: CatalogVersion.Copy) {
        resolving = copy.ipaID
        Task {
            do {
                let resolved = try await store.copy(ipaID: copy.ipaID)
                resolving = nil
                onInstall(resolved)
            } catch {
                resolving = nil
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Saying how an app ran

struct CompatibilityReportView: View {
    @AppStorage("storeDark") private var storeDark = false
    let app: StoreApp
    let version: String
    let device: String
    let onDone: (CompatibilityNote?) -> Void

    @Environment(\.openURL) private var openURL
    @State private var verdict: CompatibilityNote.Verdict = .works
    @State private var note = ""

    var body: some View {
        VStack(spacing: 0) {
            ClassicNavBar(title: "How It Runs", left: ("Cancel", { onDone(nil) }), right: ("Save", save))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        StoreIcon(url: app.iconURL, size: 44)
                        VStack(alignment: .leading) {
                            Text(app.name).font(Classic.font(15, bold: true)).foregroundStyle(Classic.rowText)
                            Text("Version \(version) on \(device)").font(Classic.font(12)).foregroundStyle(Classic.rowDetail)
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(CompatibilityNote.Verdict.allCases, id: \.self) { v in
                            Button { verdict = v } label: {
                                HStack {
                                    Label(v.title, systemImage: v.symbol).font(Classic.font(15)).foregroundStyle(Classic.rowText)
                                    Spacer()
                                    if verdict == v { Image(systemName: "checkmark").foregroundStyle(Classic.link) }
                                }
                                .padding(12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if v != CompatibilityNote.Verdict.allCases.last { Classic.separator.frame(height: 1) }
                        }
                    }
                    .background(Classic.cell, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Classic.groupBorder, lineWidth: 1))
                    Text("What did you see?").font(Classic.font(14, bold: true)).foregroundStyle(Classic.header)
                    TextEditor(text: $note)
                        .frame(minHeight: 100)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Classic.cell, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Classic.groupBorder, lineWidth: 1))
                    Text("Saved on this phone, shown on the app\u{2019}s page and in the store\u{2019}s lists, and included in every report you send. Legacy Store itself takes no submissions, so to share it with everyone, post it to the project on GitHub.")
                        .font(Classic.font(11))
                        .foregroundStyle(Classic.header)
                    ClassicBarButton(title: "Save and post on GitHub\u{2026}") {
                        let saved = makeNote()
                        Compatibility.save(saved)
                        if let url = Compatibility.issueURL(saved) { openURL(url) }
                        onDone(saved)
                    }
                }
                .padding(14)
            }
            .background(Classic.Pinstripes().ignoresSafeArea())
        }
        .environment(\.colorScheme, storeDark ? .dark : .light)
        .onAppear {
            if let existing = Compatibility.note(for: app.id) {
                verdict = existing.verdict
                note = existing.note
            }
        }
    }

    private func makeNote() -> CompatibilityNote {
        CompatibilityNote(appKey: app.id, name: app.name, version: version, device: device, verdict: verdict,
                          note: note.trimmingCharacters(in: .whitespacesAndNewlines), date: Date())
    }

    private func save() {
        let saved = makeNote()
        Compatibility.save(saved)
        onDone(saved)
    }
}

struct StoreIcon: View {
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Classic.placeholderTop, Classic.placeholderBottom], startPoint: .top, endPoint: .bottom)
                    .overlay(Image(systemName: "app").foregroundStyle(Classic.faint))
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

