//
//  TerminalSmoothScrollPosition.swift
//  libghostty-spm
//

/// Where the viewport is while a precision scroll moves it by the pixel:
/// its first row, and how many pixels of that row are scrolled off above
/// the top edge.
///
/// With `0022-pixel-smooth-scrolling.patch` the viewport can rest between
/// rows. The C API reports the row (the scrollbar, on a later tick) and
/// never the pixels, so a view that sends precision scrolls keeps this
/// copy and advances it the way Ghostty's `Surface.smoothScrollViewport`
/// advances the engine's. Every delta sent is a whole number of pixels, so
/// both sides do the same integer arithmetic and the copy cannot drift by
/// a fraction.
struct TerminalSmoothScrollPosition: Equatable {
    /// The cell height in pixels, the furthest row the viewport's first row
    /// can reach (the scrollback's length: 0 with none and on the alternate
    /// screen), and the rows on a screen.
    struct Extent: Equatable {
        let cellHeight: Int
        let maxRow: Int
        let screenRows: Int

        init(cellHeight: Int, maxRow: Int, screenRows: Int) {
            self.cellHeight = cellHeight
            self.maxRow = maxRow
            self.screenRows = screenRows
        }

        /// Nil until the surface has a cell height.
        init?(cellHeightPixels: UInt32, rows: UInt16, scrollbar: TerminalScrollbar?) {
            guard cellHeightPixels > 0 else { return nil }
            let maxRow = scrollbar.map { $0.total > $0.len ? Int($0.total - $0.len) : 0 } ?? 0
            self.init(cellHeight: Int(cellHeightPixels), maxRow: maxRow, screenRows: max(1, Int(rows)))
        }

        /// The bottom of the scrollback, in pixels from its top.
        var maxPixels: Int {
            maxRow * cellHeight
        }
    }

    /// 0 ..< cell height, and 0 at the top of the scrollback and on the
    /// active area, where Ghostty drops it.
    var row = 0
    var fraction = 0
    var isValid = false
    var isAtBottom = false

    /// Pixels from the top of the scrollback.
    func pixels(cellHeight: Int) -> Int {
        row * cellHeight + fraction
    }

    /// Brings the copy up to date with the engine before it is used.
    ///
    /// The scrollbar report for a scroll arrives a frame or so after the
    /// delta was sent, so while deltas keep going out the copy is trusted
    /// and the report is not: judged by the report, the top would be reached
    /// half a row early. `trustingReport` says the report is known to be
    /// later than the last delta sent; it then gives the row, since output,
    /// typing at the bottom and keyboard paging move the viewport too. A row
    /// that differs from the copy's was not reached by these deltas, and
    /// Ghostty ignores its fraction then, so the copy drops it as well.
    ///
    /// Following the active area while output arrives, the scrollback grows
    /// and the bottom moves down with it; a font size change can leave the
    /// fraction past the new cell height.
    mutating func sync(with bar: TerminalScrollbar?, in extent: Extent, trustingReport: Bool) {
        if let bar, extent.maxRow > 0 {
            if !isValid || trustingReport {
                if !isValid || Int(bar.offset) != row {
                    fraction = 0
                }
                row = Int(bar.offset)
                isAtBottom = bar.offset + bar.len >= bar.total
                isValid = true
            }
        } else {
            row = 0
            fraction = 0
            isAtBottom = true
            isValid = true
        }
        if isAtBottom || row >= extent.maxRow {
            row = extent.maxRow
            fraction = 0
            isAtBottom = true
        }
        fraction = min(max(0, fraction), extent.cellHeight - 1)
    }

    /// Ghostty's `smoothScrollViewport`, mirrored: `pixels` toward the
    /// scrollback, negative toward the active area. Past either end the
    /// engine stops at the edge and keeps no fraction.
    mutating func scroll(by pixels: Int, in extent: Extent) {
        guard pixels != 0 else { return }
        let limit = extent.maxPixels
        let position = min(max(0, self.pixels(cellHeight: extent.cellHeight) - pixels), limit)
        isAtBottom = position >= limit
        row = isAtBottom ? extent.maxRow : position / extent.cellHeight
        fraction = isAtBottom ? 0 : position % extent.cellHeight
    }

    /// The scroll, in pixels, that brings the viewport to the nearer whole
    /// row: the fraction itself back up to the row, or the rest of the row
    /// down to the next one. Half a row goes back.
    func pixelsToNearestRow(cellHeight: Int) -> Int {
        fraction * 2 <= cellHeight ? fraction : fraction - cellHeight
    }

    /// The scroll, in pixels, that brings the viewport to a whole row the
    /// way it was going: `travel` is the last delta sent, positive toward
    /// the scrollback. The fraction itself back up to the row when it was
    /// going toward the scrollback, the rest of the row down to the next
    /// one when it was going toward the active area — never back against
    /// the travel. With no travel, the nearer row.
    func pixelsToRow(following travel: Int, cellHeight: Int) -> Int {
        guard fraction != 0 else { return 0 }
        guard travel != 0 else { return pixelsToNearestRow(cellHeight: cellHeight) }
        return travel > 0 ? fraction : fraction - cellHeight
    }
}
