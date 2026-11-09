import SwiftUI
import UIKit

/// The emulated screen. Polls the emulator's newest frame on a display link (the library hands back a pointer
/// plus a serial, and says "nothing new" cheaply) and turns touches into normalised screen coordinates.
final class DisplayUIView: UIView {
    var qemu: QemuRuntime?
    private var link: CADisplayLink?
    private var serial: UInt64 = 0
    private var imageSize = CGSize(width: 320, height: 480)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.contentsGravity = .resizeAspect
        layer.magnificationFilter = .linear
        isMultipleTouchEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick() {
        guard let qemu else { return }
        var pixels: UnsafeRawPointer?
        var w: Int32 = 0, h: Int32 = 0
        guard qemu.frame(&pixels, &w, &h, &serial), let pixels, w > 0, h > 0 else { return }
        let data = Data(bytes: pixels, count: Int(w) * Int(h) * 4)   // BGRA, copied: the buffer is recycled
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
        guard let image = CGImage(
            width: Int(w), height: Int(h), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(w) * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent) else { return }
        imageSize = CGSize(width: Int(w), height: Int(h))
        layer.contents = image
        PerfStats.frames += 1
        if PerfStats.frames == 1 { LTMLog.note("first guest frame \(w)x\(h)") }
    }

    /// Where the aspect-fit image sits inside the view.
    private var imageRect: CGRect {
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func send(_ touch: UITouch, phase: Int32) {
        guard let qemu else { return }
        let r = imageRect, p = touch.location(in: self)
        let nx = min(max((p.x - r.minX) / r.width, 0), 1), ny = min(max((p.y - r.minY) / r.height, 0), 1)
        qemu.touch(0, phase, nx, ny)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { if let t = touches.first { send(t, phase: 0) } }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { if let t = touches.first { send(t, phase: 1) } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { if let t = touches.first { send(t, phase: 2) } }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { if let t = touches.first { send(t, phase: 2) } }
}

struct DisplayView: UIViewRepresentable {
    let qemu: QemuRuntime?
    func makeUIView(context: Context) -> DisplayUIView {
        let v = DisplayUIView()
        v.qemu = qemu
        return v
    }
    func updateUIView(_ view: DisplayUIView, context: Context) { view.qemu = qemu }
}
