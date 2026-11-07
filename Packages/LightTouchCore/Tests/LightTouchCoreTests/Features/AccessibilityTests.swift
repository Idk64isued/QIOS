import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// Device ▸ Accessibility: which devices have the guest's accessibility features and under what names, the iTunes
/// keys a switch sets through the lockdown-ax child, the state read back from the guest, and the menu's items.
struct AccessibilityTests {
    @Test func onlyTheAccessibilityBoardsHaveThemFromThreeOh() {
        for board in [Board.n18, .n88, .k48, .n81, .n90] {
            #expect(AccessibilityFeature.unavailableReason(board: board, version: "4.2.1") == nil, "\(board)")
        }
        #expect(
            AccessibilityFeature.unavailableReason(board: .n72, version: "4.2.1")
                == "The iPod touch (2nd generation) has no accessibility features."
        )
        for board in [Board.n45, .m68] {
            #expect(AccessibilityFeature.unavailableReason(board: board, version: "3.1.3") != nil, "\(board)")
        }
        #expect(AccessibilityFeature.unavailableReason(board: .n88, version: "2.2.1") != nil)
        #expect(AccessibilityFeature.unavailableReason(board: .n88, version: "3.0") == nil)
    }

    @Test func invertIsWhiteOnBlackUntilSix() {
        #expect(AccessibilityFeature.invertColors.title(version: "3.1.3") == "White on Black")
        #expect(AccessibilityFeature.invertColors.title(version: "5.1.1") == "White on Black")
        #expect(AccessibilityFeature.invertColors.title(version: "6.0") == "Invert Colors")
        #expect(AccessibilityFeature.invertColors.title(version: "7.1.2") == "Invert Colors")
        #expect(
            AccessibilityFeature.allCases.map { $0.title(version: "6.1.6") } == [
                "VoiceOver", "Zoom", "Invert Colors", "Mono Audio", "Speak Auto-text"
            ]
        )
    }

    @Test func aSwitchSetsItsITunesKeyThroughTheChild() async throws {
        try await withTemporaryDirectoryAsync { dir in
            let tool = dir.appendingPathComponent("LightTouchServices")
            let log = dir.appendingPathComponent("argv")
            try "#!/bin/sh\necho \"$USBMUXD_SOCKET_ADDRESS $*\" >> \"\(log.path)\"\n"
                .write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
            let services = DeviceServices(clientSocket: "/tmp/mux.sock")
            try await services.setAccessibility(.voiceOver, on: true, tool: tool.path)
            try await services.setAccessibility(.invertColors, on: false, tool: tool.path)
            #expect(
                try String(contentsOf: log, encoding: .utf8) == """
                    /tmp/mux.sock lockdown-ax VoiceOverTouchEnabledByiTunes=1
                    /tmp/mux.sock lockdown-ax InvertDisplayEnabledByiTunes=0

                    """
            )
            try "#!/bin/sh\necho refused >&2\nexit 1\n".write(to: tool, atomically: true, encoding: .utf8)
            await #expect(throws: DeviceToolsError.self) {
                try await services.setAccessibility(.zoom, on: true, tool: tool.path)
            }
        }
    }

    @Test func theGuestsPreferencesSayWhatIsOn() async throws {
        let link = FakeGuestLink()
        let guest = GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
        #expect(try await guest.accessibility() == [], "no preferences yet: all off")
        link.files["/var/mobile/Library/Preferences/com.apple.Accessibility.plist"] =
            try PropertyListSerialization.data(
                fromPropertyList: [
                    "VoiceOverTouchEnabled": true, "InvertColorsEnabled": true, "ZoomTouchEnabled": false,
                    "VoiceOverTouchSpeakingRate": 0.5
                ],
                format: .binary,
                options: 0
            )
        #expect(try await guest.accessibility() == [.voiceOver, .invertColors])
    }

    /// iPhone OS 3.0 to 3.1.3's handler inverts the display through SpringBoard alone: White on Black is lockdown's.
    @Test func whiteOnBlackBeforeThreeTwoIsLockdowns() async throws {
        try await withTemporaryDirectoryAsync { dir in
            let tool = dir.appendingPathComponent("LightTouchServices")
            try "#!/bin/sh\n[ \"$*\" = \"lockdown-ax --get InvertDisplayEnabledByiTunes\" ] && echo 1\n"
                .write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
            let link = FakeGuestLink()
            link.files["/var/mobile/Library/Preferences/com.apple.Accessibility.plist"] =
                try PropertyListSerialization.data(
                    fromPropertyList: ["VoiceOverTouchEnabled": true],
                    format: .binary,
                    options: 0
                )
            let guest = GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
            let services = DeviceServices(clientSocket: "/tmp/mux.sock")
            #expect(
                try await services.accessibility(guest: guest, version: "3.1.3", tool: tool.path)
                    == [.voiceOver, .invertColors]
            )
            #expect(try await services.accessibility(guest: guest, version: "3.2", tool: tool.path) == [.voiceOver])
        }
    }

    @Test func theMenuDimsWhatTheDeviceLacksAndChecksWhatIsOn() {
        var state = DeviceMenuState()
        state.version = "4.2.1"
        #expect(!state.validate(.accessibilityMenu).isEnabled, "no device running")
        #expect(
            state.validate(.accessibility(.invertColors))
                == .init(isEnabled: false, title: "White on Black", isOn: false)
        )
        state.isRunning = true
        state.accessibilityOn = [.voiceOver]
        #expect(state.validate(.accessibilityMenu).isEnabled)
        #expect(state.validate(.accessibility(.voiceOver)) == .init(isEnabled: true, title: "VoiceOver", isOn: true))
        #expect(state.validate(.accessibility(.zoom)) == .init(isEnabled: true, title: "Zoom", isOn: false))
        state.accessibilityUnavailable = "The iPod touch (2nd generation) has no accessibility features."
        #expect(
            state.validate(.accessibilityMenu)
                == .init(isEnabled: false, toolTip: state.accessibilityUnavailable),
            "the whole submenu is dimmed, with the reason"
        )
        #expect(
            state.validate(.accessibility(.zoom))
                == .init(isEnabled: false, title: "Zoom", isOn: false, toolTip: state.accessibilityUnavailable)
        )
        state = DeviceMenuState()
        state.isRunning = true
        #expect(state.validate(.accessibility(.voiceOver)).isOn == false, "not read yet: no check mark")
    }
}
