import Cocoa
import LightTouchCore
import SwiftUI

/// About Light Touch: the standard panel with AboutCredits' runs as its credits. Show Licenses opens the Licenses
/// window, which reads the license files from the bundle (nothing is opened by file URL, so it works from any
/// location, App Translocation's included).
extension AboutCredits {
    @MainActor static func show() {
        let bundle = Bundle.main
        let text = credits(
            buildInputs: bundle.url(forResource: "build-inputs", withExtension: "json").flatMap {
                try? Data(contentsOf: $0)
            },
            licenses: licensesDirectory != nil
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: text])
        // The panel's credits view opens links itself; Show Licenses is the app's.
        let credits = NSApp.windows.lazy.compactMap { $0.contentView.flatMap(Self.textView(in:)) }.first
        credits?.delegate = LicensesLink.shared
    }

    /// licenses/ in the app's resources.
    @MainActor static var licensesDirectory: URL? { Bundle.main.url(forResource: "licenses", withExtension: nil) }

    static func credits(buildInputs: Data?, licenses: Bool) -> NSAttributedString {
        let size = NSFont.smallSystemFontSize
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 170)]
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let out = NSMutableAttributedString()
        for run in runs(buildInputs: buildInputs, licenses: licenses) {
            var attributes = body
            if run.isHeading { attributes[.font] = NSFont.boldSystemFont(ofSize: size) }
            if run.isDetail { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return out
    }

    private static func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.string.contains("Show Licenses") { return text }
        return view.subviews.lazy.compactMap(textView(in:)).first
    }
}

private final class LicensesLink: NSObject, NSTextViewDelegate {
    static let shared = LicensesLink()
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard link as? URL == AboutCredits.licensesLink else { return false }
        LicensesWindow.show()
        return true
    }
}

/// The Licenses window (About's Show Licenses): each bundled component's licenses, read from licenses/.
enum LicensesWindow {
    @MainActor private static var window: NSWindow?

    @MainActor static func show() {
        if window == nil, let directory = AboutCredits.licensesDirectory {
            let window = NSWindow(
                contentViewController: NSHostingController(
                    rootView: LicensesView(licenses: AboutCredits.licenses(in: directory))
                )
            )
            window.title = "Licenses"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 860, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct LicensesView: View {
    let licenses: [AboutCredits.License]
    @State private var selection: AboutCredits.License.ID?

    var body: some View {
        NavigationSplitView {
            List(licenses, selection: $selection) { Text($0.name) }
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let license = licenses.first(where: { $0.id == selection }) {
                LicenseText(text: license.text)
            } else {
                Text("No Selection").foregroundStyle(.secondary)
            }
        }
        .task { if selection == nil { selection = licenses.first?.id } }
    }
}

private struct LicenseText: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: NSFont.smallSystemFontSize, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .id(text)  // a new component starts at its top
    }
}
