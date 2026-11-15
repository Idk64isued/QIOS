import AVFoundation
import HostRuntime
import ImageIO
import Metal
import RealityKit
import SwiftUI
import UIKit

/// The Mac app's 3D device (LightTouchMac/UI/DeviceModelView.swift), on the phone: the bundled model
/// (Models/<name>.usdz) with the live screen as a material on its display, touches on that display sent to the
/// guest, and the rest of the view for looking at it: drag to turn it, pinch to bring it closer, double-tap to stand
/// it back up. Its Home and Sleep/Wake buttons work. The special trick (Device › Special trick) is the Mac's: a 360
/// double kickflip with its chime.
///
/// Models ship for the iPod touch 1G, 2G (and 3G, the same chassis) and 4G, the iPhone 3GS and the iPad; the iPhone
/// and iPhone 4 have none, and show With Device instead. RealityKit's model loading and texture turns need iOS 18.
enum DeviceModel3D {
    /// The bundled model for a board, if it has one (and this phone can show it).
    static func url(for board: Board?) -> URL? {
        guard #available(iOS 18, *), let name = board?.facts.art.model else { return nil }
        return Bundle.main.url(forResource: name, withExtension: "usdz", subdirectory: "Models")
    }

    /// Device › Special trick posts this; the model on screen does it.
    static let specialTrick = Notification.Name("LightTouchSpecialTrick")

    private static var chime: AVAudioPlayer?

    /// The THPS chime, landing on the pop (a beat after the crouch starts).
    static func playChime() {
        guard let url = Bundle.main.url(forResource: "special_trick", withExtension: "mp3") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            chime = try? AVAudioPlayer(contentsOf: url)
            chime?.volume = 0.8
            chime?.play()
        }
    }
}

/// Whatever shows the guest's screen and can hand back its newest frame (screenshots, reports).
@MainActor
protocol GuestFrameSource: AnyObject {
    var latestFrame: CGImage? { get }
}

extension DisplayUIView: GuestFrameSource {}

struct ModelStage: View {
    let board: Board?
    let url: URL
    let qemu: QemuRuntime?
    let keyboardBridge: UIView?
    let onHome: () -> Void
    @EnvironmentObject private var controls: DeviceControls
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                Text("The 3D model couldn\u{2019}t load on this phone. Settings › View › With Device shows the photo instead.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else if let board {
                if #available(iOS 18, *) {
                    ModelRepresentable(
                        board: board, url: url, qemu: qemu, keyboardBridge: keyboardBridge, asleep: controls.screenAsleep,
                        onHome: onHome, onFailure: { failed = true })
                }
            }
        }
        .overlay {
            if controls.screenAsleep {
                SleepOverlay { controls.wakeScreen() }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: controls.screenAsleep)
    }
}

@available(iOS 18, *)
private struct ModelRepresentable: UIViewRepresentable {
    let board: Board
    let url: URL
    let qemu: QemuRuntime?
    let keyboardBridge: UIView?
    let asleep: Bool
    let onHome: () -> Void
    let onFailure: () -> Void

    func makeUIView(context: Context) -> ModelHostView {
        let host = ModelHostView()
        host.qemu = qemu
        host.keyboardBridge = keyboardBridge
        host.onHome = onHome
        host.asleep = asleep
        host.load(url: url, board: board, onFailure: onFailure)
        return host
    }

    func updateUIView(_ view: ModelHostView, context: Context) {
        view.qemu = qemu
        view.keyboardBridge = keyboardBridge
        view.onHome = onHome
        view.asleep = asleep
    }
}

/// Holds the model once it has loaded, feeds it the guest's frames and turns touches into the guest's or the view's.
@available(iOS 18, *)
@MainActor
final class ModelHostView: UIView, GuestFrameSource {
    var qemu: QemuRuntime?
    weak var keyboardBridge: UIView?
    var onHome: () -> Void = {}
    /// The device has switched its own screen off. The model's display goes dark (as on a real sleeping phone, and
    /// as the Mac app does it) and new frames stop being pushed, so the model holds still and the sleep overlay that
    /// SwiftUI draws over it animates smoothly instead of fighting the model's redraw.
    var asleep = false {
        didSet {
            guard asleep != oldValue else { return }
            model?.setScreenOff(asleep)
        }
    }
    private var model: DeviceModelUIView?
    private var link: CADisplayLink?
    private var serial: UInt64 = 0
    private var latestImage: CGImage?
    var latestFrame: CGImage? { latestImage }

    // How the user is looking at it.
    private var yaw: CGFloat = 0, pitch: CGFloat = 0, zoom: CGFloat = 1
    private enum Role { case guest(Int), look, home, sleepWake }
    private var roles: [ObjectIdentifier: Role] = [:]
    private var lastPoint: [ObjectIdentifier: CGPoint] = [:]
    private var slots: [UITouch?] = [nil, nil]
    private var pinchStart: (distance: CGFloat, zoom: CGFloat)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(trick), name: DeviceModel3D.specialTrick, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(turned), name: DisplayUIView.turnsChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func load(url: URL, board: Board, onFailure: @escaping () -> Void) {
        Task { [weak self] in
            do {
                let model = try await DeviceModelUIView(url: url, profile: board)
                guard let self else { return }
                self.model = model
                model.frame = self.bounds
                model.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                self.insertSubview(model, at: 0)
                if let latestImage = self.latestImage { model.updateFrame(latestImage) }
                model.setScreenOff(self.asleep)
                self.repose(animated: false)
            } catch {
                LTMLog.note("3D model: \(url.lastPathComponent) did not load: \(error.localizedDescription)")
                onFailure()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        model?.frame = bounds
        repose(animated: false)
    }

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
        if let qemu, !asleep {
            var pixels: UnsafeRawPointer?
            var w: Int32 = 0, h: Int32 = 0
            if qemu.frame(&pixels, &w, &h, &serial), let pixels, w > 0, h > 0 {
                let data = Data(bytes: pixels, count: Int(w) * Int(h) * 4)
                ScreenRecorder.active?.append(bgra: data, width: Int(w), height: Int(h))
                if let image = DisplayUIView.image(data, width: Int(w), height: Int(h)) {
                    latestImage = image
                    model?.updateFrame(image)
                    PerfStats.frames += 1
                }
            }
        }
        model?.advanceAnimations()
    }

    @objc private func trick() {
        guard let model else { return }
        model.specialTrick()
        DeviceModel3D.playChime()
    }

    @objc private func turned() { repose(animated: true) }

    private func repose(animated: Bool) {
        guard let model, bounds.width > 0, bounds.height > 0 else { return }
        let outline = model.shellPixels
        let sideways = DisplayUIView.turns % 2 != 0
        let w = sideways ? outline.height : outline.width, h = sideways ? outline.width : outline.height
        let fit = min(bounds.width / max(w, 1), bounds.height / max(h, 1)) * 0.9
        model.drawsNearest = DisplayUIView.sharpPixels
        model.pose(
            scale: fit * zoom, rotation: (DisplayUIView.turns % 4) * 90, roll: 0, pitch: pitch, yaw: yaw,
            animated: animated, spring: false)
    }

    // MARK: - Touches

    private func send(_ touch: UITouch, phase: Int32, slot: Int) {
        guard let model, let qemu, let p = model.panelPoint(touch.location(in: model), unbounded: true) else { return }
        qemu.touch(Int32(slot), phase, min(max(p.x, 0), 1), min(max(p.y, 0), 1))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        keyboardBridge?.becomeFirstResponder()
        guard let model else { return }
        for touch in touches {
            let id = ObjectIdentifier(touch)
            let point = touch.location(in: model)
            lastPoint[id] = touch.location(in: self)
            if model.panelPoint(point) != nil, let free = slots.firstIndex(where: { $0 == nil }) {
                slots[free] = touch
                if free == 1 { qemu?.manualTouch2?(true) }
                roles[id] = .guest(free)
                send(touch, phase: 0, slot: free)
            } else if model.homeButtonRect?.insetBy(dx: -6, dy: -6).contains(point) == true {
                roles[id] = .home
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onHome()
            } else if model.control(at: point) == .sleepWake {
                roles[id] = .sleepWake
                qemu?.button(1, true)
            } else {
                roles[id] = .look
                if touch.tapCount == 2 {
                    yaw = 0
                    pitch = 0
                    zoom = 1
                    repose(animated: true)
                }
            }
        }
        startPinchIfTwoLooking()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            let now = touch.location(in: self)
            defer { lastPoint[id] = now }
            switch roles[id] {
            case .guest(let slot): send(touch, phase: 1, slot: slot)
            case .look:
                guard pinchStart == nil, let before = lastPoint[id] else { continue }
                yaw += (now.x - before.x) * 0.01
                pitch = min(max(pitch + (now.y - before.y) * 0.01, -1.3), 1.3)
                repose(animated: false)
            default: break
            }
        }
        if let pinch = pinchStart, let distance = lookingDistance(), pinch.distance > 0 {
            zoom = min(max(pinch.zoom * distance / pinch.distance, 0.4), 3)
            repose(animated: false)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            switch roles[id] {
            case .guest(let slot):
                send(touch, phase: 2, slot: slot)
                slots[slot] = nil
                if slot == 1 { qemu?.manualTouch2?(false) }
            case .sleepWake:
                let qemu = qemu
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { qemu?.button(1, false) }
            default: break
            }
            roles[id] = nil
            lastPoint[id] = nil
        }
        if lookingTouches().count < 2 { pinchStart = nil }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func lookingTouches() -> [CGPoint] {
        roles.compactMap { (id, role) -> CGPoint? in
            if case .look = role { return lastPoint[id] }
            return nil
        }
    }

    private func lookingDistance() -> CGFloat? {
        let points = lookingTouches()
        guard points.count >= 2 else { return nil }
        return hypot(points[0].x - points[1].x, points[0].y - points[1].y)
    }

    private func startPinchIfTwoLooking() {
        if pinchStart == nil, let distance = lookingDistance() { pinchStart = (distance, zoom) }
    }
}

/// The live LCD is a material on the asset, with input projected onto that same surface (the Mac's DeviceModelView,
/// with UIKit in place of AppKit).
@available(iOS 18, *)
@MainActor
final class DeviceModelUIView: UIView {
    private let renderer = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
    private let chassis = Entity()
    private let camera = PerspectiveCamera()
    private let homeLighting = Entity()
    private let chassisShadow = CALayer()
    private var shellBounds = BoundingBox()
    private var targetPose: Transform?
    private var transition: (start: CFTimeInterval, from: Transform, to: Transform, spring: Bool)?
    private var basePose = Transform()
    private let display: Entity
    private let home: Entity
    private let displayBounds: BoundingBox
    /// The upright screen's width in shell pixels: pose and physical scale size the model's display to what the flat
    /// shell's cutout would be.
    private let screenWidth: Float
    /// The screen texture's fixed turn on the panel (the iPad's sideways panel's is 270).
    private let surfaceRotation: Int
    enum Control: Equatable { case sleepWake, volumeUp, volumeDown }
    private var controls: [(entity: Entity, control: Control?)] = []
    private var screenMaterial = UnlitMaterial(applyPostProcessToneMap: false)
    private var screenTexture: TextureResource?
    /// The screen's pixels drawn crisp rather than smoothed (Settings › Sharp pixels).
    var drawsNearest = true {
        didSet { if oldValue != drawsNearest { updateScreenMaterial() } }
    }
    private var screenOff = false
    private var trickStarted: CFTimeInterval?
    private var poseDirty = true
    /// RealityKit presents every display refresh even when nothing moves, so a model that has been still for
    /// `freezeDelay` is swapped for a snapshot and the renderer hidden; any change brings the live renderer back.
    private let still = CALayer()
    private var lastChange = CACurrentMediaTime()
    private var changeGeneration = 0
    private var freezing = false
    private static let freezeDelay: CFTimeInterval = 0.5

    init(url: URL, profile: Board) async throws {
        let loaded = try await Entity(contentsOf: url)
        func firstModel(_ entity: Entity) -> Entity? {
            if entity.components[ModelComponent.self] != nil { return entity }
            return entity.children.lazy.compactMap { firstModel($0) }.first
        }
        guard let surface = loaded.findEntity(named: "Display"), let display = firstModel(surface),
            let home = loaded.findEntity(named: "HomeButton")
        else {
            throw NSError(
                domain: "DeviceModel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) is missing its display or Home button."])
        }
        self.display = display
        self.home = home
        displayBounds = display.visualBounds(relativeTo: display)
        screenWidth = Float(profile.facts.art.screenCutout.width)
        // The iPad's panel scans out landscape: its picture is turned a quarter clockwise on the panel, a 270° mapping.
        let pixels = profile.hardware.map { CGSize(width: $0.screenWidth, height: $0.screenHeight) } ?? CGSize(width: 320, height: 480)
        surfaceRotation = pixels.width > pixels.height ? 270 : 0
        let named: [([String], Control?)] = [
            (["SleepWakeButton", "Sleep_wake___black_fitted_button"], .sleepWake),
            (["VolumeButton", "Volume___continuous_recessed_centre_rocker"], nil),
            (["VolumeUpButton"], .volumeUp), (["VolumeDownButton"], .volumeDown),
        ]
        for (names, control) in named {
            if let entity = names.lazy.compactMap({ loaded.findEntity(named: $0) }).first {
                controls.append((entity, control))
            }
        }
        super.init(frame: .zero)
        renderer.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableCameraGrain, .disableGroundingShadows]
        renderer.environment.background = .color(.clear)
        renderer.backgroundColor = .clear
        renderer.isOpaque = false
        renderer.isUserInteractionEnabled = false
        addSubview(renderer)
        let anchor = AnchorEntity(world: .zero)
        chassis.addChild(loaded)
        shellBounds = loaded.visualBounds(relativeTo: chassis)
        anchor.addChild(chassis)
        anchor.addChild(camera)
        anchor.addChild(homeLighting)
        renderer.scene.addAnchor(anchor)
        camera.camera.near = 0.001
        camera.camera.far = 10
        camera.camera.fieldOfViewOrientation = .vertical
        // A black seat closes N72's gap, which otherwise exposes steel around Home.
        if profile.facts.art.model == "N72" {
            var rim = MeshDescriptor(name: "Home black gasket")
            var vertices: [SIMD3<Float>] = []
            var indices: [UInt32] = []
            for i in 0..<128 {
                let angle = Float(i) * 2 * .pi / 128
                for radius: Float in [0.00487, 0.00515] {
                    vertices.append([cos(angle) * radius, sin(angle) * radius, 0])
                }
                let a = UInt32(i * 2)
                let b = UInt32(((i + 1) % 128) * 2)
                indices += [a, a + 1, b, b, a + 1, b + 1]
            }
            rim.positions = .init(vertices)
            rim.primitives = .triangles(indices)
            let seat = ModelEntity(mesh: try .generate(from: [rim]), materials: [UnlitMaterial(color: .black)])
            seat.position = [0, -0.0457, 0.004145]
            chassis.addChild(seat)
        }
        func tune(_ entity: Entity) {
            if var model = entity.components[ModelComponent.self] {
                model.materials = model.materials.map { material in
                    guard var finish = material as? PhysicallyBasedMaterial else { return material }
                    let name = finish.name ?? entity.name
                    if name.contains("Black_glass") || name == "glass" || name.contains("inactive_LCD_perimeter") {
                        finish.specular = .init(floatLiteral: 0)
                        finish.baseColor = .init(tint: UIColor(white: 0.018, alpha: 1))
                    }
                    if name == "glyph" {
                        finish.baseColor = .init(tint: UIColor(white: 0.95, alpha: 1))
                        finish.metallic = .init(floatLiteral: 0)
                        finish.roughness = .init(floatLiteral: 0.5)
                    }
                    if name == "frameDark" {
                        finish.baseColor = .init(tint: UIColor(red: 0.47, green: 0.48, blue: 0.5, alpha: 1))
                        finish.metallic = .init(floatLiteral: 0.7)
                        finish.roughness = .init(floatLiteral: 0.36)
                    }
                    if profile == .n45 && (name == "glass" || name.contains("inactive_LCD_perimeter")) {
                        finish.baseColor = .init(tint: UIColor(red: 0.07, green: 0.08, blue: 0.1, alpha: 1))
                        finish.specular = .init(floatLiteral: 0.5)
                    }
                    if profile == .n81 && (name == "glass" || name.contains("inactive_LCD_perimeter")) {
                        finish.specular = .init(floatLiteral: 1)
                    }
                    if name.contains("protective_window") {
                        finish.baseColor = .init(tint: .black)
                        finish.metallic = .init(floatLiteral: 0)
                        finish.roughness = .init(floatLiteral: 0.01)
                        finish.specular = .init(floatLiteral: 0.04)
                        finish.blending = .transparent(opacity: .init(floatLiteral: 0))
                    }
                    if name.contains("multilayer_coated_lens") {
                        finish.baseColor = .init(tint: UIColor(red: 0.18, green: 0.25, blue: 0.5, alpha: 1))
                        finish.roughness = .init(floatLiteral: 0.02)
                    }
                    if name.contains("textured_molded_barrel") {
                        finish.normal = .init()
                        finish.specular = .init(floatLiteral: 0)
                        finish.roughness = .init(floatLiteral: 1)
                    }
                    if name.contains("Concave") {
                        finish.specular = .init(floatLiteral: 0.5)
                        finish.roughness = .init(floatLiteral: 0.4)
                    }
                    return finish
                }
                entity.components.set(model)
            }
            for child in entity.children { tune(child) }
        }
        tune(loaded)
        let lighting = try await modelEnvironment(profile == .n81 ? "N81Studio" : "N72Studio")
        renderer.environment.lighting.resource = lighting
        renderer.environment.lighting.intensityExponent = 2
        var homeLight = ImageBasedLightComponent(source: .single(lighting), intensityExponent: 2)
        homeLight.inheritsRotation = true
        homeLighting.components.set(homeLight)
        home.components.set(ImageBasedLightReceiverComponent(imageBasedLight: homeLighting))
        if profile == .n45 {
            let rimLighting = Entity()
            anchor.addChild(rimLighting)
            rimLighting.components.set(
                ImageBasedLightComponent(source: .single(try await modelEnvironment("N45Rim")), intensityExponent: 2))
            for name in [
                "Front_frame___broad_graphite_bevel", "Cover_glass___opaque_masked_surround",
                "Display___inactive_optical_border", "Ambient_proximity_sensor___1",
            ] {
                loaded.findEntity(named: name)?.components.set(ImageBasedLightReceiverComponent(imageBasedLight: rimLighting))
            }
        }
        layer.insertSublayer(chassisShadow, at: 0)
        still.isHidden = true
        still.contentsGravity = .resize
        still.actions = ["contents": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(still)
        chassisShadow.shadowColor = UIColor.black.cgColor
        chassisShadow.shadowOpacity = 0.4
        chassisShadow.shadowRadius = 24
        chassisShadow.shadowOffset = CGSize(width: 0, height: 6)
        chassisShadow.actions = ["shadowPath": NSNull(), "bounds": NSNull(), "position": NSNull()]
        screenMaterial.color = .init(tint: .black)
        updateScreenMaterial()
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateViewport()
    }

    private func updateViewport() {
        poseDirty = true
        noteChange()
        renderer.frame = bounds
        chassisShadow.frame = bounds
        camera.camera.fieldOfViewInDegrees = Float(2 * atan(Double(max(renderer.bounds.height, 1)) / 6000) * 180 / .pi)
    }

    /// The model's upright outline in shell pixels (the flat shell's units), for fitting it.
    var shellPixels: CGSize {
        let pixels = screenWidth / displayBounds.extents.x
        return CGSize(width: CGFloat(shellBounds.extents.x * pixels), height: CGFloat(shellBounds.extents.y * pixels))
    }

    func pose(
        scale: CGFloat, rotation: Int, roll: CGFloat, pitch: CGFloat, yaw: CGFloat = 0, flat: Bool = false,
        animated: Bool, spring: Bool = false
    ) {
        let rest = Float(rotation == 270 ? -90 : rotation) * .pi / 180
        let units = Float(scale) * screenWidth / 10000 / displayBounds.extents.x
        let pose = Transform(
            scale: SIMD3(repeating: units),
            rotation: Self.orientation(rest: rest, roll: Float(roll), pitch: Float(pitch), yaw: Float(yaw), flat: flat),
            translation: .zero)
        if targetPose != pose {
            if animated && targetPose != nil && !UIAccessibility.isReduceMotionEnabled {
                transition = (CACurrentMediaTime(), basePose, pose, spring)
            } else {
                transition = nil
                basePose = pose
            }
            targetPose = pose
        }
        homeLighting.orientation = simd_quatf(angle: -rest, axis: [0, 0, 1])
        camera.position = [0, 0, 0.3 + units * displayBounds.max.z]
        updateViewport()
        mapSurface()
        updateScreenMaterial()
        advanceAnimations()
    }

    private func mapSurface() {
        let offset: SIMD2<Float>
        switch surfaceRotation {
        case 90: offset = [1, 0]
        case 180: offset = [1, 1]
        case 270: offset = [0, 1]
        default: offset = .zero
        }
        screenMaterial.textureCoordinateTransform = .init(
            offset: offset, rotation: Float(surfaceRotation == 270 ? -90 : surfaceRotation) * .pi / 180)
    }

    static func orientation(rest: Float, roll: Float, pitch: Float, yaw: Float = 0, flat: Bool = false) -> simd_quatf {
        let tilt =
            flat
            ? simd_quatf(angle: roll, axis: [0, 1, 0]) * simd_quatf(angle: -rest, axis: [0, 0, 1])
            : simd_quatf(angle: -roll - rest, axis: [0, 0, 1])
        return simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: -pitch, axis: [1, 0, 0]) * tilt
    }

    /// A new screen picture.
    func updateFrame(_ image: CGImage) {
        noteChange()
        do {
            // replace() updates the texture the material already holds; reassigning the material every frame makes
            // RealityKit reprocess the model.
            if let screenTexture {
                try screenTexture.replace(withImage: image, options: .init(semantic: .color))
                return
            }
            screenTexture = try TextureResource(image: image, options: .init(semantic: .color))
            updateScreenMaterial()
        } catch {
            LTMLog.note("3D model: screen upload failed: \(error.localizedDescription)")
        }
    }

    private func updateScreenMaterial() {
        if let screenTexture, !screenOff {
            var sampler = MaterialParameters.Texture.Sampler()
            sampler.modify { descriptor in
                descriptor.sAddressMode = .clampToEdge
                descriptor.tAddressMode = .clampToEdge
                descriptor.magFilter = drawsNearest ? .nearest : .linear
                descriptor.minFilter = .linear
            }
            screenMaterial.color = .init(tint: .white, texture: .init(screenTexture, sampler: sampler))
        } else {
            screenMaterial.color = .init(tint: .black)
        }
        guard var model = display.components[ModelComponent.self] else { return }
        model.materials = [screenMaterial]
        display.components.set(model)
    }

    func setScreenOff(_ off: Bool) {
        noteChange()
        screenOff = off
        updateScreenMaterial()
    }

    private func surfacePoint(_ p: CGPoint) -> CGPoint {
        switch surfaceRotation {
        case 90: return CGPoint(x: 1 - p.y, y: p.x)
        case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 270: return CGPoint(x: p.y, y: 1 - p.x)
        default: return p
        }
    }

    private func intersection(_ point: CGPoint, entity: Entity, z: Float) -> SIMD3<Float>? {
        guard let ray = renderer.ray(through: renderer.convert(point, from: self)) else { return nil }
        let near = entity.convert(position: ray.origin, from: nil)
        let direction = entity.convert(direction: ray.direction, from: nil)
        guard abs(direction.z) > 0.000001 else { return nil }
        let t = (z - near.z) / direction.z
        return t >= 0 ? near + direction * t : nil
    }

    /// The point on the panel (0…1) under a view point; nil off it, unless `unbounded`, which extends the panel's plane.
    func panelPoint(_ point: CGPoint, unbounded: Bool = false) -> CGPoint? {
        guard let local = intersection(point, entity: display, z: displayBounds.max.z) else { return nil }
        let p = surfacePoint(
            CGPoint(
                x: CGFloat((local.x - displayBounds.min.x) / displayBounds.extents.x),
                y: CGFloat((displayBounds.max.y - local.y) / displayBounds.extents.y)))
        return unbounded || CGRect(x: 0, y: 0, width: 1, height: 1).contains(p) ? p : nil
    }

    var homeButtonRect: CGRect? {
        let b = home.visualBounds(relativeTo: home)
        let points = [(b.min.x, b.min.y), (b.max.x, b.min.y), (b.min.x, b.max.y), (b.max.x, b.max.y)]
            .compactMap { x, y in
                renderer.project(home.convert(position: [x, y, b.max.z], to: nil)).map { convert($0, from: renderer) }
            }
        guard points.count == 4 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private var cornerRadius: Float { min(shellBounds.extents.x, shellBounds.extents.y) * 0.13 }

    /// The side control under a point: a ray through each control's bounds, in the model's own axes.
    func control(at point: CGPoint) -> Control? {
        guard let ray = renderer.ray(through: renderer.convert(point, from: self)) else { return nil }
        let origin = chassis.convert(position: ray.origin, from: nil)
        let direction = chassis.convert(direction: ray.direction, from: nil)
        for (entity, control) in controls {
            let b = entity.visualBounds(relativeTo: chassis)
            let t0 = (b.min - origin) / direction
            let t1 = (b.max - origin) / direction
            let near = simd_reduce_max(simd_min(t0, t1))
            let far = simd_reduce_min(simd_max(t0, t1))
            guard near <= far, far >= 0 else { continue }
            if let control { return control }
            return (origin + direction * max(near, 0)).y > b.center.y ? .volumeUp : .volumeDown
        }
        return nil
    }

    private func noteChange() {
        lastChange = CACurrentMediaTime()
        changeGeneration += 1
        freezing = false
        if renderer.isHidden {
            renderer.isHidden = false
            still.isHidden = true
            still.contents = nil
        }
    }

    private func freezeIfStill() {
        guard !freezing, !renderer.isHidden, window != nil, CACurrentMediaTime() - lastChange >= Self.freezeDelay
        else { return }
        freezing = true
        let generation = changeGeneration
        renderer.snapshot(saveToHDR: false) { [weak self] image in
            guard let self, self.freezing, self.changeGeneration == generation else { return }
            self.freezing = false
            guard let image = image?.cgImage else {
                self.lastChange = CACurrentMediaTime()
                return
            }
            self.still.frame = self.renderer.frame
            self.still.contents = image
            self.still.isHidden = false
            self.renderer.isHidden = true
        }
    }

    /// A 360 double kickflip, launched with the THPS special chime.
    func specialTrick() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        trickStarted = CACurrentMediaTime()
    }

    /// Returns false, touching nothing, when the model is still.
    @discardableResult func advanceAnimations() -> Bool {
        guard poseDirty || transition != nil || trickStarted != nil else {
            freezeIfStill()
            return false
        }
        poseDirty = false
        noteChange()
        let now = CACurrentMediaTime()
        if let animation = transition {
            let t = now - animation.start
            let duration = animation.spring ? 1.1 : 0.4
            let fraction: Float
            if animation.spring {
                let frequency = sqrt(200.0 - 49.0)
                fraction = Float(1 - exp(-7 * t) * (cos(frequency * t) + 7 / frequency * sin(frequency * t)))
            } else {
                let x = min(t / duration, 1)
                fraction = Float(x * x * (3 - 2 * x))
            }
            basePose = Transform(
                scale: simd_mix(animation.from.scale, animation.to.scale, SIMD3(repeating: fraction)),
                rotation: simd_slerp(animation.from.rotation, animation.to.rotation, fraction),
                translation: .zero)
            if t >= duration {
                basePose = animation.to
                transition = nil
            }
        }
        chassis.transform = basePose
        if let start = trickStarted {
            // Crouch, pop, double kickflip over a 360 shove-it, catch, and stomp the landing.
            let t = Float(now - start)
            let height = basePose.scale.y * shellBounds.extents.y
            var lift: Float = 0
            var grow: Float = 1
            var pitch: Float = 0
            var wobble: Float = 0
            var flip: Float = 0
            var spin: Float = 0
            switch t {
            case ..<0.15:
                let crouch = sin(t / 0.15 * .pi / 2)
                lift = -0.06 * height * crouch
                pitch = 0.3 * crouch
            case ..<1:
                let air = (t - 0.15) / 0.85
                let back = air - 1
                lift = 2.2 * height * air * (1 - air)
                grow = 1 + 0.18 * sin(air * .pi)
                pitch = 0.3 * (1 - air) * (1 - air)
                wobble = 0.35 * sin(air * 2 * .pi)
                flip = (1 + 2.70158 * back * back * back + 1.70158 * back * back) * 4 * .pi
                spin = (air < 0.5 ? 4 * air * air * air : 1 + 4 * back * back * back) * 2 * .pi
            case ..<1.25:
                let land = (t - 1) / 0.45
                let settle = exp(-11 * land)
                lift = -0.05 * height * settle * cos(3 * .pi * land)
                pitch = -0.12 * settle * sin(4 * .pi * land)
            default:
                trickStarted = nil
            }
            chassis.position = [0, lift, 0]
            chassis.scale = basePose.scale * grow
            let turn = simd_quatf(angle: spin, axis: [0, 1, 0]) * simd_quatf(angle: -pitch, axis: [1, 0, 0])
            let flipped = simd_quatf(angle: wobble, axis: [0, 0, 1]) * basePose.rotation * simd_quatf(angle: flip, axis: [0, 1, 0])
            chassis.orientation = turn * flipped
        }
        // Project the rounded chassis outline; never shadow the rectangular ARView.
        let path = CGMutablePath()
        let radius = cornerRadius
        for corner in 0..<4 {
            let right = corner == 0 || corner == 3
            let top = corner < 2
            let center = SIMD2<Float>(
                right ? shellBounds.max.x - radius : shellBounds.min.x + radius,
                top ? shellBounds.max.y - radius : shellBounds.min.y + radius)
            for step in 0...8 {
                let angle = Float(corner) * .pi / 2 + Float(step) * .pi / 16
                let local = SIMD3<Float>(center.x + cos(angle) * radius, center.y + sin(angle) * radius, shellBounds.max.z)
                guard let point = renderer.project(chassis.convert(position: local, to: nil)) else { continue }
                if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        path.closeSubpath()
        chassisShadow.shadowPath = path
        return true
    }
}

/// An environment from its equirectangular source image (Models/<name>.png), built here rather than shipped
/// compiled, as the Mac app does.
@available(iOS 18, *)
private func modelEnvironment(_ name: String) async throws -> EnvironmentResource {
    guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Models"),
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw CocoaError(.fileReadCorruptFile) }
    return try await EnvironmentResource(equirectangular: image)
}
