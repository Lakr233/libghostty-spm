@testable import GhosttyTerminal
import Testing

/// `contains` follows Ghostty's `Selection.contains`, cell for cell.
struct TerminalSelectionRegionTests {
    private func region(
        _ top: (Int, Int), _ bottom: (Int, Int), rectangle: Bool = false,
    ) -> TerminalSelectionRegion {
        TerminalSelectionRegion(
            topLeft: TerminalViewportCell(column: top.0, row: top.1),
            bottomRight: TerminalViewportCell(column: bottom.0, row: bottom.1),
            columns: 20, rows: 10, isRectangle: rectangle,
        )
    }

    private func cell(_ column: Int, _ row: Int) -> TerminalViewportCell {
        TerminalViewportCell(column: column, row: row)
    }

    @Test
    func `a one-row selection covers its columns only`() {
        let selection = region((3, 2), (7, 2))
        #expect(selection.contains(cell(3, 2)))
        #expect(selection.contains(cell(7, 2)))
        #expect(!selection.contains(cell(2, 2)))
        #expect(!selection.contains(cell(8, 2)))
        #expect(!selection.contains(cell(5, 1)))
        #expect(!selection.contains(cell(5, 3)))
    }

    @Test
    func `a linear selection takes whole rows between its first and last`() {
        let selection = region((15, 1), (4, 4))
        #expect(selection.contains(cell(15, 1)))
        #expect(selection.contains(cell(19, 1)))
        #expect(!selection.contains(cell(14, 1)))
        #expect(selection.contains(cell(0, 2)))
        #expect(selection.contains(cell(19, 3)))
        #expect(selection.contains(cell(0, 4)))
        #expect(selection.contains(cell(4, 4)))
        #expect(!selection.contains(cell(5, 4)))
        #expect(!selection.contains(cell(0, 5)))
        #expect(!selection.contains(cell(19, 0)))
    }

    @Test
    func `a rectangle covers the same columns on every row`() {
        let selection = region((4, 1), (9, 4), rectangle: true)
        #expect(selection.contains(cell(4, 1)))
        #expect(selection.contains(cell(9, 4)))
        #expect(selection.contains(cell(6, 2)))
        #expect(!selection.contains(cell(3, 2)))
        #expect(!selection.contains(cell(10, 2)))
        #expect(!selection.contains(cell(15, 1)))
        #expect(!selection.contains(cell(0, 4)))
    }

    @Test
    func `a clipped linear selection runs to the viewport's edge`() {
        let selection = TerminalSelectionRegion(
            topLeft: cell(0, 0), bottomRight: cell(19, 9), columns: 20, rows: 10,
            isRectangle: false, isClippedAtTop: true, isClippedAtBottom: true,
        )
        #expect(selection.contains(cell(0, 0)))
        #expect(selection.contains(cell(19, 9)))
        #expect(selection.contains(cell(10, 5)))
    }
}
