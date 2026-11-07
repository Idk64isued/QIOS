import Cocoa
import DeviceRuntime
import HostRuntime
import LightTouchCore

extension DisplayView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHighlight.show(for: dropOperation(sender))
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHighlight.show(for: dropOperation(sender))
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight.show(for: []) }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlight.show(for: []) }

    private func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Refuse at the drag system, not with an alert per file. During the boot
        // the menu and toolbar items for this same operation are correctly
        // grayed out, but the drop still showed the green copy badge, accepted,
        // and then queued one "The device isn't ready yet" sheet per .ipa to be
        // dismissed one at a time.
        // An IPSW is for the library, not this device: any time, from outside.
        if sender.draggingSource == nil, onDropIPSW != nil, !dropped(sender, .ipsw).isEmpty {
            sender.numberOfValidItemsForDrop = dropped(sender, .ipsw).count
            return .copy
        }
        guard emulator?.canQueueInstall == true else { return [] }
        let catalog = droppedCatalogApps(sender)
        if !catalog.isEmpty, onDropCatalogApp != nil {
            sender.numberOfValidItemsForDrop = catalog.count
            return .copy
        }
        // Local drags carry .fileURL too (an installed row is draggable to
        // the Finder as its .ipa), but dropping one back on the device would
        // just reinstall what's already there — only OUTSIDE files install.
        guard sender.draggingSource == nil else { return [] }
        let count =
            (onDropIPA == nil ? 0 : dropped(sender, .ipa).count)
            + (onDropMedia == nil ? 0 : dropped(sender, .media).count)
        guard count > 0 else { return [] }
        sender.numberOfValidItemsForDrop = count
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Readiness can change after the drag entered. Never animate a
        // successful drop when its owner will reject the import.
        guard dropOperation(sender) == .copy else { return false }
        let ipsws = dropped(sender, .ipsw)
        if sender.draggingSource == nil, let onDropIPSW, !ipsws.isEmpty {
            onDropIPSW(ipsws)
            return true
        }
        let catalog = droppedCatalogApps(sender)
        if !catalog.isEmpty, let onDropCatalogApp {
            catalog.forEach(onDropCatalogApp)
            return true
        }
        guard sender.draggingSource == nil else { return false }
        let ipas = dropped(sender, .ipa)
        let media = dropped(sender, .media)
        guard !ipas.isEmpty || !media.isEmpty else { return false }
        for ipa in ipas { onDropIPA?(ipa) }  // AppInstaller queues them
        for file in media { onDropMedia?(file) }
        return true
    }

    private func dropped(_ sender: NSDraggingInfo, _ kind: DroppedFiles) -> [URL] {
        DroppedFiles.files(sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [], kind)
    }

    /// Store rows dragged from the inspector: decode the private payload.
    private func droppedCatalogApps(_ sender: NSDraggingInfo) -> [CatalogApp] {
        (sender.draggingPasteboard.pasteboardItems ?? []).compactMap { item in
            item.data(forType: .ltmCatalogApp)
                .flatMap { try? JSONDecoder().decode(CatalogApp.self, from: $0) }
        }
    }
}
