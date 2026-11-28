//
//  TerminalSurface+ScreenText.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

public extension TerminalSurface {
    /// Plain text of the screen (the scrollback plus the active area) from
    /// the start of `row` through the screen's last cell, without changing
    /// Ghostty's selection or mouse state and without sending input to the
    /// running program. Rows count from the oldest scrollback row, the units
    /// of `TerminalScrollbar.total`, so a host can read the last lines of a
    /// screen without knowing its column count. Ghostty joins a soft-wrapped
    /// row to the next without a separator and puts `"\n"` between rows only
    /// at a hard line break; there are no escape sequences. Returns nil for a
    /// negative row, a read Ghostty rejects, or a surface that is gone. A row
    /// below the screen is not rejected: it reads as empty text.
    func readScreenText(fromRow row: Int = 0) -> String? {
        guard let surface = rawValue, row >= 0, row <= Int(UInt32.max) else { return nil }
        let start = row == 0
            ? ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
            : ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row))
        let end = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        let selection = ghostty_selection_s(top_left: start, bottom_right: end, rectangle: false)
        var result = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &result) else { return nil }
        defer { ghostty_surface_free_text(surface, &result) }
        return result.text.map {
            String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(result.text_len)), as: UTF8.self)
        } ?? ""
    }
}
