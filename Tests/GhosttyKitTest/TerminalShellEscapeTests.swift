@testable import GhosttyTerminal
import Testing

struct TerminalShellEscapeTests {
    @Test
    func `plain paths are untouched`() {
        #expect(TerminalShellEscape.escape("/tmp/ghostty-paste/image.png") == "/tmp/ghostty-paste/image.png")
    }

    @Test
    func `shell metacharacters are backslash escaped`() {
        #expect(TerminalShellEscape.escape("/Users/me/My File (1).png") == "/Users/me/My\\ File\\ \\(1\\).png")
        #expect(TerminalShellEscape.escape("a'b\"c$d`e") == "a\\'b\\\"c\\$d\\`e")
        #expect(TerminalShellEscape.escape("x\\y") == "x\\\\y")
    }

    @Test
    func `non-ascii text passes through`() {
        #expect(TerminalShellEscape.escape("/tmp/截图 1.png") == "/tmp/截图\\ 1.png")
    }
}
