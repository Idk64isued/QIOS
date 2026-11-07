import AppKit
import HostRuntime
import Testing

@testable import Display
@testable import LightTouchCore

extension SharedState {
    /// The zoom drawn offscreen: Physical Size is the panel's real width in every bezel mode, Pixel Accurate one
    /// display pixel per guest pixel and crisp, smoothed between whole pixels (the 3D model too), and each board's
    /// saved zoom comes back in a new view.
    @Suite struct ZoomLayoutTests {
        init() {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            _ = fixtureMachines
            frozen = false
        }

        static let art = DisplayTests.n72Model.merging([
            "ipad-frame.png": "LightTouchMac/Assets.xcassets/ipad-frame.imageset/ipad-frame.png",
            "shell-iphone4.png": "LightTouchMac/Assets.xcassets/shell-iphone4.imageset/shell-iphone4.png"
        ]) { a, _ in a }

        @Test func sizesInEveryBezel() async throws {
            for key in [DisplayView.bezelKey, DisplayView.showsBezelKey] + Board.allCases.map(ZoomMode.defaultsKey) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            defer {
                UserDefaults.standard.removeObject(forKey: DisplayView.bezelKey)
                for board in Board.allCases {
                    UserDefaults.standard.removeObject(forKey: ZoomMode.defaultsKey(for: board))
                }
            }
            try await MainBundle.with(Self.art) {
                DeviceModelView.loadingDelay = .zero
                DeviceModelView.preparationDelay = .milliseconds(20)
                for board in [Board.n72, .k48, .n90] { try await sizes(board) }
            }
        }

        func sizes(_ board: Board) async throws {
            func check(_ ok: Bool, _ what: String, line: Int = #line) { #expect(ok, "\(board) line \(line): \(what)") }
            frameWidth = Int32(board.screenPixels.width)
            frameHeight = Int32(board.screenPixels.height)
            let guest = board.uprightScreenPixels
            var physicalWidths: [CGFloat] = []
            for bezel in [DisplayView.Bezel.model, .flat, .off] {
                DisplayView.bezel = bezel
                let d = DisplayView(frame: NSRect(x: 0, y: 0, width: 900, height: 900), profile: board)
                let e = EmulatorController()
                d.emulator = e
                let window = NSWindow(contentRect: d.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = d
                defer {
                    window.contentView = nil
                    withExtendedLifetime(e) {}
                }
                func settle() async throws {
                    d.needsLayout = true
                    d.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(150))
                    d.layoutSubtreeIfNeeded()
                }
                func all(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(all) }
                let root = try #require(d.layer)
                let lcd = try #require(
                    all(root).first { $0.backgroundColor == NSColor.black.cgColor && $0.contentsGravity == .resize }
                )
                /// The LCD's on-screen width; the 3D model's display projects at the same scale (DeviceModelView).
                func lcdWidth() -> CGFloat {
                    let box = lcd.convert(lcd.bounds, to: root)
                    return min(box.width, box.height)
                }
                let backing = window.backingScaleFactor
                let what = "\(bezel)"

                d.zoom = .physical
                try await settle()
                if let physical = d.zoomContext.physical {
                    let width = d.appliedScale * d.screenCutout.width
                    check(abs(width - physical * guest.width) < 0.01 * width, "\(what): Physical is \(width) pt wide")
                    if bezel != .model {
                        check(abs(lcdWidth() - width) < 1, "\(what): LCD \(lcdWidth()) for \(width)")
                    }
                    physicalWidths.append(width)
                } else {
                    // A display with no size data shows Fit and keeps Physical Size.
                    check(d.zoom == .physical && abs(d.zoomPoints - d.zoomContext.fit) < 0.001, "\(what): no size")
                }

                d.zoom = .pixelAccurate
                try await settle()
                check(abs(d.zoomPoints * backing - 1) < 0.001, "\(what): Pixel Accurate at \(d.zoomPoints) pt")
                if bezel != .model {
                    check(abs(lcdWidth() * backing - guest.width) < 0.5, "\(what): LCD \(lcdWidth()) pt")
                }
                check(lcd.magnificationFilter == .nearest, "\(what): Pixel Accurate isn't crisp")
                let model = d.subviews.compactMap { $0 as? DeviceModelView }.first
                if let model { check(model.drawsNearest, "\(what): the model smooths Pixel Accurate") }

                // Half a display pixel off a whole one: smoothed, the model too.
                d.zoom = .points((CGFloat(2) + 0.5) / backing)
                try await settle()
                check(lcd.magnificationFilter == .linear, "\(what): 2.5 px per guest pixel is crisp")
                if let model { check(!model.drawsNearest, "\(what): the model is crisp at 2.5 px") }
            }
            if physicalWidths.count > 1 {
                check(
                    physicalWidths.allSatisfy { abs($0 - physicalWidths[0]) < 0.5 },
                    "Physical differs by bezel: \(physicalWidths)"
                )
            }
        }

        /// The saved zoom is per board and a new view (a new window's) starts at it.
        @Test func eachBoardsZoomComesBackInANewView() {
            for board in Board.allCases { UserDefaults.standard.removeObject(forKey: ZoomMode.defaultsKey(for: board)) }
            defer {
                for board in Board.allCases {
                    UserDefaults.standard.removeObject(forKey: ZoomMode.defaultsKey(for: board))
                }
            }
            ZoomMode.points(3).save(for: .n72)
            ZoomMode.physical.save(for: .k48)
            let frame = NSRect(x: 0, y: 0, width: 400, height: 400)
            #expect(DisplayView(frame: frame, profile: .n72).zoom == .points(3))
            #expect(DisplayView(frame: frame, profile: .k48).zoom == .physical)
            #expect(DisplayView(frame: frame, profile: .n90).zoom == .fit)
        }

        /// Two devices of one board: a zoom picked on one is the other's too when its view comes back to the window
        /// (selected again), where each view kept the zoom it had when it was made.
        @Test func aBoardsZoomFollowsItsOtherDeviceOnReturn() {
            UserDefaults.standard.removeObject(forKey: ZoomMode.defaultsKey(for: .n72))
            defer { UserDefaults.standard.removeObject(forKey: ZoomMode.defaultsKey(for: .n72)) }
            let frame = NSRect(x: 0, y: 0, width: 400, height: 400)
            let first = DisplayView(frame: frame, profile: .n72)
            let second = DisplayView(frame: frame, profile: .n72)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = second
            // What the window's zoom control does (MainWindowController.apply).
            second.zoom = .pixelAccurate
            ZoomMode.pixelAccurate.save(for: .n72)
            window.contentView = first
            #expect(first.zoom == .pixelAccurate)
            window.contentView = nil
        }
    }
}
