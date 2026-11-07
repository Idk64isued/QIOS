// How many of a listener's connections are served at once (WebProxy). Each guest connection to the web proxy is a
// thread here and a socket pair in this process (slirp connects it to the proxy's socket), so a guest opening
// connections without end would take the user's thread limit; past the cap a connection is closed at once, which
// closes the guest's end too.

import Foundation

final class ConnectionLimit: @unchecked Sendable {
    let capacity: Int
    private let lock = NSLock()
    private var active = 0

    init(capacity: Int) { self.capacity = capacity }

    /// Serves `fd` on a thread of its own (`serve` closes it); or, with `capacity` connections being served, closes
    /// it unanswered and returns false.
    @discardableResult
    func start(_ fd: Int32, _ serve: @escaping @Sendable (Int32) -> Void) -> Bool {
        let admitted = lock.withLock {
            guard active < capacity else { return false }
            active += 1
            return true
        }
        guard admitted else {
            close(fd)
            return false
        }
        Thread.detachNewThread { [self] in
            serve(fd)
            lock.withLock { active -= 1 }
        }
        return true
    }
}
