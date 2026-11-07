// Tweaks' Marketing Status Bar: the status bar a screenshot wants (StatusBarStyle), in each firmware's own way.
//
// 4.2 to 7.1.2: UIKit's status bar override data (+[UIStatusBarServer postStatusBarOverrideData:]), laid out for one
// firmware: what Apple's internal Status Bar Overrides pane posted (the agent's `statusbar` op sends it). The struct is
// UIKit's private StatusBarOverrideData: overrideItemIsEnabled[N] at 0, the override bits right after it, and the
// StatusBarRawData values from byte 28 (itemIsEnabled[N], timeString[64], the GSM signal, serviceString[100], …).
// Offsets from each build's method type encoding and the merge routines that read it (4.2.1, 4.3.3, 5.1.1, 6.1.6, 7.1.2
// dyld caches), the item numbers from UIKit's status bar item table (its entries' names: Time, …, Bluetooth, TTY,
// Alarm, …, Location, RotationLock, …, Activity, ThermalColor, in item order): a firmware whose layout was not read
// gets none. 5.0 (9A334), 6.0 (10A403) and 7.0 (beta 11A4372q) encode the struct as the next minor does, up to the
// bitfields at its end, with the same item tables; 4.1 (8B117) has no postStatusBarOverrideData.
//
// 1.0 to 4.1: SpringBoard's own demo keys, read in -loadDebuggingAndDemoPrefs (3.1.3 0x848a, 4.0 0x9d68; the keys
// in every SpringBoard from 2.2.1 to 4.1, 3.2.2 too): SBFakeTime with SBFakeTimeString is the clock's text
// (SBStatusBarTimeView tile, 4.0 and 4.1 SBStatusBarDataManager _updateTimeString); SBFakeCarrier the operator name;
// SBFakeBars, an integer, full bars where it is nonzero (5 cellular, 3 Wi-Fi with Wi-Fi as the data network where it
// is 1) and a full battery (displayBatteryCapacityAsPercentage answers 100). 1.0 and 1.1.4's SpringBoards name the same
// keys, but for 1.0's SBFakeCarrier.

import BinaryParsing
import Foundation

/// What the status bar shows with Marketing Status Bar on (TweakSettings.statusBar).
public nonisolated struct StatusBarStyle: Codable, Equatable, Sendable {
    public init() {}

    /// The clock's text; empty: the real time.
    public var time = "9:41 AM"
    /// The carrier's name (an iPod's or iPad's "iPod"/"iPad" in its place); empty: the network's own.
    public var carrier = ""
    /// Cellular bars, 0...5.
    public var cellBars = 5
    /// Wi-Fi bars, 0...3.
    public var wifiBars = 3
    /// Battery, percent.
    public var battery = 100
    public var charging = false
    /// The alarm, location, Bluetooth, rotation lock and activity indicators hidden.
    public var hidesIndicators = true

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        time = try c.decodeIfPresent(String.self, forKey: .time) ?? d.time
        carrier = try c.decodeIfPresent(String.self, forKey: .carrier) ?? d.carrier
        cellBars = try c.decodeIfPresent(Int.self, forKey: .cellBars) ?? d.cellBars
        wifiBars = try c.decodeIfPresent(Int.self, forKey: .wifiBars) ?? d.wifiBars
        battery = try c.decodeIfPresent(Int.self, forKey: .battery) ?? d.battery
        charging = try c.decodeIfPresent(Bool.self, forKey: .charging) ?? d.charging
        hidesIndicators = try c.decodeIfPresent(Bool.self, forKey: .hidesIndicators) ?? d.hidesIndicators
    }

    /// Whether `version` takes it as SpringBoard's demo keys (1.0 to 4.1): the clock's text and the carrier, with
    /// full bars and battery.
    public static func takesKeys(version: String) -> Bool { TweakSettings.before(version, "4.2") }

    /// Whether its SpringBoard reads SBFakeCarrier: 1.0's has the other demo keys and not that one (1.1.4's has it).
    public static func takesCarrier(version: String) -> Bool { !TweakSettings.before(version, "1.1") }

    /// The keys that set it on a 1.0 to 4.1 SpringBoard.
    func keys(version: String) -> [GuestDefault] {
        var keys = [GuestDefault("com.apple.springboard", "SBFakeBars", .int(1))]
        if !time.isEmpty {
            keys += [
                GuestDefault("com.apple.springboard", "SBFakeTime", .bool(true)),
                GuestDefault("com.apple.springboard", "SBFakeTimeString", .string(time))
            ]
        }
        if !carrier.isEmpty, Self.takesCarrier(version: version) {
            keys.append(GuestDefault("com.apple.springboard", "SBFakeCarrier", .string(carrier)))
        }
        return keys
    }
}

public nonisolated struct StatusBarOverride: Sendable {
    let size: Int
    /// overrideItemIsEnabled's count: the override bits start at this byte.
    let items: Int
    /// The bits as (byte, bit).
    let wifiBars: (Int, Int), dataNetwork: (Int, Int), batteryCapacity: (Int, Int), batteryState: (Int, Int)
    /// values' fields.
    let time: Int, gsmBars: Int, wifiBarsValue: Int
    /// The alarm, location, Bluetooth, rotation lock and activity items' numbers.
    let indicators: [Int]

    /// Where the values (StatusBarRawData) start: the data getStatusBarData reads back.
    static let values = 28

    /// The layout of `version`'s UIKit; nil where it was not read.
    public static func layout(version: String) -> StatusBarOverride? {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        switch (parts[0], parts[1]) {
        case (4, 2):
            return .init(
                size: 1992,
                items: 22,
                wifiBars: (23, 1),
                dataNetwork: (23, 2),
                batteryCapacity: (23, 3),
                batteryState: (23, 4),
                time: 50,
                gsmBars: 120,
                wifiBarsValue: 1456,
                indicators: [12, 15, 10, 16, 20]
            )
        case (4, 3):
            return .init(
                size: 1892,
                items: 22,
                wifiBars: (23, 1),
                dataNetwork: (23, 2),
                batteryCapacity: (23, 3),
                batteryState: (23, 4),
                time: 50,
                gsmBars: 120,
                wifiBarsValue: 1456,
                indicators: [12, 15, 10, 16, 20]
            )
        case (5, 0), (5, 1):
            return .init(
                size: 2092,
                items: 23,
                wifiBars: (24, 2),
                dataNetwork: (24, 3),
                batteryCapacity: (24, 5),
                batteryState: (24, 6),
                time: 51,
                gsmBars: 120,
                wifiBarsValue: 1656,
                indicators: [12, 15, 10, 16, 21]
            )
        case (6, 0), (6, 1):
            return .init(
                size: 1992,
                items: 24,
                wifiBars: (25, 1),
                dataNetwork: (25, 2),
                batteryCapacity: (25, 4),
                batteryState: (25, 5),
                time: 52,
                gsmBars: 120,
                wifiBarsValue: 1556,
                indicators: [12, 15, 10, 16, 22]
            )
        case (7, 0), (7, 1):
            return .init(
                size: 2000,
                items: 25,
                wifiBars: (26, 1),
                dataNetwork: (26, 2),
                batteryCapacity: (26, 4),
                batteryState: (26, 5),
                time: 53,
                gsmBars: 124,
                wifiBarsValue: 1560,
                indicators: [13, 16, 11, 17, 23]
            )
        default: return nil
        }
    }

    /// The values' size: what the agent's `statusbarget data` reads (getStatusBarData).
    public var rawSize: Int { size - Self.values }

    /// What status bar raw data (getStatusBarData: SpringBoard's, the overrides merged in) shows: the clock's text,
    /// the carrier and the battery. The guest's bytes: a C string is read within its char[capacity] field, what the
    /// data doesn't hold reads as empty (the battery as -1).
    public func shown(_ raw: Data) -> (time: String, carrier: String, battery: Int) {
        func text(_ at: Int, capacity: Int) -> String {
            let field = try? raw.withParserSpan { s throws(ParsingError) in
                try s.seek(toRelativeOffset: at - Self.values)
                return try [UInt8](parsing: &s, byteCount: min(capacity, s.count))
            }
            return String(decoding: (field ?? []).prefix { $0 != 0 }, as: UTF8.self)
        }
        let battery = try? raw.withParserSpan { s throws(ParsingError) in
            try s.seek(toRelativeOffset: wifiBarsValue + 8 - Self.values)
            return Int(try Int32(parsingLittleEndian: &s))
        }
        return (text(time, capacity: 64), text(gsmBars + 4, capacity: 100), battery ?? -1)
    }

    /// No overrides: posting it gives the status bar back to SpringBoard.
    public var cleared: Data { Data(count: size) }

    /// `style` as overrides. The override bits are UIKit's bitfield in declaration order (time, GSM raw, GSM bars,
    /// service string, the service images, …, Wi-Fi bars, data network, …, battery capacity and state); the service
    /// string sits right after the GSM bars on every layout.
    public func data(_ style: StatusBarStyle) -> Data {
        var d = Data(count: size)
        func bit(_ at: (Int, Int)) { d[at.0] |= UInt8(1 << at.1) }
        func int(_ value: Int, at offset: Int) {
            withUnsafeBytes(of: Int32(value).littleEndian) { d.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        // A C string in a char[capacity] field: whole characters, NUL-terminated.
        func string(_ s: String, at offset: Int, capacity: Int) {
            var s = s
            while s.utf8.count >= capacity { s.removeLast() }
            d.replaceSubrange(offset..<offset + s.utf8.count, with: Data(s.utf8))
        }
        if !style.time.isEmpty {
            bit((items, 0))
            string(style.time, at: time, capacity: 64)
        }
        bit((items, 2))  // GSM signal bars
        int(min(max(style.cellBars, 0), 5), at: gsmBars)
        if !style.carrier.isEmpty {
            bit((items, 3))
            string(style.carrier, at: gsmBars + 4, capacity: 100)
        }
        bit(wifiBars)
        int(min(max(style.wifiBars, 0), 3), at: wifiBarsValue)
        bit(dataNetwork)
        int(5, at: wifiBarsValue + 4)  // Wi-Fi: the data network shows its bars
        bit(batteryCapacity)
        int(min(max(style.battery, 0), 100), at: wifiBarsValue + 8)
        bit(batteryState)
        int(style.charging ? 1 : 0, at: wifiBarsValue + 12)  // 0 draining, 1 charging
        if style.hidesIndicators {
            for item in indicators { d[item] = 1 }  // overridden, and values.itemIsEnabled[item] stays 0
        }
        return d
    }
}
