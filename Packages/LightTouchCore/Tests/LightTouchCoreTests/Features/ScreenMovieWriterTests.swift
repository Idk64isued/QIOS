import AVFoundation
import CoreGraphics
import DeviceRuntime
import Foundation
import Testing

@testable import LightTouchCore

/// The guest's audio as the helper delivers it: 440 Hz left, 880 Hz right, 44.1 kHz S16LE in 10 ms packets on the
/// capture's own clock, with a one-second pause (1 s to 2 s) and 3 s in all. `now` is the clock the test advances.
nonisolated private final class ToneSource: @unchecked Sendable {  // lock-protected
    private let lock = NSLock()
    private var now = 0.0, frame = 0
    var time: Double {
        get { lock.withLock { now } }
        set { lock.withLock { now = newValue } }
    }

    /// One packet, or 0 bytes when the clock hasn't reached the next one (or the source is done).
    func read(_ buffer: UnsafeMutableRawPointer, _ seconds: inout Double) -> Int {
        lock.withLock {
            if frame == 44100 { frame = 88200 }
            if frame >= 132300 || Double(frame + 441) / 44100 > now { return 0 }
            seconds = Double(frame) / 44100
            let samples = buffer.assumingMemoryBound(to: Int16.self)
            for i in 0..<441 {
                samples[i * 2] = Int16(12000 * sin(2 * .pi * 440 * Double(frame) / 44100))
                samples[i * 2 + 1] = Int16(12000 * sin(2 * .pi * 880 * Double(frame) / 44100))
                frame += 1
            }
            return 1764
        }
    }

    /// LightTouchDevice's AudioPump, in process: drains the source into the GuestAudioCapture the recorder reads,
    /// as the helper's `.audio` and `.audioEnded` events would.
    func capture() -> GuestAudioCapture {
        nonisolated final class Flag: @unchecked Sendable {
            let lock = NSLock()
            var stopped = false
        }  // lock-protected
        let flag = Flag()
        let capture = GuestAudioCapture(
            clock: { [self] in time },
            stop: { _ in flag.lock.withLock { flag.stopped = true } }
        )
        capture.begin(generation: 1)
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                var seconds = -1.0
                let n = buffer.withUnsafeMutableBytes { read($0.baseAddress!, &seconds) }
                if n > 0 || seconds >= 0 {
                    capture.receive(.audio(generation: 1, seconds: seconds, pcm: Data(buffer[0..<n])))
                    if n > 0 { continue }
                }
                if flag.lock.withLock({ flag.stopped }) {
                    return capture.receive(.audioEnded(generation: 1, failed: false))
                }
                usleep(5000)
            }
        }
        return capture
    }
}

private func solid(_ width: Int, _ height: Int, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// A movie's audio as 44.1 kHz stereo, each packet placed at its timestamp (gaps silent), and its frames' pixels.
private struct Movie {
    let asset: AVURLAsset
    init(_ url: URL) { asset = AVURLAsset(url: url) }

    func audio() async throws -> [[Double]] {
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2
            ]
        )
        reader.add(output)
        #expect(reader.startReading())
        var channels: [[Double]] = [[], []]
        while let buffer = output.copyNextSampleBuffer() {
            let start = Int((buffer.presentationTimeStamp.seconds * 44100).rounded())
            let block = try #require(CMSampleBufferGetDataBuffer(buffer))
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            )
            let frames = length / 4
            let samples = UnsafeRawPointer(pointer!).assumingMemoryBound(to: Int16.self)
            for c in 0..<2 where channels[c].count < start + frames {
                channels[c] += Array(repeating: 0, count: start + frames - channels[c].count)
            }
            for i in 0..<frames where start + i >= 0 {
                for c in 0..<2 { channels[c][start + i] = Double(samples[i * 2 + c]) }
            }
        }
        return channels
    }

    func frame(at seconds: Double) async throws -> (width: Int, height: Int, rgb: (Int, Int) -> [Int]) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (width, height, { x, y in (0..<3).map { Int(bytes[(y * width + x) * 4 + $0]) } })
    }
}

/// TestSupport's temporary directory, for async bodies.
private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ltm-tests-" + UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func rms(_ samples: ArraySlice<Double>) -> Double {
    (samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count)).squareRoot()
}
/// A tone's frequency from its rising zero crossings.
private func frequency(_ samples: ArraySlice<Double>) -> Double {
    let s = Array(samples)
    let rising = (1..<s.count).filter { s[$0 - 1] < 0 && s[$0] >= 0 }
    guard let first = rising.first, let last = rising.last, last > first else { return 0 }
    return Double(rising.count - 1) * 44100 / Double(last - first)
}
private func near(_ a: [Int], _ b: [Int], _ tolerance: Int = 30) -> Bool {
    zip(a, b).allSatisfy { abs($0 - $1) < tolerance }
}

/// The production movie writer: native dimensions through portrait, landscape and rotation, the canvas background,
/// stereo audio on the capture's clock with its pause kept, and a take that survives a crash.
struct ScreenMovieWriterTests {
    enum Mode: String, CaseIterable { case portrait, landscape, rotated, canvas }
    static let orange = [255, 64, 0], blue = [0, 128, 255]

    func record(_ mode: Mode, to url: URL) async throws {
        let portrait = solid(320, 480, 1, 0.25, 0)
        let landscape = solid(480, 320, 0, 0.5, 1)
        let tones = ToneSource()
        let writer = ScreenMovieWriter()
        try await writer.start(
            url: url,
            audio: tones.capture(),
            canvasSize: mode == .canvas ? CGSize(width: 640, height: 400) : nil,
            background: mode == .canvas ? landscape : nil,
            screenSize: mode == .landscape ? CGSize(width: 480, height: 320) : CGSize(width: 320, height: 480)
        )
        for tick in 0...30 {
            tones.time = Double(tick) / 10
            let turned = mode == .landscape || ((mode == .rotated || mode == .canvas) && tick > 15)
            // mixer and video share the capture clock
            try await writer.append(turned ? landscape : portrait, seconds: 999)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await writer.finish(seconds: 999)
    }

    @Test(arguments: Mode.allCases)
    func geometryAudioAndPauseGap(_ mode: Mode) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("take.mov")
        do {
            try await record(mode, to: url)
            let movie = Movie(url)
            #expect(try await movie.asset.loadTracks(withMediaType: .audio).count == 1)
            let video = try await movie.asset.loadTracks(withMediaType: .video)
            #expect(video.count == 1)
            let expected =
                switch mode {
                case .portrait: CGSize(width: 320, height: 480)
                case .landscape: CGSize(width: 480, height: 320)
                case .rotated: CGSize(width: 320, height: 480)  // the screen as it was at the start
                case .canvas: CGSize(width: 640, height: 400)
                }
            #expect(try await video[0].load(.naturalSize) == expected)
            #expect(abs(try await movie.asset.load(.duration).seconds - 3) < 0.1)

            let audio = try await movie.audio()
            #expect(abs(Double(audio[0].count) / 44100 - 3) < 0.1, "\(Double(audio[0].count) / 44100) s of audio")
            for start in [0.2, 2.2] {
                let range = Int(start * 44100)..<Int((start + 0.5) * 44100)
                for (channel, hz) in [(0, 440.0), (1, 880.0)] {
                    #expect(abs(frequency(audio[channel][range]) - hz) < 3, "\(mode) at \(start) s, channel \(channel)")
                    #expect(rms(audio[channel][range]) > 7000)
                }
            }
            let gap = Int(1.2 * 44100)..<Int(1.8 * 44100)
            #expect(rms(audio[0][gap]) < 50 && rms(audio[1][gap]) < 50, "pause gap lost")

            for seconds in [0.5, 2.5] {
                let frame = try await movie.frame(at: seconds)
                let turned = mode == .landscape || ((mode == .rotated || mode == .canvas) && seconds > 1.5)
                let color = turned ? Self.blue : Self.orange
                #expect(
                    near(frame.rgb(frame.width / 2, frame.height / 2), color),
                    "\(mode) at \(seconds) s: \(frame.rgb(frame.width / 2, frame.height / 2))"
                )
                switch mode {
                case .portrait, .landscape:  // the screen reaches every corner: no padding, no scaling
                    #expect(near(frame.rgb(4, 4), color) && near(frame.rgb(frame.width - 5, frame.height - 5), color))
                case .canvas:
                    #expect(near(frame.rgb(4, 4), Self.blue), "canvas lost its background")
                case .rotated where turned:  // fitted, centered on black
                    #expect(frame.rgb(4, 4).max()! < 12, "turned screen lost its padding")
                    #expect(near(frame.rgb(4, frame.height / 2), color), "turned screen not fitted to the width")
                case .rotated:
                    #expect(near(frame.rgb(4, 4), color) && near(frame.rgb(frame.width - 5, frame.height - 5), color))
                }
            }
        }
    }
}
