import Foundation
import Testing

@testable import SessionKit

/// `sessions listings`' diff: by path, what went, what came and what changed, the header too.
struct VolumeListingTests {
    @Test func diffsByPath() {
        let recorded = "# HX free=10\na\t0:0\t755\nb\t0:0\t644\t1\nc\t0:0\t644\t2\n"
        let current = "# HX free=9\na\t0:0\t755\nb\t0:0\t600\t1\nd\t0:0\t644\t3\n"
        #expect(
            VolumeListing.diff(recorded: recorded, current: current) == [
                "- # HX free=10", "+ # HX free=9", "- b\t0:0\t644\t1", "+ b\t0:0\t600\t1", "- c\t0:0\t644\t2",
                "+ d\t0:0\t644\t3"
            ]
        )
        #expect(VolumeListing.diff(recorded: recorded, current: recorded).isEmpty)
    }
}
