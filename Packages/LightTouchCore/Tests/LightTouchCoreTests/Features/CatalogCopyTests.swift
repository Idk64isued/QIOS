import Crypto
import Foundation
import Testing

@testable import LightTouchCore

/// A copy record's checks: the minimum OS against the device's own version, architecture, encryption, family and
/// the downloaded file's size and checksum (CatalogCopy).
struct CatalogCopyTests {
    @Test(arguments: [
        ("2.2.1", true), ("3", true), ("3.1.3", true), ("3.1.4", false), ("3.2", false), ("10.0", false),
        ("3.x", false), ("-1", false), ("3..1", false), ("", false)
    ])
    func minimumOSAgainstTheDefaultDevice(_ os: String, _ allowed: Bool) {
        #expect((CatalogCopy.osIssue(os) == nil) == allowed)
    }

    /// The device's own version, not 3.1.3: a 4.2.1 iPod takes 4.0 apps, a 3.2.2 iPad refuses 4.0 and takes 3.2.
    @Test(arguments: [
        ("4.0", "4.2.1", true), ("4.2.1", "4.2.1", true), ("4.3", "4.2.1", false),
        ("3.2", "3.2.2", true), ("4.0", "3.2.2", false), ("3.1.3", "3.2", true)
    ])
    func minimumOSAgainstTheDevice(_ os: String, _ device: String, _ allowed: Bool) {
        #expect((CatalogCopy.osIssue(os, deviceOS: device) == nil) == allowed)
    }

    @Test func osIssueWords() {
        #expect(CatalogCopy.osIssue("4.0", deviceOS: "3.2.2") == "Requires iOS 4.0; this device runs iOS 3.2.2.")
    }

    static let good: [String: Any] = [
        "ipa_id": "123", "size": 3, "md5": "900150983cd24fb0d6963f7d28e17f72", "available": true,
        "binary": ["install_status": "installable", "architectures": ["armv6"], "macho_min_os": "3.0"]
    ]
    static func copy(_ changes: [String: Any] = [:]) throws -> CatalogCopy {
        try JSONDecoder().decode(
            CatalogCopy.self,
            from: JSONSerialization.data(withJSONObject: good.merging(changes) { _, new in new })
        )
    }

    @Test func compatibility() throws {
        #expect(try Self.copy().unavailableReason(minimumOS: "3.0") == nil)
        #expect(try Self.copy().unavailableReason(minimumOS: "3.2") != nil)
        // The iPad's armv7 CPU runs an armv6-only copy and an armv7 one; its version is the iPad's.
        #expect(try Self.copy().unavailableReason(minimumOS: "3.0", deviceOS: "3.2.2", arch: "armv7") == nil)
        let armv7: [String: Any] = [
            "binary": [
                "install_status": "installable", "architectures": ["armv7"], "macho_min_os": "3.2",
                "device_family_macho": ["2"]
            ]
        ]
        #expect(try Self.copy(armv7).unavailableReason(minimumOS: "3.2", deviceOS: "3.2.2", arch: "armv7") == nil)
        #expect(try Self.copy(armv7).unavailableReason(minimumOS: "4.0", deviceOS: "3.2.2", arch: "armv7") != nil)
        #expect(try Self.copy(armv7).unavailableReason(minimumOS: "3.2", arch: "armv6") != nil)
        for changes: [String: Any] in [
            ["available": false], ["binary": NSNull()],
            ["binary": ["install_status": "encrypted", "architectures": ["armv6"]]],
            ["binary": ["install_status": "installable", "architectures": ["armv7"]]],
            ["binary": ["install_status": "installable", "architectures": ["armv6"], "macho_min_os": "4.0"]],
            ["binary": ["install_status": "installable", "architectures": ["armv6"], "device_family_macho": ["3"]]]
        ] {
            #expect(try Self.copy(changes).unavailableReason(minimumOS: "2.0") != nil, "\(changes)")
        }
    }

    @Test func downloadIntegrity() async throws {
        try await withTemporaryState { directory in
            let file = directory.appendingPathComponent("abc")
            try Data("abc".utf8).write(to: file)
            try await Self.copy().verifyDownload(file)
            for changes: [String: Any] in [["size": 4], ["md5": String(repeating: "0", count: 32)], ["md5": "bad"]] {
                await #expect(throws: CatalogError.self) { try await Self.copy(changes).verifyDownload(file) }
            }
        }
    }

    /// Live copy record (Box.net 1682, 09-29): Mach-O families come as numbers ([1,2]), not strings.
    @Test func numericDeviceFamilies() throws {
        let box = try JSONDecoder().decode(
            CatalogCopy.self,
            from: Data(contentsOf: fixture("store-compat/live-copy-1682.json"))
        )
        #expect(box.binary?.deviceFamilyMachO == ["1", "2"])
        #expect(box.unavailableReason(minimumOS: "3.0", deviceOS: "4.2", arch: "armv7") == nil)
    }

    /// Copy record 2.1: armv7_code refuses an armv6 device only; a 2.0 record has none and passes on armv6.
    @Test func armv7CodeInAnArmv6Slice() throws {
        let copy = try JSONDecoder().decode(
            CatalogCopy.self,
            from: Data(contentsOf: fixture("store-compat/new-copy-195588.json"))
        )
        #expect(copy.unavailableReason(minimumOS: "3.0") == "This copy needs a newer processor than this device has.")
        #expect(copy.unavailableReason(minimumOS: "3.0", deviceOS: "3.2", arch: "armv7") == nil)
        let old = try JSONDecoder().decode(
            CatalogCopy.self,
            from: Data(contentsOf: fixture("store-compat/old-copy-195588.json"))
        )
        #expect(old.binary?.armv7Code == nil && old.unavailableReason(minimumOS: "3.0") == nil)
    }
}

/// The words a Legacy Store failure and an excluded app reach the user in (CatalogError, CatalogApp).
struct CatalogWordsTests {
    @Test func serverErrorsReadPlainly() {
        #expect(
            CatalogError.badStatus(502).localizedDescription == "Legacy Store isn’t responding. Try again in a moment."
        )
        for code in [404, 500, 0] { #expect(!CatalogError.badStatus(code).localizedDescription.contains("HTTP")) }
        #expect(
            CatalogError.unreadable.localizedDescription == "Legacy Store sent a response Light Touch couldn’t read."
        )
        #expect(
            CatalogError.unsupportedDevice(name: "iPhone 4").localizedDescription
                == "Legacy Store doesn’t support iPhone 4 yet."
        )
        #expect(
            CatalogError.status(400, body: Data("{}".utf8)).localizedDescription
                == CatalogError.badStatus(400).localizedDescription
        )
        if case .unsupportedDevice = CatalogError.status(
            400,
            body: Data(#"{"error":"device must be one of iPod1,1"}"#.utf8)
        ) {
        } else {
            Issue.record("a 400 naming the devices is unsupportedDevice")
        }
    }

    @Test(arguments: [
        ("no_armv6_or_armv7_slice", "Needs a newer processor"),
        ("unsupported_device_family", "Not made for this device"),
        ("capability:telephony", "Needs hardware this device doesn’t have"),
        ("capability:!armv6", "Not made for this device"),
        ("encrypted", "Encrypted — can’t open in Light Touch"), ("something_new", "Not compatible with this device")
    ])
    func incompatibilityReasons(_ code: String, _ words: String) {
        let app = CatalogApp(
            name: "",
            ipaID: 1,
            downloadURL: URL(string: "https://example.invalid")!,
            compat: .init(compatible: false, reasons: [code])
        )
        #expect(app.incompatibility == words)
        #expect(app.subtitle == words)
    }
}
