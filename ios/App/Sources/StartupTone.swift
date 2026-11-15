import AVFoundation
import Foundation

/// A tiny original startup tone, generated in-process, each time a device starts. The Mac app has its
/// own celebratory sound (special_trick.mp3) that we don't ship here; this is an original two-note bell written as
/// PCM. It is quiet, short, and respects the "Startup tone" setting.
@MainActor
enum StartupTone {
    private static var player: AVAudioPlayer?

    /// Called when a device starts (once per boot). It plays through the same audio session as the device's own
    /// sound (playback, so the ring/silent switch doesn't swallow it, as it did the ambient session this used to
    /// switch to, which also took the session away from the emulator's audio).
    static func play() {
        guard UserDefaults.standard.object(forKey: "startupTone") as? Bool ?? true, let url = cached() else { return }
        AudioSessionSetup.apply()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = 0.5
        player?.prepareToPlay()
        if player?.play() != true { LTMLog.note("startup tone: did not play") }
    }

    /// WAV on disk; made on first use, reused thereafter.
    private static func cached() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-startup.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data = wav()
        try? data.write(to: url)
        return url
    }

    /// Two short bells (E6 then A6), each a decaying sine with a light harmonic. 16-bit PCM, 22,050 Hz, mono, ~700 ms.
    private static func wav() -> Data {
        let sampleRate: Int = 22_050
        let duration = 0.7
        let total = Int(Double(sampleRate) * duration)
        var samples = [Int16]()
        samples.reserveCapacity(total)
        let notes: [(freq: Double, start: Double, length: Double)] = [
            (659.25, 0.00, 0.40),  // E5
            (880.00, 0.18, 0.50),  // A5
        ]
        for i in 0..<total {
            let t = Double(i) / Double(sampleRate)
            var value = 0.0
            for note in notes {
                let local = t - note.start
                if local < 0 || local > note.length { continue }
                let envelope = pow(1.0 - local / note.length, 2.2)
                // Fundamental + a quiet third harmonic for a bell-ish color.
                value += envelope * (sin(2 * .pi * note.freq * local) + 0.3 * sin(2 * .pi * note.freq * 3 * local))
            }
            let clipped = max(-0.8, min(0.8, value * 0.45))
            samples.append(Int16(clipped * Double(Int16.max)))
        }
        return wavFile(samples: samples, sampleRate: sampleRate)
    }

    private static func wavFile(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        u32(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16)            // fmt chunk size
        u16(1)             // PCM
        u16(1)             // channels
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))  // byte rate
        u16(2)             // block align
        u16(16)            // bits per sample
        data.append(contentsOf: Array("data".utf8))
        u32(bytes)
        samples.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }
        return data
    }
}
