import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Media files for the preparation tests, made here with the system's own encoders (and, for MP3, which macOS
/// can't encode, silent frames written by hand).
enum MediaFixtures {
    typealias RGBA = (UInt8, UInt8, UInt8, UInt8)

    /// An image `width`×`height` painted by `fill` (rectangles in pixel coordinates, top-left origin), written as
    /// `type` with the given EXIF orientation.
    static func image(
        _ url: URL,
        width: Int,
        height: Int,
        type: UTType,
        orientation: Int? = nil,
        background: RGBA = (0, 0, 0, 0),
        fill: [(CGRect, RGBA)]
    ) throws {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        func paint(_ rect: CGRect, _ c: RGBA) {
            context.setFillColor(
                red: CGFloat(c.0) / 255,
                green: CGFloat(c.1) / 255,
                blue: CGFloat(c.2) / 255,
                alpha: CGFloat(c.3) / 255
            )
            context.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        }
        paint(CGRect(x: 0, y: 0, width: width, height: height), background)
        for (rect, color) in fill { paint(rect, color) }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The decoded pixels of an image file, and a sampler at (x, y) from the top left.
    static func pixels(_ url: URL) throws -> (width: Int, height: Int, at: (Int, Int) -> RGBA) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let copy = data
        return (
            width, height,
            { x, y in
                let i = (y * width + x) * 4
                return (copy[i], copy[i + 1], copy[i + 2], copy[i + 3])
            }
        )
    }

    static func isProgressiveJPEG(_ url: URL) -> Bool {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (properties?[kCGImagePropertyJFIFDictionary] as? [CFString: Any])?[kCGImagePropertyJFIFIsProgressive]
            as? Bool == true
    }

    /// A stereo 440 Hz tone, `seconds` long at 44.1 kHz, in `format` (kAudioFormatMPEG4AAC or
    /// kAudioFormatAppleLossless in .m4a, kAudioFormatLinearPCM in .wav).
    static func tone(_ url: URL, seconds: Double = 6, format: AudioFormatID) throws {
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        var settings: [String: Any] = [AVFormatIDKey: format, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2]
        if format == kAudioFormatLinearPCM {
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
        }
        if format == kAudioFormatAppleLossless { settings[AVEncoderBitDepthHintKey] = 16 }
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(seconds * 44100)
        let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { samples[i] = Float(0.25 * sin(2 * Double.pi * 440 * Double(i) / 44100)) }
        }
        try file.write(from: buffer)
    }

    /// `seconds` of silent MPEG-1 Layer III, 128 kbit/s, 44.1 kHz stereo: frames whose side information is all
    /// zero decode as silence.
    static func silentMP3(_ url: URL, seconds: Double = 6) throws {
        let frameCount = Int((seconds * 44100 / 1152).rounded(.up))
        var frame = Data([0xFF, 0xFB, 0x90, 0x00])
        frame.append(Data(count: 417 - 4))
        try Data((0..<frameCount).flatMap { _ in frame }).write(to: url)
    }

    /// The AAC packets of an .m4a as raw ADTS (what a .aac file holds).
    static func adts(from m4a: URL, to url: URL) async throws {
        let asset = AVURLAsset(url: m4a)
        let track = try await asset.loadTracks(withMediaType: .audio)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var data = Data()
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            )
            let bytes = Data(bytes: pointer!, count: length)
            var offset = 0
            for index in 0..<CMSampleBufferGetNumSamples(buffer) {
                let size = CMSampleBufferGetSampleSize(buffer, at: index)
                let packet = bytes.subdata(in: offset..<offset + size)
                offset += size
                let total = packet.count + 7
                // AAC LC (profile 1 = object type 2 - 1), 44.1 kHz (index 4), two channels, no CRC.
                data.append(contentsOf: [
                    0xFF, 0xF1, UInt8(1 << 6 | 4 << 2 | 2 >> 2), UInt8((2 & 3) << 6 | (total >> 11)),
                    UInt8((total >> 3) & 0xFF), UInt8((total & 7) << 5 | 0x1F), 0xFC
                ])
                data.append(packet)
            }
        }
        guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        try data.write(to: url)
    }

    /// A `width`×`height` H.264 movie at 30 fps, `seconds` long, moving color bars, with a stereo AAC tone track.
    @concurrent nonisolated static func movie(_ url: URL, width: Int, height: Int, seconds: Int = 6) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        let audio = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
            ]
        )
        video.expectsMediaDataInRealTime = true
        audio.expectsMediaDataInRealTime = true
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: true)!
        var audioTime = 0
        func ready(_ input: AVAssetWriterInput) async throws {
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        /// The tone up to `end` samples, a tenth of a second at a time.
        func appendAudio(until end: Int) async throws {
            while audioTime < end {
                try await ready(audio)
                let count = min(4410, end - audioTime)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                for i in 0..<count {
                    let v = Float(0.25 * sin(2 * Double.pi * 440 * Double(audioTime + i) / 44100))
                    buffer.floatChannelData![0][2 * i] = v
                    buffer.floatChannelData![0][2 * i + 1] = v
                }
                var sample: CMSampleBuffer?
                var timing = CMSampleTimingInfo(
                    duration: CMTime(value: 1, timescale: 44100),
                    presentationTimeStamp: CMTime(value: CMTimeValue(audioTime), timescale: 44100),
                    decodeTimeStamp: .invalid
                )
                CMSampleBufferCreate(
                    allocator: nil,
                    dataBuffer: nil,
                    dataReady: false,
                    makeDataReadyCallback: nil,
                    refcon: nil,
                    formatDescription: format.formatDescription,
                    sampleCount: count,
                    sampleTimingEntryCount: 1,
                    sampleTimingArray: &timing,
                    sampleSizeEntryCount: 0,
                    sampleSizeArray: nil,
                    sampleBufferOut: &sample
                )
                CMSampleBufferSetDataBufferFromAudioBufferList(
                    sample!,
                    blockBufferAllocator: nil,
                    blockBufferMemoryAllocator: nil,
                    flags: 0,
                    bufferList: buffer.audioBufferList
                )
                audio.append(sample!)
                audioTime += count
            }
        }
        // Interleaved a frame at a time: the writer stops taking one track while the other lags.
        for frame in 0..<seconds * 30 {
            try await appendAudio(until: (frame + 1) * 44100 / 30)
            try await ready(video)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer!)
            // Eight vertical bars moving a little each frame: each row is one pattern, copied down.
            let pattern = (0..<width).flatMap { x -> [UInt8] in
                let bar = ((x + frame * 8) / max(width / 8, 1)) % 8
                return [UInt8((bar & 1) * 255), UInt8(((bar >> 1) & 1) * 255), UInt8(((bar >> 2) & 1) * 255), 255]
            }
            for y in 0..<height {
                pattern.withUnsafeBytes {
                    (base + y * row).update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: width * 4)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        video.markAsFinished()
        audio.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// A movie's video track as the device decodes it: size, frame rate, H.264 profile_idc and level_idc (from its
    /// avcC), and each audio track's codec, channels and sample rate.
    nonisolated struct MovieFormat: Sendable {
        var width = 0, height = 0, frameRate: Float = 0, codec: FourCharCode = 0, profile = 0, level = 0
        var audio: [(codec: AudioFormatID, channels: UInt32, rate: Double)] = []
    }
    @concurrent nonisolated static func format(of url: URL) async throws -> MovieFormat {
        let asset = AVURLAsset(url: url)
        var result = MovieFormat()
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let description = try await track.load(.formatDescriptions)[0]
        let size = CMVideoFormatDescriptionGetDimensions(description)
        result.width = Int(size.width)
        result.height = Int(size.height)
        result.frameRate = try await track.load(.nominalFrameRate)
        result.codec = CMFormatDescriptionGetMediaSubType(description)
        let atoms =
            CMFormatDescriptionGetExtension(
                description,
                extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
            ) as? [String: Any]
        if let avcC = atoms?["avcC"] as? Data, avcC.count > 3 {
            result.profile = Int(avcC[1])
            result.level = Int(avcC[3])
        }
        for audio in try await asset.loadTracks(withMediaType: .audio) {
            for format in try await audio.load(.formatDescriptions) {
                let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee
                result.audio.append((stream.mFormatID, stream.mChannelsPerFrame, stream.mSampleRate))
            }
        }
        return result
    }
}
