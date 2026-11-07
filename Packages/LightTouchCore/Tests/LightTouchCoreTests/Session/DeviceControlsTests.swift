import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// The keyboard settings as they reach the machine, and the control requests they ride on.
struct DeviceControlsTests {
    final class Machine {
        var requests: [LinkRequest] = []
        var answer = true
        lazy var control: MachineControl = { [unowned self] request, done in
            requests.append(request)
            done(answer)
        }
    }

    @Test func keyboardToggleGatesPressesButNotReleasesAndPersists() throws {
        try withTemporaryDirectory { directory in
            let machine = Machine()
            var sent: [LinkCommand] = []
            var canPress = true
            let settings = DeviceSettingsFile(directory: directory)
            let keyboard = KeyboardInput(
                settings: settings,
                canToggleHardwareKeyboard: true,
                control: machine.control,
                send: { sent.append($0) },
                canPress: { canPress }
            )
            #expect(keyboard.enabled)
            keyboard.sendKey(macKeyCode: 0, down: true)
            #expect(sent == [.key(macKeyCode: 0, down: true)])
            #expect(observes({ _ = keyboard.enabled }) { keyboard.toggleEnabled() }, "the menu's checkmark follows")
            #expect(!keyboard.enabled && DeviceSettings.load(directory).keyboardInputEnabled == false)
            keyboard.sendKey(macKeyCode: 0, down: true)
            keyboard.sendKey(macKeyCode: 0, down: false)
            #expect(
                sent == [.key(macKeyCode: 0, down: true), .key(macKeyCode: 0, down: false)],
                "a release still goes after disabling"
            )
            keyboard.toggleEnabled()
            #expect(keyboard.enabled)
            canPress = false  // asleep, stopped or not taking input
            keyboard.sendKey(macKeyCode: 0, down: true)
            #expect(sent.count == 2, "a sleeping or stopped device gets no presses")
        }
    }

    @Test func connectHardwareKeyboardNowAndAtBoot() throws {
        try withTemporaryDirectory { directory in
            let machine = Machine()
            let keyboard = KeyboardInput(
                settings: DeviceSettingsFile(directory: directory),
                canToggleHardwareKeyboard: true,
                control: machine.control,
                send: { _ in },
                canPress: { true }
            )
            keyboard.applyHardware()
            #expect(machine.requests.isEmpty, "a boot with the keyboard on asks nothing")
            #expect(observes({ _ = keyboard.hardwareConnected }) { keyboard.toggleHardware() })
            #expect(!keyboard.hardwareConnected && machine.requests == [.hardwareKeyboard(false)])
            #expect(DeviceSettings.load(directory).hardwareKeyboard == false)
            keyboard.applyHardware()
            #expect(
                machine.requests == [.hardwareKeyboard(false), .hardwareKeyboard(false)],
                "a boot unplugs it when it's off"
            )
            keyboard.toggleHardware()
            #expect(keyboard.hardwareConnected && machine.requests.last == .hardwareKeyboard(true))

            let other = Machine()
            var off = DeviceSettings()
            off.hardwareKeyboard = false
            try off.save(directory)
            let without = KeyboardInput(
                settings: DeviceSettingsFile(directory: directory),
                canToggleHardwareKeyboard: false,
                control: other.control,
                send: { _ in },
                canPress: { true }
            )
            without.applyHardware()
            #expect(other.requests.isEmpty, "a board without the toggle is never asked")
        }
    }

    @Test func onlyABootsFirstFrameRunsIt() {
        #expect(VMState.booting.runsAfterFrame(poweringOn: false))
        #expect(!VMState.booting.runsAfterFrame(poweringOn: true), "a power-on still waiting to resume")
        for state in [VMState.running, .paused, .poweredOff, .notStarted, .dead(exitCode: nil)] {
            #expect(!state.runsAfterFrame(poweringOn: false), "\(state): a later frame applies nothing again")
        }
    }

    @Test func lateAndRetiredControlRepliesDontReachALaterBoot() {
        let scope = BootSessionScope()
        let link = RecordingLink()
        link.answer = nil
        var applied = 0
        scope.control(.compass(1), on: link) { if $0 { applied += 1 } }
        scope.retire()
        scope.renew()
        scope.control(.compass(2), on: link) { if $0 { applied += 10 } }
        link.pending[0](.success(.ok(true)))
        #expect(applied == 0, "the old boot's reply")
        link.pending[1](.success(.ok(true)))
        #expect(applied == 10)
        scope.retire()
        link.pending[1](.success(.ok(true)))
        #expect(applied == 10, "a retired boot's reply")

        var results: [Bool] = []
        scope.control(.compass(3), on: link) { results.append($0) }
        #expect(results == [false], "a retired boot sends nothing")
        let fresh = BootSessionScope()
        fresh.control(.compass(4), on: nil) { results.append($0) }
        fresh.control(.compass(5), on: link) { results.append($0) }
        link.pending.last!(.success(.ok(false)))
        fresh.control(.compass(6), on: link) { results.append($0) }
        link.pending.last!(.failure(.timedOut))
        #expect(results == [false, false, false, false], "no helper, a refusal, a timeout")
    }
}
