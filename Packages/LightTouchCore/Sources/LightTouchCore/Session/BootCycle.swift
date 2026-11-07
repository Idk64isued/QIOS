// Restart and Power On in place: a new boot on the same helper (QEMU's system_reset), with every per-boot watch
// started again in the order the first boot started them. A device without a guest to sync through, or whose
// helper is gone, gets a fresh helper instead (DeviceSessionHost.restart).

import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire

/// What a reset and a power-on read and do on the session, each step as the session names it.
public protocol BootCycleHost: AnyObject {
    var bootScope: BootSessionScope { get }
    var state: VMState { get }
    func transition(to next: VMState)
    var storageFailed: Bool { get }
    var shuttingDown: Bool { get }
    /// stop() or release() ran: this controller's boots are over.
    var isReleased: Bool { get }
    var hasGuestTools: Bool { get }
    /// A setting only a fresh helper takes (BootSettings) changed since this helper's boot was built.
    var nextStartChanged: Bool { get }
    var helper: DeviceHelper? { get }
    var helperLink: HelperLink? { get }
    var workers: WorkerRetirement { get }
    var readiness: ReadinessWatch { get }
    var notices: DeviceNotices { get }
    /// The helper's status block, read now.
    var status: SharedStatus? { get }
    /// The guest agent's sync: the guest's filesystems flushed.
    func syncGuest() async throws
    /// Stop's halt, started now (ShutdownLadder.halt).
    @discardableResult func halt() -> Task<Bool, Never>
    func restart()
    func retireBoot()
    func endBoot(_ end: BootEnd)
    // The per-boot steps, in the order a boot takes them.
    /// Everything the last boot learned about its guest, forgotten (BootWatchHost.forgetBootFacts).
    func forgetBootFacts()
    /// usbmuxd runs again if it was given up on (USBMux.ensureRunning).
    func ensureUSBMux()
    func publishDeveloperConnection()
    /// The guest cold-boots portrait, so the tracked orientation (and the iPad's accelerometer) follows it back.
    /// Leaving it at 90/270 left DisplayView posing the shell sideways while the guest published a portrait buffer.
    func resetRotation()
    func startTimeZoneSync()
    func startForegroundWatch()
    /// Auto-rotation: the guest agent's, or springboardservices' where the board has no guest tools.
    func startOrientationWatch()
    func startGuestPackageWatch()
    func startBootWatch()
}

extension BootCycleHost {
    /// A boot begins (a fresh helper's, a Restart's, a Power On's): a new scope and nothing the last boot learned.
    public func beginBoot() {
        bootScope.renew()
        forgetBootFacts()
        ensureUSBMux()
        publishDeveloperConnection()
        resetRotation()
    }

    /// Every watch a boot runs, in order: the one list a fresh helper's boot, a Restart and a Power On all start, so
    /// none of them can leave one out (Power On used to leave auto-rotation off: state audit A-3).
    public func startBootWatches() {
        startTimeZoneSync()
        startForegroundWatch()
        startOrientationWatch()
        readiness.start()
        startGuestPackageWatch()
        startBootWatch()
    }
}

/// What a helper's boot was built with that only a fresh helper changes: the free-form panel, the Internet, the debug
/// port and the boot arguments. Chosen while the device was shut down, they used to wait for a Stop, since Start
/// powered the same helper on (state audit A-4).
public struct BootSettings: Equatable {
    public var panel: String?
    public var network: Bool
    public var debugPort: Bool
    public var bootArgs: String
    public init(panel: String?, network: Bool, debugPort: Bool, bootArgs: String) {
        self.panel = panel
        self.network = network
        self.debugPort = debugPort
        self.bootArgs = bootArgs
    }
}

public final class BootCycle {
    private unowned let host: BootCycleHost
    public init(host: BootCycleHost) { self.host = host }

    /// A power-on waits for the machine before resuming it: no frame ends its boot until then.
    public private(set) var poweringOn = false
    /// Bumped by each power-on: an ending power-on clears `poweringOn` unless a later one owns it.
    private var powerOns = 0
    /// The guest agent's sync before a restart, at most.
    var syncBudget: Double = 20
    /// How long a power-on waits for the PMU reset to clear the shutdown latch.
    var latchWait: Duration = .seconds(5)

    private var isPoweredOff: Bool { host.state == .poweredOff }

    /// A fresh helper's boot is built: it begins, with every watch.
    public func begin() {
        host.beginBoot()
        host.startBootWatches()
    }

    /// Restart the guest. Flush first: a bare system_reset is the same hard cut as a SIGKILL as far as the guest's
    /// filesystem is concerned — it loses the HFS+ catalog updates still in memory, which is how a device ends up on
    /// the Connect-to-iTunes screen.
    public func reset() {
        if isPoweredOff {
            powerOn()
            return
        }
        guard !host.shuttingDown else { return }
        guard !host.storageFailed else { return }
        if host.state == .paused {
            // A paused guest can't sync: resume it first (state audit A-14).
            host.helperLink?.send(.machine(.resume))
            host.transition(to: .running)
        }
        let preparation = host.readiness.current
        preparation?.cancel()
        let generation = host.bootScope.generation
        let syncBudget = syncBudget
        host.bootScope[.reset] = Task { [weak self] in
            guard let self else { return }
            let host = host
            await preparation?.value
            guard !Task.isCancelled, generation == host.bootScope.generation else { return }
            if !host.hasGuestTools {
                // No guest to sync through: a hard halt (storage flushed, the
                // journal replays), then a fresh helper, as Stop then Start.
                _ = await host.halt().value
                host.restart()
                return
            }
            let synced = await withSoftDeadline(syncBudget) { @MainActor in
                do {
                    try await host.syncGuest()
                    return true
                } catch { return false }
            }
            guard !Task.isCancelled, generation == host.bootScope.generation, !host.storageFailed, !host.shuttingDown,
                !host.state.isDead
            else { return }
            guard synced == true else {
                host.notices.report(
                    "Couldn’t restart because the device didn’t finish saving its files.",
                    for: .powerOff
                )
                if host.state == .booting { host.readiness.start() }
                return
            }
            host.notices.resolve(.powerOff)
            host.retireBoot()
            let retiredGeneration = host.bootScope.generation
            // Retirement intentionally cancels this boot's reset task. Finish
            // only this transition after old workers are reaped; a concurrent
            // halt/death prevents renewing the scope.
            await host.workers.task?.value
            guard retiredGeneration == host.bootScope.generation, !host.isReleased, !host.storageFailed,
                !host.shuttingDown,
                !host.state.isDead, host.state != .poweredOff
            else { return }
            host.beginBoot()
            host.helperLink?.send(.machine(.reset))
            host.transition(to: .booting)
            host.startBootWatches()
        }
    }

    /// The machine was kept at guest power-off (-no-shutdown): reset and resume it, without reinitializing QEMU or
    /// opening a second NAND writer. Stopped by a halt, the helper is gone: a fresh one starts; so does one when a
    /// next-start setting changed while it was off, once this helper has quit.
    public func powerOn() {
        guard isPoweredOff, !host.storageFailed, !host.shuttingDown else { return }
        if host.helper?.isDead != false {
            host.restart()
            return
        }
        if host.nextStartChanged {
            logEvent("power on: settings for the next start changed; starting a fresh helper")
            let halt = host.halt()
            let host = host
            Task {
                if await halt.value { host.restart() }
            }
            return
        }
        host.beginBoot()
        poweringOn = true
        powerOns += 1
        let run = powerOns
        host.transition(to: .booting)
        host.helperLink?.send(.machine(.reset))
        let generation = host.bootScope.generation
        let latchWait = latchWait
        host.bootScope[.powerOn] = Task { [weak self] in
            guard let self else { return }
            // However it ends (resumed, given up, or cancelled by a Restart or a halt retiring the boot): a
            // `poweringOn` left set kept frames from ending the next boot (state audit A-10).
            defer { if run == powerOns { poweringOn = false } }
            let host = host
            await host.workers.task?.value
            guard !Task.isCancelled, generation == host.bootScope.generation else { return }
            let deadline = SuspendingClock.now + latchWait
            // system_reset is queued. Wait until the PMU reset clears its
            // shutdown latch (the helper republishes it at 20 Hz) before
            // resuming the stopped VM.
            while host.status?.shutdownConfirmed == true, SuspendingClock.now < deadline {
                // Cancelled (a Restart or a halt retired the boot): end now. A swallowed cancellation spun here,
                // holding the main actor and `poweringOn`, until the latch wait ran out.
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard !Task.isCancelled, generation == host.bootScope.generation else { return }
            guard host.status?.shutdownConfirmed == false, !host.state.isDead else {
                if !host.state.isDead { host.endBoot(.guestPoweredOff) }
                return
            }
            host.helperLink?.send(.machine(.resume))
            host.startBootWatches()
        }
    }
}
