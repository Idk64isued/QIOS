// Developer access through stock OpenSSH/SFTP, libusbmuxd inetcat and QEMU GDB.
// Build: swift build -c release --package-path tools/device-access (.build/release/device-access)
import ArgumentParser
import Foundation

struct AccessError: Error, CustomStringConvertible {
    let description: String
}
func fail(_ message: String) throws -> Never { throw AccessError(description: message) }
func sshLiteral(_ value: String) -> String { value.replacingOccurrences(of: "%", with: "%%") }
func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func endpoint(_ value: String) throws -> String {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == "127.0.0.1", let port = UInt16(parts[1]), port > 0 else {
        try fail("Endpoint must be 127.0.0.1:PORT (1–65535).")
    }
    return "127.0.0.1:\(port)"
}
func executable(_ value: String) throws -> String {
    guard value.hasPrefix("/"), !value.contains("\n"), !value.contains("\r"),
        FileManager.default.isExecutableFile(atPath: value)
    else {
        try fail("Tool must be an executable absolute path: \(value)")
    }
    return value
}
struct DeviceAccess: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ltm-device-access",
        abstract: "Developer SSH, SFTP and GDB for one device instance; `-- COMMAND` passes a remote command to ssh."
    )
    enum Mode: String, ExpressibleByArgument {
        case enable, disable, ssh, sftp, config, gdb
    }
    @Argument var mode: Mode
    @Option(transform: { value in
        guard let id = UUID(uuidString: value) else { throw ValidationError("A device instance UUID is required.") }
        return id
    })
    var instance: UUID
    @Option(help: "127.0.0.1:PORT, this instance's private usbmuxd.") var usbmux: String?
    @Option(help: "The inetcat executable, an absolute path.") var inetcat: String?
    @Option(help: "A private key, an absolute path.") var identity: String?
    @Option(help: "The private state directory, an absolute path.") var state: String?
    @Option(help: "127.0.0.1:PORT, the QEMU GDB stub.") var gdb: String?
    @Option(help: "An sftp batch file, an absolute path.") var batch: String?
    @Argument(parsing: .postTerminator) var command: [String] = []

    func run() throws { throw ExitCode(try access(self)) }
}

func access(_ arguments: DeviceAccess) throws -> Int32 {
    var (usbmux, inetcat, gdb) = (arguments.usbmux, arguments.inetcat, arguments.gdb)
    let mode = arguments.mode.rawValue
    let command = arguments.command
    let id = arguments.instance
    guard command.isEmpty || mode == "ssh" else { try fail("Remote commands are supported only for ssh.") }
    if let supplied = usbmux { _ = try endpoint(supplied) }
    if mode == "gdb", let supplied = gdb {
        print("target remote \(try endpoint(supplied))")
        return 0
    }
    let alias = "lighttouch-" + id.uuidString.lowercased()
    if let directory = arguments.state, !directory.hasPrefix("/") {
        try fail("State directory must be an absolute path.")
    }
    let base =
        arguments.state.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Light Touch/DeveloperSSH",
            isDirectory: true
        )
    guard base.path.hasPrefix("/"), !base.path.contains("\n"), !base.path.contains("\r") else {
        try fail("State directory must be an absolute path without newlines.")
    }
    let state = base.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(
        at: state,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
    let profile = state.appendingPathComponent("connection.json")
    if FileManager.default.fileExists(atPath: profile.path), mode != "enable", mode != "disable" {
        struct Connection: Decodable {
            let instance: UUID
            let usbmux: String
            let inetcat: String
            let gdb: String?
        }
        let connection = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: profile))
        guard connection.instance == id else { try fail("Connection profile belongs to another instance.") }
        usbmux = usbmux ?? connection.usbmux
        inetcat = inetcat ?? connection.inetcat
        gdb = gdb ?? connection.gdb
    }
    if mode == "enable" || mode == "disable" {
        let marker = state.appendingPathComponent("enabled")
        if mode == "enable" {
            try Data("1\n".utf8).write(to: marker, options: .atomic)
            print("Developer SSH enabled; restart the device to provision its private keys and upstream tools.")
        } else {
            try? FileManager.default.removeItem(at: marker)
            print("Developer SSH disabled; restart the device to revert its package hooks and stop sshd.")
        }
        return 0
    }
    if mode == "gdb" {
        guard let address = gdb else { try fail("Supply the actual enabled QEMU GDB stub with --gdb.") }
        print("target remote \(try endpoint(address))")
        return 0
    }
    guard let socket = usbmux, let tool = inetcat else {
        try fail("Supply this instance’s private --usbmux endpoint and --inetcat executable.")
    }
    let socketAddress = try endpoint(socket)
    let inetcatPath = try executable(tool)
    let knownHosts = state.appendingPathComponent("known_hosts").path
    let proxy =
        "exec /usr/bin/env " + shellQuote("USBMUXD_SOCKET_ADDRESS=" + socketAddress) + " "
        + shellQuote(sshLiteral(inetcatPath)) + " -l %p"
    var sshOptions = [
        "HostName=localhost", "Port=22", "User=root", "HostKeyAlias=" + alias,
        "UserKnownHostsFile=" + shellQuote(sshLiteral(knownHosts)),
        "StrictHostKeyChecking=" + (FileManager.default.fileExists(atPath: knownHosts) ? "yes" : "ask"),
        "ProxyCommand=" + proxy, "ConnectTimeout=10", "ServerAliveInterval=15", "ServerAliveCountMax=2"
    ]
    let provisionedIdentity = state.appendingPathComponent("id_ecdsa").path
    if let identity = arguments.identity
        ?? (FileManager.default.fileExists(atPath: provisionedIdentity) ? provisionedIdentity : nil)
    {
        guard identity.hasPrefix("/"), !identity.contains("\n"), !identity.contains("\r"),
            FileManager.default.fileExists(atPath: identity)
        else {
            try fail("Identity must name an existing absolute private-key path.")
        }
        sshOptions += [
            "IdentityFile=" + shellQuote(sshLiteral(identity)), "IdentitiesOnly=yes",
            "PreferredAuthentications=publickey"
        ]
    }
    if mode == "config" {
        print("Host \(alias)")
        for option in sshOptions {
            let pair = option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            print("  \(pair[0]) \(pair[1])")
        }
        return 0
    }
    var batchArguments: [String] = []
    if let batch = arguments.batch {
        guard mode == "sftp", batch.hasPrefix("/"), FileManager.default.isReadableFile(atPath: batch) else {
            try fail("--batch requires sftp and a readable absolute file path.")
        }
        batchArguments = ["-b", batch]
    }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: mode == "ssh" ? "/usr/bin/ssh" : "/usr/bin/sftp")
    child.arguments = sshOptions.flatMap { ["-o", $0] } + batchArguments + [alias] + command
    // Standard clients own terminal I/O, authentication and the transfer protocol.
    child.standardInput = FileHandle.standardInput
    child.standardOutput = FileHandle.standardOutput
    child.standardError = FileHandle.standardError
    try child.run()
    child.waitUntilExit()
    return child.terminationStatus
}
DeviceAccess.main()
