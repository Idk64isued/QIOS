import BuildSupport
import Foundation
import Testing

@testable import ReleaseChecks

/// Devices prepared by the bundled firmwarekit and booted through the bundled helper, dylib, services worker and
/// usbmuxd (`sessions single` in tests/sessions: lit, lockdown, time zone, the Home screen, AFC, an IPA install, a
/// clean shutdown): the built-in iPod, and a fresh `firmwarekit create` of one firmware per preparation route.
@Suite(.serialized, .enabled(if: appGiven, "no app: LTM_RELEASE_APP / LTM_RELEASE_ARCHIVE (the Release plan)"))
struct ReleaseBootTests {
    /// The built-in iPod and the routes, from Packages/ReleaseChecks/boots.json, which scripts/ship also reads to
    /// fetch their IPSWs.
    struct Boots: Decodable {
        let builtIn: String
        /// One entry per distinct preparation path (Preparer.prepare's boards, K48Board's strategies): N45Board
        /// (1.x), N72Board, K48Board by iBoot (iPad), by kboot on the A4 with 4.x data protection (iPhone 4) and by
        /// kboot on the S5L8920 with its own NOR (iPhone 3GS). Every IPSW from the app's cache (the catalog's sha1);
        /// a missing one fails.
        let routes: [String]
    }
    static let boots: Boots = {
        let file = repository.appendingPathComponent("Packages/ReleaseChecks/boots.json")
        do { return try JSONDecoder().decode(Boots.self, from: Data(contentsOf: file)) } catch {
            fatalError("\(file.path): \(error)")
        }
    }()
    static let builtIn = boots.builtIn
    static let routes = boots.routes
    /// Emulators at once (host load).
    static let lanes = 2

    @Test func theBuiltInIPodUnpacksWithItsOwnIdentityAndBoots() throws {
        try boot(entry: Self.builtIn, builtIn: true, sessions: try buildSessions())
    }

    @Test(.enabled(if: !ReleaseApp.skipPrepare, "LTM_RELEASE_SKIP_PREPARE=1 (development dry runs only)"))
    func everyPreparationRouteCreatesADeviceThatBoots() async throws {
        let ipsws = try Self.routes.map { try ipsw(for: $0) }
        let missing = ipsws.filter { !FileManager.default.fileExists(atPath: $0.path) }
        try #require(missing.isEmpty, "no IPSW in the app's cache (download them in the app): \(missing.map(\.path))")
        let sessions = try buildSessions()
        await withTaskGroup(of: Void.self) { group in
            for lane in 0..<Self.lanes {
                group.addTask {
                    for id in stride(from: lane, to: Self.routes.count, by: Self.lanes).map({ Self.routes[$0] }) {
                        do { try boot(entry: id, builtIn: false, sessions: sessions) } catch is ExpectationFailedError {
                            // #require recorded it; the lane goes on to its next route
                        } catch {
                            Issue.record(error, "\(id)")
                        }
                    }
                }
            }
        }
    }

    /// A firmwarekit that crashed leaves its volumes attached: whatever is attached from under `dir` is detached.
    func detachImages(under dir: URL) {
        let plain = { (p: String) in p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p }
        guard let info = try? Shell.run(["hdiutil", "info", "-plist"]),
            let plist = try? PropertyListSerialization.propertyList(from: Data(info.output.utf8), format: nil)
                as? [String: Any]
        else { return }
        for image in plist["images"] as? [[String: Any]] ?? []
        where plain(image["image-path"] as? String ?? "").hasPrefix(plain(dir.path) + "/") {
            let devices = (image["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["dev-entry"] as? String }
            if let device = devices.min(by: { $0.count < $1.count }) {
                _ = try? Shell.run(["hdiutil", "detach", device, "-force"])
            }
        }
    }

    func catalogEntry(_ id: String) throws -> [String: Any] {
        let catalog =
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: try ReleaseApp.app().appendingPathComponent("Contents/Resources/firmware-catalog.json")
                )
            ) as! [String: Any]
        return try #require((catalog["entries"] as! [[String: Any]]).first { $0["id"] as? String == id }, "\(id)")
    }

    func ipsw(for id: String) throws -> URL {
        let sha1 = (try catalogEntry(id)["source"] as? [String: Any])?["sha1"] as? String ?? "none"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/gold.samhenri.LightTouchMac/IPSW/\(sha1).ipsw")
    }

    /// tests/sessions' command, built once here; it boots a device through the bundle's helper, dylib, services
    /// worker, usbmuxd, SecureROMs and guest package.
    func buildSessions() throws -> URL {
        let sessions = repository.appendingPathComponent("tests/sessions")
        let built = try Shell.run(
            ["swift", "build", "--package-path", sessions.path, "--product", "sessions"],
            timeout: 900
        )
        try #require(built.succeeded, "building tests/sessions: \(built.output.suffix(1500))")
        _ = try Shell.run(["swift", "build", "--package-path", sessions.path], timeout: 900)
        return sessions.appendingPathComponent(".build/debug/sessions")
    }

    func boot(entry id: String, builtIn: Bool, sessions: URL) throws {
        let app = try ReleaseApp.app()
        let contents = app.appendingPathComponent("Contents")
        let catalog =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: contents.appendingPathComponent("Resources/firmware-catalog.json"))
            ) as! [String: Any]
        let entry = try catalogEntry(id)
        let started = Date()
        try withScratch { work in
            let out = work.appendingPathComponent("out")
            let frames = work.appendingPathComponent("frames")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
            defer {
                detachImages(under: work)
                _ = try? Shell.run(["chflags", "-R", "nouchg", work.path])
                _ = try? Shell.run(["chmod", "-R", "u+w", work.path])
            }
            let firmwarekit = contents.appendingPathComponent("MacOS/firmwarekit").path
            let seed = UUID().uuidString
            let command: [String]
            if builtIn {
                let blob = (catalog["bundled"] as! [String: String])[id]!
                command = [
                    firmwarekit, "unpack-base", "--blob", contents.appendingPathComponent("Resources/\(blob)").path,
                    "--out", out.path, "--seed", seed
                ]
            } else {
                let ipsw = try ipsw(for: id)
                try #require(FileManager.default.fileExists(atPath: ipsw.path), "\(id): no IPSW (\(ipsw.path))")
                let entryFile = work.appendingPathComponent("entry.json")
                try JSONSerialization.data(withJSONObject: entry).write(to: entryFile)
                // as the app prepares: the helper beside firmwarekit and the bundle's guest tools by default
                command = [
                    firmwarekit, "create", "--entry", entryFile.path, "--ipsw", ipsw.path, "--out", out.path,
                    "--cache", work.appendingPathComponent("cache").path, "--seed", seed
                ]
            }
            let prepared = try Shell.run(
                command,
                environment: ReleaseApp.cleanEnvironment,
                directory: work,
                timeout: 1500
            )
            let preparedAt = Date()
            let events = prepared.output.split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            try #require(
                prepared.succeeded && events.last?["event"] as? String == "done",
                "\(id): firmwarekit \(command[1]) failed (\(prepared.status)): \(events.last ?? [:])"
            )
            let lock =
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: out.appendingPathComponent(events.last!["lock"] as! String))
                ) as! [String: Any]
            if builtIn {
                #expect(
                    (lock["identity"] as? [String: Any])?["seed"] as? String == seed,
                    "the unpacked iPod did not take its own identity"
                )
            }
            // as the app locks a base
            _ = try Shell.run(["find", out.path, "-type", "d", "-exec", "chflags", "uchg", "{}", "+"])
            let arguments = [sessions.path, "single", out.path, "--app", app.path, "--work", frames.path]
            let booted = try Shell.run(
                arguments,
                environment: ReleaseApp.cleanEnvironment,
                directory: work,
                timeout: 900
            )
            print(
                "\(id): prepared in \(Int(preparedAt.timeIntervalSince(started))) s, booted in "
                    + "\(Int(Date().timeIntervalSince(preparedAt))) s: \(booted.succeeded ? "PASS" : "FAIL")"
            )
            let summary =
                booted.output.split(separator: "\n").first { $0.contains(" passed; logs in ") }.map(String.init) ?? ""
            #expect(
                booted.succeeded,
                "\(id): boot \(summary.isEmpty ? "failed" : summary)\n\(booted.output.suffix(1500))"
            )
        }
    }
}
