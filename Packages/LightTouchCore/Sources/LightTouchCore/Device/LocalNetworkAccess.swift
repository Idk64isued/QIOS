import Darwin

/// macOS has no API to ask for Local Network access; a local-network operation asks (TN3179).
/// Connecting a UDP socket to a link-local IPv6 address on each broadcast-capable interface does it
/// without sending anything. Best effort: an answer already given shows nothing.
public nonisolated enum LocalNetworkAccess {
    public static func request() {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return }
        defer { freeifaddrs(first) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard entry.pointee.ifa_flags & UInt32(IFF_BROADCAST) != 0, let sa = entry.pointee.ifa_addr,
                sa.pointee.sa_family == AF_INET6, sa.pointee.sa_len >= MemoryLayout<sockaddr_in6>.size
            else { continue }
            var address = UnsafeRawPointer(sa).load(as: sockaddr_in6.self)
            guard address.sin6_addr.__u6_addr.__u6_addr8.0 == 0xfe,
                address.sin6_addr.__u6_addr.__u6_addr8.1 & 0xc0 == 0x80
            else { continue }
            address.sin6_port = UInt16(9).bigEndian  // discard
            withUnsafeMutableBytes(of: &address.sin6_addr) { bytes in
                for i in 8..<16 { bytes[i] = .random(in: 0...255) }
            }
            let fd = socket(AF_INET6, SOCK_DGRAM, 0)
            guard fd >= 0 else { continue }
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            close(fd)
        }
    }
}
