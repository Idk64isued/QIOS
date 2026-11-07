import Foundation
import Testing

@testable import HostServiceWire

/// The staging names an upload uses and which of them a late startup sweep may remove: another session's
/// leftovers only, never this session's uploads in flight, never a path that escapes the directory.
struct StagingNamesTests {
    @Test func stagingNamesAreUniqueAndOnlyOrphansAreSwept() {
        let file = URL(fileURLWithPath: "/tmp/Temple Run.ipa")
        let first = DeviceServices.stagingName(file)
        let second = DeviceServices.stagingName(file)
        #expect(first != second)
        #expect(!first.contains("/"))
        let old = "Temple_Run-01234567.ipa"
        // The directory listing returns after both new uploads started.
        #expect([old, first, second, ".", "..", "../escape", ""].filter(DeviceServices.isOrphanedStagingName) == [old])
    }

    @Test func orphanedMediaUploadsAreOtherSessionsUploadsOnly() {
        let uuid = UUID().uuidString
        #expect(DeviceServices.isOrphanedMediaUpload("audio.m4a.upload-" + uuid))
        #expect(DeviceServices.isOrphanedMediaUpload("image.jpg.upload-" + uuid + "-" + UUID().uuidString))
        #expect(!DeviceServices.isOrphanedMediaUpload("audio.m4a.upload-" + DeviceServices.stagingSession + "-" + uuid))
        for name in [
            "audio.m4a", "image.jpg", ".photo-receipt", "song.json", "audio.m4a.upload-invalid",
            "../image.jpg.upload-" + uuid
        ] {
            #expect(!DeviceServices.isOrphanedMediaUpload(name), "\(name)")
        }
    }
}
