import SessionKit
import Testing

struct ReportTests {
    /// A run's last line is PASS with the tally and the log, or FAIL with its first failed check.
    @Test func theVerdictNamesTheFirstFailure() {
        let report = Report()
        report.check(true, "boots")
        #expect(report.verdict(log: "/w") == "PASS 1/1 passed /w")
        report.check(false, "Home screen")
        report.check(false, "music library")
        #expect(report.verdict(log: "/w") == "FAIL Home screen (1/3 passed) /w")
    }
}
