import AppKit
import HostRuntime
import Testing

@testable import AppViews
@testable import LightTouchCore

/// The prepare screen (DevicePlaceholderViewController) in every state and its build-info popover, with the real
/// catalog and DeviceRow, in windows never ordered in. The name, version and state lines stack in that order; the
/// buttons share one row with the default last (Show Logs to its left); an error's state line says what failed; a
/// file system operation shows its words and a spinner and holds Start; two jobs never share one bar; an accepted
/// IPSW drag rings the screen until it leaves; no label is clipped. The popover (ⓘ) has a real size (RC1's was 0x0)
/// and shows the support status and its explanation, the source note and the release date.
extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

extension SharedState {
    @Suite struct PlaceholderTests {
        @MainActor final class Drag: NSObject, NSDraggingInfo {
            let draggingPasteboard = NSPasteboard.withUniqueName()
            var draggingSource: Any? { nil }
            var draggingDestinationWindow: NSWindow? { nil }
            var draggingSourceOperationMask: NSDragOperation { .copy }
            var draggingLocation: NSPoint { .zero }
            var draggedImageLocation: NSPoint { .zero }
            nonisolated var draggedImage: NSImage? { nil }
            var draggingSequenceNumber: Int { 1 }
            var draggingFormation = NSDraggingFormation.default
            var animatesToDestination = false
            var numberOfValidItemsForDrop = 0
            var springLoadingHighlight: NSSpringLoadingHighlight { .none }
            func slideDraggedImage(to screenPoint: NSPoint) {}
            override nonisolated func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
                nil
            }
            func resetSpringLoading() {}
            func enumerateDraggingItems(
                options: NSDraggingItemEnumerationOptions = [],
                for view: NSView?,
                classes classArray: [AnyClass],
                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
            ) {}
            func files(_ names: [String]) {
                draggingPasteboard.clearContents()
                precondition(draggingPasteboard.writeObjects(names.map { URL(fileURLWithPath: "/tmp/" + $0) as NSURL }))
            }
        }

        @Test func everyState() throws {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let catalog = try FirmwareCatalog.load(
                from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .appendingPathComponent("../../../../LightTouchMac/Resources/firmware-catalog.json")
                    .standardizedFileURL
            )
            func entry(_ id: String) -> FirmwareCatalog.Entry { catalog.entry(id: id)! }
            let id = UUID()
            let beta = entry("k48ap-9A5220p")
            let ipad = entry("k48ap-7B500")
            let ipod = entry("n72ap-7E18")
            var prep = Preparation(step: 3, steps: 7, name: "Decrypting", fraction: 0.4)
            prep.remaining = 95
            let unsupported = "Light Touch can’t prepare this beta yet: its graphics library isn’t supported."
            let states: [(String, DeviceRow)] = [
                ("not-downloaded", DeviceRow(entry: beta, instanceID: nil, session: nil, job: nil)),
                ("downloaded", DeviceRow(entry: ipad, instanceID: nil, session: nil, job: nil, downloaded: true)),
                (
                    "downloading",
                    DeviceRow(
                        entry: beta,
                        instanceID: nil,
                        session: nil,
                        job: .downloading(fraction: 0.43, remaining: 70)
                    )
                ),
                (
                    "downloading-archive",
                    DeviceRow(
                        entry: beta,
                        instanceID: nil,
                        session: nil,
                        job: .downloading(fraction: 0.43, remaining: 1900, mirror: "archive.org", speed: 850_000)
                    )
                ),
                ("preparing", DeviceRow(entry: beta, instanceID: nil, session: nil, job: .preparing(prep))),
                (
                    "almost-done",
                    DeviceRow(
                        entry: beta,
                        instanceID: nil,
                        session: nil,
                        job: .preparing(
                            {
                                var p = prep
                                p.remaining = 4
                                return p
                            }()
                        )
                    )
                ),
                (
                    "downloading-starting",
                    DeviceRow(entry: beta, instanceID: nil, session: nil, job: .downloading(fraction: 0.01))
                ),
                ("error", DeviceRow(entry: beta, instanceID: nil, session: nil, job: .failed(unsupported))),
                ("ready", DeviceRow(entry: ipad, instanceID: id, session: nil, job: nil)),
                (
                    "older-recipe",
                    DeviceRow(entry: entry("n45ap-4B1"), instanceID: id, session: nil, job: nil, baseRecipe: 1)
                ),
                (
                    "stopped",
                    DeviceRow(entry: ipad, instanceID: id, session: .dead("The iPad stopped unexpectedly."), job: nil)
                ),
                ("requires-ipsw", DeviceRow(entry: ipod, instanceID: nil, session: nil, job: nil))
            ]
            var failures: [String] = []
            var skips: Set<String> = []
            for (name, row) in states {
                let vc = DevicePlaceholderViewController()
                vc.skipsSetup = (
                    { skips.contains($0) }, { id, on in if on { skips.insert(id) } else { skips.remove(id) } }
                )
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: true
                )
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = vc.view
                vc.update(row, canDownload: true)
                vc.view.layoutSubtreeIfNeeded()
                let view = vc.view

                func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
                func visible(_ v: NSView) -> Bool {
                    var p: NSView? = v
                    while let q = p {
                        if q.isHidden { return false }
                        p = q.superview
                    }
                    return v.window != nil
                }
                func frame(_ v: NSView) -> NSRect {
                    v.convert(
                        v.alignmentRect(forFrame: v.frame).offsetBy(dx: -v.frame.minX, dy: -v.frame.minY),
                        to: view
                    )
                }
                let labels = all(view).compactMap { $0 as? NSTextField }.filter {
                    visible($0) && !$0.stringValue.isEmpty
                }
                let checkboxes = all(view).compactMap { $0 as? NSButton }.filter {
                    visible($0) && $0.title == "Skip Setup Assistant"
                }
                let buttons = all(view).compactMap { $0 as? NSButton }.filter {
                    visible($0) && $0.isBordered && !checkboxes.contains($0)
                }
                func fail(_ s: String) { failures.append("\(name): \(s)") }
                // Skip Setup Assistant: only before an iOS 5 or later build is prepared (the 5.0 beta here), off until
                // chosen, and the choice is kept for the entry.
                if (name == "not-downloaded") != (checkboxes.count == 1) {
                    fail("Skip Setup shown: \(checkboxes.count)")
                }
                if let box = checkboxes.first {
                    if box.state != .off { fail("Skip Setup on before it was chosen") }
                    box.performClick(nil)
                    if !skips.contains(row.entry.id) { fail("the Skip Setup choice wasn't kept") }
                    vc.update(row, canDownload: true)
                    if box.state != .on { fail("the kept Skip Setup choice isn't shown") }
                }
                // The art is the sidebar's thumbnail for the model, dimmed, not the shell.
                if let profile = row.entry.profile {
                    let art = all(view).compactMap { $0 as? NSImageView }.first { $0.alphaValue < 1 }
                    if art?.image?.tiffRepresentation
                        != {
                            let i = profile.icon.copy() as! NSImage
                            i.size = NSSize(width: 256, height: 256)
                            return i.tiffRepresentation
                        }()
                    {
                        fail("the art isn't the device's icon")
                    }
                }
                for l in labels {
                    let f = frame(l)
                    if !view.bounds.contains(f) { fail("\(l.stringValue) outside the view") }
                    if l.maximumNumberOfLines != 0 || l.cell?.wraps == false,
                        l.intrinsicContentSize.width > l.frame.width + 0.5
                    {
                        fail("\(l.stringValue) clipped")
                    }
                }
                // Top to bottom: name, version, state.
                let texts = labels.sorted { frame($0).midY > frame($1).midY }.map(\.stringValue)
                guard let n = texts.firstIndex(of: row.entry.profile!.marketingName),
                    let v = texts.firstIndex(where: { $0.hasPrefix("iOS ") })
                else {
                    fail("no name or version: \(texts)")
                    continue
                }
                if !(n < v && v + 1 < texts.count) { fail("order: \(texts)") }
                if texts.count < 3 { fail("no state line: \(texts)") }
                if let primary = row.primaryTitle {
                    guard let p = buttons.first(where: { $0.title == primary }) else {
                        fail("no \(primary)")
                        continue
                    }
                    for b in buttons where b !== p {
                        if abs(frame(b).midY - frame(p).midY) > 0.5 { fail("\(b.title) not on \(primary)'s row") }
                        if frame(b).maxX > frame(p).minX { fail("\(b.title) after the default button") }
                        if abs(frame(b).height - frame(p).height) > 0.5 {
                            fail("\(b.title) and \(primary) differ in size")
                        }
                    }
                    if p.keyEquivalent == "\r" && row.primaryAction == .cancel { fail("Return cancels") }
                }
                if row.isError && !buttons.contains(where: { $0.title == "Show Logs" }) {
                    fail("an error without Show Logs")
                }
                // A base from an older recipe: its line and Prepare Again beside Start (still the default); no other state shows them.
                let again = buttons.first { $0.title == "Prepare Again…" }
                if (name == "older-recipe") != (again != nil) { fail("Prepare Again shown: \(again != nil)") }
                if let note = row.olderRecipeNote, !texts.contains(note) { fail("no older-recipe line: \(texts)") }
                if row.preparedByOlderRecipe, again?.isEnabled != true || row.primaryTitle != "Start" {
                    fail("Prepare Again disabled or Start not the default")
                }
                if row.isError && !texts.contains(where: { $0.hasPrefix("Couldn’t ") || $0 == "Stopped unexpectedly" })
                {
                    fail("an error headline that doesn't say what failed: \(texts)")
                }
                if texts.contains("Error") { fail("a bare Error headline") }
                // A job's headline is its stage ("Downloading from archive.org…", "Decrypting…"), right under the version;
                // under the bar, the percent and the time left (and a slow download's speed).
                if let headline = row.progressHeadline {
                    if texts[safe: v + 1] != headline {
                        fail("headline \(texts[safe: v + 1] ?? "none"), want \(headline): \(texts)")
                    }
                    if texts[safe: v + 2] != row.progressLine || texts.count != v + 3 {
                        fail("the line under the bar: \(texts), want \(row.progressLine ?? "nil")")
                    }
                    if !(row.progressLine ?? "").contains("%") { fail("no percent: \(row.progressLine ?? "nil")") }
                    if row.progress != nil,
                        let bar = all(view).compactMap({ $0 as? NSProgressIndicator }).first(where: visible),
                        let line = texts[safe: v + 2], let label = labels.first(where: { $0.stringValue == line }),
                        !(frame(bar).minY > frame(label).maxY)
                    {
                        fail("the percent line isn't under the bar")
                    }
                }
                if name == "downloading-archive",
                    texts[safe: v + 1] != "Downloading from archive.org…"
                        || !(texts[safe: v + 2] ?? "").hasSuffix("850 KB/s")
                {
                    fail("a slow archive.org download: \(texts)")
                }
                if name == "almost-done", !(texts[safe: v + 2] ?? "").hasSuffix("Almost done…") {
                    fail("Almost done without its ellipsis: \(texts)")
                }
                if let bar = all(view).compactMap({ $0 as? NSProgressIndicator }).first(where: visible),
                    !["Download progress", "Preparation progress"].contains(bar.accessibilityLabel() ?? "")
                {
                    fail("progress bar labeled \(bar.accessibilityLabel() ?? "nothing")")
                }
            }

            // A file system operation in flight: its words with a spinner in the state line, and Start held.
            do {
                let vc = DevicePlaceholderViewController()
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: true
                )
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = vc.view
                func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
                func visible(_ v: NSView) -> Bool {
                    var p: NSView? = v
                    while let q = p {
                        if q.isHidden { return false }
                        p = q.superview
                    }
                    return true
                }
                let ready = DeviceRow(entry: ipad, instanceID: id, session: nil, job: nil)
                vc.update(ready, canDownload: true, activity: "Reading the file system…")
                vc.view.layoutSubtreeIfNeeded()
                let texts = all(vc.view).compactMap { $0 as? NSTextField }.filter { visible($0) }.map(\.stringValue)
                let spinner = all(vc.view).compactMap { $0 as? NSProgressIndicator }.first {
                    $0.style == .spinning && visible($0)
                }
                let start = all(vc.view).compactMap { $0 as? NSButton }.first { $0.title == "Start" }
                if !texts.contains("Reading the file system…") || texts.contains("Ready") || spinner == nil
                    || start?.isEnabled != false
                {
                    failures.append(
                        "activity: \(texts), spinner \(spinner != nil), Start enabled \(start?.isEnabled ?? false)"
                    )
                }
                vc.update(ready, canDownload: true)
                if all(vc.view).contains(where: { ($0 as? NSProgressIndicator)?.style == .spinning && visible($0) })
                    || start?.isEnabled != true
                {
                    failures.append("the spinner stays or Start stays held after the operation")
                }
            }

            // Two jobs, one placeholder: each has its own bar, so switching rows never animates one bar between their values.
            do {
                let vc = DevicePlaceholderViewController()
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: true
                )
                window.contentView = vc.view
                func shownBar() -> NSProgressIndicator? {
                    func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
                    return all(vc.view).compactMap { $0 as? NSProgressIndicator }.first { bar in
                        var p: NSView? = bar
                        while let q = p {
                            if q.isHidden { return false }
                            p = q.superview
                        }
                        return bar.window != nil
                    }
                }
                let a = DeviceRow(
                    entry: beta,
                    instanceID: nil,
                    session: nil,
                    job: .preparing(.init(step: 9, steps: 10, name: "x", fraction: 1))
                )
                let b = DeviceRow(entry: ipad, instanceID: nil, session: nil, job: .downloading(fraction: 0.4))
                vc.update(a, canDownload: true)
                let barA = shownBar()
                vc.update(b, canDownload: true)
                let barB = shownBar()
                if barA == nil || barB == nil || barA === barB || barB?.doubleValue != 0.2 {
                    failures.append(
                        "switching jobs reused one bar: \(String(describing: barA)) \(String(describing: barB))"
                    )
                }
                vc.update(a, canDownload: true)
                if shownBar() !== barA || barA?.doubleValue != 0.9 {
                    failures.append("switching back didn't show the first job's own bar at 90%")
                }
            }

            // An .ipsw dragged over the placeholder lights the drop ring; anything else doesn't (HIG p.294).
            do {
                let vc = DevicePlaceholderViewController()
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: true
                )
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = vc.view
                vc.update(states[1].1, canDownload: true)
                let drop: NSDraggingDestination = vc.view
                let drag = Drag()
                defer { drag.draggingPasteboard.releaseGlobally() }
                func ring() -> NSView? { vc.view.subviews.first { $0 is DropHighlight } }
                drag.files(["Notes.txt"])
                if drop.draggingEntered?(drag) != [] || ring()?.isHidden == false {
                    failures.append("drop: a non-IPSW drag was accepted or lit")
                }
                drag.files(["iPad1,1_3.2.2_7B500_Restore.ipsw"])
                if drop.draggingEntered?(drag) != .copy || ring()?.isHidden != false {
                    failures.append("drop: an IPSW drag isn't highlighted")
                }
                vc.view.layoutSubtreeIfNeeded()
                drop.draggingExited?(drag)
                if ring()?.isHidden != true { failures.append("drop: the ring stays after the drag leaves") }
            }

            // The art sits on the window itself in dark mode, for every board: no lighter square behind it (issue 44;
            // macOS's iPhone 4 icon has a 12% white plate in its 256-1024 px images).
            for board in Board.allCases {
                guard let e = catalog.entries.first(where: { $0.profile == board }) else { continue }
                let vc = DevicePlaceholderViewController()
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: true
                )
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = vc.view
                vc.update(DeviceRow(entry: e, instanceID: nil, session: nil, job: nil), canDownload: true)
                vc.view.layoutSubtreeIfNeeded()
                func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
                guard let art = all(vc.view).compactMap({ $0 as? NSImageView }).first(where: { $0.alphaValue < 1 }),
                    let image = art.image, let bitmap = vc.view.bitmapImageRepForCachingDisplay(in: vc.view.bounds)
                else {
                    failures.append("\(board): no art")
                    continue
                }
                vc.view.cacheDisplay(in: vc.view.bounds, to: bitmap)
                // The image's square, centered in the art view and scaled down to fit.
                let scale = min(1, art.bounds.width / image.size.width, art.bounds.height / image.size.height)
                let side = image.size.width * scale
                let square = vc.view.convert(
                    NSRect(x: art.bounds.midX - side / 2, y: art.bounds.midY - side / 2, width: side, height: side),
                    from: art
                )
                func pixel(_ p: NSPoint) -> [Int] {
                    let x = Int(p.x * CGFloat(bitmap.pixelsWide) / vc.view.bounds.width)
                    let y = Int((vc.view.bounds.height - p.y) * CGFloat(bitmap.pixelsHigh) / vc.view.bounds.height)
                    var raw = [Int](repeating: 0, count: 4)
                    bitmap.getPixel(&raw, atX: x, y: y)
                    return raw
                }
                let outside = pixel(NSPoint(x: square.minX - 8, y: square.midY))
                for corner in [
                    NSPoint(x: square.minX + 6, y: square.minY + 6), NSPoint(x: square.maxX - 6, y: square.minY + 6),
                    NSPoint(x: square.minX + 6, y: square.maxY - 6), NSPoint(x: square.maxX - 6, y: square.maxY - 6)
                ] where zip(pixel(corner), outside).contains(where: { abs($0 - $1) > 1 }) {
                    failures.append("\(board): the art's square \(pixel(corner)) on the background \(outside)")
                    break
                }
            }

            // The ⓘ popover: a real size and the build's words, for experimental, untested and beta builds.
            for e in [entry("k48ap-7B405"), entry("n45ap-3B48b"), beta, entry("n72ap-8C5091e"), entry("n72ap-7E18")] {
                let row = DeviceRow(entry: e, instanceID: nil, session: nil, job: nil)
                guard let content = DevicePlaceholderViewController.infoContent(for: row) else {
                    failures.append("\(e.id): no popover")
                    continue
                }
                let size = content.preferredContentSize
                content.view.layoutSubtreeIfNeeded()
                let words = content.view.subviews.compactMap { $0 as? NSTextField }.filter {
                    !$0.stringValue.isEmpty && $0.frame.width > 20 && $0.frame.height > 8
                }
                let text = words.map(\.stringValue).joined(separator: "\n")
                if size.width < 100 || size.height < 40 || content.view.frame.size != size {
                    failures.append("\(e.id): popover size \(size), view \(content.view.frame.size)")
                }
                if let tag = row.supportNote,
                    !words.contains(where: { $0.stringValue == tag }) || !text.contains(row.supportExplanation ?? "?")
                {
                    failures.append("\(e.id): no \(tag) and its explanation: \(text)")
                }
                if !text.contains("Released ") { failures.append("\(e.id): no release date: \(text)") }
                if let note = e.statusNote, !text.contains(note) { failures.append("\(e.id): no source note: \(text)") }
                for w in words where !content.view.bounds.contains(w.frame) {
                    failures.append("\(e.id): \(w.stringValue) outside the popover")
                }
            }
            #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        }
    }
}
