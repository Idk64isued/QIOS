import AppKit
import HostRuntime
import Metal
import RealityKit
import Testing

@testable import LightTouchCore
@testable import Model

func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
/// Renders the model's own scene headless: RealityRenderer draws the same
/// entities and camera into a texture, so no window is ever shown and the
/// check runs with the display asleep. Pixel (x, y) is the view's y-up point.
@available(macOS 15, *) @MainActor func render(_ model: DeviceModelView) async throws -> CGImage {
    let view = model.subviews[0] as! ARView
    let anchors = Array(view.scene.anchors)
    for anchor in anchors { view.scene.removeAnchor(anchor) }
    defer { for anchor in anchors { view.scene.addAnchor(anchor) } }
    let renderer = try RealityRenderer()
    for anchor in anchors { renderer.entities.append(anchor) }
    func camera(_ e: Entity) -> Entity? { e is PerspectiveCamera ? e : e.children.lazy.compactMap(camera).first }
    renderer.activeCamera = anchors.lazy.compactMap(camera).first!
    renderer.lighting.resource = view.environment.lighting.resource
    renderer.lighting.intensityExponent = view.environment.lighting.intensityExponent
    renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0.5, alpha: 1))
    let w = Int(model.bounds.width) * 2
    let h = Int(model.bounds.height) * 2
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm_srgb,
        width: w,
        height: h,
        mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let texture = MTLCreateSystemDefaultDevice()!.makeTexture(descriptor: descriptor)!
    let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
    // Twice: the first pass can precede material and texture uploads.
    for _ in 0..<2 {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            do {
                try renderer.updateAndRender(
                    deltaTime: 1.0 / 60,
                    cameraOutput: output,
                    onComplete: { _ in done.resume() }
                )
            } catch {
                done.resume(throwing: error)
            }
        }
    }
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let context = CGContext(
        data: &bytes,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.displayP3)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}
/// RealityKit writes Display P3: compare raw P3 components with P3 references.
func color(_ image: CGImage, _ p: CGPoint, in size: CGSize) -> NSColor {
    let rep = NSBitmapImageRep(cgImage: image)
    var pixel = [Int](repeating: 0, count: 4)
    rep.getPixel(
        &pixel,
        atX: Int(p.x / size.width * CGFloat(rep.pixelsWide)),
        y: Int((1 - p.y / size.height) * CGFloat(rep.pixelsHigh))
    )
    return NSColor(
        displayP3Red: CGFloat(pixel[0]) / 255,
        green: CGFloat(pixel[1]) / 255,
        blue: CGFloat(pixel[2]) / 255,
        alpha: 1
    )
}
/// Upright quadrants (red, green / blue, yellow), a center circle and TOP, then
/// turned into the panel's own scan-out orientation: the iPad's is landscape (a quarter counterclockwise), every
/// other board's upright, whatever the device does.
func pattern(_ profile: Board) -> CGImage {
    // Counterclockwise quarter-turns from upright.
    let turnsBack = profile.panelRotation != 0 ? 1 : 0
    let upright = profile.uprightScreenPixels
    let size = turnsBack % 2 == 0 ? upright : CGSize(width: upright.height, height: upright.width)
    let w = Int(size.width)
    let h = Int(size.height)
    let context = CGContext(
        data: nil,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    // Draw in the upright frame: turn the context so its y-up upright picture lands turned back.
    context.translateBy(x: size.width / 2, y: size.height / 2)
    context.rotate(by: CGFloat(turnsBack) * .pi / 2)
    context.translateBy(x: -upright.width / 2, y: -upright.height / 2)
    let colors: [NSColor] = [.red, .green, .blue, .yellow]
    for i in 0..<4 {
        context.setFillColor(colors[i].cgColor)
        context.fill(
            CGRect(
                x: CGFloat(i % 2) * upright.width / 2,
                y: CGFloat(1 - i / 2) * upright.height / 2,
                width: upright.width / 2,
                height: upright.height / 2
            )
        )
    }
    let d = upright.width * 0.6
    context.setStrokeColor(.white)
    context.setLineWidth(upright.width * 0.02)
    context.strokeEllipse(in: CGRect(x: (upright.width - d) / 2, y: (upright.height - d) / 2, width: d, height: d))
    let text = NSAttributedString(
        string: "TOP",
        attributes: [.font: NSFont.boldSystemFont(ofSize: upright.width * 0.12), .foregroundColor: NSColor.white]
    )
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetBoundsWithOptions(line, [])
    context.textPosition = CGPoint(x: (upright.width - bounds.width) / 2, y: upright.height * 0.9)
    CTLineDraw(line, context)
    return context.makeImage()!
}

extension SharedState {
    /// Every board's 3D model (Models/<board>.usdz through the production DeviceModelView), rendered headless with
    /// RealityRenderer, no window: the LCD keeps its aspect and scale whatever the viewport, the panel is mounted the
    /// right way, frame colors land at projected touch points in four orientations and two tilts, Home sits below the
    /// LCD with its glyph visible and its lighting steady, the side controls press where they're drawn, the spring and
    /// rotation animate, shake moves and tilts the model, N45's graphite and glass match Apple's shot, the LCD upscales
    /// nearest-neighbor, and screen off is black.
    @Suite struct ModelTests {
        init() {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            _ = fixtureMachines
        }

        @Test(arguments: [("N72", Board.n72), ("K48", .k48), ("N45", .n45), ("N81", .n81), ("N88", .n88)])
        func model(_ name: String, _ profile: Board) async throws {
            try await MainBundle.with([
                "Models/N72Studio.png": "Models/N72Studio.png", "Models/N45Rim.png": "Models/N45Rim.png",
                "Models/N81Studio.png": "Models/N81Studio.png"
            ]) {
                guard #available(macOS 15, *) else { return }  // RealityKit's texture rotation and RealityRenderer
                try await check(name, profile)
            }
        }

        @available(macOS 15, *) func check(_ name: String, _ profile: Board) async throws {
            let model = try await DeviceModelView(
                url: MainBundle.repository.appendingPathComponent("Models/\(name).usdz"),
                profile: profile
            )
            model.frame = NSRect(x: 0, y: 0, width: 800, height: 800)
            let cutout = profile.screenCutout.size
            /// The upright LCD's on-screen box: the four panel corners' projections.
            func lcdBox() -> CGRect {
                let points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map(
                    model.projectedPoint
                )
                let xs = points.map(\.x)
                let ys = points.map(\.y)
                return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            }
            // Resize the actual ARView synchronously: the projection must keep the
            // LCD's physical aspect and size before an asynchronous layout catches up.
            for size in [
                CGSize(width: 400, height: 1000), CGSize(width: 1200, height: 450), CGSize(width: 800, height: 800)
            ] {
                model.setFrameSize(size)
                model.pose(scale: 0.3, rotation: 0, roll: 0, pitch: 0, animated: false)
                let renderer = model.subviews[0] as! ARView
                #expect(renderer.bounds.size == size)
                let box = lcdBox()
                #expect(
                    abs(box.width / box.height - cutout.width / cutout.height) < 0.003,
                    "LCD stretched during resize to \(size): \(box.size)"
                )
                #expect(
                    abs(box.width - 0.3 * cutout.width) < 0.1,
                    "Display scale changed with viewport aspect: \(box.width)"
                )
            }
            // The panel's own axes on the upright model: the iPad's landscape panel is
            // mounted a quarter-turn clockwise, so its left edge (portrait SpringBoard's
            // status bar) is the device's top; the iPod's panel top is the top.
            let top = profile.panelRotation != 0 ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
            let bottom = CGPoint(x: 1 - top.x, y: 1 - top.y)
            let (t, b) = (model.projectedPoint(top), model.projectedPoint(bottom))
            #expect(
                t.y - b.y > 0.99 * lcdBox().height && abs(t.x - b.x) < 0.01,
                "Panel mounted the wrong way: top \(t) bottom \(b)"
            )
            let shell = model.shellPixels
            #expect(shell.width > cutout.width && shell.height > cutout.height)
            let points = [
                CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25), CGPoint(x: 0.25, y: 0.75),
                CGPoint(x: 0.75, y: 0.75)
            ]
            var homeLevels: [CGFloat] = []
            // No panel turns its surface with the device.
            for rotation in [0, 90, 180, 270] {
                let frame = pattern(profile)
                let reference = NSBitmapImageRep(cgImage: frame)
                model.updateFrame(frame)
                for tilt in [0.0, 0.35] {
                    model.pose(scale: 0.5, rotation: rotation, roll: tilt, pitch: tilt, animated: false)
                    let snapshot = try await render(model)
                    for p in points {
                        let screen = model.projectedPoint(p)
                        let hit = model.panelPoint(screen)!
                        #expect(hypot(hit.x - p.x, hit.y - p.y) < 0.0001)
                        let pixel = color(snapshot, screen, in: model.bounds.size)
                        let expected = reference.colorAt(
                            x: Int(p.x * CGFloat(frame.width)),
                            y: Int(p.y * CGFloat(frame.height))
                        )!.usingColorSpace(.displayP3)!
                        #expect(
                            abs(pixel.redComponent - expected.redComponent) < 0.22
                                && abs(pixel.greenComponent - expected.greenComponent) < 0.22
                                && abs(pixel.blueComponent - expected.blueComponent) < 0.22,
                            "Frame orientation mismatch rotation=\(rotation) tilt=\(tilt) point=\(p) pixel=\(pixel) reference=\(expected)"
                        )
                    }
                    if tilt == 0 {
                        let rect = model.homeButtonRect!
                        // Home sits below the LCD on the upright device, whichever way it is turned.
                        let rest = CGFloat(rotation == 270 ? -90 : rotation) * .pi / 180
                        let down = CGVector(dx: -sin(rest), dy: -cos(rest))  // y-up view; turns are clockwise
                        let lcd = lcdBox()
                        let offset = CGVector(dx: rect.midX - lcd.midX, dy: rect.midY - lcd.midY)
                        #expect(
                            offset.dx * down.dx + offset.dy * down.dy > 0.5 * max(lcd.width, lcd.height),
                            "Home is not below the LCD at \(rotation): \(rect) vs \(lcd)"
                        )
                        // The upright picture's top-left (red) stays at the device's top-left, however it is turned:
                        // the screen turns with the device, not stretched upright into it.
                        let s = 0.25 * min(lcd.width, lcd.height)
                        let topLeft = CGPoint(
                            x: lcd.midX + s * (sin(rest) - cos(rest)),
                            y: lcd.midY + s * (cos(rest) + sin(rest))
                        )
                        let corner = color(snapshot, topLeft, in: model.bounds.size)
                        #expect(
                            corner.redComponent > 0.6 && corner.greenComponent < 0.35 && corner.blueComponent < 0.35,
                            "Picture not upright on the device at \(rotation): \(corner)"
                        )
                        // The same spot on the cap in every orientation (the device's right of center).
                        let p = CGPoint(
                            x: rect.midX + rect.width * 0.3 * cos(rest),
                            y: rect.midY - rect.width * 0.3 * sin(rest)
                        )
                        let level = color(snapshot, p, in: model.bounds.size)
                        homeLevels.append(level.redComponent)
                        #expect(level.redComponent < 0.35, "Home button washed out: \(rotation) \(level)")
                        // The glyph's rounded square reads as a light ring on the black cap (K48's and N45's steel glyph vanished).
                        if rotation == 0 {
                            let rep = NSBitmapImageRep(cgImage: snapshot)
                            var levels: [CGFloat] = []
                            for i in 0..<40 {
                                for j in 0..<40 {
                                    let q = CGPoint(
                                        x: rect.minX + rect.width * (CGFloat(i) + 0.5) / 40,
                                        y: rect.minY + rect.height * (CGFloat(j) + 0.5) / 40
                                    )
                                    guard hypot(q.x - rect.midX, q.y - rect.midY) < rect.width * 0.4 else { continue }
                                    var px = [Int](repeating: 0, count: 4)
                                    rep.getPixel(
                                        &px,
                                        atX: Int(q.x / model.bounds.width * CGFloat(rep.pixelsWide)),
                                        y: Int((1 - q.y / model.bounds.height) * CGFloat(rep.pixelsHigh))
                                    )
                                    levels.append(
                                        (0.2126 * CGFloat(px[0]) + 0.7152 * CGFloat(px[1]) + 0.0722 * CGFloat(px[2]))
                                            / 255
                                    )
                                }
                            }
                            levels.sort()
                            let cap = levels[levels.count / 2]
                            let glyph = levels.last!
                            #expect(glyph - cap > 0.25, "Home glyph barely visible: \(glyph) on \(cap)")
                        }
                    }
                }
            }
            #expect(
                homeLevels.max()! - homeLevels.min()! < 0.12,
                "Home lighting changes with orientation: \(homeLevels)"
            )
            // Turned before the LCD's turned picture arrives: the last portrait frame turns with the device, its top-left
            // still at the device's top-left, not mapped for the new pose (it flashed stretched or turned on rotation).
            model.updateFrame(pattern(profile))
            for rotation in [90, 180, 270] {
                model.pose(scale: 0.5, rotation: rotation, roll: 0, pitch: 0, animated: false)
                let snapshot = try await render(model)
                let lcd = lcdBox()
                let rest = CGFloat(rotation == 270 ? -90 : rotation) * .pi / 180
                let s = 0.25 * min(lcd.width, lcd.height)
                let topLeft = CGPoint(
                    x: lcd.midX + s * (sin(rest) - cos(rest)),
                    y: lcd.midY + s * (cos(rest) + sin(rest))
                )
                let corner = color(snapshot, topLeft, in: model.bounds.size)
                #expect(
                    corner.redComponent > 0.6 && corner.greenComponent < 0.35 && corner.blueComponent < 0.35,
                    "The portrait frame doesn't turn with the device at \(rotation): \(corner)"
                )
            }
            // Hardware controls: each named side control answers where it is drawn, and
            // the LCD and bezel are not controls.
            model.updateFrame(pattern(profile))
            model.pose(scale: 0.5, rotation: 0, roll: 0, pitch: 0, animated: false)
            let view = model.subviews[0] as! ARView
            func projected(_ entity: Entity, _ fraction: SIMD3<Float>) -> CGPoint {
                let b = entity.visualBounds(relativeTo: nil)
                return model.convert(view.project(b.min + (b.max - b.min) * fraction)!, from: view)
            }
            var found: [String] = []
            for (names, expected) in [
                (["SleepWakeButton", "Sleep_wake___black_fitted_button"], [DeviceModelView.Control.sleepWake]),
                (["VolumeButton", "Volume___continuous_recessed_centre_rocker"], [.volumeUp, .volumeDown]),
                (["VolumeUpButton"], [.volumeUp]), (["VolumeDownButton"], [.volumeDown])
            ] {  // N81: two buttons
                guard let entity = names.lazy.compactMap({ view.scene.findEntity(named: $0) }).first else { continue }
                found.append(entity.name)
                if expected.count == 1 {
                    #expect(
                        model.control(at: projected(entity, [0.5, 0.5, 0.5])) == expected[0],
                        "\(entity.name) does not press"
                    )
                } else {
                    #expect(
                        model.control(at: projected(entity, [0.5, 0.8, 0.5])) == .volumeUp,
                        "\(entity.name) upper half is not volume up"
                    )
                    #expect(
                        model.control(at: projected(entity, [0.5, 0.2, 0.5])) == .volumeDown,
                        "\(entity.name) lower half is not volume down"
                    )
                }
            }
            #expect(model.control(at: model.projectedPoint(CGPoint(x: 0.5, y: 0.5))) == nil)
            let bezel = model.projectedPoint(
                CGPoint(x: bottom.x + (bottom.x - 0.5) * 0.12, y: bottom.y + (bottom.y - 0.5) * 0.12)
            )
            #expect(
                model.isChassis(bezel) && model.control(at: bezel) == nil,
                "The bezel below the LCD must grab the chassis"
            )
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                model.pose(scale: 0.5, rotation: 0, roll: 0, pitch: 0, animated: false)
                let rest = model.projectedPoint(top)
                model.pose(scale: 0.5, rotation: 0, roll: 0.4, pitch: 0, animated: false)
                let tilted = model.projectedPoint(top)
                model.pose(scale: 0.5, rotation: 0, roll: 0, pitch: 0, animated: true, spring: true)
                // A second layout with the same target must not cancel the spring.
                model.pose(scale: 0.5, rotation: 0, roll: 0, pitch: 0, animated: false)
                #expect(abs(model.projectedPoint(top).x - tilted.x) < 1)
                // The overshoot lasts only ~0.17-0.43 s: sample the spring rather than one instant.
                // Past the rest pose, as a fraction of the release distance (the spring peaks near 0.17).
                var overshoot: CGFloat = 0
                let released = CACurrentMediaTime()
                while CACurrentMediaTime() - released < 0.6 {
                    try await Task.sleep(for: .seconds(0.01))
                    model.advanceAnimations()
                    overshoot = max(overshoot, (rest.x - model.projectedPoint(top).x) / (tilted.x - rest.x))
                }
                #expect(overshoot > 0.05, "Spring must cross the resting pose: \(overshoot)")
                try await Task.sleep(for: .seconds(0.6))
                model.advanceAnimations()
                #expect(abs(model.projectedPoint(top).x - rest.x) < 0.01)
                // Some sample must sit well away from both the start and the end of the 0.4 s transition.
                let corner = CGPoint(x: 0.2, y: 0.3)
                let start = model.projectedPoint(corner)
                model.pose(scale: 0.8, rotation: 90, roll: 0, pitch: 0, animated: true)
                var path: [CGPoint] = []
                let turned = CACurrentMediaTime()
                while CACurrentMediaTime() - turned < 0.5 {
                    try await Task.sleep(for: .seconds(0.01))
                    model.advanceAnimations()
                    path.append(model.projectedPoint(corner))
                }
                let end = path.last!
                let between = path.map { min(hypot($0.x - start.x, $0.y - start.y), hypot($0.x - end.x, $0.y - end.y)) }
                    .max()!
                #expect(between > 10, "Rotation/scale must interpolate: \(between)")
            }
            model.pose(scale: 0.4, rotation: 0, roll: 0, pitch: 0, animated: false)
            try await Task.sleep(for: .seconds(0.1))
            let small = lcdBox().width
            model.pose(scale: 0.8, rotation: 0, roll: 0, pitch: 0, animated: false)
            try await Task.sleep(for: .seconds(0.1))
            let large = lcdBox().width
            #expect(abs(large / small - 2) < 0.001)
            let center = model.projectedPoint(CGPoint(x: 0.5, y: 0.5))
            /// Opposite LCD edges' length differences: a translation (even in depth)
            /// keeps the face-on panel a rectangle, only a tilt makes it a trapezoid.
            /// (The box width is no measure: a tilt widens it, backing away narrows it,
            /// and mid-shake the two cancel.)
            func skew() -> CGPoint {
                let p = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map(
                    model.projectedPoint
                )
                func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
                return CGPoint(x: length(p[0], p[1]) - length(p[2], p[3]), y: length(p[0], p[2]) - length(p[1], p[3]))
            }
            let restSkew = skew()
            // The wobble crosses its rest pose many times: sample it rather than one instant.
            var moved: CGFloat = 0
            var tilted: CGFloat = 0
            let shaken = CACurrentMediaTime()
            model.shake()
            while CACurrentMediaTime() - shaken < 0.25 {
                try await Task.sleep(for: .seconds(0.01))
                model.advanceAnimations()
                moved = max(moved, abs(model.projectedPoint(CGPoint(x: 0.5, y: 0.5)).x - center.x))
                tilted = max(tilted, abs(skew().x - restSkew.x) + abs(skew().y - restSkew.y))
            }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                #expect(moved > 1, "Shake must move the model: \(moved)")
                #expect(tilted > 0.2, "Shake must change 3D perspective, not only position: \(tilted)")
            }
            try await Task.sleep(for: .seconds(0.5))
            model.advanceAnimations()
            #expect(abs(model.projectedPoint(CGPoint(x: 0.5, y: 0.5)).x - center.x) < 0.01)
            model.pose(scale: 0.5, rotation: 0, roll: 0, pitch: 0, animated: false)
            let face = try await render(model)
            // N45 against Apple's product shot (touch_topsongs.jpg, color-managed from its CMYK to sRGB): a dark graphite
            // frame lit from the upper left, sRGB ~115-130 there falling to ~65-90 at the right and bottom, shot on white.
            // On the app's dark window that level already read as silver (Sam, 10-04: "mid-gray and even silver"), so the
            // frame sits a stop under the shot: luma ~0.34 upper left, ~0.18 lower right; anything at the old 0.5-0.75 is
            // silver again. The asset's near-black frameDark alone gives ~0.03 everywhere; flat paint gives no gradient.
            // Blue-black glass, ~25, with a faint sheen (~43) to the upper right of a diagonal (N45Rim).
            if profile == .n45 {
                func level(_ p: CGPoint) -> CGFloat {
                    let c = color(face, model.projectedPoint(p), in: model.bounds.size)
                    return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
                }
                let lit = [CGPoint(x: -0.095, y: 0.2), CGPoint(x: 0.5, y: -0.217)].map(level)
                let shade = [CGPoint(x: 1.095, y: 0.8), CGPoint(x: 0.5, y: 1.217)].map(level)
                let sheen = level(CGPoint(x: 0.85, y: -0.1))
                let glass = [CGPoint(x: 0.05, y: -0.2), CGPoint(x: 0.15, y: 1.1)].map(level)
                #expect(
                    lit.allSatisfy { $0 > 0.27 && $0 < 0.42 },
                    "N45 frame's upper left is not a dark graphite (silver above 0.42): \(lit)"
                )
                #expect(
                    shade.allSatisfy { $0 > 0.12 && $0 < 0.25 },
                    "N45 frame's lower right is not a darker graphite: \(shade)"
                )
                #expect(lit.min()! - shade.max()! > 0.1, "N45 frame has no upper-left light: \(lit) vs \(shade)")
                #expect(
                    glass.allSatisfy { $0 > 0.06 && $0 < 0.15 } && sheen - glass.max()! > 0.05,
                    "N45 glass is not blue-black with a sheen: \(glass) \(sheen)"
                )
            }
            // Nearest-neighbor upscaling: a 4x6 black/white checker blown up to ~600 px must keep hard edges.
            // A linear mag filter ramps across each ~150 px cell, leaving a third or more of a scan mid-gray.
            do {
                let cw = 4
                let ch = 6
                let checker = CGContext(
                    data: nil,
                    width: cw,
                    height: ch,
                    bitsPerComponent: 8,
                    bytesPerRow: cw * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )!
                for y in 0..<ch {
                    for x in 0..<cw where (x + y) % 2 == 0 {
                        checker.setFillColor(.white)
                        checker.fill(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
                model.updateFrame(checker.makeImage()!)
                let shot = try await render(model)
                var mid = 0
                var total = 0
                for i in 0..<400 {
                    let q = model.projectedPoint(CGPoint(x: 0.02 + 0.96 * Double(i) / 399, y: 0.25))
                    let c = color(shot, q, in: model.bounds.size)
                    if c.greenComponent > 0.15 && c.greenComponent < 0.85 { mid += 1 }
                    total += 1
                }
                #expect(mid * 100 < total * 3, "LCD upscaling is not nearest-neighbor: \(mid)/\(total) blurred samples")
                model.updateFrame(pattern(profile))
            }
            model.setScreenOff(true)
            let dark = color(
                try await render(model),
                model.projectedPoint(CGPoint(x: 0.5, y: 0.5)),
                in: model.bounds.size
            )
            #expect(dark.redComponent < 0.05 && dark.greenComponent < 0.05 && dark.blueComponent < 0.05)
        }
    }
}
