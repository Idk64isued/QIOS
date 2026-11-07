// The Mac's region and clock format for a device's lockdown (lockdown-tz --locale/--24h).

import Foundation

/// The Mac's region and clock format, as lockdown takes them: com.apple.international's Locale ("en_GB") and the
/// 24-hour key. The device's language is left alone.
public nonisolated struct ClockRegion: Equatable, Sendable {
    public var locale: String
    public var uses24HourClock: Bool

    public static var mac: ClockRegion {
        ClockRegion(
            Locale.autoupdatingCurrent,
            appleLocale: CFPreferencesCopyAppValue("AppleLocale" as CFString, kCFPreferencesAnyApplication) as? String
        )
    }

    public init(locale: String, uses24HourClock: Bool) {
        self.locale = locale
        self.uses24HourClock = uses24HourClock
    }

    /// `locale`'s language and region ("en_GB"; a region override "@rg=chzzzz" gives its region, "de_CH"), and whether its time format
    /// (the "j" skeleton, which follows System Settings' 24-hour switch) is 24-hour.
    public init(_ locale: Locale) {
        let language = locale.language.languageCode?.identifier ?? "en"
        self.locale = locale.region.map { "\(language)_\($0.identifier)" } ?? language
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        uses24HourClock = format.contains("H") || format.contains("k")
    }

    /// `locale`'s 24-hour setting with the region formats of `appleLocale`, the user's AppleLocale preference, where
    /// there is one: in an app localized only in English, `locale` (Locale.current) carries the app's language with
    /// the user's region, en_UA for a uk_UA user, which would replace the uk_UA the device was prepared with.
    init(_ locale: Locale, appleLocale: String?) {
        self.init(locale)
        if let appleLocale { self.locale = ClockRegion(Locale(identifier: appleLocale)).locale }
    }

    /// lockdown-tz's options.
    public var arguments: [String] { ["--locale", locale, "--24h", uses24HourClock ? "1" : "0"] }
}
