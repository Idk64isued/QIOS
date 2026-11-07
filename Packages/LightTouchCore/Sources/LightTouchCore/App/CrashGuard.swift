// The steps a launch or a device's window runs that can crash in code the app can't catch (issue 99: RealityKit's
// engine start inside a third-party Metal driver) and that a saved choice runs again at every launch. Each marks
// itself running in the defaults while it runs; a mark still there at launch means the last run died in it, and from
// then on the step is skipped (2D for 3D; no automatic start) until it runs to its end again: View ▸ Device Bezels ▸ 3D,
// or the user starting a device. The launch that finds a mark says so once (`notice`); Copy Bug Report Info lists
// every step skipped.

import Foundation

public enum CrashGuard {
    public enum Step: String, CaseIterable, Sendable {
        /// The 3D device (DeviceModelView: RealityKit's engine start and first frame), the default bezel.
        case model
        /// A device starting, from its helper's launch until iOS answers: the launch starts the only device set up.
        case deviceStart

        public var title: String {
            switch self {
            case .model: "3D device"
            case .deviceStart: "starting a device at launch"
            }
        }
    }

    static let key = "CrashGuard"
    private static let running = "running"
    private static var defaults = UserDefaults.standard
    /// How many of each step run now (two devices' windows each load a model): the mark goes with the last.
    private static var depth: [Step: Int] = [:]
    /// The steps skipped: the last run (or an earlier one) died in them; Copy Bug Report Info lists their titles.
    public private(set) static var skipped: Set<Step> = []
    /// The steps the last run died in, for this launch's notice until it is dismissed.
    public private(set) static var unnoticed: [Step] = []

    /// Once, at launch, before any step runs: marks still running become skipped steps.
    @discardableResult
    public static func launch(_ defaults: UserDefaults = .standard) -> [Step] {
        self.defaults = defaults
        depth = [:]
        var marks = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        unnoticed = Step.allCases.filter { marks[$0.rawValue] == running }
        for step in unnoticed { marks[step.rawValue] = "crashed" }
        store(marks)
        skipped = Set(Step.allCases.filter { marks[$0.rawValue] != nil })
        for step in unnoticed {
            logEvent("crash guard: the last run quit in step \(step.rawValue); skipped until it runs again")
        }
        return unnoticed
    }

    public static func skips(_ step: Step) -> Bool { skipped.contains(step) }

    /// Before the step; written through at once, so a crash right after it still finds it.
    public static func begin(_ step: Step) {
        depth[step, default: 0] += 1
        guard depth[step] == 1 else { return }
        skipped.remove(step)
        mark(step, running)
    }

    /// Once the step is done, however it ended (but by a crash): it is no longer skipped.
    public static func end(_ step: Step) {
        guard let count = depth[step], count > 0 else { return }
        depth[step] = count - 1
        if count == 1 { mark(step, nil) }
    }

    /// A clean quit: whatever is still running didn't crash.
    public static func quit() {
        for step in depth.keys where depth[step] ?? 0 > 0 { mark(step, nil) }
        depth = [:]
    }

    /// View ▸ Device Bezels ▸ 3D chosen while 3D is skipped: the next model load runs it again.
    public static func tryAgain(_ step: Step) {
        guard skipped.remove(step) != nil, depth[step] ?? 0 == 0 else { return }
        mark(step, nil)
        unnoticed.removeAll { $0 == step }
    }

    public static func dismissNotice() { unnoticed = [] }

    /// The window's notice for the steps the last run died in.
    public static var notice: String? {
        let model = unnoticed.contains(.model)
        let start = unnoticed.contains(.deviceStart)
        switch (model, start) {
        case (false, false): return nil
        case (true, false): return "Light Touch quit unexpectedly while showing the 3D device, so it shows 2D."
        case (false, true):
            return "Light Touch quit unexpectedly while a device was starting, so it didn’t start one this time."
        case (true, true):
            return "Light Touch quit unexpectedly while a device was starting, so it didn’t start one and shows 2D."
        }
    }

    private static func mark(_ step: Step, _ value: String?) {
        var marks = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        marks[step.rawValue] = value
        store(marks)
    }

    private static func store(_ marks: [String: String]) {
        if marks.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(marks, forKey: key) }
        // Waits for the write: the crash this guards against can follow at once.
        defaults.synchronize()
    }
}
