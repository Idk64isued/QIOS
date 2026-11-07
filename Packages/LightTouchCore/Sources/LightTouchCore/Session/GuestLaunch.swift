// The session's guest-facing flows that need nothing but their inputs: opening an app (the wake before it) and
// composing the boot's guest-package offer.

import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire

/// What opening an app reads and does on the session.
public protocol AppLaunchHost: AnyObject {
    var profile: Board { get }
    /// The guest takes input (running, prepared, not stopping).
    var acceptsInput: Bool { get }
    var isSleeping: Bool { get }
    /// The emulated backlight, from the helper's status block.
    var displaySleeping: Bool? { get }
    func pressHome()
    /// Throws until usbmuxd is up (EmulatorController.services).
    func checkServices() throws
    var guestAgentAlive: Bool { get }
    /// The agent's launch (GuestServices.launch): AppLaunchError.locked when SpringBoard refuses a locked device.
    func launchInGuest(_ bundleID: String) async throws
}

extension AppLaunchHost {
    /// Open an app, waking a sleeping display first with the hardware Home button. SpringBoard still enforces the
    /// Lock Screen and any passcode when the launch is requested. Typed launch errors (and a cancellation) reach the
    /// caller unchanged.
    public func launchApp(_ bundleID: String) async throws {
        guard acceptsInput else { throw AppLaunchError.unavailable }
        if isSleeping {
            pressHome()
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(100))
                guard acceptsInput else { throw AppLaunchError.unavailable }
                if displaySleeping != true { break }
            }
        }
        try checkServices()
        guard guestAgentAlive else {
            throw DeviceToolsError.failed("Open it from the \(profile.shortName)’s Home screen.")
        }
        try await launchInGuest(bundleID)
    }
}

public enum GuestOfferComposition {
    /// This boot's offer: with the optional developer additions when `augmentation` has them, and without them when
    /// those fail (optional developer access must not suppress required additions). nil when even the required
    /// package can't be composed: the device keeps what it runs.
    public static func offer<Augment>(
        augmentation: Augment?,
        compose: (Augment?) throws -> GuestPackage.Offer?
    ) -> GuestPackage.Offer? {
        do {
            do {
                return try compose(augmentation)
            } catch  where augmentation != nil {
                logEvent("developer tools: not offered: \(error.localizedDescription)")
                return try compose(nil)
            }
        } catch {
            logEvent("guest package: no offer: \(error.localizedDescription)")
            return nil
        }
    }
}
