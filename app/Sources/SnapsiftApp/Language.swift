import Foundation
import SnapsiftCore

/// Languages snapsift speaks. Adding a case forces every message in ``L10n`` to
/// be translated (the switches there are exhaustive), so the UI can never ship
/// half-localized.
enum Language: String, CaseIterable, Identifiable, Sendable {
    case en = "en-US"
    case ja = "ja-JP"
    case zhTW = "zh-TW"   // 台灣華語 / Taiwan Mandarin

    var id: String { rawValue }

    /// Locale for formatting dates/numbers in the active language, so composite
    /// strings don't mix the system locale's conventions into the chosen
    /// language. The raw values are already full locale codes.
    var locale: Locale { Locale(identifier: rawValue) }

    /// The language's own name, for the menu.
    var endonym: String {
        switch self {
        case .en:   return "English"
        case .ja:   return "日本語"
        case .zhTW: return "繁體中文"
        }
    }

    /// Parse a BCP-47 / POSIX-ish tag. Any Chinese tag maps to Traditional —
    /// the only Chinese snapsift ships, by design.
    static func parse(_ raw: String) -> Language? {
        let s = raw.replacingOccurrences(of: "_", with: "-").lowercased()
        if s.hasPrefix("zh") { return .zhTW }
        if s.hasPrefix("ja") { return .ja }
        if s.hasPrefix("en") { return .en }
        return nil
    }

    /// Resolve the active language from the user's PREFERRED LANGUAGES, in
    /// their order, defaulting to English.
    ///
    /// Not `Locale.current`: on macOS that follows the FORMAT REGION, not the
    /// language. A Japanese-speaking user with region United States opened an
    /// English app; a Taiwanese user working in Japan opened a Japanese one —
    /// the first thing a paid app shows, in the wrong language, with the fix
    /// hidden behind a globe menu they must first be able to read.
    /// `Locale.preferredLanguages` is System Settings' own ordered list, so the
    /// second preference wins when the first isn't one of our three.
    static func detect(preferredLanguages: [String] = Locale.preferredLanguages) -> Language {
        guard let tag = preferredLanguageTag(from: preferredLanguages,
                                             supported: { parse($0) != nil })
        else { return .en }
        return parse(tag) ?? .en
    }
}
