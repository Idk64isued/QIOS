import SwiftUI

// Device ▸ Tweaks: Apple's own hidden switches, the Mac app's Tweaks panel. Each is a preference key in the mobile
// user's domain, written through the agent (read the plist, change the key, put it back as mobile's) and applied by
// restarting the Home screen, or Core Animation's debug colors, which the agent's cadebug op sets live. Each switch
// is offered only on the firmware whose reader has it (the Mac app's research, Tweaks.swift there).

struct GuestTweak: Identifiable, Hashable {
    let id: String
    let title: String
    let caption: String
    /// Preference keys this switch sets ("domain", "key", value).
    let keys: [(String, String, Any)]
    let first: String, last: String

    static func == (a: GuestTweak, b: GuestTweak) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    func available(on version: String) -> Bool {
        version.compare(first, options: .numeric) != .orderedAscending
            && version.compare(last, options: .numeric) != .orderedDescending
    }

    static func all(version: String) -> [GuestTweak] {
        let modernSafari = version.compare("6.0", options: .numeric) != .orderedAscending
        return [
            GuestTweak(id: "signal", title: "Signal as Numbers", caption: "Wi-Fi and cellular bars as dBm (SBShowRSSI)",
                       keys: [("com.apple.springboard", "SBShowRSSI", true), ("com.apple.springboard", "SBShowGSMRSSI", true)],
                       first: "1.0", last: "7.1.2"),
            GuestTweak(id: "clock", title: "Keynote Clock", caption: "The status bar always says 9:42 (SBFakeTime)",
                       keys: [("com.apple.springboard", "SBFakeTime", true)], first: "1.0", last: "4.0.2"),
            GuestTweak(id: "slow", title: "Slow Animations", caption: "Every UIKit animation ten times slower",
                       keys: [("com.apple.UIKit", "UIAnimationDragCoefficient", 10)], first: "3.0", last: "7.1.2"),
            GuestTweak(id: "emoji", title: "Emoji Keyboard Everywhere", caption: "The Emoji keyboard outside Japan (KeyboardEmojiEverywhere)",
                       keys: [("com.apple.Preferences", "KeyboardEmojiEverywhere", true)], first: "2.2", last: "4.3.5"),
            GuestTweak(id: "safari", title: "Safari Debugging",
                       caption: modernSafari ? "Web Inspector (RemoteInspectorEnabled)" : "Safari\u{2019}s Debug Console (ConsoleEnabled)",
                       keys: [modernSafari ? ("com.apple.webinspectord", "RemoteInspectorEnabled", true)
                                           : ("com.apple.mobilesafari", "ConsoleEnabled", true)],
                       first: "1.1", last: "7.1.2"),
        ].filter { $0.available(on: version) }
    }
}

/// Core Animation's debug colors (the CA_COLOR_* bits of CARenderServerSetDebugFlags).
enum CAColor: UInt32, CaseIterable, Identifiable {
    case off = 0, blended = 0x4, copied = 0x2, misaligned = 0x4000, offscreen = 0x20000, flash = 0x1
    var id: UInt32 { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .blended: return "Blended Layers"
        case .copied: return "Copied Images"
        case .misaligned: return "Misaligned Images"
        case .offscreen: return "Offscreen-Rendered"
        case .flash: return "Flash Updated Regions"
        }
    }
    static let mask: UInt32 = 0x4 | 0x2 | 0x4000 | 0x20000 | 0x1
}

extension GuestAgent {
    static let preferences = "/var/mobile/Library/Preferences"

    /// A preference domain of the mobile user, as a dictionary (empty when it has none yet).
    func readDefaults(_ domain: String) async -> [String: Any]? {
        guard let data = await getFile("\(Self.preferences)/\(domain).plist") else { return [:] }
        if data.isEmpty { return [:] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Sets (or with nil removes) keys in a domain, written back as mobile's binary plist. False if it failed.
    func writeDefaults(_ domain: String, _ changes: [String: Any?]) async -> Bool {
        guard var plist = await readDefaults(domain) else { return false }
        for (key, value) in changes {
            if let value { plist[key] = value } else { plist.removeValue(forKey: key) }
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else { return false }
        let path = "\(Self.preferences)/\(domain).plist"
        guard await putData(data, guestPath: path, mode: "0600") else { return false }
        return await chown(uid: 501, gid: 501, path: path)
    }

    /// Restart the Home screen (backboardd from iOS 6, which owns the display there), as a respring does.
    func respring() async {
        let six = (guestVersion ?? "3").compare("6.0", options: .numeric) != .orderedAscending
        _ = await run(["/bin/launchctl", "stop", six ? "com.apple.backboardd" : "com.apple.SpringBoard"])
    }

    /// Core Animation's debug flags: set `value` under `mask` and return the flags now (mask 0 only reads them).
    func caDebug(mask: UInt32, value: UInt32) async -> UInt32? {
        guard ops.contains("cadebug"), let reply = await request("cadebug \(mask) \(value)"), reply.status == 0 else { return nil }
        let text = String(decoding: reply.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return UInt32(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text, radix: text.hasPrefix("0x") ? 16 : 10)
    }
}

struct TweaksView: View {
    let agent: GuestAgent
    let onDismiss: () -> Void

    @State private var version = "3.1.3"
    @State private var on: Set<String> = []
    @State private var initial: Set<String> = []
    @State private var caColor: CAColor = .off
    @State private var caAvailable = false
    @State private var loading = true
    @State private var status = ""
    @State private var proxyFixed = false

    private var tweaks: [GuestTweak] { GuestTweak.all(version: version) }

    var body: some View {
        NavigationView {
            Form {
                if loading {
                    HStack { ProgressView(); Text("Reading the device\u{2019}s settings\u{2026}") }
                } else {
                    Section(footer: Text("These are Apple\u{2019}s own hidden settings. Applying restarts the device\u{2019}s Home screen.")) {
                        if tweaks.isEmpty { Text("None of these switches exist on \(version).").foregroundStyle(.secondary) }
                        ForEach(tweaks) { tweak in
                            Toggle(isOn: Binding(
                                get: { on.contains(tweak.id) },
                                set: { if $0 { on.insert(tweak.id) } else { on.remove(tweak.id) } }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tweak.title)
                                    Text(tweak.caption).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("Apply") { apply() }.disabled(on == initial)
                    }
                    if caAvailable {
                        Section(header: Text("Core Animation Colors"),
                                footer: Text("Tints what the device\u{2019}s compositor does the slow way, live. Off when the device restarts.")) {
                            Picker("Show", selection: $caColor) {
                                ForEach(CAColor.allCases) { Text($0.title).tag($0) }
                            }
                            .onChange(of: caColor) { color in
                                Task { _ = await agent.caDebug(mask: CAColor.mask, value: color.rawValue) }
                            }
                        }
                    }
                    if proxyFixed {
                        Section(footer: Text("This device was prepared to send its web traffic through a proxy that only the Mac app runs, so every connection waited for it before giving up and going direct. Light Touch now sends it straight out. Put the proxy back only if you are running one yourself at 10.0.2.100:3128.")) {
                            Button("Put Back the Web Proxy") {
                                Task {
                                    status = "Putting the proxy back\u{2026}"
                                    let ok = await agent.restoreWebProxy()
                                    status = ok ? "The prepared proxy is back. It takes effect on the next connection."
                                                : "Couldn\u{2019}t put the proxy back. \(agent.lastLog)"
                                    if ok { proxyFixed = false }
                                }
                            }
                        }
                    }
                    if !status.isEmpty { Section { Text(status).font(.footnote) } }
                }
            }
            .navigationTitle("Tweaks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { onDismiss() } } }
            .task { await load() }
        }
        .navigationViewStyle(.stack)
    }

    private func load() async {
        version = agent.guestVersion ?? "3.1.3"
        var found: Set<String> = []
        var cache: [String: [String: Any]] = [:]
        for tweak in tweaks {
            var all = true
            for (domain, key, _) in tweak.keys {
                if cache[domain] == nil { cache[domain] = await agent.readDefaults(domain) ?? [:] }
                if cache[domain]?[key] == nil { all = false }
            }
            if all { found.insert(tweak.id) }
        }
        on = found
        initial = found
        if version.compare("3.1", options: .numeric) != .orderedAscending, let flags = await agent.caDebug(mask: 0, value: 0) {
            caAvailable = true
            caColor = CAColor.allCases.first { $0 != .off && flags & $0.rawValue != 0 } ?? .off
        }
        proxyFixed = await agent.hasRewrittenProxy()
        loading = false
    }

    private func apply() {
        let changes = tweaks.filter { on.contains($0.id) != initial.contains($0.id) }
        Task {
            status = "Applying\u{2026}"
            var byDomain: [String: [String: Any?]] = [:]
            for tweak in changes {
                let enable = on.contains(tweak.id)
                for (domain, key, value) in tweak.keys {
                    byDomain[domain, default: [:]].updateValue(enable ? Optional(value) : nil, forKey: key)
                }
            }
            var failed: [String] = []
            for (domain, keys) in byDomain {
                let ok = await agent.writeDefaults(domain, keys)
                if !ok { failed.append(domain) }
            }
            if !failed.isEmpty {
                status = "Couldn\u{2019}t change \(failed.joined(separator: ", ")). \(agent.lastLog)"
                return
            }
            await agent.respring()
            initial = on
            status = "Applied. The Home screen is restarting."
        }
    }
}
