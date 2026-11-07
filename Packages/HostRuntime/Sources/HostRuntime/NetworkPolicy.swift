// Where a device's traffic may go from this Mac. The emulated device is untrusted (period software with public
// root exploits), so every path that carries its traffic out decides here, on the address it will connect to: the
// web proxy's requests and raw tunnel (LightTouchDevice/WebProxy.swift, URLSession through its egress) and the
// `sessions` checks that judge them. qemu-ios's libslirp patch (slirp_destination_class) applies the same rule
// to the guest's own NAT, wifi0 and cell0.
//
//   host           this Mac itself: 0/8, 127/8, :: and ::1, "localhost". Never: its loopback services (dev servers,
//                  local model and tool servers) are not the device's, whatever Attach to Local Network says.
//   localNetwork   private 10/8, 172.16/12, 192.168/16; link-local 169.254/16, fe80::/10; shared (CGNAT) 100.64/10;
//                  benchmarking 198.18/15; multicast, reserved and broadcast 224/3; unique local fc00::/7,
//                  site-local fec0::/10, multicast ff00::/8; .local names; and this Mac's own interface
//                  addresses that would otherwise be public. Only with Attach to Local Network on, which is the
//                  LAN as another device on it would see it, this Mac's LAN addresses included.
//   public         everything else.
//
// An IPv6 address carrying an IPv4 one (v4-mapped ::ffff:0:0/96, v4-translated ::ffff:0:0:0/96, v4-compatible
// ::/96, NAT64 64:ff9b::/96) is judged as that IPv4 address. A name is resolved once, refused if any of its
// addresses is (or if it doesn't resolve), and connected to at exactly the addresses that were checked.

import Darwin

public nonisolated enum NetworkPolicy {
    public enum Reach: Sendable, Equatable { case `public`, localNetwork, host }

    public enum Refusal: Error, Sendable, Equatable {
        case host, localNetwork, unresolved
    }

    /// An address and port to connect to, as resolved and checked.
    public struct Endpoint: Sendable, Equatable {
        public var bytes: [UInt8]  // 4 or 16
        public var port: UInt16
        public var scope: UInt32
        public init(bytes: [UInt8], port: UInt16, scope: UInt32 = 0) {
            self.bytes = bytes
            self.port = port
            self.scope = scope
        }
    }

    /// The IPv4 address an IPv6 one carries, or the address as it is.
    public static func canonical(_ b: [UInt8]) -> [UInt8] {
        guard b.count == 16 else { return b }
        let zero = { (r: Range<Int>) in b[r].allSatisfy { $0 == 0 } }
        if zero(0..<10) && b[10] == 0xff && b[11] == 0xff  // v4-mapped
            || zero(0..<8) && b[8] == 0xff && b[9] == 0xff && b[10] == 0 && b[11] == 0  // v4-translated
            || zero(0..<12)  // v4-compatible, :: and ::1 among them (0.0.0.0, 0.0.0.1)
            || b[0..<12].elementsEqual([0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0])  // NAT64
        {
            return Array(b[12...])
        }
        return b
    }

    /// The address's reach by its range alone.
    public static func reach(_ bytes: [UInt8]) -> Reach {
        let bytes = canonical(bytes)
        if bytes.count == 16 {
            let b = bytes
            return b[0] & 0xfe == 0xfc || b[0] == 0xfe && b[1] & 0x80 == 0x80 || b[0] == 0xff ? .localNetwork : .public
        }
        guard bytes.count == 4 else { return .host }
        let (a, b) = (bytes[0], bytes[1])
        if a == 0 || a == 127 { return .host }
        return a == 10 || a == 172 && b & 0xf0 == 16 || a == 192 && b == 168 || a == 169 && b == 254
            || a == 100 && b & 0xc0 == 64 || a == 198 && b & 0xfe == 18 || a >= 224 ? .localNetwork : .public
    }

    /// The address's reach, one of `own` (this Mac's interface addresses) being at least the local network.
    public static func reach(_ bytes: [UInt8], own: Set<[UInt8]>) -> Reach {
        let reach = reach(bytes)
        return reach == .public && own.contains(canonical(bytes)) ? .localNetwork : reach
    }

    /// This Mac's interface addresses, IPv4 carried in IPv6 as itself.
    public static func interfaceAddresses() -> Set<[UInt8]> {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        return Set(
            sequence(first: list, next: { $0?.pointee.ifa_next }).compactMap {
                $0.flatMap { endpoint($0.pointee.ifa_addr) }.map { canonical($0.bytes) }
            }
        )
    }

    public static func allows(_ reach: Reach, localNetwork: Bool) -> Bool {
        reach == .public || reach == .localNetwork && localNetwork
    }

    /// A numeric address in any spelling the resolver takes as one ("127.1", "0x7f000001", "::ffff:7f00:1",
    /// "[::1]", "fe80::1%en0"), or nil for a name.
    public static func address(_ host: String) -> [UInt8]? {
        let host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }
        return endpoint(first.pointee.ai_addr)?.bytes
    }

    /// What can be refused without resolving: a numeric address, "localhost" and its subdomains, a .local name
    /// while the local network is off, and a host that looks numeric but isn't one the resolver reads (URLSession
    /// connects to loopback and link-local literals itself, past any proxy, so these must be refused here).
    public static func screen(
        _ host: String,
        localNetwork: Bool,
        own: Set<[UInt8]> = interfaceAddresses()
    ) throws(Refusal) {
        var name = host.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" || name.hasSuffix(".localhost") { throw .host }
        if let bytes = address(host) {
            let reach = reach(bytes, own: own)
            if !allows(reach, localNetwork: localNetwork) { throw reach == .host ? .host : .localNetwork }
            return
        }
        let numeric = name.split(separator: ".").allSatisfy { part in
            part.allSatisfy(\.isNumber) || part.hasPrefix("0x") && part.dropFirst(2).allSatisfy(\.isHexDigit)
        }
        if name.isEmpty || numeric || name.contains(":") || name.contains("%") { throw .unresolved }
        if name.hasSuffix(".local"), !localNetwork { throw .localNetwork }
    }

    /// `host`'s addresses, resolved once by `lookup` and every one of them allowed, to connect to as they are.
    public static func resolve(
        _ host: String,
        port: Int,
        localNetwork: Bool,
        own: Set<[UInt8]> = interfaceAddresses(),
        lookup: (String, Int) -> [Endpoint] = systemLookup
    ) throws(Refusal) -> [Endpoint] {
        try screen(host, localNetwork: localNetwork, own: own)
        let endpoints = lookup(host, port)
        guard !endpoints.isEmpty else { throw .unresolved }
        for endpoint in endpoints {
            let reach = reach(endpoint.bytes, own: own)
            if !allows(reach, localNetwork: localNetwork) { throw reach == .host ? .host : .localNetwork }
        }
        return endpoints
    }

    /// getaddrinfo's TCP addresses for `host`, empty when it fails.
    public static func systemLookup(_ host: String, _ port: Int) -> [Endpoint] {
        let host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0 else { return [] }
        defer { freeaddrinfo(list) }
        return sequence(first: list, next: { $0?.pointee.ai_next }).compactMap {
            $0.flatMap { endpoint($0.pointee.ai_addr) }
        }
    }

    /// A connected TCP socket to the first of `endpoints` that answers, or nil.
    public static func connect(_ endpoints: [Endpoint], timeout: Int = 10) -> Int32? {
        func connect<T>(_ fd: Int32, _ address: T) -> Bool {
            withUnsafePointer(to: address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<T>.size)) == 0
                }
            }
        }
        for e in endpoints {
            let fd = socket(e.bytes.count == 4 ? AF_INET : AF_INET6, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var limit = timeval(tv_sec: timeout, tv_usec: 0)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let connected: Bool
            if e.bytes.count == 4 {
                var a = sockaddr_in()
                a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                a.sin_family = sa_family_t(AF_INET)
                a.sin_port = e.port.bigEndian
                withUnsafeMutableBytes(of: &a.sin_addr) { $0.copyBytes(from: e.bytes) }
                connected = connect(fd, a)
            } else {
                var a = sockaddr_in6()
                a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                a.sin6_family = sa_family_t(AF_INET6)
                a.sin6_port = e.port.bigEndian
                a.sin6_scope_id = e.scope
                withUnsafeMutableBytes(of: &a.sin6_addr) { $0.copyBytes(from: e.bytes) }
                connected = connect(fd, a)
            }
            if connected { return fd }
            close(fd)
        }
        return nil
    }

    private static func endpoint(_ a: UnsafeMutablePointer<sockaddr>?) -> Endpoint? {
        guard let a else { return nil }
        let raw = UnsafeRawPointer(a)
        switch Int32(a.pointee.sa_family) {
        case AF_INET:
            let s = raw.load(as: sockaddr_in.self)
            return Endpoint(bytes: withUnsafeBytes(of: s.sin_addr) { Array($0) }, port: UInt16(bigEndian: s.sin_port))
        case AF_INET6:
            let s = raw.load(as: sockaddr_in6.self)
            return Endpoint(
                bytes: withUnsafeBytes(of: s.sin6_addr) { Array($0) },
                port: UInt16(bigEndian: s.sin6_port),
                scope: s.sin6_scope_id
            )
        default: return nil
        }
    }
}
