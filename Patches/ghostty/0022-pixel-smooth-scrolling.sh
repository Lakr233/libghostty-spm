#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# =============================================================================
# Smooth scrolling: a precision scroll moves the picture by the pixel
# =============================================================================
#
# Upstream's Surface.scrollCallback collects the pixels of a precision scroll
# and moves the viewport once a whole row has come in, so content under a
# finger or a trackpad jumps a row at a time. On a surface that opted in
# (ghostty_surface_set_smooth_scroll; off by default, so every other host
# keeps upstream's behaviour) the viewport still moves by whole rows and the
# remainder becomes a fraction in [0, cell height)
# (renderer.State.scroll_frac): the renderer draws the grid that many pixels
# higher and captures one overscan row below the viewport
# (RenderState.overscan_request, upstream) to fill the bottom edge.
#
# The fraction is stored with what the viewport was when it was set: the
# active screen, the scrollbar offset, the page list's count of viewport
# moves (PageList.viewport_moves, which every PageList.scroll bumps), the
# cell height and the grid size. Any other viewport move -- a keybinding,
# output scrolling to the bottom, a resize, a font size change, a switch of
# screens -- changes one of them, and the fraction is then cleared on its
# next read. The move count is what keeps page up then page down from
# bringing an old fraction back at the same offset.
#
# Only a precision scroll of a screen with scrollback and no mouse reporting
# takes this path; wheel notches, mouse reporting and alternate scroll are
# unchanged, and the fraction is zero at the top of the scrollback and on
# the active area.
#
# C API (include/ghostty.h, apprt/embedded.zig):
#   ghostty_surface_set_smooth_scroll(surface, bool) -- the opt-in
#   ghostty_surface_smooth_scroll(surface, *state)   -- where the viewport
#     is, read under the renderer lock: first row, last reachable row,
#     the fraction in pixels, the cell height, and whether a precision
#     scroll would move it by the pixel right now
#   ghostty_surface_smooth_scroll_by(surface, up_px) -- move it by raw
#     pixels (positive toward the scrollback), without the precision
#     scroll multiplier: what a view uses to bring it back to a row
#
# The renderer gets a `content_offset` uniform applied to cell backgrounds,
# glyphs (decorations, cursor and selection are glyph instances) and Kitty
# images, and a `viewport_rows` uniform in the padding after `grid_size`;
# while the offset is not zero, text and images are discarded outside the
# viewport and the background keeps its unshifted padding mapping. With no
# offset every path is what it was. The OpenGL shaders get the offset but
# no clipping, and are neither built nor tested here.
#
# Every edit is an exact anchor (Script/support/anchored_edit.py). Several
# anchors sit in text 0010 and 0015 leave as upstream wrote it; the
# renderer edits run after 0015's in generic.zig.
# =============================================================================

PYTHONPATH="$(cd "$(dirname "$0")/../../Script/support" && pwd)" python3 - "$SOURCE_DIR" <<'PY'
import sys

from anchored_edit import Source

source_dir = sys.argv[1]

# --- PageList: count viewport moves -----------------------------------------

pages = Source(source_dir, "src/terminal/PageList.zig")
pages.insert_after(
    "viewport_pin_row_offset: ?usize,\n",
    """
/// libghostty-spm smooth scrolling: bumped by every `scroll`, so a sub-row
/// offset kept for one viewport position can tell that the viewport has
/// been moved since, even back to the same row.
viewport_moves: u64 = 0,
""",
)
pages.replace(
    """pub fn scroll(self: *PageList, behavior: Scroll) void {
    defer self.assertIntegrity();
""",
    """pub fn scroll(self: *PageList, behavior: Scroll) void {
    defer self.assertIntegrity();
    self.viewport_moves +%= 1;
""",
)
pages.save()

# --- renderer.State: the fraction and what it belongs to --------------------

state = Source(source_dir, "src/renderer/State.zig")
state.insert_after(
    "mouse: Mouse = .{},\n",
    """
/// Smooth scrolling (libghostty-spm): how far, in pixels, the viewport is
/// scrolled past the top of its first row. Written by the surface with the
/// mutex held; read through `ScrollFraction.current`, which clears it once
/// the viewport has moved for any other reason.
scroll_frac: ScrollFraction = .{},
""",
)
state.insert_before(
    "pub const Mouse = struct {\n",
    """/// A sub-row viewport offset and the viewport it was set for.
pub const ScrollFraction = struct {
    px: f32 = 0,
    key: Key = .{},

    pub const Key = struct {
        screen: terminalpkg.ScreenSet.Key = .primary,
        offset: usize = 0,
        viewport_moves: u64 = 0,
        cell_height: u32 = 0,
        rows: terminalpkg.size.CellCountInt = 0,
        cols: terminalpkg.size.CellCountInt = 0,

        /// The viewport as it is now. `offset` is the active screen's
        /// scrollbar offset, which the caller usually has at hand.
        pub fn of(
            t: *const terminalpkg.Terminal,
            offset: usize,
            cell_height: u32,
        ) Key {
            return .{
                .screen = t.screens.active_key,
                .offset = offset,
                .viewport_moves = t.screens.active.pages.viewport_moves,
                .cell_height = cell_height,
                .rows = t.rows,
                .cols = t.cols,
            };
        }
    };

    /// The fraction while the viewport is still where it was left, else
    /// zero; a stale fraction is cleared, so it cannot come back.
    pub fn current(self: *ScrollFraction, key: Key) f32 {
        if (self.px > 0 and
            self.px < @as(f32, @floatFromInt(key.cell_height)) and
            std.meta.eql(self.key, key)) return self.px;
        self.* = .{};
        return 0;
    }
};

""",
)
state.save()

# --- Surface: opt-in, the precision path, the API's core --------------------

surface = Source(source_dir, "src/Surface.zig")
surface.insert_after(
    "selection_scroll_active: bool = false,\n",
    """
/// libghostty-spm smooth scrolling: precision scrolls move the viewport by
/// the pixel (`smoothScrollViewport`). Off unless the host opts in.
smooth_scroll: bool = false,
""",
)
surface.replace(
    """        if (y.delta != 0) {
            // Modify our viewport, this requires a lock since it affects
""",
    """        if (self.smooth_scroll and scroll_mods.precision and yoff != 0) {
            // Precision scrolls move the viewport by the pixel: the whole
            // amount (the rows above plus what stayed pending) goes to
            // smoothScrollViewport, which keeps the remainder itself.
            const cell_h: f64 = @floatFromInt(self.size.cell.height);
            const up_px = @as(f64, @floatFromInt(y.delta)) * cell_h +
                self.mouse.pending_scroll_y;
            self.mouse.pending_scroll_y = 0;
            self.smoothScrollViewport(up_px);
        } else if (y.delta != 0) {
            // Modify our viewport, this requires a lock since it affects
""",
)
surface.insert_before(
    """/// This is called when the content scale of the surface changes. The surface
""",
    """/// Smooth scrolling (libghostty-spm): where the viewport is, for
/// ghostty_surface_smooth_scroll.
pub const SmoothScroll = struct {
    /// A precision scroll would move the viewport by the pixel now: the
    /// surface opted in, the screen has scrollback, and neither mouse
    /// reporting nor alternate scroll takes the scroll.
    available: bool = false,
    row: usize = 0,
    max_row: usize = 0,
    fraction: f64 = 0,
    cell_height: u32 = 0,
};

/// Turns smooth scrolling on or off for this surface. Off drops any
/// fraction, so the viewport is back on a row.
pub fn setSmoothScroll(self: *Surface, enabled: bool) void {
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        self.smooth_scroll = enabled;
        if (!enabled) self.renderer_state.scroll_frac = .{};
    }
    self.queueRender() catch {};
}

pub fn smoothScrollState(self: *Surface) SmoothScroll {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    const bar = self.io.terminal.screens.active.pages.scrollbar();
    const cell_h = self.size.cell.height;
    const key: rendererpkg.State.ScrollFraction.Key = .of(&self.io.terminal, bar.offset, cell_h);
    return .{
        .available = self.smoothScrollAvailable(bar),
        .row = bar.offset,
        .max_row = bar.total -| bar.len,
        .fraction = self.renderer_state.scroll_frac.current(key),
        .cell_height = cell_h,
    };
}

/// Scrolls by raw pixels, positive toward the scrollback, with no scroll
/// multiplier: a view bringing the viewport back to a row. Does nothing
/// when a precision scroll would not move the viewport by the pixel.
pub fn smoothScrollBy(self: *Surface, up_px: f64) void {
    if (up_px == 0) return;
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        const bar = self.io.terminal.screens.active.pages.scrollbar();
        if (!self.smoothScrollAvailable(bar)) return;
        self.mouse.pending_scroll_y = 0;
        self.smoothScrollViewport(up_px);
    }
    self.queueRender() catch {};
}

/// Precondition: the renderer_state mutex must be held.
fn smoothScrollAvailable(self: *Surface, bar: terminal.Scrollbar) bool {
    if (!self.smooth_scroll) return false;
    if (bar.total <= bar.len) return false;
    if (self.isMouseReporting()) return false;
    const t = &self.io.terminal;
    if (t.screens.active_key == .alternate and
        t.flags.mouse_event == .none and
        t.modes.get(.mouse_alternate_scroll)) return false;
    return true;
}

/// Smooth scrolling (libghostty-spm). Scrolls the viewport by `up_px`
/// pixels toward the scrollback (negative: toward the active area): whole
/// rows move the viewport, the rest becomes `renderer_state.scroll_frac`,
/// how far the grid is drawn above the viewport's first row. The fraction
/// is always in [0, cell height) and is dropped (zero) where there is
/// nothing to show past it: at the top of the scrollback and when the
/// viewport reaches the active area.
///
/// Precondition: the renderer_state mutex must be held.
fn smoothScrollViewport(self: *Surface, up_px: f64) void {
    const cell_height = self.size.cell.height;
    const cell_h: f64 = @floatFromInt(cell_height);
    if (cell_h <= 0) return;

    const t = &self.io.terminal;
    const pages = &t.screens.active.pages;
    const before = pages.scrollbar();
    const frac: f64 = self.renderer_state.scroll_frac.current(
        .of(t, before.offset, cell_height),
    );

    // Pixels from the top of the current first row down to the new top.
    const target = frac - up_px;
    const rows = @floor(target / cell_h);
    var new_frac = target - rows * cell_h;
    const delta: isize = @intFromFloat(rows);
    if (delta != 0) t.scrollViewport(.{ .delta = delta });

    const after = pages.scrollbar();
    const moved = @as(isize, @intCast(after.offset)) - @as(isize, @intCast(before.offset));
    if (moved != delta or after.offset + after.len >= after.total) new_frac = 0;

    self.renderer_state.scroll_frac = .{
        .px = @floatCast(new_frac),
        .key = .of(t, after.offset, cell_height),
    };
}

""",
)
surface.save()

# --- C API -----------------------------------------------------------------

header = Source(source_dir, "include/ghostty.h")
header.insert_after(
    """GHOSTTY_API void ghostty_surface_mouse_pressure(ghostty_surface_t, uint32_t, double);
""",
    """// libghostty-spm: smooth scrolling (Patches/ghostty/0022)
typedef struct {
  bool available;
  uint64_t row;
  uint64_t max_row;
  double fraction;
  uint32_t cell_height;
} ghostty_surface_smooth_scroll_s;
GHOSTTY_API void ghostty_surface_set_smooth_scroll(ghostty_surface_t, bool);
GHOSTTY_API void ghostty_surface_smooth_scroll(ghostty_surface_t,
                                               ghostty_surface_smooth_scroll_s*);
GHOSTTY_API void ghostty_surface_smooth_scroll_by(ghostty_surface_t, double);
""",
)
header.save()

embedded = Source(source_dir, "src/apprt/embedded.zig")
embedded.insert_before(
    """    export fn ghostty_surface_mouse_pressure(
""",
    """    // ghostty_surface_smooth_scroll_s (libghostty-spm)
    const SmoothScroll = extern struct {
        available: bool,
        row: u64,
        max_row: u64,
        fraction: f64,
        cell_height: u32,
    };

    /// libghostty-spm: precision scrolls move the viewport by the pixel
    /// on this surface. Off by default.
    export fn ghostty_surface_set_smooth_scroll(surface: *Surface, enabled: bool) void {
        surface.core_surface.setSmoothScroll(enabled);
    }

    /// libghostty-spm: where the viewport is, read under the renderer lock.
    export fn ghostty_surface_smooth_scroll(surface: *Surface, result: *SmoothScroll) void {
        const v = surface.core_surface.smoothScrollState();
        result.* = .{
            .available = v.available,
            .row = v.row,
            .max_row = v.max_row,
            .fraction = v.fraction,
            .cell_height = v.cell_height,
        };
    }

    /// libghostty-spm: scroll by raw pixels, positive toward the scrollback,
    /// without the precision scroll multiplier.
    export fn ghostty_surface_smooth_scroll_by(surface: *Surface, up_px: f64) void {
        surface.core_surface.smoothScrollBy(up_px);
    }

""",
)
embedded.save()

# --- Renderer ---------------------------------------------------------------

generic = Source(source_dir, "src/renderer/generic.zig")
generic.insert_after(
    "                overlay_features: []const Overlay.Feature,\n",
    "                scroll_frac_px: f32,\n",
)
scrollbar_read = """                // Get our scrollbar out of the terminal. We synchronize
                // the scrollbar read with frame data updates because this
                // naturally limits the number of calls to this method (it
                // can be expensive) and also makes it so we don't need another
                // cross-thread mailbox message within the IO path.
                const scrollbar = state.terminal.screens.active.pages.scrollbar();

"""
generic.replace(
    scrollbar_read,
    "                // (The scrollbar is read above, for smooth scrolling.)\n\n",
)
generic.insert_before(
    """                // Begin the update of our terminal state. Work that
""",
    """                // Get our scrollbar out of the terminal, before the update
                // below: smooth scrolling (libghostty-spm) needs it to set
                // the overscan request. Reading it with the frame data
                // naturally limits the number of calls to this method (it
                // can be expensive) and avoids another cross-thread mailbox
                // message within the IO path.
                const scrollbar = state.terminal.screens.active.pages.scrollbar();

                // Smooth scrolling (libghostty-spm): the surface's
                // fractional row only counts while the viewport is still
                // where the surface left it. With one, capture one overscan
                // row below the viewport to fill the bottom edge.
                const scroll_frac_px: f32 = state.scroll_frac.current(.of(
                    state.terminal,
                    scrollbar.offset,
                    self.grid_metrics.cell_height,
                ));
                self.terminal_state.overscan_request = if (scroll_frac_px > 0)
                    .{ .below = 1 }
                else
                    .{};

""",
    marker="                // Smooth scrolling (libghostty-spm): the surface's\n",
)
generic.insert_after(
    "                    .overlay_features = overlay_features,\n",
    "                    .scroll_frac_px = scroll_frac_px,\n",
)
generic.insert_after(
    """                    log.warn("error rebuilding GPU cells err={}", .{err});
                };
""",
    """
                // Smooth scrolling: shift the whole grid up by the
                // fractional row. It needs the overscan row below; without
                // it (the viewport follows the active area) it is dropped.
                {
                    const frac: f32 = if (self.terminal_state.overscan.below > 0)
                        critical.scroll_frac_px
                    else
                        0;
                    const offset_y = -frac;
                    if (self.uniforms.content_offset[1] != offset_y) {
                        self.uniforms.content_offset = .{ 0, offset_y };
                        self.cells_rebuilt = true;
                    }
                }
""",
)
generic.replace(
    """            const state: *terminal.RenderState = &self.terminal_state;

            const grid_size_diff =
                self.cells.size.rows != state.rows or
                self.cells.size.columns != state.cols;

            if (grid_size_diff) {
                var new_size = self.cells.size;
                new_size.rows = state.rows;
""",
    """            const state: *terminal.RenderState = &self.terminal_state;

            // The GPU grid holds the viewport plus any overscan row below it
            // (smooth scrolling). Uncaptured overscan rows stay empty.
            const grid_rows: terminal.size.CellCountInt =
                state.rows + state.overscan_request.below;

            const grid_size_diff =
                self.cells.size.rows != grid_rows or
                self.cells.size.columns != state.cols;

            // Only the Metal shaders clip to the viewport so far.
            if (comptime @hasField(@TypeOf(self.uniforms), "viewport_rows")) {
                self.uniforms.viewport_rows = state.rows;
            }

            if (grid_size_diff) {
                var new_size = self.cells.size;
                new_size.rows = grid_rows;
""",
)
generic.replace(
    """            const row_len: usize = @min(
                state.rows,
                self.cells.size.rows,
            );
""",
    """            const row_len: usize = @min(
                state.rowDataRange().end,
                self.cells.size.rows,
            );

            // Overscan rows that were requested but not captured.
            for (row_len..self.cells.size.rows) |y| {
                self.cells.clear(@intCast(y));
            }
""",
)
generic.replace(
    "                } else if (y == self.cells.size.rows - 1) {\n",
    "                } else if (y == state.rows - 1) {\n",
)
generic.save()

metal_zig = Source(source_dir, "src/renderer/metal/shaders.zig")
metal_zig.replace(
    """    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// Size of the grid in columns and rows.
    grid_size: [2]u16 align(4),

""",
    """    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// Pixel offset applied to every cell, glyph and image, for smooth
    /// scrolling (libghostty-spm). Zero means the grid is drawn as is.
    /// When it is not zero, everything is clipped to the viewport (the
    /// grid area inside the padding).
    content_offset: [2]f32 align(8) = .{ 0, 0 },

    /// Size of the grid in columns and rows.
    grid_size: [2]u16 align(4),

    /// Rows of the grid that are the viewport; the rest of `grid_size` are
    /// overscan rows below it (smooth scrolling). Only read while
    /// `content_offset` is not zero. Fits in the padding before
    /// `grid_padding`, so the layout of the other fields is unchanged.
    viewport_rows: u16 align(2) = 0,

""",
)
metal_zig.save()

gl_zig = Source(source_dir, "src/renderer/opengl/shaders.zig")
gl_zig.replace(
    """    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// Size of the grid in columns and rows.
""",
    """    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// See the Metal Uniforms (libghostty-spm smooth scrolling). The GLSL
    /// shaders apply the offset but do not clip yet.
    content_offset: [2]f32 align(8) = .{ 0, 0 },

    /// Size of the grid in columns and rows.
""",
)
gl_zig.save()

glsl = Source(source_dir, "src/renderer/shaders/glsl/common.glsl")
glsl.replace(
    "    uniform vec2 cell_size;\n    uniform uint grid_size_packed_2u16;\n",
    "    uniform vec2 cell_size;\n    uniform vec2 content_offset;\n    uniform uint grid_size_packed_2u16;\n",
)
glsl.save()

glsl = Source(source_dir, "src/renderer/shaders/glsl/cell_bg.f.glsl")
glsl.replace(
    "    ivec2 grid_pos = ivec2(floor((gl_FragCoord.xy - grid_padding.wx) / cell_size));\n",
    "    ivec2 grid_pos = ivec2(floor((gl_FragCoord.xy - grid_padding.wx - content_offset) / cell_size));\n",
)
glsl.save()

glsl = Source(source_dir, "src/renderer/shaders/glsl/cell_text.v.glsl")
glsl.replace(
    "    vec2 cell_pos = cell_size * vec2(grid_pos);\n",
    "    vec2 cell_pos = cell_size * vec2(grid_pos) + content_offset;\n",
)
glsl.save()

glsl = Source(source_dir, "src/renderer/shaders/glsl/image.v.glsl")
glsl.replace(
    "    vec2 image_pos = (cell_size * grid_pos) + cell_offset;\n",
    "    vec2 image_pos = (cell_size * grid_pos) + cell_offset + content_offset;\n",
)
glsl.save()

metal = Source(source_dir, "src/renderer/shaders/shaders.metal")
metal.replace(
    "  float2 cell_size;\n  ushort2 grid_size;\n  float4 grid_padding;\n",
    "  float2 cell_size;\n  float2 content_offset;\n  ushort2 grid_size;\n  ushort viewport_rows;\n  float4 grid_padding;\n",
)
metal.insert_before(
    """//-------------------------------------------------------------------
// Cell Background Shader
//-------------------------------------------------------------------
""",
    """//-------------------------------------------------------------------
// Content offset (smooth scrolling, libghostty-spm)
//-------------------------------------------------------------------

// Height in pixels of the viewport: the grid area inside the padding. With
// overscan the grid has more rows than this; they are clipped.
float viewport_height(constant Uniforms& uniforms) {
  return float(uniforms.viewport_rows) * uniforms.cell_size.y;
}

// Whether a fragment at pixel position `position` falls outside the
// viewport while the grid is offset, i.e. must be clipped. With no offset
// nothing is clipped, so glyphs may overhang into the padding as before.
bool content_clipped(constant Uniforms& uniforms, float4 position) {
  if (uniforms.content_offset.y == 0.0f) return false;
  float y = position.y - uniforms.grid_padding.x;
  return y < 0.0f || y >= viewport_height(uniforms);
}

""",
)
metal.replace(
    "  int2 grid_pos = int2(floor((in.position.xy - uniforms.grid_padding.wx) / uniforms.cell_size));\n",
    """  float2 pos = in.position.xy - uniforms.grid_padding.wx;

  // Rows that exist on the screen: the grid can hold more (overscan), but
  // padding extension always extends the viewport's last row.
  int view_rows = uniforms.grid_size.y;
  bool below_view = false;

  // Smooth scrolling: inside the viewport the grid is offset;
  // the padding keeps its usual unshifted mapping.
  if (uniforms.content_offset.y != 0.0f) {
    float view_h = viewport_height(uniforms);
    view_rows = uniforms.viewport_rows;
    below_view = pos.y >= view_h;
    if (pos.y >= 0.0f && !below_view) {
      pos -= uniforms.content_offset;
      // Past the grid there is nothing to extend: show the background.
      if (pos.y < 0.0f || pos.y >= float(uniforms.grid_size.y) * uniforms.cell_size.y) {
        return float4(0.0);
      }
    }
  }

  int2 grid_pos = int2(floor(pos / uniforms.cell_size));
""",
)
metal.replace(
    """  } else if (grid_pos.y > uniforms.grid_size.y - 1) {
    if (uniforms.padding_extend & EXTEND_DOWN) {
      grid_pos.y = uniforms.grid_size.y - 1;
""",
    """  } else if (grid_pos.y > uniforms.grid_size.y - 1 ||
             (below_view && grid_pos.y > view_rows - 1)) {
    if (uniforms.padding_extend & EXTEND_DOWN) {
      grid_pos.y = view_rows - 1;
""",
)
metal.replace(
    "  float2 cell_pos = uniforms.cell_size * float2(in.grid_pos);\n",
    "  float2 cell_pos = uniforms.cell_size * float2(in.grid_pos) + uniforms.content_offset;\n",
)
metal.replace(
    "  float2 image_pos = (uniforms.cell_size * in.grid_pos) + in.cell_offset;\n",
    "  float2 image_pos = (uniforms.cell_size * in.grid_pos) + in.cell_offset + uniforms.content_offset;\n",
)
metal.replace(
    """fragment float4 cell_text_fragment(
  CellTextVertexOut in [[stage_in]],
  texture2d<float> textureGrayscale [[texture(0)]],
  texture2d<float> textureColor [[texture(1)]],
  constant Uniforms& uniforms [[buffer(1)]]
) {
""",
    """fragment float4 cell_text_fragment(
  CellTextVertexOut in [[stage_in]],
  texture2d<float> textureGrayscale [[texture(0)]],
  texture2d<float> textureColor [[texture(1)]],
  constant Uniforms& uniforms [[buffer(1)]]
) {
  if (content_clipped(uniforms, in.position)) discard_fragment();

""",
)
metal.replace(
    """fragment float4 image_fragment(
  ImageVertexOut in [[stage_in]],
  texture2d<float> image [[texture(0)]],
  constant Uniforms& uniforms [[buffer(1)]]
) {
""",
    """fragment float4 image_fragment(
  ImageVertexOut in [[stage_in]],
  texture2d<float> image [[texture(0)]],
  constant Uniforms& uniforms [[buffer(1)]]
) {
  if (content_clipped(uniforms, in.position)) discard_fragment();

""",
)
metal.save()
PY
