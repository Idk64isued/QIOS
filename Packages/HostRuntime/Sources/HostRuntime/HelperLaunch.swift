// How LightTouchDevice starts: this value, as JSON, is its one argument. The helper loads the GPL-2.0-only emulator,
// so it parses no command line of its own (no argument parser links into it); the app, firmwarekit and the harness
// build this instead.
import Foundation

public struct HelperLaunch: Codable, Sendable, Equatable {
    public enum Mode: Codable, Sendable, Equatable {
        /// Spawned by the app (DeviceLink): the link socket is fd 3, the hello goes to `service` with `token`.
        case connect(service: String, token: String, instance: UUID)
        /// Boot, run scripted actions, PNG dumps, status on stdout.
        case headless(config: String)
        /// Boot until QEMU exits or a serial marker (seal/keybag): firmwarekit's preparation boots.
        case oneshot(config: String)
        /// Load the dylib, print the dylib's path and every machine's DeviceInfo.
        case machines
    }

    public var mode: Mode
    /// The device's lease: the hello fails (exit 75) if another process holds its flock.
    public var lease: String?

    public init(_ mode: Mode, lease: String? = nil) {
        self.mode = mode
        self.lease = lease
    }

    /// The helper's arguments (after its path).
    public var arguments: [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // A value of strings and a UUID always encodes.
        return [String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)]
    }

    /// The helper's side: its arguments (after its path) back to the value.
    public init(arguments: [String]) throws {
        guard arguments.count == 1 else {
            throw CocoaError(
                .coderInvalidValue,
                userInfo: [NSLocalizedDescriptionKey: "LightTouchDevice takes one argument, its launch as JSON"]
            )
        }
        self = try JSONDecoder().decode(Self.self, from: Data(arguments[0].utf8))
    }
}
