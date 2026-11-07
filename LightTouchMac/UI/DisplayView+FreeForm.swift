import Cocoa
import DeviceRuntime
import HostRuntime
import LightTouchCore

extension DisplayView {
    // View ▸ Free-Form Screen: no bezel, and the screen itself is resizable. Its edges and corners are handles (a
    // band just outside it, with resize cursors); a drag moves the grabbed edge and keeps the opposite one where it
    // was (⌥ moves both), snapped only to what the board's panel= takes (FreeFormResize), at the zoom it had: Fit
    // is held as its points per guest pixel, so the screen doesn't jump. While a new size waits, the last frame
    // shows unscaled in it, the window's subtitle reads the size (and why an edge stopped), and the owner offers
    // Apply (Return) and Revert (Escape). Apply records the size and, if the device runs, restarts it there (Stop's
    // hard halt, then a fresh helper): UIKit takes the panel's size at boot only. The last frame stays up, through
    // the next session's view (`handoffs`), until the new boot's first frame. View ▸ Native Size and a double-click
    // on a handle make the shipped size the new one.

    var freeFormActive: Bool { freeFormPanel != nil || freeFormTarget != nil }
    /// The running scan's scan-to-upright turn: the shipped panel's, or the free-form one's (Board.freeFormTurn).
    var guestTurn: CGFloat { runningScan.map(profile.freeFormTurn(scan:)) ?? profile.panelRotation }

    var isFreeForm: Bool { freeFormPanel != nil }
    var canToggleFreeForm: Bool { profile.supportsFreeForm && !restartingAtPanel }

    /// A new size waits for Apply.
    var hasPendingPanel: Bool {
        isFreeForm && !restartingAtPanel && freeFormTarget.map { $0 != freeFormPanel } == true
    }
    var canShowNativeSize: Bool {
        isFreeForm && !restartingAtPanel && (freeFormTarget ?? freeFormPanel) != profile.uprightScreenPixels
    }

    /// The screen's size as seen ("640 × 1136"); nil when not free-form.
    var freeFormSize: String? { (freeFormTarget ?? freeFormPanel).map { FreeFormResize.text(onScreen($0)) } }
    /// The size, and why an edge stopped.
    var freeFormReadout: String? {
        freeFormSize.map { ([$0] + [freeFormLimit].compactMap { $0 }).joined(separator: " — ") }
    }

    /// The width of the handles, just outside the screen's edges.
    static let handleBand: CGFloat = 10
    /// The last frame of a device restarting at a new panel, for that device's next view.
    private static var handoffs: [UUID: CGImage] = [:]

    /// The owner's device: its recorded panel as it scans (nil when not free-form) and its identity for the hand-off.
    func configureFreeForm(scan: CGSize?, key: UUID) {
        deviceKey = key
        if profile.supportsFreeForm, let scan {
            runningScan = scan
            freeFormPanel = profile.uprightPanel(scan: scan)
            applyFreeFormGeometry()
            applyBezel(.off)
            needsLayout = true
        }
        if let image = Self.handoffs.removeValue(forKey: key) {
            contentLayer.contents = image
            showsHandoff = true
            restartTitle =
                "Restarting at \(FreeFormResize.text(onScreen(freeFormPanel ?? profile.uprightScreenPixels)))…"
        }
    }

    /// View ▸ Free-Form Screen. On keeps the running size (the shipped panel's; no restart); off returns to the
    /// shipped panel and the bezel, restarting if the guest runs at another size.
    func setFreeForm(_ on: Bool) {
        guard canToggleFreeForm, on != isFreeForm else { return }
        let native = profile.uprightScreenPixels
        if on {
            runningScan = nil
            freeFormPanel = native
            _ = onPanelChange?(native, false)
            applyFreeFormGeometry()
            applyBezel(.off)
            needsLayout = true
            freeFormChanged()
            return
        }
        let running = freeFormPanel
        freeFormPanel = nil
        freeFormTarget = running == native ? nil : native
        freeFormOffset = .zero
        freeFormLimit = nil
        if freeFormTarget == nil || !requestPanel(nil) {
            if freeFormTarget == nil { _ = onPanelChange?(nil, false) }
            freeFormTarget = nil
            applyFreeFormGeometry()
            applyBezel(Self.bezel)
        }
        needsLayout = true
        freeFormChanged()
    }

    /// Apply (or Return): restart at the new size, or with the device stopped simply take it.
    func applyPanel() {
        guard hasPendingPanel, let target = freeFormTarget else { return }
        if !requestPanel(target) {
            runningScan = profile.scan(upright: target)  // recorded for the next start
            freeFormPanel = target
            clearPendingPanel()
        }
        freeFormChanged()
    }

    /// Revert (or Escape): back to the running size.
    func revertPanel() {
        guard hasPendingPanel else { return }
        clearPendingPanel()
        freeFormChanged()
    }

    /// View ▸ Native Size, or a double-click on a handle: the shipped size, waiting for Apply like a drag's.
    func showNativeSize() {
        guard canShowNativeSize else { return }
        freeFormTarget = profile.uprightScreenPixels
        freeFormOffset = .zero
        freeFormLimit = nil
        if freeFormTarget == freeFormPanel { freeFormTarget = nil }
        applyFreeFormGeometry()
        needsLayout = true
        freeFormChanged()
    }

    private func clearPendingPanel() {
        freeFormTarget = nil
        freeFormOffset = .zero
        freeFormLimit = nil
        applyFreeFormGeometry()
        needsLayout = true
    }

    private func freeFormChanged() {
        window?.invalidateCursorRects(for: self)
        onFreeFormChange?()
    }

    /// The screen's box in the shell follows the size shown; the caller lays out (or is layout).
    private func applyFreeFormGeometry() {
        guard let size = freeFormTarget ?? freeFormPanel else {
            nativeScreenPixels = profile.uprightScreenPixels
            screenCutout = profile.screenCutout
            return
        }
        // One shell unit per guest pixel, centered where the shipped screen sits (layout adds freeFormOffset).
        nativeScreenPixels = size
        let center = CGPoint(x: profile.screenCutout.midX, y: profile.screenCutout.midY)
        screenCutout = CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Upright ⇄ as seen: the device's quarter-turns swap the sides.
    private func onScreen(_ size: CGSize) -> CGSize {
        quarterTurned ? CGSize(width: size.height, height: size.width) : size
    }
    private var quarterTurned: Bool { (emulator?.rotationDegrees ?? 0) % 180 != 0 }

    private var screenRect: CGRect? {
        guard let root = layer else { return nil }
        return contentLayer.convert(contentLayer.bounds, to: root)
    }

    /// The edges a press on a handle grabs; nil off the handles, or when the screen can't be resized now.
    func panelEdges(at p: CGPoint) -> CGVector? {
        guard isFreeForm, !restartingAtPanel, let r = screenRect else { return nil }
        return FreeFormResize.edges(at: p, screen: r, band: Self.handleBand)
    }

    /// The mouse on a handle: a press grabs it, a drag resizes, the release leaves the size waiting for Apply.
    /// True when the event was the resize's (not a touch).
    func panelResize(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            guard let edges = panelEdges(at: p) else { return false }
            if event.clickCount == 2 {
                showNativeSize()
                return true
            }
            // Fit would refit the new size; the drag holds the size it shows, in points per guest pixel.
            if zoom == .fit { zoom = .points(zoomPoints) }
            let start = freeFormTarget ?? freeFormPanel ?? profile.uprightScreenPixels
            panelDrag = (p, edges, onScreen(start), freeFormOffset)
        case .leftMouseDragged:
            guard let drag = panelDrag else { return false }
            let result = FreeFormResize(board: profile).drag(
                from: drag.size,
                edges: drag.edges,
                by: CGVector(dx: p.x - drag.origin.x, dy: p.y - drag.origin.y),
                points: zoomPoints,
                symmetric: event.modifierFlags.contains(.option),
                quarterTurned: quarterTurned
            )
            freeFormTarget = onScreen(result.size)
            freeFormOffset = CGVector(dx: drag.offset.dx + result.shift.dx, dy: drag.offset.dy + result.shift.dy)
            freeFormLimit = result.limit
            applyFreeFormGeometry()
            needsLayout = true
            freeFormChanged()
        default:
            guard panelDrag != nil else { return false }
            panelDrag = nil
            if freeFormTarget == freeFormPanel { clearPendingPanel() }
            freeFormChanged()
        }
        return true
    }

    /// Return applies a waiting size and Escape reverts it, before the keys would reach the guest.
    func panelKey(_ event: NSEvent) -> Bool {
        guard hasPendingPanel, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        switch event.keyCode {
        case 36, 76: applyPanel()
        case 53: revertPanel()
        default: return false
        }
        return true
    }

    /// Record the panel and have the owner restart on it. While it restarts the screen keeps the last frame
    /// (unscaled) and reads "Restarting at…", and the frame waits for the next view. False: nothing restarts.
    private func requestPanel(_ upright: CGSize?) -> Bool {
        let image = currentFrame().flatMap { Self.image($0, colorSpace: colorSpace) }
        guard onPanelChange?(upright, true) == true else { return false }
        restartingAtPanel = true
        if let deviceKey, let image { Self.handoffs[deviceKey] = image }
        updatePowerPresentation()
        return true
    }

    /// The owner couldn't restart (the helper didn't exit, or another restart was under way): the size waits for
    /// Apply again, and no later restart inherits this one's last frame (state audit C-4).
    func panelRestartRefused() {
        guard restartingAtPanel else { return }
        restartingAtPanel = false
        if let deviceKey { Self.handoffs[deviceKey] = nil }
        updatePowerPresentation()
        freeFormChanged()
    }

    /// "Restarting at W × H…" while this device restarts at a new size.
    var panelRestartText: String? {
        guard restartingAtPanel else { return nil }
        return "Restarting at \(FreeFormResize.text(onScreen(freeFormTarget ?? profile.uprightScreenPixels)))…"
    }

    /// A frame of another size than the screen's (the last one before a resize or restart) shows unscaled.
    var holdsOldFrame: Bool { freeFormTarget != nil || restartingAtPanel || showsHandoff }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isFreeForm, !restartingAtPanel, let r = screenRect else { return }
        let b = Self.handleBand
        addCursorRect(CGRect(x: r.minX - b, y: r.minY, width: b, height: r.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: r.maxX, y: r.minY, width: b, height: r.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: r.minX, y: r.minY - b, width: r.width, height: b), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: r.minX, y: r.maxY, width: r.width, height: b), cursor: .resizeUpDown)
        for (x, y) in [(r.minX - b, r.minY - b), (r.maxX, r.minY - b), (r.minX - b, r.maxY), (r.maxX, r.maxY)] {
            addCursorRect(
                CGRect(x: x, y: y, width: b, height: b),
                cursor: Self.cornerCursor(left: x < r.minX, top: y < r.minY)
            )
        }
    }

    /// A diagonal resize cursor (macOS 15); before it, the crosshair.
    static func cornerCursor(left: Bool, top: Bool) -> NSCursor {
        guard #available(macOS 15, *) else { return .crosshair }
        let position: NSCursor.FrameResizePosition =
            top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
        return .frameResize(position: position, directions: .all)
    }
}
