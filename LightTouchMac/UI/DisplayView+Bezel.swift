import Cocoa
import DeviceRuntime
import HostRuntime
import LightTouchCore

extension DisplayView {
    @objc func bezelPreferenceChanged() { applyBezel(freeFormActive ? .off : Self.bezel) }

    /// The device around the screen, its flat art, or the screen alone. Flat and bare drop the model (and its
    /// load); bare also empties the shell layer, which stays as the screen's transform: rotation, zoom and touch
    /// mapping are unchanged.
    func applyBezel(_ bezel: Bezel) {
        guard bezel != appliedBezel else { return }
        // 3D skipped after a crash (CrashGuard) is applied again each time, so choosing 3D tries it again.
        let modelSkipped = bezel == .model && CrashGuard.skips(.model)
        appliedBezel = modelSkipped ? nil : bezel
        bare = bezel == .off
        modelLoadTask?.cancel()
        modelFallbackTask?.cancel()
        modelLoadTask = nil
        for model in [modelView, pendingModelView] { model?.removeFromSuperview() }
        modelView = nil
        pendingModelView = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shellLayer.removeAnimation(forKey: "modelPresentation")
        let art =
            bare ? nil : NSImage(named: profile.shellImageName)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        shellLayer.contents = art
        shellLayer.shadowOpacity = bare ? 0 : 0.4
        // The shadow follows the art's outline. Without a path Core Animation casts it from everything the layer
        // draws, the live screen inside it included, so each new frame rendered the shadow again offscreen and
        // redrew its whole area, which reaches up under the toolbar's glass (issue 107).
        shellLayer.shadowPath = art.map { Self.outline(of: $0, size: shellPixels) }
        // Bare, the transform turns and scales about the screen's center, which layout() puts at the pane's.
        shellLayer.anchorPoint =
            bare
            ? CGPoint(x: screenCutout.midX / shellPixels.width, y: screenCutout.midY / shellPixels.height)
            : CGPoint(x: 0.5, y: 0.5)
        shellLayer.isHidden = false
        CATransaction.commit()
        modelPresentationFinished = true
        // macOS 14 keeps the photo shell; RealityKit texture rotation requires 15.
        if bezel == .model, Self.rendersModel, !modelSkipped, #available(macOS 15, *),
            let name = profile.deviceModelName,
            let url = Bundle.main.url(forResource: name, withExtension: "usdz", subdirectory: "Models")
        {
            modelPresentationFinished = false
            // Give RealityKit one second to present the device itself. Slower
            // startup shows a temporary photo while the live model keeps
            // loading; a busy GPU must never permanently disable 3D.
            shellLayer.isHidden = true
            homeButton.isHidden = true
            let profile = profile
            modelFallbackTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.showStaticDevice()
            }
            CrashGuard.begin(.model)
            modelLoadTask = Task { [weak self] in
                defer { CrashGuard.end(.model) }
                do {
                    let model = try await DeviceModelView(url: url, profile: profile)
                    try Task.checkCancellation()
                    guard self?.stageModelForPresentation(model) == true else { return }
                    let frameReady = await model.prepareFirstFrame()
                    try Task.checkCancellation()
                    // Do not retain the display across a renderer callback. A
                    // stalled snapshot must not keep a closed window alive.
                    guard frameReady else { return }
                    self?.presentModel(model)
                } catch is CancellationError {} catch {
                    NSLog("%@ model could not load: %@", name, error.localizedDescription)
                    self?.showStaticDevice()
                }
            }
        }
        needsLayout = true
    }

    /// The art's opaque outline in the shell layer's space (`size`, top-left origin like the screen cutout): each
    /// row's leftmost and rightmost opaque pixel, every few rows, as one polygon. A device's outline is convex
    /// across each row, so that is its shape to within the rows skipped.
    static func outline(of art: CGImage, size: CGSize) -> CGPath {
        let (width, height) = (art.width, art.height)
        var alpha = [UInt8](repeating: 0, count: width * height)
        alpha.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            )?.draw(art, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let (sx, sy) = (size.width / CGFloat(width), size.height / CGFloat(height))
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for row in stride(from: 0, to: height, by: 4) {
            let line = alpha[(row * width)..<((row + 1) * width)]
            guard let first = line.firstIndex(where: { $0 >= 128 }), let last = line.lastIndex(where: { $0 >= 128 })
            else { continue }
            let y = CGFloat(row) * sy
            left.append(CGPoint(x: CGFloat(first - row * width) * sx, y: y))
            right.append(CGPoint(x: CGFloat(last + 1 - row * width) * sx, y: y))
        }
        let path = CGMutablePath()
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
        return path
    }

    private func stageModelForPresentation(_ model: DeviceModelView) -> Bool {
        guard modelView == nil else { return false }
        addSubview(model, positioned: .below, relativeTo: homeButton)
        pendingModelView = model
        model.alphaValue = 0
        model.setScreenOff(powerPresentation != .awake)
        if let surface = currentFrame(), let image = Self.image(surface, colorSpace: colorSpace) {
            model.updateFrame(image)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        return true
    }

    private func showStaticDevice() {
        guard modelView == nil else { return }
        modelPresentationFinished = true
        modelFallbackTask?.cancel()
        shellLayer.isHidden = false
        needsLayout = true
    }

    private func presentModel(_ model: DeviceModelView) {
        guard modelView == nil else { return }
        modelPresentationFinished = true
        modelFallbackTask?.cancel()
        pendingModelView = nil
        modelView = model
        model.setScreenOff(powerPresentation != .awake)
        needsLayout = true
        layoutSubtreeIfNeeded()
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.0 : 0.2
        if !shellLayer.isHidden, duration > 0 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shellLayer.opacity
            fade.toValue = 0
            fade.duration = duration
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            shellLayer.add(fade, forKey: "modelPresentation")
        } else {
            shellLayer.isHidden = true
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            model.animator().alphaValue = CGFloat(shellLayer.opacity)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.shellLayer.isHidden = true
                self?.shellLayer.removeAnimation(forKey: "modelPresentation")
            }
        }
    }
}
