import Foundation

// Legacy Store's read-only API (https://legacystore.app/api): charts as they were on a day, collections, genres,
// every app's archived screenshots, rating history and reviews. Lists are {data, total, next_url}; ids are strings;
// an app is addressed by its App Store id. Responses carry long cache headers and URLSession's cache keeps them, as
// the site asks ("please cache responses and keep request rates reasonable").
//
// Read leniently: the documentation abbreviates some records ("…"), so every field is looked up by the names the
// site uses and anything missing is simply not shown.

enum StoreAPI {
    static let base = URL(string: "https://legacystore.app/api/v1")!

    typealias JSON = [String: Any]

    static func get(_ path: String, _ query: [String: String?] = [:]) async throws -> JSON {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty { c.queryItems = items.sorted { $0.name < $1.name } }
        let data = try await Transfer.data(c.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? JSON else {
            throw Transfer.Failure(message: "Legacy Store sent something Light Touch couldn\u{2019}t read.")
        }
        if let error = json["error"] as? JSON {
            throw Transfer.Failure(message: error["message"] as? String ?? "Legacy Store refused the request.")
        }
        return json
    }

    static func list(_ json: JSON) -> [JSON] { json["data"] as? [JSON] ?? [] }

    static func string(_ j: JSON, _ keys: String...) -> String? {
        for k in keys {
            if let s = j[k] as? String, !s.isEmpty { return s }
            if let n = j[k] as? NSNumber { return n.stringValue }
        }
        return nil
    }

    static func double(_ j: JSON, _ keys: String...) -> Double? {
        for k in keys {
            if let n = j[k] as? NSNumber { return n.doubleValue }
            if let s = j[k] as? String, let d = Double(s) { return d }
        }
        return nil
    }

    static func url(_ j: JSON, _ keys: String...) -> URL? {
        for k in keys { if let s = j[k] as? String, let u = URL(string: s) { return u } }
        return nil
    }

    static let isoDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = isoDate.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }
}

/// One app as lists show it.
struct StoreApp: Identifiable, Hashable {
    let id: String              // App Store id (the API's canonical key)
    let name: String
    let developer: String?
    let iconURL: URL?
    let bundleID: String?
    let versionCount: Int?
    let label: String?          // a collection's own caption

    init(_ j: StoreAPI.JSON) {
        let app = j["app"] as? StoreAPI.JSON ?? [:]
        id = StoreAPI.string(j, "app_store_id", "id") ?? StoreAPI.string(app, "app_store_id", "id") ?? UUID().uuidString
        name = StoreAPI.string(j, "name", "title") ?? StoreAPI.string(app, "name") ?? "Untitled"
        developer = StoreAPI.string(j, "developer", "artist_name") ?? StoreAPI.string(app, "developer", "artist_name")
        iconURL = StoreAPI.url(j, "icon_url", "artwork_url") ?? StoreAPI.url(app, "icon_url", "artwork_url")
        bundleID = StoreAPI.string(j, "bundle_id") ?? StoreAPI.string(app, "bundle_id")
        versionCount = (j["version_count"] as? Int) ?? (app["version_count"] as? Int)
        label = StoreAPI.string(j, "label", "caption")
    }
}

// MARK: - Charts

struct ChartType: Identifiable, Hashable {
    let slug: String
    let name: String
    var id: String { slug }
    static let defaults = [
        ChartType(slug: "top-free", name: "Top Free"), ChartType(slug: "top-paid", name: "Top Paid"),
        ChartType(slug: "top-grossing", name: "Top Grossing"),
    ]
}

struct ChartEntry: Identifiable, Hashable {
    let position: Int
    let app: StoreApp
    /// The archive holds no copy of it yet (the site shows these in grey).
    let preserved: Bool
    var id: Int { position }
}

struct StoreChart {
    var type: ChartType
    var snapshotDate: String
    var availableDates: [String]
    var entries: [ChartEntry]
}

extension StoreAPI {
    static func chartTypes() async -> [ChartType] {
        guard let json = try? await get("charts/types") else { return ChartType.defaults }
        let raw = (json["data"] as? [Any]) ?? (json["types"] as? [Any]) ?? []
        let types: [ChartType] = raw.compactMap { item in
            if let s = item as? String { return ChartType(slug: s, name: s.replacingOccurrences(of: "-", with: " ").capitalized) }
            if let j = item as? JSON, let slug = string(j, "slug") { return ChartType(slug: slug, name: string(j, "name") ?? slug) }
            return nil
        }
        return types.isEmpty ? ChartType.defaults : types
    }

    /// The archived chart nearest `date` (YYYY-MM-DD), top 50.
    static func chart(type: String, date: String?, genre: String? = nil) async throws -> StoreChart {
        let json = try await get("charts", ["type": type, "date": date, "genre": genre, "device": "iphone"])
        let t = json["chart_type"] as? JSON ?? [:]
        let positions = (json["positions"] as? [JSON]) ?? list(json)
        let entries = positions.compactMap { p -> ChartEntry? in
            guard let position = (p["position"] as? Int) ?? Int(string(p, "position") ?? "") else { return nil }
            let preserved = p["app"] is JSON
            return ChartEntry(position: position, app: StoreApp(p), preserved: preserved)
        }
        .sorted { $0.position < $1.position }
        return StoreChart(
            type: ChartType(slug: string(t, "slug") ?? type, name: string(t, "name") ?? type),
            snapshotDate: string(json, "snapshot_date") ?? (date ?? ""),
            availableDates: (json["available_dates"] as? [String]) ?? [],
            entries: Array(entries.prefix(50)))
    }
}

// MARK: - Collections and genres

struct StoreCollection: Identifiable, Hashable {
    let slug: String
    let title: String
    let series: String?
    let count: Int?
    var id: String { slug }
}

struct StoreGenre: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int?
}

extension StoreAPI {
    static func collections() async throws -> [StoreCollection] {
        list(try await get("collections")).compactMap { j in
            guard let slug = string(j, "slug") else { return nil }
            return StoreCollection(slug: slug, title: string(j, "title", "name") ?? slug, series: string(j, "series"),
                                   count: j["app_count"] as? Int)
        }
    }

    static func collection(_ slug: String) async throws -> [StoreApp] {
        let json = try await get("collections/\(slug)")
        let members = (json["apps"] as? [JSON]) ?? (json["members"] as? [JSON]) ?? list(json)
        return members.map(StoreApp.init)
    }

    static func genres() async throws -> [StoreGenre] {
        list(try await get("genres")).compactMap { j in
            guard let id = string(j, "genre_id", "id") else { return nil }
            return StoreGenre(id: id, name: string(j, "name", "title") ?? id, count: j["app_count"] as? Int)
        }
        .sorted { ($0.count ?? 0) > ($1.count ?? 0) }
    }

    static func apps(genre: String? = nil, query: String? = nil, sort: String = "versions") async throws -> [StoreApp] {
        list(try await get("apps", ["genre": genre, "q": query, "sort": sort, "limit": "100"])).map(StoreApp.init)
    }
}

// MARK: - One app

struct StoreAppDetail {
    var app: StoreApp
    var description: String?
    var genre: String?
    var released: Date?
    var price: String?
    var versionCount: Int?
    var versions: [CatalogVersion]
}

struct ScreenshotSet: Identifiable, Hashable {
    struct Shot: Hashable { let url: URL; let width: Int; let height: Int }
    let captured: Date?
    let version: String?
    let shots: [Shot]
    var id: String { (version ?? "") + "@" + (captured.map { "\($0.timeIntervalSince1970)" } ?? "") }
    var title: String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return [captured.map { f.string(from: $0) }, version.map { "v" + $0 }].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}

struct RatingCapture {
    let captured: Date?
    let count: Int?
    let average: Double?
    let version: String?
    let price: Double?
}

struct StoreReview: Identifiable, Hashable {
    let id: String
    let title: String
    let body: String
    let stars: Int
    let author: String?
    let date: Date?
}

extension StoreAPI {
    static func detail(_ key: String) async throws -> StoreAppDetail {
        let j = try await get("apps/\(key)")
        let versionsData = try JSONSerialization.data(withJSONObject: j["versions"] as? [Any] ?? [])
        let versions = (try? JSONDecoder().decode([CatalogVersion].self, from: versionsData)) ?? []
        let price = double(j, "price", "price_amount").map { $0 == 0 ? "Free" : String(format: "$%.2f", $0) }
            ?? string(j, "formatted_price", "price_text")
        return StoreAppDetail(
            app: StoreApp(j),
            description: string(j, "description", "summary", "long_description"),
            genre: string(j, "genre", "primary_genre_name", "genre_name"),
            released: date(string(j, "original_release_date", "release_date")),
            price: price,
            versionCount: j["version_count"] as? Int,
            versions: versions.sorted { StoreTarget.newer($0.version ?? "0", than: $1.version ?? "0") })
    }

    static func screenshots(_ key: String) async -> [ScreenshotSet] {
        guard let json = try? await get("apps/\(key)/screenshots") else { return [] }
        return list(json).compactMap { set in
            let shots = (set["shots"] as? [JSON] ?? []).compactMap { s -> ScreenshotSet.Shot? in
                guard let u = url(s, "url") else { return nil }
                return .init(url: u, width: (s["width"] as? Int) ?? 320, height: (s["height"] as? Int) ?? 480)
            }
            return shots.isEmpty ? nil : ScreenshotSet(captured: date(string(set, "captured_at")), version: string(set, "version"), shots: shots)
        }
    }

    static func ratings(_ key: String) async -> [RatingCapture] {
        guard let json = try? await get("apps/\(key)/ratings") else { return [] }
        return list(json).map { r in
            RatingCapture(
                captured: date(string(r, "captured_at")),
                count: (r["rating_count"] as? Int) ?? (r["user_rating_count"] as? Int),
                average: double(r, "rating_average", "average_rating", "average_user_rating", "average", "rating", "stars"),
                version: string(r, "listed_version", "version"),
                price: double(r, "price_amount", "price"))
        }
    }

    static func reviews(_ key: String) async -> [StoreReview] {
        guard let json = try? await get("apps/\(key)/reviews", ["limit": "30"]) else { return [] }
        return list(json).compactMap { r in
            guard let id = string(r, "review_id", "id") else { return nil }
            return StoreReview(id: id, title: string(r, "title") ?? "", body: string(r, "body", "content") ?? "",
                               stars: (r["stars"] as? Int) ?? Int(double(r, "stars", "rating") ?? 0),
                               author: string(r, "author", "author_name"), date: date(string(r, "reviewed_at", "date")))
        }
    }
}
