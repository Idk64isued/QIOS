import Foundation

extension URL {
    /// This file URL, or "name 2.ext", "name 3.ext"… when something is already there (as the Finder names copies).
    public nonisolated var unused: URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return self }
        let base = deletingPathExtension().lastPathComponent
        let ext = pathExtension
        let folder = deletingLastPathComponent()
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
