import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Observation
import Testing
import os

@testable import LightTouchCore

/// Whether `body` changes anything `read` reads, as Observation reports it (at the change, synchronously).
func observes(_ read: () -> Void, during body: () throws -> Void) rethrows -> Bool {
    let raised = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking(read) { raised.withLock { $0 = true } }
    try body()
    return raised.withLock { $0 }
}

/// A fresh directory under the temporary directory for an async body, removed afterwards.
func withScratchDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ltm-tests-" + UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

/// Polls `condition` every 5 ms; a guard (30 s unless `within` says otherwise) turns a hang into a failure instead
/// of a stuck run.
func eventually(
    _ what: String,
    within seconds: TimeInterval = 30,
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline {
            Issue.record("timed out waiting: \(what)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// The helper's link, recorded: commands in order, requests answered `ok(answer)` at once or held for the test.
final class RecordingLink: HelperLink {
    var commands: [LinkCommand] = []
    var requests: [LinkRequest] = []
    /// nil: replies are held in `pending` for the test to deliver.
    var answer: Bool? = true
    var pending: [DeviceLink.Reply] = []
    var onCommand: ((LinkCommand) -> Void)?
    func send(_ command: LinkCommand) {
        commands.append(command)
        onCommand?(command)
    }
    func request(_ request: LinkRequest, timeout: TimeInterval, reply: @escaping DeviceLink.Reply) {
        requests.append(request)
        if let answer { reply(.success(.ok(answer))) } else { pending.append(reply) }
    }
}

/// A device helper: SIGTERM exits it a little later (unless hung); SIGKILL always does.
final class FakeHelper: DeviceHelper {
    var hung = false, terms = 0, kills = 0, isDead = false
    /// Outlives even SIGKILL (a wedged process, as far as the halt can tell).
    var unkillable = false
    var onExit: (() -> Void)?
    func terminate() {
        terms += 1
        guard !hung else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            self.exit()
        }
    }
    func kill() {
        kills += 1
        if !unkillable { exit() }
    }
    func exit() {
        guard !isDead else { return }
        isDead = true
        onExit?()
    }
    func waitForExit(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isDead, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return isDead
    }
}

/// A helper status block: the backlight and the shutdown latch, the rest zero.
func helperStatus(displaySleeping: Bool = false, shutdownConfirmed: Bool = false) -> SharedStatus {
    SharedStatus(
        heartbeat: 0,
        frameSerial: 0,
        width: 0,
        height: 0,
        ringGeneration: 0,
        uiReady: true,
        storageFailed: false,
        shutdownConfirmed: shutdownConfirmed,
        displaySleeping: displaySleeping,
        agentStatus: 0,
        glesContexts: 0,
        iconGeneration: 0,
        qemuState: .running,
        exitCode: 0,
        helperPID: 0
    )
}

/// The session's state machines wired as EmulatorController wires them, around fakes for the helper, its link,
/// lockdown and the guest. Every host step the machines take is recorded in `steps`, in order.
final class FakeSession: MachineHost, ConnectionHost, ActivationServices, ReadinessHost, BootWatchHost, ShutdownHost,
    EraseHost, BootCycleHost, AppLaunchHost
{
    let directory: URL
    let profile: Board
    let bootScope = BootSessionScope()
    let workers = WorkerRetirement()
    var steps: [String] = []

    init(directory: URL, profile: Board = .n72) {
        self.directory = directory
        self.profile = profile
    }

    // MARK: Core pieces, as the controller holds them
    lazy var settingsFile = DeviceSettingsFile(directory: directory)
    lazy var notices = DeviceNotices(settings: settingsFile, shortName: profile.shortName) { [unowned self] in
        storageFailed
    }
    lazy var readiness = ReadinessWatch(host: self, notices: notices)
    lazy var recovery = ConnectionRecovery(host: self, notices: notices)
    lazy var activation: ActivationCheck = {
        let activation = ActivationCheck(
            host: self,
            services: self,
            recovery: recovery,
            readiness: readiness,
            notices: notices
        )
        activation.retryDelay = .milliseconds(5)
        return activation
    }()
    lazy var ladder = ShutdownLadder(host: self)
    lazy var bootWatch = BootWatch(host: self)
    lazy var eraser = DeviceErase(host: self)
    lazy var cycle = BootCycle(host: self)
    lazy var hostPower = HostPower(host: self) {}
    var countsBootTime: Bool { hostPower.countsBootTime }

    // MARK: State
    var state = VMState.booting
    func transition(to next: VMState) { state.transition(to: next) }
    var storageFailed = false
    var shuttingDown: Bool { ladder.shuttingDown }
    var halting: Bool { ladder.halting }
    var isDead: Bool { state.isDead }
    var isErasing = false
    var started = true
    var isReleased = false
    var hasGuestTools = true
    var nextStartChanged = false
    var filesMeddled = false
    var fakeHelper: FakeHelper? = FakeHelper()
    var helper: DeviceHelper? { fakeHelper }
    let link = RecordingLink()
    var linkUp = true
    var helperLink: HelperLink? { linkUp ? link : nil }
    var status: SharedStatus? = helperStatus()
    var bootFinished = false

    /// As EmulatorController.deviceReachable's didSet: a service answer clears the standing issue; every change
    /// considers a recovery and the activation check.
    var deviceReachable: Bool? {
        didSet {
            if deviceReachable == true { recovery.servicesAnswered() }
            recovery.consider()
            activation.checkIfNeeded()
        }
    }
    var isRunning = true
    var preparingDevice: Bool { readiness.preparingDevice }
    var bootStage: BootStage { readiness.bootStage }
    var isInstalling = false, hasFileTransfer = false, installerUsesDevice = false
    var liveAgentStatus = 1
    var guestAgentAlive = true
    var recoveries = 0
    func reconnectManagement() async throws { recoveries += 1 }
    func appsMayHaveChanged() { steps.append("appsChanged") }

    // MARK: Lockdown (ActivationServices)
    var activationAnswers: [String?] = [], activationAsked = 0
    func activationState() async -> String? {
        activationAsked += 1
        return activationAnswers.isEmpty ? nil : activationAnswers.removeFirst()
    }
    var finished = 0, completionFailures = 0
    func finishActivation() async throws {
        finished += 1
        if completionFailures > 0 {
            completionFailures -= 1
            throw CocoaError(.fileReadUnknown)
        }
    }
    var servicesAnswer = false, probed = 0
    func installProxyReady() async -> Bool {
        probed += 1
        return servicesAnswer
    }

    // MARK: Readiness
    var isPainting: Bool { state == .running }
    var usbAnswers = true
    var onDeviceReady: (() -> Void)?
    func deviceReady() async -> Bool {
        onDeviceReady?()
        return usbAnswers
    }
    var springBoardReady = true, springBoardChecks = 0
    /// As DeviceApps.waitForSpringBoard's deadline: one wait gives up after this (nil: never).
    var springBoardWait: Duration?
    var expectsSetup = false
    func waitForSpringBoard(agentCounts: Bool) async throws {
        springBoardChecks += 1
        let deadline = springBoardWait.map { ContinuousClock.now + $0 }
        while !springBoardReady {
            if let deadline, ContinuousClock.now >= deadline {
                throw DeviceToolsError.failed("The Home screen didn’t come back.")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    var homes = 0
    /// Home lights the display (the emulated backlight), and the device keeps taking input after it.
    var homesWake = true, acceptsInputAfterHome = true
    /// Whether input was still held back each time Home was pressed.
    var preparingAtHome: [Bool] = []
    func pressHome() {
        homes += 1
        preparingAtHome.append(readiness.preparingDevice)
        if !acceptsInputAfterHome { acceptsInput = false }
        if homesWake, let status {
            self.status = helperStatus(displaySleeping: false, shutdownConfirmed: status.shutdownConfirmed)
        }
    }
    func readyForInput() { deviceReachable = true }

    // MARK: Retirement and teardown
    var timeZoneStops = 0
    /// The retired boot's services worker; `hangWorker`: one whose teardown never finishes.
    var hangWorker = false
    func retireBoot() {
        guard !bootScope.retired else { return }
        steps.append("retire")
        timeZoneStops += 1
        bootScope.retire()
        let hang = hangWorker
        workers.chain { if hang { try? await Task.sleep(for: .seconds(3600)) } }
    }
    func releaseBootResources() { steps.append("release") }
    func willStop() { steps.append("willStop") }

    // MARK: Erase
    var eraseTargetsOverride: DeviceErase.Targets?
    var eraseTargets: DeviceErase.Targets {
        eraseTargetsOverride
            ?? DeviceErase.Targets(
                overlay: directory.appendingPathComponent("overlay"),
                snapshots: ["snapshot", "snapshot.tmp", "snapshot.bad"].map { directory.appendingPathComponent($0) },
                preparedNOR: directory.appendingPathComponent("nor.bin"),
                state: directory,
                owner: UUID()
            )
    }
    func discardInstalls() { steps.append("discard") }
    func stopGuestWatches() { steps.append("stopWatches") }
    @discardableResult func halt() -> Task<Bool, Never> { ladder.halt() }
    var onRestart: (() -> Void)?
    func restart() {
        steps.append("restart")
        onRestart?()
    }

    // MARK: Boot cycle steps
    var syncFails = false
    var beforeSyncReturns: (() -> Void)?
    var syncs = 0
    func syncGuest() async throws {
        syncs += 1
        beforeSyncReturns?()
        if syncFails { throw CocoaError(.fileReadUnknown) }
    }
    func publishDeveloperConnection() { steps.append("publish") }
    func ensureUSBMux() { steps.append("ensureUSBMux") }
    /// As EmulatorController.forgetBootFacts, for the facts the fake holds.
    func forgetBootFacts() {
        steps.append("forgetBootFacts")
        isSleeping = false
        deviceReachable = nil
        recovery.forget()
    }
    func endBoot(_ end: BootEnd) { bootWatch.endBoot(end) }
    func resetRotation() { steps.append("resetRotation") }
    func startTimeZoneSync() { steps.append("timeZone") }
    func startForegroundWatch() { steps.append("foreground") }
    func startOrientationWatch() { steps.append("orientation") }
    func startGuestPackageWatch() { steps.append("guestPackage") }
    func startBootWatch() { steps.append("bootWatch") }
    func resyncTimeZone() { steps.append("resyncTimeZone") }

    // MARK: App launch
    var acceptsInput = true, isSleeping = false
    var displaySleeping: Bool? { status?.displaySleeping }
    var servicesUp = true
    func checkServices() throws {
        if !servicesUp { throw DeviceToolsError.failed("The device is not reachable over USB yet.") }
    }
    var launched: [String] = [], launchFailure: Error?
    func launchInGuest(_ bundleID: String) async throws {
        launched.append(bundleID)
        if let launchFailure { throw launchFailure }
    }
}
