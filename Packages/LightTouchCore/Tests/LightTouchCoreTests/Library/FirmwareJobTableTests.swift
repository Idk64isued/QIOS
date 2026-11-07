import Foundation
import Testing

@testable import LightTouchCore

/// FirmwareJobTable's transitions, driven directly: one state per entry, and events for a job the entry no longer
/// runs dropped.
@Suite struct FirmwareJobTableTests {
    let now = Date(timeIntervalSince1970: 0)
    let a = UUID(), b = UUID()

    @Test func cancelThenPrepareRunsOnceTheOldPreparerIsGone() {
        var t = FirmwareJobTable()
        t.preparing("e", a, afterDownload: false, now: now)
        let r1 = t.cancel("e")
        #expect(r1 == [.cancelPreparation(a)])
        #expect(t.phase("e") == .cancelling(a, retry: false) && t.shown["e"] == nil, "the row is back to Prepare")
        let r2 = t.request("e")
        #expect(!r2 && t.phase("e") == .cancelling(a, retry: true), "Prepare is remembered")
        #expect(t.shown["e"] == .preparing(.init(name: "Starting")))
        #expect(!t.mayPrepare("e"), "not beside the old preparer")
        let r3 = t.preparation("e", a, .progress(0.5, detail: nil), now: now)
        #expect(r3 == [] && t.phase("e") != nil)
        let r4 = t.preparation("e", a, .cancelled, now: now)
        #expect(r4 == [.retry("e")] && t.phase("e") == nil)
        // Cancel, then Cancel the retry too: nothing starts.
        t.preparing("e", b, afterDownload: false, now: now)
        _ = t.cancel("e")
        _ = t.request("e")
        _ = t.cancel("e")
        let r5 = t.preparation("e", b, .cancelled, now: now)
        #expect(r5 == [] && t.phase("e") == nil)
    }

    @Test func eventsOfAnotherPreparerAreDropped() {
        var t = FirmwareJobTable()
        t.preparing("e", b, afterDownload: true, now: now)
        let r6 = t.preparation("e", a, .failed("old"), now: now)
        #expect(r6 == [] && t.phase("e") == .preparing(b))
        _ = t.preparation("e", b, .step(1, of: 2, name: "Decrypting"), now: now)
        guard case .preparing(let p)? = t.shown["e"] else {
            Issue.record("\(t.shown)")
            return
        }
        #expect(p.step == 1 && p.name == "Decrypting" && p.startsAt == 0.5)
        #expect(t.preparing == 1)
        _ = t.preparation("e", b, .failed("why"), now: now)
        #expect(t.phase("e") == .failed("why") && t.shown["e"] == .failed("why") && t.isIdle("e"))
    }

    @Test func aLatePublishEndsACancel() {
        var t = FirmwareJobTable()
        t.preparing("e", a, afterDownload: false, now: now)
        _ = t.cancel("e")
        _ = t.request("e")
        let instance = DeviceInstance(
            id: a,
            name: "x",
            board: "k48ap",
            firmware: "e",
            created: now,
            base: .init(kind: .prepared, path: ""),
            storage: .init(key: "", overlay: "", snapshot: "", usbmuxConf: "")
        )
        let r7 = t.preparation("e", a, .published(instance), now: now)
        #expect(r7 == [] && t.phase("e") == nil, "no retry")
    }

    @Test func anImportNeverDisturbsAJobUnderWay() {
        var t = FirmwareJobTable()
        t.preparing("busy", a, afterDownload: false, now: now)
        #expect(!t.isIdle("busy"))
        t.importing("row", b)
        let r8 = t.imported(b, onto: "row", matched: "busy")
        #expect(!r8, "matched an entry that is preparing")
        #expect(t.phase("row") == nil && t.phase("busy") == .preparing(a))
        _ = t.download("busy2", ["s"])
        let r9 = t.imported(UUID(), onto: nil, matched: "busy2")
        #expect(!r9 && t.phase("busy2") == .downloading(["s"]))
        t.fail("old", "x")
        let r10 = t.imported(UUID(), onto: nil, matched: "old")
        #expect(r10, "a failed entry may prepare again")
        // Cancelled while it checked: the late result and failure are dropped.
        t.importing("row", a)
        let r11 = t.cancel("row")
        #expect(r11 == [.cancelImport(a)])
        let r12 = t.imported(a, onto: "row", matched: "row")
        #expect(!r12 && !t.importFailed(a, onto: "row", "x"))
        #expect(t.phase("row") == nil)
    }

    @Test func aSharedDownloadOutlivesOneJobsCancel() {
        var t = FirmwareJobTable(bytes: ["p": 100, "s": 300])
        let r13 = t.download("point", ["p", "s"])
        #expect(r13 == ["p", "s"])
        let r14 = t.download("base", ["s"])
        #expect(r14 == [], "already downloading")
        let r15 = t.cancel("point")
        #expect(r15 == [.cancelDownload("p")], "4.3's IPSW is still wanted")
        let r16 = t.download("s", .progress(0.5), now: now)
        #expect(r16 == [])
        #expect(t.shown["base"].map { if case .downloading(let f, _, _, _, _) = $0 { f } else { -1 } } == 0.5)
        #expect(t.download("s", .finished(URL(fileURLWithPath: "/s")), now: now) == [.prepare("base")])
    }

    @Test func aTwoIPSWJobPreparesWhenBothAreHere() {
        var t = FirmwareJobTable(bytes: ["p": 100, "s": 300])
        _ = t.download("point", ["p", "s"])
        _ = t.download("s", .progress(1), now: now)
        _ = t.download("p", .progress(0.5), now: now)
        #expect(t.shown["point"].map { if case .downloading(let f, _, 2, _, _) = $0 { f } else { -1 } } == 0.875)
        #expect(t.download("s", .finished(URL(fileURLWithPath: "/s")), now: now) == [])
        #expect(t.download("p", .finished(URL(fileURLWithPath: "/p")), now: now) == [.prepare("point")])
        _ = t.download("x", ["q"])
        _ = t.download("q", .failed(.corrupted), now: now)
        #expect(t.phase("x") == .failed(FirmwareError.corrupted.localizedDescription) && t.downloads["q"] == nil)
    }

    @Test func aRelaunchRebuildsOnlyTheSavedJobs() {
        var t = FirmwareJobTable()
        _ = t.download("point", ["p", "s"])
        let intents = t.intents
        #expect(intents == ["point": ["p", "s"]])
        // Relaunched while 4.3's IPSW ("s") downloads: its task reports to 4.3.1's job, and 4.3 gets none.
        var r = FirmwareJobTable()
        r.restore(intents, stored: ["p"])
        let r1 = r.resume(tasks: ["s"])
        #expect(r1 == [] && r.phase("point") == .downloading(["p", "s"]) && r.phase("s") == nil)
        let r2 = r.download("s", .finished(URL(fileURLWithPath: "/s")), now: now)
        #expect(r2 == [.prepare("point")])
        // Its task is gone (it failed while the app was closed): it starts again.
        var gone = FirmwareJobTable()
        gone.restore(intents, stored: ["p"])
        let r3 = gone.resume(tasks: [])
        #expect(r3 == [.startDownload("s")])
        // Both IPSWs landed while the app was closed: it prepares.
        var landed = FirmwareJobTable()
        landed.restore(intents, stored: ["p", "s"])
        let r4 = landed.resume(tasks: [])
        #expect(r4 == [.prepare("point")])
        // A task no saved job waits for makes no job.
        var none = FirmwareJobTable()
        let r5 = none.resume(tasks: ["s"])
        #expect(r5 == [] && none.jobs.isEmpty)
    }

    @Test func dismissingARowForgetsOnlyAFailure() {
        var t = FirmwareJobTable()
        t.fail("gone", "x")
        t.preparing("busy", a, afterDownload: false, now: now)
        t.dismiss("gone")
        t.dismiss("busy")
        #expect(t.phase("gone") == nil && t.phase("busy") == .preparing(a))
    }
}
