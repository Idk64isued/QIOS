import Compression
import CryptoKit
import Foundation

/// Unpacks a Light Touch packed device (an .itbase folder, e.g. the Mac app's Contents/Resources/Device/n72ap-7E18.itbase)
/// into a device base, on the phone. Same as FirmwareKit's PreparedBase.unpack for the files (the identity reseed and
/// language seed are not done: the packed base is an en-US device that boots with the identity it was packed with).
///
/// Layout: index.json {format 2, chunkBytes 1 MiB, files[{name,size,mode,sha256}], images[{name,size,mode,chunks}]},
/// files/<name> whole, <image minus extension>/<NNNNNN>.z a zlib chunk of the image, no file = a hole of zeros.
/// The NAND image is sparse (ftruncate + pwrite), so only the chunks that hold data take space on the phone.
enum PackedDevice {
    struct Index: Decodable {
        struct File: Decodable { let name: String; let size: Int; let mode: Int; let sha256: String }
        struct Image: Decodable { let name: String; let size: Int; let mode: Int; let chunks: [String: String] }
        let format: Int
        let chunkBytes: Int
        let files: [File]
        let images: [Image]
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let chunk = 1 << 20

    /// The packed devices found in Files > Light Touch (at the top, or in Device/).
    static func find() -> [URL] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var found: [URL] = []
        for folder in [docs, docs.appendingPathComponent("Device", isDirectory: true)] {
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            found += items.filter { $0.pathExtension == "itbase" }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func safe(_ name: String) throws -> String {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        if name.isEmpty || name.hasPrefix("/") || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            throw Failure(message: "refusing entry name \(name)")
        }
        return name
    }

    /// A zlib stream (2-byte header, deflate, 4-byte adler32) -> its bytes; Compression's ZLIB is the raw deflate part.
    static func inflate(_ packed: Data, expected: Int) -> [UInt8]? {
        guard packed.count > 6, expected > 0 else { return nil }
        let body = packed.dropFirst(2).dropLast(4)
        var out = [UInt8](repeating: 0, count: expected)
        let n: Int = body.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                guard let s = src.bindMemory(to: UInt8.self).baseAddress, let d = dst.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(d, expected, s, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n == expected ? out : nil
    }

    /// Unpacks `itbase` into `base` (which must not exist yet). `progress` gets 0...1 and may be called off the main thread.
    static func unpack(itbase: URL, into base: URL, progress: (Double) -> Void) throws {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: itbase.appendingPathComponent("index.json")),
            let index = try? JSONDecoder().decode(Index.self, from: data)
        else { throw Failure(message: "\(itbase.lastPathComponent) has no readable index.json: not a packed device.") }
        guard index.format == 2, index.chunkBytes == chunk else {
            throw Failure(message: "Unsupported packed-device format \(index.format) (chunk \(index.chunkBytes)).")
        }
        if fm.fileExists(atPath: base.path) { throw Failure(message: "\(base.path) already exists.") }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        let total = Double(max(index.files.count + index.images.reduce(0) { $0 + $1.chunks.count }, 1))
        var done = 0.0
        progress(0)

        for f in index.files {
            let name = try safe(f.name)
            let content = try Data(contentsOf: itbase.appendingPathComponent("files/\(name)"))
            guard content.count == f.size, hex(content) == f.sha256 else { throw Failure(message: "\(name) differs from its index.") }
            let url = base.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url)
            done += 1
            progress(done / total)
        }

        for image in index.images {
            let name = try safe(image.name)
            let url = base.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o644)
            guard fd >= 0, ftruncate(fd, off_t(image.size)) == 0 else {
                throw Failure(message: "\(name): \(String(cString: strerror(errno)))")
            }
            defer { close(fd) }
            let stem = (name as NSString).deletingPathExtension
            for (number, want) in image.chunks.sorted(by: { $0.key < $1.key }) {
                guard let i = Int(number), i >= 0, i * chunk < image.size else {
                    throw Failure(message: "\(name) chunk \(number) is outside the image.")
                }
                let packed = try Data(contentsOf: itbase.appendingPathComponent("\(stem)/\(number).z"))
                let length = min(chunk, image.size - i * chunk)
                guard let raw = inflate(packed, expected: length), hex(Data(raw)) == want else {
                    throw Failure(message: "\(name) chunk \(number) is damaged.")
                }
                let written = raw.withUnsafeBytes { pwrite(fd, $0.baseAddress, length, off_t(i * chunk)) }
                guard written == length else {
                    throw Failure(message: errno == ENOSPC ? "The phone is out of space." : "\(name): \(String(cString: strerror(errno)))")
                }
                done += 1
                progress(done / total)
            }
        }
        guard fm.fileExists(atPath: base.appendingPathComponent("device.lock.json").path) else {
            throw Failure(message: "Unpacked, but there is no device.lock.json: wrong or incomplete packed device.")
        }
        progress(1)
    }
}

/// Runs an unpack off the main thread and reports to the UI.
@MainActor
final class Importer: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var fraction = 0.0
    @Published private(set) var message = ""

    func unpack(_ itbase: URL, whenDone: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        fraction = 0
        message = "Unpacking \(itbase.lastPathComponent)…"
        let stem = itbase.deletingPathExtension().lastPathComponent
        let base = Library.devices.appendingPathComponent(stem, isDirectory: true).appendingPathComponent("base", isDirectory: true)
        Task.detached(priority: .userInitiated) { [weak self] in
            var result = "Unpacked \(stem). Pull down to refresh the list."
            do {
                try PackedDevice.unpack(itbase: itbase, into: base) { f in
                    Task { @MainActor in self?.fraction = f }
                }
            } catch {
                try? FileManager.default.removeItem(at: base.deletingLastPathComponent())  // no half-made device
                result = error.localizedDescription
            }
            await MainActor.run {
                self?.message = result
                self?.busy = false
                whenDone()
            }
        }
    }
}
