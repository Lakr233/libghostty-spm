@testable import GhosttyTerminal
import Testing

/// Every expectation here is what GNU libintl's canonicalization returned
/// for the tag, after upstream's `fixZhLocale`, read off the libintl that
/// libghostty linked through 2.2.2026101501.
struct TerminalLocaleNameTests {
    @Test(arguments: [
        ("en", "en"),
        ("en-US", "en_US"),
        ("en_US", "en_US"),
        ("en-HK", "en_HK"),
        ("ja-HK", "ja_HK"),
        ("pt-BR", "pt_BR"),
        ("es-419", "es_419"),
        ("ca-ES-valencia", "ca_ES_valencia"),
        ("en-US-POSIX", "en_US_POSIX"),
        ("ber-Latn", "ber_Latn"),
        ("ja-Jpan", "ja_Jpan"),
        ("en_US.UTF-8", "en_US.UTF_8"),
        ("", ""),
    ])
    func `other tags join their subtags with an underscore`(tag: String, name: String) {
        #expect(TerminalLocaleName.posix(tag) == name)
    }

    @Test(arguments: [
        ("zh-Hans", "zh_CN"),
        ("zh-Hant", "zh_TW"),
        ("zh-Hans-CN", "zh_CN"),
        ("zh-Hans-HK", "zh_CN"),
        ("zh-Hans-SG", "zh_SG"),
        ("zh-Hant-TW", "zh_TW"),
        ("zh-Hant-HK", "zh_HK"),
        ("zh-Hant-MO", "zh_MO"),
        ("zh-Hant-CN", "zh_TW"),
        ("zh-Hans-", "zh_CN"),
        ("zh-HK", "zh_HK"),
        ("zh-Latn-CN", "zh_Latn_CN"),
        ("yue-Hant-HK", "yue_Hant_HK"),
    ])
    func `chinese tags name the region gettext catalogs use`(tag: String, name: String) {
        #expect(TerminalLocaleName.posix(tag) == name)
    }

    @Test(arguments: [
        ("sr-Latn", "sr@latin"),
        ("uz-Cyrl", "uz@cyrillic"),
        ("az-Arab", "az@arabic"),
        ("mn-Mong", "mn@mongolian"),
        ("en-Latn", "en@latin"),
        ("sr-Cyrl", "sr"),
        ("uz-Latn", "uz"),
        ("kk-Cyrl", "kk"),
        ("ga-dots", "ga"),
        ("pa-Arab", "pa_PK"),
        ("pa-Guru", "pa_IN"),
        ("sr-Latn-RS", "sr_Latn_RS"),
        ("yue-Hans", "yue_Hans"),
        ("ber-Arab", "ber_Arab"),
        ("sr-latn", "sr_latn"),
        ("--Latn", "__Latn"),
        ("---Latn", "--@latin"),
    ])
    func `only a seven-byte language and script tag takes a modifier`(tag: String, name: String) {
        #expect(TerminalLocaleName.posix(tag) == name)
    }

    @Test(arguments: [
        ("English", "en"),
        ("Japanese", "ja"),
        ("Chinese, Simplified", "zh_CN"),
        ("Traditional Chinese", "zh_TW"),
        ("Brazilian Portugese", "pt_BR"),
        ("Flemish", "nl_BE"),
        ("Sami", "se_NO"),
        ("Hawaiian", "haw"),
        ("english", "english"),
        ("English-US", "English_US"),
        ("Klingon", "Klingon"),
    ])
    func `legacy language names match whole and case-sensitively`(tag: String, name: String) {
        #expect(TerminalLocaleName.posix(tag) == name)
    }

    /// libintl compares bytes. Swift compares strings by canonical
    /// equivalence, under which U+212A KELVIN SIGN equals K.
    @Test
    func `tables match bytes, not canonically equivalent strings`() {
        #expect(Array(TerminalLocaleName.posix("\u{212A}azakh").utf8) == Array("\u{212A}azakh".utf8))
        #expect(TerminalLocaleName.posix("zh-Hant-H\u{212A}") == "zh_TW")
        #expect(Array(TerminalLocaleName.posix("sr-La\u{0301}tn").utf8) == Array("sr_La\u{0301}tn".utf8))
    }

    @Test
    func `every table entry is reachable`() {
        for (tag, name) in TerminalLocaleName.legacyNames {
            #expect(TerminalLocaleName.posix(tag) == name, "\(tag)")
        }
        for (tag, name) in TerminalLocaleName.scriptTagNames {
            #expect(tag.utf8.count == 7, "\(tag)")
            #expect(TerminalLocaleName.posix(tag) == name, "\(tag)")
        }
    }
}
