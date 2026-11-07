import Foundation
import Testing

@testable import LightTouchCore

/// The session's lifecycle changes only through VMState.transition(to:) and its table (state audit A-19).
struct VMStateTransitionTests {
    static let states: [VMState] = [.notStarted, .booting, .running, .paused, .poweredOff, .dead(exitCode: nil)]

    /// Every pair, legal and illegal, against the table written out by hand.
    @Test func everyPairFollowsTheTable() {
        let legal: Set<String> = [
            "notStarted→booting", "notStarted→dead",
            "booting→booting", "booting→running", "booting→poweredOff", "booting→dead",
            "running→paused", "running→booting", "running→poweredOff", "running→dead",
            "paused→running", "paused→booting", "paused→poweredOff", "paused→dead",
            "poweredOff→booting", "poweredOff→poweredOff", "poweredOff→dead"
        ]
        func name(_ state: VMState) -> String { state.isDead ? "dead" : "\(state)" }
        for from in Self.states {
            for to in Self.states {
                let pair = "\(name(from))→\(name(to))"
                #expect(from.allows(to) == legal.contains(pair), "\(pair)")
                if legal.contains(pair) {
                    var state = from
                    state.transition(to: to)
                    #expect(state == to, "\(pair) is taken")
                }
            }
        }
        #expect(VMState.notStarted.allows(.dead(exitCode: 1)), "a boot that can't be built carries its exit code")
    }

    /// A dead device coming back to life (a late frame or resume, dead with live timers: A-1) was a plain assignment
    /// away; now it traps in a debug build.
    @Test func aDeadDeviceCantRunAgain() async {
        await #expect(processExitsWith: .failure) {
            var state = VMState.dead(exitCode: nil)
            state.transition(to: .running)
        }
        await #expect(processExitsWith: .failure) {
            var state = VMState.poweredOff
            state.transition(to: .paused)
        }
    }
}
