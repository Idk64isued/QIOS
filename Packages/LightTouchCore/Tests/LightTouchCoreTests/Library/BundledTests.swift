import Foundation
import Testing

@testable import LightTouchCore

/// Bundled's lookups against a fake app bundle: native helpers first, then the guest tools unpacked from
/// Resources/Guest/guest.aar (into the user's caches, executable as packed), then the checkout's fallbacks; a
/// non-executable file is no tool; LTM_FILES names the files root.
struct BundledTests {
    let fm = FileManager.default

    @Test func lookupOrderAndTheUnpackedGuestTools() throws {
        try withTemporaryDirectory { work in
            let contents = work.appendingPathComponent("Check.app/Contents")
            try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleExecutable": "check", "CFBundleIdentifier": "test.check"],
                format: .xml,
                options: 0
            ).write(to: contents.appendingPathComponent("Info.plist"))
            _ = try LibraryFixtures.script(contents.appendingPathComponent("MacOS/check"), "exit 0\n")
            let packed = work.appendingPathComponent("packed/tools")
            try fm.createDirectory(at: packed, withIntermediateDirectories: true)
            _ = try LibraryFixtures.script(packed.appendingPathComponent("itmedia"), "echo guest tool\n")
            try fm.createDirectory(
                at: contents.appendingPathComponent("Resources/Guest"),
                withIntermediateDirectories: true
            )
            try LibraryFixtures.run(
                "/usr/bin/aa",
                [
                    "archive", "-d", packed.deletingLastPathComponent().path,
                    "-o", contents.appendingPathComponent("Resources/Guest/guest.aar").path
                ]
            )
            let bundle = try #require(Bundle(url: contents.deletingLastPathComponent()))

            let host = try #require(Bundled.hostToolsDirectory(of: bundle))
            #expect(
                URL(fileURLWithPath: host).standardizedFileURL
                    == contents.appendingPathComponent("MacOS").standardizedFileURL
            )
            let root = try #require(Bundled.guestRoot(resources: bundle.resourceURL))
            defer { try? fm.removeItem(at: root) }  // this test's unpacked copy
            #expect(root.path.contains("/Caches/gold.samhenri.LightTouchMac/Guest/"))
            let guestTools = root.appendingPathComponent("tools").path
            let directories = [host, guestTools]

            // A non-executable file is never a tool, nor a fallback.
            let plain = work.appendingPathComponent("com.qemu.it-agent.plist")
            try Data("fixture".utf8).write(to: plain)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
            #expect(Bundled.resolve("missing", fallbacks: [plain.path], in: directories) == nil)
            let fallback = try LibraryFixtures.script(work.appendingPathComponent("checkout-tool"), "exit 0\n")
            #expect(
                Bundled.resolve("missing", fallbacks: [plain.path, fallback.path], in: directories) == fallback.path
            )

            // A native helper of the same name wins; without it, the guest tool, unpacked and executable as packed.
            let helper = try LibraryFixtures.script(
                URL(fileURLWithPath: host).appendingPathComponent("itmedia"),
                "exit 0\n"
            )
            #expect(Bundled.tool("itmedia", in: directories) == helper.path)
            try fm.removeItem(at: helper)
            #expect(Bundled.tool("itmedia", in: directories) == guestTools + "/itmedia")
            #expect(try LibraryFixtures.run(guestTools + "/itmedia", []) == "guest tool\n")
            #expect(Bundled.resolve("itmedia", fallbacks: [fallback.path], in: directories) == guestTools + "/itmedia")

            // LTM_FILES names the device assets; else the bundle's Resources/Device.
            #expect(
                Bundled.filesRoot(
                    environment: ["LTM_FILES": work.appendingPathComponent("files").path],
                    resources: bundle.resourceURL
                )
                    == work.appendingPathComponent("files").path
            )
            try fm.createDirectory(
                at: contents.appendingPathComponent("Resources/Device"),
                withIntermediateDirectories: true
            )
            #expect(
                Bundled.filesRoot(environment: [:], resources: bundle.resourceURL)
                    == bundle.resourceURL!.appendingPathComponent("Device").path
            )
        }
        #expect(Bundled.binarySearchPaths.first == Bundled.hostToolsDirectory, "our helpers before anyone's")
    }
}
