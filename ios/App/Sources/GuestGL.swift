import CryptoKit
import Foundation

// Putting back the GL front end that update 61 replaced.
//
// What 61 did, and why it was wrong
// ---------------------------------
// The GL front end inside a device (OpenGLES.framework/OpenGLES, qemu-ios contrib/gles-public) names its 914
// dispatch slots by decoding the exported trampolines. On iOS 6 it manages only a fraction of them and the rest go
// nowhere, which is real and is why iOS 6 games draw into the wrong place or not at all.
//
// Update 61 swapped in the front end from LightTouchMac v1.0-2026.11.16, on the theory that its decoder reads iOS
// 6's longer trampolines. On the device it named 311 of 914 where the old one named 309. Two slots. The theory was
// wrong: the decoder that reads a MOVW-built offset followed by a register-offset load is in qemu-ios db230fe8e8's
// source, but it is not in the front end that release ships, so swapping the binary bought nothing.
//
// It also broke devices, for a reason worth writing down. OpenGLES lives in the dyld shared cache and preparation
// makes dyld prefer the copy on disk — but not for every process. After the swap, one boot's log showed three
// processes on the old front end (name table 0xad3b3412, 309 named) and three on the new one (0xf31a2b68, 311
// named), against a host that speaks 0xad3b3412 and warns that "the shim was built from another table". Two
// dispatch tables, two sets of slot numbers, one host resolving them as though they were the same. A device coming
// up to a black screen is exactly what that buys.
//
// So this file now only undoes it. The file 61 saved beside the original, OpenGLES.ltm-old, is preparation's own; it
// goes back on the next boot and nothing is installed in its place. A device that never took 61's front end has no
// backup and is left alone.
//
// The real fix for iOS 6's dispatch table is in the host, not the guest: that decoder is in qemu-ios db230fe8e8,
// which this build does not pin. That is the emulator move, and it is the honest way to do this (ios/README.md).

enum GuestGL {
    static let path = "/System/Library/Frameworks/OpenGLES.framework/OpenGLES"
    /// What update 61 saved before writing its own: preparation's front end for this device.
    static let backup = path + ".ltm-old"
    /// Update 61's opt-out marker, removed with the rest so it doesn't outlive what it was for.
    static let keepOld = "/System/Library/Frameworks/OpenGLES.framework/.ltm-keep-old"
    /// The 2026.11.16 front end update 61 installed, by content: only a file that is exactly it is replaced, so a
    /// front end changed some other way is never touched.
    static let installedBy61 = "a92ab6fb7f1b876b8903a8debb0bfe5867bc5b8c0d707a39a50d5ae585441586"

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension GuestAgent {
    /// Puts preparation's GL front end back on a device update 61 changed, and restarts the Home screen so every
    /// process picks up the same one. Quiet on a device that was never changed. Run once the agent answers.
    func revertGLFrontEnd() async {
        guard ops.contains("get"), ops.contains("getrange"), ops.contains("unlink"),
            ops.contains("put") || ops.contains("putpart")
        else { return }
        // No backup means 61 never ran here, or its revert already has.
        guard let old = await getFile(GuestGL.backup), !old.isEmpty else { return }

        let current = await getFile(GuestGL.path)
        if let current, GuestGL.digest(current) == GuestGL.installedBy61 {
            log("GL front end: putting back the one this device was prepared with (update 61\u{2019}s named two more "
                + "slots out of 914 and left processes split across two dispatch tables)\u{2026}")
            guard await unlink(path: GuestGL.path) else {
                log("GL front end: couldn\u{2019}t remove update 61\u{2019}s; left as it is. \(lastLog)")
                return
            }
            guard await putData(old, guestPath: GuestGL.path, mode: "0755"),
                let check = await getFile(GuestGL.path), check == old
            else {
                log("GL front end: PUTTING THE OLD ONE BACK FAILED and this device may not draw. \(lastLog)")
                return
            }
            _ = await unlink(path: GuestGL.backup)
            _ = await unlink(path: GuestGL.keepOld)
            await sync()
            log("GL front end: back to the prepared one; restarting the Home screen so every process loads it")
            await respring()
            return
        }
        // The front end is already something other than 61's: only the leftovers go.
        _ = await unlink(path: GuestGL.backup)
        _ = await unlink(path: GuestGL.keepOld)
        await sync()
    }
}
