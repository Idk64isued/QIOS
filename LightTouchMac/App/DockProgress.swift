import Cocoa
import LightTouchCore

/// Downloads and preparations on the Dock icon: one bar under the icon while any runs (FirmwareJob.dockProgress),
/// and no idle sleep meanwhile.
@MainActor final class DockProgress {
    private var bar: NSProgressIndicator?
    private var activity = UserActivity("Downloading and preparing firmware")
    private var observer: NSObjectProtocol?

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: FirmwareJobs.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    private func update() {
        let tile = NSApp.dockTile
        let fraction = FirmwareJob.dockProgress(FirmwareJobs.shared.jobs.values)
        activity.held = fraction != nil
        guard let fraction else {
            if bar != nil {
                bar = nil
                tile.contentView = nil
                tile.display()
            }
            return
        }
        if bar == nil {
            let view = NSImageView(image: NSApp.applicationIconImage)
            view.frame = NSRect(origin: .zero, size: tile.size)
            let progress = NSProgressIndicator(
                frame: NSRect(
                    x: tile.size.width * 0.1,
                    y: tile.size.height * 0.08,
                    width: tile.size.width * 0.8,
                    height: 18
                )
            )
            progress.style = .bar
            progress.isIndeterminate = false
            progress.minValue = 0
            progress.maxValue = 1
            view.addSubview(progress)
            tile.contentView = view
            bar = progress
        }
        guard abs((bar?.doubleValue ?? 0) - fraction) >= 0.005 else { return }
        bar?.doubleValue = fraction
        tile.display()
    }
}
