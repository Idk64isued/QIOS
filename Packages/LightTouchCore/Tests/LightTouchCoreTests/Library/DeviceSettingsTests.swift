import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// Per-device settings: what earlier builds kept in user defaults ("<name>.<uuid>", and the app-wide keyboard and
/// auto-rotate keys before those) moves once into each device's settings.plist, and every such key goes.
struct DeviceSettingsTests {
    @Test func defaultsMoveIntoEachDevicesSettingsAndTheKeysGo() throws {
        try withTemporaryDirectory { state in
            let suite = "ltm-device-settings-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let a = UUID()
            let b = UUID()
            let gone = UUID()
            for id in [a, b] {
                try FileManager.default.createDirectory(
                    at: DeviceInstance.directory(id, state: state),
                    withIntermediateDirectories: true
                )
            }
            var carrier = CarrierSettings()
            carrier.carrier = "Test Net"
            carrier.bars = 2
            defaults.set(["message": "Couldn't erase", "operation": "erase"], forKey: "deviceNotice.\(a.uuidString)")
            defaults.set(1, forKey: "motionPose.\(a.uuidString)")
            defaults.set(false, forKey: "keyboardInputEnabled.\(a.uuidString)")
            defaults.set(true, forKey: "debugPort.\(a.uuidString)")
            defaults.set(try JSONEncoder().encode(carrier), forKey: "carrier.\(a.uuidString)")
            defaults.set(1, forKey: "motionPose.\(gone.uuidString)")
            defaults.set(true, forKey: "keyboardInputEnabled")
            defaults.set(false, forKey: "autoRotateWithGuest")
            defaults.set("kept", forKey: "captureFolder")

            DeviceSettings.migrateDefaults(defaults, state: state, devices: [a, b])

            #expect(
                DeviceSettings.load(DeviceInstance.directory(a, state: state))
                    == DeviceSettings(
                        deviceNotice: .init(message: "Couldn't erase", operation: "erase"),
                        motionPose: 1,
                        keyboardInputEnabled: false,
                        autoRotateWithGuest: false,
                        debugPort: true,
                        carrier: carrier
                    ),
                "A's keys, the app-wide auto-rotate under them"
            )
            #expect(
                DeviceSettings.load(DeviceInstance.directory(b, state: state))
                    == DeviceSettings(keyboardInputEnabled: true, autoRotateWithGuest: false),
                "B takes the app-wide keys"
            )
            let bytes = try Data(contentsOf: DeviceSettings.url(DeviceInstance.directory(a, state: state)))
            #expect(String(decoding: bytes.prefix(5), as: UTF8.self) == "<?xml", "an XML property list")
            #expect(
                (defaults.persistentDomain(forName: suite) ?? [:]).keys.sorted() == ["captureFolder"],
                "every per-device and app-wide key went, a deleted device's too"
            )
        }
    }

    /// Connect Hardware Keyboard: off is saved per device and read back; unset is connected.
    @Test func hardwareKeyboardChoiceIsKept() throws {
        try withTemporaryDirectory { device in
            var keyboard = DeviceSettings.load(device)
            #expect(keyboard.hardwareKeyboard == nil)
            keyboard.hardwareKeyboard = false
            try keyboard.save(device)
            #expect(DeviceSettings.load(device).hardwareKeyboard == false)
        }
    }

    @Test func keyboardToggleBoards() {
        _ = ShippedResources.machines
        #expect(
            Board.n90.canToggleHardwareKeyboard && !Board.n88.canToggleHardwareKeyboard
                && !Board.n72.canToggleHardwareKeyboard
        )
    }
}
