// What a file dropped from outside the app is, by what takes it: an IPSW, or a
// folder that may hold some, goes to the library, an .ipa or importable media to a running device, anything
// else is named as unsupported. The device screen, the app list, the sidebar
// and the placeholder share it; the drag and the pasteboard stay theirs.

import Foundation

public nonisolated enum DroppedFiles: Equatable {
    case ipsw, ipa, media, unsupported

    public init(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "ipsw": self = .ipsw
        case "ipa": self = .ipa
        case let suffix where PreparedMedia.extensions.contains(suffix): self = .media
        default: self = Self.isFolder(url) ? .ipsw : .unsupported
        }
    }

    /// A folder, not a package (an .app is a file to the user).
    public static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    /// The .ipsw files among `urls`, and in the folders among them up to `depth` levels down (hidden files and
    /// packages skipped), each folder's in path order.
    public static func ipsws(in urls: [URL], depth: Int = 4) -> [URL] {
        urls.flatMap { url -> [URL] in
            guard isFolder(url) else { return url.pathExtension.lowercased() == "ipsw" ? [url] : [] }
            guard
                let walk = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else { return [] }
            var found: [URL] = []
            for case let file as URL in walk {
                if walk.level >= depth { walk.skipDescendants() }
                if file.pathExtension.lowercased() == "ipsw", !isFolder(file) { found.append(file) }
            }
            return found.sorted { $0.path < $1.path }
        }
    }

    /// The file URLs among `urls` of `kind`, in drop order.
    public static func files(_ urls: [URL], _ kind: DroppedFiles) -> [URL] {
        urls.filter { $0.isFileURL && DroppedFiles($0) == kind }
    }
}
