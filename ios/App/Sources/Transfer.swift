import CryptoKit
import Foundation

/// Downloads and file hashing for everything the app fetches (IPSWs, the Mac release, IPAs).
/// A download streams straight to disk, so a 400 MB file costs no memory, and it stops when its task is cancelled.
enum Transfer {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "LightTouch-iOS/\(version) (+https://github.com/Idk64isued/QIOS)"
    }()

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Downloads `url` to `destination` (replacing it). `progress` gets 0...1, or -1 while the size is unknown; it is
    /// called off the main thread, a few times a second. `expectedBytes` is used when the server names no length.
    static func download(
        _ url: URL,
        to destination: URL,
        expectedBytes: Int64? = nil,
        progress: @escaping (Double) -> Void
    ) async throws {
        let job = DownloadJob(destination: destination, expectedBytes: expectedBytes, progress: progress)
        try await job.run(request(url))
    }

    /// Small JSON or text answers.
    static func data(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(url))
        if let code = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
            throw Failure(message: "\(url.host ?? "The server") answered HTTP \(code).")
        }
        return data
    }

    // MARK: - Hashing (4 MiB at a time, never the whole file)

    private static func digest<H: HashFunction>(_ url: URL, _ hash: H, progress: ((Double) -> Void)?) throws -> String {
        var hash = hash
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = max(1, fileSize(url))
        var read: Int64 = 0
        while true {
            try Task.checkCancellation()
            let next = try autoreleasepool { try handle.read(upToCount: 4 << 20) }
            guard let chunk = next, !chunk.isEmpty else { break }
            hash.update(data: chunk)
            read += Int64(chunk.count)
            progress?(min(1, Double(read) / Double(size)))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha1(of url: URL, progress: ((Double) -> Void)? = nil) throws -> String {
        try digest(url, Insecure.SHA1(), progress: progress)
    }

    static func sha256(of url: URL, progress: ((Double) -> Void)? = nil) throws -> String {
        try digest(url, SHA256(), progress: progress)
    }

    static func md5(of url: URL, progress: ((Double) -> Void)? = nil) throws -> String {
        try digest(url, Insecure.MD5(), progress: progress)
    }

    // MARK: - Sizes

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// What a file or folder really takes on the phone (a sparse NAND image counts only the blocks it holds).
    static func diskUsage(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        func allocated(_ item: URL) -> Int64 {
            guard let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return allocated(url) }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [])
        else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker { total += allocated(item) }
        return total
    }

    static func freeSpace() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let free = values.volumeAvailableCapacityForImportantUsage, free > 0
        {
            return free
        }
        return ((try? FileManager.default.attributesOfFileSystem(forPath: home.path))?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// One URLSession download task and its delegate. The file is moved into place inside the delegate call, because the
/// system deletes its temporary file as soon as that call returns.
private final class DownloadJob: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedBytes: Int64?
    private let progress: (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var lastReport = Date.distantPast

    init(destination: URL, expectedBytes: Int64?, progress: @escaping (Double) -> Void) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func run(_ request: URLRequest) async throws {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: request)
                self.lock.lock()
                self.continuation = continuation
                self.task = task
                self.lock.unlock()
                if Task.isCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.15 else { return }
        lastReport = now
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (expectedBytes ?? 0)
        progress(total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : -1)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(code) else {
            let host = downloadTask.originalRequest?.url?.host ?? "The server"
            outcome = .failure(Transfer.Failure(message: code == 503
                ? "\(host) is busy right now. Try again in a minute." : "\(host) answered HTTP \(code)."))
            return
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<Void, Error>
        if let error {
            let cancelled = (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
            result = .failure(cancelled ? CancellationError() : error)
        } else {
            result = outcome ?? .failure(Transfer.Failure(message: "The download ended without a file."))
        }
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
