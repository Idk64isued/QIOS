import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

/// Records the device's screen and its sound into a movie (H.264 and AAC in an .mp4), the Mac app's Record Screen.
/// DisplayUIView hands every new guest frame to the recording in progress and AudioPlayer every packet of sound it
/// takes from the emulator, so recording costs nothing while it is off and needs no second reader of either.
/// The guest only draws when something changes, so the movie has as many frames as the device drew (a still screen
/// is one long frame); the last frame is repeated at the end so the movie lasts as long as the recording did.
final class ScreenRecorder: @unchecked Sendable {
    private static let lock = NSLock()
    private static var current: ScreenRecorder?

    /// The recording in progress, if any.
    static var active: ScreenRecorder? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    enum Failure: Error, LocalizedError {
        case cannotStart(String)
        var errorDescription: String? {
            switch self { case .cannotStart(let why): return why }
        }
    }

    let url: URL
    let width: Int, height: Int
    private let queue = DispatchQueue(label: "lighttouch.recorder")
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let start = CACurrentMediaTime()
    private var lastVideo = CMTime.invalid
    private var lastBuffer: CVPixelBuffer?
    private var audioFrames: Int64 = 0
    private var audioOffset: Int64?
    private var audioFormat: CMAudioFormatDescription?
    private var finished = false

    /// Starts recording a screen of `width` × `height` pixels (the guest's framebuffer).
    static func start(width: Int, height: Int) throws -> ScreenRecorder {
        let recorder = try ScreenRecorder(width: width, height: height)
        lock.lock()
        current = recorder
        lock.unlock()
        LTMLog.note("recording: started, \(width)x\(height)")
        return recorder
    }

    private init(width: Int, height: Int) throws {
        self.width = width
        self.height = height
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        url = FileManager.default.temporaryDirectory.appendingPathComponent("Light Touch \(f.string(from: Date())).mp4")
        try? FileManager.default.removeItem(at: url)
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) } catch {
            throw Failure.cannotStart("Couldn\u{2019}t start the movie: \(error.localizedDescription)")
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, width * height * 8)],
        ])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else {
            throw Failure.cannotStart("This phone can\u{2019}t make a movie of a \(width)\u{00D7}\(height) screen.")
        }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else {
            throw Failure.cannotStart("Couldn\u{2019}t start the movie: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16,
            mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        audioFormat = format
    }

    private var now: CMTime { CMTime(seconds: CACurrentMediaTime() - start, preferredTimescale: 600) }

    /// One guest frame: BGRA, `width` × `height`, rows packed. Frames of another size are skipped.
    func append(bgra: Data, width w: Int, height h: Int) {
        guard w == width, h == height else { return }
        let time = now
        queue.async { [self] in
            guard !finished, video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                bgra.withUnsafeBytes { raw in
                    guard let src = raw.baseAddress else { return }
                    for row in 0..<h {
                        memcpy(base + row * stride, src + row * w * 4, w * 4)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            appendVideo(buffer, at: time)
        }
    }

    private func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) {
        if lastVideo.isValid, CMTimeCompare(time, lastVideo) <= 0 { return }
        if adaptor.append(buffer, withPresentationTime: time) {
            lastVideo = time
            lastBuffer = buffer
        }
    }

    /// Stereo 16-bit samples at 44.1 kHz, `count` of them (two per frame), as the emulator's mixer makes them.
    func appendAudio(_ samples: UnsafePointer<Int16>, count: Int) {
        let frames = count / 2
        guard frames > 0 else { return }
        let data = Data(bytes: samples, count: frames * 4)
        let arrival = CACurrentMediaTime() - start
        queue.async { [self] in
            guard !finished, let audioFormat else { return }
            if audioOffset == nil { audioOffset = Int64(arrival * 44100) }
            let pts = CMTime(value: (audioOffset ?? 0) + audioFrames, timescale: 44100)
            audioFrames += Int64(frames)
            guard audio.isReadyForMoreMediaData else { return }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block) == noErr,
                let block
            else { return }
            let copied = data.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
            }
            guard copied == noErr else { return }
            var sample: CMSampleBuffer?
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: audioFormat, sampleCount: frames,
                presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample) == noErr,
                let sample
            else { return }
            audio.append(sample)
        }
    }

    /// Ends the recording; `done` gets the movie (nil if nothing could be written), on the main queue.
    func stop(_ done: @escaping (URL?) -> Void) {
        Self.lock.lock()
        if Self.current === self { Self.current = nil }
        Self.lock.unlock()
        let end = now
        queue.async { [self] in
            guard !finished else { return }
            if let lastBuffer { appendVideo(lastBuffer, at: end) }
            finished = true
            video.markAsFinished()
            audio.markAsFinished()
            writer.endSession(atSourceTime: end)
            writer.finishWriting { [self] in
                let ok = writer.status == .completed && lastVideo.isValid
                LTMLog.note("recording: " + (ok ? "saved \(Int(end.seconds)) s" : "failed \(writer.error?.localizedDescription ?? "(no frames)")"))
                DispatchQueue.main.async { done(ok ? url : nil) }
            }
        }
    }
}
