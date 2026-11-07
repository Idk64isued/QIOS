import Testing

@testable import LightTouchCore

/// The Device menu's device items and the capture commands' availability, from a device snapshot; the rotation
/// control's alternating turns.
struct DeviceMenuStateTests {
    func running() -> DeviceMenuState {
        var state = DeviceMenuState()
        state.isRunning = true
        state.acceptsInput = true
        return state
    }

    @Test func pauseNamesWhatItDoesAndWaitsForInstalls() {
        var state = running()
        #expect(state.validate(.pause) == .init(isEnabled: true, title: "Pause"))
        state.isRunning = false
        state.machine = .paused
        state.acceptsInput = false
        #expect(state.validate(.pause) == .init(isEnabled: true, title: "Resume"))
        state = running()
        state.hasPendingInstalls = true
        #expect(!state.validate(.pause).isEnabled, "a queued install keeps the device running")
        state = running()
        state.isInstalling = true
        #expect(!state.validate(.pause).isEnabled)
        state = DeviceMenuState()
        #expect(!state.validate(.pause).isEnabled, "nothing to pause when stopped")
    }

    /// State audit A-14: Restart was enabled whenever the device wasn't dead. Paused, it is (the restart resumes the
    /// guest first); powered off it powers on; not while it stops, is dead, or its storage failed.
    @Test func restartIsOfferedWhereItCanRun() {
        var state = running()
        #expect(state.validate(.restart).isEnabled)
        state.isRunning = false
        state.machine = .paused
        #expect(state.validate(.restart).isEnabled)
        state = DeviceMenuState()
        state.machine = .poweredOff
        #expect(state.validate(.restart).isEnabled)
        for change: (inout DeviceMenuState) -> Void in [
            { $0.machine = .dead(exitCode: nil) }, { $0.shuttingDown = true }, { $0.storageFailed = true }
        ] {
            var stopped = running()
            change(&stopped)
            #expect(!stopped.validate(.restart).isEnabled)
        }
    }

    /// The machine-state rows of the table, every VMState: what Pause, Restart, Start and Carrier offer when the
    /// device isn't ready for the user (isRunning false).
    @Test func eachMachineStateValidates() {
        let states: [VMState] = [.notStarted, .booting, .running, .paused, .poweredOff, .dead(exitCode: 1)]
        for machine in states {
            var state = DeviceMenuState()
            state.machine = machine
            state.hasCellular = true
            #expect(state.validate(.pause).isEnabled == (machine == .paused), "\(machine)")
            #expect(state.validate(.pause).title == (machine == .paused ? "Resume" : "Pause"))
            #expect(state.validate(.restart).isEnabled == !machine.isDead, "\(machine)")
            #expect(state.validate(.lock).isEnabled == (machine == .poweredOff), "\(machine)")
            #expect(state.validate(.carrier).isEnabled == (machine == .paused), "\(machine)")
            var capture = CaptureAvailability()
            capture.machine = machine
            #expect(capture.canTakeScreenshot == (machine == .paused) && !capture.canStartRecording)
        }
    }

    @Test func rotationLeavesArrowKeysToTextBeingEdited() {
        var state = running()
        #expect(state.validate(.rotate).isEnabled)
        state.editingText = true
        #expect(!state.validate(.rotate).isEnabled)
        state.editingText = false
        state.acceptsInput = false
        #expect(!state.validate(.rotate).isEnabled)
    }

    @Test func inputNeedsADeviceTakingInput() {
        var state = running()
        #expect(state.validate(.input).isEnabled)
        state.acceptsInput = false
        #expect(!state.validate(.input).isEnabled)
    }

    @Test func compassChecksItsCurrentValue() {
        var state = running()
        #expect(!state.validate(.compassHeading(0)).isEnabled, "no compass, dimmed (never left out)")
        state.hasCompass = true
        state.compassHeading = 90
        #expect(state.validate(.compassHeading(90)) == .init(isEnabled: true, isOn: true))
        #expect(state.validate(.compassHeading(0)).isOn == false)
        state.compassHeading = nil
        #expect(state.validate(.compassHeading(0)).isOn == false)
    }

    @Test func carrierNeedsACellularDeviceRunningOrPaused() {
        var state = running()
        #expect(!state.validate(.carrier).isEnabled)
        state.hasCellular = true
        #expect(state.validate(.carrier).isEnabled)
        state.isRunning = false
        state.machine = .paused
        #expect(state.validate(.carrier).isEnabled)
        state.machine = .running
        #expect(!state.validate(.carrier).isEnabled)
    }

    @Test func lockWakesAndPowersOn() {
        var state = running()
        #expect(state.validate(.lock) == .init(isEnabled: true, title: "Lock"))
        state.isSleeping = true
        #expect(state.validate(.lock).title == "Wake")
        state = DeviceMenuState()
        state.machine = .poweredOff
        #expect(state.validate(.lock) == .init(isEnabled: true, title: "Start"))
        state.shuttingDown = true
        #expect(!state.validate(.lock).isEnabled)
    }

    @Test func captureAvailabilityFollowsTheDevice() {
        var c = CaptureAvailability()
        c.isRunning = true
        #expect(c.canTakeScreenshot && c.canStartRecording && c.canToggleRecording)
        c.isRunning = false
        c.machine = .paused
        #expect(
            c.canTakeScreenshot && !c.canStartRecording && !c.canToggleRecording,
            "a paused screen can be shot, not recorded"
        )
        c.isSleeping = true
        #expect(!c.canTakeScreenshot && !c.canToggleRecording)
        c.recordingCanStop = true
        #expect(c.canToggleRecording, "stopping must remain available when the guest stops")
        c.recordingSaving = true
        #expect(!c.canToggleRecording)
        c = CaptureAvailability()
        c.isRunning = true
        c.screenshotBusy = true
        #expect(!c.canTakeScreenshot && !c.canStartRecording && !c.canToggleRecording)
        #expect(!CaptureAvailability().canTakeScreenshot, "no device")
    }

    /// Default presses alternate between upright portrait and home-button-right landscape; Option reverses the same
    /// next turn, including after auto-rotation.
    @Test func rotationControlAlternates() {
        var degrees = 0
        for expected in [270, 0, 270, 0] {
            let action = RotationControlAction(rotationDegrees: degrees, optionPressed: false)
            degrees = (degrees + (action.clockwise ? 90 : 270)) % 360
            #expect(degrees == expected)
        }
        for degrees in [0, 90, 180, 270] {
            let normal = RotationControlAction(rotationDegrees: degrees, optionPressed: false)
            let alternate = RotationControlAction(rotationDegrees: degrees, optionPressed: true)
            #expect(normal.clockwise != alternate.clockwise && normal.symbol != alternate.symbol)
        }
    }
}
