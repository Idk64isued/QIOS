import Foundation
import Testing

@testable import LightTouchCore

/// ClockRegion turns a Mac locale (its region override and 24-hour switch included) into lockdown's Locale id and
/// 24-hour flag (lockdown-tz --locale/--24h).
struct ClockRegionTests {
    func region(_ id: String) -> ClockRegion { ClockRegion(Locale(identifier: id)) }

    @Test func localeAndClockFormat() {
        #expect(region("en_GB") == ClockRegion(locale: "en_GB", uses24HourClock: true))
        #expect(region("en_US") == ClockRegion(locale: "en_US", uses24HourClock: false))
        #expect(
            region("en_US@hours=h23") == ClockRegion(locale: "en_US", uses24HourClock: true),
            "the Mac's 24-hour switch"
        )
        #expect(region("en_GB@hours=h12").uses24HourClock == false, "the Mac's 12-hour switch")
        #expect(region("de_DE@rg=chzzzz").locale == "de_CH", "a region override gives its region")
    }

    /// The Mac's region formats are the user's AppleLocale, not the app's Locale.current, whose language is the app's
    /// (issue 85: en_UA replaced the uk_UA a device was prepared with).
    @Test func regionIsTheUsersAppleLocale() {
        #expect(ClockRegion(Locale(identifier: "en_UA"), appleLocale: "uk_UA").locale == "uk_UA")
        #expect(ClockRegion(Locale(identifier: "en_US@hours=h23"), appleLocale: "uk_UA").uses24HourClock)
        #expect(ClockRegion(Locale(identifier: "en_UA"), appleLocale: "de_DE@rg=chzzzz").locale == "de_CH")
        #expect(ClockRegion(Locale(identifier: "en_UA"), appleLocale: nil).locale == "en_UA")
    }

    @Test func lockdownTZArguments() {
        #expect(region("en_US").arguments == ["--locale", "en_US", "--24h", "0"])
        #expect(region("en_GB").arguments == ["--locale", "en_GB", "--24h", "1"])
    }
}
