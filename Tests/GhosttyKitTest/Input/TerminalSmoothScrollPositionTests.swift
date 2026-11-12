@testable import GhosttyTerminal
import Testing

/// The copy of the viewport position a view keeps while a precision scroll
/// moves it by the pixel, checked against what the engine's
/// `smoothScrollViewport` does with the same deltas.
struct TerminalSmoothScrollPositionTests {
    /// 30 px rows, 100 rows of scrollback, 24 on a screen.
    private let extent = TerminalSmoothScrollPosition.Extent(cellHeight: 30, maxRow: 100, screenRows: 24)

    private func position(row: Int, fraction: Int = 0) -> TerminalSmoothScrollPosition {
        var position = TerminalSmoothScrollPosition()
        position.row = row
        position.fraction = fraction
        position.isValid = true
        return position
    }

    @Test
    func `scrolling back moves into the row above and keeps the rest as a fraction`() {
        var position = position(row: 50)
        position.scroll(by: 7, in: extent)
        #expect(position.row == 49)
        #expect(position.fraction == 23)
        position.scroll(by: 23, in: extent)
        #expect(position.row == 49)
        #expect(position.fraction == 0)
        position.scroll(by: -45, in: extent)
        #expect(position.row == 50)
        #expect(position.fraction == 15)
        #expect(!position.isAtBottom)
    }

    @Test
    func `the top of the scrollback stops the scroll and keeps no fraction`() {
        var position = position(row: 1, fraction: 10)
        position.scroll(by: 1000, in: extent)
        #expect(position == self.position(row: 0))
    }

    @Test
    func `the bottom of the scrollback is the active area`() {
        var position = position(row: 99, fraction: 20)
        position.scroll(by: -11, in: extent)
        #expect(position.row == 100)
        #expect(position.fraction == 0)
        #expect(position.isAtBottom)
        position.scroll(by: -500, in: extent)
        #expect(position.row == 100)
        #expect(position.isAtBottom)
    }

    @Test
    func `a zero delta changes nothing`() {
        var position = position(row: 40, fraction: 3)
        position.scroll(by: 0, in: extent)
        #expect(position == self.position(row: 40, fraction: 3))
    }

    @Test
    func `the nearer row is behind up to half a row and ahead past it`() {
        #expect(position(row: 5, fraction: 0).pixelsToNearestRow(cellHeight: 30) == 0)
        #expect(position(row: 5, fraction: 10).pixelsToNearestRow(cellHeight: 30) == 10)
        #expect(position(row: 5, fraction: 15).pixelsToNearestRow(cellHeight: 30) == 15)
        #expect(position(row: 5, fraction: 16).pixelsToNearestRow(cellHeight: 30) == -14)
        #expect(position(row: 5, fraction: 29).pixelsToNearestRow(cellHeight: 30) == -1)
    }

    @Test
    func `scrolling to the nearer row lands on it`() {
        for fraction in 0 ..< 30 {
            var position = position(row: 20, fraction: fraction)
            position.scroll(by: position.pixelsToNearestRow(cellHeight: 30), in: extent)
            #expect(position.fraction == 0)
            #expect(position.row == (fraction * 2 <= 30 ? 20 : 21))
        }
    }

    @Test
    func `following the travel goes on to the row ahead and never back`() {
        // Toward the scrollback: back up to the row the fraction belongs to.
        #expect(position(row: 5, fraction: 29).pixelsToRow(following: 40, cellHeight: 30) == 29)
        #expect(position(row: 5, fraction: 1).pixelsToRow(following: 1, cellHeight: 30) == 1)
        // Toward the active area: the rest of the row, down to the next one.
        #expect(position(row: 5, fraction: 1).pixelsToRow(following: -40, cellHeight: 30) == -29)
        #expect(position(row: 5, fraction: 29).pixelsToRow(following: -1, cellHeight: 30) == -1)
        // On a row already, and with no travel the nearer row.
        #expect(position(row: 5, fraction: 0).pixelsToRow(following: 40, cellHeight: 30) == 0)
        #expect(position(row: 5, fraction: 10).pixelsToRow(following: 0, cellHeight: 30) == 10)
        #expect(position(row: 5, fraction: 16).pixelsToRow(following: 0, cellHeight: 30) == -14)
        for fraction in 1 ..< 30 {
            var up = position(row: 20, fraction: fraction)
            up.scroll(by: up.pixelsToRow(following: 7, cellHeight: 30), in: extent)
            #expect(up == position(row: 20))
            var down = position(row: 20, fraction: fraction)
            down.scroll(by: down.pixelsToRow(following: -7, cellHeight: 30), in: extent)
            #expect(down == position(row: 21))
        }
    }

    @Test
    func `a first report gives the row and a report at the bottom follows it down`() {
        var position = TerminalSmoothScrollPosition()
        position.sync(with: TerminalScrollbar(total: 124, offset: 100, len: 24), in: extent, trustingReport: false)
        #expect(position.isValid)
        #expect(position.isAtBottom)
        #expect(position.row == 100)
        let grown = TerminalSmoothScrollPosition.Extent(cellHeight: 30, maxRow: 130, screenRows: 24)
        position.sync(with: TerminalScrollbar(total: 124, offset: 100, len: 24), in: grown, trustingReport: false)
        #expect(position.row == 130)
        #expect(position.fraction == 0)
    }

    @Test
    func `a report not known to be later than the last delta is ignored`() {
        var position = position(row: 50, fraction: 12)
        position.sync(with: TerminalScrollbar(total: 124, offset: 51, len: 24), in: extent, trustingReport: false)
        #expect(position == self.position(row: 50, fraction: 12))
    }

    @Test
    func `a later report keeps the fraction on the same row and drops it on another`() {
        var position = position(row: 50, fraction: 12)
        position.sync(with: TerminalScrollbar(total: 124, offset: 50, len: 24), in: extent, trustingReport: true)
        #expect(position == self.position(row: 50, fraction: 12))
        position.sync(with: TerminalScrollbar(total: 124, offset: 48, len: 24), in: extent, trustingReport: true)
        #expect(position == self.position(row: 48))
    }

    @Test
    func `a smaller cell height clamps the fraction inside the row`() {
        var position = position(row: 50, fraction: 25)
        let smaller = TerminalSmoothScrollPosition.Extent(cellHeight: 20, maxRow: 100, screenRows: 24)
        position.sync(with: TerminalScrollbar(total: 124, offset: 50, len: 24), in: smaller, trustingReport: false)
        #expect(position.fraction == 19)
    }

    @Test
    func `nothing to scroll back to is the bottom`() {
        let empty = TerminalSmoothScrollPosition.Extent(cellHeight: 30, maxRow: 0, screenRows: 24)
        var position = position(row: 7, fraction: 4)
        position.sync(with: TerminalScrollbar(total: 24, offset: 0, len: 24), in: empty, trustingReport: false)
        #expect(position.row == 0)
        #expect(position.fraction == 0)
        #expect(position.isAtBottom)
        var unreported = self.position(row: 7, fraction: 4)
        unreported.sync(with: nil, in: extent, trustingReport: false)
        #expect(unreported.row == 100)
        #expect(unreported.isAtBottom)
    }

    @Test
    func `the extent reads the scrollback length off the scrollbar`() throws {
        let extent = try #require(TerminalSmoothScrollPosition.Extent(
            cellHeightPixels: 34,
            rows: 24,
            scrollbar: TerminalScrollbar(total: 1024, offset: 3, len: 24),
        ))
        #expect(extent == TerminalSmoothScrollPosition.Extent(cellHeight: 34, maxRow: 1000, screenRows: 24))
        #expect(extent.maxPixels == 34000)
        #expect(TerminalSmoothScrollPosition.Extent(cellHeightPixels: 34, rows: 24, scrollbar: nil)?.maxRow == 0)
        #expect(TerminalSmoothScrollPosition.Extent(cellHeightPixels: 0, rows: 24, scrollbar: nil) == nil)
    }
}
