import DeviceRuntime
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// The hardware buttons (pressed, then released off the main queue), shake, tilt in its pose, and composed text
/// (through the agent, else as US keys in order).
struct DeviceInputTests {
    /// Records commands from any thread: a button's release comes off the main queue.
    final class Link: HelperLink, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [LinkCommand] = []
        var commands: [LinkCommand] { lock.withLock { sent } }
        func send(_ command: LinkCommand) { lock.withLock { sent.append(command) } }
        func request(_ request: LinkRequest, timeout: TimeInterval, reply: @escaping DeviceLink.Reply) {}
    }

    final class Host: InputHost {
        let link = Link()
        var helperLink: HelperLink? { link }
        var acceptsInput = true, isSleeping = false, keyboardInputEnabled = true
        var agentTypes = false
        var typed: [String] = []
        func typeThroughAgent(_ text: String) async -> Bool {
            typed.append(text)
            return agentTypes
        }
    }

    @Test func aButtonIsPressedThenReleased() async {
        let host = Host()
        let input = DeviceInput(
            host: host,
            settings: DeviceSettingsFile(directory: URL(fileURLWithPath: "/nonexistent"))
        )
        input.tap(.power)
        #expect(host.link.commands == [.button(1, down: true)], "held down")
        await eventually("the release") { host.link.commands.count == 2 }
        #expect(host.link.commands == [.button(1, down: true), .button(1, down: false)])
        input.shake()
        #expect(host.link.commands.last == .shake && input.shakeGeneration == 1)
    }

    @Test func tiltGoesOnlyToAnAwakeGuestInItsPose() throws {
        try withTemporaryDirectory { directory in
            let host = Host()
            let input = DeviceInput(host: host, settings: DeviceSettingsFile(directory: directory))
            #expect(input.motionPose == .upright)
            #expect(observes({ _ = input.motionPose }) { input.setMotionPose(.flat) }, "the Motion menu follows")
            #expect(DeviceSettings.load(directory).motionPose == DeviceInput.MotionPose.flat.rawValue)
            input.setTilt(angle: 30, pitch: 10)
            #expect(
                host.link.commands == [
                    ChassisTilt.attitudeCommand(angle: 30, pitch: 10, pose: DeviceInput.MotionPose.flat.rawValue)
                ]
            )
            host.isSleeping = true
            input.setTilt(angle: 40)
            host.isSleeping = false
            host.acceptsInput = false
            input.setTilt(angle: 50)
            #expect(host.link.commands.count == 1, "a sleeping or stopped guest gets no tilt")
        }
    }

    @Test func textGoesThroughTheAgentElseAsKeysInOrder() async throws {
        let host = Host()
        let input = DeviceInput(
            host: host,
            settings: DeviceSettingsFile(directory: URL(fileURLWithPath: "/nonexistent"))
        )
        input.keyGap = .zero
        host.agentTypes = true
        input.typeText("Hi", shiftHeld: false)
        await input.currentTyping?.value
        #expect(host.typed == ["Hi"] && host.link.commands.isEmpty, "the agent typed it")

        host.agentTypes = false
        input.typeText("A", shiftHeld: false)
        input.typeText("b", shiftHeld: false)  // waits for the first
        await input.currentTyping?.value
        let a = Int(GuestKeyboard.key(for: "A")!.0)
        let b = Int(GuestKeyboard.key(for: "b")!.0)
        #expect(
            host.link.commands == [
                .key(macKeyCode: 56, down: true), .key(macKeyCode: a, down: true),
                .key(macKeyCode: a, down: false), .key(macKeyCode: 56, down: false),
                .key(macKeyCode: b, down: true), .key(macKeyCode: b, down: false)
            ]
        )
        input.typeText("A", shiftHeld: true)
        await input.currentTyping?.value
        #expect(
            host.link.commands.suffix(2) == [.key(macKeyCode: a, down: true), .key(macKeyCode: a, down: false)],
            "Shift already held: not pressed again"
        )

        host.keyboardInputEnabled = false
        input.typeText("c", shiftHeld: false)
        host.keyboardInputEnabled = true
        host.isSleeping = true
        input.typeText("c", shiftHeld: false)
        await input.currentTyping?.value
        #expect(host.typed.count == 4, "passthrough off or asleep: nothing typed")
    }
}
