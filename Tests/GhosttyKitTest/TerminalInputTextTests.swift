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
    func countsPasteLinesForDiagnosticsOnly() {
        #expect(TerminalInputText.lineCount(in: "") == 0)
        #expect(TerminalInputText.lineCount(in: "echo ok") == 0)
        #expect(TerminalInputText.lineCount(in: "line 1\nline 2\nline 3") == 2)
    }

    @Test
    func routesMultilinePasteToDirectTextPath() {
        #expect(TerminalInputText.shouldSendPasteDirectly("line 1\nline 2"))

        let codexSizedPaste = Array(repeating: "explain this code", count: 68)
            .joined(separator: "\n")
        #expect(TerminalInputText.lineCount(in: codexSizedPaste) == 67)
        #expect(TerminalInputText.shouldSendPasteDirectly(codexSizedPaste))
    }

    @Test
    func routesLargeSingleLinePasteToDirectTextPath() {
        let text = String(repeating: "a", count: TerminalInputText.directPasteMinimumBytes)
        #expect(TerminalInputText.shouldSendPasteDirectly(text))
    }

    @Test
    func keepsSmallSingleLinePasteOnBindingPath() {
        #expect(!TerminalInputText.shouldSendPasteDirectly(""))
        #expect(!TerminalInputText.shouldSendPasteDirectly("echo ok"))
    }
}
