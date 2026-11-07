// Settings ▸ General ▸ ANGLE renderer: a device started with it on draws its GL through ANGLE on Metal instead of the
// system's OpenGL (PreparedDeviceBoot's angle, the machine's gl-renderer=angle). Experimental: snapshots of a device
// on it aren't saved (the emulator refuses them).

import Foundation

public nonisolated enum ANGLERenderer {
    /// UserDefaults key for the toggle (off unless turned on).
    public static let key = "ExperimentalANGLERenderer"
    /// Whether the next device start gets it.
    public static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
}
