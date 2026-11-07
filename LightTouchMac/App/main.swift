import Cocoa
import LightTouchCore

// Top-level, so it is retained for the process lifetime (NSApplication.delegate
// is a weak reference). Program entry is the main thread; assumeIsolated lets
// the delegate's MainActor-isolated conformance be assigned without a hop.
logEvent("Light Touch started")
let delegate = MainActor.assumeIsolated {
    RestorationDefaults.configure()
    return AppDelegate()
}
MainActor.assumeIsolated {
    LightTouchApplication.shared.delegate = delegate
}
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
