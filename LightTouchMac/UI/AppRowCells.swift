// The Apps inspector's row views (AppsInspectorViewController's table): a Legacy Store result with its button,
// and the row for work in flight. What each row says is LightTouchCore's (AppsInspectorRows); these only draw it.

import Cocoa
import LightTouchCore

@MainActor enum AppRowCells {
    /// The row's icon well: the image when we have one, else a quiet
    /// system-fill square as the view's own background (rounded by its mask).
    /// The color is resolved for the current appearance here; rows rebuild on
    /// every reload, so a theme switch catches up on the next one.
    static func setIcon(_ image: NSImage?, on view: NSImageView?) {
        view?.image = image
        view?.layer?.backgroundColor = NSColor.systemFill.cgColor
    }

    /// A Legacy Store result: icon, name, "developer, 66 MB" (or why it can't run here), and its button
    /// (Install or Open), whose tag is the row it was built for. Built fresh each time: a page of results is small,
    /// and every state change reloads the row, so tags never go stale.
    static func catalogCell(
        _ app: CatalogApp,
        icon: NSImage?,
        button buttonTitle: String,
        enabled: Bool,
        row: Int,
        target: AnyObject?,
        action: Selector?
    ) -> NSTableCellView {
        let cell = NSTableCellView()
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 6
        image.layer?.cornerCurve = .circular
        image.layer?.masksToBounds = true
        image.translatesAutoresizingMaskIntoConstraints = false
        setIcon(icon, on: image)

        let text = NSTextField(labelWithString: app.name)
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.cell?.wraps = false
        text.allowsExpansionToolTips = true
        text.translatesAutoresizingMaskIntoConstraints = false
        let incompatible = app.incompatibility != nil
        if incompatible {
            text.textColor = .secondaryLabelColor
            image.alphaValue = 0.5
        }

        let subtitle = NSTextField(labelWithString: app.subtitle)
        subtitle.textColor = incompatible ? .tertiaryLabelColor : .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: buttonTitle, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.tag = row
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isEnabled = enabled

        [image, text, subtitle, button].forEach(cell.addSubview)
        cell.imageView = image
        cell.textField = text
        cell.toolTip = [app.bundleID, app.version.map { "v\($0)" }]
            .compactMap { $0 }.joined(separator: " — ")
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 32),
            image.heightAnchor.constraint(equalToConstant: 32),
            button.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 60),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -6),
            text.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: 0),
            subtitle.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -6),
            subtitle.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 1)
        ])
        return cell
    }

    /// A row for work in flight — icon, title, status subtitle and a trailing
    /// circular progress indicator, determinate when a download knows its
    /// size. One style for installs, downloads, removals and catalog rows.
    /// Built fresh each time (such rows are few) so the indicator animates.
    static func progressCell(
        icon: NSImage?,
        title: String,
        subtitle subtitleText: String,
        fraction: Double? = nil,
        job: InstallJob? = nil,
        resume: @escaping () -> Void
    ) -> NSTableCellView {
        let cell = NSTableCellView()
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 6
        image.layer?.cornerCurve = .circular
        image.layer?.masksToBounds = true
        image.translatesAutoresizingMaskIntoConstraints = false
        setIcon(icon, on: image)
        image.layer?.opacity = NSApp.isActive ? 1 : 0.5
        let text = NSTextField(labelWithString: title)
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.cell?.wraps = false
        text.allowsExpansionToolTips = true
        text.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: subtitleText)
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.translatesAutoresizingMaskIntoConstraints = false
        if let fraction, fraction >= 0 {
            progress.isIndeterminate = false
            progress.minValue = 0
            progress.maxValue = 1
            progress.doubleValue = fraction
        } else {
            progress.startAnimation(nil)
        }
        let action = InlineActionButton(
            title: job?.failed == true ? "Retry" : job?.status == "Paused" ? "Resume" : "Cancel"
        ) { [weak job] in
            guard let job else { return }
            if job.failed {
                job.retry?()
            } else if AppInstaller.isPaused(job.deviceID) {
                resume()
            } else {
                job.cancel()
            }
        }
        action.isHidden = job == nil
        action.isEnabled = job?.failed == true || job?.isCancellable == true
        action.translatesAutoresizingMaskIntoConstraints = false
        progress.isHidden = job?.failed == true
        [image, text, subtitle, progress, action].forEach(cell.addSubview)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 32),
            image.heightAnchor.constraint(equalToConstant: 32),
            action.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            action.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            action.widthAnchor.constraint(equalToConstant: job == nil ? 0 : 54),
            progress.trailingAnchor.constraint(equalTo: action.leadingAnchor, constant: -4),
            progress.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: progress.leadingAnchor, constant: -6),
            text.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: 0),
            subtitle.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: progress.leadingAnchor, constant: -6),
            subtitle.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 1)
        ])
        return cell
    }
}
