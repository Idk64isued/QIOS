import AppKit
import Testing

@testable import AppViews
@testable import Display
@testable import LightTouchCore

extension SharedState {
    /// The collapsed console bar over a real DisplayView (issue 33), offscreen: an iPad at Fit with its flat bezel,
    /// the pane short enough that the device reaches the inset above the window's bottom edge. Portrait puts the Home
    /// button inside the bar's strip; it must still be the Home button's, as the bezel beside it is the device's.
    /// Renders go to the temporary directory.
    @Suite struct ConsoleOverDeviceTests {
        init() {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            _ = Display.fixtureMachines
        }

        @Test(arguments: [0, 90]) func homeButtonUnderTheCollapsedBar(_ rotation: Int) async throws {
            try await MainBundle.with([
                "ipad-frame.png": "LightTouchMac/Assets.xcassets/ipad-frame.imageset/ipad-frame.png"
            ]) {
                DisplayView.bezel = .flat
                defer { UserDefaults.standard.removeObject(forKey: DisplayView.bezelKey) }
                let suite = "ltm-console-device-check-\(getpid())"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let display = DisplayView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600), profile: .k48)
                let e = Display.EmulatorController()
                display.emulator = e
                e.rotationDegrees = rotation
                // Over the device's gradient, as DeviceContentView holds it.
                let pane = NSView(frame: display.frame)
                pane.wantsLayer = true
                pane.layer?.contents = NSImage(
                    contentsOf: MainBundle.repository.appendingPathComponent(
                        "LightTouchMac/Assets.xcassets/gradient.imageset/gradient.jpeg"
                    )
                )
                pane.layer?.contentsGravity = .resizeAspectFill
                display.autoresizingMask = [.width, .height]
                pane.addSubview(display)
                let split = ConsoleSplitView(top: pane, autosaveName: "view", defaults: defaults)
                split.bar.overGradient = true
                split.bar.paneTakesPress = { display.takesPress(atWindowPoint: $0) }
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                window.contentView = split
                split.wantsLayer = true
                display.needsLayout = true
                split.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                split.layoutSubtreeIfNeeded()

                #expect(split.layout.isCollapsed && pane.frame == split.bounds, "the device has the whole pane")
                let home = display.homeButton
                #expect(!home.isHidden, "the flat bezel's Home button shows")
                let homeRect = split.convert(home.bounds, from: home)
                let center = NSPoint(x: homeRect.midX, y: homeRect.midY)
                if rotation == 0 {
                    #expect(homeRect.minY < ConsoleBar.height, "portrait's Home button reaches the strip: \(homeRect)")
                }
                #expect(
                    split.hitTest(center)?.isDescendant(of: home) == true,
                    "the Home button at \(center) is the device's, got \(String(describing: split.hitTest(center)))"
                )
                // The bezel beside the Home button is the device's (its chassis, which a drag tilts); under the
                // device's bottom edge and beside it, the strip is the console divider's grab area.
                let shellRect = split.convert(display.shellLayer.frame, from: display)
                let bezel = NSPoint(x: homeRect.maxX + 30, y: shellRect.minY + 8)
                #expect(shellRect.minY + 8 < ConsoleBar.height, "the bezel reaches the strip: \(shellRect)")
                #expect(split.hitTest(bezel) === display, "the strip beside the Home button is the device's")
                #expect(!split.bar.grabs(bezel), "no resize cursor over the device")
                for off in [NSPoint(x: bezel.x, y: shellRect.minY - 6), NSPoint(x: 100, y: 10)] {
                    #expect(split.hitTest(off) === split.bar && split.bar.grabs(off), "the strip at \(off) grabs")
                }

                // The layer tree, not cacheDisplay: the device's scale and turn live in layer transforms. render(in:)
                // skips a transform with perspective, so the shell's goes flat for the picture (at rest, no tilt, the
                // perspective term changes nothing on screen).
                split.displayIfNeeded()
                let shell = display.shellLayer
                let posed = shell.transform
                var flat = posed
                flat.m34 = 0
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                shell.transform = flat
                CATransaction.commit()
                defer { shell.transform = posed }
                let scale: CGFloat = 2
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(split.bounds.width * scale),
                    pixelsHigh: Int(split.bounds.height * scale),
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                )!
                let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
                context.scaleBy(x: scale, y: scale)
                try #require(split.layer).render(in: context)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "ltm-console-over-ipad-\(rotation).png"
                )
                try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                print("render: \(url.path) home \(homeRect)")
            }
        }
    }
}
