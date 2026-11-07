import Foundation
import Testing

@testable import SessionKit

/// The driver's lit timer does not run during boot admission, however long it takes, and runs from its end.
struct BootBudgetTests {
    @Test func litTimerStartsAfterAdmission() {
        let now = Date()
        #expect(litSeconds(admitted: nil, now: now) == 0)
        #expect(litSeconds(admitted: now.addingTimeInterval(-30), now: now) == 30)
    }
}
