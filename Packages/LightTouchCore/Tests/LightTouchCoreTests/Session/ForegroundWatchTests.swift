import DeviceRuntime
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// The guest's front app while the device answers (and nothing while it sleeps or an install holds it; a download
/// doesn't),
/// the web proxy applied on each pass, and Setup's end lifting the boot's network restriction once.
struct ForegroundWatchTests {
    struct NoAgent: Error {}

    final class Host: ForegroundHost {
        let bootScope = BootSessionScope()
        let link = RecordingLink()
        var helperLink: HelperLink? { link }
        var canReachDevice = true, isSleeping = false, isInstalling = false, installerUsesDevice = false
        /// AppInstaller has a job for the device (a Legacy Store download, or one waiting for the device).
        var hasPendingInstallWork = false
        var guestAgentAlive = true
        let overlay: URL
        var fronts: [(bundleID: String, name: String?)?] = []
        /// What a poll answers once `fronts` is used up (nil: no agent), so a loaded host can't race past it.
        var settled: (bundleID: String, name: String?)?
        var proxyPasses = 0
        /// Polls left in `fronts` at each tweaks pass.
        var tweakPasses: [Int] = []
        var finished: [Int] = []
        /// Polls still to come when Setup finished.
        var remainingAtFinish: Int?
        init(overlay: URL) { self.overlay = overlay }
        func foregroundApp() async throws -> (bundleID: String, name: String?) {
            if fronts.isEmpty, let settled { return settled }
            guard !fronts.isEmpty, let front = fronts.removeFirst() else { throw NoAgent() }
            return front
        }
        func applyWebProxy(since applied: Int?, generation: Int) async throws -> Int? {
            proxyPasses += 1
            return applied
        }
        func applyTweaks(generation: Int) async throws { tweakPasses.append(fronts.count) }
        func setupFinished(generation: Int) {
            finished.append(generation)
            remainingAtFinish = fronts.count
        }
    }

    func watch(_ host: Host) -> ForegroundWatch {
        let watch = ForegroundWatch(host: host)
        watch.interval = .milliseconds(5)
        return watch
    }

    @Test func theFrontAppNamesTheWindow() async throws {
        try await withScratchDirectory { overlay in
            let host = Host(overlay: overlay)
            host.isSleeping = true
            let watch = watch(host)
            host.settled = ("com.apple.mobilesafari", "Safari")
            watch.start()
            try await Task.sleep(for: .milliseconds(40))
            #expect(watch.appName == nil && host.proxyPasses == 0, "asleep: no polls")
            host.isSleeping = false
            await eventually("Safari") { watch.appName == "Safari" }
            host.settled = nil
            await eventually("the failed poll") { watch.appName == nil }
            #expect(host.proxyPasses >= 2, "the proxy is applied on every pass")
            #expect(host.tweakPasses.count >= 2, "so are the tweaks")
            watch.stop()
        }
    }

    @Test func aDownloadDoesNotHoldTheWatchAnInstallDoes() async throws {
        try await withScratchDirectory { overlay in
            let host = Host(overlay: overlay)
            host.hasPendingInstallWork = true  // a Legacy Store download, not on the device yet
            host.settled = ("com.apple.springboard", "Home")
            let watch = watch(host)
            watch.start()
            await eventually("polled during the download") { watch.appName == "Home" }
            host.installerUsesDevice = true
            try await Task.sleep(for: .milliseconds(20))
            let passes = host.proxyPasses
            try await Task.sleep(for: .milliseconds(40))
            #expect(host.proxyPasses == passes, "an install on the device: no polls")
            watch.stop()
        }
    }

    @Test func setupsEndLiftsTheRestrictionOnce() async throws {
        try await withScratchDirectory { overlay in
            let host = Host(overlay: overlay)
            let watch = watch(host)
            watch.setupGate = BootRecipe.SetupNetworkGate()
            host.fronts = [
                ("com.apple.purplebuddy", "Setup"), ("com.apple.springboard", "Home"), nil,
                ("com.apple.springboard", "Home"), ("com.apple.mobilesafari", "Safari"),
                ("com.apple.springboard", "Home")
            ]
            watch.start()
            await eventually("lifted") { !host.finished.isEmpty }
            await eventually("every poll seen") { host.fronts.isEmpty }
            watch.stop()
            #expect(
                host.link.commands == [.netRestrict(false)] && host.finished == [host.bootScope.generation],
                "once, after two unlocked polls in a row"
            )
            #expect(
                host.remainingAtFinish == 1,
                "the failed poll broke the streak: lifted at Safari, not the Home before it"
            )
            #expect(watch.setupGate == nil)
            #expect(
                FileManager.default.fileExists(atPath: BootRecipe.setupDoneMark(overlay: overlay).path),
                "the overlay remembers Setup is done"
            )
            #expect(
                !host.tweakPasses.isEmpty && host.tweakPasses.allSatisfy { $0 <= host.remainingAtFinish ?? -1 },
                "tweaks wait for Setup's end (\(host.tweakPasses))"
            )
        }
    }

    /// A boot without slirp's restriction (no network) still marks Setup done, so later boots wait for the Home screen.
    @Test func setupsEndIsMarkedWithoutTheRestriction() async throws {
        try await withScratchDirectory { overlay in
            let host = Host(overlay: overlay)
            let watch = watch(host)
            watch.setupGate = BootRecipe.SetupNetworkGate()
            watch.liftsRestrict = false
            host.fronts = [
                ("com.apple.purplebuddy", "Setup"), ("com.apple.springboard", "Home"),
                ("com.apple.springboard", "Home")
            ]
            watch.start()
            await eventually("finished") { !host.finished.isEmpty }
            watch.stop()
            #expect(host.link.commands.isEmpty, "nothing to lift")
            #expect(FileManager.default.fileExists(atPath: BootRecipe.setupDoneMark(overlay: overlay).path))
        }
    }
}
