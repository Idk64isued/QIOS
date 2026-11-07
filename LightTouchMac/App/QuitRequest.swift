import Cocoa

/// NSApplication's deferred quit runs a nested modal loop. Invoking it inside a main-queue callback occupies that
/// serial queue until quit finishes, starving the Swift main-actor tasks needed to finish it. A run-loop timer
/// invokes AppKit without holding the dispatch queue. System logout still uses applicationShouldTerminate's native reply.
enum QuitRequest {
    /// Quit soon, unless `awaiting` (a quit already waits on the devices) by then.
    static func post(unless awaiting: @escaping @MainActor () -> Bool) {
        guard !awaiting() else { return }
        let timer = Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard !awaiting() else { return }
                NSApp.terminate(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
