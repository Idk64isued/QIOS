// The Tweaks panel (Device ▸ Tweaks…): one device's TweakSettings, saved as they change and applied by its session
// (DeviceTweaks) when it runs; its hidden apps, opened through the guest agent while it runs; and the window's finger
// dots, the touches every firmware shows.

import Foundation
import Observation

@Observable public final class TweaksPanelModel {
    public private(set) var tweaks: DeviceTweaks
    /// The running session's guest services; nil while the device is stopped.
    @ObservationIgnored private var guest: GuestServices?
    /// Show Finger Dots, the window's (MainWindowController's toggle); nil where there's no window to show them.
    @ObservationIgnored public var fingerDots: (get: () -> Bool, set: (Bool) -> Void)?

    public init(tweaks: DeviceTweaks, guest: GuestServices?) {
        self.tweaks = tweaks
        self.guest = guest
    }

    /// The device started, stopped or was replaced: its tweaks and its guest now.
    public func rebind(tweaks: DeviceTweaks, guest: GuestServices?) {
        let started = guest != nil && self.guest == nil
        self.tweaks = tweaks
        self.guest = guest
        if guest == nil || started { hiddenApps = nil }
    }

    public var isRunning: Bool { guest != nil }
    /// The hidden apps open through the guest agent, which iPhone OS 1.x doesn't run.
    public var opensHiddenApps: Bool { tweaks.guestTools }
    public var settings: TweakSettings { tweaks.settings }

    public func isOn(_ tweak: Tweak) -> Bool { settings.isOn(tweak) }
    public func isAvailable(_ tweak: Tweak) -> Bool { tweaks.isAvailable(tweak) }
    public func caption(_ tweak: Tweak) -> String { tweak.caption(version: tweaks.version) }
    public func note(_ tweak: Tweak) -> String? { tweaks.note(tweak) }

    public func set(_ tweak: Tweak, on: Bool) {
        guard isAvailable(tweak) || !on else { return }
        tweaks.change { if on { $0.on.insert(tweak) } else { $0.on.remove(tweak) } }
    }

    public func set(coreAnimationColor: CoreAnimationColor) {
        tweaks.change { $0.coreAnimationColor = coreAnimationColor }
    }
    public func set(clock: Date) { tweaks.change { $0.clock = clock } }
    public func setStatusBar(_ change: (inout StatusBarStyle) -> Void) { tweaks.change { change(&$0.statusBar) } }

    /// Marketing Status Bar sets the carrier: every SpringBoard but 1.0's.
    public var statusBarSetsCarrier: Bool { StatusBarStyle.takesCarrier(version: tweaks.version) }
    /// Marketing Status Bar sets the bars, battery and indicators one by one: UIKit's overrides (4.2 on). 2.0 to 4.1
    /// SpringBoard draws them full or real (SBFakeBars).
    public var statusBarSetsEach: Bool { !StatusBarStyle.takesKeys(version: tweaks.version) }
    public var hasCellular: Bool { tweaks.cellular }

    /// What the panel says under the switches: why the session couldn't apply something.
    public var status: String? {
        if let message { return message }
        if let failure = tweaks.failure ?? tweaks.mountFailure ?? tweaks.stoppedFailure { return failure }
        let old = tweaks.needsNewerGuestTools.map(\.title)
        guard !old.isEmpty else { return nil }
        return "\(old.joined(separator: " and ")) needs newer guest tools. Restart the device to update them "
            + "(iOS 7: prepare it again)."
    }
    public private(set) var message: String?

    // MARK: Hidden apps

    /// The hidden apps this running device has; nil until listed (or while stopped).
    public private(set) var hiddenApps: [HiddenApp]?

    public func listHiddenApps() async {
        guard let guest, opensHiddenApps, hiddenApps == nil else { return }
        do { hiddenApps = try await HiddenApp.present(on: guest) } catch {
            message = "Couldn’t list the hidden apps: \(error.localizedDescription)"
        }
    }

    public func open(_ app: HiddenApp) async {
        guard let guest, opensHiddenApps else { return }
        do {
            try await guest.launch(app.bundleID)
            message = nil
        } catch let error as AppLaunchError {
            message =
                switch error {
                case .locked: "Unlock the device, then open \(app.name) again."
                case .unavailable: "Wait for the device to finish starting, then try again."
                case .failed: "\(app.name) didn’t open."
                }
        } catch {
            message = "\(app.name) didn’t open."
        }
    }
}
