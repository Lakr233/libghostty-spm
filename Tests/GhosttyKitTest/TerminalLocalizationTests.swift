import Foundation
@testable import GhosttyTerminal
import Testing

/// The selection menus read their titles from the module bundle; a key
/// missing a language falls back to English in that language's menu.
struct TerminalLocalizationTests {
    static let keys = ["Copy", "Paste", "Select", "Select All"]
    static let languages = [
        "ar", "bn", "de", "es", "fr", "hi", "id", "it", "ja", "ko",
        "pt-BR", "ru", "sw", "tr", "vi", "yo", "zh-Hans", "zh-Hant",
    ]

    @Test(arguments: languages)
    func `every menu title is translated`(language: String) throws {
        for key in Self.keys {
            let value = try Self.translation(of: key, in: language)
            #expect(value != nil && value != key, "\(language) lacks \(key)")
        }
    }

    /// The package ships compiled `.lproj` tables (see
    /// `Script/generate-localizations.sh`). SwiftPM's native build system
    /// lowercases their names (`zh-hans.lproj`), which Foundation's own
    /// language matching accepts, so the table is found the same way.
    static func translation(of key: String, in language: String) throws -> String? {
        let match = Bundle.preferredLocalizations(from: Bundle.module.localizations, forPreferences: [language])
        let localization = try #require(match.first { $0.caseInsensitiveCompare(language) == .orderedSame })
        let path = try #require(Bundle.module.path(forResource: localization, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let value = bundle.localizedString(forKey: key, value: "\u{0}", table: nil)
        return value == "\u{0}" ? nil : value
    }
}
