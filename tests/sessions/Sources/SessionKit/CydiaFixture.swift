import CryptoKit
import Foundation

/// The Cydia repositories a jailbroken base's check talks to, made locally so the check needs no internet (the web
/// proxy serves this tree: LightTouchDevice/WebProxy.swift `fixture`). The four sources FirmwareKit seeds answer as
/// they do online (Release and Packages.bz2 at the paths Cydia's APT asks for; `_` is any one path segment, the
/// Core Foundation version in apt.saurik.com's dist), Cydia/Telesphoreo listing one package of ours, `package`, whose
/// one file prints 42; Cydia's front page is a page and a stylesheet; iOS's captive-network probe gets Success.
public enum CydiaFixture {
    public static let package = "ltm-fixture"
    /// What the check runs once the package is installed, and what it prints.
    public static let command = ["/usr/bin/ltm-fixture"]
    public static let output = "42"
    /// The dist directories (under each host) FirmwareKit's sources point Cydia's APT at.
    static let dists = [
        "apt.saurik.com/dists/ios/_", "apt.thebigboss.org/repofiles/cydia/dists/stable",
        "modmyi.saurik.com/dists/stable", "zodttd.saurik.com/repo/cydia/dists/stable"
    ]

    /// Writes the tree into `root` (made, or replaced).
    public static func write(to root: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        func put(_ path: String, _ data: Data) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let deb = try self.deb()
        let filename = "debs/\(package)_1.0_iphoneos-arm.deb"
        try put("apt.saurik.com/" + filename, deb)
        let stanza = """
            Package: \(package)
            Version: 1.0
            Architecture: iphoneos-arm
            Maintainer: Light Touch
            Installed-Size: 4
            Filename: \(filename)
            Size: \(deb.count)
            MD5sum: \(Insecure.MD5.hash(data: deb).map { String(format: "%02x", $0) }.joined())
            Section: Utilities
            Name: Light Touch Fixture
            Description: the harness's package, installed through Cydia


            """
        for dist in dists {
            try put(
                dist + "/Release",
                Data(
                    "Origin: Light Touch\nLabel: Light Touch\nSuite: stable\nCodename: ios\nArchitectures: iphoneos-arm\nComponents: main\n"
                        .utf8
                )
            )
            let packages = dist.hasPrefix("apt.saurik.com/") ? stanza : ""
            try put(
                dist + "/main/binary-iphoneos-arm/Packages.bz2", try tool(["/usr/bin/bzip2", "-c"], Data(packages.utf8))
            )
        }
        // Cydia opens /ui/<idiom>/1.1/, which sends it to home/.
        try put(
            "cydia.saurik.com/ui/_/1.1/index.html",
            Data("<html><head><meta http-equiv=\"refresh\" content=\"0; url=home/\"></head></html>\n".utf8)
        )
        try put(
            "cydia.saurik.com/ui/_/1.1/home/index.html",
            Data(
                "<html><head><link rel=\"stylesheet\" href=\"style.css\"></head><body><h1>Light Touch</h1></body></html>\n"
                    .utf8
            )
        )
        try put("cydia.saurik.com/ui/_/1.1/home/style.css", Data("h1 { text-align: center }\n".utf8))
        try put(
            "www.apple.com/library/test/success.html",
            Data("<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>".utf8)
        )
    }

    /// The package: an ar archive of debian-binary, control.tar.gz and data.tar.gz (/usr/bin/ltm-fixture), as dpkg
    /// reads them, made with the Mac's tar.
    static func deb() throws -> Data {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-cydia-fixture-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let control = dir.appendingPathComponent("control")
        let data = dir.appendingPathComponent("data")
        try fm.createDirectory(at: control, withIntermediateDirectories: true)
        try fm.createDirectory(at: data.appendingPathComponent("usr/bin"), withIntermediateDirectories: true)
        try Data(
            "Package: \(package)\nVersion: 1.0\nArchitecture: iphoneos-arm\nMaintainer: Light Touch\nDescription: the harness's package\n"
                .utf8
        )
        .write(to: control.appendingPathComponent("control"))
        let script = data.appendingPathComponent("usr/bin/ltm-fixture")
        try Data("#!/bin/sh\necho $((6 * 7))\n".utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        func tarball(_ dir: URL) throws -> Data {
            try tool(
                [
                    "/usr/bin/tar", "--format", "ustar", "--uid", "0", "--gid", "0", "--uname", "root", "--gname",
                    "wheel", "-czf", "-", "-C", dir.path, "."
                ],
                Data()
            )
        }
        return ar([
            ("debian-binary", Data("2.0\n".utf8)), ("control.tar.gz", try tarball(control)),
            ("data.tar.gz", try tarball(data))
        ])
    }

    /// A common-format ar archive (each name at most 15 bytes).
    static func ar(_ members: [(String, Data)]) -> Data {
        var out = Data("!<arch>\n".utf8)
        func field(_ s: String, _ width: Int) -> String { s.padding(toLength: width, withPad: " ", startingAt: 0) }
        for (name, body) in members {
            let header =
                field(name, 16) + field("0", 12) + field("0", 6) + field("0", 6) + field("100644", 8)
                + field("\(body.count)", 10) + "`\n"
            out += Data(header.utf8) + body
            if body.count % 2 == 1 { out += Data("\n".utf8) }
        }
        return out
    }

    /// `argv`'s standard output, given `input`; throws when it fails.
    static func tool(_ argv: [String], _ input: Data) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        try p.run()
        inPipe.fileHandleForWriting.write(input)
        try inPipe.fileHandleForWriting.close()
        let output = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "\(argv[0]) failed"])
        }
        return output
    }
}
