import Foundation

/// Saved machine state, so the next launch restores in seconds instead of booting for minutes.
/// qemu-ios writes it as a migration stream (`qemu_ios_snapshot_save2`) and restores it from `-incoming file:<path>`.
///
/// Rules that keep the disk and the saved RAM in step:
/// - a snapshot is written to snapshot.tmp, then promoted, so a half-written one is never used;
/// - it is tied to the emulator build that wrote it (a different build cannot read it) and to its own size (truncated = bad);
/// - it is used once: the first launch that restores it deletes it, because from then on the guest writes to the disk
///   and the old RAM image would no longer match it. Quit with "Save & quit" to make a new one.
struct Snapshots {
    let overlay: URL
    var file: URL { overlay.appendingPathComponent("snapshot") }
    var tmp: URL { overlay.appendingPathComponent("snapshot.tmp") }
    var meta: URL { overlay.appendingPathComponent("snapshot.meta") }

    struct Meta: Codable {
        var build: String
        var size: Int64
    }

    private func size(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let number = attributes[.size] as? NSNumber
        else { return nil }
        return number.int64Value
    }

    /// A snapshot exists, was written by this emulator build, and is the size it was when it was saved.
    func usable(build: String) -> Bool {
        guard let data = try? Data(contentsOf: meta), let m = try? JSONDecoder().decode(Meta.self, from: data) else { return false }
        return m.build == build && size(of: file) == m.size && m.size > 0
    }

    func discard() {
        for url in [file, tmp, meta] { try? FileManager.default.removeItem(at: url) }
    }

    func discardTemp() { try? FileManager.default.removeItem(at: tmp) }

    /// Makes the finished snapshot.tmp the snapshot.
    func promote(build: String) throws {
        guard let written = size(of: tmp), written > 0 else {
            throw NSError(domain: "LTM", code: 10, userInfo: [NSLocalizedDescriptionKey: "The saved state is empty."])
        }
        let fm = FileManager.default
        try? fm.removeItem(at: meta)
        try? fm.removeItem(at: file)
        try fm.moveItem(at: tmp, to: file)
        try JSONEncoder().encode(Meta(build: build, size: written)).write(to: meta)
    }
}
