import Foundation
import Testing

@testable import LightTouchCore

/// Quit's ladder: what holds it, what asks, the halts it waits for, one reply, and the budget's backstop.
struct QuitCoordinatorTests {
    final class Log {
        var events: [String] = []
        /// What quitting would interrupt now.
        var busy: String?
    }

    /// A quit request with every guard clear unless overridden; records what the coordinator asked for.
    func request(
        _ quit: QuitCoordinator,
        _ log: Log,
        confirmWait: Bool = true,
        recording: Bool = false,
        preparing: Int = 0,
        confirmPreparation: Bool = true,
        hasDevices: Bool = true,
        changes: Bool = false,
        confirmChanges: Bool = true,
        running: [(@escaping () -> Void) -> Void]
    ) -> QuitCoordinator.Answer {
        quit.shouldTerminate(
            busy: { log.busy },
            confirmWait: {
                log.events.append("wait for \($0)")
                return confirmWait
            },
            finishRecording: {
                log.events.append("recording")
                return recording
            },
            preparing: preparing,
            confirmPreparation: {
                log.events.append("confirm preparing \($0)")
                return confirmPreparation
            },
            hasDevices: hasDevices,
            changesInProgress: changes,
            confirmChanges: {
                log.events.append("confirm changes")
                return confirmChanges
            },
            cancelChanges: { log.events.append("cancel changes") },
            running: running
        )
    }

    /// Lets the main queue run (the coordinator replies there).
    func settle() async throws { try await Task.sleep(for: .milliseconds(30)) }

    @Test func holdsAndQuestions() {
        let log = Log()
        let quit = QuitCoordinator(budget: 60, retry: {}, reply: { log.events.append("reply") })
        let halt: (@escaping () -> Void) -> Void = { _ in log.events.append("halt") }
        #expect(request(quit, log, recording: true, running: [halt]) == .cancel && log.events == ["recording"])
        log.events = []
        #expect(request(quit, log, preparing: 2, confirmPreparation: false, running: [halt]) == .cancel)
        #expect(log.events == ["recording", "confirm preparing 2"])
        log.events = []
        #expect(
            request(quit, log, preparing: 1, hasDevices: false, changes: true, running: []) == .now,
            "no device: nothing to halt or cancel"
        )
        #expect(log.events == ["recording", "confirm preparing 1"])
        log.events = []
        #expect(request(quit, log, changes: true, confirmChanges: false, running: [halt]) == .cancel)
        #expect(log.events == ["recording", "confirm changes"], "declined: nothing cancelled, nothing halted")
        log.events = []
        #expect(request(quit, log, running: []) == .now, "devices all stopped already")
        #expect(!quit.awaitingTermination)
    }

    /// Confirmed changes are cancelled and then the devices halt like any other quit (their storage is flushed).
    @Test func confirmedChangesStillHalt() async throws {
        let log = Log()
        let quit = QuitCoordinator(budget: 60, retry: {}, reply: { log.events.append("reply") })
        #expect(
            request(
                quit,
                log,
                changes: true,
                running: [
                    { done in
                        log.events.append("halt")
                        done()
                    }
                ]
            ) == .later
        )
        #expect(log.events == ["recording", "confirm changes", "cancel changes", "halt"])
        try await settle()
        #expect(log.events.last == "reply")
    }

    @Test func waitsForTheLastDeviceAndRepliesOnce() async throws {
        let log = Log()
        let quit = QuitCoordinator(budget: 60, retry: {}, reply: { log.events.append("reply") })
        var finish: [() -> Void] = []
        #expect(request(quit, log, running: [{ finish.append($0) }, { finish.append($0) }]) == .later)
        #expect(quit.awaitingTermination && finish.count == 2)
        #expect(
            request(quit, log, running: [{ _ in log.events.append("halted again") }]) == .later,
            "a repeated quit waits"
        )
        #expect(!log.events.contains("halted again"))
        finish[0]()
        try await settle()
        #expect(!log.events.contains("reply"), "one device still running")
        finish[1]()
        try await settle()
        #expect(log.events.filter { $0 == "reply" }.count == 1 && !quit.awaitingTermination)
        finish[1]()
        try await settle()
        #expect(log.events.filter { $0 == "reply" }.count == 1, "a late callback replies nothing")
    }

    /// A halt that completes at once still replies after terminateLater was returned, never inside the request.
    @Test func synchronousCompletionRepliesAfterReturning() async throws {
        let log = Log()
        let quit = QuitCoordinator(budget: 60, retry: {}, reply: { log.events.append("reply") })
        #expect(request(quit, log, running: [{ $0() }]) == .later)
        #expect(!log.events.contains("reply"))
        try await settle()
        #expect(log.events.filter { $0 == "reply" }.count == 1)
    }

    @Test func budgetRepliesWhenAHaltNeverFinishes() async throws {
        let log = Log()
        let quit = QuitCoordinator(budget: 0.5, retry: {}, reply: { log.events.append("reply") })
        var late: (() -> Void)?
        #expect(request(quit, log, running: [{ late = $0 }]) == .later)
        try await settle()
        #expect(!log.events.contains("reply"))
        let deadline = Date().addingTimeInterval(10)
        while !log.events.contains("reply") && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.events.filter { $0 == "reply" }.count == 1 && !quit.awaitingTermination)
        late?()
        try await settle()
        #expect(log.events.filter { $0 == "reply" }.count == 1)
    }

    @Test func terminatingCancelsTheBackstop() async throws {
        let log = Log()
        let quit = QuitCoordinator(budget: 0.05, retry: {}, reply: { log.events.append("reply") })
        #expect(request(quit, log, running: [{ _ in }]) == .later)
        quit.willTerminate()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!log.events.contains("reply"))
    }

    /// An erase or a file system operation under way: quitting would leave it half done (the next launch offering
    /// Finish File System Recovery), so quit says what it waits for and, if asked to, quits once it is done.
    @Test func workUnderWayIsWaitedFor() async throws {
        let log = Log()
        let quit = QuitCoordinator(
            budget: 60,
            poll: .milliseconds(10),
            retry: { log.events.append("quit again") },
            reply: { log.events.append("reply") }
        )
        let halt: (@escaping () -> Void) -> Void = { _ in log.events.append("halt") }
        log.busy = "Saving the file system…"
        #expect(request(quit, log, confirmWait: false, running: [halt]) == .cancel)
        #expect(log.events == ["wait for Saving the file system…"], "declined: nothing else asked or halted")
        log.events = []
        #expect(request(quit, log, running: [halt]) == .cancel)
        #expect(request(quit, log, running: [halt]) == .cancel)
        #expect(log.events == ["wait for Saving the file system…"], "asked once while it waits")
        try await Task.sleep(for: .milliseconds(100))
        #expect(!log.events.contains("quit again"), "still saving")
        log.busy = nil
        let deadline = Date().addingTimeInterval(10)
        while !log.events.contains("quit again") && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.events == ["wait for Saving the file system…", "quit again"])
        log.events = []
        #expect(request(quit, log, running: [halt]) == .later && log.events == ["recording", "halt"])
    }
}
