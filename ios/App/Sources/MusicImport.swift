import AVFoundation
import ImageIO
import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

// Songs into the device's own Music app, the way the Mac app does it.
//
// The device's library is iOS's own (MusicLibrary over SQLite on 3.x), and only iOS should write it. So the song is
// staged in /var/mobile/Media/LightTouch/<id>/ (audio.<ext>, artwork.jpg) with its tags in a property list, and
// the guest helper `itmedia` (contrib/it-media, inside the Mac release's guest tools this app already downloads)
// inserts it through MusicLibrary, as a purchase would arrive. iPhone OS 3.1 and later; the 1.x and 2.x libraries
// are iTunes databases that only iTunes writes.

struct PreparedSong {
    let id: String
    let directory: URL
    let audio: URL
    let artwork: URL?
    let metadata: URL
    let title: String
}

enum MusicImport {
    static let extensions: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff"]

    /// Copies `source` into a work folder and reads its tags, length and cover.
    static func prepare(_ source: URL) async throws -> PreparedSong {
        let ext = source.pathExtension.lowercased()
        guard extensions.contains(ext) else {
            throw GuestAgent.InstallFailure(message: "Choose an MP3, M4A (AAC or Apple Lossless), WAV or AIFF file.")
        }
        let id = UUID().uuidString.lowercased()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-music-" + id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("audio." + ext)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: audio)

        let asset = AVURLAsset(url: audio)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 86400 else {
            throw GuestAgent.InstallFailure(message: "\(source.lastPathComponent) has no playable length.")
        }
        guard try await !asset.load(.hasProtectedContent) else {
            throw GuestAgent.InstallFailure(message: "\(source.lastPathComponent) is copy-protected, so it can\u{2019}t be copied.")
        }
        var (properties, cover) = try await tags(of: asset)
        properties["filename"] = audio.lastPathComponent
        properties["duration_ms"] = duration * 1000
        let title = properties["title"] as? String ?? source.deletingPathExtension().lastPathComponent
        properties["title"] = title

        var artwork: URL?
        if let cover, let image = CGImageSourceCreateWithData(cover as CFData, nil), CGImageSourceGetCount(image) > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            if let thumb = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary),
                let jpeg = UIImage(cgImage: thumb).jpegData(compressionQuality: 0.85)
            {
                // UIImage writes a baseline JPEG, which is what the old library reads.
                let url = directory.appendingPathComponent("artwork.jpg")
                try? jpeg.write(to: url)
                artwork = url
                properties["artwork"] = url.lastPathComponent
            }
        }
        let metadata = directory.appendingPathComponent("metadata.plist")
        try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: metadata)
        return PreparedSong(id: id, directory: directory, audio: audio, artwork: artwork, metadata: metadata, title: title)
    }

    /// The tags the device's library keeps (the keys itmedia reads), and the front cover's bytes.
    static func tags(of asset: AVAsset) async throws -> ([String: Any], Data?) {
        var properties: [String: Any] = [:]
        var cover: Data?
        func set(_ key: String, _ value: Any?) { if let value, properties[key] == nil { properties[key] = value } }
        func pair(_ item: AVMetadataItem, _ keys: (String, String)) async throws {
            var number = 0, count = 0
            if let text = try await item.load(.stringValue) {
                let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                number = Int(parts.first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
                count = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0 : 0
            } else if let data = try await item.load(.dataValue), data.count >= 6 {
                number = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
                count = Int(data[data.startIndex + 4]) << 8 | Int(data[data.startIndex + 5])
            }
            if (1...65535).contains(number) { set(keys.0, number) }
            if (1...65535).contains(count) { set(keys.1, count) }
        }
        func text(_ item: AVMetadataItem) async throws -> String? {
            guard let value = try await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty, value.utf8.count <= 4096
            else { return nil }
            return value
        }
        for item in try await asset.load(.metadata) {
            guard let identifier = item.identifier else { continue }
            switch identifier {
            case .iTunesMetadataSongName, .id3MetadataTitleDescription: set("title", try await text(item))
            case .iTunesMetadataArtist, .id3MetadataLeadPerformer: set("artist", try await text(item))
            case .iTunesMetadataAlbum, .id3MetadataAlbumTitle: set("album", try await text(item))
            case .iTunesMetadataAlbumArtist, .id3MetadataBand: set("album_artist", try await text(item))
            case .iTunesMetadataComposer, .id3MetadataComposer: set("composer", try await text(item))
            case .iTunesMetadataUserGenre, .id3MetadataContentType: set("genre", try await text(item))
            case .iTunesMetadataTrackNumber, .id3MetadataTrackNumber: try await pair(item, ("track_number", "track_count"))
            case .iTunesMetadataDiscNumber, .id3MetadataPartOfASet: try await pair(item, ("disc_number", "disc_count"))
            case .iTunesMetadataReleaseDate, .id3MetadataYear, .id3MetadataRecordingTime:
                if let value = try await text(item), let year = Int(value.prefix(4)), (1...9999).contains(year) {
                    set("year", year)
                }
            case .iTunesMetadataCoverArt, .id3MetadataAttachedPicture:
                if cover == nil { cover = try await item.load(.dataValue) }
            default: break
            }
        }
        for item in try await asset.load(.commonMetadata) {
            switch item.commonKey {
            case .commonKeyTitle: set("title", try await text(item))
            case .commonKeyArtist: set("artist", try await text(item))
            case .commonKeyAlbumName: set("album", try await text(item))
            case .commonKeyArtwork: if cover == nil { cover = try await item.load(.dataValue) }
            default: break
            }
        }
        return (properties, cover)
    }

    /// A song from this phone's music library, written out as an M4A. Songs from Apple Music (and anything only in
    /// the cloud) have no file the app may read.
    static func export(_ item: MPMediaItem) async throws -> URL {
        let name = item.title ?? "Song"
        guard let assetURL = item.assetURL else {
            throw GuestAgent.InstallFailure(message: "\u{201C}\(name)\u{201D} is from Apple Music or only in the cloud, so it can\u{2019}t be copied. Songs you bought or added yourself can.")
        }
        let asset = AVURLAsset(url: assetURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw GuestAgent.InstallFailure(message: "\u{201C}\(name)\u{201D} can\u{2019}t be exported.")
        }
        let safe = String(name.map { "/:\\".contains($0) ? "-" : $0 }.prefix(60))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe)-\(UUID().uuidString.prefix(6)).m4a")
        session.outputURL = out
        session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed else {
            throw GuestAgent.InstallFailure(message: "\u{201C}\(name)\u{201D} couldn\u{2019}t be exported (\(session.error?.localizedDescription ?? "unknown")).")
        }
        return out
    }
}

extension GuestAgent {
    /// Stages `song` in the guest and has itmedia add it to Music. Returns the song's title.
    func importSong(_ song: PreparedSong, progress: @escaping (String) -> Void) async throws -> String {
        try await oneAtATime { try await self.importSongNow(song, progress: progress) }
    }

    private func importSongNow(_ song: PreparedSong, progress: @escaping (String) -> Void) async throws -> String {
        let major = Int((guestVersion ?? "3").prefix { $0 != "." }) ?? 3
        let minor = Int((guestVersion ?? "3.1").split(separator: ".").dropFirst().first ?? "0") ?? 0
        guard major > 3 || (major == 3 && minor >= 1) else {
            throw InstallFailure(message: "Adding music needs iPhone OS 3.1 or later on the device: older ones keep their library in a database only iTunes writes.")
        }
        guard status == .alive, ops.contains("spawn"), ops.contains("put") || ops.contains("putpart") else {
            throw InstallFailure(message: "The device\u{2019}s agent isn\u{2019}t ready. Give it a minute after the Home screen appears.")
        }
        isInstalling = true
        defer { isInstalling = false }
        let folder = "/var/mobile/Media/LightTouch/" + song.id
        progress("Preparing \(song.title)\u{2026}")
        try await ensureHelper()
        try await runHelper(uid: 501, gid: 501, paths: ["/var/mobile/Media/LightTouch", folder], what: "make the music folder")
        let audioPath = folder + "/" + song.audio.lastPathComponent
        // Percent as it goes, so a batch reads as busy with this song rather than stuck on it.
        guard await putFile(localURL: song.audio, guestPath: audioPath, mode: "0644", progress: { sent, total in
            let percent = total > 0 ? Int(Double(sent) / Double(total) * 100) : 0
            progress("Copying \(song.title)\u{2026} \(percent)%")
        }) else {
            throw InstallFailure(message: "Copying \(song.title) into the device failed. \(lastLog)")
        }
        var staged = [audioPath]
        if let artwork = song.artwork {
            let path = folder + "/artwork.jpg"
            if await putFile(localURL: artwork, guestPath: path, mode: "0644") { staged.append(path) }
        }
        try await runHelper(uid: 501, gid: 501, paths: staged, what: "give the song to the Music app")
        let plist = "/tmp/ltm-media-\(song.id).plist"
        let exe = try await ensureGuestTool("itmedia")
        guard await putFile(localURL: song.metadata, guestPath: plist, mode: "0644") else {
            throw InstallFailure(message: "Couldn\u{2019}t put the music importer into the device. \(lastLog)")
        }
        progress("Adding \(song.title) to Music\u{2026}")
        let result = await run([exe, plist, song.id], timeout: 120)
        _ = await unlink(path: plist)
        let output = result.map { String(decoding: $0.output, as: UTF8.self) } ?? ""
        log("itmedia: status \(result?.status ?? -1): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        guard let result, result.status == 0, output.contains("imported") else {
            forgetGuestTool("itmedia")
            let reason = output.split(separator: "\n").last.map(String.init) ?? "no answer"
            throw InstallFailure(message: "Music didn\u{2019}t take \(song.title): \(reason)")
        }
        return song.title
    }
}

extension MacFiles {
    /// A file from the guest archive's tools/ (itmedia, itphoto), next to the guest-tools folder a preparation reads.
    static func guestTool(_ name: String) -> URL? {
        guard let tools = try? guestToolsDirectory() else { return nil }
        let url = tools.deletingLastPathComponent().appendingPathComponent("tools", isDirectory: true).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - The sheet

struct MusicImportView: View {
    let agent: GuestAgent
    let onDismiss: () -> Void

    @State private var pickingFiles = false
    @State private var pickingLibrary = false
    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let good: Bool
    }

    @State private var lines: [Line] = []
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        NavigationView {
            ZStack {
                LTBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        GlassCard("Add music", symbol: "music.note") {
                            Text("Songs go into the device\u{2019}s own Music app, with their titles, artists, albums and covers. MP3, M4A, WAV and AIFF.")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Theme.secondaryText)
                            Button { pickingFiles = true } label: {
                                Label("From Files\u{2026}", systemImage: "folder").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                            Button { pickingLibrary = true } label: {
                                Label("From this phone\u{2019}s music\u{2026}", systemImage: "music.note.list").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(busy)
                            Text("From your music library: songs you bought or added yourself. Apple Music songs are protected and can\u{2019}t be copied.")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        if busy || !status.isEmpty {
                            HStack(spacing: 8) {
                                if busy { ProgressView() }
                                Text(status).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Theme.primaryText)
                                Spacer()
                            }
                            .padding(.horizontal, 6)
                        }
                        if !lines.isEmpty {
                            GlassCard("Done", symbol: "checklist") {
                                ForEach(lines) { line in
                                    Label(line.text, systemImage: line.good ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .font(.system(size: 12, design: .rounded))
                                        .foregroundStyle(line.good ? Theme.success : Theme.danger)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { onDismiss() }.foregroundStyle(Theme.accent) }
            }
        }
        .navigationViewStyle(.stack)
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.mp3, .mpeg4Audio, .wav, .aiff, .audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .sheet(isPresented: $pickingLibrary) {
            MediaLibraryPicker { items in
                pickingLibrary = false
                importLibrary(items)
            }
            .ignoresSafeArea()
        }
    }

    private func importFiles(_ urls: [URL]) {
        run(urls.count) { index in try await MusicImport.prepare(urls[index]) }
    }

    private func importLibrary(_ items: [MPMediaItem]) {
        run(items.count) { index in
            let file = try await MusicImport.export(items[index])
            defer { try? FileManager.default.removeItem(at: file) }
            return try await MusicImport.prepare(file)
        }
    }

    /// One song after another: prepare, then hand to the device.
    private func run(_ count: Int, prepare: @escaping (Int) async throws -> PreparedSong) {
        guard count > 0 else { return }
        busy = true
        Task {
            for index in 0..<count {
                status = "Song \(index + 1) of \(count)\u{2026}"
                do {
                    let song = try await prepare(index)
                    defer { try? FileManager.default.removeItem(at: song.directory) }
                    let title = try await agent.importSong(song) { text in status = text }
                    lines.append(Line(text: "\(title) is in Music", good: true))
                } catch {
                    lines.append(Line(text: error.localizedDescription, good: false))
                }
            }
            busy = false
            status = lines.contains { !$0.good } ? "Finished, with problems." : "Finished. Open Music on the device."
        }
    }
}

/// The system's music picker.
struct MediaLibraryPicker: UIViewControllerRepresentable {
    let onPick: ([MPMediaItem]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = true
        picker.showsCloudItems = false
        picker.prompt = "Songs for the device"
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: MPMediaPickerController, context: Context) {}

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let onPick: ([MPMediaItem]) -> Void
        init(onPick: @escaping ([MPMediaItem]) -> Void) { self.onPick = onPick }

        func mediaPicker(_ picker: MPMediaPickerController, didPickMediaItems collection: MPMediaItemCollection) {
            onPick(collection.items)
        }

        func mediaPickerDidCancel(_ picker: MPMediaPickerController) { onPick([]) }
    }
}
