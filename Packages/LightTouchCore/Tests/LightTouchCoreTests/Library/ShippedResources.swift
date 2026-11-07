import Foundation
import HostRuntime

@testable import LightTouchCore

/// The repository's shipped catalog and the machines fixture, for tests that read them.
enum ShippedResources {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let catalogURL = root.appendingPathComponent("LightTouchMac/Resources/firmware-catalog.json")
    static var catalog: FirmwareCatalog { try! FirmwareCatalog.load(from: catalogURL) }

    /// tests/fixtures/machines.json (`LightTouchDevice '{"mode":{"machines":{}}}'`) as the process's machines, for board lookups
    /// that need the emulator's facts. Evaluate before the first lookup.
    static let machines: Void = {
        let url = root.appendingPathComponent("tests/fixtures/machines.json")
        Machines.set(try! JSONDecoder().decode([DeviceInfo].self, from: Data(contentsOf: url)))
    }()
}
