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

    /// Xcode and SwiftPM's swiftbuild compile the catalog into `.lproj`
    /// tables; SwiftPM's native build system (the default before Swift
    /// 6.4) copies `Localizable.xcstrings` into the bundle as is.
    static func translation(of key: String, in language: String) throws -> String? {
        if let path = Bundle.module.path(forResource: language, ofType: "lproj") {
            let bundle = try #require(Bundle(path: path))
            let value = bundle.localizedString(forKey: key, value: "\u{0}", table: nil)
            return value == "\u{0}" ? nil : value
        }
        let url = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = catalog?["strings"] as? [String: Any]
        let entry = strings?[key] as? [String: Any]
        let localization = (entry?["localizations"] as? [String: Any])?[language] as? [String: Any]
        let unit = localization?["stringUnit"] as? [String: Any]
        guard unit?["state"] as? String == "translated" else { return nil }
        return unit?["value"] as? String
    }
}
