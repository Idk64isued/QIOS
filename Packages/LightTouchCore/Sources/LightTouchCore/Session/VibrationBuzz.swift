// The sound of an iPhone's vibration motor, which the Mac plays while the guest runs it. The helper's status says
// whether the motor runs and how many times it has started (qemu_ios_ui_vibrator), read at the status poll; a start
// the poll missed (a buzz shorter than a poll) still plays, for `missedPulse`. render() fills the audio thread's
// buffers with a motor's buzz, ramped in and out so it neither clicks nor cuts off.

import Foundation
import os

nonisolated public final class VibrationBuzz: Sendable {
    public static let sampleRate = 44_100.0
    /// How long a start the poll missed sounds: the guest's own length for it is lost between two polls.
    static let missedPulse = 0.1
    /// Seconds from silence to full level, and back.
    static let ramp = 0.012
    /// An eccentric-mass motor's rotation rate, the buzz's fundamental. A calibration knob, not a measurement.
    static let motorHertz = 175.0
    /// Peak level, of 1.
    static let amplitude = 0.2

    private struct State {
        var running = false
        var pulses: UInt64?
        var burst = 0  // frames of a missed pulse still to play
        var level = 0.0
        var phase = 0.0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// One status read: the motor runs now, and its starts so far. A count that goes down (a restarted helper) is a
    /// new baseline, not a buzz.
    public func observe(running: Bool, pulses: UInt64) {
        state.withLock {
            if let last = $0.pulses, pulses > last, !running {
                $0.burst = max($0.burst, Int(Self.missedPulse * Self.sampleRate))
            }
            $0.pulses = pulses
            $0.running = running
        }
    }

    /// Nothing to play and nothing still fading out: the output can stop.
    public var isIdle: Bool { state.withLock { !$0.running && $0.burst == 0 && $0.level == 0 } }

    /// Mono samples at `sampleRate`, from the audio thread.
    public func render(_ samples: UnsafeMutableBufferPointer<Float>) {
        // Unchecked: the buffer is the caller's for the length of this call.
        state.withLockUnchecked { s in
            let step = 1 / (Self.ramp * Self.sampleRate)
            for i in samples.indices {
                let target: Double = s.running || s.burst > 0 ? 1 : 0
                if s.burst > 0 { s.burst -= 1 }
                s.level += min(max(target - s.level, -step), step)
                guard s.level > 0 else {
                    samples[i] = 0
                    continue
                }
                s.phase = (s.phase + Self.motorHertz / Self.sampleRate).truncatingRemainder(dividingBy: 1)
                // A clipped sine and its octave: the rattle of a weight spinning off center.
                let angle = 2 * Double.pi * s.phase
                let buzz = 0.8 * tanh(4 * sin(angle)) + 0.2 * sin(2 * angle)
                samples[i] = Float(s.level * Self.amplitude * buzz)
            }
        }
    }
}
