import CoreGraphics
import Testing

@testable import LightTouchCore

/// Physical Size's points per millimeter: measured sizes kept, CoreGraphics' 72-dpi fallback and bad metadata refused.
struct DisplayMeasurementsTests {
    let logical = CGSize(width: 1512, height: 982)

    @Test func measuredSizeGivesPointsPerMillimeter() throws {
        let value = try #require(
            DisplayMeasurements.pointsPerMillimeter(
                logical: logical,
                hardware: CGSize(width: 302.4, height: 196.4),
                fallbackBounds: logical
            )
        )
        #expect(abs(value * 110 - 550) < 0.01)
    }

    @Test(arguments: [
        CGSize(width: 1512 * 25.4 / 72, height: 982 * 25.4 / 72),  // the synthetic 72 dpi estimate
        .zero,  // absent
        CGSize(width: 100, height: 500)  // inconsistent aspect
    ])
    func unusableMetadataIsRefused(_ hardware: CGSize) {
        #expect(
            DisplayMeasurements.pointsPerMillimeter(logical: logical, hardware: hardware, fallbackBounds: logical)
                == nil
        )
    }
}
