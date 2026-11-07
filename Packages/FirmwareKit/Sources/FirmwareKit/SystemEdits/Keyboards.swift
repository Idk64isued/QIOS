// Keyboards: a prepared device's AppleKeyboards, the iOS keyboards for its language and the Mac's enabled keyboard
// layouts and input modes, as the firmware's own TextInput bundles name them (seedLanguage).

import Carbon
import Foundation

extension SystemEdits {
    /// One of the Mac's input sources (Text Input Sources): its ID, languages, localized name, and whether it is a
    /// keyboard layout (com.apple.keylayout.French) rather than an input method's mode or the Emoji & Symbols palette.
    struct MacKeyboard: Equatable {
        var id: String
        var languages: [String]
        var name = ""
        var layout = false
    }

    static let emojiPalette = "com.apple.CharacterPaletteIM"

    /// The Mac's enabled keyboard layouts, input modes (an input method's ASCII-capable Roman mode left out: the Mac's
    /// layout stands for it) and Emoji & Symbols; with `ids` (`create --keyboards`), those installed sources instead.
    static func macKeyboards(_ ids: [String]? = nil) -> [MacKeyboard] {
        let filter = ids == nil ? [kTISPropertyInputSourceIsEnabled as String: true] as CFDictionary : nil
        guard let list = TISCreateInputSourceList(filter, ids != nil)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        func value<T>(_ s: TISInputSource, _ key: CFString) -> T? {
            TISGetInputSourceProperty(s, key).flatMap {
                Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as? T
            }
        }
        var found: [String: MacKeyboard] = [:]
        var order: [String] = []
        for s in list {
            guard let id: String = value(s, kTISPropertyInputSourceID),
                let type: String = value(s, kTISPropertyInputSourceType)
            else { continue }
            let layout = type == (kTISTypeKeyboardLayout as String)
            let mode =
                type == (kTISTypeKeyboardInputMode as String)
                || type == (kTISTypeKeyboardInputMethodWithoutModes as String)
            guard layout || (mode && value(s, kTISPropertyInputSourceIsASCIICapable) != true) || id == emojiPalette
            else { continue }
            if let ids, !ids.contains(id) { continue }
            found[id] = MacKeyboard(
                id: id,
                languages: value(s, kTISPropertyInputSourceLanguages) ?? [],
                name: value(s, kTISPropertyLocalizedName) ?? "",
                layout: layout
            )
            order.append(id)
        }
        return (ids ?? order).compactMap { found[$0] }
    }

    /// The keyboards a firmware has: each TextInput bundle's UIKeyboardSupportedInputModes ("fr_FR", "ja_JP-Kana",
    /// "emoji"), and, from 5.x on, UIKeyboardDefaultLanguageInputModes (a language or locale's keyboards).
    struct KeyboardCatalog {
        var modes: [String: [String: Any]] = [:]
        var defaults: [String: [String]] = [:]

        /// Read from the system volume's System/Library/TextInput; nil where it has none (1.x).
        init?(_ v: any VolumeFiles) {
            let textInput = "System/Library/TextInput"
            guard let bundles = try? v.contentsOfDirectory(at: textInput) else { return nil }
            for b in bundles.sorted() where b.hasPrefix("TextInput_") {
                guard let data = try? v.contents(at: "\(textInput)/\(b)/Info.plist"),
                    let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { continue }
                modes.merge(info["UIKeyboardSupportedInputModes"] as? [String: [String: Any]] ?? [:]) { a, _ in a }
                defaults.merge(info["UIKeyboardDefaultLanguageInputModes"] as? [String: [String]] ?? [:]) { a, _ in a }
            }
            if modes.isEmpty { return nil }
            // Variants of one keyboard (3.x's en_US-BigBear and en_US-Zephyr, both QWERTY) go by their mode's name.
            for (base, variants) in Dictionary(grouping: modes.keys.filter { $0.contains("-") }, by: Self.base)
            where modes[base] == nil {
                let layouts = Set(variants.map { Self.layoutClass(modes[$0]) })
                if layouts.count == 1, variants.count > 1, !layouts.contains("") {
                    modes[base] = modes[variants[0]]
                    for v in variants { modes[v] = nil }
                }
            }
        }

        init(modes: [String: [String: Any]], defaults: [String: [String]] = [:]) {
            self.modes = modes
            self.defaults = defaults
        }

        static func base(_ mode: String) -> String { String(mode.prefix { $0 != "-" && $0 != "@" }) }
        static func layoutClass(_ mode: [String: Any]?) -> String {
            (mode?["UIKeyboardLayoutClass"] as? [String: String])?["Portrait"] ?? ""
        }
        static func squash(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "") }
        /// "zh-Hans", "ja-Jpan": a language with its script, so zh_Hans and zh_TW part.
        static func script(_ language: String) -> String {
            let l = Locale.Language(identifier: Locale.Language(identifier: language).maximalIdentifier)
            return [l.languageCode?.identifier, l.script?.identifier].compactMap { $0 }.joined(separator: "-")
        }

        /// The mode as AppleKeyboards stores it: as the firmware's own defaults name it ("fr_FR", "ja_JP-Kana"), iOS
        /// picking its software layout, with the Mac's `hardware` layout where the mode lists it, from 5.x on
        /// ("fr_FR@hw=French", a form UIKit itself writes).
        func stored(_ mode: String, hardware: String?) -> String {
            let hw = (modes[mode]?["HWLayouts"] as? [String] ?? []).first {
                Self.squash($0) == hardware.map(Self.squash)
            }
            return hw.map { "\(mode)@hw=\($0)" } ?? mode
        }

        /// The firmware's keyboard for `language`: narrowed by the Mac layout `hardware` (7.x: fr_FR's French), a
        /// variant named in `hints` (KanaTyping: ja_JP-Kana), then `regions` in order, then name order.
        func mode(language: String, hardware: String? = nil, hints: [String] = [], regions: [String] = []) -> String? {
            let want = Self.script(language)
            var c = modes.keys.filter { $0 != "emoji" && Self.script(Self.base($0)) == want }.sorted()
            func narrow(_ keep: (String) -> Bool) { if c.contains(where: keep) { c = c.filter(keep) } }
            if let hardware {
                narrow {
                    ((modes[$0]?["Hardware"] as? [String: Any])?["Layout"] as? String).map(Self.squash)
                        == Self.squash(hardware)
                }
            }
            let tokens = hints.flatMap { $0.lowercased().split { !$0.isLetter && !$0.isNumber } }
            narrow { m in
                guard let v = m.split(separator: "-").dropFirst().first?.lowercased() else { return false }
                return tokens.contains { $0.hasPrefix(v) }
            }
            for r in regions { narrow { Locale(identifier: Self.base($0)).region?.identifier == r } }
            return c.first
        }

        /// AppleKeyboards: the iOS keyboards for the device's `language` and `locale` first (the firmware's defaults
        /// where it lists them, else its keyboard for the language and region), then the `mac` keyboards it has, each
        /// as the firmware's keyboard for its language (in the device's region where there is a choice).
        func keyboards(language: String, locale: String, mac: [MacKeyboard]) -> [String] {
            let region = Locale(identifier: locale).region?.identifier
            let device =
                defaults[locale] ?? defaults[language.replacingOccurrences(of: "-", with: "_")]
                ?? mode(language: language, regions: [region].compactMap { $0 } + likelyRegion(language)).map { [$0] }
                ?? []
            // The device's own as the firmware lists them; a Mac keyboard where its mode is not there yet, or with its
            // hardware layout in place of the bare mode.
            var out = device.filter { modes[String($0.prefix { $0 != "@" })] != nil }
            for k in mac {
                var m: String?
                var hardware: String?
                if k.id == emojiPalette {
                    m = modes["emoji"] == nil ? nil : "emoji"
                } else if let l = k.languages.first {
                    hardware = k.layout ? k.id.components(separatedBy: ".").last : nil
                    let regions = [region].compactMap { $0 } + likelyRegion(l)
                    m = mode(language: l, hardware: hardware, hints: [k.id, k.name], regions: regions)
                }
                guard let m else { continue }
                if let i = out.firstIndex(of: m) {
                    out[i] = stored(m, hardware: hardware)
                } else if !out.contains(where: { $0.prefix { $0 != "@" } == m }) {
                    out.append(stored(m, hardware: hardware))
                }
            }
            return out
        }

        func likelyRegion(_ language: String) -> [String] {
            [Locale.Language(identifier: Locale.Language(identifier: language).maximalIdentifier).region?.identifier]
                .compactMap { $0 }
        }
    }
}
