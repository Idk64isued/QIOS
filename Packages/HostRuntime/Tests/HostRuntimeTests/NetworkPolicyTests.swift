import Testing

@testable import HostRuntime

struct NetworkPolicyTests {
    typealias Endpoint = NetworkPolicy.Endpoint
    static func lookupNever(_ host: String, _ port: Int) -> [Endpoint] {
        Issue.record("\(host) was looked up")
        return []
    }
    static func v4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Endpoint {
        Endpoint(bytes: [a, b, c, d], port: 80)
    }

    /// This Mac itself, in every spelling a guest can write: refused with the local network on or off, before any lookup.
    @Test(arguments: [
        "127.0.0.1", "127.1", "127.255.255.254", "2130706433", "0x7f000001", "0x7f.1", "0.0.0.0", "0",
        "0.1.2.3", "::1", "[::1]", "::", "::ffff:127.0.0.1", "[::ffff:127.0.0.1]", "::ffff:7f00:1", "::127.0.0.1",
        "::ffff:0:127.0.0.1", "64:ff9b::7f00:1", "::ffff:0.0.0.0", "::ffff:127.0.0.1%", "localhost", "LOCALHOST.",
        "x.localhost"
    ])
    func thisMacIsNeverReachable(host: String) {
        for lan in [false, true] {
            #expect(throws: NetworkPolicy.Refusal.host) {
                try NetworkPolicy.resolve(host, port: 80, localNetwork: lan, lookup: Self.lookupNever)
            }
        }
    }

    /// The local networks: refused while Attach to Local Network is off, allowed once it is on.
    @Test(arguments: [
        "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254", "100.64.0.1", "100.127.255.255",
        "198.18.0.1", "198.19.255.255", "224.0.0.251", "239.255.255.250", "240.0.0.1", "255.255.255.255",
        "[::ffff:192.168.1.1]", "::ffff:10.0.0.1", "::10.0.0.1", "64:ff9b::a00:1", "::ffff:0:a9fe:a9fe", "fe80::1",
        "fe80::1%lo0", "fc00::1", "fd12:3456::1", "fec0::1", "ff02::1", "printer.local", "Printer.Local."
    ])
    func localNetworksNeedAttachToLocalNetwork(host: String) throws {
        #expect(throws: NetworkPolicy.Refusal.localNetwork) {
            try NetworkPolicy.resolve(host, port: 80, localNetwork: false, lookup: Self.lookupNever)
        }
        try NetworkPolicy.screen(host, localNetwork: true)
    }

    @Test(arguments: [
        "93.184.215.14", "1.1.1.1", "11.0.0.1", "100.63.255.255", "100.128.0.1", "172.15.0.1", "172.32.0.1",
        "192.169.0.1", "198.17.0.1", "198.20.0.1", "223.255.255.255", "2606:4700::1111", "[2001:4860:4860::8888]",
        "::ffff:8.8.8.8", "64:ff9b::808:808"
    ])
    func publicAddressesPass(host: String) throws {
        let endpoints = try NetworkPolicy.resolve(host, port: 443, localNetwork: false)
        #expect(endpoints.count == 1 && endpoints[0].port == 443)
    }

    /// A name that answers a public address when checked and a loopback one later is connected to at the address
    /// it was checked at: it is looked up once.
    @Test func aNameIsResolvedOnceAndUsedAsChecked() throws {
        var answers = [[Self.v4(93, 184, 215, 14)], [Self.v4(127, 0, 0, 1)]]
        var lookups = 0
        let endpoints = try NetworkPolicy.resolve("rebind.example", port: 80, localNetwork: false) { _, _ in
            lookups += 1
            return answers.removeFirst()
        }
        #expect(endpoints == [Self.v4(93, 184, 215, 14)] && lookups == 1)
    }

    @Test func aNameIsRefusedByAnyOfItsAddresses() {
        let answers: [String: [Endpoint]] = [
            "mixed.example": [Self.v4(93, 184, 215, 14), Self.v4(127, 0, 0, 1)],
            "mapped.example": [Endpoint(bytes: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1], port: 80)],
            "unspecified.example": [Self.v4(0, 0, 0, 0)]
        ]
        for name in answers.keys {
            #expect(throws: NetworkPolicy.Refusal.host) {
                try NetworkPolicy.resolve(name, port: 80, localNetwork: true) { host, _ in answers[host] ?? [] }
            }
        }
        #expect(throws: NetworkPolicy.Refusal.localNetwork) {
            try NetworkPolicy.resolve("lan.example", port: 80, localNetwork: false) { _, _ in [Self.v4(100, 100, 1, 1)]
            }
        }
        #expect(
            (try? NetworkPolicy.resolve("lan.example", port: 80, localNetwork: true) { _, _ in [Self.v4(192, 168, 1, 5)]
            })
                == [Self.v4(192, 168, 1, 5)]
        )
    }

    /// This Mac's own addresses that would otherwise be public (a global IPv6 address, a public IPv4 one) reach its
    /// services listening on every interface: the local network, by address, name, or carried in IPv6.
    @Test func thisMacsOwnPublicAddressesAreItsLocalNetwork() throws {
        let own: Set<[UInt8]> = [[203, 0, 113, 5], [0x26, 0x06, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5]]
        for host in ["203.0.113.5", "::ffff:203.0.113.5", "64:ff9b::cb00:7105", "2606:4700::5"] {
            #expect(throws: NetworkPolicy.Refusal.localNetwork) {
                try NetworkPolicy.resolve(host, port: 80, localNetwork: false, own: own, lookup: Self.lookupNever)
            }
        }
        #expect(throws: NetworkPolicy.Refusal.localNetwork) {
            try NetworkPolicy.resolve("mac.example", port: 80, localNetwork: false, own: own) { _, _ in
                [Self.v4(203, 0, 113, 5)]
            }
        }
        #expect(
            try NetworkPolicy.resolve("mac.example", port: 80, localNetwork: true, own: own) { _, _ in
                [Self.v4(203, 0, 113, 5)]
            } == [Self.v4(203, 0, 113, 5)]
        )
        #expect(NetworkPolicy.interfaceAddresses().contains([127, 0, 0, 1]))
    }

    /// A name that doesn't resolve, and a host that looks numeric but isn't an address, are refused (fail closed).
    @Test(arguments: ["nx.example", "127.0.0.1.", "1.2.3.4.5", "0x7g.1", "0177.0.0.1", "1:2", ""])
    func unresolvedIsRefused(host: String) {
        #expect(throws: NetworkPolicy.Refusal.unresolved) {
            try NetworkPolicy.resolve(host, port: 80, localNetwork: true) { _, _ in [] }
        }
    }
}
