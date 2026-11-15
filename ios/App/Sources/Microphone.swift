import AVFoundation
import Foundation

/// The app's one audio session setup, so the player, the volume buttons and the microphone agree on it: playback
/// only, or play-and-record (out of the speaker, not the earpiece) while the microphone is on.
enum AudioSessionSetup {
    static var wantsMicrophone = false

    static func apply() {
        let session = AVAudioSession.sharedInstance()
        do {
            if wantsMicrophone {
                try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            } else {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
        } catch {
            LTMLog.note("audio session: \(error.localizedDescription)")
        }
    }
}

/// This phone's microphone as the emulated device's (qemu-ios patch 0007): the audio is converted to 44.1 kHz and
/// handed to the emulator, whose I2S port for the codec gives it to the guest when the guest records (Voice Memos,
/// a game's voice chat, a call). The machines with a capture path are the S5L8920 and A4 ones — iPhone 3GS, iPod
/// touch 3G and 4G, iPhone 4, iPad; the iPod touch 2G and the 1.x boards' I2S models have no input at all.
final class Microphone: @unchecked Sendable {
    typealias Write = @convention(c) (UnsafePointer<Int16>?, Int32) -> Int32
    typealias Enable = @convention(c) (Bool) -> Void

    private let engine = AVAudioEngine()
    private let write: Write
    private let enable: Enable
    private let listening: (@convention(c) () -> Bool)?
    private var converter: AVAudioConverter?
    private(set) var running = false

    /// The boards whose machines take microphone input.
    static func supported(board: String?) -> Bool {
        ["n18ap", "n88ap", "n81ap", "n90ap", "k48ap"].contains(board ?? "")
    }

    /// nil when this emulator build has no microphone input.
    init?(qemu: QemuRuntime) {
        guard let write = qemu.micWrite, let enable = qemu.micEnable else { return nil }
        self.write = write
        self.enable = enable
        listening = qemu.micListening
    }

    /// Whether something on the device is reading the microphone right now.
    var guestIsListening: Bool { running && (listening?() ?? false) }

    /// Asks for access, then starts. A line saying why not, or nil once it's running.
    @MainActor
    func start() async -> String? {
        guard !running else { return nil }
        let granted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
        guard granted else { return "Light Touch isn\u{2019}t allowed to use the microphone (Settings \u{203A} Privacy \u{203A} Microphone)." }
        AudioSessionSetup.wantsMicrophone = true
        AudioSessionSetup.apply()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else {
            stopSession()
            return "This phone has no microphone input available right now."
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.feed(buffer, as: outFormat)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            stopSession()
            return "The microphone didn\u{2019}t start: \(error.localizedDescription)"
        }
        enable(true)
        running = true
        LTMLog.note("microphone: on (\(Int(inFormat.sampleRate)) Hz, \(inFormat.channelCount) ch in)")
        return nil
    }

    func stop() {
        guard running else { return }
        running = false
        enable(false)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        stopSession()
        LTMLog.note("microphone: off")
    }

    private func stopSession() {
        AudioSessionSetup.wantsMicrophone = false
        AudioSessionSetup.apply()
    }

    /// The audio thread: convert one buffer to 44.1 kHz mono, double it into stereo, hand it over.
    private func feed(_ buffer: AVAudioPCMBuffer, as format: AVAudioFormat) {
        guard let converter, buffer.frameLength > 0 else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        _ = converter.convert(to: converted, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let mono = converted.int16ChannelData?[0] else { return }
        let n = Int(converted.frameLength)
        guard n > 0 else { return }
        var stereo = [Int16](repeating: 0, count: n * 2)
        for i in 0..<n {
            stereo[2 * i] = mono[i]
            stereo[2 * i + 1] = mono[i]
        }
        _ = stereo.withUnsafeBufferPointer { write($0.baseAddress, Int32(n)) }
    }
}
