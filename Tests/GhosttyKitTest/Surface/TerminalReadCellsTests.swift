import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// `readCells` read off a live surface: by cell range, in viewport or screen
/// coordinates, without touching the selection or the program's input.
@MainActor
struct TerminalReadCellsTests {
    private func columns(_ surface: TerminalSurface) throws -> Int {
        try Int(#require(surface.size()).columns)
    }

    @Test
    func `an exact range inside one row`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        let columns = try columns(surface)
        harness.receive("\u{1B}[2J\u{1B}[Hhello world")

        let read = try #require(surface.readCells(6 ... 10, columns: columns, viewport: true))
        #expect(read.text == "world")
        #expect(try #require(surface.readCells(0 ... 4, columns: columns, viewport: true)).text == "hello")
    }

    @Test
    func `a soft wrap has no separator and a hard break has a newline`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        // The harness never resizes the terminal to the view, so the width
        // rows wrap at is the selection region's, not `size()`'s.
        harness.receive("\u{1B}[2J\u{1B}[Hx")
        #expect(surface.performBindingAction("select_all"))
        let columns = try #require(surface.selectionRegion()).columns
        let long = String(repeating: "abcdefghij", count: columns / 10 + 2).prefix(columns + 5)
        harness.receive("\u{1B}[2J\u{1B}[H\(long)\r\nnext")

        // Row 0 wrapped into row 1; "next" starts row 2 after a hard break.
        let wrapped = try #require(surface.readCells(0 ... (2 * columns - 1), columns: columns, viewport: true))
        #expect(wrapped.text == String(long))
        let hard = try #require(surface.readCells(columns ... (2 * columns + 3), columns: columns, viewport: true))
        #expect(hard.text == String(long.suffix(5)) + "\nnext")
    }

    @Test
    func `wide, emoji and combining characters keep their cells`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        let columns = try columns(surface)
        // 日本 take cells 0-3, the emoji 4-5, "e" + U+0301 is one cell (6), "z" is 7.
        harness.receive("\u{1B}[2J\u{1B}[H日本😀e\u{301}z")

        #expect(try #require(surface.readCells(0 ... 3, columns: columns, viewport: true)).text == "日本")
        #expect(try #require(surface.readCells(1 ... 1, columns: columns, viewport: true)).text == "日")
        #expect(try #require(surface.readCells(4 ... 5, columns: columns, viewport: true)).text == "😀")
        #expect(try #require(surface.readCells(6 ... 6, columns: columns, viewport: true)).text == "e\u{301}")
        #expect(try #require(surface.readCells(0 ... 7, columns: columns, viewport: true)).text == "日本😀e\u{301}z")
    }

    @Test
    func `an invalid range or a dead surface reads nil, one below the grid reads no text`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        let columns = try columns(surface)
        harness.receive("hello")

        #expect(surface.readCells(-1 ... 3, columns: columns) == nil)
        #expect(surface.readCells(0 ... 3, columns: 0) == nil)
        #expect(surface.readCells(0 ... 3, columns: -4) == nil)
        #expect(surface.readCells(0 ... Int.max, columns: columns) == nil)
        // Below the grid Ghostty still answers, with no text.
        let rows = try Int(#require(surface.size()).rows)
        let below = (rows + 40) * columns
        #expect(surface.readCells(below ... below + 2, columns: columns, viewport: true)?.text == "")

        harness.coordinator.freeSurface()
        #expect(surface.readCells(0 ... 3, columns: columns) == nil)
    }

    @Test
    func `a read leaves the selection and the program's input alone`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        let columns = try columns(surface)
        harness.receive("\u{1B}[2J\u{1B}[Halpha beta gamma")
        #expect(surface.performBindingAction("select_all"))
        let selected = try #require(surface.readSelection())
        let region = try #require(surface.selectionRegion())
        _ = await harness.takeOutbound()

        let read = try #require(surface.readCells(6 ... 9, columns: columns, viewport: true))
        #expect(read.text == "beta")

        #expect(surface.readSelection() == selected)
        #expect(surface.selectionRegion() == region)
        #expect(await harness.takeOutbound().isEmpty)
    }

    @Test
    func `viewport and screen coordinates differ once there is scrollback`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        let columns = try columns(surface)
        let lines = (0 ..< 150).map { String(format: "row%03d", $0) }
        harness.receive("\u{1B}[2J\u{1B}[H" + lines.joined(separator: "\r\n"))

        // Screen row 0 is the first line ever written; viewport row 0 is
        // the top of what is visible, many lines later.
        #expect(try #require(surface.readCells(0 ... 5, columns: columns)).text == "row000")
        let top = try #require(surface.readCells(0 ... 5, columns: columns, viewport: true)).text
        #expect(top.hasPrefix("row"))
        #expect(top != "row000")

        // Scrolling the viewport moves viewport rows and leaves screen rows.
        #expect(surface.scrollToRow(0))
        #expect(try #require(surface.readCells(0 ... 5, columns: columns, viewport: true)).text == "row000")
        #expect(try #require(surface.readCells(0 ... 5, columns: columns)).text == "row000")
        #expect(try #require(surface.readCells(10 * columns ... 10 * columns + 5, columns: columns)).text == "row010")
    }
}
