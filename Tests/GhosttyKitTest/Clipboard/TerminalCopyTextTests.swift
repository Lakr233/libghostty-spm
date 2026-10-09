import CoreGraphics
import Foundation
@testable import GhosttyTerminal
import Testing

@MainActor
struct TerminalCopyTextTests {
    @Test func `trims row padding and the gutter the selection started past`() {
        let text = "Reply with only this, no   \n  tools: The quick brown fox   \n  river bank.      "
        #expect(
            TerminalCopyText.clean(text, startColumn: 2)
                == "Reply with only this, no\ntools: The quick brown fox\nriver bank.",
        )
    }

    @Test func `keeps indentation relative to the selection start`() {
        let code = "def f():\n    return 1  \n"
        #expect(TerminalCopyText.clean(code, startColumn: 0) == "def f():\n    return 1\n")
        let nested = "if x:\n        y()\n    z()"
        #expect(TerminalCopyText.clean(nested, startColumn: 4) == "if x:\n    y()\nz()")
    }

    @Test func `leaves the first line's leading text and inner spaces alone`() {
        #expect(TerminalCopyText.clean("  a  b  ", startColumn: 8) == "  a  b")
        #expect(TerminalCopyText.clean("", startColumn: 3) == "")
    }

    @Test func `highlight rects cover only each row's text`() throws {
        let grid = try #require(
            TerminalSelectionGrid(
                metrics: .init(
                    columns: 10, rows: 5, widthPixels: 200, heightPixels: 200,
                    cellWidthPixels: 20, cellHeightPixels: 40,
                ),
                scale: 2, firstBaseline: CGPoint(x: 0, y: 14), imeBottom: 100,
            ),
        )
        let text: [Int: ClosedRange<Int>] = [0: 0 ... 5, 1: 12 ... 16]
        let rects = grid.rects(for: 2 ... 29, viewportOffset: 0) { text[$0] }
        #expect(rects == [
            CGRect(x: 20, y: 0, width: 40, height: 20),
            CGRect(x: 20, y: 20, width: 50, height: 20),
        ])
    }

    @Test func `a Claude Code paragraph copies without its padding`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        let columns = try Int(#require(surface.size()).columns)
        // Claude Code's own bytes: each row padded with spaces to paint its
        // background, the next reached by CR + cursor down, its gutter spaces.
        harness.receive(
            "\u{1B}[2J\u{1B}[H❯ Reply with only this, no   \r\u{1B}[1B  tools: The quick fox   \r\u{1B}[1B  river bank.        ",
        )
        let start = 2
        let row2 = try #require(surface.textCells(inRow: 2, columns: columns))
        let raw = try #require(surface.readCells(start ... row2.upperBound, columns: columns)?.text)
        #expect(raw.contains("no   \n  tools"))
        #expect(
            TerminalCopyText.clean(raw, startColumn: start)
                == "Reply with only this, no\ntools: The quick fox\nriver bank.",
        )
        #expect(surface.textCells(inRow: 1, columns: columns) == (columns + 2) ... (columns + 21))
    }
}
