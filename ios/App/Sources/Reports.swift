import SwiftUI
import UIKit
import ZIPFoundation

// Reports: everything about a test run in one place, so nothing is lost and nothing has to be gathered by hand.
//
//  - Files > Light Touch > Reports keeps the log of each of the last ten sessions, saved when the next one starts,
//    so a crash or a swipe-away no longer loses the run before it.
//  - Send report bundles a zip: what you say happened, the device, the phone, the settings, the whole log, the last
//    session's log, the device's screen, and your app compatibility notes. It goes out through the share sheet.
//  - Copy summary puts a short text version on the clipboard: the same facts and only the log lines that matter.

enum Reports {
    static var folder: URL { Library.documents.appendingPathComponent("Reports", isDirectory: true) }
    /// Where a graphics capture writes its frames and render targets (Settings \u{25B8} Graphics capture).
    static var captureFolder: URL { folder.appendingPathComponent("GraphicsCapture", isDirectory: true) }
    static let keep = 10

    /// The log the last session wrote, kept before this session's replaces it. Called before LTMLog.start().
    static func archivePreviousLog() {
        let fm = FileManager.default
        let log = LTMLog.url
        guard let size = (try? fm.attributesOfItem(atPath: log.path))?[.size] as? NSNumber, size.intValue > 0 else { return }
        Library.ensure(folder)
        let modified = (try? fm.attributesOfItem(atPath: log.path))?[.modificationDate] as? Date ?? Date()
        let target = folder.appendingPathComponent("session-\(stamp(modified)).log")
        try? fm.removeItem(at: target)
        try? fm.copyItem(at: log, to: target)
        // Only the newest ten.
        let sessions = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("session-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in sessions.dropFirst(keep) { try? fm.removeItem(at: old) }
    }

    static var previousSession: URL? {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("session-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }

    static func stamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: date)
    }

    // MARK: - What a report says

    struct Context {
        var note: String
        var deviceName: String?
        var deviceDetails: String?
        var screen: CGImage?
    }

    /// The facts at the top of a report and a summary.
    static func header(_ context: Context) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let app = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        var phone = utsname()
        uname(&phone)
        let model = withUnsafePointer(to: &phone.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let defaults = UserDefaults.standard
        let settings = ["viewMode", "appearance", "homeInterface", "autoCool", "smoothSound", "keepState", "passBattery", "reportCharger", "mirrorVibration", "passMotion",
                        "cellularModem", "enableUSB", "verboseBoot", "kernelConsole", "passLocation", "netRestricted", "netLAN", "codeCacheMB", "fastGL", "rect2d", "diag", "sharpPixels", "coolMode",
                        "wifiNetwork", "debugPort", "rawKeyboard", "microphone", "glRenderer"]
            .compactMap { key in defaults.object(forKey: key).map { "\(key)=\($0)" } }
            .joined(separator: " ")
        var lines = [
            "Light Touch for iOS report, \(stamp())",
            "What happened: \(context.note.isEmpty ? "(not said)" : context.note)",
            "Device: \(context.deviceName ?? "none running")\(context.deviceDetails.map { " — \($0)" } ?? "")",
            "App: \(app); phone \(model), iOS \(UIDevice.current.systemVersion); \(JIT.summary)",
            "Thermal: \(LTMLog.thermal); low power \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")",
            "Settings: \(settings.isEmpty ? "defaults" : settings)",
        ]
        let notes = Compatibility.all()
        if !notes.isEmpty {
            lines.append("Compatibility notes: \(notes.count)")
            for n in notes.prefix(20) { lines.append("  \(n.verdict.title): \(n.name) \(n.version) on \(n.device) — \(n.note)") }
        }
        return lines.joined(separator: "\n")
    }

    /// The lines of a log worth reading first: problems, the graphics bridge's refusals and fixes, the agent, sound,
    /// the profiler, saves.
    static func importantLines(_ text: String, limit: Int = 160) -> [String] {
        let keys = ["error", "fail", "REFUSED", "npot", "has only level 0", "host APPLE", "[agent]", "[audio]", "[prof]",
                    "background:", "first lit frame", "could not", "couldn", "stopped", "panic", "[snapshot]", "cpu "]
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = String(line)
            if l.hasPrefix("[acct]   same-pc") { continue }
            if keys.contains(where: { l.localizedCaseInsensitiveContains($0) }) || l.hasPrefix("[acct]") {
                out.append(l.count > 300 ? String(l.prefix(300)) + "…" : l)
            }
        }
        // Keep the start and the end, where boots and failures are.
        if out.count > limit { out = Array(out.prefix(limit / 3)) + ["… \(out.count - limit) lines …"] + Array(out.suffix(limit * 2 / 3)) }
        return out
    }

    static func summary(_ context: Context) -> String {
        let log = (try? String(contentsOf: LTMLog.url, encoding: .utf8)) ?? ""
        return header(context) + "\n\nLog (the lines that matter):\n" + importantLines(log).joined(separator: "\n")
    }

    /// A binary PPM (P6, RGB) or PGM (P5, grey) as the GL host writes them -- "P6\nW H\n255\n" then the pixels --
    /// turned into a PNG. Nil for anything else.
    static func netpbmToPNG(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), data.count > 16 else { return nil }
        // The header is three newline-terminated lines.
        var fields: [String] = []
        var start = data.startIndex, i = data.startIndex
        while fields.count < 3, i < data.endIndex {
            if data[i] == 0x0A {
                fields.append(String(decoding: data[start..<i], as: UTF8.self))
                start = data.index(after: i)
            }
            i = data.index(after: i)
        }
        guard fields.count == 3, fields[2] == "255" else { return nil }
        let size = fields[1].split(separator: " ").compactMap { Int($0) }
        guard size.count == 2, size[0] > 0, size[1] > 0 else { return nil }
        let grey = fields[0] == "P5"
        guard grey || fields[0] == "P6" else { return nil }
        let channels = grey ? 1 : 3
        let row = size[0] * channels
        guard data.count - start >= row * size[1],
            let provider = CGDataProvider(data: data.subdata(in: start..<(start + row * size[1])) as CFData),
            let image = CGImage(width: size[0], height: size[1], bitsPerComponent: 8, bitsPerPixel: 8 * channels,
                bytesPerRow: row, space: grey ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: image).pngData()
    }

    /// The zip, in the temporary folder, and a copy of its report.txt in Reports.
    static func bundle(_ context: Context) throws -> URL {
        let fm = FileManager.default
        let name = "LightTouch-report-\(stamp())"
        let work = fm.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try summary(context).write(to: work.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        if fm.fileExists(atPath: LTMLog.url.path) {
            try? fm.copyItem(at: LTMLog.url, to: work.appendingPathComponent("lighttouch.log"))
        }
        if fm.fileExists(atPath: LTMLog.serialURL.path) {
            try? fm.copyItem(at: LTMLog.serialURL, to: work.appendingPathComponent("serial.log"))
        }
        if let previous = previousSession {
            try? fm.copyItem(at: previous, to: work.appendingPathComponent("previous-" + previous.lastPathComponent))
        }
        if let screen = context.screen, let png = UIImage(cgImage: screen).pngData() {
            try? png.write(to: work.appendingPathComponent("screen.png"))
        }
        if let data = try? JSONEncoder().encode(Compatibility.all()) {
            try? data.write(to: work.appendingPathComponent("compatibility.json"))
        }
        // A graphics capture's frames and render targets, as PNGs (the raw files are several MB each).
        if let files = try? fm.contentsOfDirectory(at: captureFolder, includingPropertiesForKeys: nil), !files.isEmpty {
            let out = work.appendingPathComponent("graphics-capture", isDirectory: true)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            for file in files where ["ppm", "pgm"].contains(file.pathExtension) {
                if let png = Self.netpbmToPNG(file) {
                    try? png.write(to: out.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".png"))
                }
            }
        }
        let zip = fm.temporaryDirectory.appendingPathComponent(name + ".zip")
        try? fm.removeItem(at: zip)
        try fm.zipItem(at: work, to: zip, shouldKeepParent: true)
        Library.ensure(folder)
        try? fm.copyItem(at: work.appendingPathComponent("report.txt"), to: folder.appendingPathComponent(name + ".txt"))
        try? fm.removeItem(at: work)
        return zip
    }
}

// MARK: - Compatibility notes

/// How an app ran, as the user saw it. Kept on this phone (Reports/compatibility.json), shown in the Legacy Store,
/// put into every report, and postable as a GitHub issue. Legacy Store's API is read-only, so there is nowhere on
/// its side to send them.
struct CompatibilityNote: Codable, Identifiable, Hashable {
    enum Verdict: String, Codable, CaseIterable {
        case works, glitches, crashes, wontInstall
        var title: String {
            switch self {
            case .works: return "Works"
            case .glitches: return "Runs with glitches"
            case .crashes: return "Crashes"
            case .wontInstall: return "Won\u{2019}t install"
            }
        }
        var symbol: String {
            switch self {
            case .works: return "checkmark.circle.fill"
            case .glitches: return "exclamationmark.triangle.fill"
            case .crashes: return "xmark.octagon.fill"
            case .wontInstall: return "arrow.down.circle.dotted"
            }
        }
    }

    var id: String { appKey + "|" + version + "|" + device }
    var appKey: String
    var name: String
    var version: String
    var device: String
    var verdict: Verdict
    var note: String
    var date: Date
}

enum Compatibility {
    static var file: URL { Reports.folder.appendingPathComponent("compatibility.json") }

    static func all() -> [CompatibilityNote] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([CompatibilityNote].self, from: data)) ?? []).sorted { $0.date > $1.date }
    }

    static func note(for appKey: String) -> CompatibilityNote? { all().first { $0.appKey == appKey } }

    static func save(_ note: CompatibilityNote) {
        var notes = all().filter { $0.id != note.id }
        notes.insert(note, at: 0)
        Library.ensure(Reports.folder)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(notes).write(to: file, options: .atomic)
    }

    /// A new GitHub issue on the project, filled in. Nothing is sent until it is submitted there.
    static func issueURL(_ note: CompatibilityNote) -> URL? {
        var c = URLComponents(string: "https://github.com/Idk64isued/QIOS/issues/new")
        let body = """
            **App:** \(note.name) \(note.version) (\(note.appKey))
            **Device:** \(note.device)
            **Result:** \(note.verdict.title)

            \(note.note)
            """
        c?.queryItems = [
            URLQueryItem(name: "title", value: "Compatibility: \(note.name) \(note.version) — \(note.verdict.title)"),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: "compatibility"),
        ]
        return c?.url
    }
}

// MARK: - The report sheet

struct ReportSheet: View {
    let deviceName: String?
    let deviceDetails: String?
    let screen: CGImage?
    let onDismiss: () -> Void

    @State private var note = ""
    @State private var share: ShareItem?
    @State private var status = ""
    @State private var working = false

    var body: some View {
        NavigationView {
            ZStack {
                LTBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        GlassCard("What happened?", symbol: "text.bubble") {
                            TextEditor(text: $note)
                                .frame(minHeight: 110)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                .font(.system(size: 14, design: .rounded))
                            Text("For example: \u{201C}installed Angry Birds, it froze when I quit it.\u{201D}")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        GlassCard("Send it", symbol: "paperplane") {
                            Button(action: shareReport) {
                                Label(working ? "Packing\u{2026}" : "Share report (zip)", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(working)
                            Text("The log, the last session's log, the device's screen, your settings and app notes. Share it to Files, Messages, AirDrop or a chat.")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Theme.secondaryText)
                            Button(action: copySummary) {
                                Label("Copy summary", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            Text("A short text version with only the log lines that matter, ready to paste.")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Theme.secondaryText)
                            if !status.isEmpty {
                                Text(status).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Theme.success)
                            }
                        }
                        GlassCard("Kept on this phone", symbol: "folder") {
                            Text("Files \u{203A} On My iPhone \u{203A} LightTouch \u{203A} Reports keeps the last \(Reports.keep) sessions\u{2019} logs and every report you make, even if the app was closed or crashed.")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Send report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { onDismiss() }.foregroundStyle(Theme.accent) }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(item: $share) { item in ActivityView(items: [item.url]) }
    }

    private var context: Reports.Context {
        Reports.Context(note: note, deviceName: deviceName, deviceDetails: deviceDetails, screen: screen)
    }

    private func shareReport() {
        working = true
        let context = self.context
        Task {
            let url = try? await Task.detached { try Reports.bundle(context) }.value
            working = false
            if let url { share = ShareItem(url: url) } else { status = "Couldn\u{2019}t pack the report." }
        }
    }

    private func copySummary() {
        UIPasteboard.general.string = Reports.summary(context)
        status = "Summary copied. Paste it into the chat."
    }
}
