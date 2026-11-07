import Testing

@testable import LightTouchCore

/// The motor's on/off as the status poll reads it, turned into the buzz the Mac plays: sound while it runs, a short
/// buzz for a start the poll missed, nothing for a restarted helper's count, and no click at either end.
struct VibrationBuzzTests {
    /// `seconds` of output, rendered in the audio thread's 512-frame slices.
    private func render(_ buzz: VibrationBuzz, seconds: Double) -> [Float] {
        var out: [Float] = []
        var remaining = Int(seconds * VibrationBuzz.sampleRate)
        while remaining > 0 {
            var slice = [Float](repeating: .nan, count: min(512, remaining))
            slice.withUnsafeMutableBufferPointer { buzz.render($0) }
            out += slice
            remaining -= slice.count
        }
        return out
    }

    private func loud(_ samples: some Collection<Float>) -> Int { samples.count { abs($0) > 0.05 } }

    @Test func itBuzzesWhileTheMotorRunsAndStopsWithIt() {
        let buzz = VibrationBuzz()
        buzz.observe(running: false, pulses: 0)
        #expect(render(buzz, seconds: 0.1).allSatisfy { $0 == 0 })
        #expect(buzz.isIdle)
        buzz.observe(running: true, pulses: 1)
        let on = render(buzz, seconds: 0.4)
        #expect(loud(on) > on.count / 2)
        #expect(!buzz.isIdle)
        buzz.observe(running: false, pulses: 1)
        let fading = render(buzz, seconds: 0.05)
        #expect(fading.suffix(1000).allSatisfy { $0 == 0 })
        #expect(buzz.isIdle)
        #expect(render(buzz, seconds: 0.5).allSatisfy { $0 == 0 })
    }

    @Test func aStartThePollMissedStillBuzzesBriefly() {
        let buzz = VibrationBuzz()
        buzz.observe(running: false, pulses: 3)
        // Started and stopped again between two polls.
        buzz.observe(running: false, pulses: 4)
        let missed = render(buzz, seconds: 0.3)
        let rate = VibrationBuzz.sampleRate
        #expect(loud(missed.prefix(Int(VibrationBuzz.missedPulse * rate))) > Int(0.05 * rate))
        #expect(
            missed.dropFirst(Int((VibrationBuzz.missedPulse + 2 * VibrationBuzz.ramp) * rate)).allSatisfy { $0 == 0 })
        #expect(buzz.isIdle)
    }

    @Test func aRestartedHelperCountingFromZeroIsNotABuzz() {
        let buzz = VibrationBuzz()
        buzz.observe(running: false, pulses: 7)
        buzz.observe(running: false, pulses: 0)
        #expect(render(buzz, seconds: 0.3).allSatisfy { $0 == 0 })
    }

    @Test func itRampsInAndOutWithoutAClick() {
        let buzz = VibrationBuzz()
        buzz.observe(running: true, pulses: 1)
        let start = render(buzz, seconds: 0.2)
        let largestStep = zip(start, start.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(abs(start[0]) < 0.01)
        #expect(largestStep < 0.1)
        buzz.observe(running: false, pulses: 1)
        let end = render(buzz, seconds: 0.05)
        let joined = [start.last ?? 0] + end
        #expect((zip(joined, joined.dropFirst()).map { abs($1 - $0) }.max() ?? 0) < 0.1)
    }
}
