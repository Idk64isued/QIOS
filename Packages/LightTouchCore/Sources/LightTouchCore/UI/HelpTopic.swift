import Foundation

/// One of Help.txt's task topics: a "# " line starts one. "[Device]" reads as the selected device's name.
public struct HelpTopic: Equatable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    public static func topics(_ text: String) -> [HelpTopic] {
        text.components(separatedBy: "\n# ").compactMap { chunk in
            let lines = chunk.drop { $0 == "#" || $0 == " " }.split(
                separator: "\n",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard let title = lines.first, !title.isEmpty else { return nil }
            return HelpTopic(
                title: String(title),
                body: lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            )
        }
    }

    /// The topic with "[Device]" read as `deviceName`.
    public func naming(_ deviceName: String) -> HelpTopic {
        HelpTopic(
            title: title.replacingOccurrences(of: "[Device]", with: deviceName),
            body: body.replacingOccurrences(of: "[Device]", with: deviceName)
        )
    }

    /// The body as shown: paragraphs one line apart (the text view spaces them).
    public var shownBody: String { body.replacingOccurrences(of: "\n\n", with: "\n") }
}
