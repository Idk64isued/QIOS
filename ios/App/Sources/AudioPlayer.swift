import AVFoundation
import Foundation
import os

/// Plays the guest's sound. The emulator exposes its mixer as 44100 Hz stereo S16LE packets
/// (qemu_ios_audio_capture_*), the same feed the Mac app records from; here we play them instead.
///
/// The device is emulated, so its sound arrives at the pace the emulator manages, not at the pace a speaker wants
/// it — on a slow board (the iPod touch 1G with software graphics) it comes in bursts with gaps between them. The
/// first version played whatever had arrived the moment it arrived, so every gap was a click into silence and every
/// burst a click back out: sound that was right, delivered as crackle. This one keeps a small jitter buffer: it
/// waits until it holds a little audio before it plays, waits again whenever it runs dry instead of stuttering
/// sample by sample, fades at both edges so a gap is a gap rather than a click, and trims itself back if it ever
/// starts running late.
final class AudioPlayer: @unchecked Sendable {
    private let qemu: QemuRuntime
    private let engine = AVAudioEngine()

    // A fixed ring of interleaved L,R samples, allocated once: nothing on the audio thread allocates or moves memory.
    private let capacity = 44100 * 2 * 2          // two seconds of stereo, in samples
    private let ring: UnsafeMutablePointer<Int16>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var readIndex = 0                      // samples
    private var count = 0                          // samples buffered

    // The jitter buffer, in stereo frames.
    private let startFrames = 44100 * 12 / 100     // 120 ms before playing, or resuming after running dry
    private let lateFrames = 44100 * 45 / 100      // more than 450 ms buffered means we are falling behind...
    private let trimToFrames = 44100 * 15 / 100    // ...so drop back to 150 ms

    // Audio-thread state.
    private var playing = false
    private var gain: Float = 0
    private let gainStep: Float = 1.0 / 220        // ~5 ms fade
    private var lastLeft: Float = 0
    private var lastRight: Float = 0

    private var running = false

    init(qemu: QemuRuntime) {
        self.qemu = qemu
        ring = UnsafeMutablePointer<Int16>.allocate(capacity: capacity)
        ring.initialize(repeating: 0, count: capacity)
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        ring.deallocate()
        lock.deallocate()
    }

    func start() {
        guard !running else { return }
        running = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frames, abl -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let left = buffers[0].mData?.assumingMemoryBound(to: Float.self)
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            self.render(frames: Int(frames), left: left, right: right)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try? engine.start()

        let thread = Thread { [weak self] in self?.pump() }
        thread.name = "ltm-audio"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        running = false
        engine.stop()
    }

    // MARK: - Audio thread

    private func render(frames: Int, left: UnsafeMutablePointer<Float>?, right: UnsafeMutablePointer<Float>?) {
        os_unfair_lock_lock(lock)
        if !playing, count / 2 >= startFrames { playing = true }
        for i in 0..<frames {
            var l: Float
            var r: Float
            if playing, count >= 2 {
                l = Float(ring[readIndex]) / 32768
                r = Float(ring[readIndex + 1]) / 32768
                readIndex = (readIndex + 2) % capacity
                count -= 2
                gain = min(1, gain + gainStep)
                lastLeft = l
                lastRight = r
            } else {
                // Dry. Let the last sample die away rather than dropping to zero (that drop is the click), and
                // wait for the buffer to fill back up before playing again.
                if playing { playing = false }
                gain = max(0, gain - gainStep)
                l = lastLeft
                r = lastRight
            }
            left?[i] = l * gain
            right?[i] = r * gain
        }
        os_unfair_lock_unlock(lock)
    }

    // MARK: - Producer

    /// Waits for the VM to come up, starts a capture generation, then moves packets into the ring.
    private func pump() {
        while running && !qemu.ready() { Thread.sleep(forTimeInterval: 0.25) }
        guard running else { return }
        let generation = qemu.audioStart()
        var packet = [UInt8](repeating: 0, count: 16384)
        while running {
            var seconds = 0.0
            let n = packet.withUnsafeMutableBytes { qemu.audioRead(generation, $0.baseAddress, 16384, &seconds) }
            if n < 0 { break }   // generation expired or failed
            if n == 0 { Thread.sleep(forTimeInterval: 0.005); continue }
            packet.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                enqueue(samples.baseAddress!, count: Int(n) / 2)
            }
        }
        qemu.audioStop(generation)
    }

    private func enqueue(_ samples: UnsafePointer<Int16>, count incoming: Int) {
        guard incoming > 0 else { return }
        os_unfair_lock_lock(lock)
        // Never hold more than the ring: drop the oldest to make room.
        let overflow = count + incoming - capacity
        if overflow > 0 {
            let drop = (overflow + 1) & ~1
            readIndex = (readIndex + drop) % capacity
            count -= drop
        }
        var writeIndex = (readIndex + count) % capacity
        for i in 0..<incoming {
            ring[writeIndex] = samples[i]
            writeIndex = (writeIndex + 1) % capacity
        }
        count += incoming
        // Running late: more than half a second queued means the sound now trails the screen. Catch up.
        if count / 2 > lateFrames {
            let drop = count - trimToFrames * 2
            readIndex = (readIndex + drop) % capacity
            count -= drop
        }
        os_unfair_lock_unlock(lock)
    }
}
