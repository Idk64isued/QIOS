import Foundation

/// A finished command: its status and what it wrote.
public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String
    public var succeeded: Bool { status == 0 }
}

public enum Shell {
    /// Runs `arguments` (the first is the executable: an absolute path, or a name found on PATH, /usr/bin first) to its
    /// exit. Output goes through files, so a chatty tool never blocks on a full pipe. `directory`: its working
    /// directory (a bundle's tool run from inside the bundle can write into it, e.g. a coverage default.profraw).
    @discardableResult
    public static func run(
        _ arguments: [String],
        input: String? = nil,
        environment: [String: String]? = nil,
        directory: URL? = nil,
        timeout: TimeInterval = 600
    ) throws -> CommandResult {
        let process = Process()
        process.currentDirectoryURL = directory
        process.executableURL = URL(fileURLWithPath: try resolve(arguments[0], path: environment?["PATH"]))
        process.arguments = Array(arguments.dropFirst())
        if let environment { process.environment = environment }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "release-checks-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let out = scratch.appendingPathComponent("out")
        let err = scratch.appendingPathComponent("err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: out)
        let errHandle = try FileHandle(forWritingTo: err)
        process.standardOutput = outHandle
        process.standardError = errHandle
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                process.waitUntilExit()
                throw ShellError.timedOut(arguments.joined(separator: " "))
            }
            usleep(20_000)
        }
        try? outHandle.close()
        try? errHandle.close()
        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: (try? Data(contentsOf: out)) ?? Data(), as: UTF8.self),
            error: String(decoding: (try? Data(contentsOf: err)) ?? Data(), as: UTF8.self)
        )
    }

    /// `name` on the command's PATH (the environment it runs in; this process's when it is given none), then the
    /// system's. A command given an environment (ReleaseApp.cleanEnvironment) never finds a tool on this process's PATH.
    static func resolve(_ name: String, path given: String? = nil) throws -> String {
        if name.hasPrefix("/") { return name }
        let path =
            (given ?? ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/libexec"]
        guard
            let found = path.map({ "\($0)/\(name)" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw ShellError.notFound(name)
        }
        return found
    }
}

public enum ShellError: Error, CustomStringConvertible {
    case notFound(String)
    case timedOut(String)
    public var description: String {
        switch self {
        case .notFound(let name): "no \(name) on PATH"
        case .timedOut(let command): "timed out: \(command)"
        }
    }
}

/// `body` with a new scratch directory (symlinks resolved), removed afterward: the release checks' and their tests'.
public func withScratch<T>(_ body: (URL) throws -> T) throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("release-checks-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(root)
}
