import Foundation

// The emulated iPhone's cellular baseband (qemu-ios hw/misc/ios_baseband.c).
//
// The board gives the iPhones a fake modem on the serial line the kernel's AppleReliableSerialLayer wraps, and the
// emulator exposes it to the host by property name. That is how the Mac app drives it, and the same two functions
// are in this build's library, so the carrier name, the signal, an incoming call and an incoming text are all a
// property away. An iPod touch has no modem: every call here answers false, which is what hides this from its UI.
//
// Properties this uses:
//   carrier         the operator name in the status bar      "Halcyon"
//   signal-dbm      signal strength, -51 (full) … -113       "-75"
//   registered      on the network at all                    "true" / "false"
//   sim-present     a SIM in the tray                        "true" / "false"
//   incoming-call   make the device ring                     "+15551234567"
//   remote-answer   the far end picks up                     "1"
//   remote-hangup   the far end hangs up                     "1"
//   incoming-sms    deliver a text                           "+15551234567|hello"
// and reads back carrier, call-state, registered, sim-present, attached, signal-dbm and the rest as JSON.

struct ModemStatus: Equatable {
    var carrier = ""
    var callState = ""
    var mccMnc = ""
    var lastDialed = ""
    var registered = false
    var simPresent = false
    var attached = false
    var signalDBM = 0

    /// What the guest's status bar is doing, in a few words.
    var summary: String {
        var parts: [String] = []
        parts.append(registered ? (carrier.isEmpty ? "registered" : carrier) : "no service")
        if !simPresent { parts.append("no SIM") }
        if signalDBM != 0 { parts.append("\(bars)/5 bars") }
        if !callState.isEmpty, callState != "idle" { parts.append("call: " + callState) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// -51 dBm is full, -113 is nothing; the status bar shows five bars between.
    var bars: Int {
        guard signalDBM != 0 else { return 0 }
        let clamped = min(max(signalDBM, -113), -51)
        return min(5, max(0, Int(((Double(clamped) + 113) / 62 * 5).rounded())))
    }

    /// True while the device is ringing or in a call.
    var inCall: Bool { !callState.isEmpty && callState != "idle" && callState != "none" }
}

@MainActor
final class ModemController: ObservableObject {
    @Published private(set) var status: ModemStatus?
    @Published var note = ""

    /// Set once the emulator has loaded its library; nil before that, and on a device with no modem at all.
    var qemu: QemuRuntime?
    private var timer: Timer?

    init(qemu: QemuRuntime? = nil) { self.qemu = qemu }

    /// False on an iPod touch (no modem) and on an emulator build without the baseband bridge.
    var isAvailable: Bool { qemu?.modemSet != nil && qemu?.modemStatus != nil }

    // MARK: - Reading

    func refresh() {
        guard let qemu, let statusFn = qemu.modemStatus else { return }
        guard let raw = statusFn() else {
            status = nil
            return
        }
        defer { qemu.modemFree?(raw) }
        let json = String(cString: raw)
        guard let data = json.data(using: .utf8),
            let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        var next = ModemStatus()
        next.carrier = fields["carrier"] as? String ?? ""
        next.callState = fields["call-state"] as? String ?? ""
        next.mccMnc = fields["mcc-mnc"] as? String ?? ""
        next.lastDialed = fields["last-dialed"] as? String ?? ""
        next.registered = fields["registered"] as? Bool ?? false
        next.simPresent = fields["sim-present"] as? Bool ?? false
        next.attached = fields["attached"] as? Bool ?? false
        next.signalDBM = (fields["signal-dbm"] as? NSNumber)?.intValue ?? 0
        status = next
    }

    /// Keeps `status` fresh while a modem screen is open. The first read comes back empty because the emulator
    /// fills its snapshot in the background, so poll rather than read once.
    func startPolling() {
        refresh()
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Writing

    @discardableResult
    func set(_ property: String, _ value: String) -> Bool {
        guard let setFn = qemu?.modemSet else { return false }
        let ok = property.withCString { p in value.withCString { v in setFn(p, v) } }
        if !ok { LTMLog.note("modem: \(property) refused") }
        return ok
    }

    // MARK: - The things a person actually wants

    func setCarrier(_ name: String) -> Bool {
        let trimmed = String(name.prefix(32)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return set("carrier", trimmed)
    }

    func setSignal(bars: Int) -> Bool {
        // Five bars across the usable range; 0 bars is "searching" rather than a number the modem would report.
        let dbm = bars <= 0 ? -113 : Int((-113.0 + (Double(min(bars, 5)) / 5.0) * 62.0).rounded())
        return set("signal-dbm", "\(dbm)")
    }

    func setRegistered(_ on: Bool) -> Bool { set("registered", on ? "true" : "false") }
    func setSIMPresent(_ on: Bool) -> Bool { set("sim-present", on ? "true" : "false") }

    /// Rings the device. The modem refuses unless it is registered with the radio on and the channel open, which is
    /// the guest's own state, so this reports back rather than pretending.
    func call(from number: String) -> String {
        let cleaned = Self.cleanNumber(number)
        guard !cleaned.isEmpty else { return "Type a number first." }
        guard set("incoming-call", cleaned) else {
            return "The device isn\u{2019}t ready to ring yet \u{2014} it has to be registered on the network first."
        }
        refresh()
        return "Ringing \(cleaned)\u{2026}"
    }

    func answerRemotely() -> String {
        set("remote-answer", "1") ? "The other end picked up." : "There is no call to answer."
    }

    func hangUpRemotely() -> String {
        set("remote-hangup", "1") ? "The other end hung up." : "There is no call to hang up."
    }

    /// Delivers a text. The sender must be 1–20 digits, optionally after a '+'.
    func text(from number: String, body: String) -> String {
        let cleaned = Self.cleanNumber(number)
        guard !cleaned.isEmpty else { return "Type a number to send from." }
        let message = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return "Type a message first." }
        guard set("incoming-sms", "\(cleaned)|\(message)") else {
            return "The device isn\u{2019}t ready for messages yet \u{2014} it has to be registered on the network first."
        }
        return "Sent."
    }

    // MARK: - On a timer

    /// A call or a text, waiting for its moment.
    ///
    /// The modem has always been able to ring on demand. What it could not do is ring in a minute, which is the
    /// difference between a button and an alibi: set it going, put the phone down, and the 2007 one rings itself.
    struct Alarm: Equatable {
        enum Kind: Equatable {
            case call
            case text(String)
        }
        var kind: Kind
        var number: String
        /// Whole seconds from when it was set.
        var delay: Int

        var isCall: Bool { kind == .call }
    }

    /// The countdown, so the UI can show it and nothing else has to keep time.
    @Published private(set) var alarm: Alarm?
    @Published private(set) var secondsLeft = 0

    private var alarmTask: Task<Void, Never>?

    /// Sets a call or a text to arrive later. Replaces one already waiting, since two at once is not a feature.
    func schedule(_ wanted: Alarm) -> String {
        let cleaned = Self.cleanNumber(wanted.number)
        guard !cleaned.isEmpty else { return "Type a number first." }
        if case .text(let body) = wanted.kind,
            body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "Type a message first."
        }
        guard wanted.delay > 0 else {
            // No delay asked for: this is the plain button, so behave like it.
            switch wanted.kind {
            case .call: return call(from: cleaned)
            case .text(let body): return text(from: cleaned, body: body)
            }
        }
        cancelAlarm()
        var set = wanted
        set.number = cleaned
        alarm = set
        secondsLeft = set.delay
        alarmTask = Task { [weak self] in
            // Counted down a second at a time rather than slept through in one go, so the UI can show it and a
            // cancel takes effect at once. Task.sleep throws on cancellation, which ends this quietly.
            while true {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard let self, self.secondsLeft > 0 else { return }
                self.secondsLeft -= 1
                if self.secondsLeft == 0 { break }
            }
            guard let self, let due = self.alarm else { return }
            self.alarm = nil
            switch due.kind {
            case .call: self.note = self.call(from: due.number)
            case .text(let body): self.note = self.text(from: due.number, body: body)
            }
        }
        return (set.isCall ? "Ringing" : "Texting") + " in \(Self.spell(set.delay))."
    }

    /// Calls the whole thing off.
    @discardableResult
    func cancelAlarm() -> String {
        alarmTask?.cancel()
        alarmTask = nil
        guard alarm != nil else { return "" }
        alarm = nil
        secondsLeft = 0
        return "Called off."
    }

    /// "30 seconds", "1 minute", "2 minutes 30 seconds" \u{2014} whichever reads best for the number given.
    static func spell(_ seconds: Int) -> String {
        guard seconds >= 60 else { return "\(seconds) seconds" }
        let minutes = seconds / 60, rest = seconds % 60
        let m = "\(minutes) minute" + (minutes == 1 ? "" : "s")
        return rest == 0 ? m : m + " \(rest) seconds"
    }

    /// Digits, keeping a leading +, which is all the modem accepts.
    static func cleanNumber(_ raw: String) -> String {
        let plus = raw.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return "" }
        return (plus ? "+" : "") + String(digits.prefix(20))
    }
}
