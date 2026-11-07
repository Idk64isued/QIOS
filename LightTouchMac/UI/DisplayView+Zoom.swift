import Cocoa
import LightTouchCore

// The device's size in the pane: ZoomMode's points per guest pixel (p) for the pane, this display and this
// device as shown, the shell scale that draws it, and how the guest's pixels are filtered at it.

extension DisplayView {
    /// Points of breathing room between the shell and the pane edge when
    /// zoomed. A flat inset, not a fraction of the pane: 0.85 of the pane threw
    /// away 15% of a 1400-point window — over 200 points of black — to leave the
    /// same visual margin an 8-point gap gives.
    ///
    /// Wide enough that the shell's shadow has somewhere to fall.
    static let zoomInset: CGFloat = 16

    /// The display's points per millimeter where the view's center is; nil when it reports no physical size.
    private var pointsPerMillimeter: CGFloat? {
        guard let window else { return nil }
        let center = window.convertPoint(toScreen: convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? window.screen
        return screen.flatMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).flatMap {
                DisplayMeasurements.pointsPerMillimeter(
                    display: CGDirectDisplayID($0.uint32Value),
                    logical: screen.frame.size
                )
            }
        }
    }

    /// The sizes the zoom can be here: Fit for this pane and what is shown (the 3D model's outline, the flat shell
    /// or the bare screen, turned as the device is), the panel's physical size on this display, its backing scale.
    var zoomContext: ZoomContext {
        let usable = deviceLayoutRect
        let box = fittedBox
        let shellFit = min(
            max(usable.width - 2 * Self.zoomInset, 1) / box.width,
            max(usable.height - 2 * Self.zoomInset, 1) / box.height
        )
        return ZoomContext(
            fit: shellFit * shellPerGuestPixel,
            physical: ZoomContext.physical(pointsPerMillimeter: pointsPerMillimeter, ppi: profile.panelPPI),
            backing: window?.backingScaleFactor ?? 2
        )
    }

    /// Shell pixels per guest pixel: the cutout's width over the panel's (1 in free-form, where they are one).
    var shellPerGuestPixel: CGFloat { screenCutout.width / nativeScreenPixels.width }

    /// The p on screen now.
    var zoomPoints: CGFloat { appliedScale * shellPerGuestPixel }

    /// The box Fit fits, in shell pixels as seen: the 3D model's outline once it has one (the iPad's flat art is
    /// smaller), the flat shell, or bare the screen alone; swapped in landscape.
    var fittedBox: CGSize {
        let shell = (modelView ?? pendingModelView)?.shellPixels ?? shellPixels
        let fitted = bare ? screenCutout.size : shell
        let rotation = emulator?.rotationDegrees ?? 0
        return rotation == 90 || rotation == 270 ? CGSize(width: fitted.height, height: fitted.width) : fitted
    }

    @objc func screenChanged() { needsLayout = true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        screenChanged()
    }

    /// The shell's scale for the current zoom.
    func zoomScale() -> CGFloat {
        zoomContext.points(for: zoom) / shellPerGuestPixel
    }

    /// Crisp or smoothed by the one rule (ZoomContext.drawsNearest), the flat screen and the 3D model alike.
    func applyZoomFilter() {
        let nearest = ZoomContext.drawsNearest(points: zoomPoints, backing: window?.backingScaleFactor ?? 2)
        contentLayer.magnificationFilter = nearest ? .nearest : .linear
        modelView?.drawsNearest = nearest
        pendingModelView?.drawsNearest = nearest
    }
}
