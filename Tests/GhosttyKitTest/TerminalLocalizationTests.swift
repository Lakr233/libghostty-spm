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
        let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        for key in Self.keys {
            let value = bundle.localizedString(forKey: key, value: "\u{0}", table: nil)
            #expect(value != "\u{0}" && value != key, "\(language) lacks \(key)")
        }
    }
}
