import CryptoKit
import Foundation
import Testing

@testable import SessionKit

/// The local Cydia repositories: each seeded source has a Release and a Packages.bz2, and Cydia/Telesphoreo's lists
/// the fixture's package with the size and MD5 of the .deb served beside it, which the Mac's ar and tar read as dpkg
/// would (debian-binary first; an executable /usr/bin/ltm-fixture owned by root).
struct CydiaFixtureTests {
    static func shell(_ command: String) throws -> String {
        String(decoding: try CydiaFixture.tool(["/bin/sh", "-c", command], Data()), as: UTF8.self)
    }

    @Test func servesEverySourceAndAnInstallablePackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try CydiaFixture.write(to: root)
        for dist in CydiaFixture.dists {
            #expect(FileManager.default.fileExists(atPath: root.path + "/\(dist)/Release"))
            #expect(
                FileManager.default.fileExists(atPath: root.path + "/\(dist)/main/binary-iphoneos-arm/Packages.bz2"))
        }
        let packages = try Self.shell(
            "bzip2 -dc '\(root.path)/apt.saurik.com/dists/ios/_/main/binary-iphoneos-arm/Packages.bz2'")
        let fields = Dictionary(
            packages.split(separator: "\n").compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            },
            uniquingKeysWith: { a, _ in a }
        )
        #expect(fields["Package"] == CydiaFixture.package)
        let deb = try Data(contentsOf: root.appendingPathComponent("apt.saurik.com/" + (fields["Filename"] ?? "")))
        #expect(fields["Size"] == "\(deb.count)")
        #expect(fields["MD5sum"] == Insecure.MD5.hash(data: deb).map { String(format: "%02x", $0) }.joined())

        let path = root.appendingPathComponent("apt.saurik.com/" + fields["Filename"]!).path
        #expect(try Self.shell("ar -t '\(path)'") == "debian-binary\ncontrol.tar.gz\ndata.tar.gz\n")
        #expect(try Self.shell("ar -p '\(path)' debian-binary") == "2.0\n")
        let listing = try Self.shell("ar -p '\(path)' data.tar.gz | tar -tvzf -")
        #expect(listing.contains("-rwxr-xr-x  0 root   wheel"))
        #expect(listing.contains("./usr/bin/ltm-fixture"))
        #expect(
            try Self.shell("ar -p '\(path)' control.tar.gz | tar -xOzf - ./control").contains("Package: ltm-fixture"))
        #expect(try Self.shell("ar -p '\(path)' data.tar.gz | tar -xOzf - ./usr/bin/ltm-fixture | sh") == "42\n")
    }
}
