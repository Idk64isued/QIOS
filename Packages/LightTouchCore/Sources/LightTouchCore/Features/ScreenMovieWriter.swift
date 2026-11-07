import AVFoundation
import CoreGraphics
import Darwin
import DeviceRuntime
import Foundation

/// The writer and pixel buffers stay on one actor. The producer awaits each
/// append; encoding cannot accumulate an unbounded queue of guest frames.
public actor ScreenMovieWriter {
    public init() {}
    private var canvasSize: CGSize?
    private var background: CGImage?
    private var outputSize = CGSize(width: 320, height: 480)
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var count = 0
    private var audioInput: AVAssetWriterInput?
    private var audioFormat: CMAudioFormatDescription?
    private var capture: GuestAudioCapture?
    private var finishing = false
    private var audioFrame: Int64 = 0

    /// `audio`: the device's capture (EmulatorController.startAudioCapture), or nil for a silent movie.
    /// `screenSize`: the screen's pixels as they're upright at the start (320×480 for the shipped iPod in portrait),
    /// a screen-only movie's frame. A movie can't change size: a screen turned later is fitted inside it on black.
    public func start(
        url: URL,
        audio: GuestAudioCapture? = nil,
        canvasSize: CGSize? = nil,
        background: CGImage? = nil,
        screenSize: CGSize = CGSize(width: 320, height: 480)
    ) throws {
        guard self.writer == nil, !finishing else { throw CaptureError.failed("A recording is already active.") }
        self.canvasSize = canvasSize
        self.background = background
        outputSize = canvasSize ?? screenSize
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        guard width > 0, height > 0 else { throw CaptureError.failed("Invalid recording size.") }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let transfer: String
        if #available(macOS 15.0, *) {
            transfer = AVVideoTransferFunction_IEC_sRGB
        } else {
            transfer = AVVideoTransferFunction_ITU_R_709_2
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: transfer,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ],
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(3_000_000, width * height * 8)]
            ]
        )
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )
        guard writer.canAdd(input) else { throw CaptureError.failed("Video encoding is unavailable.") }
        writer.add(input)
        let audioInput: AVAssetWriterInput?
        if audio != nil {
            let audio = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000
                ]
            )
            audio.expectsMediaDataInRealTime = true
            guard writer.canAdd(audio) else { throw CaptureError.failed("Audio encoding is unavailable.") }
            writer.add(audio)
            audioInput = audio
        } else {
            audioInput = nil
        }
        guard writer.startWriting() else { throw writer.error ?? CaptureError.failed("Couldn’t start recording.") }
        writer.startSession(atSourceTime: .zero)
        capture = audio
        self.audioInput = audioInput
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        count = 0
        audioFrame = 0
    }
    public func append(_ image: CGImage?, seconds: Double) async throws {
        guard !finishing else { return }
        _ = try await drainAudio()
        guard let image else { return }
        let seconds = capture?.seconds ?? seconds
        guard let writer, let input, let adaptor else { return }
        if writer.status == .failed { throw writer.error ?? CaptureError.failed("Recording failed.") }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
            let buffer
        else { throw CaptureError.failed("Couldn’t record the screen.") }
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CaptureError.failed("Couldn’t record the screen.")
        }
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferCGColorSpaceKey,
            sRGB,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_sRGB,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: Int(outputSize.width),
                height: Int(outputSize.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: sRGB,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            )
        else {
            throw CaptureError.failed("Couldn’t record the screen.")
        }
        let output = CGRect(origin: .zero, size: outputSize)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(output)
        if canvasSize != nil, let background {
            let factor = max(
                outputSize.width / CGFloat(background.width),
                outputSize.height / CGFloat(background.height)
            )
            let size = CGSize(
                width: CGFloat(background.width) * factor,
                height: CGFloat(background.height) * factor
            )
            context.draw(
                background,
                in: CGRect(
                    x: (output.width - size.width) / 2,
                    y: (output.height - size.height) / 2,
                    width: size.width,
                    height: size.height
                )
            )
        }
        // Fitted and centered: the canvas in its frame, or a screen turned since the start on black. A screen
        // at the frame's own size is drawn pixel for pixel.
        let native = canvasSize == nil && CGSize(width: image.width, height: image.height) == outputSize
        let factor = min(outputSize.width / CGFloat(image.width), outputSize.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
        context.interpolationQuality = native ? .none : .high
        context.draw(
            image,
            in: CGRect(
                x: (output.width - size.width) / 2,
                y: (output.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        )
        guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)) else {
            throw writer.error ?? CaptureError.failed("Couldn’t record the screen.")
        }
        count += 1
    }
    private func drainAudio(through end: Double? = nil) async throws -> Bool {
        guard let capture, let audioInput else { return true }
        guard let writer, writer.status != .failed else {
            throw self.writer?.error ?? CaptureError.failed("Audio recording failed.")
        }
        while audioInput.isReadyForMoreMediaData {
            guard let packet = try capture.read() else { return true }
            try await appendAudio(packet.data, seconds: packet.seconds, through: end)
            if packet.data.isEmpty { return true }
        }
        return false
    }

    private func appendAudio(_ data: Data, seconds: Double, through end: Double? = nil) async throws {
        guard audioInput != nil else { return }
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max / 44100), data.count % 4 == 0 else {
            throw CaptureError.failed("Couldn’t record the device’s audio.")
        }
        let target = Int64((seconds * 44100).rounded())
        let limit = end.map { Int64(max(0, $0 * 44100)) } ?? Int64.max
        // AAC encoding closes timestamp gaps. Supply silence explicitly, in
        // bounded chunks, so pauses and idle periods retain video alignment.
        while audioFrame < min(target, limit) {
            let frames = Int(min(4410, min(target, limit) - audioFrame))
            try await encodeAudio(Data(count: frames * 4), frames: frames)
        }
        let skipped = Int(min(Int64(data.count / 4), max(0, audioFrame - target)))
        let frames = min(data.count / 4 - skipped, Int(max(0, min(Int64(data.count / 4), limit - audioFrame))))
        guard frames > 0 else { return }
        try await encodeAudio(Data(data.dropFirst(skipped * 4)), frames: frames)
    }

    private func encodeAudio(_ data: Data, frames: Int) async throws {
        guard let audioInput, let writer else { return }
        let deadline = ContinuousClock.now + .seconds(10)
        while !audioInput.isReadyForMoreMediaData {
            guard writer.status == .writing, ContinuousClock.now < deadline else {
                throw writer.error ?? CaptureError.failed("Couldn’t record the device’s audio.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        if audioFormat == nil {
            var format = AudioStreamBasicDescription(
                mSampleRate: 44100,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 16,
                mReserved: 0
            )
            guard
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &format,
                    layoutSize: 0,
                    layout: nil,
                    magicCookieSize: 0,
                    magicCookie: nil,
                    extensions: nil,
                    formatDescriptionOut: &audioFormat
                ) == noErr
            else {
                throw CaptureError.failed("Couldn’t record the device’s audio.")
            }
        }
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: frames * 4,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: frames * 4,
                flags: 0,
                blockBufferOut: &block
            ) == noErr,
            let block
        else { throw CaptureError.failed("Couldn’t allocate an audio packet.") }
        let copied = data.withUnsafeBytes {
            guard let bytes = $0.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: bytes,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: frames * 4
            )
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 44100),
            presentationTimeStamp: CMTime(value: audioFrame, timescale: 44100),
            decodeTimeStamp: .invalid
        )
        var size = 4
        var sample: CMSampleBuffer?
        guard copied == noErr,
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: audioFormat,
                sampleCount: frames,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &size,
                sampleBufferOut: &sample
            ) == noErr,
            let sample, audioInput.append(sample)
        else {
            throw writer.error ?? CaptureError.failed("Couldn’t record the device’s audio.")
        }
        audioFrame += Int64(frames)
    }

    public func cancel() {
        capture?.stop()
        writer?.cancelWriting()
        capture = nil
        audioInput = nil
        audioFormat = nil
        writer = nil
        input = nil
        adaptor = nil
        finishing = false
    }

    public func finish(seconds: Double) async throws {
        guard let writer, let input, !finishing else { throw CaptureError.failed("No recording is active.") }
        finishing = true
        let end = capture?.seconds ?? seconds
        capture?.stop()
        defer {
            capture = nil
            audioInput = nil
            audioFormat = nil
            self.writer = nil
            self.input = nil
            self.adaptor = nil
            finishing = false
        }
        do {
            guard count > 0 else { throw CaptureError.failed("No device frames were recorded.") }
            // The helper drains what the guest had queued after the stop (<= 1 s),
            // then says so (.audioEnded).
            let deadline = ContinuousClock.now + .seconds(10)
            while true {
                let drained = try await drainAudio(through: end)
                if drained, capture?.isFinished ?? true { break }
                guard ContinuousClock.now < deadline else {
                    if drained { break }  // the device never ended its audio: keep what arrived
                    throw CaptureError.failed("Couldn’t record the device’s audio.")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            try await appendAudio(Data(), seconds: end, through: end)
            writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 44100))
            input.markAsFinished()
            audioInput?.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw writer.error ?? CaptureError.failed("Couldn’t finish recording.")
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
    }
}

public nonisolated enum CaptureError: LocalizedError {
    case failed(String)
    public var errorDescription: String? { if case .failed(let message) = self { message } else { nil } }
}

/// A recording's guest audio, pushed by the device's helper: `.audio` packets
/// (44.1 kHz stereo S16LE; an empty one marks silence through its time) after
/// `audioStart`, until `.audioEnded` once the stop has drained. Events arrive
/// on the main queue; the writer reads under the lock.
public nonisolated final class GuestAudioCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: @Sendable () -> Double
    private let stopSource: @Sendable (UInt64) -> Void
    private var generation: UInt64 = 0
    private var packets: [(data: Data, seconds: Double)] = []
    private var ended = false, failed = false, stopped = false

    /// `clock`: seconds since the capture started, the same monotonic clock the
    /// dylib stamps packets with. `stop`: ask the helper to stop that generation.
    public init(clock: @escaping @Sendable () -> Double, stop: @escaping @Sendable (UInt64) -> Void) {
        self.clock = clock
        stopSource = stop
    }

    /// The helper's capture generation (its audioStart reply).
    public func begin(generation: UInt64) { lock.withLock { self.generation = generation } }

    public func receive(_ event: LinkEvent) {
        lock.withLock {
            switch event {
            // Events can land before `begin`: nothing else is capturing then.
            case .audio(let g, let seconds, let pcm) where generation == 0 || g == generation:
                packets.append((pcm, seconds))
            case .audioEnded(let g, let didFail) where generation == 0 || g == 0 || g == generation:
                ended = true
                failed = didFail
            default: break
            }
        }
    }

    public var seconds: Double { clock() }

    public func stop() {
        let g: UInt64 = lock.withLock {
            stopped = true
            return generation
        }
        if g != 0 { stopSource(g) }
    }

    /// After stop(): the helper has delivered everything.
    public var isFinished: Bool { lock.withLock { ended && packets.isEmpty } }

    public func read() throws -> (data: Data, seconds: Double)? {
        try lock.withLock {
            if !packets.isEmpty { return packets.removeFirst() }
            if ended, failed, !stopped { throw CaptureError.failed("Couldn’t record the device’s audio.") }
            return nil
        }
    }
}
