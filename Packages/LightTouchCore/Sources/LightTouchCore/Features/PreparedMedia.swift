import Foundation
import HostRuntime

public enum PreparedMedia: Sendable {
    case song(MediaSong)
    case photo(MediaPhoto)
    case video(MediaVideo)

    public nonisolated static let extensions = MediaSong.extensions.union(MediaPhoto.extensions).union(
        MediaVideo.extensions
    )

    public var directory: URL {
        switch self {
        case .song(let song): song.directory
        case .photo(let photo): photo.directory
        case .video(let video): video.directory
        }
    }

    public var title: String {
        switch self {
        case .song(let song): song.title
        case .photo(let photo): photo.title
        case .video(let video): video.title
        }
    }

    public var destination: String {
        switch self {
        case .song: "Music"
        case .photo: "Photos"
        case .video: "Videos"
        }
    }

    /// The library a file would go to, by its extension, before it is read (MediaSupport's gate).
    public nonisolated static func destination(forExtension suffix: String) -> String {
        let suffix = suffix.lowercased()
        return MediaSong.extensions.contains(suffix)
            ? "Music" : MediaVideo.extensions.contains(suffix) ? "Videos" : "Photos"
    }

    public nonisolated static func prepare(_ source: URL, profile: Board) async throws -> PreparedMedia {
        if MediaSong.extensions.contains(source.pathExtension.lowercased()) {
            return .song(try await MediaSong.prepare(source))
        }
        if MediaVideo.extensions.contains(source.pathExtension.lowercased()) {
            return .video(try await MediaVideo.prepare(source, profile: profile))
        }
        return .photo(try await MediaPhoto.prepare(source))
    }
}
