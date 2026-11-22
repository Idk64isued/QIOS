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
    /// An app install is running (GuestInstaller.swift).
    @Published var isInstalling: Bool = false
    /// The guest's iPhone OS version (the device's lock file), which decides where an app goes.
    var guestVersion: String?
    /// lt-mkdirs is in the guest for this session.
    var helperReady = false
    /// lt-unpack is in the guest (GuestInstaller.ensureUnpacker).
    var unpackReady = false
    /// lt-install is in the guest (GuestInstaller.ensureInstaller).
    var installReady = false
    /// This device's installd has already turned an app down this boot, so the next install skips it and copies the
    /// app in by hand straight away (GuestInstaller). Cleared when a fresh agent says hello.
    var installdRefuses = false
    /// The end of the queue of installs and imports: each waits for the one before it (one at a time, so two never
    /// write into the guest at once).
    var jobTail: Task<Void, Never>?

    /// Runs `work` after every install or import queued before it has finished.
    func oneAtATime<T>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = jobTail
        let job = Task { @MainActor () async throws -> T in
            _ = await previous?.value
            return try await work()
        }
        jobTail = Task { _ = try? await job.value }
        return try await job.value
    }

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
        guard let reply = await pollRaw(id: id, timeout: 5.0) else { log("ping timed out"); return }

        // The body (after the status line) is "it_agent v5\nops ping spawn sync put putpart get ...\n". This used to
        // read the status line as the version, so no op was ever found and every device looked like it had no spawn.
        let lines = (String(data: reply.body, encoding: .utf8) ?? "").components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("it_agent") {
            version = first
            log("Agent: \(first)")
            // A fresh agent means a fresh boot, and /tmp went with it: whatever was copied there is gone.
            toolsInPlace.removeAll()
            installdRefuses = false
        }
        if let opsLine = lines.first(where: { $0.hasPrefix("ops ") }) {
            ops = opsLine.dropFirst(4).components(separatedBy: " ").filter { !$0.isEmpty }
            log("Ops: \(ops.joined(separator: ", "))")
        } else if version.hasPrefix("it_agent v1") {
            log("This guest has the first agent, which can only paste. Rebuild the device for app installs.")
        }
    }

    /// Guest tools already copied into the running device, by name. Cleared when a fresh agent says hello.
    private var toolsInPlace: Set<String> = []

    /// Copies a guest tool to a fixed path, once per boot, and gives back that path.
    ///
    /// Importing a batch used to copy itmedia (or itphoto) in again for every single song or photo and delete it
    /// afterwards — an upload and two round trips per item, on top of the item itself. That is most of why a long
    /// import sat on one item looking stuck.
    func ensureGuestTool(_ name: String) async throws -> String {
        let path = "/tmp/ltm-" + name
        if toolsInPlace.contains(name) { return path }
        guard let tool = MacFiles.guestTool(name) else {
            throw InstallFailure(message: "The guest tools have no \(name). Get the Mac files again (Add device \u{203A} Mac files).")
        }
        guard await putFile(localURL: tool, guestPath: path, mode: "0755") else {
            throw InstallFailure(message: "Couldn\u{2019}t put \(name) into the device. \(lastLog)")
        }
        toolsInPlace.insert(name)
        return path
    }

    /// Forgets a copied tool, so the next import puts it back. For when running it fails: the likeliest reason is
    /// that it is no longer there.
    func forgetGuestTool(_ name: String) { toolsInPlace.remove(name) }

    /// The largest body one request can carry: the emulator's IT_AGENT_REQUEST_MAX (256 KiB) less room for the
    /// request line, and base64 expands by four bytes for every three.
    private static let chunkSize = 256 * 1024 - 4097

    /// How many putpart requests are kept in the emulator's queue at once.
    ///
    /// This is where "copying anything takes ages" came from. The guest's daemon polls for work, and when it finds
    /// none it sleeps a quarter of a second before asking again. Sending one chunk, waiting for its reply, and only
    /// then sending the next meant the queue was empty every single time the daemon looked: each 252 KiB chunk cost
    /// its own transfer plus most of that sleep, which pinned every copy — a song, a photo, a 36 MB app bundle — at
    /// about a megabyte a second no matter how fast the link underneath was.
    ///
    /// Keeping a few chunks queued ahead means the daemon always has the next one waiting the moment it finishes the
    /// last, and never sleeps mid-file. The emulator's queue holds 16 items in all (IT_AGENT_QUEUE_MAX, shared with
    /// finished results and with whatever else is talking to the agent), so four leaves plenty of room. The agent
    /// takes one item at a time from the head of that queue, so the chunks still land in the order they were sent.
    private static let putDepth = 4

    /// Put a file into the guest filesystem.
    /// For files over one chunk, uses putpart, a few chunks in flight at a time.
    func putFile(localURL: URL, guestPath: String, mode: String = "0644",
                 progress: ((Int, Int) -> Void)? = nil) async -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: localURL),
            let total = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.intValue
        else {
            log("Cannot read \(localURL.lastPathComponent)"); return false
        }
        defer { try? handle.close() }
        isBusy = true
        defer { isBusy = false }

        let chunkSize = Self.chunkSize

        if total <= chunkSize {
            let data = (try? handle.readToEnd()) ?? Data()
            let id = UUID().uuidString
            let b64 = data.base64EncodedString()
            let ok = agentRequest("\(id) put \(guestPath) \(mode)\n\(b64)")
            guard ok else { log("put request failed"); return false }
            guard let result = await pollResult(id: id, timeout: 30.0) else {
                log("put timed out"); return false
            }
            let success = Self.succeeded(result)
            log(success ? "Put \(guestPath) ok (\(data.count) bytes)" : "Put failed: \(Self.failureText(result))")
            return success
        }

        // Multi-part put, pipelined. `sending` holds the chunks the emulator has taken but not yet answered, oldest
        // first; the loop tops it up to putDepth, then waits for the oldest to come back.
        var sending: [(id: String, end: Int)] = []
        var offset = 0           // the next byte to read
        var done = 0             // bytes the guest has confirmed written
        var announced = 0        // bytes at the last log line
        let step = 4 << 20       // how often the log says where the copy is

        func submit() -> Bool? {
            guard offset < total else { return nil }   // nothing left to send
            let end = min(offset + chunkSize, total)
            guard let chunk = try? handle.read(upToCount: end - offset), chunk.count == end - offset else {
                log("Could not read \(localURL.lastPathComponent) at \(offset)")
                return false
            }
            let id = UUID().uuidString
            let line = "\(id) putpart \(offset) \(end >= total ? 1 : 0) \(mode) \(guestPath)\n"
            guard agentRequest(line + chunk.base64EncodedString()) else { return false }
            sending.append((id, end))
            offset = end
            return true
        }

        while done < total {
            // Fill the queue. A refused request means the emulator's queue is full, not an error: wait for the
            // oldest reply to make room and try again next time round.
            while sending.count < Self.putDepth {
                guard let accepted = submit() else { break }
                if !accepted {
                    guard !sending.isEmpty else {
                        log("putpart failed at offset \(offset): the device wouldn\u{2019}t take it")
                        return false
                    }
                    break
                }
            }
            guard !sending.isEmpty else { break }
            let oldest = sending.removeFirst()
            guard let result = await pollResult(id: oldest.id, timeout: 60.0) else {
                log("putpart timed out at offset \(oldest.end)"); return false
            }
            guard Self.succeeded(result) else {
                log("putpart failed at \(oldest.end): \(Self.failureText(result))"); return false
            }
            done = oldest.end
            progress?(done, total)
            // One line every few megabytes. A line per chunk filled the log with hundreds of near-identical
            // "Uploaded" lines for one app, and each of them was a main-actor write while the copy was running.
            if done - announced >= step || done >= total {
                announced = done
                log("Uploaded \(done)/\(total) bytes")
            }
        }
        guard done == total else {
            log("putpart stopped at \(done)/\(total) bytes"); return false
        }
        log("Put \(guestPath) ok (\(total) bytes, multi-part)")
        return true
    }

    /// Put bytes into the guest filesystem (through a temporary file, so large ones go in parts too).
    func putData(_ data: Data, guestPath: String, mode: String = "0644") async -> Bool {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-put-\(UUID().uuidString)")
        guard (try? data.write(to: temp)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: temp) }
        return await putFile(localURL: temp, guestPath: guestPath, mode: mode)
    }

    /// Any agent op by its request line ("cadebug 4 4"), with an optional body: its status (negative = -errno) and
    /// reply body, or nil when the agent didn't answer.
    func request(_ line: String, body: Data = Data(), timeout: TimeInterval = 10) async -> (status: Int, body: Data)? {
        let id = UUID().uuidString
        guard agentRequest("\(id) \(line)\n\(body.isEmpty ? "" : body.base64EncodedString())"),
            let reply = await pollRaw(id: id, timeout: timeout)
        else { return nil }
        return (reply.status ?? -1, reply.body)
    }

    /// Spawn a command in the guest. Returns its stdout+stderr, or nil when it could not be started.
    func spawn(argv: [String]) async -> Data? {
        guard let r = await run(argv) else { return nil }
        return r.status < 0 ? nil : r.output
    }

    /// Spawn a command in the guest: its exit status (negative = it never ran: -errno) and its stdout+stderr.
    /// The agent's spawn has no shell; argv[0] has to be an absolute path.
    func run(_ argv: [String], timeout: TimeInterval = 60) async -> (status: Int, output: Data)? {
        let id = UUID().uuidString
        let argStr = argv.joined(separator: "\0") + "\0"
        let b64 = Data(argStr.utf8).base64EncodedString()
        guard agentRequest("\(id) spawn\n\(b64)") else { log("spawn request failed"); return nil }
        guard let reply = await pollRaw(id: id, timeout: timeout) else {
            log("spawn \(argv.first ?? "") timed out"); return nil
        }
        return (reply.status ?? -1, reply.body)
    }

    /// A file from the guest (any size: `get` up to 1 MiB, then `getrange` in pieces). nil if it isn't there.
    func getFile(_ path: String) async -> Data? {
        let id = UUID().uuidString
        guard agentRequest("\(id) get \(path)\n") else { return nil }
        guard let reply = await pollRaw(id: id, timeout: 30) else { return nil }
        if reply.status == 0 { return reply.body }
        guard reply.status == -27 /* EFBIG */ else { return nil }
        var out = Data()
        let piece = 512 * 1024
        while true {
            let rid = UUID().uuidString
            guard agentRequest("\(rid) getrange \(out.count) \(piece) \(path)\n"),
                let part = await pollRaw(id: rid, timeout: 30), part.status == 0
            else { return nil }
            out.append(part.body)
            if part.body.count < piece { return out }
        }
    }

    /// The frontmost app's interface orientation in degrees (0, 90, 180, -90), or nil where the agent can't tell
    /// (it knows SpringBoard's ABI on 3.1.3 only).
    func orientation() async -> Int? {
        guard ops.contains("orientation") else { return nil }
        let id = UUID().uuidString
        guard agentRequest("\(id) orientation\n"), let reply = await pollRaw(id: id, timeout: 2), reply.status == 0
        else { return nil }
        return Int((String(data: reply.body, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// sync(2) in the guest: what it has written reaches its storage, so a kill now leaves a consistent disk.
    @discardableResult
    func sync() async -> Bool {
        guard ops.contains("sync") else { return false }
        let id = UUID().uuidString
        guard agentRequest("\(id) sync\n"), let reply = await pollRaw(id: id, timeout: 10) else { return false }
        return reply.status == 0
    }

    /// Launch a bundle id in the guest.
    func launchApp(bundleID: String) async -> Bool {
        let id = UUID().uuidString
        let ok = agentRequest("\(id) launch \(bundleID)\n")
        guard ok else { log("launch request failed"); return false }
        guard let result = await pollResult(id: id, timeout: 10.0) else {
            log("launch timed out"); return false
        }
        let success = Self.succeeded(result)
        log(success ? "Launched \(bundleID)" : "Launch failed: \(result)")
        return success
    }

    /// Change file ownership in the guest.
    func chown(uid: Int, gid: Int, path: String) async -> Bool {
        let id = UUID().uuidString
        let ok = agentRequest("\(id) chown \(uid) \(gid) \(path)\n")
        guard ok else { return false }
        guard let result = await pollResult(id: id, timeout: 10.0) else { return false }
        return Self.succeeded(result)
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
        return Self.succeeded(result)
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

    // MARK: - IPA install: GuestInstaller.swift (no jailbreak needed)

    // MARK: - Internals

    /// The agent's status line, as its README defines it: 0 is success, a negative number is -errno, anything
    /// else is a child's exit status. Everything here used to look for the words "ok" or "put", which the agent
    /// never sends — so a perfectly good upload came back as "putpart error: 0" and the install gave up.
    static func succeeded(_ result: String) -> Bool {
        let status = (result.components(separatedBy: "\n").first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = Int(status) { return code == 0 }
        return status.hasPrefix("ok")
    }

    /// What went wrong, for the log: the errno where there is one.
    static func failureText(_ result: String) -> String {
        let status = (result.components(separatedBy: "\n").first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = Int(status), code < 0 { return "error \(-code) (\(String(cString: strerror(Int32(-code)))))" }
        return status.isEmpty ? "no answer" : status
    }

    /// Results that arrived for other requests while one was being waited for. `agent-result` hands out whichever
    /// result is ready, so without this a second caller (orientation polling during an install) lost the first one's.
    private var mailbox: [String: (status: Int?, statusText: String, body: Data)] = [:]

    /// Waits for the result of request `id`: its status (the agent's number when it is one) and its decoded body.
    private func pollRaw(id: String, timeout: TimeInterval) async -> (status: Int?, statusText: String, body: Data)? {
        let deadline = Date().addingTimeInterval(timeout)
        var spins = 0
        while Date() < deadline {
            if let mine = mailbox.removeValue(forKey: id) { return mine }
            while let raw = agentResult() {
                // "<id> <status>\n<base64 body>"
                let newline = raw.firstIndex(of: "\n") ?? raw.endIndex
                let header = raw[..<newline].split(separator: " ", maxSplits: 1).map(String.init)
                guard header.count >= 1 else { continue }
                let statusText = header.count > 1 ? header[1].trimmingCharacters(in: .whitespaces) : ""
                let bodyText = newline < raw.endIndex ? String(raw[raw.index(after: newline)...]) : ""
                let body = Data(base64Encoded: bodyText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Data()
                let entry = (status: Int(statusText), statusText: statusText, body: body)
                if header[0] == id { return entry }
                if mailbox.count < 64 { mailbox[header[0]] = entry }
            }
            // A reply that is already on its way arrives within a few milliseconds, and a copy is hundreds of round
            // trips, so look often at first and back off once it is clear this one is going to take a while.
            spins += 1
            try? await Task.sleep(nanoseconds: spins < 40 ? 5_000_000 : 20_000_000)
        }
        agentCancel(id)
        return nil
    }

    /// The status line and the body as text, for the callers that only check `succeeded`.
    private func pollResult(id: String, timeout: TimeInterval) async -> String? {
        guard let r = await pollRaw(id: id, timeout: timeout) else { return nil }
        let text = String(data: r.body, encoding: .utf8) ?? ""
        return text.isEmpty ? r.statusText : r.statusText + "\n" + text
    }

    func log(_ message: String) {
        lastLog = message
        LTMLog.note("[agent] \(message)")
    }
}
