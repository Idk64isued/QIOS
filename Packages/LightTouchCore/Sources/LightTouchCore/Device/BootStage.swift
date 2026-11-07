// Where a boot stands, from what the device has shown: serial lines, the guest tools reporting in, USB.
// Never a timer. Pure Foundation; LightTouchCoreTests' BootStageTests.

import Foundation

public nonisolated enum BootStage: Int, Comparable, Sendable {
    /// Nothing from the device yet.
    case poweringOn
    /// iBoot is up and loading the kernel.
    case loading
    /// The kernel printed its banner (serial, with the kernel console on).
    case kernel
    /// iOS userland runs: launchd on serial, the guest tools' loader or agent.
    case system
    /// The USB bridge sees the device; lockdown and the Home screen are next.
    case usb

    /// What the device proved, in the order a boot shows it.
    public enum Event: Equatable, Sendable {
        /// A phrase from `serialMarkers`, the first time the serial log prints it.
        case serial(String)
        case guestTools
        case usbAttached
    }

    /// The serial log phrases the watch reports, and the stage each proves. Whichever the board prints:
    /// iBoot-204 has no banner, and the kernel's own lines need the kernel console.
    public static let serialMarkers: [String: BootStage] = [
        ":: iBoot for": .loading,
        "Loading kernel cache": .loading,
        "Darwin Kernel Version": .kernel,
        "iBoot version: ": .kernel,  // the kernel's line, not iBoot's
        "launchd[1] has started up": .system
    ]

    /// Stages only move forward: a late marker never takes the boot back.
    public func after(_ event: Event) -> BootStage {
        let reached: BootStage? =
            switch event {
            case .serial(let phrase): Self.serialMarkers[phrase]
            case .guestTools: .system
            case .usbAttached: .usb
            }
        return max(self, reached ?? self)
    }

    /// The boot toast's subtitle, under "Starting iOS…".
    public var text: String { text(expectingSetup: false) }
    /// `expectingSetup`: this boot ends in Setup (iOS 5+, not yet set up), not the Home screen.
    public func text(expectingSetup: Bool) -> String {
        switch self {
        case .poweringOn: "Powering on"
        case .loading: "Loading iOS"
        case .kernel: "Starting the system"
        case .system: "Connecting over USB"
        case .usb: expectingSetup ? "Waiting for Setup" : "Waiting for the Home screen"
        }
    }

    public static func < (a: BootStage, b: BootStage) -> Bool { a.rawValue < b.rawValue }
}

/// What the board's boot budget does to a device whose USB hasn't answered by then.
public nonisolated enum ReadinessDeadline: Equatable, Sendable {
    /// iOS is up and showing a picture: keep it running, and say which services wait for USB.
    case keepRunning
    /// No picture from iOS (nothing, or only iBoot's logo on a boot that never got further): stop it.
    case stop

    /// `painted`: the display has shown frames this boot; `stage`: how far the boot has provably got.
    /// A painted display alone is not enough, because iBoot lights it too.
    public static func verdict(painted: Bool, stage: BootStage) -> ReadinessDeadline {
        painted && stage >= .system ? .keepRunning : .stop
    }

    public static func notice(shortName: String) -> String {
        "Apps and files will be available when the \(shortName) connects."
    }
}

/// Whether SpringBoard is up by what the guest agent names frontmost: its own screens (lock, Home, Setup's
/// slide) or Setup Assistant over it. An app in front, or no answer, says nothing about readiness at boot.
public nonisolated enum SpringBoardAnswer {
    public static func up(frontmost bundleID: String?) -> Bool {
        bundleID == "com.apple.springboard" || bundleID == "com.apple.purplebuddy"
    }
}
