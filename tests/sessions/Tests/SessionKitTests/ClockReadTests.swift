import Testing

@testable import SessionKit

/// The status bar's clock is found where Vision places its word: a 5.x status bar reads as one line, carrier and clock
/// together, whose center is far left of the clock's.
struct ClockReadTests {
    typealias Line = TextReader.Line

    @Test func theClockIsItsWordNotItsLine() {
        var bar = Line(text: "Light Touch 2:38 PM", x: 0.28, y: 0.02)
        bar.words = [
            Line(text: "Light", x: 0.06, y: 0.02), Line(text: "Touch", x: 0.18, y: 0.02),
            Line(text: "2:38", x: 0.47, y: 0.02), Line(text: "PM", x: 0.55, y: 0.02)
        ]
        let clock = TextReader.clock(in: [Line(text: "Messages", x: 0.12, y: 0.2), bar])
        #expect(clock?.text == "2:38" && clock?.x == 0.47)
        #expect(TextReader.clock(in: [Line(text: "9:41 AM", x: 0.5, y: 0.02)])?.x == 0.5, "a line without words")
        #expect(TextReader.clock(in: [Line(text: "Light Touch", x: 0.1, y: 0.02)]) == nil)
    }
}
