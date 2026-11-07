import Foundation

/// A fresh directory under the temporary directory, removed after `body`.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ltm-tests-" + UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

/// A path for one file in a fresh temporary directory.
func withTemporaryFile<T>(named name: String = "file", _ body: (URL) throws -> T) throws -> T {
    try withTemporaryDirectory { try body($0.appendingPathComponent(name)) }
}
