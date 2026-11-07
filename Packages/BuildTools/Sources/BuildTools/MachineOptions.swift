// HostRuntime's MachineOptions.swift, generated from a libqemu-arm.dylib: the -machine options each board's machine
// declares (qom-list-properties of each machine type in tests/fixtures/machines.json, class and instance properties
// both). A boot passes no other (PreparedDeviceBoot). scripts/vendor writes it for the pinned QEMU and
// scripts/vendor-check fails the build while the checkout's copy differs.
import Foundation

public enum MachineOptions {
    /// Where the table lives in the repository.
    public static let path = "Packages/HostRuntime/Sources/HostRuntime/MachineOptions.swift"

    /// The table's source for the QEMU that `qemu` runs (a command hosting libqemu-arm.dylib's qemu_ios_main, which
    /// is given QMP on stdio).
    public static func source(qemu: [String], machines fixture: URL) throws -> String {
        let listed = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [[String: Any]] ?? []
        let machines = listed.compactMap { m in
            (m["board"] as? String).flatMap { board in (m["machine"] as? String).map { (board, $0) } }
        }.sorted { $0.0 < $1.0 }
        var commands: [[String: Any]] = [["execute": "qmp_capabilities"]]
        commands += machines.map {
            ["execute": "qom-list-properties", "arguments": ["typename": "\($0.1)-machine"]]
        }
        commands.append(["execute": "quit"])
        let input =
            try commands.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        let text = try converse(qemu + ["-M", "none", "-display", "none", "-nodefaults", "-qmp", "stdio"], input: input)
        // QMP ends its lines with CR LF, one Character in Swift
        let replies = text.split(whereSeparator: \.isNewline).compactMap { line in
            ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["return"]
                as? [[String: Any]]
        }
        guard replies.count == machines.count else {
            throw ToolError("machine-options: \(replies.count) property lists for \(machines.count) machines\n\(text)")
        }
        let entries = zip(machines, replies).map { machine, properties in
            let names = Set(properties.compactMap { $0["name"] as? String }).subtracting(["type"]).sorted()
            return "    \"\(machine.0)\": [\n" + names.map { "        \"\($0)\"" }.joined(separator: ",\n") + "\n    ]"
        }
        // No trailing commas, as swift-format writes it (.swift-format), so the hook leaves the file as written here.
        return """
            // The -machine options each board's machine declares, from qemu-ios's qom-list-properties of each machine
            // type: written by scripts/vendor for the pinned qemu-ios (scripts/vendor-check fails the build while this
            // differs). Don't edit it by hand.

            extension Board {
                /// The -machine options this board's machine declares; a boot passes no other (PreparedDeviceBoot).
                public var machineOptions: Set<String> { declaredMachineOptions[rawValue] ?? [] }
            }

            private let declaredMachineOptions: [String: Set<String>] = [
            \(entries.joined(separator: ",\n"))
            ]

            """
    }

    /// Runs `arguments` with `input` on its standard input; its standard output, or a failure with its error output.
    static func converse(_ arguments: [String], input: String) throws -> String {
        let process = Process()
        process.executableURL = url(arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        // ponytail: stderr is read after stdout ends; QEMU's few lines there never fill the pipe.
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ToolError(
                "\(arguments.joined(separator: " ")) failed (\(process.terminationStatus)): \(String(decoding: err, as: UTF8.self))"
            )
        }
        return String(decoding: out, as: UTF8.self)
    }
}
