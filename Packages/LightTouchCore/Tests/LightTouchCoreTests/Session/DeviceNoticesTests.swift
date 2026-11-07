import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import LightTouchCore

/// The device notice: kept in the device's settings.plist across relaunches, resolved only by its own operation,
/// and while storage has failed, always the storage notice and not dismissable.
struct DeviceNoticesTests {
    @Test func noticesPersistResolveByOperationAndHoldWhileStorageFailed() throws {
        try withTemporaryDirectory { directory in
            var failed = false
            @MainActor func open() -> DeviceNotices {
                DeviceNotices(settings: DeviceSettingsFile(directory: directory), shortName: "iPod") { failed }
            }
            let notices = open()
            #expect(
                observes({ _ = notices.message }) { notices.report("Retry preparation", for: .preparation) },
                "the window's notice follows a report"
            )
            #expect(notices.message == "Retry preparation")
            #expect(open().message == "Retry preparation", "a relaunch reads the notice back")
            #expect(
                DeviceSettings.load(directory).deviceNotices
                    == [.init(message: "Retry preparation", operation: "preparation")]
            )
            #expect(!notices.offersErase)

            #expect(!observes({ _ = notices.message }) { notices.resolve(.powerOff) })
            #expect(notices.message != nil && open().message != nil, "another operation's success leaves it")
            #expect(observes({ _ = notices.message }) { notices.resolve(.preparation) })
            #expect(notices.message == nil && open().message == nil)

            notices.report("Couldn’t finish erasing", for: .erase)
            #expect(notices.offersErase)
            notices.report("Not activated", for: .activation)
            #expect(notices.offersErase)

            failed = true
            notices.report("Another failure", for: .powerOff)
            #expect(notices.message?.hasPrefix("Couldn’t save to disk, so the iPod stopped") == true)
            #expect(DeviceSettings.load(directory).deviceNotices?.last?.operation == "storage")
            #expect(!notices.offersErase, "storage failure: Erase is not the remedy")
            notices.dismiss()
            #expect(notices.message != nil, "a storage failure can't be dismissed")
            notices.resolve(.storage)
            #expect(notices.message != nil)
            failed = false
            notices.dismiss()
            #expect(notices.message == "Couldn’t finish erasing", "the notices under it show again")
        }
    }

    /// Each operation keeps its own notice (a low-space warning no longer takes the Erase remedy with it when it
    /// resolves), and a fresh helper ends the last boot's notices, a relaunch's included, but not the device's own.
    @Test func noticesAreKeptPerOperationAndABootsEndWithIt() throws {
        try withTemporaryDirectory { directory in
            @MainActor func open() -> DeviceNotices {
                DeviceNotices(settings: DeviceSettingsFile(directory: directory), shortName: "iPod") { false }
            }
            let notices = open()
            notices.report("Made with an older system image", for: .erase)
            notices.report("Low on space", for: .lowSpace)
            #expect(notices.message == "Made with an older system image", "the Erase remedy shows first")
            #expect(notices.offersErase)
            notices.resolve(.lowSpace)
            #expect(notices.message == "Made with an older system image" && notices.offersErase)

            notices.report("Didn’t stop. Quit Light Touch to stop it.", for: .powerOff)
            notices.report("Couldn’t save to disk", for: .storage)
            notices.dismiss()
            #expect(notices.message == "Made with an older system image", "dismissing one shows the next")
            notices.report("Startup failed", for: .preparation)
            notices.report("Files changed", for: .files)
            let relaunched = open()
            #expect(relaunched.message == "Made with an older system image")
            relaunched.dismiss()
            #expect(relaunched.message == "Didn’t stop. Quit Light Touch to stop it.")
            relaunched.helperStarted()
            #expect(relaunched.message == nil && open().message == nil, "the last boot's notices end with it")

            open().report("Not activated", for: .activation)
            open().report("Couldn’t save to disk", for: .storage)
            open().helperStarted()
            #expect(open().message == "Not activated" && open().offersErase, "the device's own stay")
        }
    }

    @Test func anEarlierBuildsNoticeIsRead() throws {
        try withTemporaryDirectory { directory in
            var saved = DeviceSettings()
            saved.deviceNotice = .init(message: "Couldn’t erase", operation: "erase")
            try saved.save(directory)
            let notices = DeviceNotices(settings: DeviceSettingsFile(directory: directory), shortName: "iPod") { false }
            #expect(notices.message == "Couldn’t erase" && notices.offersErase)
            notices.resolve(.erase)
            #expect(notices.message == nil && DeviceSettings.load(directory) == DeviceSettings())
        }
    }

    @Test func settingsFileKeepsOtherFieldsAndSavesEachChange() throws {
        try withTemporaryDirectory { directory in
            var saved = DeviceSettings()
            saved.motionPose = 1
            try saved.save(directory)
            let file = DeviceSettingsFile(directory: directory)
            #expect(observes({ _ = file.value }) { file.change { $0.keyboardInputEnabled = false } })
            #expect(
                !observes({ _ = file.value }) { file.change { $0.keyboardInputEnabled = false } },
                "no change, no update"
            )
            let read = DeviceSettings.load(directory)
            #expect(read.motionPose == 1 && read.keyboardInputEnabled == false)
        }
    }

    /// Two holders of one device's settings (a session and the Carrier panel's, a stopped device's menu, an
    /// erase's) see each other's changes, and neither writes back what the other changed.
    @Test func everyFileOnADeviceSharesItsSettings() throws {
        try withTemporaryDirectory { directory in
            let session = DeviceSettingsFile(directory: directory)
            let other = DeviceSettingsFile(directory: directory)
            _ = session.value
            _ = other.value
            #expect(observes({ _ = session.value }) { other.change { $0.motionPose = 2 } })
            #expect(session.value.motionPose == 2)
            session.change { $0.keyboardInputEnabled = false }
            other.change { $0.localNetwork = true }
            let read = DeviceSettings.load(directory)
            #expect(read.motionPose == 2 && read.keyboardInputEnabled == false && read.localNetwork == true)
        }
    }
}
