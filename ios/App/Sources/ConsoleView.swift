import SwiftUI

/// The Console button's sheet: the device's own serial console (iBoot, the kernel with Settings › Kernel console on,
/// the guest helpers) and Halcyon's log, live, as the Mac app's Device Console and Kernel Console show them.
/// Both are tails of files that keep growing (LTMLog.serialURL and LTMLog.url), reread once a second while open.
struct ConsoleView: View {
    enum Source: String, CaseIterable {
        case device = "Device"
        case app = "Halcyon"
    }

    let onDone: () -> Void
    @State private var source: Source = .device
    @State private var text = ""
    @State private var follow = true
    @State private var shareItem: ShareItem?
    @AppStorage("kernelConsole") private var kernelConsole = false
    @AppStorage("verboseBoot") private var verboseBoot = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The newest part of a log: enough to read a boot without loading a long session into a Text.
    private static let tailBytes = 96 * 1024

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $source) {
                    ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                if source == .device && !kernelConsole {
                    Text("Only iBoot and the guest helpers write here until Settings › Kernel console is on (it takes effect at the next boot).")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(text.isEmpty ? "Nothing yet." : text)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(text.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .background(Color.black.opacity(0.92))
                    .onChange(of: text) { _ in
                        if follow { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
                HStack {
                    Toggle("Follow", isOn: $follow).toggleStyle(.switch).fixedSize()
                    Spacer()
                    Toggle("Kernel console", isOn: $kernelConsole).toggleStyle(.switch).fixedSize()
                }
                .font(.system(size: 12, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .navigationTitle("Console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: onDone) }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let url = Self.exportCopy(of: source) { shareItem = ShareItem(url: url) }
                    } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear(perform: reload)
        .onChange(of: source) { _ in reload() }
        .onReceive(timer) { _ in reload() }
        .sheet(item: $shareItem) { item in ActivityView(items: [item.url]) }
    }

    private func url(for source: Source) -> URL { source == .device ? LTMLog.serialURL : LTMLog.url }

    private func reload() {
        let next = Self.tail(url(for: source))
        if next != text { text = next }
    }

    /// The last `tailBytes` of a file, as text (the serial port carries bytes, not always UTF-8).
    static func tail(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text.replacingOccurrences(of: "\r", with: "")
    }

    /// A copy of a whole log to share, named for what it is.
    static func exportCopy(of source: Source) -> URL? {
        if source == .app { return LTMLog.exportCopy() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: LTMLog.serialURL.path) else { return nil }
        let copy = fm.temporaryDirectory.appendingPathComponent("serial-\(Reports.stamp()).txt")
        try? fm.removeItem(at: copy)
        return (try? fm.copyItem(at: LTMLog.serialURL, to: copy)) != nil ? copy : nil
    }
}
