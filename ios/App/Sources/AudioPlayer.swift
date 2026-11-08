import AVFoundation
import Foundation

/// Plays the guest's sound. The emulator exposes its mixer as 44100 Hz stereo S16LE packets
/// (qemu_ios_audio_capture_*), the same feed the Mac app records from; here we play them instead.
final class AudioPlayer: @unchecked Sendable {
    private let qemu: QemuRuntime
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var ring = [Int16]()          // interleaved L,R
    private var running = false
    private let maxSamples = 44100 * 2    // ~1 s of stereo; older audio is dropped to keep latency low

    init(qemu: QemuRuntime) { self.qemu = qemu }

    func start() {
        guard !running else { return }
        running = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frames, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard let self else { return noErr }
            self.lock.lock()
            let available = self.ring.count / 2
            let n = min(Int(frames), available)
            for i in 0..<Int(frames) {
                let l: Float = i < n ? Float(self.ring[2 * i]) / 32768 : 0
                let r: Float = i < n ? Float(self.ring[2 * i + 1]) / 32768 : 0
                buffers[0].mData?.assumingMemoryBound(to: Float.self)[i] = l
                if buffers.count > 1 { buffers[1].mData?.assumingMemoryBound(to: Float.self)[i] = r }
            }
            if n > 0 { self.ring.removeFirst(n * 2) }
            self.lock.unlock()
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try? engine.start()

        let thread = Thread { [weak self] in self?.pump() }
        thread.name = "ltm-audio"
        thread.start()
    }

    func stop() {
        running = false
        engine.stop()
    }

    /// Waits for the VM to come up, starts a capture generation, then moves packets into the ring buffer.
    private func pump() {
        while running && !qemu.ready() { Thread.sleep(forTimeInterval: 0.25) }
        guard running else { return }
        let generation = qemu.audioStart()
        var packet = [UInt8](repeating: 0, count: 16384)
        while running {
            var seconds = 0.0
            let n = packet.withUnsafeMutableBytes { qemu.audioRead(generation, $0.baseAddress, 16384, &seconds) }
            if n < 0 { break }   // generation expired or failed
            if n == 0 { Thread.sleep(forTimeInterval: 0.01); continue }
            let count = Int(n) / 2
            lock.lock()
            packet.withUnsafeBytes { raw in
                ring.append(contentsOf: raw.bindMemory(to: Int16.self).prefix(count))
            }
            if ring.count > maxSamples { ring.removeFirst(ring.count - maxSamples) }
            lock.unlock()
        }
        qemu.audioStop(generation)
    }
}
