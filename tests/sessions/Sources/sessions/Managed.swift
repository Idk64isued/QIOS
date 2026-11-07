import FirmwareSchema
import Foundation
import HostRuntime
import LightTouchCore
import SessionKit

/// `sessions single --managed`: the base booted as a device the user already has. It is published under the run's
/// state as Light Touch publishes a prepared device (PreparationJob.publish: Devices/<uuid>/base, locked, and its
/// device.plist), the base an APFS clone, so the shared one is never written; then session-driver starts it as the
/// app's Start does, every boot through boot admission (FirmwareTool.admitStart) and the record's boot
/// (DeviceInstance.preparedBoot).
///
/// `--expect-admission STEP` names an admission step the base must need and the device must come out of the run with
/// (an old device: an older format or preparation). The old devices are APFS clones kept in
/// ~/Developer/qemu-ios-files/old-devices, never booted in place:
///   - n45ap-4A102-sc-prefs (preparation 11, before 44b92c0b): sc-prefs, the 1.1.3 to 1.1.5 Wi-Fi preferences moved
///     to where configd reads them (N45Migration); the run also checks configd joins qemu-ios.
///   - n88ap-8A293-format1 (4.0 prepared 2026-10-05: a format 1 legacy NAND store, recipe 1, kboot.bin's
///     ncoref-frequency 0): image-store, the format 2 migration (K48NANDMigration); iphone-imei, the recipe 1 -> 2
///     identity marker; audio-clock, the kboot.bin copy with the audio clock set (PreparedDeviceBoot.audioClockBoot);
///     the run also checks the lock sound.
///
/// Each is `sessions single OLD --expect-admission STEP ...`; a new admission step adds its Step, what it leaves
/// (`done`) and an old device that needs it.
enum ManagedDevice {
    enum Step: String, CaseIterable {
        case scPrefs = "sc-prefs"
        case imageStore = "image-store"
        case audioClock = "audio-clock"
        case iPhoneIMEI = "iphone-imei"
    }

    /// Devices/<uuid> under `state` for `base`, with `catalog`'s entry for it.
    static func make(base: URL, state: URL, catalog: FirmwareCatalog) throws -> DeviceInstance {
        let lock = try DeviceLock.read(base: base)
        guard let id = lock?.entryID, let entry = catalog.entry(id: id) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: base.path])
        }
        return try PreparationJob.publish(copyOf: base, entry: entry, state: state)
    }

    /// Whether `instance` (under `state`) has what each step leaves.
    static func done(_ step: Step, _ instance: DeviceInstance, state: URL) -> Bool {
        let fm = FileManager.default
        guard let record = try? DeviceInstance.read(DeviceInstance.directory(instance.id, state: state)) else {
            return false
        }
        let paths = record.paths(state: state, logs: state)
        switch step {
        case .scPrefs: return fm.fileExists(atPath: paths.overlay.appendingPathComponent(".n45-sc-prefs-3").path)
        case .imageStore:
            return record.format >= DeviceRecord.imageFormat
                && PreparedDeviceBoot.isImageStore(paths.base.appendingPathComponent("nand"))
        case .audioClock: return fm.fileExists(atPath: paths.overlay.appendingPathComponent("kboot.bin").path)
        case .iPhoneIMEI:
            let marker =
                (try? Data(contentsOf: paths.directory.appendingPathComponent(FirmwareWire.migratedRecipeFile)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return marker?["step"] as? String == "iphone-imei"
        }
    }

    /// Every boot admitted, and each expected step done by the end of the run.
    static func judge(_ r: Report, _ d: String, _ instance: DeviceInstance, state: URL, expect: [Step], events: Events)
    {
        let admissions = events.find("bootAdmission", ["device": d])
        let changed = admissions.map { $0.bool("changed") ? "changed" : "unchanged" }
        r.check(
            !admissions.isEmpty && admissions.count == events.find("hello", ["device": d]).count,
            "\(d): every boot went through boot admission (\(changed.joined(separator: ", ")))"
                + admissions.compactMap { $0.string("notice").flatMap { $0.isEmpty ? nil : ": \($0)" } }.joined()
        )
        for step in expect {
            r.check(done(step, instance, state: state), "\(d): admission step \(step.rawValue) done")
        }
    }
}
