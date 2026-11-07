import AVFoundation
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// Movie preparation (MediaVideo): an iPod-playable export (H.264 Baseline, level 3.0 at most, at most 640×480 and
/// 30 fps, AAC of at most two channels at 48 kHz), its library metadata, one identity for repeated and simultaneous
/// drops, a private cache that recovers from damage, the source left untouched, invalid input refused,
/// cancellation honored; a 720p movie stays 720p for the iPad and is 640 wide for the iPod.
struct MediaVideoTests {
    @Test func iPodExportMetadataIdentityAndCache() async throws {
        try await withTemporaryState { work in
            let source = work.appendingPathComponent("Movie 'quoted' $title — été.mp4")
            try await MediaFixtures.movie(source, width: 480, height: 320)
            let original = try Data(contentsOf: source)
            let cache = work.appendingPathComponent("cache")
            let first = try await MediaVideo.prepare(source, cacheDirectory: cache, profile: .n72)
            defer { try? FileManager.default.removeItem(at: first.directory) }
            #expect(first.title == source.deletingPathExtension().lastPathComponent)
            #expect(first.video.lastPathComponent == "video.m4v" && UUID(uuidString: first.id) != nil)
            let metadata =
                try PropertyListSerialization.propertyList(from: Data(contentsOf: first.metadata), format: nil)
                as? [String: Any]
            #expect(metadata?["kind"] as? String == "feature-movie" && metadata?["filename"] as? String == "video.m4v")
            #expect(metadata?["title"] as? String == first.title)
            let duration = try #require(metadata?["duration_ms"] as? Double)
            #expect(duration > 5900 && duration < 6100, "\(duration) ms")

            let format = try await MediaFixtures.format(of: first.video)
            #expect(
                format.codec == kCMVideoCodecType_H264 && format.profile == 66,
                "H.264 Baseline: profile_idc \(format.profile)"
            )
            #expect(
                format.level <= 30 && format.width <= 640 && format.height <= 480 && format.frameRate <= 30.5,
                "\(format)"
            )
            #expect(
                !format.audio.isEmpty
                    && format.audio.allSatisfy {
                        $0.codec == kAudioFormatMPEG4AAC && $0.channels <= 2 && $0.rate <= 48000
                    }
            )

            // A repeated export reconciles to one guest library item, and the user's movie is never rewritten.
            try await Task.sleep(for: .milliseconds(1100))
            let second = try await MediaVideo.prepare(source, cacheDirectory: cache, profile: .n72)
            defer { try? FileManager.default.removeItem(at: second.directory) }
            #expect(first.id == second.id && first.directory != second.directory)
            #expect(try Data(contentsOf: source) == original)
            let cached = try #require(
                try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first
            )
            #expect(
                (try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? NSNumber)?.intValue
                    == 0o700
            )
            #expect(
                (try FileManager.default.attributesOfItem(atPath: cached.path)[.posixPermissions] as? NSNumber)?
                    .intValue == 0o600
            )

            // Two simultaneous drops adopt the same atomic cache winner.
            let simultaneous = work.appendingPathComponent("simultaneous-cache")
            async let a = MediaVideo.prepare(source, cacheDirectory: simultaneous, profile: .n72)
            async let b = MediaVideo.prepare(source, cacheDirectory: simultaneous, profile: .n72)
            let (left, right) = try await (a, b)
            defer {
                try? FileManager.default.removeItem(at: left.directory)
                try? FileManager.default.removeItem(at: right.directory)
            }
            #expect(left.id == right.id)

            // A damaged cache entry can never poison later imports.
            try Data("invalid cache".utf8).write(to: cached)
            let repaired = try await MediaVideo.prepare(source, cacheDirectory: cache, profile: .n72)
            defer { try? FileManager.default.removeItem(at: repaired.directory) }
            #expect(
                (try FileManager.default.attributesOfItem(atPath: repaired.video.path)[.size] as? NSNumber)?.intValue
                    ?? 0 > 0
            )
            let repairedFormat = try await MediaFixtures.format(of: repaired.video)
            #expect(repairedFormat.profile == 66)
        }
    }

    @Test func invalidInputAndCancellation() async throws {
        try await withTemporaryState { work in
            let source = work.appendingPathComponent("movie.mp4")
            try await MediaFixtures.movie(source, width: 320, height: 240, seconds: 2)
            let fm = FileManager.default
            fm.createFile(atPath: work.appendingPathComponent("empty.mp4").path, contents: nil)
            try Data("not a movie".utf8).write(to: work.appendingPathComponent("broken.mov"))
            try MediaFixtures.tone(work.appendingPathComponent("audio.m4a"), format: kAudioFormatMPEG4AAC)
            try fm.moveItem(at: work.appendingPathComponent("audio.m4a"), to: work.appendingPathComponent("audio.mov"))
            try fm.createDirectory(at: work.appendingPathComponent("folder.mp4"), withIntermediateDirectories: false)
            try fm.copyItem(at: source, to: work.appendingPathComponent("unknown.avi"))
            for name in ["empty.mp4", "broken.mov", "audio.mov", "folder.mp4", "unknown.avi"] {
                await #expect(throws: (any Error).self, "accepted \(name)") {
                    try await MediaVideo.prepare(
                        work.appendingPathComponent(name),
                        cacheDirectory: work.appendingPathComponent("cache"),
                        profile: .n72
                    )
                }
            }
            let cancelled = Task {
                try await MediaVideo.prepare(
                    source,
                    cacheDirectory: work.appendingPathComponent("cache"),
                    profile: .n72
                )
            }
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            let duringExport = Task {
                try await MediaVideo.prepare(
                    source,
                    cacheDirectory: work.appendingPathComponent("cancel-cache"),
                    profile: .n72
                )
            }
            try await Task.sleep(for: .milliseconds(10))
            duringExport.cancel()
            await #expect(throws: CancellationError.self) { try await duringExport.value }
        }
    }

    @Test func hdKeepsItsSizeOnlyWhereItPlays() async throws {
        try await withTemporaryState { work in
            let source = work.appendingPathComponent("hd.mp4")
            try await MediaFixtures.movie(source, width: 1280, height: 720, seconds: 2)
            let cache = work.appendingPathComponent("hd-cache")
            let ipad = try await MediaVideo.prepare(source, cacheDirectory: cache, profile: .k48)
            defer { try? FileManager.default.removeItem(at: ipad.directory) }
            let ipod = try await MediaVideo.prepare(source, cacheDirectory: cache, profile: .n72)
            defer { try? FileManager.default.removeItem(at: ipod.directory) }
            let big = try await MediaFixtures.format(of: ipad.video)
            let small = try await MediaFixtures.format(of: ipod.video)
            #expect(big.width == 1280 && big.height == 720 && big.level <= 31, "\(big)")
            #expect(small.width <= 640 && small.height <= 480, "\(small)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 2, "cached apart")
        }
    }
}
