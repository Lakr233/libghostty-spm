import Foundation
@testable import ShellCraftKit
import Testing

struct ShellCraftEngineRedrawTests {
    @Test
    func `emoji sequences take the width of one cluster`() {
        #expect("\u{2764}\u{FE0F}".terminalDisplayWidth == 2)
        #expect("\u{1F44D}\u{1F3FD}".terminalDisplayWidth == 2)
        #expect("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}".terminalDisplayWidth == 2)
        #expect("\u{1F1EF}\u{1F1F5}".terminalDisplayWidth == 2)
        #expect(
            terminalRenderedInputState(
                promptDisplayWidth: 2,
                input: "\u{1F44D}\u{1F3FD}ab",
                cursorPosition: 2,
                terminalColumns: 80,
            ).cursorColumn == 6,
        )
    }

    @Test
    func `prompt width skips OSC and short escape payloads`() {
        let prompts = [
            "\u{1B}]133;A\u{07}$ ",
            "\u{1B}]2;title\u{1B}\\$ ",
            "\u{1B}(B$ ",
            "\u{1B}]133;A\u{07}\u{1B}[1;32m$\u{1B}[0m ",
        ]
        for prompt in prompts {
            #expect(ShellDefinition(prompt: prompt, welcomeMessage: "") {}.promptDisplayWidth == 2)
        }
    }

    @Test
    func `a bare escape key does not swallow the next key`() async {
        let shell = await EngineHarness()
        await shell.start()

        await shell.feed([0x1B])
        await shell.feed("whoami\r")
        #expect(shell.drain().contains("tester"))

        await shell.feed("\u{1B}O")
        await shell.feed("whoami\r")
        #expect(shell.drain().contains("tester"))

        await shell.feed([0x1B])
        await shell.feed("\u{1B}[A")
        let recalled = shell.drain()
        #expect(recalled.contains("$ whoami"))
        #expect(!recalled.contains("[A"))
    }

    @Test
    func `meta keys sent in one write still edit`() async {
        let shell = await EngineHarness()
        await shell.start()
        await shell.feed("ab cd")
        _ = shell.drain()

        await shell.feed("\u{1B}b")
        #expect(shell.drain().hasSuffix("\u{1B}[6G"))
    }

    @Test
    func `a multi-line prompt redraws only its last line`() async {
        let shell = await EngineHarness(prompt: "a\r\n$ ")
        await shell.start()
        await shell.feed("xy")
        _ = shell.drain()

        await shell.feed([0x7F])
        #expect(shell.drain() == "\r\u{1B}[J$ x\u{1B}[4G")
        await shell.feed([0x7F])
        #expect(shell.drain() == "\r\u{1B}[J$ \u{1B}[3G")
    }

    @Test
    func `input taller than the screen redraws only the rows still on it`() async {
        let shell = await EngineHarness(columns: 10, rows: 5)
        await shell.start()
        let input = String(repeating: "a", count: 100)
        await shell.feed(input)
        _ = shell.drain()

        // 102 cells fill 11 rows; the top 6 are in scrollback, and the cursor
        // sits 4 rows below the top of the screen.
        let tail = String(repeating: "a", count: 42)
        await shell.feed("\u{1B}[D")
        #expect(shell.drain() == "\r\u{1B}[4A\r\u{1B}[J\(tail)\u{1B}[2G")
        await shell.feed("\u{1B}[D")
        #expect(shell.drain() == "\r\u{1B}[4A\r\u{1B}[J\(tail)\u{1B}[1G")

        await shell.feed([0x15])
        #expect(shell.drain() == "\r\u{1B}[4A\r\u{1B}[J$ \u{1B}[3G")
        await shell.feed("x")
        await shell.feed([0x7F])
        #expect(shell.drain() == "x\r\u{1B}[J$ \u{1B}[3G")
    }
}
