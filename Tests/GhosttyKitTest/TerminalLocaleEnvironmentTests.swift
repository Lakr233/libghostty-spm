import Foundation
@testable import GhosttyTerminal
import Testing

struct TerminalLocaleEnvironmentTests {
    @Test
    func `lang and language follow upstream's setLangFromCocoa`() {
        let values = TerminalLocaleEnvironment.values(
            languageCode: "zh",
            countryCode: "HK",
            preferredLanguages: ["zh-Hans-HK", "en-HK", "ja-HK"],
        )
        #expect(values == .init(
            lang: "zh_HK.UTF-8",
            language: "zh_CN.UTF-8:en_HK.UTF-8:ja_HK.UTF-8",
        ))
    }

    @Test
    func `nothing is set without both codes`() {
        #expect(TerminalLocaleEnvironment.values(languageCode: "en", countryCode: nil, preferredLanguages: ["en"]) == nil)
        #expect(TerminalLocaleEnvironment.values(languageCode: nil, countryCode: "US", preferredLanguages: ["en"]) == nil)
    }

    @Test
    func `language is left unset when no language fits`() {
        #expect(TerminalLocaleEnvironment.values(languageCode: "en", countryCode: "US", preferredLanguages: [])
            == .init(lang: "en_US.UTF-8", language: nil))

        let long = String(repeating: "a", count: 300)
        #expect(TerminalLocaleEnvironment.values(languageCode: "en", countryCode: "US", preferredLanguages: [long, "fr-FR"])
            == .init(lang: "en_US.UTF-8", language: "fr_FR.UTF-8"))

        let many = Array(repeating: "sr-Latn-RS", count: 80)
        #expect(TerminalLocaleEnvironment.values(languageCode: "en", countryCode: "US", preferredLanguages: many)
            == .init(lang: "en_US.UTF-8", language: nil))
    }

    @Test
    func `an overlong lang sets nothing`() {
        let code = String(repeating: "x", count: 130)
        #expect(TerminalLocaleEnvironment.values(languageCode: code, countryCode: "US", preferredLanguages: ["en"]) == nil)
    }

    /// Through `exports`, not the process environment: swift-testing runs
    /// suites in parallel, and a `setenv` while another thread reads the
    /// environment crashes the test process.
    @Test
    func `nothing is exported while the host has set lang`() {
        let hongKong = Locale(identifier: "zh_HK")
        let preferred = ["zh-Hans-HK", "en-HK"]
        let expected = TerminalLocaleEnvironment.Values(
            lang: "zh_HK.UTF-8",
            language: "zh_CN.UTF-8:en_HK.UTF-8",
        )

        #expect(TerminalLocaleEnvironment.exports(currentLang: "fr_FR.UTF-8", locale: hongKong, preferredLanguages: preferred) == nil)
        #expect(TerminalLocaleEnvironment.exports(currentLang: "", locale: hongKong, preferredLanguages: preferred) == expected)
        #expect(TerminalLocaleEnvironment.exports(currentLang: nil, locale: hongKong, preferredLanguages: preferred) == expected)
        #expect(TerminalLocaleEnvironment.exports(currentLang: nil, locale: Locale(identifier: "en"), preferredLanguages: preferred) == nil)
    }
}
