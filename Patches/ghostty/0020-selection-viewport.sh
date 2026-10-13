#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# =============================================================================
# Report where the user selection lies in the viewport
# =============================================================================
#
# ghostty_surface_read_selection locates the selection only as a linear
# offset (`row * cols + column`) counted in the terminal's own column count,
# which can differ from ghostty_surface_size's grid while a resize is still
# on its way to the terminal, and it does not say whether the selection is a
# rectangle. A host cannot turn that into cells, so it cannot tell whether a
# click landed on the selection (dragging the selected text out of the view).
#
# ghostty_surface_selection_viewport reads the selection's corners under the
# renderer lock, as viewport cells, together with the column and row count
# they are in, the rectangle flag, and which corner was clipped to the
# viewport. A clipped rectangle keeps its own column; a clipped linear
# selection runs to the viewport's first or last cell. It returns false when
# there is no selection or none of it is in view.
#
# Two additive edits, both exact anchors (Script/support/anchored_edit.py):
# the C declaration in include/ghostty.h and the export in
# src/apprt/embedded.zig.
# =============================================================================

PYTHONPATH="$(cd "$(dirname "$0")/../../Script/support" && pwd)" python3 - "$SOURCE_DIR" <<'PY'
import sys

from anchored_edit import Source

source_dir = sys.argv[1]

header = Source(source_dir, "include/ghostty.h")
header.insert_after(
    """  bool rectangle;
} ghostty_selection_s;
""",
    """
// libghostty-spm: ghostty_surface_selection_viewport
typedef struct {
  uint32_t top_left_x;
  uint32_t top_left_y;
  uint32_t bottom_right_x;
  uint32_t bottom_right_y;
  uint32_t columns;
  uint32_t rows;
  bool rectangle;
  bool top_left_clipped;
  bool bottom_right_clipped;
} ghostty_selection_viewport_s;
""",
)
header.insert_after(
    "GHOSTTY_API bool ghostty_surface_read_selection(ghostty_surface_t, ghostty_text_s*);\n",
    """GHOSTTY_API bool ghostty_surface_selection_viewport(ghostty_surface_t,
                                                   ghostty_selection_viewport_s*);
""",
)
header.save()

src = Source(source_dir, "src/apprt/embedded.zig")
src.insert_after(
    """                .rectangle = self.rectangle,
            };
        }
    };
""",
    """
    // ghostty_selection_viewport_s (libghostty-spm)
    const SelectionViewport = extern struct {
        top_left_x: u32,
        top_left_y: u32,
        bottom_right_x: u32,
        bottom_right_y: u32,
        columns: u32,
        rows: u32,
        rectangle: bool,
        top_left_clipped: bool,
        bottom_right_clipped: bool,
    };
""",
)
src.insert_before(
    """    /// Read some arbitrary text from the surface.
""",
    """    /// libghostty-spm: the user selection's corners as viewport cells, in
    /// the terminal's own column and row count. False when there is no
    /// selection or none of it is in the viewport.
    export fn ghostty_surface_selection_viewport(
        surface: *Surface,
        result: *SelectionViewport,
    ) bool {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());

        const screen = core_surface.io.terminal.screens.active;
        const sel = screen.selection orelse return false;
        const pages = &screen.pages;
        const vp_tl = pages.getTopLeft(.viewport);
        const vp_br = pages.getBottomRight(.viewport) orelse return false;
        const tl_pin = sel.topLeft(screen);
        const br_pin = sel.bottomRight(screen);
        if (br_pin.before(vp_tl) or vp_br.before(tl_pin)) return false;

        const cols: u32 = pages.cols;
        const rows: u32 = pages.rows;
        if (cols == 0 or rows == 0) return false;
        const last_col = cols - 1;

        // A corner above or below the viewport is clipped to its edge. A
        // rectangle keeps its column there; a linear selection runs to the
        // viewport's first or last cell.
        const tl_pt: ?terminal.point.Coordinate = if (pages.pointFromPin(.viewport, tl_pin)) |pt|
            if (pt.coord().y < rows) pt.coord() else null
        else
            null;
        const br_pt: ?terminal.point.Coordinate = if (pages.pointFromPin(.viewport, br_pin)) |pt|
            if (pt.coord().y < rows) pt.coord() else null
        else
            null;

        const tl_x: u32 = if (tl_pt) |pt| pt.x else if (sel.rectangle) tl_pin.x else 0;
        const br_x: u32 = if (br_pt) |pt| pt.x else if (sel.rectangle) br_pin.x else last_col;

        result.* = .{
            .top_left_x = @min(tl_x, last_col),
            .top_left_y = if (tl_pt) |pt| pt.y else 0,
            .bottom_right_x = @min(br_x, last_col),
            .bottom_right_y = if (br_pt) |pt| pt.y else rows - 1,
            .columns = cols,
            .rows = rows,
            .rectangle = sel.rectangle,
            .top_left_clipped = tl_pt == null,
            .bottom_right_clipped = br_pt == null,
        };
        return true;
    }

""",
)
src.save()
PY
