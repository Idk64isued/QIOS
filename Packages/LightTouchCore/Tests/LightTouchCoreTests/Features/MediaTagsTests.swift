import AVFoundation
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import LightTouchCore

/// Every Music-library tag and the cover reach the staged metadata (what itmedia hands MusicLibrary): an MP3 and
/// raw ADTS AAC with the ID3v2.3 frames iTunes writes (TCMP, TPE2, a "(17)" TCON, a JPEG APIC), and an M4A with
/// iTunes atoms and a PNG cover. The guest's own mapping of that plist (itmedia.c) is qemu-ios's to test.
struct MediaTagsTests {
    static let quadrants: [((Double, Double), MediaFixtures.RGBA)] = [
        ((0.25, 0.25), (200, 40, 40, 255)), ((0.75, 0.25), (40, 180, 60, 255)),
        ((0.25, 0.75), (40, 60, 200, 255)), ((0.75, 0.75), (240, 220, 30, 255))
    ]

    static func cover(_ url: URL, _ type: UTType) throws {
        try MediaFixtures.image(
            url,
            width: 1000,
            height: 1000,
            type: type,
            fill: quadrants.map { (center, color) in
                (CGRect(x: (center.0 - 0.25) * 1000, y: (center.1 - 0.25) * 1000, width: 500, height: 500), color)
            }
        )
    }

    /// An ID3v2.3 tag with these text frames (UTF-16 with a BOM) and a JPEG APIC.
    static func id3(title: String, cover: Data) -> Data {
        func frame(_ id: String, _ body: Data) -> Data {
            var size = UInt32(body.count).bigEndian
            return Data(id.utf8) + Data(bytes: &size, count: 4) + Data([0, 0]) + body
        }
        func text(_ id: String, _ value: String) -> Data { frame(id, Data([1]) + value.data(using: .utf16)!) }
        var frames = [
            ("TIT2", title), ("TPE1", "Track Artist"), ("TALB", "The Album"), ("TPE2", "Album Artist"),
            ("TCOM", "Some Composer"),
            ("TRCK", "3/12"), ("TPOS", "2/3"), ("TYER", "1987"), ("TCON", "(17)"), ("TCMP", "1")
        ].reduce(Data()) { $0 + text($1.0, $1.1) }
        frames += frame("APIC", Data([0]) + Data("image/jpeg".utf8) + Data([0, 3, 0]) + cover)
        let n = frames.count
        return Data("ID3".utf8)
            + Data([3, 0, 0, UInt8((n >> 21) & 127), UInt8((n >> 14) & 127), UInt8((n >> 7) & 127), UInt8(n & 127)])
            + frames
    }

    static func prepared(_ source: URL) async throws -> (MediaSong, [String: Any]) {
        let song = try await MediaSong.prepare(source)
        let metadata =
            try PropertyListSerialization.propertyList(from: Data(contentsOf: song.metadata), format: nil)
            as? [String: Any] ?? [:]
        return (song, metadata)
    }

    func expectTags(_ metadata: [String: Any], genre: String, _ name: String) {
        let want: [String: AnyHashable] = [
            "title": "Tagged Tïtle", "artist": "Track Artist", "album": "The Album", "album_artist": "Album Artist",
            "composer": "Some Composer", "genre": genre, "track_number": 3, "track_count": 12,
            "disc_number": 2, "disc_count": 3, "year": 1987, "compilation": true
        ]
        for (key, value) in want {
            #expect(metadata[key] as? AnyHashable == value, "\(name): \(key) = \(String(describing: metadata[key]))")
        }
    }

    func expectCover(_ song: MediaSong, _ name: String) throws {
        let art = try #require(song.artwork, "\(name): no cover staged")
        let image = try MediaFixtures.pixels(art)
        #expect(
            image.width == 640 && image.height == 640 && !MediaFixtures.isProgressiveJPEG(art),
            "\(name): artwork \(image.width)x\(image.height)"
        )
        for ((x, y), color) in Self.quadrants {
            let p = image.at(Int(x * 640), Int(y * 640))
            #expect(
                abs(Int(p.0) - Int(color.0)) <= 12 && abs(Int(p.1) - Int(color.1)) <= 12
                    && abs(Int(p.2) - Int(color.2)) <= 12,
                "\(name): artwork at \((x, y)) is \(p), expected \(color)"
            )
        }
    }

    @Test func id3TagsOnMP3AndRawAAC() async throws {
        try await withTemporaryState { work in
            let jpeg = work.appendingPathComponent("cover.jpg")
            try Self.cover(jpeg, .jpeg)
            let tag = Self.id3(title: "Tagged Tïtle", cover: try Data(contentsOf: jpeg))
            let mp3 = work.appendingPathComponent("untagged.mp3")
            let m4a = work.appendingPathComponent("plain.m4a")
            let adts = work.appendingPathComponent("untagged.aac")
            try MediaFixtures.silentMP3(mp3, seconds: 3)
            try MediaFixtures.tone(m4a, seconds: 3, format: kAudioFormatMPEG4AAC)
            try await MediaFixtures.adts(from: m4a, to: adts)
            let song = work.appendingPathComponent("Song.mp3")
            let aac = work.appendingPathComponent("Song.aac")
            try (tag + Data(contentsOf: mp3)).write(to: song)
            // AVAudioFile converts samples, not tags: a raw AAC's ID3 must survive its conversion to M4A.
            try (tag + Data(contentsOf: adts)).write(to: aac)
            var identities: [String] = []
            for source in [song, aac] {
                let (prepared, metadata) = try await Self.prepared(source)
                defer { try? FileManager.default.removeItem(at: prepared.directory) }
                expectTags(metadata, genre: "Rock", source.lastPathComponent)
                try expectCover(prepared, source.lastPathComponent)
                identities.append(prepared.id)
            }
            // The same AAC samples under another title are another song.
            let other = work.appendingPathComponent("Other.aac")
            try (Self.id3(title: "Another Title", cover: try Data(contentsOf: jpeg)) + Data(contentsOf: adts)).write(
                to: other
            )
            let (otherSong, _) = try await Self.prepared(other)
            defer { try? FileManager.default.removeItem(at: otherSong.directory) }
            #expect(otherSong.id != identities[1], "different AAC tags collapsed into one import identity")
        }
    }

    @Test func iTunesAtomsOnM4A() async throws {
        try await withTemporaryState { work in
            let png = work.appendingPathComponent("cover.png")
            let plain = work.appendingPathComponent("plain.m4a")
            let song = work.appendingPathComponent("Song.m4a")
            try Self.cover(png, .png)
            try MediaFixtures.tone(plain, seconds: 3, format: kAudioFormatMPEG4AAC)
            func item(_ id: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol) -> AVMetadataItem {
                let item = AVMutableMetadataItem()
                item.identifier = id
                item.value = value
                return item
            }
            let export = try #require(
                AVAssetExportSession(asset: AVURLAsset(url: plain), presetName: AVAssetExportPresetPassthrough)
            )
            export.metadata = [
                item(.iTunesMetadataSongName, "Tagged Tïtle" as NSString),
                item(.iTunesMetadataArtist, "Track Artist" as NSString),
                item(.iTunesMetadataAlbum, "The Album" as NSString),
                item(.iTunesMetadataAlbumArtist, "Album Artist" as NSString),
                item(.iTunesMetadataComposer, "Some Composer" as NSString),
                item(.iTunesMetadataUserGenre, "Synthpop" as NSString),
                item(.iTunesMetadataTrackNumber, Data([0, 0, 0, 3, 0, 12, 0, 0]) as NSData),
                item(.iTunesMetadataDiscNumber, Data([0, 0, 0, 2, 0, 3]) as NSData),
                item(.iTunesMetadataReleaseDate, "1987" as NSString),
                item(.iTunesMetadataDiscCompilation, 1 as NSNumber),
                item(.iTunesMetadataCoverArt, try Data(contentsOf: png) as NSData)
            ]
            try await export.export(to: song, as: .m4a)
            let (prepared, metadata) = try await Self.prepared(song)
            defer { try? FileManager.default.removeItem(at: prepared.directory) }
            expectTags(metadata, genre: "Synthpop", "Song.m4a")
            try expectCover(prepared, "Song.m4a")
        }
    }
}
