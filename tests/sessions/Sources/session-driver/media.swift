import Foundation
import HostServiceClient

@testable import LightTouchCore

// `sessions single --media FILE…`: Import Media's own path at the first Home (PreparedMedia, DeviceServices' AFC
// staging, GuestServices.commitMedia with the given itmedia/itphoto), and what the guest's libraries hold, read back
// from the databases Music and Photos read: before the import, after it, and with Music open on every boot.

/// Each file prepared, staged and committed as the app's MediaImport does; emits `mediaImport`. The songs' and
/// videos' titles, for the library read. A song's cover on 3.x and 4.0 to 4.2.1, where the purchase-folder insert takes
/// it, is counted in the artwork cache that version's MusicLibrary reads (`coverRows`): 3.x's one in Purchases, 4.x's
/// beside the song (8C148 -[MLTrack mobileArtworkCacheFolder]); 5.x on keep covers in the library itself.
@MainActor func importMedia(
    _ d: Device,
    agent: GuestAgent,
    files: [String],
    tools: String,
    version: String
) async -> [String] {
    var titles: [String] = []
    let guest = GuestServices(agent: agent)
    for file in files {
        let t0 = Date()
        var fields: [String: Any] = ["device": d.name, "file": file]
        do {
            let media = try await PreparedMedia.prepare(URL(fileURLWithPath: file), profile: d.profile)
            fields["destination"] = media.destination
            fields["title"] = media.title
            if media.destination != "Photos" { titles.append(media.title) }
            try await MediaImport(services: d.services, guest: guest).stage(media, progress: { _ in })
            let (id, helper, metadata): (String, String, URL?) =
                switch media {
                case .song(let song): (song.id, "itmedia", song.metadata)
                case .video(let video): (video.id, "itmedia", video.metadata)
                case .photo(let photo): (photo.id, "itphoto", nil)
                }
            let local = URL(fileURLWithPath: tools).appendingPathComponent(helper)
            fields["ok"] = try await guest.commitMedia(
                id: id,
                helper: helper,
                localHelper: { local },
                metadata: metadata
            )
            if case .song(let song) = media, song.artwork != nil,
                let cache = purchaseArtworkCache(version: version, staging: id)
            {
                fields["coverCache"] = cache
                fields["coverRows"] = await artworkRows(d, agent: agent, cache: cache)
            }
        } catch let error as GuestAgentError {
            fields["ok"] = false
            // The helper's last line names the refusal; the whole output goes beside the run's logs.
            let log = d.dir.appendingPathComponent("media-\(URL(fileURLWithPath: file).lastPathComponent).log")
            try? error.output.write(to: log)
            fields["error"] = String(decoding: error.output.suffix(300), as: UTF8.self)
            fields["log"] = log.path
            fields["status"] = error.status
        } catch {
            fields["ok"] = false
            fields["error"] = "\(error)"
        }
        fields["seconds"] = Date().timeIntervalSince(t0)
        emit("mediaImport", fields)
    }
    return titles
}

/// Music opened through the agent (com.apple.mobileipod, or com.apple.Music on the iPad and 7.x), so the read after it
/// is of a library Music has loaded and checked; emits `musicOpened`.
@MainActor func openMusic(_ d: Device, agent: GuestAgent) async {
    var opened = ""
    for id in ["com.apple.mobileipod", "com.apple.Music"] where opened.isEmpty {
        if (try? await agent.launch(id)) != nil { opened = id }
    }
    try? await Task.sleep(for: .seconds(20))
    emit("musicOpened", ["device": d.name, "app": opened, "front": (try? await agent.frontmost().bundleID) ?? ""])
}

/// The folder of the ArtworkCache MusicLibrary reads a purchase's cover from on this version, or nil where covers
/// don't go through it (5.x on, and 4.3's ML3 importer).
func purchaseArtworkCache(version: String, staging: String) -> String? {
    let parts = version.split(separator: ".").compactMap { Int($0) }
    switch (parts.first ?? 0, parts.count > 1 ? parts[1] : 0) {
    case (3, _): return "/var/mobile/Media/Purchases/MobileArtworkDB"
    case (4, 0...2): return "/var/mobile/Media/LightTouch/\(staging)/MobileArtworkDB"
    default: return nil
    }
}

/// The rows of `cache`'s artwork.db (each a rendered format of a cover), read on the Mac; 0 when there is none.
@MainActor func artworkRows(_ d: Device, agent: GuestAgent, cache: String) async -> Int {
    guard let data = try? await agent.get(cache + "/artwork.db", limit: 16 << 20) else { return 0 }
    let local = d.dir.appendingPathComponent("artwork-\(UUID().uuidString).db")
    try? data.write(to: local)
    defer { try? FileManager.default.removeItem(at: local) }
    let p = Process()
    let out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = [local.path, "SELECT count(*) FROM artwork"]
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return 0 }
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

/// Songs and videos per title in the music library (ML3's MediaLibrary.sqlitedb from 5.x, else iTunes Library.itlp's
/// Library.itdb), and Saved Photos: the JPEG originals under DCIM and the assets Photos' own database lists (4.x on).
/// Emits `mediaCount`.
@MainActor func mediaCounts(_ d: Device, agent: GuestAgent, generation: Int, stage: String, titles: [String]) async {
    let dir = d.dir.appendingPathComponent("media-\(generation)-\(stage)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    /// The database and its WAL copied out; its path, or nil when the guest has none.
    func pull(_ remote: String, as name: String) async -> URL? {
        guard let data = try? await agent.get(remote, limit: 256 << 20) else { return nil }
        let local = dir.appendingPathComponent(name)
        try? data.write(to: local)
        for suffix in ["-wal", "-journal"] {
            if let side = try? await agent.get(remote + suffix, limit: 256 << 20) {
                try? side.write(to: URL(fileURLWithPath: local.path + suffix))
            }
        }
        return local
    }
    func query(_ db: URL, _ sql: String) -> Int? {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db.path, sql]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return p.terminationStatus == 0 ? Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }
    let itunes = "/var/mobile/Media/iTunes_Control/iTunes/"
    var fields: [String: Any] = ["device": d.name, "generation": generation, "stage": stage]
    var found: [String: Int] = [:]
    if let ml3 = await pull(itunes + "MediaLibrary.sqlitedb", as: "MediaLibrary.sqlitedb") {
        fields["library"] = "ML3"
        for title in titles {
            let quoted = title.replacingOccurrences(of: "'", with: "''")
            found[title] =
                query(ml3, "SELECT count(*) FROM item_extra WHERE title='\(quoted)'")
                ?? query(ml3, "SELECT count(*) FROM item WHERE title='\(quoted)'") ?? -1
        }
        fields["items"] = query(ml3, "SELECT count(*) FROM item") ?? -1
    } else if let itdb = await pull(itunes + "iTunes Library.itlp/Library.itdb", as: "Library.itdb") {
        fields["library"] = "itlp"
        for title in titles {
            let quoted = title.replacingOccurrences(of: "'", with: "''")
            found[title] = query(itdb, "SELECT count(*) FROM item WHERE title='\(quoted)'") ?? -1
        }
        fields["items"] = query(itdb, "SELECT count(*) FROM item") ?? -1
    } else {
        fields["library"] = "none"
        for title in titles { found[title] = 0 }
    }
    fields["found"] = found
    // Saved Photos' originals, as AFC lists them.
    var originals = 0
    if let albums = try? await d.services.files(in: "DCIM") {
        for album in albums where album.isDirectory && album.name.hasSuffix("APPLE") {
            originals +=
                (try? await d.services.files(in: "DCIM/\(album.name)"))?
                .filter { $0.name.uppercased().hasSuffix(".JPG") }.count ?? 0
        }
    }
    fields["originals"] = originals
    if let photos = await pull("/var/mobile/Media/PhotoData/Photos.sqlite", as: "Photos.sqlite") {
        fields["assets"] =
            query(photos, "SELECT count(*) FROM ZGENERICASSET WHERE ZKIND=0")
            ?? query(photos, "SELECT count(*) FROM ZGENERICASSET") ?? query(photos, "SELECT count(*) FROM Photo") ?? -1
    }
    emit("mediaCount", fields)
}
