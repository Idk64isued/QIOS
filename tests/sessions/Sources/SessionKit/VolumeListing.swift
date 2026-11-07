import Foundation

/// A volume's recorded listing (`sessions listings`): one line per path, tab-separated, sorted by path —
/// path, uid:gid, mode (octal), flags (hex), size, resource size, the content's SHA-256 (first 16 hex digits; - for
/// a folder or link), the link's target (-) — after a header of the volume's own facts. No dates: they are when the
/// preparation ran.
public enum VolumeListing {
    /// Path to its line, for the diff; the header under "#".
    public static func lines(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let path = line.hasPrefix("#") ? "#" : String(line.prefix { $0 != "\t" })
            out[path] = String(line)
        }
        return out
    }

    /// What changed from `recorded` to `current`: "- line" for what went or changed, "+ line" for what came, by path.
    public static func diff(recorded: String, current: String) -> [String] {
        let (old, new) = (lines(recorded), lines(current))
        return Set(old.keys).union(new.keys).sorted().flatMap { path -> [String] in
            guard old[path] != new[path] else { return [] }
            return [old[path].map { "- " + $0 }, new[path].map { "+ " + $0 }].compactMap { $0 }
        }
    }
}
