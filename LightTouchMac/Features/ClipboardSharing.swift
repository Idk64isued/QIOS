import Cocoa
import LightTouchCore

/// Settings ▸ General ▸ Share clipboard with devices (on unless turned off): ClipboardSync between the Mac's
/// pasteboard and every running device with one (iOS 3.0 and later), only while the user is at the device. A device
/// is handed the Mac's text when its window comes to the front (checked twice a second, and at once when Light Touch
/// becomes active), as soon as it takes input; its copies arrive as the helper reports them
/// (LinkEvent.guestPasteboard) and reach the Mac's pasteboard only with its window key and a touch or key on it just
/// before.
@MainActor final class ClipboardSharing {
    static let shared = ClipboardSharing()
    /// The running devices (AppDelegate's sessions).
    var emulators: () -> [EmulatorController] = { [] }
    private var sync = ClipboardSync()
    /// What each boot (its DeviceProcess) was last handed or reported.
    private var delivered: [ObjectIdentifier: String] = [:]
    private var timer: Timer?
    /// The user's last touch or key on each device (DisplayView).
    private var interactions: [ObjectIdentifier: Date] = [:]
    private var loggedRefusal = false

    static var enabled: Bool { ClipboardSync.enabled }

    func start() {
        guard timer == nil else { return }
        // Coming to the front and leaving it are checked at once, so a quick trip away still hands the Mac's text.
        for name in [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification
        ] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ClipboardSharing.shared.tick() }
            }
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardSharing.shared.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard Self.enabled else { return }
        let boots = emulators().compactMap { emulator in
            emulator.sharesClipboard ? emulator.process.map { (emulator, ObjectIdentifier($0)) } : nil
        }
        delivered = delivered.filter { entry in boots.contains { $0.1 == entry.key } }
        sync.keep(devices: Set(boots.map(\.1)))
        interactions = interactions.filter { entry in boots.contains { ObjectIdentifier($0.0) == entry.key } }
        for (emulator, boot) in boots
        where sync.handsMacText(to: boot, focused: isFocused(emulator), acceptsInput: emulator.acceptsInput) {
            let board = NSPasteboard.general
            _ = sync.macChanged(changeCount: board.changeCount) { board.string(forType: .string) }
            guard let text = sync.pending(delivered: delivered[boot]) else { continue }
            emulator.pasteToGuest(text)
            delivered[boot] = text
        }
    }

    /// Light Touch is frontmost with `emulator`'s device in the key window.
    private func isFocused(_ emulator: EmulatorController) -> Bool {
        NSApp.isActive
            && (NSApp.keyWindow?.windowController as? MainWindowController)?.attachedSession?.emulator === emulator
    }

    /// A touch or key from the user on `emulator`'s screen.
    func userInteracted(with emulator: EmulatorController) { interactions[ObjectIdentifier(emulator)] = .now }

    /// A copy on `emulator`'s device: onto the Mac's pasteboard when the user was at it, and the other devices' when
    /// their windows come to the front.
    func guestCopied(_ text: String, on emulator: EmulatorController) {
        guard Self.enabled, emulator.sharesClipboard, let process = emulator.process else { return }
        delivered[ObjectIdentifier(process)] = text
        let copy = sync.guestCopied(
            text,
            focused: isFocused(emulator),
            lastInteraction: interactions[ObjectIdentifier(emulator)]
        )
        guard case .take(let text) = copy else {
            if copy == .refused, !loggedRefusal {
                loggedRefusal = true
                logEvent(
                    "Clipboard: a device's copy was left off the Mac's pasteboard (no touch or key on it just before)"
                )
            }
            return
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        sync.wroteMac(changeCount: board.changeCount)
    }
}

extension EmulatorController {
    /// The device's iOS has a pasteboard to share (3.0 and later).
    var sharesClipboard: Bool { ClipboardSync.supported(iosVersion: iosVersion) }
    /// A touch or key from the user on the device's screen (DisplayView): what lets its next copy reach the Mac.
    func userInteracted() { ClipboardSharing.shared.userInteracted(with: self) }
}
