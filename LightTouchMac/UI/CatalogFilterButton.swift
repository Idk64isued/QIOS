import Cocoa
import LightTouchCore

/// The standard filter pull-down beside Installed/Store, over CatalogFilter.
/// The family choice applies only on an iPad: an iPhone or iPod touch can't run iPad-only apps, so its menu
/// shows the choice dimmed and unchecked. Each choice is saved as it's made, and every device's button follows
/// the saved choices, so a choice made on another device never leaves this menu stale.
/// A filter narrower than the default shows filled and in the accent color, as Finder and Mail show theirs.
final class CatalogFilterButton: NSPopUpButton {
    private(set) var filter: CatalogFilter
    let isIPad: Bool
    private let defaults: UserDefaults
    var onChange: () -> Void = {}
    private var familyItems: [NSMenuItem] = []
    private let unavailableItem = NSMenuItem(
        title: "Show Unavailable Apps",
        action: #selector(unavailableToggled(_:)),
        keyEquivalent: ""
    )

    init(isIPad: Bool, defaults: UserDefaults = .standard) {
        self.isIPad = isIPad
        self.defaults = defaults
        filter = CatalogFilter.load(defaults)
        super.init(frame: .zero, pullsDown: true)
        isBordered = false
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityLabel("Filter")
        toolTip = "Filter"
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        let menu = NSMenu()
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "")  // a pull-down's first item is its face
        for (title, tag) in [("iPhone and iPad Apps", 0), ("iPad Apps Only", 1)] {
            let item = menu.addItem(withTitle: title, action: #selector(familyChosen(_:)), keyEquivalent: "")
            item.tag = tag
            item.isEnabled = isIPad
            familyItems.append(item)
        }
        menu.addItem(.separator())
        menu.addItem(unavailableItem)
        for item in menu.items { item.target = self }
        menu.autoenablesItems = false
        self.menu = menu
        update()
        NotificationCenter.default.addObserver(self, selector: #selector(saved), name: Self.saved, object: defaults)
    }
    /// Posted once both choices are saved (UserDefaults' own notification comes between the two).
    private static let saved = Notification.Name("LTMCatalogFilterSaved")
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ apps: [CatalogApp]) -> [CatalogApp] { filter.apply(apps, iPad: isIPad) }

    /// A button (another device's, or this one) saved a choice.
    @objc private func saved() {
        let saved = CatalogFilter.load(defaults)
        guard saved != filter else { return }
        filter = saved
        update()
        onChange()
    }

    private func update() {
        let isActive = filter.isActive(iPad: isIPad)
        let symbol = isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
        contentTintColor = isActive ? .controlAccentColor : nil
        itemArray[0].image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Filter")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        // Off an iPad neither is checked: a disabled item never shows a choice saved on an iPad.
        for item in familyItems { item.state = isIPad && (item.tag == 1) == filter.iPadOnly ? .on : .off }
        unavailableItem.state = filter.showUnavailable ? .on : .off
    }

    @objc private func familyChosen(_ sender: NSMenuItem) {
        filter.iPadOnly = sender.tag == 1
        changed()
    }

    @objc private func unavailableToggled(_ sender: NSMenuItem) {
        filter.showUnavailable.toggle()
        changed()
    }

    private func changed() {
        filter.save(defaults)
        update()
        onChange()
        NotificationCenter.default.post(name: Self.saved, object: defaults)
    }
}
