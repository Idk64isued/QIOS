import Foundation

/// One job of a matrix file.
public struct MatrixJob: Equatable, Sendable {
    public let name: String
    /// A prepared base's path, or nil when `create` makes one.
    public let base: String?
    /// firmwarekit create's flags (--id, --ipsw, …) without the ones the runner adds.
    public let create: [String]
    /// The check and its flags, the base inserted after the check's name; empty: single as the base was prepared.
    public let check: [String]

    public struct Invalid: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    public static func parse(_ text: String) throws -> [MatrixJob] {
        try text.split(separator: "\n").compactMap { raw -> MatrixJob? in
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = words.first else { return nil }
            let dash = words.firstIndex(of: "--") ?? words.endIndex
            let head = Array(words[1..<dash])
            let check = Array(words[min(dash + 1, words.endIndex)...])
            guard let first = head.first else { throw MatrixJob.Invalid("\(name): no base and no --id") }
            if first.hasPrefix("-") {
                guard head.contains("--id"), head.contains("--ipsw") else {
                    throw MatrixJob.Invalid("\(name): a preparation needs --id and --ipsw")
                }
                return MatrixJob(name: name, base: nil, create: head, check: check)
            }
            guard head.count == 1 else { throw MatrixJob.Invalid("\(name): one base, then -- and the check") }
            return MatrixJob(name: name, base: (first as NSString).expandingTildeInPath, create: [], check: check)
        }
    }
}
