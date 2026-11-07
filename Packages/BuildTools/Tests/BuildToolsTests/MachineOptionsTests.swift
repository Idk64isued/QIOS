import Foundation
import Testing

@testable import BuildTools

struct MachineOptionsTests {
    /// A stand-in QEMU: reads the QMP commands, answers with `replies` (CR LF, as QMP ends its lines).
    func qemu(_ replies: [String]) -> [String] {
        ["/bin/sh", "-c", "cat > /dev/null; printf '%s\\r\\n' \"$@\"", "sh"] + replies
    }

    func fixture() throws -> URL {
        let file = files.temporaryDirectory.appendingPathComponent("machines-\(UUID().uuidString).json")
        try Data(#"[{"board": "n90ap", "machine": "iPhone4"}, {"board": "k48ap", "machine": "iPad1"}]"#.utf8)
            .write(to: file)
        return file
    }

    /// One entry per board, sorted by board, each machine's property names sorted and without "type".
    @Test func eachBoardGetsItsMachinesProperties() throws {
        let machines = try fixture()
        defer { remove(machines) }
        let text = try MachineOptions.source(
            qemu: qemu([
                #"{"QMP": {}}"#, #"{"return": {}}"#, #"{"return": [{"name": "type"}, {"name": "b"}, {"name": "a"}]}"#,
                #"{"return": [{"name": "nand"}]}"#, #"{"event": "SHUTDOWN"}"#, #"{"return": {}}"#
            ]),
            machines: machines
        )
        #expect(
            text.hasSuffix(
                """
                private let declaredMachineOptions: [String: Set<String>] = [
                    "k48ap": [
                        "a",
                        "b"
                    ],
                    "n90ap": [
                        "nand"
                    ]
                ]

                """
            )
        )
    }

    /// A QEMU without one of the machine types answers with an error, not a list: no table.
    @Test func aMissingMachineFails() throws {
        let machines = try fixture()
        defer { remove(machines) }
        #expect(throws: ToolError.self) {
            try MachineOptions.source(
                qemu: qemu([#"{"return": [{"name": "a"}]}"#, #"{"error": {"class": "GenericError"}}"#]),
                machines: machines
            )
        }
    }
}
