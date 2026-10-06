@testable import GhosttyTerminal
import Testing

/// The Foundation-only half of font-size tracking: the action parser and
/// the model of Ghostty's own rules. The live-surface half is in
/// `TerminalFontSizeTrackingTests`.
@Suite("TerminalFontSize")
struct TerminalFontSizeTests {
    // MARK: - Binding actions

    @Test
    func `the four font-size actions parse`() {
        #expect(TerminalFontSizeAction(bindingAction: "increase_font_size:1") == .increase(1))
        #expect(TerminalFontSizeAction(bindingAction: "decrease_font_size:2.5") == .decrease(2.5))
        #expect(TerminalFontSizeAction(bindingAction: "set_font_size:14.5") == .set(14.5))
        #expect(TerminalFontSizeAction(bindingAction: "reset_font_size") == .reset)
    }

    @Test(arguments: [
        "",
        ":1",
        "copy_to_clipboard",
        "scroll_page_lines:-3",
        "increase_font_size",
        "increase_font_size:",
        "increase_font_size:big",
        "decrease_font_size:1:2",
        "set_font_size:nan",
        "reset_font_size:",
        "reset_font_size:1",
        "Reset_font_size",
        " reset_font_size",
    ])
    func `anything else is ignored`(action: String) {
        #expect(TerminalFontSizeAction(bindingAction: action) == nil)
    }

    // MARK: - Cmd keys

    @Test
    func `Cmd key characters map the way the default keybinds do`() {
        #expect(TerminalFontSizeAction(commandKeyCharacters: ["=", "="]) == .increase(1))
        #expect(TerminalFontSizeAction(commandKeyCharacters: ["+", "="]) == .increase(1))
        #expect(TerminalFontSizeAction(commandKeyCharacters: [nil, "+"]) == .increase(1))
        #expect(TerminalFontSizeAction(commandKeyCharacters: ["-", "-"]) == .decrease(1))
        #expect(TerminalFontSizeAction(commandKeyCharacters: ["_", "-"]) == .decrease(1))
        #expect(TerminalFontSizeAction(commandKeyCharacters: [nil, "0"]) == .reset)
        #expect(TerminalFontSizeAction(commandKeyCharacters: [")", "0"]) == .reset)
        #expect(TerminalFontSizeAction(commandKeyCharacters: ["k", "k"]) == nil)
        #expect(TerminalFontSizeAction(commandKeyCharacters: ["1", "1"]) == nil)
        #expect(TerminalFontSizeAction(commandKeyCharacters: [nil, nil]) == nil)
        #expect(TerminalFontSizeAction(commandKeyCharacters: ["==", "0="]) == nil)
    }

    // MARK: - Ghostty's rules

    @Test
    func `a new surface starts at the option or else the config`() {
        let configured = TerminalFontSize(configured: 13, option: nil)
        #expect(configured.points == 13)
        #expect(!configured.isAdjusted)

        let option = TerminalFontSize(configured: 13, option: 18)
        #expect(option.points == 18)
        #expect(option.isAdjusted)

        // 0 is the C config's "unset".
        #expect(TerminalFontSize(configured: 13, option: 0).points == 13)
        #expect(TerminalFontSize(configured: 13, option: 400).points == 255)
    }

    @Test
    func `steps move by their size and mark the size adjusted`() {
        var size = TerminalFontSize(configured: 13, option: nil)
        size.apply(.increase(1))
        #expect(size.points == 14)
        #expect(size.isAdjusted)
        size.apply(.increase(2.5))
        #expect(size.points == 16.5)
        size.apply(.decrease(3))
        #expect(size.points == 13.5)
    }

    @Test
    func `steps clamp at both ends`() {
        var size = TerminalFontSize(configured: 13, option: nil)
        size.apply(.decrease(20))
        #expect(size.points == 1)
        size.apply(.decrease(1))
        #expect(size.points == 1)

        size.apply(.increase(254.5))
        #expect(size.points == 255)
        size.apply(.increase(1))
        #expect(size.points == 255)
        // Ghostty caps the step itself at 255.
        size.apply(.decrease(1000))
        #expect(size.points == 1)
    }

    @Test
    func `a negative step changes nothing`() {
        var size = TerminalFontSize(configured: 13, option: nil)
        size.apply(.increase(-4))
        #expect(size.points == 13)
        size.apply(.decrease(-4))
        #expect(size.points == 13)
    }

    @Test
    func `set clamps its argument and reset returns to the config`() {
        var size = TerminalFontSize(configured: 13, option: 18)
        size.apply(.set(0.5))
        #expect(size.points == 1)
        size.apply(.set(300))
        #expect(size.points == 255)
        size.apply(.set(21.5))
        #expect(size.points == 21.5)

        size.apply(.reset)
        #expect(size.points == 13)
        #expect(!size.isAdjusted)
    }

    @Test
    func `a reload moves an unadjusted size and only retargets an adjusted one`() {
        var size = TerminalFontSize(configured: 13, option: nil)
        size.reloadConfiguration(configured: 16)
        #expect(size.points == 16)

        size.apply(.increase(1))
        size.reloadConfiguration(configured: 10)
        #expect(size.points == 17)
        #expect(size.configured == 10)

        size.apply(.reset)
        #expect(size.points == 10)
    }
}
