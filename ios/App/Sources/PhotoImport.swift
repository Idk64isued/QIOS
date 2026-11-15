import AVFoundation
import CoreImage
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// Photos and videos into the running device, the Mac app's Media import: a photo becomes an upright baseline JPEG
// (at most 2048 pixels a side) that the guest's itphoto saves into Saved Photos; a video becomes an H.264 and AAC
// .m4v the device can play (640×480 Baseline on the older boards, 720p Main on the A4 ones) that itmedia adds to
// Videos. Both helpers come from the guest archive's tools/ and want iPhone OS 3.1 or later.

/// One photo or video, ready to hand to the device.
struct PreparedMedia {
    enum Kind { case photo, video }
    let id: String
    let kind: Kind
    let title: String
    let directory: URL
    /// image.jpg or video.m4v
    let file: URL
    /// The movie's metadata.plist (itmedia); nil for a photo.
    let metadata: URL?
}

enum MediaPrep {
    static func folder() throws -> (String, URL) {
        let id = UUID().uuidString
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-media-" + id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (id, dir)
    }

    /// An upright, opaque baseline JPEG, at most 2048 pixels on its longer side.
    static func photo(_ data: Data, title: String) throws -> PreparedMedia {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw InstallFailure(message: "\(title) isn\u{2019}t a picture Light Touch can read.")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw InstallFailure(message: "\(title) couldn\u{2019}t be decoded.")
        }
        // JPEG has no transparency: flatten onto white, in sRGB.
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw InstallFailure(message: "\(title) couldn\u{2019}t be converted.") }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let flat = context.makeImage() else { throw InstallFailure(message: "\(title) couldn\u{2019}t be converted.") }
        let (id, dir) = try folder()
        let out = dir.appendingPathComponent("image.jpg")
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw InstallFailure(message: "\(title) couldn\u{2019}t be converted.")
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: false],
        ]
        CGImageDestinationAddImage(destination, flat, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw InstallFailure(message: "\(title) couldn\u{2019}t be saved.") }
        return PreparedMedia(id: id, kind: .photo, title: title, directory: dir, file: out, metadata: nil)
    }

    /// A movie the device plays: `hd` (the A4 boards) up to 1280×720 H.264 Main, else 640×480 Baseline; AAC sound.
    static func video(_ source: URL, title: String, hd: Bool) async throws -> PreparedMedia {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw InstallFailure(message: "\(title) has no length.") }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw InstallFailure(message: "\(title) has no picture.")
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let upright = natural.applying(transform)
        let w0 = abs(upright.width), h0 = abs(upright.height)
        guard w0 > 0, h0 > 0 else { throw InstallFailure(message: "\(title) has no picture.") }
        let long: CGFloat = hd ? 1280 : 640, short: CGFloat = hd ? 720 : 480
        let box = w0 >= h0 ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
        let scale = min(1, box.width / w0, box.height / h0)
        func even(_ v: CGFloat) -> Int { max(2, Int(v * scale) & ~1) }
        let outW = even(w0), outH = even(h0)

        // The composition hands each frame upright (the track's transform applied); scale it to the output size.
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let image = request.sourceImage.transformed(by: CGAffineTransform(scaleX: CGFloat(outW) / w0, y: CGFloat(outH) / h0))
            request.finish(with: image, context: nil)
        }
        composition.renderSize = CGSize(width: outW, height: outH)
        composition.frameDuration = CMTime(value: 1, timescale: 30)

        let (id, dir) = try folder()
        let out = dir.appendingPathComponent("video.m4v")
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = composition
        guard reader.canAdd(videoOut) else { throw InstallFailure(message: "\(title) can\u{2019}t be read.") }
        reader.add(videoOut)
        var audioOut: AVAssetReaderTrackOutput?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let o = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            if reader.canAdd(o) {
                reader.add(o)
                audioOut = o
            }
        }

        let writer = try AVAssetWriter(outputURL: out, fileType: .m4v)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: outW, AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: hd ? 2_500_000 : 1_200_000,
                AVVideoProfileLevelKey: hd ? AVVideoProfileLevelH264Main31 : AVVideoProfileLevelH264Baseline30,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            writer.add(a)
            audioIn = a
        }
        guard reader.startReading(), writer.startWriting() else {
            throw InstallFailure(message: "\(title) couldn\u{2019}t be converted: \((reader.error ?? writer.error)?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)
        var pairs: [(AVAssetWriterInput, AVAssetReaderOutput)] = [(videoIn, videoOut)]
        if let audioIn, let audioOut { pairs.append((audioIn, audioOut)) }
        try await Transcode.run(reader: reader, writer: writer, pairs: pairs)

        let metadata = dir.appendingPathComponent("metadata.plist")
        let properties: [String: Any] = [
            "filename": "video.m4v", "kind": "feature-movie", "title": title,
            "duration_ms": Int((duration * 1000).rounded()),
        ]
        try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: metadata)
        return PreparedMedia(id: id, kind: .video, title: title, directory: dir, file: out, metadata: metadata)
    }
}

/// Moves every sample from each reader output to its writer input, then finishes the movie.
private enum Transcode {
    final class Pump: @unchecked Sendable {
        let input: AVAssetWriterInput
        let output: AVAssetReaderOutput
        var done = false
        init(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput) {
            self.input = input
            self.output = output
        }
    }

    static func run(reader: AVAssetReader, writer: AVAssetWriter, pairs: [(AVAssetWriterInput, AVAssetReaderOutput)]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            for (index, pair) in pairs.enumerated() {
                let pump = Pump(pair.0, pair.1)
                let queue = DispatchQueue(label: "lighttouch.transcode.\(index)")
                group.enter()
                pump.input.requestMediaDataWhenReady(on: queue) {
                    guard !pump.done else { return }
                    func finish() {
                        pump.done = true
                        pump.input.markAsFinished()
                        group.leave()
                    }
                    while pump.input.isReadyForMoreMediaData {
                        guard reader.status == .reading, let sample = pump.output.copyNextSampleBuffer() else {
                            finish()
                            return
                        }
                        if !pump.input.append(sample) {
                            reader.cancelReading()
                            finish()
                            return
                        }
                    }
                }
            }
            group.notify(queue: .global()) {
                if reader.status != .completed || writer.status == .failed {
                    writer.cancelWriting()
                    c.resume(throwing: InstallFailure(message: "The video couldn\u{2019}t be converted: \((reader.error ?? writer.error)?.localizedDescription ?? "unknown error")"))
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed { c.resume() } else {
                        c.resume(throwing: InstallFailure(message: "The video couldn\u{2019}t be saved: \(writer.error?.localizedDescription ?? "unknown error")"))
                    }
                }
            }
        }
    }
}

extension GuestAgent {
    /// Hands a prepared photo (itphoto, Saved Photos) or video (itmedia, Videos) to the device.
    func importMedia(_ media: PreparedMedia, progress: @escaping (String) -> Void) async throws {
        let major = Int((guestVersion ?? "3").prefix { $0 != "." }) ?? 3
        let minor = Int((guestVersion ?? "3.1").split(separator: ".").dropFirst().first ?? "0") ?? 0
        guard major > 3 || (major == 3 && minor >= 1) else {
            throw InstallFailure(message: "Adding photos and videos needs iPhone OS 3.1 or later on the device.")
        }
        guard status == .alive, ops.contains("spawn"), ops.contains("put") || ops.contains("putpart") else {
            throw InstallFailure(message: "The device\u{2019}s agent isn\u{2019}t ready. Give it a minute after the Home screen appears.")
        }
        let toolName = media.kind == .photo ? "itphoto" : "itmedia"
        guard let tool = MacFiles.guestTool(toolName) else {
            throw InstallFailure(message: "The guest tools have no \(toolName). Get the Mac files again (Add device \u{203A} Mac files).")
        }
        isInstalling = true
        defer { isInstalling = false }
        let folder = "/var/mobile/Media/LightTouch/" + media.id
        progress("Preparing \(media.title)\u{2026}")
        try await ensureHelper()
        try await runHelper(uid: 501, gid: 501, paths: ["/var/mobile/Media/LightTouch", folder], what: "make the staging folder")
        progress("Copying \(media.title)\u{2026}")
        let staged = folder + "/" + media.file.lastPathComponent
        guard await putFile(localURL: media.file, guestPath: staged, mode: "0644") else {
            throw InstallFailure(message: "Copying \(media.title) into the device failed. \(lastLog)")
        }
        try await runHelper(uid: 501, gid: 501, paths: [staged], what: "hand it to the device")
        let exe = "/tmp/ltm-\(toolName)-\(media.id)"
        var argv = [exe]
        var temporary = [exe]
        if let metadata = media.metadata {
            let plist = "/tmp/ltm-media-\(media.id).plist"
            guard await putFile(localURL: metadata, guestPath: plist, mode: "0644") else {
                throw InstallFailure(message: "Couldn\u{2019}t copy the video\u{2019}s details into the device. \(lastLog)")
            }
            argv.append(plist)
            temporary.append(plist)
        }
        argv.append(media.id)
        guard await putFile(localURL: tool, guestPath: exe, mode: "0755") else {
            throw InstallFailure(message: "Couldn\u{2019}t put \(toolName) into the device. \(lastLog)")
        }
        progress("Adding \(media.title) to \(media.kind == .photo ? "Photos" : "Videos")\u{2026}")
        let result = await run(argv, timeout: 180)
        for path in temporary { _ = await unlink(path: path) }
        let output = result.map { String(decoding: $0.output, as: UTF8.self) } ?? ""
        log("\(toolName): status \(result?.status ?? -1): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        guard let result, result.status == 0, output.contains("imported") else {
            let reason = output.split(separator: "\n").last.map(String.init) ?? "no answer"
            throw InstallFailure(message: "\(media.kind == .photo ? "Photos" : "Videos") didn\u{2019}t take \(media.title): \(reason)")
        }
    }
}

/// A movie from the photo picker, copied out of the picker's temporary file.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-pick-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

// MARK: - The sheet

struct MediaImportView: View {
    let agent: GuestAgent
    /// The A4 boards play 720p; the others want 640×480.
    let hd: Bool
    let onDismiss: () -> Void

    @State private var picks: [PhotosPickerItem] = []
    @State private var pickingFiles = false
    @State private var lines: [MusicImportView.Line] = []
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        NavigationView {
            ZStack {
                LTBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        GlassCard("Add photos and videos", symbol: "photo.on.rectangle") {
                            Text("Photos go into the device\u{2019}s Saved Photos (Camera Roll on the iPhones), videos into its Videos app, converted to what it plays. iPhone OS 3.1 or later.")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Theme.secondaryText)
                            PhotosPicker(selection: $picks, maxSelectionCount: 20, matching: .any(of: [.images, .videos]),
                                         photoLibrary: .shared()) {
                                Label("From Photos\u{2026}", systemImage: "photo").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                            Button { pickingFiles = true } label: {
                                Label("From Files\u{2026}", systemImage: "folder").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(busy)
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
            .navigationTitle("Photos & Videos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { onDismiss() }.foregroundStyle(Theme.accent) }
            }
        }
        .navigationViewStyle(.stack)
        .onChange(of: picks) { items in
            guard !items.isEmpty else { return }
            picks = []
            importPicks(items)
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
    }

    private func importPicks(_ items: [PhotosPickerItem]) {
        run(items.count) { index in
            let item = items[index]
            let isMovie = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            if isMovie {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                    throw InstallFailure(message: "That video couldn\u{2019}t be read (it may still be in iCloud).")
                }
                defer { try? FileManager.default.removeItem(at: movie.url) }
                return try await MediaPrep.video(movie.url, title: "Video \(index + 1)", hd: hd)
            }
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw InstallFailure(message: "That photo couldn\u{2019}t be read (it may still be in iCloud).")
            }
            return try MediaPrep.photo(data, title: "Photo \(index + 1)")
        }
    }

    private func importFiles(_ urls: [URL]) {
        run(urls.count) { index in
            let url = urls[index]
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let title = url.deletingPathExtension().lastPathComponent
            if (UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie)) == true {
                return try await MediaPrep.video(url, title: title, hd: hd)
            }
            return try MediaPrep.photo(try Data(contentsOf: url), title: title)
        }
    }

    private func run(_ count: Int, prepare: @escaping (Int) async throws -> PreparedMedia) {
        guard count > 0 else { return }
        busy = true
        Task {
            for index in 0..<count {
                status = "Item \(index + 1) of \(count): converting\u{2026}"
                do {
                    let media = try await prepare(index)
                    defer { try? FileManager.default.removeItem(at: media.directory) }
                    try await agent.importMedia(media) { text in status = text }
                    lines.append(.init(text: "\(media.title) is in \(media.kind == .photo ? "Photos" : "Videos")", good: true))
                } catch {
                    lines.append(.init(text: error.localizedDescription, good: false))
                }
            }
            busy = false
            status = lines.contains { !$0.good } ? "Finished, with problems." : "Finished."
        }
    }
}
