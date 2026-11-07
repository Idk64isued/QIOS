import Crypto
import DeviceRuntime
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// GuestPackageSession's qualification of one cold boot (health budgets, record verdicts, one-shot completion), its
/// async owner under BootSessionScope, and GuestPackage's "not responding" judgment for an offer.
struct GuestPackageSessionTests {
    let offer = GuestPackage.Offer(bundled: 7, version: "1.7", serial: 7, glHook: true)
    let report = GuestPackageReport(serial: 7, result: 1)
    var record: DeviceInstance.Guest {
        var record = DeviceInstance.Guest()
        record.seed = 1
        record.bad = [7, 9]
        record.builtIn = 6
        return record
    }
    func observation(_ healthy: Bool, _ report: GuestPackageReport?, _ record: DeviceInstance.Guest?)
        -> GuestPackageSession.Observation
    {
        .init(report: report, record: record, glesProtocol: 1, healthy: healthy)
    }
    func observation(_ healthy: Bool) -> GuestPackageSession.Observation { observation(healthy, report, record) }

    @Test func continuousHealthMakesThePackageGoodOnce() throws {
        var record = record
        var session = GuestPackageSession(offer: offer)
        let firstUpdate = session.observe(observation(true), elapsed: .seconds(1))
        let first = try #require(firstUpdate)
        #expect(first.changedReport == report && first.verdict == nil)
        first.apply(to: &record)
        #expect(record.active == 7 && record.bad == [7, 9])
        #expect(session.observe(observation(true), elapsed: .seconds(9))?.changedReport == nil)
        // Losing guest health resets the continuous qualification interval.
        #expect(session.observe(observation(false), elapsed: .seconds(10))?.verdict == nil)
        #expect(session.observe(observation(true), elapsed: .seconds(11))?.verdict == nil)
        #expect(session.observe(observation(true), elapsed: .seconds(20))?.verdict == nil)
        let goodUpdate = session.observe(observation(true), elapsed: .seconds(21))
        let good = try #require(goodUpdate)
        #expect(good.verdict == .good(7) && good.changesRecord)
        good.apply(to: &record)
        #expect(record.lastGood == 7 && record.bad == [9] && record.seed == 1 && record.builtIn == 6)
        #expect(
            session.observe(observation(true), elapsed: .seconds(22)) == nil,
            "one boot must never publish a second verdict"
        )
    }

    @Test func neverHealthyIsBadOnceRecorded() throws {
        var session = GuestPackageSession(offer: offer)
        var fresh = DeviceInstance.Guest()
        fresh.seed = 1
        #expect(session.observe(observation(false, report, fresh), elapsed: .seconds(299))?.verdict == nil)
        let failureUpdate = session.observe(observation(false, report, fresh), elapsed: .seconds(300))
        let failure = try #require(failureUpdate)
        #expect(failure.verdict == .bad(7))
        failure.apply(to: &fresh)
        failure.apply(to: &fresh)
        #expect(fresh.bad == [7], "retrying record publication must not duplicate bad serials")
    }

    /// The seed and the last good package are never judged bad.
    @Test(arguments: [Int64(1), Int64(7)])
    func protectedSerialsAreUndecided(_ serial: Int64) throws {
        var record = record
        record.lastGood = 7
        var session = GuestPackageSession(offer: offer)
        let report = GuestPackageReport(serial: serial, result: 0)
        let resultUpdate = session.observe(observation(false, report, record), elapsed: .seconds(300))
        let result = try #require(resultUpdate)
        #expect(result.verdict == .undecided && result.changedReport == report)
        var saved = record
        result.apply(to: &saved)
        #expect(saved.bad == record.bad && saved.active == serial)
    }

    @Test func noReportOnceHealthyIsLegacy() throws {
        var session = GuestPackageSession(offer: offer)
        #expect(session.observe(observation(true, nil, record), elapsed: .seconds(1))?.verdict == nil)
        #expect(session.observe(observation(true, nil, record), elapsed: .seconds(30))?.verdict == nil)
        let legacyUpdate = session.observe(observation(true, nil, record), elapsed: .seconds(31))
        let legacy = try #require(legacyUpdate)
        #expect(legacy.verdict == .legacy && legacy.status == .legacy && !legacy.changesRecord)
        var incompatible = GuestPackageSession(offer: offer)
        var glesTooNew = observation(true)
        glesTooNew.glesProtocol = 100
        #expect(incompatible.observe(glesTooNew, elapsed: .zero)?.status == .outOfDate)
    }

    /// Retirement prevents delayed sampling and publication, and renewal starts fresh state.
    @Test func retiredBootPublishesNothingAndRenewalStartsFresh() async throws {
        let offer = offer
        let report = report
        let healthy = observation(true)
        let scope = BootSessionScope()
        var samples = 0
        var writes = 0
        scope[.guestPackage] = Task {
            await GuestPackageSession.watch(
                offer: offer,
                interval: .milliseconds(100),
                sample: {
                    samples += 1
                    return healthy
                },
                publish: { _ in writes += 1 }
            )
        }
        await Task.yield()
        let retiredTask = try #require(scope[.guestPackage])
        scope.retire()
        await retiredTask.value
        try await Task.sleep(for: .milliseconds(130))
        #expect(samples == 0 && writes == 0, "a retired boot published delayed package state")
        scope.renew()
        scope[.guestPackage] = Task {
            await GuestPackageSession.watch(
                offer: offer,
                interval: .milliseconds(1),
                sample: {
                    samples += 1
                    return samples == 1 ? healthy : nil
                },
                publish: { update in
                    #expect(update.changedReport == report && update.verdict == nil)
                    writes += 1
                }
            )
        }
        await scope[.guestPackage]?.value
        #expect(samples == 2 && writes == 1, "a new boot must not reuse a retired boot's seen report")
        scope.retire()
    }

    @Test func cancellationAfterAReportPreventsTheNextPublication() async throws {
        let offer = offer
        let healthy = observation(true)
        var writes = 0
        let watch = Task {
            await GuestPackageSession.watch(
                offer: offer,
                interval: .milliseconds(30),
                sample: { healthy },
                publish: { _ in writes += 1 }
            )
        }
        for _ in 0..<100 where writes == 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(writes == 1)
        watch.cancel()
        await watch.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(writes == 1, "cancellation after a report must prevent the next publication")
    }

    @Test func missingObservationStopsTheOwner() async {
        var samples = 0
        await GuestPackageSession.watch(
            offer: offer,
            interval: .milliseconds(1),
            sample: {
                samples += 1
                return nil
            },
            publish: { _ in Issue.record("published without an observation") }
        )
        #expect(samples == 1)
    }
}
