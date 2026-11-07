// A catalog source of kind "rar": the IPSW is a member of a RAR archive (BetaArchive's developer betas on
// archive.org, the only public copies of builds Apple hosted behind its developer login).
//
//   RARSource.unwrap(archive, source: entry.source, to: ipsw)
//
// The archive must weigh archive_bytes and hash to archive_sha1; its `member` is extracted streaming (UnRAR via
// Unrar.swift, extraction only) beside `ipsw`, must weigh bytes and hash to sha1, and only then becomes `ipsw`.
// Nothing partial is ever left at `ipsw`. The caller deletes the archive.

import Crypto
import FirmwareSchema
import Foundation
import Unrar

public enum RARSource {
    public static func unwrap(
        _ archive: URL,
        source: FirmwareWire.Entry.Source,
        to ipsw: URL,
        progress: ((Double) -> Void)? = nil
    ) throws {
        guard source.isArchive, let member = source.member, let sha1 = source.sha1, let archiveSHA1 = source.archiveSHA1
        else {
            throw FirmwareError(.unsupported, "not a rar source with member, sha1 and archive_sha1")
        }
        if let bytes = source.archiveBytes, size(archive) != bytes {
            throw FirmwareError(
                .shaMismatch,
                "\(archive.lastPathComponent): \(size(archive)) bytes, not the archive's \(bytes)"
            )
        }
        let got = try Preparer.digest(archive, Insecure.SHA1())
        guard got == archiveSHA1 else {
            throw FirmwareError(
                .shaMismatch,
                "\(archive.lastPathComponent): SHA-1 \(got), not the archive's \(archiveSHA1)"
            )
        }
        let rar: Archive
        let entries: [Entry]
        do {
            rar = try Archive(fileURL: archive)
            entries = try rar.entries()
        } catch {
            throw FirmwareError(.unsupported, "\(archive.lastPathComponent): not a readable RAR archive (\(error))")
        }
        // RAR names use the archiver's separator (BetaArchive's are Windows paths: media_ipsw\iPod4,1_….ipsw).
        guard
            let entry = entries.first(where: {
                $0.fileName.replacingOccurrences(of: "\\", with: "/").hasSuffix(member) && !$0.directory
            })
        else {
            throw FirmwareError(.unsupported, "\(archive.lastPathComponent) has no \(member)")
        }
        let partial = ipsw.deletingLastPathComponent().appendingPathComponent(".\(ipsw.lastPathComponent).unrar")
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw FirmwareError(.internal, "cannot create \(partial.path)")
        }
        defer { try? FileManager.default.removeItem(at: partial) }
        let out = try FileHandle(forWritingTo: partial)
        var hash = Insecure.SHA1()
        var written: Int64 = 0
        var failure: Error?
        do {
            try rar.extract(entry) { data, p in
                guard failure == nil else {
                    p.cancel()
                    return
                }
                do { try out.write(contentsOf: data) } catch {
                    failure = error
                    p.cancel()
                    return
                }
                hash.update(data: data)
                written += Int64(data.count)
                progress?(p.fractionCompleted)
            }
        } catch {
            try? out.close()
            throw failure ?? FirmwareError(.internal, "extracting \(member): \(error)")
        }
        try out.close()
        if let failure { throw failure }
        let inner = hash.finalize().hexString
        guard source.bytes.map({ $0 == written }) ?? true, inner == sha1 else {
            throw FirmwareError(
                .shaMismatch,
                "\(member): \(written) bytes, SHA-1 \(inner); the catalog's IPSW is \(source.bytes.map(String.init) ?? "?") bytes, \(sha1)"
            )
        }
        try? FileManager.default.removeItem(at: ipsw)
        try FileManager.default.moveItem(at: partial, to: ipsw)
    }

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
    }
}
