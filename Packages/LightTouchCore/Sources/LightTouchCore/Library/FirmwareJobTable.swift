// Every catalog entry's firmware job as one state, and the only transitions between them. FirmwareJobs runs what
// they ask for (downloads, import checks, preparers) and feeds their events back; nothing here does I/O, so
// FirmwareJobTableTests drives it directly.
//
//   none/failed ── Download and Prepare ─▶ downloading(sha1s) ── every IPSW here ─▶ preparing(job) ─▶ none (a device)
//        │                                                                             │          └─▶ failed(why)
//        └──────── import ─▶ importing(token) ── matched ─▶ preparing(job)              └─ Cancel ─▶ cancelling(job)
//                                                                     ─▶ none once the preparer exits, or a new
//                                                                        preparation if Prepare was asked meanwhile
//
// Downloads outlive the app (a background URLSession); the downloading jobs (`intents`) are saved, and a relaunch
// rebuilds exactly those: never a job for an entry nobody asked for.
//
// Events carry the job they belong to (a sha1, an import token, a PreparationJob id); one for a job the entry no
// longer runs is dropped.

import FirmwareSchema
import Foundation

public nonisolated struct FirmwareJobTable: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Hashing and copying an IPSW imported onto this entry's row.
        case importing(UUID)
        /// Waiting for these IPSWs (the entry's own and, for keybag_ramdisk_from, its sibling's), then preparing.
        case downloading([String])
        /// firmwarekit running as this PreparationJob.
        case preparing(UUID)
        /// That preparer was told to stop and hasn't exited yet. `retry`: Prepare was chosen again meanwhile; it
        /// starts once the old preparer is gone.
        case cancelling(UUID, retry: Bool)
        case failed(String)
    }

    public struct Job: Equatable, Sendable {
        public var phase: Phase
        /// What the row shows; nil while a cancelled preparer exits (the row is back to Prepare).
        public var shown: FirmwareJob?
        /// When the bar's current stretch started and how far along it was, for the time remaining.
        var start: Sample?
        /// The download's last speed sample (when, bytes so far) and its smoothed bytes per second.
        var sample: Sample?
        var speed: Double?
    }
    struct Sample: Equatable, Sendable {
        var date: Date
        var value: Double
    }

    /// What the table asks FirmwareJobs to do.
    public enum Effect: Equatable, Sendable {
        case startDownload(String)
        case cancelDownload(String)
        case cancelImport(UUID)
        case cancelPreparation(UUID)
        /// Every IPSW the entry waits for is here.
        case prepare(String)
        /// The cancelled preparer is gone and Prepare was chosen meanwhile: Download and Prepare again.
        case retry(String)
    }

    public private(set) var jobs: [String: Job] = [:]
    /// Live downloads by sha1: how far each is, and the host it comes from once its first source failed. A download
    /// is shared by every job that waits for its IPSW.
    public private(set) var downloads: [String: Download] = [:]
    public struct Download: Equatable, Sendable {
        public var fraction = 0.0
        public var mirror: String?
    }

    /// IPSWs a relaunch restored whose download task the session hasn't vouched for yet.
    var unconfirmed: Set<String> = []

    /// Catalog facts: each IPSW's size and first host by sha1, each entry's estimated preparation seconds.
    let bytes: [String: Int64]
    let hosts: [String: String]
    let seconds: [String: Int]

    public init(bytes: [String: Int64] = [:], hosts: [String: String] = [:], seconds: [String: Int] = [:]) {
        self.bytes = bytes
        self.hosts = hosts
        self.seconds = seconds
    }

    // MARK: - Reading

    public func phase(_ id: String) -> Phase? { jobs[id]?.phase }
    /// What each entry's row shows.
    public var shown: [String: FirmwareJob] { jobs.compactMapValues(\.shown) }
    /// No job, or a failed one: a new job may start.
    public func isIdle(_ id: String) -> Bool {
        switch jobs[id]?.phase {
        case nil, .failed?: true
        default: false
        }
    }
    /// The downloading jobs and the IPSWs each waits for, to rebuild them after a relaunch.
    public var intents: [String: [String]] {
        jobs.compactMapValues { if case .downloading(let sha1s) = $0.phase { sha1s } else { nil } }
    }
    /// Preparers at work (Quit asks before stopping them).
    public var preparing: Int { jobs.values.count { if case .preparing = $0.phase { true } else { false } } }

    // MARK: - Commands

    /// Download and Prepare or Try Again: true when a new job may start. One asked for while a cancelled preparer is
    /// still exiting is remembered and runs once it is gone; a job under way is left alone.
    public mutating func request(_ id: String) -> Bool {
        switch jobs[id]?.phase {
        case nil, .failed?: return true
        case .cancelling(let job, _)?:
            jobs[id] = Job(phase: .cancelling(job, retry: true), shown: .preparing(.init(name: "Starting")))
            return false
        default: return false
        }
    }

    public mutating func cancel(_ id: String) -> [Effect] {
        switch jobs[id]?.phase {
        case nil: return []
        case .importing(let token)?:
            jobs[id] = nil
            return [.cancelImport(token)]
        case .downloading(let sha1s)?:
            jobs[id] = nil
            // A download another job still waits for goes on.
            let orphaned = sha1s.filter { downloads[$0] != nil && waiting(for: $0).isEmpty }
            for sha1 in orphaned { downloads[sha1] = nil }
            return orphaned.map(Effect.cancelDownload)
        case .preparing(let job)?:
            jobs[id] = Job(phase: .cancelling(job, retry: false))
            return [.cancelPreparation(job)]
        case .cancelling(let job, _)?:
            jobs[id] = Job(phase: .cancelling(job, retry: false))
            return []
        case .failed?:
            jobs[id] = nil
            return []
        }
    }

    public mutating func fail(_ id: String, _ message: String) {
        jobs[id] = Job(phase: .failed(message), shown: .failed(message))
    }

    /// A failed job's row left the sidebar: its error goes with it.
    public mutating func dismiss(_ id: String) {
        if case .failed? = jobs[id]?.phase { jobs[id] = nil }
    }

    /// A job that ends without a device or an error (the entry already has a device).
    public mutating func clear(_ id: String) { jobs[id] = nil }

    // MARK: - Imports

    public mutating func importing(_ id: String, _ token: UUID) {
        jobs[id] = Job(phase: .importing(token), shown: .preparing(.init(name: "Checking the IPSW")))
    }

    /// An import (onto `id`'s row, or the window) matched `matched`: true when that entry is to be prepared now. One
    /// cancelled meanwhile, or matched to an entry with a job under way, prepares nothing (the IPSW stays stored).
    public mutating func imported(_ token: UUID, onto id: String?, matched: String) -> Bool {
        if let id {
            guard jobs[id]?.phase == .importing(token) else { return false }
            jobs[id] = nil
        }
        return isIdle(matched)
    }

    /// An import failed: true when its row shows it (it wasn't cancelled meanwhile).
    public mutating func importFailed(_ token: UUID, onto id: String, _ message: String) -> Bool {
        guard jobs[id]?.phase == .importing(token) else { return false }
        fail(id, message)
        return true
    }

    // MARK: - Downloads

    /// `id` waits for `sha1s` as one job, one bar; returns those with no download yet, for FirmwareJobs to start.
    public mutating func download(_ id: String, _ sha1s: [String]) -> [String] {
        let new = sha1s.filter { downloads[$0] == nil }
        for sha1 in new { downloads[sha1] = Download() }
        jobs[id] = Job(phase: .downloading(sha1s), shown: .downloading(fraction: fraction(sha1s), files: sha1s.count))
        return new
    }

    /// The jobs waiting for this IPSW.
    func waiting(for sha1: String) -> [String] {
        jobs.filter { if case .downloading(let sha1s) = $0.value.phase { sha1s.contains(sha1) } else { false } }
            .keys.sorted()
    }

    /// How far a job's downloads are together, weighted by their sizes; a finished one counts whole.
    func fraction(_ sha1s: [String]) -> Double {
        let weight = { (sha1: String) in Double(max(self.bytes[sha1] ?? 1, 1)) }
        let total = sha1s.reduce(0) { $0 + weight($1) }
        let done = sha1s.reduce(0) { $0 + weight($1) * (self.downloads[$1]?.fraction ?? 1) }
        return total > 0 ? done / total : 0
    }

    /// One IPSW's download event, for every job waiting for it.
    public mutating func download(_ sha1: String, _ event: FirmwareDownloads.Event, now: Date) -> [Effect] {
        let ids = waiting(for: sha1)
        switch event {
        case .progress(let fraction):
            guard downloads[sha1] != nil else { return [] }
            downloads[sha1]?.fraction = fraction
            for id in ids { showDownload(id, now: now) }
        case .mirror(let url): if downloads[sha1] != nil { downloads[sha1]?.mirror = url.host }
        case .resumed, .cancelled: break
        case .finished:
            downloads[sha1] = nil
            // A job with nothing left to fetch prepares; one still fetching its other IPSW waits.
            return ids.filter { id in
                guard case .downloading(let sha1s)? = jobs[id]?.phase else { return false }
                return sha1s.allSatisfy { downloads[$0] == nil }
            }.map(Effect.prepare)
        case .failed(let error):
            downloads[sha1] = nil
            for id in ids { fail(id, error.localizedDescription) }
        }
        return []
    }

    private mutating func showDownload(_ id: String, now: Date) {
        guard case .downloading(let sha1s)? = jobs[id]?.phase else { return }
        let overall = fraction(sha1s)
        // The bar spans the download and the preparation: the time left is both.
        let left = remaining(id, overall, now: now).map { $0 + Double(seconds[id] ?? 0) }
        let total = Double(sha1s.reduce(0) { $0 + (bytes[$1] ?? 0) })
        let mirror = sha1s.compactMap { downloads[$0]?.mirror ?? hosts[$0] }.first.flatMap(FirmwareJob.thirdParty)
        let speed = speed(id, bytes: overall * total, now: now)
        jobs[id]?.shown = .downloading(
            fraction: overall,
            remaining: left,
            files: sha1s.count,
            mirror: mirror,
            speed: speed
        )
    }

    /// Bytes per second over the last few seconds of a job's download; nil until measured.
    private mutating func speed(_ id: String, bytes: Double, now: Date) -> Double? {
        guard let sample = jobs[id]?.sample else {
            jobs[id]?.sample = Sample(date: now, value: bytes)
            return nil
        }
        let elapsed = now.timeIntervalSince(sample.date)
        if elapsed >= 3 {
            let rate = max(0, bytes - sample.value) / elapsed
            // Smoothed, so one slow interval doesn't swing it.
            let smoothed = jobs[id]?.speed.map { $0 * 0.6 + rate * 0.4 } ?? rate
            jobs[id]?.speed = smoothed
            jobs[id]?.sample = Sample(date: now, value: bytes)
        }
        return jobs[id]?.speed
    }

    /// Seconds left from this stretch's start (the first report of a resumed download) to `fraction` now.
    private mutating func remaining(_ id: String, _ fraction: Double, now: Date) -> TimeInterval? {
        guard let start = jobs[id]?.start else {
            jobs[id]?.start = Sample(date: now, value: fraction)
            return nil
        }
        return estimatedRemaining(elapsed: now.timeIntervalSince(start.date), from: start.value, to: fraction)
    }

    // MARK: - Relaunch

    /// Launch: the last launch's downloading jobs (`intents`) as jobs again; `stored`: the IPSWs already here.
    public mutating func restore(_ intents: [String: [String]], stored: Set<String>) {
        for (id, sha1s) in intents where jobs[id] == nil {
            for sha1 in sha1s where !stored.contains(sha1) && downloads[sha1] == nil {
                downloads[sha1] = Download()
                unconfirmed.insert(sha1)
            }
            jobs[id] = Job(
                phase: .downloading(sha1s),
                shown: .downloading(fraction: fraction(sha1s), files: sha1s.count)
            )
        }
    }

    /// The session's download tasks (by sha1), once it has said: a restored download with no task starts again, and a
    /// restored job whose IPSWs all landed while the app was closed prepares. A task no job waits for finishes into the
    /// store and nothing else.
    public mutating func resume(tasks: Set<String>) -> [Effect] {
        let restart = unconfirmed.filter { !tasks.contains($0) && downloads[$0] != nil }.sorted()
        unconfirmed = []
        let ready = jobs.filter {
            if case .downloading(let sha1s) = $0.value.phase {
                sha1s.allSatisfy { downloads[$0] == nil }
            } else {
                false
            }
        }.keys.sorted()
        return restart.map(Effect.startDownload) + ready.map(Effect.prepare)
    }

    // MARK: - Preparations

    /// False while a preparer for `id` runs or is still exiting.
    public func mayPrepare(_ id: String) -> Bool {
        switch jobs[id]?.phase {
        case .preparing?, .cancelling?: false
        default: true
        }
    }

    /// `afterDownload`: the job's download filled the first half of its bar.
    public mutating func preparing(_ id: String, _ job: UUID, afterDownload: Bool, now: Date) {
        jobs[id] = Job(
            phase: .preparing(job),
            shown: .preparing(.init(name: "Starting", startsAt: afterDownload ? 0.5 : 0)),
            start: Sample(date: now, value: 0)
        )
    }

    private mutating func update(_ id: String, now: Date, _ change: (inout Preparation) -> Void) {
        guard case .preparing(var p)? = jobs[id]?.shown else { return }
        change(&p)
        if let overall = p.overall { p.remaining = remaining(id, overall, now: now) } else { p.remaining = nil }
        jobs[id]?.shown = .preparing(p)
    }

    /// One of preparer `job`'s events; dropped unless `id` still runs that preparer.
    public mutating func preparation(_ id: String, _ job: UUID, _ event: PreparationJob.Event, now: Date) -> [Effect] {
        switch jobs[id]?.phase {
        case .preparing(let current)? where current == job:
            let update = { (table: inout Self, change: (inout Preparation) -> Void) in
                table.update(id, now: now, change)
            }
            switch event {
            case .begin(let seconds): update(&self) { $0.seconds = seconds }
            case .step(let index, let count, let name):
                update(&self) {
                    $0.step = index
                    $0.steps = count
                    $0.name = name
                    $0.fraction = 0
                    $0.detail = nil
                }
            case .progress(let fraction, let detail):
                update(&self) {
                    $0.fraction = fraction
                    $0.detail = detail ?? $0.detail
                }
            case .warning: break
            case .published, .cancelled: jobs[id] = nil
            case .failed(let message): fail(id, message)
            }
        case .cancelling(let current, let retry)? where current == job:
            switch event {
            case .begin, .step, .progress, .warning: break
            // Too late to stop: the device is there.
            case .published: jobs[id] = nil
            case .failed, .cancelled:
                jobs[id] = nil
                if retry { return [.retry(id)] }
            }
        default: break
        }
        return []
    }
}
