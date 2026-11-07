// For `flicks`: a synthetic two-finger trackpad gesture over the screen, as AppKit delivers one (the finger phase, then
// the momentum phase), through the app's ScrollDrag to the link at the events' own times.

import DeviceRuntime
import Foundation
import ImageIO
import LightTouchCore

struct TrackpadEvent {
    var ms: Double
    /// The finger phase; empty for the momentum phase's events.
    var phase: ScrollDrag.Phase = []
    /// Scroll points along the gesture's direction.
    var points = 0.0
}

/// A gesture of KIND at ~120 Hz with a little jitter, as a trackpad reports one: `flick`, a quick short swipe whose
/// fingers leave at speed, then the momentum phase; or `slow`, a short drag that comes to rest before the fingers lift
/// (no momentum).
func trackpadGesture(_ kind: String) -> [TrackpadEvent] {
    var t = 0.0
    func tick() -> Double {
        t += Double.random(in: 7...10)
        return t
    }
    let peak = Double.random(in: 18...30)
    let finger =
        kind == "slow"
        ? Array(repeating: 2.0, count: 40) + [1.5, 1, 0.5, 0.25]
        : [0.15, 0.4, 0.7, 0.95, 1, 0.75, 0.4].map { $0 * peak }
    var events = [TrackpadEvent(ms: 0, phase: .mayBegin)]
    for (i, d) in finger.enumerated() {
        events.append(TrackpadEvent(ms: tick(), phase: i == 0 ? .began : .changed, points: d))
    }
    if kind == "slow" { t += 120 }  // resting before the lift
    events.append(TrackpadEvent(ms: tick(), phase: .ended))
    guard kind != "slow" else { return events }
    var d = peak
    while d > 0.5 {
        events.append(TrackpadEvent(ms: tick(), points: d))
        d *= 0.93
    }
    return events
}

/// Plays `events` through ScrollDrag at their times, starting at `start` (touch space), with `unit` the touch-space
/// movement of one scroll point. Every touch sent, with its time: "ms phase x y".
func playTrackpad(_ events: [TrackpadEvent], start: CGPoint, unit: CGVector, link: DeviceLink) -> [String] {
    var drag = ScrollDrag()
    var log: [String] = []
    let t0 = Date()
    for e in events {
        let wait = e.ms / 1000 - Date().timeIntervalSince(t0)
        if wait > 0 { usleep(UInt32(wait * 1e6)) }
        let touches = drag.scroll(
            phase: e.phase,
            delta: CGVector(dx: unit.dx * e.points, dy: unit.dy * e.points),
            start: start
        )
        for touch in touches {
            let phase =
                switch touch.phase {
                case .begin: 0
                case .update: 1
                case .end: 2
                }
            link.send(.touch(slot: 0, phase: phase, x: touch.point.x, y: touch.point.y))
            log.append(
                String(
                    format: "%.1f %d %.4f %.4f",
                    Date().timeIntervalSince(t0) * 1000,
                    phase,
                    touch.point.x,
                    touch.point.y
                )
            )
        }
    }
    return log
}

/// How different two pictures are: the mean absolute gray difference (0...1) at 64x64.
func pictureDistance(_ a: URL, _ b: URL) -> Double {
    func gray(_ url: URL) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let ctx = CGContext(
                data: nil,
                width: 64,
                height: 64,
                bitsPerComponent: 8,
                bytesPerRow: 64,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let data = ctx.data else { return nil }
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: 4096), count: 4096))
    }
    guard let x = gray(a), let y = gray(b) else { return 1 }
    return Double(zip(x, y).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / 4096 / 255
}
