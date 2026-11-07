import Foundation
import Testing

@testable import LightTouchCore

/// Bounded log reads: the last 64 KB in whole lines, invalid UTF-8, empty and missing files, Clear points and
/// rotation; the console's line filter.
struct LogTailTests {
    @Test func boundedUTF8Tail() throws {
        try withTemporaryFile(named: "serial.log") { file in
            try Data("first\n".utf8).write(to: file)
            #expect(LogTail.read(file) == "first\n")
            var large = Data(repeating: 65, count: 70000)
            large.append(Data("\nlast line\n".utf8))
            try large.write(to: file)
            #expect(LogTail.read(file) == "last line\n", "a cut first line is dropped")
            try Data([255, 10]).write(to: file)
            #expect(LogTail.read(file).contains("\u{fffd}"))
            try Data().write(to: file)
            #expect(LogTail.read(file) == "No log output yet.")
            #expect(LogTail.read(file.appendingPathExtension("missing")).hasPrefix("Cannot read"))
        }
    }

    @Test func clearPointAndRotation() throws {
        try withTemporaryFile(named: "serial.log") { log in
            try Data("old 1\nold 2\n".utf8).write(to: log)
            let size = UInt64(try FileManager.default.attributesOfItem(atPath: log.path)[.size] as! Int)
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("new 3\n".utf8))
            try handle.close()
            let cleared = LogTail.read(log, from: size)
            #expect(cleared.text == "new 3\n" && !cleared.rotated, "clear shows only what came after")
            #expect(LogTail.read(log, from: size + 6).text == "", "cleared and nothing new: empty, not the placeholder")
            try Data("rotated\n".utf8).write(to: log, options: .atomic)
            let rotated = LogTail.read(log, from: size)
            #expect(rotated.rotated && rotated.text == "rotated\n", "a shorter file was replaced: read it all")
        }
    }

    @Test func filterIsCaseInsensitivePerLine() {
        #expect(LogTail.filtered("usb up\nkernel\nUSB down", by: "usb") == "usb up\nUSB down")
        #expect(LogTail.filtered("a\nb", by: "") == "a\nb", "empty filter shows all")
    }
}
