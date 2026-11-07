// KBoot against the iBoot it stands in for. iboot-trees/ holds the device tree the iPad's own iBoot hands its kernel
// on the emulator (iBoot-817 on 3.2.2, iBoot-931 on 4.2.1, a prepared k48ap base stopped at the kernel's entry),
// beside the IPSW's. The IPSW's tree goes through KBoot as the iPad (with the identity that base had), and KBoot's
// must come out as iBoot's, property by property, but for the differences listed here, each with its reason. A
// difference not listed fails, as does a listed one that no longer occurs, so the list can only shrink. Properties
// neither side changes are not recorded: the test fills them and expects them back untouched.

import Crypto
import Foundation
import Testing

@testable import FirmwareKit

struct KBootIBootTests {
    /// What KBoot is held to where the capture is not it: (the build it applies to, nil for both, node, property,
    /// the change, why). Each must still change its capture.
    static let corrections: [(String?, String, String, @Sendable (inout Data) -> Void, String)] = [
        (
            nil, "arm-io/mipi-dsim/lcd", "raw-panel-id", { $0[12] = 0x64 },
            "the emulator's DSI panel-ID reply lacks the panel's backlight-calibration byte, 0x64 on the real iPad"
        ),
        (
            "7B500", "arm-io", "clock-frequencies", { $0.replaceSubrange(176..<180, with: Data(count: 4)) },
            "3.x's iBoot-817 sets slot 44 to 24 MHz, 4.x's iBoots leave it 0 (931 here, the iPhone 4's 1072), and KBoot "
                + "boots 4.x and later"
        )
    ]

    /// Where KBoot differs from iBoot on purpose: (node, property or "*" for the whole node, why).
    static let exceptions: [(String, String, String)] = [
        ("chosen/iBoot", "*", "iBoot's own timestamps: no iBoot runs"),
        (
            "chosen/memory-map", "*",
            "the kernelcache's layout, which KBoot.build lays out from its segments (KBootTests.selfcheck); this test "
                + "boots a stand-in kernel"
        ),
        (
            "arm-io/sdio", "vendor-id",
            "an address in iBoot's own memory (0x5ff0b5eb from iBoot-817, here and on the real iPad; 0x5ff223b3 from "
                + "iBoot-931), not a value of the hardware; the iPhone 4's iBoot-1072 writes 0x3000"
        ),
        ("arm-io/uart3/bluetooth", "vendor-id", "as arm-io/sdio's"),
        (
            "baseband", "*",
            "a board without a modem: KBoot renames the node nobb with compatible and device_type none (fillDT), "
                + "where iBoot renames device_type AAPL,ignore; either way nothing matches it"
        ),
        ("nobb", "*", "as baseband"),
        (
            "arm-io/flash-controller0/disk", "landing-map",
            "KBoot writes one word per bus for the S5L8920 boards' 3.x DTs, which carry one word (landingMap); the "
                + "iPad's 3.2.2 DT has one per bus already, and no iPad boots 3.x through KBoot"
        ),
        ("arm-io/flash-controller0/disk", "landing-map-dt", "as landing-map"),
        (
            "arm-io/flash-controller0/disk", "logical-page-size",
            "KBoot writes the page size the 5.x DTs need (iBoot-1219's); iBoot-931 leaves 4.2.1's 0. Not yet read "
                + "from a 5.x iBoot"
        )
    ]

    enum Value: Equatable {
        case absent
        case bytes(Data)
        case unrecorded(Int)
        case same
        case digest(String)
    }
    struct Row {
        var node: String, prop: String, ipsw: Value, iboot: Value
    }

    static let filler: UInt8 = 0xA5

    static func load(_ build: String) throws -> [Row] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("iboot-trees/k48ap-\(build).tsv")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }
            .map { line in
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                func value(_ s: String) throws -> Value {
                    switch s.first {
                    case "-": return .absent
                    case "=": return s == "=" ? .same : .unrecorded(Int(s.dropFirst()) ?? 0)
                    default:
                        if s.hasPrefix("sha256:") { return .digest(String(s.dropFirst(7))) }
                        guard let d = Data(hex: s) else { throw FirmwareError(.unsupported, "bad hex: \(line)") }
                        return .bytes(d)
                    }
                }
                return Row(node: f[0], prop: f[1], ipsw: try value(f[2]), iboot: try value(f[3]))
            }
    }

    /// The IPSW's tree as a blob: the rows' nodes in order, each under the node its path names.
    static func ipswTree(_ rows: [Row]) -> Data {
        var order: [String] = []
        var props: [String: [(String, Data)]] = [:]
        for r in rows {
            if props[r.node] == nil { order.append(r.node) }
            let bytes: Data? =
                switch r.ipsw {
                case .bytes(let d): d
                case .unrecorded(let n): Data(repeating: filler, count: n)
                default: nil
                }
            // A repeat's name#2 is its name.
            let name = r.prop.lastIndex(of: "#").flatMap { $0 > r.prop.startIndex ? r.prop[..<$0] : nil } ?? r.prop[...]
            props[r.node, default: []] += bytes.map { [(String(name), $0)] } ?? []
        }
        func parent(_ p: String) -> String? {
            p == "/" ? nil : p.contains("/") ? String(p[..<(p.lastIndex(of: "/") ?? p.endIndex)]) : "/"
        }
        func blob(_ p: String) -> Data {
            KBootTests.node(props[p] ?? [], order.filter { parent($0) == p }.map(blob))
        }
        return blob("/")
    }

    /// node -> property (name#2 for a repeat) -> value, in a blob.
    static func flatten(_ b: Data) -> [String: [String: Data]] {
        var out: [String: [String: Data]] = [:]
        let d = [UInt8](b)
        func node(_ start: Int, _ parent: String?) -> Int {
            let (np, nc) = (Int(d.u32(start)), Int(d.u32(start + 4)))
            var off = start + 8
            var mine: [(String, Data)] = []
            for _ in 0..<np {
                let name = String(decoding: d[off..<off + 32].prefix { $0 != 0 }, as: UTF8.self)
                let len = Int(d.u32(off + 32) & 0x7FFF_FFFF)
                mine.append((name, Data(d[off + 36..<off + 36 + len])))
                off += 36 + ((len + 3) & ~3)
            }
            let name = String(decoding: (mine.first { $0.0 == "name" }?.1 ?? Data()).prefix { $0 != 0 }, as: UTF8.self)
            let path = parent.map { $0 == "/" ? name : "\($0)/\(name)" } ?? "/"
            var seen: [String: Int] = [:]
            for (k, v) in mine {
                seen[k, default: 0] += 1
                out[path, default: [:]][seen[k] == 1 ? k : "\(k)#\(seen[k] ?? 0)"] = v
            }
            for _ in 0..<nc { off = node(off, path) }
            return off
        }
        _ = node(0, nil)
        return out
    }

    /// KBoot's tree for the IPSW's, as the iPad, with the identity of the base iBoot booted.
    static func kboot(_ build: String, _ rows: [Row], iboot: String, base: UInt32) throws -> [String: [String: Data]] {
        let img = try KBoot.build(
            kernel: KBootTests.kernel(at: base),
            deviceTree: ipswTree(rows),
            identity: try UnitIdentity.synthesize(seed: "ipad1-\(build)-default"),
            iboot: iboot
        )
        let r0 = Int(img.bootArgsPA - img.loadPA)
        let dtp = Int(KBootTests.u32(img.image, r0 + 0x30) - base)
        return flatten(img.image[dtp..<dtp + Int(KBootTests.u32(img.image, r0 + 0x34))])
    }

    struct Difference {
        var node: String, prop: String, text: String
    }

    /// Every difference between KBoot's tree and iBoot's, and the corrections that changed the capture.
    static func differences(_ build: String, iboot: String, base: UInt32) throws -> ([Difference], Set<String>) {
        let rows = try load(build)
        let out = try kboot(build, rows, iboot: iboot, base: base)
        var found: [Difference] = []
        var corrected: Set<String> = []
        for r in rows {
            let got = out[r.node]?[r.prop]
            var want: Data?
            switch (r.iboot, r.ipsw) {
            case (.bytes(let d), _), (.same, .bytes(let d)): want = d
            case (.same, .unrecorded(let n)): want = Data(repeating: filler, count: n)
            case (.digest(let h), _):
                if got.map({ SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }) != h {
                    found.append(Difference(node: r.node, prop: r.prop, text: "KBoot's is not iBoot's (identity)"))
                }
                continue
            default: want = nil
            }
            for (only, node, prop, fix, _) in corrections
            where (only ?? build) == build && node == r.node && prop == r.prop {
                guard var w = want else { continue }
                fix(&w)
                if w != want { corrected.insert("\(only ?? "") \(node) \(prop)") }
                want = w
            }
            if got != want {
                found.append(Difference(node: r.node, prop: r.prop, text: "KBoot \(show(got)), iBoot \(show(want))"))
            }
        }
        let recorded = Set(rows.map { "\($0.node) \($0.prop)" })
        for (node, props) in out {
            for (prop, v) in props where !recorded.contains("\(node) \(prop)") {
                found.append(Difference(node: node, prop: prop, text: "KBoot \(show(v)), iBoot absent"))
            }
        }
        return (found, corrected)
    }

    static func show(_ d: Data?) -> String {
        guard let d else { return "absent" }
        return d.count > 24 ? d.prefix(24).hexString + "...(\(d.count) bytes)" : d.hexString
    }

    @Test func kbootHandsOverIBootsTree() throws {
        var hit = Set<Int>()
        var corrected = Set<String>()
        for (build, iboot, base) in [
            ("7B500", "iBoot-817.29", UInt32(0xC000_0000)), ("8C148", "iBoot-931.71.16", UInt32(0x8000_0000))
        ] {
            let (found, fixed) = try Self.differences(build, iboot: iboot, base: base)
            corrected.formUnion(fixed)
            let unexplained = found.filter { d in
                guard let i = Self.exceptions.firstIndex(where: { $0.0 == d.node && ($0.1 == "*" || $0.1 == d.prop) })
                else { return true }
                hit.insert(i)
                return false
            }
            .map { "\($0.node) \($0.prop): \($0.text)" }.sorted()
            #expect(unexplained.isEmpty, "\(build): KBoot differs from iBoot:\n\(unexplained.joined(separator: "\n"))")
        }
        for (i, (node, prop, _)) in Self.exceptions.enumerated() where !hit.contains(i) {
            Issue.record("exception \(node) \(prop) no longer differs: remove it")
        }
        for (only, node, prop, _, _) in Self.corrections where !corrected.contains("\(only ?? "") \(node) \(prop)") {
            Issue.record("correction \(node) \(prop) no longer changes the capture: remove it")
        }
    }
}
