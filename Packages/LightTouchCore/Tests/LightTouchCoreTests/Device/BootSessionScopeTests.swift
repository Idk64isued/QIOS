import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// BootSessionScope: retiring a boot cancels every task and observer it owns and refuses new ones; renew starts the next.
struct BootSessionScopeTests {
    @Test func retirementCancelsEveryTaskAndObserverAndIsolatesTheNextBoot() async throws {
        let owner = BootSessionScope()
        let oldID = owner.id
        let oldGeneration = owner.generation
        var completions = 0
        var observations = 0
        for key in BootSessionScope.Work.allCases {
            owner[key] = Task {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                completions += 1
            }
        }
        let name = Notification.Name("scope-probe-\(UUID())")
        owner.timeZoneObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { observations += 1 }
        }
        owner.localeObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { observations += 10 }
        }
        NotificationCenter.default.post(name: name, object: nil)
        #expect(observations == 11)
        owner.retire()
        NotificationCenter.default.post(name: name, object: nil)
        // A task added after retirement is cancelled at once.
        owner[.foreground] = Task {
            guard !Task.isCancelled else { return }
            completions += 100
        }
        #expect(owner[.foreground] == nil)
        try await Task.sleep(for: .milliseconds(120))
        #expect(completions == 0 && observations == 11)
        #expect(owner.generation > oldGeneration && owner.retired)

        owner.renew()
        #expect(owner.id != oldID && !owner.retired)
        owner[.foreground] = Task { completions += 1 }
        await owner[.foreground]?.value
        #expect(completions == 1)
        owner.retire()
    }

    @Test func replacingATaskCancelsThePreviousOne() async {
        let owner = BootSessionScope()
        let first = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        owner[.reset] = first
        owner[.reset] = Task {}
        #expect(first.isCancelled)
        owner.retire()
    }
}
