import Metal
import QuartzCore
import SwiftUI
import UIKit

/// Puts guest frames on screen through Metal: each frame is copied once into a shared texture and blitted into a
/// drawable the guest's size, and Core Animation scales the layer (nearest or linear, the layer's filter). The other
/// way (a CGImage per frame as a layer's contents) copied the frame twice on the main thread and had Core Animation
/// convert it again, sixty times a second.
final class MetalPresenter {
    let layer = CAMetalLayer()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var textures: [MTLTexture] = []
    private var next = 0
    private(set) var newest: MTLTexture?
    /// Frames on the GPU; a frame that arrives while three still are is skipped rather than waited for.
    private let inFlight = DispatchSemaphore(value: 3)

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false   // the drawable is a blit's destination
        layer.isOpaque = true           // the guest's fourth byte is padding, not alpha
        layer.maximumDrawableCount = 3
    }

    /// One BGRA frame, rows packed. False if it could not be shown (the caller keeps the old picture).
    func present(_ pixels: UnsafeRawPointer, width: Int, height: Int) -> Bool {
        guard inFlight.wait(timeout: .now()) == .success else { return false }
        if textures.first.map({ $0.width != width || $0.height != height }) ?? true {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.storageMode = .shared
            d.usage = [.shaderRead]
            textures = (0..<3).compactMap { _ in device.makeTexture(descriptor: d) }
            layer.drawableSize = CGSize(width: width, height: height)
            newest = nil
        }
        guard textures.count == 3 else { inFlight.signal(); return false }
        let texture = textures[next]
        next = (next + 1) % 3
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        newest = texture
        guard let drawable = layer.nextDrawable(), let commands = queue.makeCommandBuffer(),
            let blit = commands.makeBlitCommandEncoder()
        else { inFlight.signal(); return false }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: drawable.texture,
                  destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        commands.present(drawable)
        commands.commit()
        return true
    }

    /// The newest frame as an image (screenshots, reports).
    func snapshot() -> CGImage? {
        guard let texture = newest else { return nil }
        let w = texture.width, h = texture.height
        var data = Data(count: w * h * 4)
        data.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                texture.getBytes(base, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            }
        }
        return DisplayUIView.image(data, width: w, height: h)
    }
}

/// The emulated screen. Polls the emulator's newest frame on a display link (the library hands back a pointer
/// plus a serial, and says "nothing new" cheaply) and turns touches into normalised screen coordinates.
/// Also exports the newest frame as an image (for screenshots) and puts focus back on the hardware-keyboard bridge
/// whenever the user taps the screen, so a connected keyboard keeps going.
final class DisplayUIView: UIView {
    /// How far the picture turns inside the screen, in clockwise quarter turns (DeviceControls.quarterTurns sets it):
    /// the device's frame stays where it is and only its screen turns, so a landscape app reads upright, fitted into
    /// the screen's shape. Touches are turned back before they reach the guest.
    static var turns = 0 {
        didSet { if oldValue != turns { NotificationCenter.default.post(name: turnsChanged, object: nil) } }
    }
    static let turnsChanged = Notification.Name("LightTouchScreenTurns")

    var qemu: QemuRuntime?
    /// Settings › Sharp pixels: the guest's pixels scaled up as crisp squares (nearest) rather than smoothed.
    nonisolated static var sharpPixels: Bool { UserDefaults.standard.object(forKey: "sharpPixels") as? Bool ?? true }
    /// Draws the frames when Metal is there (always, on a phone that runs this); else frames are layer contents.
    private let metal: MetalPresenter?
    /// The picture, turned inside this view; the view itself never turns, so UIKit's touch coordinates stay plain.
    private let screen: CALayer
    private var shownTurns = 0
    weak var keyboardBridge: UIView?
    private var link: CADisplayLink?
    private var serial: UInt64 = 0
    private var imageSize = CGSize(width: 320, height: 480)
    /// The newest guest frame as a CGImage, kept for screenshots (the framework's own buffer is recycled, so this
    /// holds its own copy). Made when asked for, on the Metal path.
    private var latestImage: CGImage?
    var latestFrame: CGImage? { metal != nil ? metal?.snapshot() : latestImage }

    override init(frame: CGRect) {
        let presenter = MetalPresenter()
        metal = presenter
        screen = presenter?.layer ?? CALayer()
        super.init(frame: frame)
        backgroundColor = .black
        screen.contentsGravity = .resizeAspect
        applyFilter()
        layer.addSublayer(screen)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: UserDefaults.didChangeNotification, object: nil)
        shownTurns = Self.turns
        NotificationCenter.default.addObserver(self, selector: #selector(screenTurnsChanged), name: Self.turnsChanged, object: nil)
        // Two fingers, so a pinch lands on the device's own screen (Photos, Safari, Maps) instead of zooming
        // this app's view of it.
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyFilter() {
        let filter: CALayerContentsFilter = Self.sharpPixels ? .nearest : .linear
        if screen.magnificationFilter != filter { screen.magnificationFilter = filter }
        screen.minificationFilter = .linear
    }

    @objc private func settingsChanged() {
        DispatchQueue.main.async { [weak self] in self?.applyFilter(); self?.applyFrameRate() }
    }

    /// Settings › Cool mode asks for thirty frames a second (the guest's own screen runs at 30 Hz then too).
    private func applyFrameRate() {
        let cool = UserDefaults.standard.bool(forKey: "coolMode")
        let rate = CAFrameRateRange(minimum: cool ? 20 : 30, maximum: cool ? 30 : 60, preferred: cool ? 30 : 60)
        link?.preferredFrameRateRange = rate
    }

    @objc private func screenTurnsChanged() {
        shownTurns = Self.turns
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        layoutScreen()
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutScreen()
        CATransaction.commit()
    }

    /// The picture's layer: its long side along the view's when turned sideways, then turned into place.
    private func layoutScreen() {
        let sideways = shownTurns % 2 != 0
        screen.bounds = CGRect(x: 0, y: 0, width: sideways ? bounds.height : bounds.width,
                               height: sideways ? bounds.width : bounds.height)
        screen.position = CGPoint(x: bounds.midX, y: bounds.midY)
        screen.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(shownTurns) * .pi / 2))
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
        applyFrameRate()
    }

    nonisolated static func image(_ data: Data, width w: Int, height h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
            shouldInterpolate: !sharpPixels, intent: .defaultIntent)
    }

    @objc private func tick() {
        guard let qemu else { return }
        var pixels: UnsafeRawPointer?
        var w: Int32 = 0, h: Int32 = 0
        let shown = serial
        guard qemu.frame(&pixels, &w, &h, &serial), let pixels, w > 0, h > 0 else { return }
        let width = Int(w), height = Int(h)
        if let recorder = ScreenRecorder.active {
            recorder.append(bgra: Data(bytes: pixels, count: width * height * 4), width: width, height: height)
        }
        if let metal {
            // Not shown (the GPU still had three frames): ask for this one again next tick.
            guard metal.present(pixels, width: width, height: height) else { serial = shown; return }
        } else {
            let data = Data(bytes: pixels, count: width * height * 4)   // BGRA, copied: the buffer is recycled
            guard let image = Self.image(data, width: width, height: height) else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            screen.contents = image
            CATransaction.commit()
            latestImage = image
        }
        imageSize = CGSize(width: width, height: height)
        PerfStats.frames += 1
        if PerfStats.frames == 1 { LTMLog.note("first guest frame \(w)x\(h)\(metal != nil ? ", Metal" : "")") }
    }

    /// Where the aspect-fit image sits inside the picture's (unturned) layer.
    private var imageRect: CGRect {
        let b = screen.bounds
        let scale = min(b.width / imageSize.width, b.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (b.width - size.width) / 2, y: (b.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// A point in this view, in the picture's own coordinates: turned back by the screen's turns about the centre.
    private func unturned(_ p: CGPoint) -> CGPoint {
        let a = CGFloat(shownTurns) * .pi / 2
        let dx = p.x - bounds.midX, dy = p.y - bounds.midY
        let x = dx * cos(a) + dy * sin(a), y = -dx * sin(a) + dy * cos(a)
        return CGPoint(x: x + screen.bounds.width / 2, y: y + screen.bounds.height / 2)
    }

    private func send(_ touch: UITouch, phase: Int32, slot: Int = 0) {
        guard let qemu else { return }
        let r = imageRect, p = unturned(touch.location(in: self))
        let nx = min(max((p.x - r.minX) / r.width, 0), 1), ny = min(max((p.y - r.minY) / r.height, 0), 1)
        qemu.touch(Int32(slot), phase, nx, ny)
    }

    /// Which finger is which. The guest takes two slots; the first touch down owns slot 0 and the second owns
    /// slot 1, and they keep those slots until they lift, so a pinch stays a pinch.
    private var slots: [UITouch?] = [nil, nil]

    private func slot(for touch: UITouch, claiming: Bool) -> Int? {
        if let index = slots.firstIndex(where: { $0 === touch }) { return index }
        guard claiming, let free = slots.firstIndex(where: { $0 == nil }) else { return nil }
        slots[free] = touch
        if free == 1 { qemu?.manualTouch2?(true) }
        return free
    }

    private func release(_ touch: UITouch) {
        guard let index = slots.firstIndex(where: { $0 === touch }) else { return }
        slots[index] = nil
        if index == 1 { qemu?.manualTouch2?(false) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let index = slot(for: touch, claiming: true) else { continue }
            send(touch, phase: 0, slot: index)
        }
        // Any tap puts focus back on the hardware-keyboard bridge, so a connected keyboard keeps typing into the guest.
        keyboardBridge?.becomeFirstResponder()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let index = slot(for: touch, claiming: false) else { continue }
            send(touch, phase: 1, slot: index)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if let index = slot(for: touch, claiming: false) { send(touch, phase: 2, slot: index) }
            release(touch)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

struct DisplayView: UIViewRepresentable {
    let qemu: QemuRuntime?
    /// A hidden text field that catches hardware-keyboard keys and sends them to the guest agent (optional).
    let keyboardBridge: UIView?

    init(qemu: QemuRuntime?, keyboardBridge: UIView? = nil) {
        self.qemu = qemu
        self.keyboardBridge = keyboardBridge
    }

    func makeUIView(context: Context) -> DisplayUIView {
        let v = DisplayUIView()
        v.qemu = qemu
        v.keyboardBridge = keyboardBridge
        return v
    }
    func updateUIView(_ view: DisplayUIView, context: Context) {
        view.qemu = qemu
        view.keyboardBridge = keyboardBridge
    }
}

/// Finds the DisplayUIView inside a SwiftUI host view and hands back its newest frame.
enum DisplaySnapshot {
    /// The flat screen's or the 3D model's (GuestFrameSource), whichever the device is shown with.
    @MainActor
    static func latestFrame(inside root: UIView) -> CGImage? {
        func walk(_ v: UIView) -> GuestFrameSource? {
            if let d = v as? GuestFrameSource { return d }
            for child in v.subviews { if let d = walk(child) { return d } }
            return nil
        }
        return walk(root)?.latestFrame
    }
}
