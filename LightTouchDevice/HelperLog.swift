import Foundation

/// A line to the helper's stderr (the app's pipe into the device's native.log). A write that can't land is dropped:
/// once the app is gone that pipe has no reader, and FileHandle.write(_:) raises on EPIPE, which aborted the helper
/// in its own "link closed" shutdown, before the halt flushed the device's storage.
func writeStandardError(_ text: String, to handle: FileHandle = .standardError) {
    try? handle.write(contentsOf: Data(text.utf8))
}

func helperLog(_ message: String, to handle: FileHandle = .standardError) {
    var tv = timeval()
    gettimeofday(&tv, nil)
    let line =
        String(format: "[LightTouchDevice %d %.3f] ", getpid(), Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6) + message
        + "\n"
    writeStandardError(line, to: handle)
}
