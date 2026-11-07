// firmwarekit unwrap --entry ENTRY.json --archive FILE --out IPSW
//   A "rar" source's downloaded archive -> its checked IPSW (RARSource.unwrap); the app runs this when such a
//   download finishes. The archive is left to the caller.
// firmwarekit fetch --entry ENTRY.json --out IPSW
//   The entry's IPSW from its source, then each mirror (SourceFetch): checked as the catalog says, a "rar" one
//   unwrapped, the archive deleted afterwards; any failure moves on to the next, each attempt logged on stderr. For
//   scripts and end-to-end checks; the app downloads itself.
// One JSON line {ipsw, sha1, bytes} on success; {"error": ...} and exit 1 otherwise.

import FirmwareKit
import FirmwareSchema
import Foundation

private func done(_ object: [String: Any], _ code: Int32) -> Never {
    printJSON(object)
    exit(code)
}

func unwrapCommand(_ command: FirmwareCommand.Unwrap) -> Never {
    let out = fileURL(command.out)
    do {
        let entry = try FirmwareEntry.load(from: fileURL(command.entry))
        try RARSource.unwrap(fileURL(command.archive), source: entry.source, to: out)
        done(["ipsw": out.path, "sha1": entry.source.sha1 ?? "", "bytes": entry.source.bytes ?? 0], 0)
    } catch {
        done(["error": "\(error)"], 1)
    }
}

func fetchCommand(_ command: FirmwareCommand.Fetch) -> Never {
    let out = fileURL(command.out)
    do {
        let source = try FirmwareEntry.load(from: fileURL(command.entry)).source
        guard source.sha1 != nil, !source.urls.isEmpty else {
            throw FirmwareError(.unsupported, "the entry's source has no URL and SHA-1")
        }
        let from = try SourceFetch.fetch(source, to: out, download: SourceFetch.download) {
            FileHandle.standardError.write(Data("fetch: \($0)\n".utf8))
        }
        done(["ipsw": out.path, "sha1": source.sha1 ?? "", "bytes": source.bytes ?? 0, "from": from.absoluteString], 0)
    } catch {
        done(["error": "\(error)"], 1)
    }
}
