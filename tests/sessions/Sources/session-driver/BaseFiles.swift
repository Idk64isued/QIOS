import FirmwareKit
import Foundation

/// The first of `paths` (volume-relative) on the base's system volume, read offline: the volume rebuilt from the
/// base's NAND store (VolumeRebuild, no overlay) into `work`, which is removed after. For a guest without an agent.
func baseSystemFile(base: URL, paths: [String], work: URL) -> (path: String, data: Data)? {
    defer { try? FileManager.default.removeItem(at: work) }
    guard
        let image = try? VolumeRebuild.rebuild(
            base: base.appendingPathComponent("nand"),
            overlay: nil,
            into: work,
            only: ["system"]
        ).first?.image,
        let volume = try? HFSPlusVolume(image)
    else { return nil }
    for path in paths {
        if let record = try? volume.record(at: path), let data = try? volume.contents(record) { return (path, data) }
    }
    return nil
}

/// The crash reports the base itself carries (its preparation's boots wrote them): every path under a CrashReporter
/// folder of its data volume (or of the one volume, on a board with one), for GuestFaults.crashedProcesses(listed:base:).
/// nil where the base can't be read.
func baseCrashReports(base: URL, work: URL) -> [String]? {
    defer { try? FileManager.default.removeItem(at: work) }
    let nand = base.appendingPathComponent("nand")
    for volume in ["data", "system"] {
        guard let image = try? VolumeRebuild.rebuild(base: nand, overlay: nil, into: work, only: [volume]).first?.image,
            let paths = try? HFSPlusVolume(image).paths()
        else { continue }
        return paths.map(\.path).filter { $0.contains("CrashReporter/") }
    }
    return nil
}
