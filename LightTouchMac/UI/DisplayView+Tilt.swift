import Cocoa
import DeviceRuntime
import HostRuntime
import LightTouchCore

extension DisplayView {
    // Grabbing the shell anywhere outside the screen — bezel or corners — and
    // dragging side to side steers tilt games; dragging up/down adds pitch.
    // Both axes change the gravity vector measured by the accelerometer.
    // Release springs the shell back to rest and restores resting gravity.

    /// Radians of device tilt per point of two-finger swipe, when the cursor is
    /// off the panel. Much gentler than a drag: a swipe has no anchor to hold
    /// on to, so the same rate that feels direct under a finger feels wild here.
    /// A full trackpad sweep is a few degrees, which is the range tilt games use.
    var tilting: Bool { tilt.tilting }
    var tiltAngle: CGFloat { tilt.tiltAngle }  // current drag delta from rest

    /// The shell layer's rest rotation for a guest orientation, signed so 270°
    /// comes in as a single quarter turn (-π/2), not three of them — the
    /// implicit animation interpolates the transform, and the sign is what
    /// makes the swing take the short way round.
    static func layerAngle(_ degrees: Int) -> CGFloat { ChassisTilt.layerAngle(degrees) }

    /// The shell's resting rotation for the guest's current orientation —
    /// the same angle layout() starts from.
    var restAngle: CGFloat { tilt.restAngle(rotation: emulator?.rotationDegrees ?? 0) }

    /// The model's side buttons are hardware, like Home: they work asleep too.
    func pressModelControl(_ event: NSEvent) -> Bool {
        guard let modelView, let control = modelView.control(at: modelView.convert(event.locationInWindow, from: nil))
        else { return false }
        switch control {
        case .sleepWake: emulator?.pressLock()
        case .volumeUp: emulator?.pressVolumeUp()
        case .volumeDown: emulator?.pressVolumeDown()
        }
        return true
    }

    /// Keep direct manipulation on the chassis and guest touches on the LCD.
    func isChassisEvent(_ event: NSEvent) -> Bool { isChassis(windowPoint: event.locationInWindow) }

    func isChassis(windowPoint: NSPoint) -> Bool {
        if let modelView {
            return modelView.isChassis(modelView.convert(windowPoint, from: nil))
        }
        // Bare, there is no chassis to grab: the empty shell around the screen is the backdrop.
        guard modelPresentationFinished, !bare, let rootLayer = layer else { return false }
        let p = convert(windowPoint, from: nil)
        let sp = shellLayer.convert(p, from: rootLayer)
        return shellLayer.bounds.contains(sp) && !screenCutout.contains(sp)
    }

    /// The same transform layout() computes, at an arbitrary angle, applied
    /// without animation — this is the per-mouse-move path.
    func motionTransform(angle: CGFloat, scale: CGFloat) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / 1400
        let flat = emulator?.motionPose == .flat
        transform = CATransform3DRotate(transform, flat ? angle - tiltAngle : angle, 0, 0, 1)
        transform = CATransform3DRotate(transform, pitchAngle, 1, 0, 0)
        transform = CATransform3DRotate(transform, flat ? tiltAngle : 0, 0, 1, 0)
        return CATransform3DScale(transform, scale, scale, 1)
    }

    func updateModelPose(animated: Bool = false, spring: Bool = false) {
        (modelView ?? pendingModelView)?.pose(
            scale: appliedScale,
            rotation: emulator?.rotationDegrees ?? 0,
            roll: tiltAngle,
            pitch: pitchAngle,
            flat: emulator?.motionPose == .flat,
            animated: animated,
            spring: spring
        )
    }

    func projectedPanelPoint(_ point: CGPoint) -> CGPoint {
        if let modelView { return convert(modelView.projectedPoint(point), from: modelView) }
        return contentLayer.convert(
            CGPoint(
                x: point.x * contentLayer.bounds.width,
                y: point.y * contentLayer.bounds.height
            ),
            to: layer
        )
    }

    @objc func levelAttitude(_ sender: Any?) { resetMotion() }
    func sendAttitude() {
        attitudeIndicator.update(pitch: pitchAngle, roll: tiltAngle)
        attitudeIndicator.isHidden = !touchInteractionEnabled || (abs(pitchAngle) < 0.001 && abs(tiltAngle) < 0.001)
        // Flat, gravity points into the display: its screen-relative X/Y go into the sensor axes (ChassisTilt).
        // Gravity rests on how the device is held, not on a turn a front app made: this runs at every focus change.
        let attitude = tilt.attitude(rotation: emulator?.heldDegrees ?? 0, flat: emulator?.motionPose == .flat)
        emulator?.setTilt(angle: attitude.angle, pitch: attitude.pitch)
    }

    /// The trick is the 3D model's: 2D, Off, or a model still loading has nothing to flip.
    var canPerformSpecialTrick: Bool { modelView != nil }
    func specialTrick() { modelView?.specialTrick() }

    func resetMotion() {
        endTilt()
    }

    func setShellAngle(_ angle: CGFloat, animated: Bool = false) {
        updateModelPose(animated: animated, spring: animated)
        shellLayer.removeAnimation(forKey: "tiltSnap")
        shellLayer.removeAnimation(forKey: "transform")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shellLayer.transform = motionTransform(angle: angle, scale: appliedScale)
        homeButton.isHidden = homeButtonHidden
        CATransaction.commit()
    }

    func endTilt() {
        wheelTiltResetTask?.cancel()
        let from = shellLayer.presentation()?.transform ?? shellLayer.transform
        tilt.reset()
        setShellAngle(restAngle, animated: true)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: shellLayer.transform)
        spring.stiffness = 200
        spring.damping = 14
        spring.duration = spring.settlingDuration
        shellLayer.add(spring, forKey: "tiltSnap")
        // Gravity snaps straight to rest; the spring is only visual.
        sendAttitude()
    }

    /// Send a mouse event to the guest as a touch.
    ///
    /// This used to bail whenever the cursor was outside the screen — which
    /// silently dropped the TOUCH_END of any drag that ended off the panel, and
    /// a drag that runs past the edge is the most ordinary gesture there is.
    /// The guest then believed a finger was still down forever: scrolling
    /// stopped working, and `mtt_bh`'s tracked flag (which only clears on an
    /// END) desynced so no later pinch ever began. So:
    ///
    /// - a BEGIN outside the screen is not a touch, and is dropped — but then
    ///   nothing is in flight, so the matching END is dropped too;
    /// - once down, UPDATEs clamp to the panel edge rather than vanishing,
    ///   which is also what a real finger sliding onto the bezel does;
    /// - an END is delivered whenever a touch is down, wherever the cursor is.
    func emit(_ event: NSEvent, _ phase: Int32) {
        if phase == TouchPhase.begin {
            guard let (nx, ny) = normalized(event) ?? nearScreenEdge(event) else { return }
            touchDown = true
            send(phase, nx, ny)
            return
        }
        guard touchDown, let p = clampedPanelPoint(event) else { return }
        if phase == TouchPhase.end { touchDown = false }
        send(phase, Double(p.x), Double(p.y))
    }

    func send(_ phase: Int32, _ nx: Double, _ ny: Double) {
        sendVisualTouch(0, phase, nx, ny)
        // Option: second finger mirrored through the panel center (pinch).
        // Option-Shift: second finger at a locked offset (two-finger pan).
        let p = CGPoint(x: nx, y: ny)
        guard let q = touchPair.secondFinger(for: p, []) else { return }
        sendVisualTouch2(phase, Double(q.x), Double(q.y))
        showPairRings(phase == TouchPhase.end ? nil : (p, q))
    }
}
