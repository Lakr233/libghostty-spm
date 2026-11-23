//
//  TerminalSurface+SmoothScroll.swift
//  libghostty-spm
//

import GhosttyKit

/// Smooth scrolling (Patches/ghostty/0022). A surface opted in moves its
/// viewport by the pixel under a precision scroll, and the viewport can come
/// to rest between rows. Off by default in the engine: the platform views
/// turn it on for the surfaces they build and bring the viewport back to a
/// row (`TerminalSmoothScrollSettler`); a host that drives a surface of its
/// own keeps upstream's row-at-a-time scrolling.
///
/// The three functions are also the capability check between this package
/// and the binary: a libghostty without the patch has no such symbols, and
/// the package does not link against it.
extension TerminalSurface {
    func setSmoothScrolling(_ enabled: Bool) {
        guard let surface = rawValue else { return }
        TerminalDebugLog.log(.input, "surface smoothScrolling=\(enabled)")
        ghostty_surface_set_smooth_scroll(surface, enabled)
    }

    /// Where the viewport is now, read under the renderer lock. Nil with no
    /// surface or before it has a cell height.
    func smoothScrollPosition() -> TerminalSmoothScrollPosition? {
        guard let surface = rawValue else { return nil }
        var out = ghostty_surface_smooth_scroll_s()
        ghostty_surface_smooth_scroll(surface, &out)
        guard out.cell_height > 0 else { return nil }
        return TerminalSmoothScrollPosition(
            isAvailable: out.available,
            row: Int(out.row),
            maxRow: Int(out.max_row),
            fraction: out.fraction,
            cellHeight: Int(out.cell_height),
        )
    }

    /// Moves the viewport by `pixels`, positive toward the scrollback, as
    /// they are: no precision scroll multiplier, no report to the program,
    /// and nothing when a precision scroll would not move it by the pixel.
    /// What a view uses to bring the viewport to a row, and what UIKit's
    /// system scrolling uses to keep it under the finger.
    func smoothScroll(byPixels pixels: Double) {
        guard let surface = rawValue, pixels != 0 else { return }
        ghostty_surface_smooth_scroll_by(surface, pixels)
    }

    /// `smoothScroll(byPixels:)`, numbered (Patches/ghostty/0023), so
    /// `smoothScrollPresented()` can tell when a frame holding this step
    /// has been handed to the layer. What UIKit's system scrolling moves
    /// the viewport with, every frame.
    func smoothScrollTracked(byPixels pixels: Double) {
        guard let surface = rawValue, pixels != 0 else { return }
        ghostty_surface_smooth_scroll_by_tracked(surface, pixels)
    }

    /// Whether a frame holding the last `smoothScrollTracked(byPixels:)`
    /// has been handed to the layer: the renderer thread drew it and its
    /// present is queued on the main queue. Lock-free; ask on the thread
    /// that scrolls.
    func smoothScrollPresented() -> Bool {
        guard let surface = rawValue else { return true }
        return ghostty_surface_smooth_scroll_presented(surface)
    }
}
