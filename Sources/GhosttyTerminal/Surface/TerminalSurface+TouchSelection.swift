//
//  TerminalSurface+TouchSelection.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

/// Text read from a range of cells, as Ghostty returns it
/// (`ghostty_surface_read_text`).
public struct TerminalCellText: Equatable, Sendable {
    /// The text in the range. Ghostty joins a soft-wrapped row to the next
    /// without a separator and puts `"\n"` between rows only at a hard line
    /// break; a wide character appears once, not once per cell. Empty cells
    /// at the end of a row are left out; spaces the program wrote are kept.
    public let text: String
    /// The left edge and the text baseline of the range's first cell in
    /// view, in view points from the surface's top-left corner, padding
    /// included (`tl_px_x`, `tl_px_y` of `ghostty_text_s`; Ghostty divides
    /// by the content scale). A range that starts above the viewport
    /// reports the viewport's first row. (-1, -1) when no part of the
    /// range is in view.
    public let firstBaseline: CGPoint
    /// `offset_start` of `ghostty_text_s`: where the range's first cell in
    /// view sits in the viewport read as one array, `row * columns +
    /// column` with rows counted from the top of the viewport and the
    /// terminal's own column count, which ``TerminalSurface/size()`` can lag
    /// while a resize is on its way. 0 when no part of the range is in
    /// view. Ghostty notes both offsets are off for a range only partly in
    /// view: treat them as informational.
    public let offsetStart: Int
    /// `offset_len` of `ghostty_text_s`: the offset of the range's last cell
    /// in view minus ``offsetStart``, one less than the number of cells.
    public let offsetLength: Int
}

public extension TerminalSurface {
    /// Reads an inclusive cell range without changing Ghostty's selection or
    /// mouse state and without sending input to the running program. A cell
    /// is `row * columns + column`; pass the column count the terminal wraps
    /// at, which ``size()`` can lag while a resize is on its way (the
    /// selection region carries the terminal's own). With `viewport` the
    /// rows count from the top of the visible screen, otherwise from the
    /// top of the scrollback. Ghostty handles soft wraps and wide
    /// characters, so a hard line break is the `"\n"` in
    /// ``TerminalCellText/text`` and a soft wrap is no separator.
    /// Returns nil for a negative range, a non-positive `columns`, a range
    /// Ghostty rejects, or a surface that is gone. A range below the grid is
    /// not rejected: it reads as empty text.
    func readCells(_ range: ClosedRange<Int>, columns: Int, viewport: Bool = false) -> TerminalCellText? {
        guard let surface = rawValue, columns > 0, range.lowerBound >= 0,
              range.upperBound / columns <= Int(UInt32.max)
        else { return nil }
        let tag = viewport ? GHOSTTY_POINT_VIEWPORT : GHOSTTY_POINT_SCREEN
        func point(_ cell: Int) -> ghostty_point_s {
            ghostty_point_s(
                tag: tag, coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(cell % columns), y: UInt32(cell / columns),
            )
        }
        let selection = ghostty_selection_s(
            top_left: point(range.lowerBound), bottom_right: point(range.upperBound), rectangle: false,
        )
        var result = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &result) else { return nil }
        defer { ghostty_surface_free_text(surface, &result) }
        let text = result.text.map {
            String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(result.text_len)), as: UTF8.self)
        } ?? ""
        return TerminalCellText(
            text: text,
            firstBaseline: CGPoint(x: result.tl_px_x, y: result.tl_px_y),
            offsetStart: Int(result.offset_start),
            offsetLength: Int(result.offset_len),
        )
    }
}

extension TerminalSurface {
    /// Expand either half of a wide glyph. Comparing the combined read also
    /// distinguishes a spacer cell from an adjacent identical character.
    func glyphCells(at cell: Int, columns: Int) -> ClosedRange<Int> {
        let text = readCells(cell ... cell, columns: columns)?.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return cell ... cell }
        if cell % columns > 0,
           readCells((cell - 1) ... (cell - 1), columns: columns)?.text == text,
           readCells((cell - 1) ... cell, columns: columns)?.text == text
        {
            return (cell - 1) ... cell
        }
        if cell % columns < columns - 1, !text.isEmpty, text != " ",
           readCells((cell + 1) ... (cell + 1), columns: columns)?.text == text,
           readCells(cell ... (cell + 1), columns: columns)?.text == text
        {
            return cell ... (cell + 1)
        }
        return cell ... cell
    }

    func lastTextCell(rows: Int, columns: Int) -> Int? {
        guard rows > 0, columns > 0 else { return nil }
        for row in (0 ..< rows).reversed() {
            let start = row * columns
            let end = start + columns - 1
            guard let text = readCells(start ... end, columns: columns)?.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            // A suffix stops containing text after the last occupied glyph.
            // Keep Ghostty's cell mapping, including wide-character spacers.
            var lower = start
            var upper = end
            while lower < upper {
                let middle = lower + (upper - lower + 1) / 2
                if let text = readCells(middle ... end, columns: columns)?.text,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    lower = middle
                } else {
                    upper = middle - 1
                }
            }
            return lower
        }
        return nil
    }

    /// The occupied text in one physical row, excluding surrounding whitespace.
    /// Read cell intervals so wide glyphs and combining characters stay intact.
    func textCells(inRow row: Int, columns: Int) -> ClosedRange<Int>? {
        guard row >= 0, columns > 0 else { return nil }
        let start = row * columns
        let end = start + columns - 1
        func hasText(_ range: ClosedRange<Int>) -> Bool {
            guard let text = readCells(range, columns: columns)?.text else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasText(start ... end) else { return nil }
        var lower = start
        var upper = end
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if hasText(start ... middle) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        let first = lower
        upper = end
        while lower < upper {
            let middle = lower + (upper - lower + 1) / 2
            if hasText(middle ... end) {
                lower = middle
            } else {
                upper = middle - 1
            }
        }
        return first ... lower
    }

    /// Find visible text nearest the touched row, preferring the row above on a tie.
    func nearestTextRow(to row: Int, in rows: Range<Int>, columns: Int) -> Int? {
        guard columns > 0, rows.contains(row) else { return nil }
        func hasText(at row: Int) -> Bool {
            let start = row * columns
            guard let text = readCells(start ... (start + columns - 1), columns: columns)?.text else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        for distance in 0 ..< rows.count {
            let above = row - distance
            if above >= rows.lowerBound, hasText(at: above) {
                return above
            }
            let below = row + distance
            if distance > 0, below < rows.upperBound, hasText(at: below) {
                return below
            }
        }
        return nil
    }

    func wordCells(at cell: Int, columns: Int) -> ClosedRange<Int> {
        let range = glyphCells(at: cell, columns: columns)
        func isWord(_ range: ClosedRange<Int>) -> Bool {
            guard let text = readCells(range, columns: columns)?.text, !text.isEmpty else { return false }
            return !text.contains { $0.isWhitespace || "\"'`|()[]{}<>".contains($0) }
        }
        guard isWord(range) else { return range }
        // Search each side within its physical row. Read intervals through
        // Ghostty so Unicode width, graphemes and spacers keep its cell mapping.
        // Checking the endpoint also detects whitespace trimmed from a read.
        let rowStart = cell / columns * columns
        var lower = rowStart
        var upper = range.lowerBound
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if isWord(middle ... range.upperBound), isWord(middle ... middle) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        let first = lower
        lower = range.upperBound
        upper = rowStart + columns - 1
        while lower < upper {
            let middle = lower + (upper - lower + 1) / 2
            if isWord(range.lowerBound ... middle), isWord(middle ... middle) {
                lower = middle
            } else {
                upper = middle - 1
            }
        }
        return first ... lower
    }
}
