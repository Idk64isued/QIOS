// A device's settings file as the session holds it, and the notice the window shows for it (kept there, so a
// notice survives a relaunch until it is resolved or dismissed).

import DeviceRuntime
import Foundation
import HostRuntime
import Observation

/// This device's settings.plist (DeviceSettings), read once and written on every change. Every file opened on one
/// device directory shares one copy while any is open (a session's, a stopped device's menu, an erase's), so none
/// writes back a value another changed. Observable: whatever reads a setting through it (the keyboard, the notice,
/// the menus' toggles) updates with it.
public final class DeviceSettingsFile {
    public let directory: URL
    private let store: Store
    public init(directory: URL) {
        self.directory = directory
        store = Store.open(directory)
    }
    public var value: DeviceSettings { store.value }
    public func change(_ change: (inout DeviceSettings) -> Void) { store.change(change) }

    @Observable final class Store {
        let directory: URL
        init(directory: URL) { self.directory = directory }
        @ObservationIgnored private lazy var stored = DeviceSettings.load(directory)
        var value: DeviceSettings {
            access(keyPath: \.value)
            return stored
        }

        func change(_ change: (inout DeviceSettings) -> Void) {
            var value = stored
            change(&value)
            if value != stored { withMutation(keyPath: \.value) { stored = value } }
            do { try value.save(directory) } catch {
                logEvent("settings: could not save: \(error.localizedDescription)")
            }
        }

        private struct Weak { weak var store: Store? }
        private static var stores: [String: Weak] = [:]
        static func open(_ directory: URL) -> Store {
            let key = directory.standardizedFileURL.path
            if let store = stores[key]?.store { return store }
            stores = stores.filter { $0.value.store != nil }
            let store = Store(directory: directory)
            stores[key] = Weak(store: store)
            return store
        }
    }
}

/// The device's notices, one per operation, each until its operation succeeds, it is dismissed or (a boot's own)
/// a fresh helper starts. The window shows one at a time: the first in Operation's order.
public final class DeviceNotices {
    /// In the order the window shows them. Erase and activation are the device's: their remedy is Erase All
    /// Content and Settings, so they stay until an erase (or the guest's activation) clears them. The rest are a
    /// boot's and end with it (`helperStarted`).
    public enum Operation: String, CaseIterable {
        case storage, erase, activation, powerOff, files, preparation, lowSpace, storageUpdate
    }

    private let settings: DeviceSettingsFile
    private let shortName: String
    /// The helper reports its storage failing: every notice then says so, and none can be dismissed.
    private let storageFailed: () -> Bool
    public init(settings: DeviceSettingsFile, shortName: String, storageFailed: @escaping () -> Bool) {
        self.settings = settings
        self.shortName = shortName
        self.storageFailed = storageFailed
    }

    /// Kept in the settings file (an earlier build's single notice included), so they are observable through it.
    private var notices: [DeviceSettings.Notice] {
        settings.value.deviceNotices ?? settings.value.deviceNotice.map { [$0] } ?? []
    }
    private var shown: DeviceSettings.Notice? {
        let notices = notices
        return Operation.allCases.lazy.compactMap { op in notices.first { $0.operation == op.rawValue } }.first
            ?? notices.first
    }
    public var message: String? { shown?.message }

    private func update(_ change: (inout [DeviceSettings.Notice]) -> Void) {
        var notices = notices
        change(&notices)
        settings.change {
            $0.deviceNotice = nil
            $0.deviceNotices = notices.isEmpty ? nil : notices
        }
    }

    public func report(_ message: String, for operation: Operation) {
        let failed = storageFailed()
        let value =
            failed
            ? "Couldn’t save to disk, so the \(shortName) stopped and recent changes were lost. Free up space, then reopen Light Touch."
            : message
        logEvent(value)
        let kind = (failed ? .storage : operation).rawValue
        update { notices in
            notices.removeAll { $0.operation == kind }
            notices.append(.init(message: value, operation: kind))
        }
    }

    /// The shown notice's remedy is Erase All Content and Settings (a refused overlay, an unfinished or failed
    /// erase, an unactivated guest).
    public var offersErase: Bool {
        [Operation.erase.rawValue, Operation.activation.rawValue].contains(shown?.operation) && !storageFailed()
    }

    /// Dismisses the shown notice; the next one, if any, shows.
    public func dismiss() {
        guard !storageFailed(), let shown else { return }
        update { $0.removeAll { $0 == shown } }
    }

    public func resolve(_ operation: Operation) {
        guard !storageFailed(), notices.contains(where: { $0.operation == operation.rawValue }) else { return }
        update { $0.removeAll { $0.operation == operation.rawValue } }
    }

    /// A fresh helper starts: the last boot's notices (its storage, its stop, its files, its startup, its free
    /// space) no longer hold; the device's own stay.
    public func helperStarted() {
        let device: Set = [Operation.erase.rawValue, Operation.activation.rawValue]
        guard notices.contains(where: { !device.contains($0.operation ?? "") }) else { return }
        update { $0.removeAll { !device.contains($0.operation ?? "") } }
    }
}
