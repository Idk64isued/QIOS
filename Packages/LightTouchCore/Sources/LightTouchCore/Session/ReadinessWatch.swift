// From the boot until SpringBoard answers over lockdown: the startup status the window shows, how far the boot has
// provably got (BootStage), and the one display wake a boot gets before input is enabled.

import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Observation

/// What the readiness watch reads and does on the session.
public protocol ReadinessHost: AnyObject {
    var bootScope: BootSessionScope { get }
    var profile: Board { get }
    var shuttingDown: Bool { get }
    var isDead: Bool { get }
    var storageFailed: Bool { get }
    /// The display has painted frames this boot (state == .running).
    var isPainting: Bool { get }
    /// Whether boot time counts toward the deadline now (HostPower.countsBootTime).
    var countsBootTime: Bool { get }
    /// The helper's status block, read now.
    var status: SharedStatus? { get }
    /// This boot ends in Setup (iOS 5+, not yet set up), not the Home screen.
    var expectsSetup: Bool { get }
    /// The USB bridge sees the guest.
    func deviceReady() async -> Bool
    /// SpringBoard answers (its layout service, or with `agentCounts` the agent naming its screen frontmost).
    func waitForSpringBoard(agentCounts: Bool) async throws
    func pressHome()
    /// SpringBoard answered over lockdown: a real round trip, so the device is reachable.
    func readyForInput()
}

@Observable public final class ReadinessWatch {
    private unowned let host: ReadinessHost
    private let notices: DeviceNotices
    /// Fired with the old value when `preparingDevice` is set (the startup clock).
    @ObservationIgnored public var onPreparingChange: ((Bool) -> Void)?
    /// The board's boot budget (shorter in tests).
    @ObservationIgnored var budget: Duration

    public init(host: ReadinessHost, notices: DeviceNotices) {
        self.host = host
        self.notices = notices
        budget = .seconds(host.profile.bootBudget)
    }

    /// From the boot until SpringBoard answers; the status line says where it is.
    public internal(set) var preparingDevice = false { didSet { onPreparingChange?(oldValue) } }
    public private(set) var preparationStatus = "Starting iOS…"
    /// How far this boot has provably got (BootStage): the boot toast's subtitle.
    public private(set) var bootStage = BootStage.poweringOn {
        didSet { if oldValue != bootStage { logEvent("boot: \(bootStage.text)") } }
    }
    public func noteBoot(_ event: BootStage.Event) { bootStage = bootStage.after(event) }
    /// The loader's report when this boot began: a reset keeps the last boot's, which proves nothing now.
    public private(set) var reportAtBootStart: GuestPackageReport?
    public private(set) var readinessFailure: String?

    /// The readiness deadline's verdict now (ReadinessDeadline): frames painted, and how far the boot got.
    public var deadlineVerdict: ReadinessDeadline {
        ReadinessDeadline.verdict(painted: host.isPainting, stage: bootStage)
    }

    public func setStatus(_ status: String) { preparationStatus = status }

    /// SpringBoard didn't answer within one wait: the screen is the user's, the apps and files wait.
    public static func springBoardNotice(shortName: String) -> String {
        "Apps and files will be available when the \(shortName) finishes starting."
    }

    private var task: Task<Void, Never>? {
        get { host.bootScope[.readiness] }
        set { host.bootScope[.readiness] = newValue }
    }
    /// Bumped by each start(): a watch clears `preparingDevice` as it ends unless a later start() owns it.
    @ObservationIgnored private var run = 0
    public func cancel() { task?.cancel() }
    /// Waits for this boot's watch (a restart lets it finish first).
    public var current: Task<Void, Never>? { task }

    /// The boot's readiness steps, shown as the startup status until the Home screen answers: lockdown, then
    /// SpringBoard.
    public func start() {
        guard !host.shuttingDown else { return }
        task?.cancel()
        run += 1
        let run = run
        preparingDevice = true
        preparationStatus = "Starting iOS…"
        bootStage = .poweringOn
        reportAtBootStart = host.status?.guestPackage
        readinessFailure = nil
        let generation = host.bootScope.generation
        let budget = budget
        task = Task { [weak self] in
            guard let self else { return }
            let host = host
            // Every way a boot ends (Shut Down, Force Stop, the guest powering off, a crash) retires its scope, which
            // ends this watch: the startup banner goes with it, not only when this boot's generation is still current.
            defer { if run == self.run { self.preparingDevice = false } }
            do {
                var deadline: BootBudget? = BootBudget(budget)
                while true {
                    try Task.checkCancellation()
                    guard generation == host.bootScope.generation else { return }
                    guard !host.isDead, !host.storageFailed else {
                        throw DeviceToolsError.failed("The \(host.profile.shortName) didn’t become ready in time.")
                    }
                    if deadline?.tick(counting: host.countsBootTime) == true {
                        guard deadlineVerdict == .keepRunning else {
                            throw DeviceToolsError.failed("The \(host.profile.shortName) didn’t become ready in time.")
                        }
                        // iOS is on screen without USB: the screen is the user's; keep waiting for USB, quietly.
                        deadline = nil
                        preparingDevice = false
                        notices.report(ReadinessDeadline.notice(shortName: host.profile.shortName), for: .preparation)
                    }
                    if host.isPainting, await host.deviceReady() { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
                try Task.checkCancellation()
                guard generation == host.bootScope.generation else { return }
                noteBoot(.usbAttached)
                preparationStatus = host.expectsSetup ? "Waiting for Setup…" : "Waiting for the Home screen…"
                // A framebuffer and lockdown can both respond while SpringBoard
                // is still starting. Do not enable input until SpringBoard answers,
                // unless it takes longer than one wait: then the screen is live and
                // the user's (7.x's first boot: Setup's springboardservices refuses and
                // the guest agent starts in launchd's throttled band, minutes late
                // on a loaded Mac). Keep asking; the answer makes the device ready.
                while true {
                    do {
                        try await host.waitForSpringBoard(agentCounts: true)
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        guard generation == host.bootScope.generation, !host.isDead, !host.shuttingDown else { return }
                        guard !host.storageFailed else { throw error }
                        if preparingDevice {
                            logEvent("boot: SpringBoard hasn’t answered yet; input enabled, still waiting")
                            preparingDevice = false
                            notices.report(Self.springBoardNotice(shortName: host.profile.shortName), for: .preparation)
                        }
                    }
                }
                try Task.checkCancellation()
                guard generation == host.bootScope.generation else { return }
                // Read the emulated backlight, not sblaunch's optional lock
                // query: older bundled images do not implement that command.
                // Home is safe while the display is off; an awake Home screen
                // must not receive it (that would open Spotlight). Once per boot.
                guard !host.isDead, !host.shuttingDown else { return }
                if host.status?.displaySleeping == true {
                    logEvent("boot: waking the display after device preparation")
                    host.pressHome()
                    for _ in 0..<20 {
                        try await Task.sleep(for: .milliseconds(100))
                        guard generation == host.bootScope.generation, !host.isDead, !host.shuttingDown else { return }
                        if host.status?.displaySleeping != true { break }
                    }
                }
                try Task.checkCancellation()
                guard generation == host.bootScope.generation, !host.isDead, !host.shuttingDown else { return }
                logEvent("boot: ready for input")
                // SpringBoard answered over lockdown: a real round trip, so the device is reachable
                // without waiting for the Apps inspector's poll (the foreground watch, web proxy and
                // guest-package verdict key off it).
                host.readyForInput()
                notices.resolve(.preparation)
            } catch {
                if !Task.isCancelled, generation == host.bootScope.generation {
                    readinessFailure = error.localizedDescription
                    notices.report(
                        "The \(host.profile.shortName) didn’t finish starting. Restart it to try again.",
                        for: .preparation
                    )
                    logEvent("boot: readiness failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
