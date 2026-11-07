/// New-frame times during a gesture, scored as qemu-ios's tests/ipad1/jank.py scores a frame timeline: split into
/// runs at gaps over 100 ms (the screen at rest), the rate and the interval tail are taken inside the runs, so the
/// pauses before, between and after the moving parts don't dilute them.
public struct MotionFrames: Equatable, Sendable {
    public var frames = 0
    public var runs = 0
    /// Frames per second of motion: in-run intervals over their total length.
    public var fps = 0.0
    /// In-run intervals, ms.
    public var p50 = 0.0
    public var p95 = 0.0
    public var longest = 0.0

    /// `times` in seconds, ascending.
    public init(times: [Double]) {
        frames = times.count
        guard times.count > 1 else {
            runs = times.count
            return
        }
        var intervals: [Double] = []
        runs = 1
        for (a, b) in zip(times, times.dropFirst()) {
            if b - a > 0.1 { runs += 1 } else { intervals.append(b - a) }
        }
        guard !intervals.isEmpty else { return }
        fps = Double(intervals.count) / intervals.reduce(0, +)
        let sorted = intervals.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(q * Double(sorted.count)))] * 1000 }
        p50 = at(0.5)
        p95 = at(0.95)
        longest = sorted.last! * 1000
    }
}
