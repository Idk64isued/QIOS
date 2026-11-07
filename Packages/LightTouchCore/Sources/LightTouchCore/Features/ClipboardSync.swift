// Settings ▸ General ▸ Share clipboard with devices: what the Mac's clipboard and the devices' pasteboards trade, so
// a copy on either side is there to paste on the other. Text only, as the guest agent carries it (it_agent's
// QC_PB_* ops); iPhone OS 3.0 brought the pasteboard, so 1.x and 2.x have none to share.
//
// Trust: a device runs whatever its Safari or apps load, so neither side's text crosses on its own. A device's copy
// reaches the Mac's pasteboard only while the user is at that device (Light Touch frontmost, the device's window key,
// a touch or key on it in the last few seconds), at most once a second; the Mac's text reaches a device only when its
// window comes to the front (or by Paste to Device), never while it is in the background.
//
// Echoes: the agent never reports text the app gave it, nor what the guest held when it started; this side never
// sends back a copy it took from a device (`shared`), nor takes its own write to the Mac's pasteboard for a copy.

import Foundation

public struct ClipboardSync: Sendable, Equatable {
    /// UTF-8 bytes either way: the guest agent's buffer, less its NUL. Longer text isn't shared at all (cut short,
    /// it would paste something nobody copied).
    public static let maxBytes = 65_535
    public static let key = "ShareClipboard"
    /// On unless turned off.
    public static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// The text both sides last held: what every device should have, and what's no news from any of them.
    public private(set) var shared: String?
    /// The Mac pasteboard's changeCount as last seen (read or written here).
    private var macChangeCount: Int?
    /// When a device's copy was last put on the Mac's pasteboard.
    private var lastTaken: Date?
    /// The devices whose window is in front, and those of them not handed the Mac's text since it came there.
    private var focused: Set<ObjectIdentifier> = []
    private var owed: Set<ObjectIdentifier> = []

    /// How long after the user's last touch or key on a device a copy there is taken for theirs.
    public static let interactionWindow: TimeInterval = 5
    /// The least time between two device copies put on the Mac's pasteboard.
    public static let minimumInterval: TimeInterval = 1

    public init() {}

    /// The device's iOS has a pasteboard (3.0 and later).
    public static func supported(iosVersion: String) -> Bool {
        iosVersion.compare("3.0", options: .numeric) != .orderedAscending
    }

    public static func fits(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= maxBytes }

    /// The Mac's pasteboard as polled. `text` is read only when the count moved: the new text for the devices, or nil
    /// (no change, this side's own write, no text, too long, or the same text again).
    public mutating func macChanged(changeCount: Int, text: () -> String?) -> String? {
        guard changeCount != macChangeCount else { return nil }
        macChangeCount = changeCount
        guard let text = text(), Self.fits(text), text != shared else { return nil }
        shared = text
        return text
    }

    public enum GuestCopy: Equatable {
        /// Put this on the Mac's pasteboard; every other device should get it too.
        case take(String)
        /// An echo of `shared`, empty or too long.
        case ignored
        /// Not plausibly the user's: the device wasn't in front with them at it, or it copies again too soon.
        case refused
    }

    /// A device's copy. `focused`: Light Touch is frontmost with this device's window key; `lastInteraction`: the
    /// user's last touch or key on it.
    public mutating func guestCopied(
        _ text: String,
        focused: Bool,
        lastInteraction: Date?,
        now: Date = .now
    ) -> GuestCopy {
        guard Self.fits(text), text != shared else { return .ignored }
        guard focused, let lastInteraction, now.timeIntervalSince(lastInteraction) <= Self.interactionWindow,
            lastTaken.map({ now.timeIntervalSince($0) >= Self.minimumInterval }) ?? true
        else { return .refused }
        lastTaken = now
        shared = text
        return .take(text)
    }

    /// The Mac's pasteboard after this side wrote it: that change is no copy.
    public mutating func wroteMac(changeCount: Int) { macChangeCount = changeCount }

    /// Whether to hand `device` the Mac's text now (read it with macChanged, then `pending`): once each time its window
    /// comes to the front (`focused` turning true), as soon as it takes input; never while it is in the background.
    public mutating func handsMacText(to device: ObjectIdentifier, focused isFocused: Bool, acceptsInput: Bool) -> Bool
    {
        guard isFocused else {
            focused.remove(device)
            owed.remove(device)
            return false
        }
        if focused.insert(device).inserted { owed.insert(device) }
        guard acceptsInput, owed.remove(device) != nil else { return false }
        return true
    }

    /// Forget devices that stopped.
    public mutating func keep(devices: Set<ObjectIdentifier>) {
        focused.formIntersection(devices)
        owed.formIntersection(devices)
    }

    /// What a device should be handed now: `shared` when it has something else (`delivered`: what it was last
    /// handed, or reported). nil when nothing's to go.
    public func pending(delivered: String?) -> String? {
        guard let shared, shared != delivered else { return nil }
        return shared
    }
}
