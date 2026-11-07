import Foundation

/// Resolve consent before QEMU can send any guest traffic. Loopback USB and
/// Mac-side app downloads remain available when guest networking is off.
public enum NetworkAccessPreference {
    public static let key = "guestNetworkEnabled"

    /// Whether the device about to start gets the Mac's network without asking: `--network`/`--no-network`
    /// on the command line (a choice that is not remembered), else the saved answer; nil when there is neither
    /// and the user is asked (NetworkAccessPrompt).
    public static func decided(arguments: [String] = CommandLine.arguments, defaults: UserDefaults = .standard) -> Bool?
    {
        if arguments.contains("--no-network") { return false }
        if arguments.contains("--network") { return true }
        return defaults.object(forKey: key) as? Bool
    }

    /// Connect to the Internet's check: the saved choice, else what the running device has, else on.
    public static func desired(running: Bool?, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? running ?? true
    }

    /// Connect to the Internet: saves the opposite of what the menu shows; the running device keeps its network until its next start.
    public static func toggle(running: Bool?, defaults: UserDefaults = .standard) {
        defaults.set(!desired(running: running, defaults: defaults), forKey: key)
    }
}
