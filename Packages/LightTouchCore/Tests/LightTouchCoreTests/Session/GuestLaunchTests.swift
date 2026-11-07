import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// Opening an app wakes a sleeping display and nothing else, keeps the guest's lock and typed errors; the boot's
/// guest offer survives a failing developer addition but not a failing required package.
struct GuestLaunchTests {
    @Test func openWakesASleepingDisplayAndKeepsTypedErrors() async throws {
        try await withScratchDirectory { directory in
            let device = FakeSession(directory: directory)
            try await device.launchApp("com.example.game")
            #expect(device.homes == 0 && device.launched == ["com.example.game"], "an awake screen is left alone")
            device.isSleeping = true
            device.status = helperStatus(displaySleeping: true)
            try await device.launchApp("com.example.game")
            #expect(device.homes == 1 && device.displaySleeping == false && device.launched.count == 2)

            device.isSleeping = false
            device.launchFailure = AppLaunchError.locked
            await #expect(throws: AppLaunchError.locked) { try await device.launchApp("com.example.game") }
            #expect(device.homes == 1, "a locked device isn't unlocked by the host")
            device.launchFailure = CancellationError()
            await #expect(throws: CancellationError.self) { try await device.launchApp("com.example.game") }

            device.launchFailure = nil
            device.acceptsInput = false
            let launched = device.launched.count
            await #expect(throws: AppLaunchError.unavailable) { try await device.launchApp("com.example.game") }
            #expect(device.launched.count == launched)
        }
    }

    @Test func aDisplayThatNeverWakesStillLaunchesAndADeviceThatStopsDoesnt() async throws {
        try await withScratchDirectory { directory in
            let device = FakeSession(directory: directory)
            device.isSleeping = true
            device.status = helperStatus(displaySleeping: true)
            device.homesWake = false
            try await device.launchApp("com.example.game")
            #expect(device.homes == 1 && device.launched.count == 1, "the launch goes ahead after the wake's second")

            device.acceptsInputAfterHome = false
            await #expect(throws: AppLaunchError.unavailable) { try await device.launchApp("com.example.game") }
            #expect(device.launched.count == 1)
        }
    }

    @Test func withoutUSBOrAnAgentNothingLaunches() async throws {
        try await withScratchDirectory { directory in
            let device = FakeSession(directory: directory)
            device.servicesUp = false
            await #expect(throws: DeviceToolsError.self) { try await device.launchApp("com.example.game") }
            device.servicesUp = true
            device.guestAgentAlive = false
            do {
                try await device.launchApp("com.example.game")
                Issue.record("launched without an agent")
            } catch {
                #expect(error.localizedDescription == "Open it from the iPod’s Home screen.")
            }
            #expect(device.launched.isEmpty)
        }
    }

    @Test func messagesNameTheDevice() {
        #expect(AppLaunchError.locked.message(for: .n72) == "Unlock the iPod, then try again.")
        #expect(
            AppLaunchError.unavailable.message(for: .k48) == "Wait for the iPad to finish starting, then try again."
        )
        #expect(AppLaunchError.failed.message(for: .n72) == "Try opening the app on the iPod.")
    }

    struct Corrupt: Error {}
    static let builtIn = GuestPackage.Offer(bundled: 2, version: "built-in", serial: 2, glHook: false)

    @Test func developerFailurePreservesRequiredAdditions() {
        var calls: [Bool] = []
        let fallback = GuestOfferComposition.offer(augmentation: "developer tools") { augment -> GuestPackage.Offer? in
            calls.append(augment != nil)
            if augment != nil { throw Corrupt() }
            return Self.builtIn
        }
        #expect(fallback == Self.builtIn && calls == [true, false])

        calls = []
        let ordinary = GuestOfferComposition.offer(augmentation: String?.none) { augment -> GuestPackage.Offer? in
            calls.append(augment != nil)
            return Self.builtIn
        }
        #expect(ordinary == Self.builtIn && calls == [false], "no developer tools: one composition")

        let augmented = GuestOfferComposition.offer(augmentation: "developer tools") { augment -> GuestPackage.Offer? in
            GuestPackage.Offer(bundled: 3, version: augment == nil ? "plain" : "with tools", serial: 3, glHook: false)
        }
        #expect(augmented?.version == "with tools")
    }

    @Test func anInvalidRequiredPackageFailsClosed() {
        var calls = 0
        let none = GuestOfferComposition.offer(augmentation: String?.none) { _ -> GuestPackage.Offer? in
            calls += 1
            throw Corrupt()
        }
        #expect(none == nil && calls == 1)
        calls = 0
        let both = GuestOfferComposition.offer(augmentation: "developer tools") { _ -> GuestPackage.Offer? in
            calls += 1
            throw Corrupt()
        }
        #expect(both == nil && calls == 2)
    }
}
