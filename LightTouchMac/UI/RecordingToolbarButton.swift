import Cocoa

/// One recording button: record, elapsed time and stop, then progress.
final class RecordingToolbarButton: NSButton {
    enum Phase { case idle, recording, saving }
    private let progress = NSProgressIndicator()
    /// What the button last showed: an update that changes none of it touches nothing (it ran on every
    /// toolbar validation, re-making the image and re-laying the toolbar out).
    private var shown: (phase: Phase, elapsed: String, enabled: Bool)?

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        bezelStyle = .texturedRounded
        imagePosition = .imageLeading
        font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        update(.idle, elapsed: "0:00", enabled: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ phase: Phase, elapsed: String, enabled: Bool) {
        let elapsed = phase == .recording ? elapsed : ""
        if let shown, shown.phase == phase, shown.elapsed == elapsed, shown.enabled == enabled { return }
        shown = (phase, elapsed, enabled)
        let label: String
        let symbol: String
        switch phase {
        case .idle:
            label = "Start Recording"
            symbol = "record.circle"
        case .recording:
            label = "Stop Recording"
            symbol = "stop.circle.fill"
        case .saving:
            label = "Saving Recording…"
            symbol = "record.circle"
        }
        title = phase == .recording ? elapsed : ""
        image =
            phase == .saving
            ? NSImage(size: NSSize(width: 18, height: 18))
            : NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        contentTintColor = nil
        setAccessibilityLabel(label)
        setAccessibilityValue(phase == .recording ? elapsed : nil)
        toolTip = phase == .saving ? label : "\(label) (⌘R)"
        isEnabled = enabled
        if phase == .saving { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        invalidateIntrinsicContentSize()
        sizeToFit()
    }
}

extension NSToolbarItem {
    /// Label, tooltip and SF Symbol, each assigned only when it changes: every assignment makes AppKit
    /// redo the item, and these run on every toolbar validation. The symbol name is kept beside the image.
    func show(label: String? = nil, toolTip: String? = nil, symbol: String? = nil, symbolDescription: String? = nil) {
        if let label, self.label != label { self.label = label }
        if let toolTip, self.toolTip != toolTip { self.toolTip = toolTip }
        if let symbol, objc_getAssociatedObject(self, &shownSymbolKey) as? String != symbol {
            objc_setAssociatedObject(self, &shownSymbolKey, symbol, .OBJC_ASSOCIATION_COPY_NONATOMIC)
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbolDescription ?? self.label)
        }
    }
}
nonisolated(unsafe) private var shownSymbolKey: UInt8 = 0
