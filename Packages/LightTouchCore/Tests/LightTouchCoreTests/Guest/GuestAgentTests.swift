import Foundation
import Testing

@testable import LightTouchCore

/// GuestAgent and GuestServices over a device's link, with a fake guest behind it (FakeGuestLink): capability
/// detection and its cache, typed wire formats, the v1 exec fallback with shell quoting, ENOENT handling, media
/// commit through an uploaded helper (cleaned up on failure too), launch vs a locked device, locationd's first-zone
/// record, halt submission, stale/absent agents and cancellation (agentCancel).
struct GuestAgentTests {
    @Test func v2OpsAreTypedAndCapabilitiesCached() async throws {
        let link = FakeGuestLink()
        let cache = GuestAgentCache()
        let agent = GuestAgent(link: link, cache: cache)
        try await agent.spawn(["/bin/launchctl", "stop", "com.apple.SpringBoard"])
        try await agent.sync()
        #expect(link.spawns == [["/bin/launchctl", "stop", "com.apple.SpringBoard"]] && link.shells.isEmpty)
        #expect(link.ops.filter { $0 == "ping" }.count == 1, "the ping is cached")
        #expect(cache.capabilities?.version == 2 && cache.capabilities?.has("dlicon") == true)
        try await agent.put("/tmp/a b", mode: 0o644, Data("x".utf8))
        #expect(
            link.files["/tmp/a b"] == Data("x".utf8) && link.modes["/tmp/a b"] == "644",
            "mode is octal, the last word"
        )
        #expect(try await agent.get("/nope", limit: 1 << 20) == nil, "ENOENT is absent")
        try await agent.unlink("/nope")
        try await agent.chown(501, 501, "/tmp/a b")
        #expect(link.owners["/tmp/a b"] == "501:501")
        #expect(try await agent.placeholder("add", id: "qemu-install-x", bundleID: "com.x"))
        let front = try await agent.frontmost()
        #expect(front.bundleID == "com.example.game" && front.name == "Game")
        #expect(try await agent.orientation() == 90)
        link.angle = "17"
        await #expect(throws: (any Error).self, "invalid angle accepted") { try await agent.orientation() }
    }

    /// A read names the most it takes: a file over that throws having fetched no more than one byte past it, in 1 MiB
    /// ranges past 1 MiB, and one under it comes whole (smaller ones in one get).
    @Test func getStopsAtItsLimit() async throws {
        let link = FakeGuestLink()
        let agent = GuestAgent(link: link, cache: GuestAgentCache())
        let big = Data((0..<(3 << 20) + 5).map { UInt8(truncatingIfNeeded: $0) })
        link.files["/big"] = big
        link.files["/small"] = Data(count: 1000)
        #expect(try await agent.get("/big", limit: 4 << 20) == big)
        link.rangeBytes = 0
        await #expect(throws: GuestAgentError.self) { try await agent.get("/big", limit: 2 << 20) }
        #expect(link.rangeBytes == (2 << 20) + 1, "fetched \(link.rangeBytes)")
        #expect(try await agent.get("/small", limit: 1000)?.count == 1000)
        await #expect(throws: GuestAgentError.self) { try await agent.get("/small", limit: 999) }
        #expect(try await agent.get("/absent", limit: 1) == nil)
    }

    @Test func v1AgentGetsShellQuotedExecAndNoV2Ops() async throws {
        let old = FakeGuestLink(version: 1)
        let v1 = GuestAgent(link: old, cache: GuestAgentCache())
        try await v1.spawn(["/bin/launchctl", "stop", "it's"])
        try await v1.unlink("/tmp/x y")
        try await v1.chown(501, 501, "/var/mobile/Media/LightTouch")
        try await v1.sync()
        #expect(
            old.shells == [
                "'/bin/launchctl' 'stop' 'it'\\''s'", "rm -f '/tmp/x y'",
                "chown 501:501 '/var/mobile/Media/LightTouch'", "sync"
            ]
        )
        #expect(old.spawns.isEmpty && !old.ops.contains("spawn"), "a v1 agent is never sent a v2 op")
        #expect(try await v1.placeholder("add", id: "x") == false && !old.ops.contains("dlicon"))
    }

    @Test func mediaCommitUploadsItsHelperAndCleansUp() async throws {
        let link = FakeGuestLink()
        let agent = GuestAgent(link: link, cache: GuestAgentCache())
        try await withTemporaryDirectoryAsync { tmp in
            func local(_ name: String, _ data: Data) throws -> URL {
                let u = tmp.appendingPathComponent(name)
                try data.write(to: u)
                return u
            }
            let id = UUID().uuidString
            let helper = try local("itphoto", Data("helper".utf8))
            link.spawnOutput["/tmp/ltm-itphoto-\(id)"] = (0, "imported\n")
            let legacy = GuestServices(agent: agent)
            #expect(try await legacy.commitMedia(id: id, helper: "itphoto", localHelper: { helper }, metadata: nil))
            #expect(link.spawns.last == ["/tmp/ltm-itphoto-\(id)", id] && link.files["/tmp/ltm-itphoto-\(id)"] == nil)
            #expect(link.owners["/var/mobile/Media/LightTouch/\(id)"] == "501:501")
            // An older package's executable must never silently discard new fields: the app's helper runs, packaged or not.
            let packaged = GuestServices(agent: agent, packaged: true)
            let plist = try local("m.plist", Data("<plist/>".utf8))
            let music = try local("itmedia", Data("current media helper".utf8))
            link.spawnOutput["/usr/local/lighttouch/current/bin/itmedia"] = (0, "imported\n")
            link.spawnOutput["/tmp/ltm-itmedia-\(id)"] = (0, "imported\n")
            #expect(try await packaged.commitMedia(id: id, helper: "itmedia", localHelper: { music }, metadata: plist))
            #expect(link.spawns.last == ["/tmp/ltm-itmedia-\(id)", "/tmp/ltm-media-\(id).plist", id])
            #expect(!link.spawns.contains { $0.first == "/usr/local/lighttouch/current/bin/itmedia" })
            #expect(link.files["/tmp/ltm-media-\(id).plist"] == nil, "metadata removed")
            // A failing helper still cleans up, and the error surfaces.
            link.spawnOutput["/tmp/ltm-itmedia-\(id)"] = (3, "no library")
            await #expect(throws: (any Error).self, "failed commit succeeded") {
                try await legacy.commitMedia(id: id, helper: "itmedia", localHelper: { music }, metadata: plist)
            }
            #expect(link.files.keys.allSatisfy { !$0.hasPrefix("/tmp/ltm-") }, "\(link.files.keys)")
            link.spawnOutput["/tmp/ltm-itmedia-\(id)"] = (0, "partial\n")
            #expect(
                try await legacy.commitMedia(id: id, helper: "itmedia", localHelper: { music }, metadata: plist)
                    == false
            )
        }
    }

    @Test func launchRefusedOnALockedDeviceIsLocked() async throws {
        let link = FakeGuestLink()
        let services = GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
        try await services.launch("com.example.game")
        link.launchFails = true
        link.locked = true
        await #expect(throws: AppLaunchError.locked) { try await services.launch("com.example.game") }
        link.locked = false
        await #expect(throws: AppLaunchError.failed) { try await services.launch("com.example.game") }
        link.launchFails = false
        try await services.respring()
        #expect(link.spawns.last == ["/bin/launchctl", "stop", "com.apple.SpringBoard"], "5.x and earlier")
        link.files[GuestServices.backboarddJob] = Data("<plist/>".utf8)
        try await services.respring()
        #expect(link.spawns.last == ["/bin/launchctl", "stop", "com.apple.backboardd"], "6.x on: SpringBoard goes too")
        try await services.reconnectManagement()
        #expect(link.spawns.last == ["/bin/launchctl", "stop", "com.apple.mobile.lockdown"])
    }

    /// 4.x locationd's record of its first external zone is cleared with locationd unloaded, the rest of its cache
    /// kept; no record, no cache: nothing touched (smoke #58).
    @Test func locationdFirstZoneRecordIsClearedWhileUnloaded() async throws {
        let link = FakeGuestLink()
        let services = GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
        let cache = "/var/root/Library/Caches/locationd/cache.plist"
        let job = "/System/Library/LaunchDaemons/com.apple.locationd.plist"
        link.files[cache] = try PropertyListSerialization.data(
            fromPropertyList: ["PreviousTimeZone": "America/New_York", "TimeZoneBorderDistance": 12.5],
            format: .binary,
            options: 0
        )
        #expect(try await services.forgetExternalTimeZone(), "a record to clear")
        #expect(link.spawns == [["/bin/launchctl", "unload", job], ["/bin/launchctl", "load", job]])
        let ops = link.ops.filter { $0 != "ping" && $0 != "get" }
        #expect(ops == ["spawn", "put", "spawn"], "written while locationd is unloaded: \(link.ops)")
        let cleared =
            try PropertyListSerialization.propertyList(from: link.files[cache]!, format: nil) as! [String: Any]
        #expect(cleared["PreviousTimeZone"] == nil && cleared["TimeZoneBorderDistance"] as? Double == 12.5)
        #expect(
            try await services.forgetExternalTimeZone() == false && link.spawns.count == 2,
            "no record: locationd left running"
        )
        link.files[cache] = nil
        #expect(try await services.forgetExternalTimeZone() == false && link.spawns.count == 2, "no cache: nothing")
    }

    @Test func haltAndAbsentOrStaleAgents() async throws {
        let link = FakeGuestLink()
        let agent = GuestAgent(link: link, cache: GuestAgentCache())
        #expect(await agent.requestHalt() && link.halts == 1, "submitted with deadline 0")
        link.agent = 0
        #expect(await agent.requestHalt() == false)
        await #expect(throws: (any Error).self, "absent agent answered") { try await agent.frontmost() }
        #expect(await agent.waitAlive(seconds: 0.3) == false)
        link.agent = 2
        await #expect(throws: (any Error).self, "stale agent answered") { try await agent.orientation() }
        let none = GuestAgent(link: nil, cache: GuestAgentCache())
        #expect(none.status == 0 && !none.isAlive)
    }

    @Test func cancellationSendsAgentCancelAndEndsTheRequest() async throws {
        let link = FakeGuestLink()
        link.hold = true
        let agent = GuestAgent(link: link, cache: GuestAgentCache())
        let task = Task { try await agent.orientation() }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(link.cancelled.count == 1)
    }

    @Test func capabilitiesParse() {
        #expect(GuestAgentCapabilities.parse("it_agent v1\n") == GuestAgentCapabilities(version: 1, ops: []))
        #expect(
            GuestAgentCapabilities.parse("it_agent v2\nops ping spawn\n")
                == GuestAgentCapabilities(version: 2, ops: ["ping", "spawn"])
        )
        #expect(GuestAgentCapabilities.parse("nonsense") == nil)
    }
}

/// withTemporaryDirectory for async bodies.
func withTemporaryDirectoryAsync<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ltm-tests-" + UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}
