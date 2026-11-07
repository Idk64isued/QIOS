// Plays a device's vibration motor (VibrationBuzz) through the Mac's output while the guest runs it, unless
// Settings ▸ General ▸ Play vibration sound is off. The engine runs only around a buzz: it starts with one and stops
// once the buzz has been silent a while, so an idle device holds no audio hardware.

import AVFoundation
import LightTouchCore

final class VibrationSound {
    /// UserDefaults key for Settings ▸ General ▸ Play vibration sound (on unless turned off).
    static let key = "PlayVibrationSound"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    private let buzz = VibrationBuzz()
    private var engine: AVAudioEngine?
    private var idleSince: Date?

    /// One status read (SharedStatus.vibrating, vibratorPulses).
    func update(running: Bool, pulses: UInt64) {
        buzz.observe(running: running, pulses: pulses)
        guard Self.isEnabled else { return stop() }
        guard buzz.isIdle else {
            idleSince = nil
            if engine == nil { start() }
            return
        }
        guard engine != nil else { return }
        let since = idleSince ?? Date()
        idleSince = since
        if Date().timeIntervalSince(since) > 2 { stop() }
    }

    func stop() {
        engine?.stop()
        engine = nil
        idleSince = nil
    }

    private func start() {
        let engine = AVAudioEngine()
        let source = Self.makeSource(buzz)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: source.outputFormat(forBus: 0))
        do {
            try engine.start()
            self.engine = engine
        } catch {
            logEvent("vibration sound: \(error.localizedDescription)")
        }
    }

    /// Off the main actor: its render block runs on the audio thread.
    nonisolated private static func makeSource(_ buzz: VibrationBuzz) -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: VibrationBuzz.sampleRate, channels: 1)
        return AVAudioSourceNode(format: format!) { _, _, frames, list in
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                let samples = buffer.mData?.assumingMemoryBound(to: Float.self)
                buzz.render(UnsafeMutableBufferPointer(start: samples, count: Int(frames)))
            }
            return noErr
        }
    }
}
