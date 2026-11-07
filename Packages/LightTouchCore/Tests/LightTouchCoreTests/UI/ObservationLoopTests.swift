import Foundation
import Observation
import Testing

@testable import LightTouchCore

/// The observers' targeted updates: a loop fires for what its read touched, not for anything else, re-arms after
/// each change, and follows a new shape of reads after `rearm()`.
struct ObservationLoopTests {
    @Observable final class Model {
        var shown = 0
        var other = 0
    }

    /// Long enough for a stray main-actor hop to have run.
    private func settle() async { try? await Task.sleep(for: .milliseconds(50)) }

    @Test func firesForWhatItReadAndNotForTheRest() async {
        let model = Model()
        var seen: [Int] = []
        let loop = ObservationLoop(read: { _ = model.shown }, onChange: { seen.append(model.shown) })
        model.other = 1
        await settle()
        #expect(seen.isEmpty, "a property the observer didn't read changed")
        model.shown = 1
        await eventually("the first change") { seen == [1] }
        model.shown = 2  // re-armed after the first change
        await eventually("the second change") { seen == [1, 2] }
        model.shown = 2  // the same value is no change
        model.other = 2
        await settle()
        #expect(seen == [1, 2])
        model.shown = 3
        model.shown = 4  // one turn: one update, after both
        await eventually("the coalesced change") { seen == [1, 2, 4] }
        await settle()
        #expect(seen == [1, 2, 4])
        loop.cancel()
        model.shown = 5
        await settle()
        #expect(seen == [1, 2, 4], "a cancelled loop stays quiet")
    }

    @Test func readIsTheUpdateAndRearmFollowsNewReads() async {
        let first = Model()
        let second = Model()
        var target = first
        var applied = 0
        let loop = ObservationLoop(read: {
            _ = target.shown
            applied += 1
        })
        #expect(applied == 1, "the read runs at once")
        target = second
        loop.rearm()
        #expect(applied == 2)
        first.shown = 1
        await settle()
        #expect(applied == 2, "the model it no longer reads")
        second.shown = 1
        await eventually("the model it reads now") { applied == 3 }
        _ = loop
    }

    @Test func releasedLoopStopsUpdating() async {
        let model = Model()
        var updates = 0
        var loop: ObservationLoop? = ObservationLoop(read: { _ = model.shown }, onChange: { updates += 1 })
        _ = loop
        loop = nil
        model.shown = 1
        await settle()
        #expect(updates == 0)
    }
}
