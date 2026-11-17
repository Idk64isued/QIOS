import SwiftUI

/// What each update changed, from the repository's CHANGELOG.md, carried in the app as a resource.
///
/// Updates arrive here as a new build from the action, with nothing in the app to say what moved. The log is
/// written per update anyway, so the app shows it: once by itself the first time a new build runs, and from the
/// main menu whenever you want it.
enum ChangeLog {
    /// The changelog as shipped, or nil when the resource didn't make it into the build.
    static var text: String? {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
            let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return raw
    }

    private static let seenKey = "changelogSeenBuild"

    /// This build's number (CI's run number, stamped in at build time).
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }

    /// True once per new build: the first run after an update, and never again for that build.
    ///
    /// A first install is not an update, so it doesn't count — there is nothing to have changed yet. The build is
    /// recorded either way, so the next genuine update is what opens this.
    static func shouldShowForNewBuild() -> Bool {
        let seen = UserDefaults.standard.string(forKey: seenKey)
        guard seen != build else { return false }
        UserDefaults.standard.set(build, forKey: seenKey)
        return seen != nil
    }

    /// One update: its heading and the lines under it.
    struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let body: [Line]
    }

    /// A line of an entry, already told apart so the view doesn't have to parse while drawing.
    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let kind: Kind
        enum Kind { case heading, bullet, nested, plain }
    }

    /// The changelog split into updates, newest first. Entries are headed by "## ", groups within one by "**…**",
    /// and items by "- " (a nested item by two spaces and a dash).
    static func entries(limit: Int = 40) -> [Entry] {
        guard let text else { return [] }
        var entries: [Entry] = []
        var title: String?
        var body: [Line] = []
        func flush() {
            if let title { entries.append(Entry(title: title, body: body)) }
            title = nil
            body = []
        }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if rawLine.hasPrefix("## ") {
                flush()
                title = String(rawLine.dropFirst(3))
                continue
            }
            guard title != nil else { continue }   // the file's own title and preamble
            if line.isEmpty { continue }
            if line.hasPrefix("**") {
                body.append(Line(text: line.replacingOccurrences(of: "*", with: ""), kind: .heading))
            } else if rawLine.hasPrefix("  - ") {
                body.append(Line(text: clean(String(line.dropFirst(2))), kind: .nested))
            } else if line.hasPrefix("- ") {
                body.append(Line(text: clean(String(line.dropFirst(2))), kind: .bullet))
            } else {
                // A wrapped continuation of the item above it, which is how the file is written.
                if let last = body.last, last.kind == .bullet || last.kind == .nested {
                    body[body.count - 1] = Line(text: last.text + " " + clean(line), kind: last.kind)
                } else {
                    body.append(Line(text: clean(line), kind: .plain))
                }
            }
        }
        flush()
        return Array(entries.prefix(limit))
    }

    /// Markdown's emphasis and code marks, which would otherwise be read out as punctuation.
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
    }
}

/// The changelog, drawn as iOS 6's grouped tables like the rest of the main menu.
struct WhatsNewView: View {
    /// Shown as a sheet, so it closes itself.
    @Environment(\.dismiss) private var dismiss
    private let entries = ChangeLog.entries()

    var body: some View {
        SixScreen(title: "What\u{2019}s New", right: ("Done", { dismiss() })) {
            if entries.isEmpty {
                SixSection(footer: "This build shipped without its changelog.") {
                    SixRow(title: "Nothing to show", chevron: false)
                }
            }
            ForEach(entries) { entry in
                SixSection(header: entry.title) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entry.body) { line in
                            switch line.kind {
                            case .heading:
                                Text(line.text)
                                    .font(Six.font(15, bold: true))
                                    .foregroundStyle(Six.text)
                                    .padding(.top, 2)
                            case .bullet, .nested:
                                HStack(alignment: .top, spacing: 7) {
                                    Text("\u{2022}")
                                        .font(Six.font(14))
                                        .foregroundStyle(Six.header)
                                    Text(line.text)
                                        .font(Six.font(14))
                                        .foregroundStyle(Six.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.leading, line.kind == .nested ? 16 : 0)
                            case .plain:
                                Text(line.text)
                                    .font(Six.font(14))
                                    .foregroundStyle(Six.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
            }
            Text("Build \(ChangeLog.build)")
                .font(Six.font(13))
                .foregroundStyle(Six.header)
                .shadow(color: Six.headerShadow, radius: 0, y: 1)
                .padding(.top, 18)
        }
    }
}
