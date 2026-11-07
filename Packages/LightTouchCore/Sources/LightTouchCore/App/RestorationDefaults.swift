import Foundation

/// Every launch builds a new Mac interface (WindowRestorationPolicy closes AppKit's restoration per window and
/// for the app). This does not govern guest snapshots or the explicit capture/toolbar preferences stored by the app.
public enum RestorationDefaults {
    /// Apply before NSApplication is created, including after an unclean exit. A volatile override (the argument
    /// domain, this process only) cannot become a sticky preference for other apps.
    public static func configure(_ defaults: UserDefaults = .standard) {
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["NSQuitAlwaysKeepsWindows"] = false
        arguments["ApplePersistenceIgnoreState"] = true
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}
