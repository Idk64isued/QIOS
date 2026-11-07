import Testing

@testable import SessionKit

/// Motion runs split at rests, and the rate and tail taken inside them.
struct MotionFramesTests {
    static func run(from start: Double, hz: Double, count: Int) -> [Double] {
        (0..<count).map { start + Double($0) / hz }
    }

    @Test func restsDoNotDiluteTheRate() {
        // Two half-second 60 Hz runs with a second of rest between: 60 fps of motion, not ~30 over the window.
        let m = MotionFrames(times: Self.run(from: 0, hz: 60, count: 30) + Self.run(from: 1.5, hz: 60, count: 30))
        #expect(m.frames == 60 && m.runs == 2)
        #expect(abs(m.fps - 60) < 0.01)
        #expect(abs(m.p50 - 16.67) < 0.01 && abs(m.longest - 16.67) < 0.01)
    }

    @Test func aThirtyMillisecondSamplerReads33() {
        // What the app got before frames were published on the vsync: QEMU's 30 ms display refresh.
        let m = MotionFrames(times: Self.run(from: 0, hz: 1 / 0.030, count: 40))
        #expect(m.runs == 1 && abs(m.fps - 33.3) < 0.1)
    }

    @Test func aHeldFrameShowsInTheTail() {
        var times = Self.run(from: 0, hz: 60, count: 40)
        for i in 20..<times.count { times[i] += 0.05 }  // one 66.7 ms interval: a hitch, not a rest
        let m = MotionFrames(times: times)
        #expect(m.runs == 1)
        #expect(abs(m.longest - 66.67) < 0.01 && abs(m.p50 - 16.67) < 0.01)
        #expect(m.fps < 60)
    }

    @Test func nothingMovedIsZero() {
        #expect(MotionFrames(times: []) == MotionFrames(times: []))
        #expect(MotionFrames(times: [1]).fps == 0)
    }
}
