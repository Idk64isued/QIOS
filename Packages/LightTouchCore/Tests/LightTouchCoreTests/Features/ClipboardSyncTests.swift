import Foundation
import Testing

@testable import LightTouchCore

/// Share clipboard with devices: a copy on either side reaches the other once, with no echo back and no Mac write
/// taken for a copy; which iOS versions have a pasteboard; the size cap; and neither side's text crossing unless the
/// user is at the device.
struct ClipboardSyncTests {
    static let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    /// A copy with the user at the device: its window key, a touch a moment ago.
    static func userCopy(_ sync: inout ClipboardSync, _ text: String, at now: Date = now) -> String? {
        guard case .take(let text) = sync.guestCopied(text, focused: true, lastInteraction: now - 1, now: now)
        else { return nil }
        return text
    }

    @Test func macCopyGoesToDevicesOnceAndIsReadOnlyWhenTheCountMoves() {
        var sync = ClipboardSync()
        let text = "Ünïcødé 🍎 https://example.com/?a=1"
        var reads = 0
        func read(_ value: String) -> String {
            reads += 1
            return value
        }
        #expect(sync.macChanged(changeCount: 1) { read(text) } == text)
        #expect(sync.macChanged(changeCount: 1) { read("unread") } == nil)
        #expect(reads == 1)
        // The same text copied again on the Mac is nothing new for the devices.
        #expect(sync.macChanged(changeCount: 2) { "Ünïcødé 🍎 https://example.com/?a=1" } == nil)
        // No text (an image, a file) leaves the devices with what they have.
        #expect(sync.macChanged(changeCount: 3) { nil } == nil)
        #expect(sync.shared == "Ünïcødé 🍎 https://example.com/?a=1")
    }

    @Test func guestCopyGoesToTheMacWithoutComingBack() {
        var sync = ClipboardSync()
        _ = sync.macChanged(changeCount: 5) { "from the Mac" }
        // The device reporting the Mac's own text back is an echo.
        #expect(Self.userCopy(&sync, "from the Mac") == nil)
        #expect(Self.userCopy(&sync, "from the device") == "from the device")
        // The app's write to the Mac's pasteboard moves the count; that is no Mac copy to send back.
        sync.wroteMac(changeCount: 6)
        #expect(sync.macChanged(changeCount: 6) { "from the device" } == nil)
        // Nor is the same text read back under a later count (another app touching the pasteboard).
        #expect(sync.macChanged(changeCount: 7) { "from the device" } == nil)
        // A real Mac copy after that still goes.
        #expect(sync.macChanged(changeCount: 8) { "next" } == "next")
    }

    @Test func eachDeviceIsHandedTheSharedTextUntilItHasIt() {
        var sync = ClipboardSync()
        #expect(sync.pending(delivered: nil) == nil)
        _ = sync.macChanged(changeCount: 1) { "a" }
        // A device that started later (nothing delivered) gets it; one that has it, or copied it, doesn't.
        #expect(sync.pending(delivered: nil) == "a")
        #expect(sync.pending(delivered: "a") == nil)
        _ = Self.userCopy(&sync, "b")
        #expect(sync.pending(delivered: "a") == "b")
        #expect(sync.pending(delivered: "b") == nil)
    }

    @Test func oversizedAndEmptyTextIsNotShared() {
        var sync = ClipboardSync()
        let limit = String(repeating: "é", count: ClipboardSync.maxBytes / 2)  // 2 UTF-8 bytes each
        let over = limit + "é"
        #expect(sync.macChanged(changeCount: 1) { over } == nil)
        #expect(Self.userCopy(&sync, over) == nil)
        #expect(Self.userCopy(&sync, "") == nil)
        #expect(sync.macChanged(changeCount: 2) { limit } == limit)
    }

    @Test func onlyIOS3AndLaterHaveAPasteboard() {
        #expect(!ClipboardSync.supported(iosVersion: "1.1.5"))
        #expect(!ClipboardSync.supported(iosVersion: "2.2.1"))
        #expect(ClipboardSync.supported(iosVersion: "3.0"))
        #expect(ClipboardSync.supported(iosVersion: "3.1.3"))
        #expect(ClipboardSync.supported(iosVersion: "7.1.2"))
    }

    @Test func aDeviceCopyReachesTheMacOnlyRightAfterTheUserTouchedIt() {
        var sync = ClipboardSync()
        let now = Self.now
        func copy(_ text: String, focused: Bool, lastInteraction: Date?, now: Date) -> ClipboardSync.GuestCopy {
            sync.guestCopied(text, focused: focused, lastInteraction: lastInteraction, now: now)
        }
        // In the background, or in front with no touch or key on it lately: a page copying on its own.
        #expect(copy("a", focused: false, lastInteraction: now - 1, now: now) == .refused)
        #expect(copy("a", focused: true, lastInteraction: nil, now: now) == .refused)
        #expect(copy("a", focused: true, lastInteraction: now - 6, now: now) == .refused)
        #expect(sync.shared == nil)
        #expect(copy("a", focused: true, lastInteraction: now - 4, now: now) == .take("a"))
        // A second copy straight after is too soon, whoever touched; a second later it goes.
        #expect(copy("b", focused: true, lastInteraction: now, now: now + 0.5) == .refused)
        #expect(copy("b", focused: true, lastInteraction: now, now: now + 1) == .take("b"))
        // A refused copy isn't what the other devices are handed either.
        #expect(copy("c", focused: false, lastInteraction: now + 2, now: now + 3) == .refused)
        #expect(sync.pending(delivered: nil) == "b")
    }

    @Test func aDeviceIsHandedTheMacTextOnlyWhenItsWindowComesToTheFront() {
        var sync = ClipboardSync()
        let boot = NSObject()
        let device = ObjectIdentifier(boot)
        func hand(focused: Bool, acceptsInput: Bool) -> Bool {
            sync.handsMacText(to: device, focused: focused, acceptsInput: acceptsInput)
        }
        // In the background: nothing, however long it runs.
        #expect(!hand(focused: false, acceptsInput: true))
        #expect(!hand(focused: false, acceptsInput: true))
        // Coming to the front before it takes input: owed until it does, then once.
        #expect(!hand(focused: true, acceptsInput: false))
        #expect(hand(focused: true, acceptsInput: true))
        // Staying in front: no more (a copy the Mac makes meanwhile waits for the next time).
        #expect(!hand(focused: true, acceptsInput: true))
        #expect(!hand(focused: true, acceptsInput: true))
        // Leaving and coming back: once more.
        #expect(!hand(focused: false, acceptsInput: true))
        #expect(hand(focused: true, acceptsInput: true))
        // Leaving before it took input clears what it was owed.
        #expect(!hand(focused: false, acceptsInput: false))
        sync.keep(devices: [])
        #expect(hand(focused: true, acceptsInput: true))
    }
}
