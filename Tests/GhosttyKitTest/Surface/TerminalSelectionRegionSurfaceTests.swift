import CoreGraphics
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// The selection's region read off a live surface: Ghostty's own selection,
/// made by mouse drags and binding actions, read back as viewport cells.
@MainActor
struct TerminalSelectionRegionSurfaceTests {
    /// The harness view is 800 × 500 points at scale 1.
    private static let scale: CGFloat = 1

    private func selectionGrid(_ surface: TerminalSurface) -> TerminalSelectionGrid? {
        guard let metrics = surface.size(),
              let first = surface.readCells(0 ... 0, columns: Int(metrics.columns), viewport: true)
        else { return nil }
        return TerminalSelectionGrid(
            metrics: metrics, scale: Self.scale,
            firstBaseline: first.firstBaseline, imeBottom: surface.imePoint().y,
        )
    }

    private func rect(_ grid: TerminalSelectionGrid, _ column: Int, _ row: Int) -> CGRect {
        grid.rect(for: row * grid.columns + column, viewportOffset: 0)
    }

    /// Press in the left quarter of the first cell and release in the right
    /// quarter of the last, so Ghostty's half-cell rule selects both.
    private func drag(
        _ surface: TerminalSurface, _ grid: TerminalSelectionGrid,
        from start: (Int, Int), to end: (Int, Int), modifiers: TerminalInputModifiers = [],
    ) {
        let from = rect(grid, start.0, start.1)
        let to = rect(grid, end.0, end.1)
        surface.sendMousePos(x: from.minX + from.width / 4, y: from.midY, modifiers: modifiers)
        surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, modifiers: modifiers)
        surface.sendMousePos(x: (from.midX + to.midX) / 2, y: (from.midY + to.midY) / 2, modifiers: modifiers)
        surface.sendMousePos(x: to.maxX - to.width / 4, y: to.midY, modifiers: modifiers)
        surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, modifiers: modifiers)
    }

    private func fill(_ harness: GhosttySurfaceHarness, lines: Int) {
        let text = (0 ..< lines).map { String(format: "line %03d abcdefghijklmnopqrstuvwxyz", $0) }
        harness.receive(text.joined(separator: "\r\n"))
    }

    @Test
    func `no selection has no region`() async {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        guard let surface = harness.surface else { return }
        fill(harness, lines: 3)
        #expect(surface.selectionRegion() == nil)
    }

    @Test
    func `a drag reports its corners as viewport cells`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        guard let surface = harness.surface else { return }
        fill(harness, lines: 6)
        let grid = try #require(selectionGrid(surface))

        drag(surface, grid, from: (9, 1), to: (12, 3))

        let region = try #require(surface.selectionRegion())
        #expect(region.topLeft == TerminalViewportCell(column: 9, row: 1))
        #expect(region.bottomRight == TerminalViewportCell(column: 12, row: 3))
        #expect(!region.isRectangle)
        #expect(!region.isClippedAtTop)
        #expect(!region.isClippedAtBottom)
        // The terminal's own grid, not `size()`'s: here the renderer has
        // 27 rows while the terminal, never resized to the view, keeps 33.
        // That gap is why the region carries the grid it counts in.
        #expect(region.columns > region.bottomRight.column)
        #expect(region.rows > region.bottomRight.row)
        #expect(surface.readSelection()?.hasPrefix("abcdefghijklmnopqrstuvwxyz") == true)
    }

    @Test
    func `an option drag on macOS is a rectangle`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        guard let surface = harness.surface else { return }
        fill(harness, lines: 6)
        let grid = try #require(selectionGrid(surface))

        drag(surface, grid, from: (12, 1), to: (16, 4), modifiers: .alt)

        let region = try #require(surface.selectionRegion())
        #expect(region.isRectangle)
        #expect(region.topLeft == TerminalViewportCell(column: 12, row: 1))
        #expect(region.bottomRight == TerminalViewportCell(column: 16, row: 4))
        #expect(region.contains(TerminalViewportCell(column: 14, row: 2)))
        #expect(!region.contains(TerminalViewportCell(column: 2, row: 2)))
        #expect(surface.readSelection() == "defgh\ndefgh\ndefgh\ndefgh")
    }

    @Test
    func `a press is on the selection only over a selected cell`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        guard let surface = harness.surface else { return }
        fill(harness, lines: 6)
        let grid = try #require(selectionGrid(surface))
        drag(surface, grid, from: (9, 1), to: (12, 3))

        func center(_ column: Int, _ row: Int) -> CGPoint {
            let cell = rect(grid, column, row)
            return CGPoint(x: cell.midX, y: cell.midY)
        }
        #expect(surface.viewportCell(at: center(20, 2), scale: Self.scale)
            == TerminalViewportCell(column: 20, row: 2))
        #expect(surface.selectionContains(center(9, 1), scale: Self.scale))
        #expect(surface.selectionContains(center(30, 1), scale: Self.scale))
        #expect(surface.selectionContains(center(0, 2), scale: Self.scale))
        #expect(surface.selectionContains(center(12, 3), scale: Self.scale))
        #expect(!surface.selectionContains(center(8, 1), scale: Self.scale))
        #expect(!surface.selectionContains(center(13, 3), scale: Self.scale))
        #expect(!surface.selectionContains(center(10, 5), scale: Self.scale))
    }

    @Test
    func `a selection that starts in scrollback is clipped at the top`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        guard let surface = harness.surface else { return }
        fill(harness, lines: 120)
        #expect(surface.performBindingAction("select_all"))

        let region = try #require(surface.selectionRegion())
        #expect(region.isClippedAtTop)
        #expect(region.topLeft == TerminalViewportCell(column: 0, row: 0))
        #expect(!region.isRectangle)
    }

    @Test
    func `a selection scrolled out of view has no region`() async throws {
        let harness = await GhosttySurfaceHarness.make()
        defer { harness.tearDown() }
        guard let surface = harness.surface else { return }
        fill(harness, lines: 120)
        let grid = try #require(selectionGrid(surface))
        drag(surface, grid, from: (0, grid.rows - 2), to: (5, grid.rows - 2))
        #expect(surface.selectionRegion() != nil)

        #expect(surface.scrollToRow(0))

        #expect(surface.hasSelection())
        #expect(surface.selectionRegion() == nil)
    }
}
