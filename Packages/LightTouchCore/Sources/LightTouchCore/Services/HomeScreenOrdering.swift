import Foundation
import HostRuntime
import HostServiceClient
import HostServiceWire

extension DeviceServices {
    @discardableResult
    public func moveOnHomeScreen(_ bundleID: String, before other: String?, profile: Board) async throws -> [String] {
        try await moveOnHomeScreen(bundleID, before: other, deviceName: profile.shortName)
    }
}
