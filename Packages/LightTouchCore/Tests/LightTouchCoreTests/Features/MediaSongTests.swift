import AVFoundation
import Foundation
import Testing

@testable import LightTouchCore

/// Song preparation (MediaSong): the staged copy is the source's bytes with its duration and one identity, raw ADTS
/// AAC becomes an M4A whose identity survives a second conversion, malformed audio is refused and cancellation
/// honored. The sources are six seconds each: AAC and Apple Lossless M4A, PCM WAV and silent MP3.
struct MediaSongTests {
    static func write(_ name: String, to url: URL) throws {
        switch name {
        case "aac.m4a": try MediaFixtures.tone(url, format: kAudioFormatMPEG4AAC)
        case "lossless.m4a": try MediaFixtures.tone(url, format: kAudioFormatAppleLossless)
        case "stereo.wav": try MediaFixtures.tone(url, format: kAudioFormatLinearPCM)
        default: try MediaFixtures.silentMP3(url)
        }
    }

    @Test(arguments: ["aac.m4a", "lossless.m4a", "stereo.wav", "tone.mp3"])
    func stagedCopyKeepsTheBytes(_ name: String) async throws {
        try await withTemporaryState { work in
            let source = work.appendingPathComponent(name)
            try Self.write(name, to: source)
            let song = try await MediaSong.prepare(source)
            defer { try? FileManager.default.removeItem(at: song.directory) }
            #expect(
                try Data(contentsOf: song.audio) == Data(contentsOf: source),
                "the staged copy is the source's bytes"
            )
            let metadata =
                try PropertyListSerialization.propertyList(from: Data(contentsOf: song.metadata), format: nil)
                as? [String: Any]
            let duration = try #require(metadata?["duration_ms"] as? Double)
            #expect(abs(duration - 6000) < 100, "\(duration) ms")
            #expect(metadata?["filename"] as? String == song.audio.lastPathComponent)
            #expect(UUID(uuidString: song.id) != nil)
            let repeated = try await MediaSong.prepare(source)
            defer { try? FileManager.default.removeItem(at: repeated.directory) }
            #expect(repeated.id == song.id && repeated.directory != song.directory)
        }
    }

    @Test func rawAACBecomesM4AWithAStableIdentity() async throws {
        try await withTemporaryState { work in
            let m4a = work.appendingPathComponent("source.m4a")
            let raw = work.appendingPathComponent("raw.aac")
            try MediaFixtures.tone(m4a, format: kAudioFormatMPEG4AAC)
            try await MediaFixtures.adts(from: m4a, to: raw)
            let converted = try await MediaSong.prepare(raw)
            defer { try? FileManager.default.removeItem(at: converted.directory) }
            #expect(converted.audio.pathExtension == "m4a")
            let decoded = try AVAudioFile(forReading: converted.audio)
            #expect(abs(Double(decoded.length) / decoded.processingFormat.sampleRate - 6) < 0.15)
            #expect(
                !FileManager.default.fileExists(atPath: converted.directory.appendingPathComponent("audio.aac").path)
            )
            // A second conversion a second later writes new timestamps; the identity ignores them.
            try await Task.sleep(for: .seconds(1.1))
            let repeated = try await MediaSong.prepare(raw)
            defer { try? FileManager.default.removeItem(at: repeated.directory) }
            #expect(repeated.id == converted.id, "AAC conversion changed content identity")
        }
    }

    @Test func malformedAndCancelled() async throws {
        try await withTemporaryState { work in
            let invalid = work.appendingPathComponent("invalid.m4a")
            try Data("not audio".utf8).write(to: invalid)
            await #expect(throws: (any Error).self) { try await MediaSong.prepare(invalid) }
            let source = work.appendingPathComponent("aac.m4a")
            try MediaFixtures.tone(source, format: kAudioFormatMPEG4AAC)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try await MediaSong.prepare(source)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }

    /// The track and disc numbers a tag's text or its binary trkn/disk atom gives, and the genre a gnre atom names: a
    /// missing number reads as 0, a short atom as none, a gnre index past the table as no genre.
    @Test func trackDiscAndGenreTags() {
        #expect(MediaSong.numberPair("3/12") == (3, 12) && MediaSong.numberPair(" 7 ") == (7, 0))
        #expect(MediaSong.numberPair("/12") == (0, 12), "a count without a number is not the number")
        #expect(MediaSong.numberPair("/") == (0, 0))
        func atom(_ bytes: [UInt8]) -> [Int]? { MediaSong.numberPair(Data(bytes)).map { [$0, $1] } }
        #expect(atom([0, 0, 0, 3, 0, 12, 0, 0]) == [3, 12] && atom([0, 0, 1, 0, 0, 2]) == [256, 2])
        #expect(atom([0, 0, 0, 3, 0]) == nil)
        #expect(MediaSong.predefinedGenre(Data([0, 1])) == "Blues" && MediaSong.predefinedGenre(Data([0, 0])) == nil)
        #expect(MediaSong.predefinedGenre(Data([1, 1])) == nil, "257 is past the ID3v1 table")
        #expect(MediaSong.predefinedGenre(Data([1])) == nil)
    }
}
