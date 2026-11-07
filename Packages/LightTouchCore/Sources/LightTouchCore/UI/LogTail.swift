import Foundation

/// A log file's tail, as the log window and the console show it.
public nonisolated enum LogTail {
    public static func read(_ url: URL) -> String { read(url, from: 0).text }

    /// The file's last 64 KB after `from` (a Clear point), whole lines only.
    /// `rotated` when the file is now shorter than `from`: it was replaced, so read it all.
    public static func read(_ url: URL, from: UInt64) -> (text: String, rotated: Bool) {
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let size = try file.seekToEnd()
            let limit: UInt64 = 65536
            let rotated = size < from
            let start = max(rotated ? 0 : from, size > limit ? size - limit : 0)
            try file.seek(toOffset: start)
            var data = try file.read(upToCount: Int(limit)) ?? Data()
            if start > (rotated ? 0 : from), let newline = data.firstIndex(of: 10) {
                data = Data(data.suffix(from: data.index(after: newline)))
            }
            if data.isEmpty { return (from > 0 && !rotated ? "" : "No log output yet.", rotated) }
            return (String(decoding: data, as: UTF8.self), rotated)
        } catch {
            return ("Cannot read \(url.lastPathComponent): \(error.localizedDescription)", false)
        }
    }

    /// The lines containing `filter`, case-insensitively; everything for an empty filter.
    public static func filtered(_ value: String, by filter: String) -> String {
        filter.isEmpty
            ? value
            : value.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
    }
}
