import Foundation

/// Bridge to the QEMU guest agent (contrib/it-agent). The agent runs inside the emulated
/// device and communicates over a cp15 tunnel — no USB or network needed. It can put files,
/// launch apps, read the guest's state, and more. We use it to install IPAs and interact
/// with a jailbroken guest that has /bin/mkdir and shell tools.
///
/// Wire format:  request  = "<uuid> <op> <args>\n<base64 body>"
///               result   = "<id> <status>\n<base64>"
///
/// The C API is resolved lazily from the emulator dylib (it may be absent in older builds).
@MainActor
final class GuestAgent: ObservableObject {
    private let qemu: QemuRuntime

    @Published private(set) var status: AgentStatus = .unknown
    @Published private(set) var version: String = ""
    @Published private(set) var ops: [String] = []
    @Published private(set) var hasShell: Bool = false   // /bin/mkdir exists → jailbroken guest
    @Published private(set) var lastLog: String = ""
    @Published private(set) var isBusy: Bool = false

    enum AgentStatus: String {
        case unknown   = "unknown"
        case absent    = "absent"
        case alive     = "alive"
        case stale     = "stale"
    }

    init(qemu: QemuRuntime) {
        self.qemu = qemu
    }

    // MARK: - C API wrappers (resolved from QemuRuntime)

    private func agentRequest(_ request: String) -> Bool {
        guard let fn = qemu.agentRequest else { return false }
        return request.withCString { fn($0) }
    }

    private func agentCancel(_ id: String) {
        guard let fn = qemu.agentCancel else { return }
        id.withCString { fn($0) }
    }

    private func agentResult() -> String? {
        guard let fn = qemu.agentResult, let freeResult = qemu.agentFreeResult else { return nil }
        guard let ptr = fn() else { return nil }
        let result = String(cString: ptr)
        freeResult(ptr)
        return result
    }

    private func agentStatusRaw() -> Int32 {
        guard let fn = qemu.agentStatus else { return -1 }
        return fn()
    }

    // MARK: - Public operations

    /// Polls the agent status and runs a ping to discover version + ops.
    /// probe() is called every few seconds until the agent answers, so a "not here yet" is only logged once.
    private var loggedAbsent = false

    func probe() async {
        let raw = agentStatusRaw()
        switch raw {
        case 0:
            status = .absent
            if !loggedAbsent { loggedAbsent = true; log("Agent not running in guest yet; still watching") }
            return
        case 1: status = .alive
        case 2: status = .stale; if !loggedAbsent { loggedAbsent = true; log("Agent stale") }; return
        default:
            status = .unknown
            if !loggedAbsent { loggedAbsent = true; log("Agent API not available in this emulator build") }
            return
        }
        loggedAbsent = false

        // Send a ping to get version and supported ops
        let id = UUID().uuidString
        let body = ""  // ping has no body
        let ok = agentRequest("\(id) ping\n\(body)")
        guard ok else { log("ping request failed"); return }

        // Poll for result (up to 5 seconds)
        let result = await pollResult(id: id, timeout: 5.0)
        guard let result else { log("ping timed out"); return }

        // Parse: "it_agent v6\nops ping spawn sync put putpart get ..."
        let lines = result.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("it_agent") {
            version = first
            log("Agent: \(first)")
        }
        if lines.count > 1, lines[1].hasPrefix("ops ") {
            ops = lines[1].dropFirst(4).components(separatedBy: " ").filter { !$0.isEmpty }
            log("Ops: \(ops.joined(separator: ", "))")
        }
    }

    /// Put a file into the guest filesystem.
    /// For files > ~250 KB, uses putpart (256 KiB chunks minus header overhead).
    func putFile(localURL: URL, guestPath: String, mode: String = "0644") async -> Bool {
        guard let data = try? Data(contentsOf: localURL) else {
            log("Cannot read \(localURL.lastPathComponent)"); return false
        }
        isBusy = true
        defer { isBusy = false }

        let chunkSize = 256 * 1024 - 4097  // putpart chunk limit

        if data.count <= chunkSize {
            // Single put
            let id = UUID().uuidString
            let b64 = data.base64EncodedString()
            let ok = agentRequest("\(id) put \(guestPath) \(mode)\n\(b64)")
            guard ok else { log("put request failed"); return false }
            guard let result = await pollResult(id: id, timeout: 30.0) else {
                log("put timed out"); return false
            }
            let success = result.hasPrefix("ok") || result.hasPrefix("put")
            log(success ? "Put \(guestPath) ok (\(data.count) bytes)" : "Put failed: \(result)")
            return success
        } else {
            // Multi-part put
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                let chunk = data[offset..<end]
                let isFinal = end >= data.count
                let id = UUID().uuidString
                let b64 = chunk.base64EncodedString()
                let ok = agentRequest("\(id) putpart \(offset) \(isFinal ? 1 : 0) \(mode) \(guestPath)\n\(b64)")
                guard ok else { log("putpart failed at offset \(offset)"); return false }
                guard let result = await pollResult(id: id, timeout: 30.0) else {
                    log("putpart timed out at offset \(offset)"); return false
                }
                if !result.hasPrefix("ok") && !result.hasPrefix("put") {
                    log("putpart error: \(result)"); return false
                }
                offset = end
                log("Uploaded \(end)/\(data.count) bytes")
            }
            log("Put \(guestPath) ok (\(data.count) bytes, multi-part)")
            return true
        }
    }

    /// Spawn a command in the guest. Returns stdout (base64-decoded).
    func spawn(argv: [String]) async -> Data? {
        let id = UUID().uuidString
        // argv is NUL-terminated, absolute argv[0]
        let argStr = argv.joined(separator: "\0")
        let b64 = Data(argStr.utf8).base64EncodedString()
        let ok = agentRequest("\(id) spawn\n\(b64)")
        guard ok else { log("spawn request failed"); return nil }

        guard let result = await pollResult(id: id, timeout: 60.0) else {
            log("spawn timed out"); return nil
        }

        let parts = result.components(separatedBy: "\n")
        if parts.count > 1, let decoded = Data(base64Encoded: parts[1]) {
            return decoded
        }
        return nil
    }

    /// Launch a bundle id in the guest.
    func launchApp(bundleID: String) async -> Bool {
        let id = UUID().uuidString
        let ok = agentRequest("\(id) launch \(bundleID)\n")
        guard ok else { log("launch request failed"); return false }
        guard let result = await pollResult(id: id, timeout: 10.0) else {
            log("launch timed out"); return false
        }
        let success = result.hasPrefix("ok") || result.hasPrefix("launch")
        log(success ? "Launched \(bundleID)" : "Launch failed: \(result)")
        return success
    }

    /// Change file ownership in the guest.
    func chown(uid: Int, gid: Int, path: String) async -> Bool {
        let id = UUID().uuidString
        let ok = agentRequest("\(id) chown \(uid) \(gid) \(path)\n")
        guard ok else { return false }
        guard let result = await pollResult(id: id, timeout: 10.0) else { return false }
        return result.hasPrefix("ok") || result.hasPrefix("chown")
    }

    // MARK: - Typing (hardware keyboard bridge)

    /// Type Unicode text into whatever text field has focus in the guest. One `type` request per burst.
    @discardableResult
    func typeText(_ text: String) async -> Bool {
        guard !text.isEmpty else { return true }
        let id = UUID().uuidString
        let encoded = Data(text.utf8).base64EncodedString()
        guard agentRequest("\(id) type\n\(encoded)") else { return false }
        return await pollResult(id: id, timeout: 5.0) != nil
    }

    /// Delete one character in the guest's focused text field.
    @discardableResult
    func backspace() async -> Bool {
        let id = UUID().uuidString
        guard agentRequest("\(id) backspace\n") else { return false }
        return await pollResult(id: id, timeout: 5.0) != nil
    }

    // MARK: - Apps

    struct GuestApp: Identifiable, Hashable {
        let bundleID: String
        let name: String
        let path: String
        var id: String { bundleID.isEmpty ? path : bundleID }
    }

    /// Lists the user apps on the guest (/Applications under 501, roughly). Returns an empty list if the agent
    /// doesn't give us a shell: `/Applications` is on the system volume on 1.x–4.x, we read it via `spawn ls`.
    func listApps() async -> [GuestApp] {
        guard hasShell else { return [] }
        guard let listing = await spawn(argv: ["/bin/ls", "-1", "/Applications"]),
            let text = String(data: listing, encoding: .utf8)
        else { return [] }
        let names = text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasSuffix(".app") }
        var out: [GuestApp] = []
        for name in names {
            let path = "/Applications/\(name)"
            // Info.plist's CFBundleIdentifier (+ CFBundleDisplayName / CFBundleName) if the shell can read the plist.
            var bundleID = ""
            var display = (name as NSString).deletingPathExtension
            if let plist = await spawn(argv: ["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", "\(path)/Info.plist"]),
                let text = String(data: plist, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty, !text.lowercased().contains("error")
            {
                bundleID = text
            }
            if let plist = await spawn(argv: ["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleDisplayName", "\(path)/Info.plist"]),
                let text = String(data: plist, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty, !text.lowercased().contains("error")
            {
                display = text
            }
            out.append(GuestApp(bundleID: bundleID, name: display, path: path))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Removes an installed app folder from /Applications (jailbroken only).
    @discardableResult
    func removeApp(at path: String) async -> Bool {
        guard hasShell else { return false }
        guard let out = await spawn(argv: ["/bin/rm", "-rf", path]) else { return false }
        // `rm -rf` prints nothing on success.
        return out.isEmpty
    }

    // MARK: - Files

    struct GuestFile: Identifiable, Hashable {
        let name: String
        let isDirectory: Bool
        let size: Int64
        var id: String { name + (isDirectory ? "/" : "") }
    }

    /// Lists a directory on the guest with `spawn ls -lA`. Requires shell tools.
    func listDirectory(_ path: String) async -> [GuestFile] {
        guard hasShell else { return [] }
        guard let out = await spawn(argv: ["/bin/ls", "-lAp", path]),
            let text = String(data: out, encoding: .utf8)
        else { return [] }
        var files: [GuestFile] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // `total 123` or `ls: cannot access...`
            guard parts.count >= 9, let first = parts.first?.first, "-dlbcps".contains(first) else { continue }
            let size = Int64(parts[4]) ?? 0
            let name = parts.dropFirst(8).joined(separator: " ")
            if name.isEmpty { continue }
            let trimmed = name.hasSuffix("/") ? String(name.dropLast()) : name
            files.append(GuestFile(name: trimmed, isDirectory: first == "d" || name.hasSuffix("/"), size: size))
        }
        return files.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Delete a file in the guest.
    func unlink(path: String) async -> Bool {
        let id = UUID().uuidString
        let ok = agentRequest("\(id) unlink \(path)\n")
        guard ok else { return false }
        guard let result = await pollResult(id: id, timeout: 10.0) else { return false }
        return result.hasPrefix("ok") || result.hasPrefix("unlink")
    }

    /// Check whether /bin/mkdir exists (rough proxy for jailbroken with shell tools).
    func checkShellCapabilities() async {
        // Try to spawn /bin/ls /bin/mkdir — if it works, we have shell tools
        guard ops.contains("spawn") else {
            hasShell = false
            log("Agent has no spawn op — cannot check for shell tools")
            return
        }

        if let result = await spawn(argv: ["/bin/ls", "/bin/mkdir"]) {
            let output = String(data: result, encoding: .utf8) ?? ""
            hasShell = output.contains("mkdir")
            log(hasShell ? "Guest has /bin/mkdir (jailbroken)" : "No /bin/mkdir")
        } else {
            hasShell = false
            log("Could not check for shell tools")
        }
    }

    // MARK: - IPA Install (requires shell tools or future USB stack)

    /// Attempt to install an IPA into the guest. Currently requires a jailbroken guest with
    /// shell tools (mkdir, cp). The Mac app uses AFC + installation_proxy over a USB bridge;
    /// that path needs the cross-built USB stack (probe-usb in CI).
    func installIPA(localURL: URL) async -> Bool {
        isBusy = true
        defer { isBusy = false }

        guard status == .alive else {
            log("Agent not alive, cannot install"); return false
        }

        // Extract the IPA (it's a zip) to find the .app bundle
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            // Use unzip via Process is not available on iOS, so we use ZIPFoundation-style manual unzip
            // For now, we just upload the IPA and let the guest-side handle it if possible
            log("IPA install via agent: uploading \(localURL.lastPathComponent)…")

            let guestIPA = "/tmp/\(localURL.lastPathComponent)"
            let uploaded = await putFile(localURL: localURL, guestPath: guestIPA)
            guard uploaded else { log("Upload failed"); return false }

            if hasShell {
                // Use shell tools to unzip and install
                log("Extracting on guest…")
                _ = await spawn(argv: ["/bin/mkdir", "-p", "/tmp/ipa_install"])
                let unzipResult = await spawn(argv: ["/usr/bin/unzip", "-o", guestIPA, "-d", "/tmp/ipa_install"])
                if unzipResult == nil {
                    log("Guest unzip not available, trying alternative…")
                    // Older iOS may not have unzip; the IPA stays uploaded for manual install
                    log("IPA uploaded to \(guestIPA). Use Cydia or manual install.")
                    return true
                }

                // Find the .app folder
                if let lsResult = await spawn(argv: ["/bin/ls", "/tmp/ipa_install/Payload"]),
                   let output = String(data: lsResult, encoding: .utf8) {
                    let apps = output.components(separatedBy: "\n").filter { $0.hasSuffix(".app") }
                    if let appName = apps.first {
                        log("Found app: \(appName)")
                        // Copy to /Applications (requires root on jailbroken device)
                        _ = await spawn(argv: ["/bin/cp", "-R", "/tmp/ipa_install/Payload/\(appName)", "/Applications/\(appName)"])
                        _ = await chown(uid: 0, gid: 0, path: "/Applications/\(appName)")
                        log("Installed \(appName) to /Applications")
                        // Clean up
                        _ = await unlink(path: guestIPA)
                        _ = await spawn(argv: ["/bin/rm", "-rf", "/tmp/ipa_install"])
                        return true
                    }
                }
                log("Could not find .app in IPA")
                return false
            } else {
                log("No shell tools. IPA uploaded to guest at \(guestIPA). Jailbreak the device or wait for USB install support.")
                return true
            }
        } catch {
            log("IPA install error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Internals

    private func pollResult(id: String, timeout: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = agentResult() {
                // Format: "<id> <status>\n<base64 body>"
                let parts = raw.components(separatedBy: "\n")
                guard let header = parts.first else { continue }
                let headerParts = header.components(separatedBy: " ")
                guard headerParts.count >= 2, headerParts[0] == id else { continue }

                let statusStr = headerParts[1]
                if parts.count > 1, let decoded = Data(base64Encoded: parts[1]) {
                    return statusStr + "\n" + (String(data: decoded, encoding: .utf8) ?? "")
                }
                return statusStr
            }
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }
        return nil
    }

    private func log(_ message: String) {
        lastLog = message
        LTMLog.note("[agent] \(message)")
    }
}
