import Foundation
import HostRuntime

/// The emulator's machines (`LightTouchDevice '{"mode":{"machines":{}}}'`), recorded in tests/fixtures/machines.json for tests that
/// build argv without the emulator library; tests/release/test-package.py holds the record to the bundled library.
enum MachineFixtures {
    static let all: [DeviceInfo] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../tests/fixtures/machines.json").standardized
        return try! JSONDecoder().decode([DeviceInfo].self, from: Data(contentsOf: url))
    }()
    /// Make them the process's machines (idempotent).
    static func install() { Machines.set(all) }
}
