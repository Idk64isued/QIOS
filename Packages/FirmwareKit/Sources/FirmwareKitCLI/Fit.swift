// firmwarekit fit --root DIR --arch armv6|armv7 FILE...: FitCheck.loads for each guest Mach-O against the firmware
// whose system volume is mounted (read-only is enough) at DIR. One JSON line per file; exit 1 if any does not fit.
import FirmwareKit
import FirmwareSchema
import Foundation

func fitCommand(_ command: FirmwareCommand.Fit) -> Never {
    let fw = FitCheck.Firmware(root: URL(fileURLWithPath: command.root), arch: command.arch)
    var ok = true
    for f in command.files {
        let fit = FitCheck.loads(
            (f as NSString).lastPathComponent,
            (try? Data(contentsOf: URL(fileURLWithPath: f))) ?? Data(),
            on: fw,
            host: command.host
        )
        ok = ok && fit.fits
        printJSON(fit.object)
    }
    exit(ok ? 0 : 1)
}

/// One JSON line on stdout (keys sorted, slashes as they are).
func printJSON(_ object: [String: Any]) {
    let data =
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
        ?? Data(#"{"error":"unencodable output"}"#.utf8)
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}
