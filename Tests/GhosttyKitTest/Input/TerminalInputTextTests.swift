import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

struct TerminalInputTextTests {
    @Test
    func `routes lone software return commits as semantic enter`() {
        #expect(
            TerminalSoftwareKeyCommitRouter.route(
                text: "\n",
                hasMarkedText: false,
                hardwareKeyHandled: false,
            ) == .semanticEnter,
        )
        #expect(
            TerminalSoftwareKeyCommitRouter.route(
                text: "\r",
                hasMarkedText: false,
                hardwareKeyHandled: false,
            ) == .semanticEnter,
        )
    }

    @Test
    func `keeps paste and marked text on text path`() {
        for text in ["a\n", "\n\n", "\r\n", "first\nsecond\n"] {
            #expect(
                TerminalSoftwareKeyCommitRouter.route(
                    text: text,
                    hasMarkedText: false,
                    hardwareKeyHandled: false,
                ) == .text,
            )
        }
        #expect(
            TerminalSoftwareKeyCommitRouter.route(
                text: "\n",
                hasMarkedText: true,
                hardwareKeyHandled: false,
            ) == .text,
        )
    }

    @Test
    func `hardware duplicate wins over software return classification`() {
        #expect(
            TerminalSoftwareKeyCommitRouter.route(
                text: "\n",
                hasMarkedText: false,
                hardwareKeyHandled: true,
            ) == .suppressHardwareDuplicate,
        )
    }

    @Test
    func `filters apple private use function keys from text path`() {
        #expect(TerminalInputText.filteredFunctionKeyText("\u{F702}") == nil)
        #expect(TerminalInputText.filteredFunctionKeyText("\u{F703}") == nil)
        #expect(TerminalInputText.filteredFunctionKeyText("UIKeyInputLeftArrow") == nil)
        #expect(TerminalInputText.filteredFunctionKeyText("UIKeyInputUpArrow") == nil)
        #expect(TerminalInputText.filteredFunctionKeyText("a") == "a")
        #expect(TerminalInputText.filteredFunctionKeyText("你好") == "你好")
    }

    @Test
    func `recognizes private use function key scalars`() {
        #expect(TerminalInputText.isPrivateUseFunctionKey("\u{F702}"))
        #expect(TerminalInputText.isPrivateUseFunctionKey("\u{F703}"))
        #expect(!TerminalInputText.isPrivateUseFunctionKey("a"))
        #expect(!TerminalInputText.isPrivateUseFunctionKey("你"))
    }

    @Test
    func `recognizes UI kit named function keys`() {
        #expect(TerminalInputText.isUIKitNamedFunctionKey("UIKeyInputLeftArrow"))
        #expect(TerminalInputText.isUIKitNamedFunctionKey("UIKeyInputDownArrow"))
        #expect(!TerminalInputText.isUIKitNamedFunctionKey("a"))
        #expect(!TerminalInputText.isUIKitNamedFunctionKey("你好"))
    }

    @Test
    func `counts paste lines for diagnostics only`() {
        #expect(TerminalInputText.lineCount(in: "") == 0)
        #expect(TerminalInputText.lineCount(in: "echo ok") == 0)
        #expect(TerminalInputText.lineCount(in: "line 1\nline 2\nline 3") == 2)
    }

    @Test
    func `key event text leaves control characters to the encoder`() {
        for text in ["\r", "\n", "\t", "\u{1B}", "\u{08}", "\u{7F}", "\u{00}"] {
            #expect(TerminalInputText.keyEventText(text) == nil)
        }
        #expect(TerminalInputText.keyEventText(nil) == nil)
        #expect(TerminalInputText.keyEventText("") == nil)
        #expect(TerminalInputText.keyEventText("a") == "a")
        #expect(TerminalInputText.keyEventText(" ") == " ")
        #expect(TerminalInputText.keyEventText("å") == "å")
        #expect(TerminalInputText.keyEventText("你好") == "你好")
    }
}

/// Shift+Return as the UIKit view builds it: Shift in the mods and marked
/// consumed (the view spends every modifier but Ctrl and Cmd on the text).
/// With `\r` as its text the kitty encoder dropped Shift and wrote `\r`,
/// so Claude Code submitted instead of inserting a newline.
@MainActor
struct TerminalHardwareReturnEncodingTests {
    private func shiftReturn(text: String?, on surface: TerminalSurface) {
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.keycode = TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: 0x28)
        event.mods = TerminalInputModifiers.shift.ghosttyMods
        event.consumed_mods = TerminalInputModifiers.shift.ghosttyMods
        guard let text = TerminalInputText.keyEventText(text) else {
            _ = surface.sendKeyEvent(event)
            return
        }
        text.withCString { pointer in
            event.text = pointer
            _ = surface.sendKeyEvent(event)
        }
    }

    @Test
    func `shift return keeps shift under the legacy encoding and kitty`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        guard let surface = harness.surface else { return }

        shiftReturn(text: "\r", on: surface)
        #expect(await harness.drain() == Data("\u{1B}[27;2;13~".utf8))

        harness.receive("\u{1B}[>1u")
        shiftReturn(text: "\r", on: surface)
        #expect(await harness.drain() == Data("\u{1B}[13;2u".utf8))
    }
}

#if canImport(UIKit)
    #if !targetEnvironment(macCatalyst)
        @MainActor
        struct TerminalSoftwareReturnStickyModifierTests {
            @Test
            func `armed control is consumed by software return`() {
                let state = TerminalStickyModifierState()
                state.toggle(.ctrl)

                #expect(state.ctrl == .armed)
                #expect(state.consumeForNextKey() == .ctrl)
                #expect(state.ctrl == .inactive)
            }

            @Test
            func `locked control remains locked after software return`() {
                let state = TerminalStickyModifierState()
                state.toggle(.ctrl)
                state.toggle(.ctrl)

                #expect(state.ctrl == .locked)
                #expect(state.consumeForNextKey() == .ctrl)
                #expect(state.ctrl == .locked)
            }
        }
    #endif
#endif
