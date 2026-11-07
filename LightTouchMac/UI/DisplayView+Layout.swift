import Cocoa
import DeviceRuntime
import HostRuntime
import LightTouchCore

extension DisplayView {
    /// The shell layer stays at its native pixel size and carries scale and
    /// rotation in a single transform; the content layer is its child, parked
    /// at the screen cutout in shell-native pixels. Locked-together geometry
    /// falls out of the layer tree — layout only picks the scale, the angle,
    /// and the home button's (view-space) frame.
    override func layout() {
        super.layout()
        // The pose comes from the emulator's tracked orientation, not the frame
        // buffer's aspect — 480×320 alone can't tell landscape-left from
        // landscape-right, and 180° doesn't change the dimensions at all.
        // (Layout is still *triggered* by the dims flipping in step(), which
        // every quarter turn does.)
        let rotation = emulator?.rotationDegrees ?? 0
        if let lastRotation, lastRotation != rotation { endLiveText() }
        let orientationChanged = lastRotation.map { $0 != rotation } ?? false
        lastRotation = rotation

        let scale = zoomScale()
        appliedScale = scale
        applyZoomFilter()
        // Center on the safe area, not the raw bounds: a view that ran behind a
        // toolbar would push the device up under it. The main window's pane
        // (DeviceContentView) already starts below the toolbar, where its
        // gradient doesn't.
        let usable = deviceLayoutRect
        // A one-sided free-form resize keeps the opposite edge where it was.
        let offset = freeFormActive ? freeFormOffset : .zero
        let viewCenter = CGPoint(x: usable.midX + offset.dx, y: usable.midY + offset.dy)
        let shellCenter = CGPoint(x: shellPixels.width / 2, y: shellPixels.height / 2)
        let rest = Self.layerAngle(rotation)
        let angle = (motionRestAngle ?? rest) + tiltAngle

        // The home button is an NSView, so it can't ride the shell's transform;
        // project its shell-native center through the same rotation by hand.
        // NOTE: in this flipped (y-down) view the standard rotation matrix
        // turns a point visually clockwise for a positive angle — the SAME
        // visual direction a positive angle gives the layer transform here
        // (AppKit's geometry flip inverts a layer transform's handedness too),
        // so `rest` feeds both unconverted. At rest+tilt the button is mid-drag
        // and invisible anyway, so only `rest` is projected.
        let buttonCenterNative = CGPoint(
            x: shellPixels.width / 2,
            y: shellPixels.height - homeButtonBottomInset
                - homeButtonDiameter / 2
        )
        let native = CGVector(
            dx: buttonCenterNative.x - shellCenter.x,
            dy: buttonCenterNative.y - shellCenter.y
        )
        let buttonOffset = CGVector(
            dx: native.dx * cos(rest) - native.dy * sin(rest),
            dy: native.dx * sin(rest) + native.dy * cos(rest)
        )
        let buttonDiameter = (homeButtonDiameter * scale).rounded()
        let buttonRect = CGRect(
            x: (viewCenter.x + buttonOffset.dx * scale - buttonDiameter / 2).rounded(),
            y: (viewCenter.y + buttonOffset.dy * scale - buttonDiameter / 2).rounded(),
            width: buttonDiameter,
            height: buttonDiameter
        )

        let animate = orientationChanged || pendingAnimatedLayout
        pendingAnimatedLayout = false

        layoutContent()

        // Scale and rotation live in ONE transform, and the content is a child
        // of the shell — the whole device swings as a unit.
        CATransaction.begin()
        if animate {
            CATransaction.setAnimationDuration(Self.rotationDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)  // no implicit fade on plain resize
        }
        shellLayer.position = viewCenter
        shellLayer.transform = motionTransform(angle: angle, scale: scale)
        homeButton.isHidden = homeButtonHidden
        CATransaction.commit()

        modelView?.frame = bounds
        pendingModelView?.frame = bounds
        modelView?.viewportCenter = viewCenter
        pendingModelView?.viewportCenter = viewCenter
        updateModelPose(animated: animate)
        if let modelView, let rect = modelView.homeButtonRect {
            homeButton.frame = convert(rect, from: modelView)
        } else {
            homeButton.frame = buttonRect
        }
        if let liveTextView, let root = layer {
            if let modelView {
                let a = convert(modelView.projectedPoint(.zero), from: modelView)
                let b = convert(modelView.projectedPoint(CGPoint(x: 1, y: 1)), from: modelView)
                liveTextView.frame = CGRect(
                    x: min(a.x, b.x),
                    y: min(a.y, b.y),
                    width: abs(b.x - a.x),
                    height: abs(b.y - a.y)
                )
            } else {
                liveTextView.frame = contentLayer.convert(contentLayer.bounds, to: root)
            }
        }
        if freeFormActive { window?.invalidateCursorRects(for: self) }
        onZoomLayout?()
    }

    /// The content layer's bounds and turn for the frame it shows. currentFrame() calls it in the transaction that
    /// puts a frame up, as layout does, so a frame never shows in another frame's geometry. Every board's panel scans
    /// out as is, whatever way the device is held, and turns with the shell, as on hardware; the guest turns its own
    /// UI inside it. Applied WITHOUT animation. Bounds, never frame: setting .frame on a transformed layer is undefined
    /// (it was the squished-screen bug).
    func layoutContent() {
        // The scan stands a quarter-turn from upright when the guest turned its UI into it (guestTurn: the iPad's).
        let cutoutSize =
            guestTurn != 0 ? CGSize(width: screenCutout.height, height: screenCutout.width) : screenCutout.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.bounds = CGRect(origin: .zero, size: cutoutSize)
        // A frame of the size before a resize shows unscaled on black, not stretched to the new one.
        contentLayer.contentsGravity = holdsOldFrame ? .center : .resize
        contentLayer.masksToBounds = holdsOldFrame
        // Counter only the guest's quarter-turn, never the temporary tilt.
        // A layout during a gesture must not leave the panel crooked after release.
        // The panel turns with the shell: only the scan-to-upright quarter-turn applies.
        contentLayer.transform = CATransform3DMakeRotation(guestTurn, 0, 0, 1)
        CATransaction.commit()
    }

    /// No Home button bare (⇧⌘H presses it), while the model loads, or over a tilting flat shell.
    var homeButtonHidden: Bool {
        bare || !modelPresentationFinished || (modelView == nil && (tiltAngle != 0 || pitchAngle != 0))
    }
}
