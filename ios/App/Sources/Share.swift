import SwiftUI
import UIKit

/// Something to hand to the iOS share sheet.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet: Save to Files, AirDrop, Messages, Mail, a cloud drive, anywhere.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension LTMLog {
    /// A copy of lighttouch.log as it is right now, in the temporary folder with a time in its name, ready to share.
    /// nil if there is no log yet (it is made when a device boots and kept until the next boot).
    static func exportCopy() -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let copy = fm.temporaryDirectory.appendingPathComponent("lighttouch-\(formatter.string(from: Date())).txt")
        try? fm.removeItem(at: copy)
        do {
            try fm.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }
}
