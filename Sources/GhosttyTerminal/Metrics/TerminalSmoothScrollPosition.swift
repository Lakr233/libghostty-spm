//
//  TerminalSmoothScrollPosition.swift
//  libghostty-spm
//

/// Where the viewport is while precision scrolls move it by the pixel: its
/// first row, and how many pixels of that row are scrolled off above the
/// top edge. Read from the engine under its renderer lock
/// (`ghostty_surface_smooth_scroll`, Patches/ghostty/0022), so it is never
/// a frame behind the way the scrollbar report is.
struct TerminalSmoothScrollPosition: Equatable {
    /// A precision scroll would move the viewport by the pixel right now:
    /// the surface opted in, the screen has scrollback, and neither mouse
    /// reporting nor alternate scroll takes the scroll. Ghostty decides,
    /// with `mouse-reporting` and the program's modes in hand.
    var isAvailable: Bool
    var row: Int
    /// The furthest row the viewport's first row can reach: the active
    /// area's.
    var maxRow: Int
    /// 0 ..< cell height; 0 at the top of the scrollback, on the active
    /// area, and once the viewport moved for any other reason.
    var fraction: Double
    var cellHeight: Int

    /// Pixels from the top of the scrollback.
    var pixels: Double {
        Double(row * cellHeight) + fraction
    }

    /// The scroll, in pixels toward the scrollback, that puts the top of
    /// the viewport `target` pixels from the top of the scrollback.
    ///
    /// Counted from the first row, never as `pixels - target`: the engine
    /// takes the scroll off its own fraction (a `Float`) and floors what is
    /// left into rows, so a scroll meant to land on a row must cancel the
    /// fraction exactly. Next to `row * cellHeight`, thousands of pixels
    /// down the scrollback, a fraction of a millionth of a pixel loses its
    /// low bits; a last step that came out a hair past it left the engine
    /// just under a whole row, which it then dropped, and the viewport
    /// ended a row past the row it was brought to.
    func pixels(to target: Int) -> Double {
        fraction + Double(row * cellHeight - target)
    }

    /// The bottom of the scrollback, in pixels from its top.
    var maxPixels: Int {
        maxRow * cellHeight
    }

    var isAtBottom: Bool {
        row >= maxRow
    }

    /// The scroll, in pixels toward the scrollback, that brings the
    /// viewport to the nearer whole row: the fraction itself back up to the
    /// row, or the rest of the row down to the next one. Half a row goes
    /// back.
    var pixelsToNearestRow: Double {
        fraction * 2 <= Double(cellHeight) ? fraction : fraction - Double(cellHeight)
    }

    /// The scroll that brings the viewport to a whole row the way it was
    /// going: `travel` is the last scroll sent, positive toward the
    /// scrollback. The fraction itself back up to the row when it was going
    /// toward the scrollback, the rest of the row down to the next one when
    /// it was going toward the active area — never back against the travel,
    /// or a string of flicks jumps back and forth. With no travel, the
    /// nearer row.
    func pixelsToRow(following travel: Double) -> Double {
        guard fraction != 0 else { return 0 }
        guard travel != 0 else { return pixelsToNearestRow }
        return travel > 0 ? fraction : fraction - Double(cellHeight)
    }
}
