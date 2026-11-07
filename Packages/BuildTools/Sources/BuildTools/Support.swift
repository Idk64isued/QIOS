import BuildSupport
import CryptoKit
import Foundation

/// A failure the tools report as one line on stderr and exit 1.
public struct ToolError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

var files: FileManager { .default }

func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

/// A file's SHA-256, hex.
func sha256(_ file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hash = SHA256()
    while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { hash.update(data: block) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func readJSON(_ file: URL) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
        throw ToolError("\(file.path): not a JSON object")
    }
    return object
}

func writeJSON(_ object: Any, to file: URL) throws {
    try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try (data + Data("\n".utf8)).write(to: file, options: .atomic)
}

/// Runs a command to its exit, its output and error appended to `log` (or inherited); throws on a nonzero status.
func run(_ arguments: [String], log: URL? = nil, environment: [String: String]? = nil, in directory: URL? = nil) throws
{
    let process = Process()
    process.executableURL = url(arguments[0].hasPrefix("/") ? arguments[0] : "/usr/bin/env")
    process.arguments = arguments[0].hasPrefix("/") ? Array(arguments.dropFirst()) : arguments
    if let environment { process.environment = environment }
    if let directory { process.currentDirectoryURL = directory }
    process.standardInput = FileHandle.nullDevice
    if let log {
        try files.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !files.fileExists(atPath: log.path) { files.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data("\n+ \(arguments.joined(separator: " "))\n".utf8))
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
    } else {
        try process.run()
        process.waitUntilExit()
    }
    guard process.terminationStatus == 0 else {
        var message = "\(arguments[0]) failed (\(process.terminationStatus))"
        if let log {
            let tail = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).suffix(25)
            message = tail.joined(separator: "\n") + "\n\(message); see \(log.path)"
        }
        throw ToolError(message)
    }
}

/// A command's standard output, trimmed; throws on a nonzero status.
func output(_ arguments: [String], environment: [String: String]? = nil) throws -> String {
    let result = try Shell.run(arguments, environment: environment)
    guard result.succeeded else {
        throw ToolError("\(arguments.joined(separator: " ")) failed (\(result.status)): \(result.error)")
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Finder's folder settings, which appear in any directory someone opened in Finder: never an input or an output.
func isFinderLitter(_ name: String) -> Bool { (name as NSString).lastPathComponent == ".DS_Store" }

/// Every regular file and symlink under `root` (not descending into linked directories), relative paths, sorted.
func walk(_ root: URL) -> [String] {
    guard let e = files.enumerator(atPath: root.resolvingSymlinksInPath().path) else { return [] }
    var found: [String] = []
    while let name = e.nextObject() as? String {
        let type = e.fileAttributes?[.type] as? FileAttributeType
        if (type == .typeRegular || type == .typeSymbolicLink) && !isFinderLitter(name) { found.append(name) }
    }
    return found.sorted()
}

/// A directory's entries, sorted by path, without Finder's .DS_Store.
func entries(_ directory: URL) throws -> [URL] {
    try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { !isFinderLitter($0.lastPathComponent) }.sorted { $0.path < $1.path }
}

func remove(_ path: URL) { try? files.removeItem(at: path) }
