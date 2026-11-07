// An entry's IPSW from its source and mirrors (FirmwareWire.Entry.Source.alternatives), in order: the next one on
// any failure (an HTTP error, a timeout, other bytes). A "rar" alternative is unwrapped (RARSource) into the IPSW.
//
//   let from = try SourceFetch.fetch(entry.source, to: ipsw, download: get, log: log)
//
// `download(url, file)` puts one URL's bytes at `file` or throws. Nothing but a checked IPSW is ever left at `out`.

import Crypto
import FirmwareSchema
import Foundation

public enum SourceFetch {
    /// The URL that served the IPSW now at `out`; the last alternative's error when none did.
    @discardableResult
    public static func fetch(
        _ source: FirmwareWire.Entry.Source,
        to out: URL,
        download: (URL, URL) throws -> Void,
        log: (String) -> Void = { _ in }
    ) throws -> URL {
        let file = out.deletingLastPathComponent().appendingPathComponent(".\(out.lastPathComponent).download")
        defer { try? FileManager.default.removeItem(at: file) }
        var last: Error = FirmwareError(.unsupported, "the entry's source has no URL")
        for alternative in source.alternatives {
            guard let url = alternative.url, let want = alternative.downloadSHA1 else { continue }
            do {
                log("trying \(url.absoluteString)")
                try? FileManager.default.removeItem(at: file)
                try download(url, file)
                if alternative.isArchive {
                    try RARSource.unwrap(file, source: alternative, to: out)
                } else {
                    let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? -1
                    if let bytes = alternative.bytes, bytes != size {
                        throw FirmwareError(.shaMismatch, "\(size) bytes, not \(bytes)")
                    }
                    let got = try Preparer.digest(file, Insecure.SHA1())
                    guard got == want else { throw FirmwareError(.shaMismatch, "SHA-1 \(got), not \(want)") }
                    try? FileManager.default.removeItem(at: out)
                    try FileManager.default.moveItem(at: file, to: out)
                }
                log("served by \(url.absoluteString)")
                return url
            } catch {
                last = error
                log(
                    "\(url.absoluteString) failed: \((error as? FirmwareError).map { "\($0)" } ?? error.localizedDescription)"
                )
            }
        }
        throw last
    }

    /// One URL to `file`, synchronously (URLSession's download task; redirects followed).
    public static func download(_ url: URL, to file: URL) throws {
        let finished = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<Void, Error> = .failure(FirmwareError(.internal, "no response"))
        URLSession.shared.downloadTask(with: url) { location, response, error in
            defer { finished.signal() }
            if let error {
                result = .failure(error)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard let location, (200..<300).contains(status) else {
                result = .failure(FirmwareError(.internal, "HTTP \(status)"))
                return
            }
            result = Result {
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: location, to: file)
            }
        }.resume()
        finished.wait()
        try result.get()
    }
}
