@testable import GhosttyTerminal
import Testing

struct TerminalInputTextTests {
    @Test
    func filtersApplePrivateUseFunctionKeysFromTextPath() {
        #expect(TerminalInputText.filteredFunctionKeyText("\u{F702}") == nil)
        #expect(TerminalInputText.filteredFunctionKeyText("\u{F703}") == nil)
        #expect(TerminalInputText.filteredFunctionKeyText("UIKeyInputLeftArrow") == nil)
        #expect(TerminalInputText.filteredFunctionKeyText("UIKeyInputUpArrow") == nil)
        #expect(TerminalInputText.filteredFunctionKeyText("a") == "a")
        #expect(TerminalInputText.filteredFunctionKeyText("你好") == "你好")
    }

    @Test
    func recognizesPrivateUseFunctionKeyScalars() {
        #expect(TerminalInputText.isPrivateUseFunctionKey("\u{F702}"))
        #expect(TerminalInputText.isPrivateUseFunctionKey("\u{F703}"))
        #expect(!TerminalInputText.isPrivateUseFunctionKey("a"))
        #expect(!TerminalInputText.isPrivateUseFunctionKey("你"))
    }

    @Test
    func recognizesUIKitNamedFunctionKeys() {
        #expect(TerminalInputText.isUIKitNamedFunctionKey("UIKeyInputLeftArrow"))
        #expect(TerminalInputText.isUIKitNamedFunctionKey("UIKeyInputDownArrow"))
        #expect(!TerminalInputText.isUIKitNamedFunctionKey("a"))
        #expect(!TerminalInputText.isUIKitNamedFunctionKey("你好"))
    }

    @Test
    func recognizesLargePasteByByteCount() {
        let text = String(repeating: "a", count: TerminalInputText.largePasteMinimumBytes)
        #expect(TerminalInputText.shouldSendPasteDirectly(text))
    }

    @Test
    func recognizesLargePasteByLineCount() {
        let text = Array(repeating: "echo ok", count: TerminalInputText.largePasteMinimumLineCount + 1)
            .joined(separator: "\n")
        #expect(TerminalInputText.shouldSendPasteDirectly(text))
    }

    @Test
    func keepsSmallPasteOnBindingPath() {
        #expect(!TerminalInputText.shouldSendPasteDirectly(""))
        #expect(!TerminalInputText.shouldSendPasteDirectly("echo ok"))
        #expect(!TerminalInputText.shouldSendPasteDirectly("line 1\nline 2"))
    }
}
