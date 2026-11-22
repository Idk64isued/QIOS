import CryptoKit
import Foundation

// The GL front end inside an iOS 6+ device (OpenGLES.framework/OpenGLES, qemu-ios contrib/gles-public), brought up to
// the one from LightTouchMac v1.0-2026.11.16.
//
// A device's front end is whatever its preparation put in. The one before 2026.11.16 could not read iOS 6's longer
// dispatch stubs (an offset made with MOVW, then a register-offset load): of 6.1.3's 914 dispatch slots it named 309,
// so calls such as the framebuffer and renderbuffer ones went nowhere, and Minecraft drew every frame into an
// incomplete framebuffer (a black screen). The newer front end reads them. It needs three things from the emulator
// that patch 0023 gives this build's (a third word in DRAWABLE_STORAGE, CAPABILITIES, SET_ERROR), so it is put in only
// here, never by hand.
//
// Only a LightTouch front end is replaced (the file says "OpenGLES front end (contrib/gles-public)"), and only on 6.x
// and later, where the old one fails; 1.x-5.x devices keep theirs. The old file is kept beside it as OpenGLES.ltm-old.

enum GuestGL {
    static let path = "/System/Library/Frameworks/OpenGLES.framework/OpenGLES"
    static let backup = path + ".ltm-old"
    /// Present when the user put the old one back (Tweaks): the update leaves that device alone from then on.
    static let keepOld = "/System/Library/Frameworks/OpenGLES.framework/.ltm-keep-old"
    static let resource = "gl-frontend-2026.11.16"
    static let sha256 = "a92ab6fb7f1b876b8903a8debb0bfe5867bc5b8c0d707a39a50d5ae585441586"
    static let marker = Data("[gles] OpenGLES front end (contrib/gles-public)".utf8)

    /// The bundled front end, inflated and checked, or nil (with why) if the app's copy is missing or damaged.
    static func bundled() -> (data: Data?, why: String) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "deflate"),
            let packed = try? Data(contentsOf: url)
        else { return (nil, "the app has no \(resource).deflate") }
        guard let data = try? (packed as NSData).decompressed(using: .zlib) as Data else {
            return (nil, "\(resource).deflate does not inflate")
        }
        guard digest(data) == sha256 else { return (nil, "\(resource) does not match its checksum") }
        return (data, "")
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension GuestAgent {
    /// On iOS 6 and later, replaces an older LightTouch GL front end with the bundled one and restarts the Home
    /// screen so it loads. Quiet when the device already has it. Run once the agent answers.
    func updateGLFrontEnd() async {
        let version = guestVersion ?? "3"
        guard version.compare("6.0", options: .numeric) != .orderedAscending else { return }
        guard ops.contains("get"), ops.contains("getrange"), ops.contains("unlink"), ops.contains("putpart") else { return }

        if await getFile(GuestGL.keepOld) != nil { return }

        guard let current = await getFile(GuestGL.path), !current.isEmpty else {
            log("GL front end: couldn\u{2019}t read \(GuestGL.path); left as it is")
            return
        }
        if GuestGL.digest(current) == GuestGL.sha256 { return }
        guard current.range(of: GuestGL.marker) != nil else {
            log("GL front end: \(GuestGL.path) isn\u{2019}t a LightTouch front end; left as it is")
            return
        }
        let bundled = GuestGL.bundled()
        guard let new = bundled.data else {
            log("GL front end: not updated, \(bundled.why)")
            return
        }

        log("GL front end: updating to 2026.11.16 (iOS \(version) dispatch tables)\u{2026}")
        // Keep the old one, once: the first backup is the preparation's own file.
        if await getFile(GuestGL.backup) == nil {
            guard await putData(current, guestPath: GuestGL.backup, mode: "0755") else {
                log("GL front end: couldn\u{2019}t save the old one; left as it is. \(lastLog)")
                return
            }
        }
        // Unlink before writing: running processes have the file mapped, and writing over it in place would change
        // their code under them. A fresh file leaves their copy alone until they restart.
        guard await unlink(path: GuestGL.path) else {
            log("GL front end: couldn\u{2019}t remove the old one; left as it is. \(lastLog)")
            return
        }
        var check: Data?
        if await putData(new, guestPath: GuestGL.path, mode: "0755") { check = await getFile(GuestGL.path) }
        guard let check, GuestGL.digest(check) == GuestGL.sha256 else {
            // Never leave the device without a GL: put the old one back.
            _ = await unlink(path: GuestGL.path)
            let restored = await putData(current, guestPath: GuestGL.path, mode: "0755")
            log("GL front end: the new one didn\u{2019}t write correctly; \(restored ? "the old one is back" : "RESTORING THE OLD ONE FAILED, rebuild the device") \(lastLog)")
            return
        }
        await sync()
        log("GL front end updated; restarting the Home screen so it loads")
        await respring()
    }

    /// Whether this device has a front end the update replaced (so Tweaks can offer to put it back).
    func hasOldGLFrontEnd() async -> Bool {
        guard (guestVersion ?? "3").compare("6.0", options: .numeric) != .orderedAscending else { return false }
        let backup = await getFile(GuestGL.backup)
        let kept = await getFile(GuestGL.keepOld)
        return backup != nil && kept == nil
    }

    /// Puts the preparation's own front end back and keeps it (the update skips this device from then on).
    func restoreOldGLFrontEnd() async -> Bool {
        guard let old = await getFile(GuestGL.backup), old.range(of: GuestGL.marker) != nil else { return false }
        guard await putData(Data("kept by the user\n".utf8), guestPath: GuestGL.keepOld) else { return false }
        guard await unlink(path: GuestGL.path), await putData(old, guestPath: GuestGL.path, mode: "0755"),
            let check = await getFile(GuestGL.path), check == old
        else { return false }
        await sync()
        log("GL front end: the old one is back, and stays")
        await respring()
        return true
    }
}
