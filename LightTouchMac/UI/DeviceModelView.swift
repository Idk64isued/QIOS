import AppKit
import HostRuntime
import ImageIO
import LightTouchCore
import Metal
import RealityKit

/// The live LCD is a material on the asset, with input projected onto that same surface.
@MainActor
final class DeviceModelView: NSView {
    private let renderer = ARView(frame: .zero)
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
    /// The upright screen's width in shell pixels: pose and physical scale
    /// size the model's display to what the flat shell's cutout would be.
    private let screenWidth: Float
    /// The screen texture's fixed turn on the panel: every board's panel scans out as is, whatever way the device is
    /// held, so the mapping never changes with it (one of the four below; the iPad's sideways panel's is 270).
    private let surfaceRotation: Int
    enum Control: Equatable { case sleepWake, volumeUp, volumeDown }
    /// Side controls by node name (revision 7 names, then N72's own); nil is a volume rocker (by half).
    private var controls: [(entity: Entity, control: Control?)] = []
    private var screenMaterial: UnlitMaterial = {
        if #available(macOS 15, *) { return UnlitMaterial(applyPostProcessToneMap: false) }
        return UnlitMaterial()
    }()
    private var screenTexture: TextureResource?
    /// The screen's pixels drawn crisp rather than smoothed. The display face projects at exactly the pose's scale
    /// (the camera sits 0.3 from it), so the flat screen's rule holds for it.
    var drawsNearest = true {
        didSet { if oldValue != drawsNearest { updateScreenMaterial() } }
    }
    var viewportCenter: CGPoint? { didSet { updateViewport() } }
    private var screenOff = false
    private var shakeStarted: CFTimeInterval?
    private var trickStarted: CFTimeInterval?
    /// Set when the pose or viewport changes; a still model is not re-posed every frame.
    private var poseDirty = true
    /// RealityKit presents every display refresh even when nothing moves, so a
    /// model that has been still for `freezeDelay` is swapped for a snapshot and
    /// the renderer hidden; any change brings the live renderer straight back.
    private let still = CALayer()
    private var lastChange = CACurrentMediaTime()
    private var changeGeneration = 0
    private var freezing = false
    private static let freezeDelay: CFTimeInterval = 0.5

    @available(macOS 15, *)
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
                domain: "DeviceModel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) is missing its display or Home button."]
            )
        }
        self.display = display
        self.home = home
        displayBounds = display.visualBounds(relativeTo: display)
        screenWidth = Float(profile.screenCutout.width)
        // The clockwise panel quarter-turn is a 270° mapping.
        surfaceRotation = (360 - Int((profile.panelRotation * 180 / .pi).rounded())) % 360
        // N81 (revision 7) has two volume buttons where the others have one rocker.
        let named: [([String], Control?)] = [
            (["SleepWakeButton", "Sleep_wake___black_fitted_button"], .sleepWake),
            (["VolumeButton", "Volume___continuous_recessed_centre_rocker"], nil),
            (["VolumeUpButton"], .volumeUp), (["VolumeDownButton"], .volumeDown)
        ]
        for (names, control) in named {
            if let entity = names.lazy.compactMap({ loaded.findEntity(named: $0) }).first {
                controls.append((entity, control))
            }
        }
        super.init(frame: .zero)
        addSubview(renderer)
        renderer.environment.background = .color(.clear)
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
        if profile.deviceModelName == "N72" {
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
            let seat = ModelEntity(
                mesh: try .generate(from: [rim]),
                materials: [UnlitMaterial(color: .black)]
            )
            seat.position = [0, -0.0457, 0.004145]
            chassis.addChild(seat)
        }
        func tune(_ entity: Entity) {
            if var model = entity.components[ModelComponent.self] {
                model.materials = model.materials.map { material in
                    guard var finish = material as? PhysicallyBasedMaterial else { return material }
                    let name = finish.name ?? entity.name
                    // N72's front glass, then revision 7's (K48, N45) and its LCD border under it.
                    if name.contains("Black_glass") || name == "glass" || name.contains("inactive_LCD_perimeter") {
                        finish.specular = .init(floatLiteral: 0)
                        finish.baseColor = .init(tint: NSColor(white: 0.018, alpha: 1))
                    }
                    // Revision 7's Home glyph (K48, N45) is a dark steel that vanished on the black cap; a real
                    // iPad's and iPod's square reads as a light gray ring. N72's ceramic glyph already does.
                    if name == "glyph" {
                        finish.baseColor = .init(tint: NSColor(white: 0.95, alpha: 1))
                        finish.metallic = .init(floatLiteral: 0)
                        finish.roughness = .init(floatLiteral: 0.5)
                    }
                    // N45's graphite front frame ships as near-black (0.03 linear) metal, which reflects almost
                    // nothing; Apple's shots show a brushed dark-graphite rim. A neutral mid base (a bluish light
                    // one read as silver) and N45Rim (below) give it its upper-left gradient; the glass is a
                    // blue-black with a sheen.
                    if name == "frameDark" {
                        finish.baseColor = .init(tint: NSColor(srgbRed: 0.47, green: 0.48, blue: 0.5, alpha: 1))
                        finish.metallic = .init(floatLiteral: 0.7)
                        finish.roughness = .init(floatLiteral: 0.36)
                    }
                    if profile == .n45 && (name == "glass" || name.contains("inactive_LCD_perimeter")) {
                        finish.baseColor = .init(tint: NSColor(srgbRed: 0.07, green: 0.08, blue: 0.1, alpha: 1))
                        finish.specular = .init(floatLiteral: 0.5)
                    }
                    // N81's glass mirrors its studio (N81Studio): the black surround behind the camera as an even deep
                    // black (~22 of 255, Apple's hero ~28) at rest and typical tilts, and the tent as a soft sheen only
                    // at steep ones. Specular 0 left it a flat, lifeless black.
                    if profile == .n81 && (name == "glass" || name.contains("inactive_LCD_perimeter")) {
                        finish.specular = .init(floatLiteral: 1)
                    }
                    // Revision 7's camera cover (N81 front and rear, N88 rear) is a specular-workflow window that
                    // RealityKit renders as a gray haze over the barrel and lens; Apple's camera reads through clear
                    // glass. RealityKit keeps a transparent material's reflection, so it is turned down as well.
                    if name.contains("protective_window") {
                        finish.baseColor = .init(tint: .black)
                        finish.metallic = .init(floatLiteral: 0)
                        finish.roughness = .init(floatLiteral: 0.01)
                        finish.specular = .init(floatLiteral: 0.04)
                        finish.blending = .transparent(opacity: .init(floatLiteral: 0))
                    }
                    // The coated lens under it: a blue-violet coating that catches the studio's card as a glint.
                    if name.contains("multilayer_coated_lens") {
                        finish.baseColor = .init(tint: NSColor(srgbRed: 0.18, green: 0.25, blue: 0.5, alpha: 1))
                        finish.roughness = .init(floatLiteral: 0.02)
                    }
                    // The barrel around it is stepped, filleted and normal-mapped at tens of microns: at app size each
                    // step's highlight lands on a pixel or none, a speckled rim and a dotted ring around the lens. A
                    // camera's barrel is a matte black light trap, so it reflects nothing.
                    if name.contains("textured_molded_barrel") {
                        finish.normal = .init()
                        finish.specular = .init(floatLiteral: 0)
                        finish.roughness = .init(floatLiteral: 1)
                    }
                    // N72's dish faces the camera, where N72Studio's light half-disc has a hard straight edge: at 0.18
                    // that edge drew a seam across the cap; 0.4 blurs it into the cap's sheen.
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
            // World-fixed like a studio light: the rim's gradient stays upper-left as the device turns.
            let rimLighting = Entity()
            anchor.addChild(rimLighting)
            rimLighting.components.set(
                ImageBasedLightComponent(
                    source: .single(try await modelEnvironment("N45Rim")),
                    intensityExponent: 2
                )
            )
            for name in [
                "Front_frame___broad_graphite_bevel", "Cover_glass___opaque_masked_surround",
                "Display___inactive_optical_border", "Ambient_proximity_sensor___1"
            ] {
                loaded.findEntity(named: name)?.components.set(
                    ImageBasedLightReceiverComponent(imageBasedLight: rimLighting)
                )
            }
        }
        wantsLayer = true
        layer?.insertSublayer(chassisShadow, at: 0)
        still.isHidden = true
        still.contentsGravity = .resize
        still.actions = ["contents": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(still)
        chassisShadow.shadowColor = NSColor.black.cgColor
        chassisShadow.shadowOpacity = 0.4
        chassisShadow.shadowRadius = 24
        chassisShadow.shadowOffset = CGSize(width: 0, height: -6)
        chassisShadow.actions = ["shadowPath": NSNull(), "bounds": NSNull(), "position": NSNull()]
        screenMaterial.color = .init(tint: .black)
        updateScreenMaterial()
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        updateViewport()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // AppKit can resize the backing view before its next layout pass. Update
        // the drawable and its projection together, including during live resize.
        updateViewport()
    }
    private func updateViewport() {
        poseDirty = true
        noteChange()
        renderer.frame = bounds
        if let center = viewportCenter {
            camera.position.x = -Float(center.x - bounds.midX) * camera.position.z / 3000
            camera.position.y = Float(center.y - bounds.midY) * camera.position.z / 3000
        }
        chassisShadow.frame = bounds
        camera.camera.fieldOfViewInDegrees = Float(
            2 * atan(Double(max(renderer.bounds.height, 1)) / 6000) * 180 / .pi
        )
    }

    /// The model's upright outline in shell pixels (the flat shell's units), for fitting it.
    var shellPixels: CGSize {
        let pixels = screenWidth / displayBounds.extents.x
        return CGSize(width: CGFloat(shellBounds.extents.x * pixels), height: CGFloat(shellBounds.extents.y * pixels))
    }

    func pose(
        scale: CGFloat,
        rotation: Int,
        roll: CGFloat,
        pitch: CGFloat,
        yaw: CGFloat = 0,
        flat: Bool = false,
        animated: Bool,
        spring: Bool = false
    ) {
        let rest = Float(rotation == 270 ? -90 : rotation) * .pi / 180
        let units = Float(scale) * screenWidth / 10000 / displayBounds.extents.x
        let pose = Transform(
            scale: SIMD3(repeating: units),
            rotation: Self.orientation(rest: rest, roll: Float(roll), pitch: Float(pitch), yaw: Float(yaw), flat: flat),
            translation: .zero
        )
        // Layout may repeat while a transition is running; only a new target replaces it.
        if targetPose != pose {
            if animated && targetPose != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
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
    /// The screen texture's turn on the panel.
    private func mapSurface() {
        let surface = surfaceRotation
        let offset: SIMD2<Float>
        switch surface {
        case 90: offset = [1, 0]
        case 180: offset = [1, 1]
        case 270: offset = [0, 1]
        default: offset = .zero
        }
        if #available(macOS 15, *) {
            screenMaterial.textureCoordinateTransform = .init(
                offset: offset,
                rotation: Float(surface == 270 ? -90 : surface) * .pi / 180
            )
        }
    }
    /// Match the accelerometer's gravity vector: upright games steer by roll,
    /// while flat games tilt the LCD about its horizontal and vertical axes.
    static func orientation(rest: Float, roll: Float, pitch: Float, yaw: Float = 0, flat: Bool = false) -> simd_quatf {
        let tilt =
            flat
            ? simd_quatf(angle: roll, axis: [0, 1, 0]) * simd_quatf(angle: -rest, axis: [0, 0, 1])
            : simd_quatf(angle: -roll - rest, axis: [0, 0, 1])
        return simd_quatf(angle: yaw, axis: [0, 1, 0])
            * simd_quatf(angle: -pitch, axis: [1, 0, 0]) * tilt
    }
    /// A snapshot is a rendering fence: asset loading alone does not mean
    /// RealityKit has prepared a drawable, lighting, and the first LCD texture.
    func prepareFirstFrame() async -> Bool {
        while !Task.isCancelled {
            // A view can finish loading before its window is attached or while the
            // window is minimized. Neither case means that the model failed.
            if window != nil, bounds.width > 0, bounds.height > 0,
                await requestFirstFrame()
            {
                return true
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return false
    }

    private final class FirstFrameRequest {
        var continuation: CheckedContinuation<Bool, Never>?
        func finish(_ ready: Bool) {
            let waiting = continuation
            continuation = nil
            waiting?.resume(returning: ready)
        }
    }

    private func requestFirstFrame() async -> Bool {
        let request = FirstFrameRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.continuation = continuation
                guard !Task.isCancelled else {
                    request.finish(false)
                    return
                }
                renderer.snapshot(saveToHDR: false) { image in
                    request.finish(image != nil)
                }
            }
        } onCancel: {
            // ARView has no snapshot cancellation API. Release our waiter when its
            // window closes; a later renderer callback becomes a harmless no-op.
            Task { @MainActor in request.finish(false) }
        }
    }
    /// A new screen picture.
    func updateFrame(_ image: CGImage) {
        noteChange()
        do {
            // replace() updates the texture the material already holds; reassigning
            // the material every frame makes RealityKit reprocess the model.
            if let screenTexture {
                try screenTexture.replace(withImage: image, options: .init(semantic: .color))
                return
            } else if #available(macOS 15, *) {
                screenTexture = try TextureResource(image: image, options: .init(semantic: .color))
            } else {
                screenTexture = try TextureResource.generate(from: image, options: .init(semantic: .color))
            }
            updateScreenMaterial()
        } catch { NSLog("Model framebuffer upload failed: %@", error.localizedDescription) }
    }
    private func updateScreenMaterial() {
        if let screenTexture, !screenOff {
            var sampler = MaterialParameters.Texture.Sampler()
            sampler.modify { descriptor in
                descriptor.sAddressMode = .clampToEdge
                descriptor.tAddressMode = .clampToEdge
                // DisplayView's one rule (ZoomContext.drawsNearest), as its flat layer; shrunk pixels still filter.
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
    private func portraitPoint(_ p: CGPoint) -> CGPoint {
        switch surfaceRotation {
        case 90: return CGPoint(x: p.y, y: 1 - p.x)
        case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 270: return CGPoint(x: 1 - p.y, y: p.x)
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
        guard let local = intersection(point, entity: display, z: displayBounds.max.z) else {
            return nil
        }
        let p = surfacePoint(
            CGPoint(
                x: CGFloat((local.x - displayBounds.min.x) / displayBounds.extents.x),
                y: CGFloat((displayBounds.max.y - local.y) / displayBounds.extents.y)
            )
        )
        return unbounded || CGRect(x: 0, y: 0, width: 1, height: 1).contains(p) ? p : nil
    }
    func projectedPoint(_ point: CGPoint) -> CGPoint {
        let p = portraitPoint(point)
        let local = SIMD3<Float>(
            displayBounds.min.x + Float(p.x) * displayBounds.extents.x,
            displayBounds.max.y - Float(p.y) * displayBounds.extents.y,
            displayBounds.max.z
        )
        guard let projected = renderer.project(display.convert(position: local, to: nil)) else {
            return .zero
        }
        return convert(projected, from: renderer)
    }
    var homeButtonRect: CGRect? {
        let b = home.visualBounds(relativeTo: home)
        let points = [(b.min.x, b.min.y), (b.max.x, b.min.y), (b.min.x, b.max.y), (b.max.x, b.max.y)]
            .compactMap { x, y in
                renderer.project(home.convert(position: [x, y, b.max.z], to: nil)).map {
                    convert($0, from: renderer)
                }
            }
        guard points.count == 4 else { return nil }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    /// The front outline as a rounded rectangle (N72's: 46 x 94 mm inside an 8 mm radius).
    private var cornerRadius: Float { min(shellBounds.extents.x, shellBounds.extents.y) * 0.13 }
    func isChassis(_ point: CGPoint) -> Bool {
        guard panelPoint(point) == nil, let p = intersection(point, entity: chassis, z: shellBounds.max.z) else {
            return false
        }
        let r = cornerRadius
        let x = max(abs(p.x - shellBounds.center.x) - (shellBounds.extents.x / 2 - r), 0)
        let y = max(abs(p.y - shellBounds.center.y) - (shellBounds.extents.y / 2 - r), 0)
        return x * x + y * y <= r * r
    }
    /// The side control under a point: a ray through each control's bounds, in
    /// the model's own axes, so it holds at any pose. A rocker's upper half is up.
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
        guard !freezing, !renderer.isHidden, window != nil,
            CACurrentMediaTime() - lastChange >= Self.freezeDelay
        else { return }
        freezing = true
        let generation = changeGeneration
        renderer.snapshot(saveToHDR: false) { [weak self] image in
            // A change since the request makes this picture stale: stay live.
            guard let self, self.freezing, self.changeGeneration == generation else { return }
            self.freezing = false
            guard let image else {
                self.lastChange = CACurrentMediaTime()
                return
            }
            self.still.frame = self.renderer.frame
            self.still.contents = image
            self.still.isHidden = false
            self.renderer.isHidden = true
        }
    }
    func shake() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        shakeStarted = CACurrentMediaTime()
    }
    /// A 360 double kickflip, launched with the THPS special chime.
    func specialTrick() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        trickStarted = CACurrentMediaTime()
    }
    /// Returns false, touching nothing, when the model is still: writing the
    /// same transform and shadow every frame keeps RealityKit and Core Animation busy.
    @discardableResult func advanceAnimations() -> Bool {
        guard poseDirty || transition != nil || shakeStarted != nil || trickStarted != nil else {
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
                // Same unit-mass spring as the original CASpringAnimation: k=200, c=14.
                let frequency = sqrt(200.0 - 49.0)
                fraction = Float(1 - exp(-7 * t) * (cos(frequency * t) + 7 / frequency * sin(frequency * t)))
            } else {
                let x = min(t / duration, 1)
                fraction = Float(x * x * (3 - 2 * x))
            }
            basePose = Transform(
                scale: simd_mix(animation.from.scale, animation.to.scale, SIMD3(repeating: fraction)),
                rotation: simd_slerp(animation.from.rotation, animation.to.rotation, fraction),
                translation: .zero
            )
            if t >= duration {
                basePose = animation.to
                transition = nil
            }
        }
        chassis.transform = basePose
        if let start = shakeStarted {
            let t = now - start
            if t >= 0.45 {
                shakeStarted = nil
            } else {
                let decay = Float(1 - t / 0.45)
                let wave = Float(sin(t * .pi * 16 / 0.45)) * decay
                let cross = Float(sin(t * .pi * 11 / 0.45)) * decay
                chassis.position = [wave * 0.00035, cross * 0.0001, cross * 0.00015]
                chassis.orientation =
                    simd_quatf(angle: cross * 0.008, axis: [1, 0, 0])
                    * simd_quatf(angle: wave * 0.012, axis: [0, 1, 0]) * basePose.rotation
            }
        }
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
                // Same bounce rhythm as a long settle, damped hard so it's over in 0.25 s.
                let land = (t - 1) / 0.45
                let settle = exp(-11 * land)
                lift = -0.05 * height * settle * cos(3 * .pi * land)
                pitch = -0.12 * settle * sin(4 * .pi * land)
            default:
                trickStarted = nil
            }
            chassis.position = [0, lift, 0]
            chassis.scale = basePose.scale * grow
            chassis.orientation =
                simd_quatf(angle: spin, axis: [0, 1, 0])
                * simd_quatf(angle: -pitch, axis: [1, 0, 0]) * simd_quatf(angle: wobble, axis: [0, 0, 1])
                * basePose.rotation * simd_quatf(angle: flip, axis: [0, 1, 0])
        }
        // Project the rounded chassis outline; never shadow the rectangular ARView.
        let path = CGMutablePath()
        let radius = cornerRadius
        for corner in 0..<4 {
            let right = corner == 0 || corner == 3
            let top = corner < 2
            let center = SIMD2<Float>(
                right ? shellBounds.max.x - radius : shellBounds.min.x + radius,
                top ? shellBounds.max.y - radius : shellBounds.min.y + radius
            )
            for step in 0...8 {
                let angle = Float(corner) * .pi / 2 + Float(step) * .pi / 16
                let local = SIMD3<Float>(
                    center.x + cos(angle) * radius,
                    center.y + sin(angle) * radius,
                    shellBounds.max.z
                )
                guard let point = renderer.project(chassis.convert(position: local, to: nil)) else { continue }
                if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        path.closeSubpath()
        chassisShadow.shadowPath = path
        return true
    }
}

/// An environment from its equirectangular source image (Models/<name>.png, scripts/generate-*-lighting.py), built
/// here rather than shipped compiled: a compiled .realityenv is encrypted, which notarization reports as an archive it
/// can't unpack. Renders within 12/255 of the compiled environment (mean under 0.4/255).
@available(macOS 15.0, *)
private func modelEnvironment(_ name: String) async throws -> EnvironmentResource {
    guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Models"),
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw CocoaError(.fileReadCorruptFile) }
    return try await EnvironmentResource(equirectangular: image)
}
