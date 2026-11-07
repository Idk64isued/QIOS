import Foundation
import Testing

@testable import LightTouchCore

/// About's credits: the build record's components (qemu-ios, usbmuxd, guest tools first, then by name), each project
/// linked to its site with its license, the link to the Licenses window; and that window's entries, read from the
/// bundled licenses/ folder.
struct AboutCreditsTests {
    @Test func componentsThenProjectsThenTheLicensesLink() throws {
        let inputs = Data(
            #"{"components":{"libplist":"2.7.0","qemu-ios":"0e4bf5a90b","guest tools":"1.1.14 (serial 16)","usbmuxd":"e19fac2d4b","glib":"2.88.3"}}"#
                .utf8
        )
        let runs = AboutCredits.runs(buildInputs: inputs, licenses: true)
        let s = runs.map(\.text).joined()
        #expect(
            s.hasPrefix(
                "Components\nqemu-ios 0e4bf5a90b\nusbmuxd e19fac2d4b\nguest tools 1.1.14 (serial 16)\nglib 2.88.3\nlibplist 2.7.0\n\nOpen-Source Software\nQEMU\tGPL-2.0\n"
            ),
            "\(s)"
        )
        #expect(runs.filter(\.isHeading).map(\.text) == ["Components\n", "Open-Source Software\n"])
        // Every project is a line of its own, its name linked to its site and its license beside it.
        for project in AboutCredits.projects {
            let i = try #require(runs.firstIndex { $0.text == project.name })
            #expect(runs[i].link == project.site && runs[i].link?.scheme == "https")
            #expect(runs[i + 1].text == "\t\(project.license)\n" && runs[i + 1].isDetail)
        }
        #expect(runs.last == .init(text: "\nShow Licenses", link: AboutCredits.licensesLink))
    }

    /// The credits name each Swift package the ledger (build-support/dependencies.json's "swiftpm" records) says ships,
    /// and no other.
    @Test func everyShippedSwiftPackageIsCredited() throws {
        let ledger = URL(fileURLWithPath: #filePath).appendingPathComponent(
            "../../../../../../build-support/dependencies.json"
        ).standardized
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as? [String: Any]
        let shipped = (object?["packages"] as? [[String: Any]] ?? []).filter {
            ($0["groups"] as? [String])?.contains("swiftpm") == true
        }.compactMap { $0["name"] as? String }
        let credited = AboutCredits.projects.map(\.directory).filter { $0.hasPrefix("swift/") }.map { $0.dropFirst(6) }
        #expect(Set(credited.map(String.init)) == Set(shipped))
    }

    /// A development build has no build record or license files: the projects, without Show Licenses.
    @Test func developmentBuildListsTheProjectsWithoutShowLicenses() {
        let runs = AboutCredits.runs(buildInputs: nil, licenses: false)
        #expect(runs.first?.text == "Open-Source Software\n")
        #expect(
            runs.count == 1 + 2 * AboutCredits.projects.count && !runs.contains { $0.link == AboutCredits.licensesLink }
        )
    }

    /// The window lists a folder per component (each Swift package on its own) by its projects' names, with its license
    /// and source note, never its patches or code.
    @Test func licensesWindowReadsTheBundledFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("licenses-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("qemu/COPYING", "GNU GPL v2")
        try write("qemu/SOURCE.txt", "qemu-ios commit abc")
        try write("glib/COPYING", "GNU LGPL")
        try write("glib/glib-pipe2-availability.patch", "--- a/glib")
        try write("swift/ZIPFoundation/LICENSE", "MIT ZIPFoundation")
        try write("swift/swift-crypto/LICENSE.txt", "Apache crypto")
        try write("swift/swift-crypto/NOTICE.txt", "crypto notice")
        try write("mystery/LICENSE", "Unknown")
        try write("empty/build.sh", "make")
        let licenses = AboutCredits.licenses(in: root)
        #expect(licenses.map(\.name) == ["GLib", "mystery", "QEMU and qemu-ios", "Swift Crypto", "ZIPFoundation"])
        let qemu = try #require(licenses.first { $0.directory == "qemu" })
        #expect(qemu.text == "COPYING\n\nGNU GPL v2\n\nSOURCE.txt\n\nqemu-ios commit abc")
        let glib = try #require(licenses.first { $0.directory == "glib" })
        #expect(!glib.text.contains("--- a/glib"))
        #expect(licenses.first { $0.directory == "swift/swift-crypto" }?.text.contains("crypto notice") == true)
    }
}
