import Foundation

/// A user-initiated ProcessInfo activity, held while `held` is true: a download, preparation, install,
/// recording or file transfer keeps the Mac from idle sleep (and the app out of App Nap) until it ends.
public struct UserActivity {
    public let reason: String
    private var token: NSObjectProtocol?

    public init(_ reason: String) { self.reason = reason }

    public var held: Bool {
        get { token != nil }
        set {
            guard newValue != held else { return }
            if newValue {
                token = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: reason)
            } else if let token {
                ProcessInfo.processInfo.endActivity(token)
                self.token = nil
            }
        }
    }
}
