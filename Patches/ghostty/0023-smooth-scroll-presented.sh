#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# =============================================================================
# Tell the host when the frame holding a smooth scroll reaches the layer
# =============================================================================
#
# On iOS the system scroll moves the viewport from a per-frame callback on the
# main thread (ghostty_surface_smooth_scroll_by, 0022), the render thread
# draws it, and the frame's completion handler queues the present on the main
# queue. The callback has returned by then, so UIKit has committed its frame
# without ours: the picture reaches the glass one refresh after the scroll
# view's own content. Measured on a 120 Hz iPhone, from the callback to the
# swap: 34.0 ms against 25.7 for UIKit content, a whole frame, and what a
# finger dragging back and forth sees as the text trailing it at each turn.
#
# If the main thread stays in the callback until the present is queued, the
# present runs behind the callback in the same run loop turn and is committed
# with it. Only the engine knows when the frame that holds a given scroll has
# been handed over, so this patch says so:
#
#   ghostty_surface_smooth_scroll_by_tracked(surface, up_px)
#       ghostty_surface_smooth_scroll_by, and numbers the scroll. The number
#       is written in the critical section that moves the viewport
#       (renderer.State.scroll_seq), so no frame can hold the position
#       without the number or the number without the position.
#   ghostty_surface_smooth_scroll_presented(surface) -> bool
#       True once a frame that holds the last tracked scroll has been handed
#       to the layer. Lock-free; ask from the thread that scrolls.
#
# updateFrame reads the number where it reads the position; the frame drawn
# from that update carries it to its completion callback (Metal's Frame),
# which records it after presenting (scroll_presented, an atomic max, so a
# frame finishing late cannot take it back). OpenGL presents on the caller's
# thread and has no completion callback; it is left as it is, and
# smoothScrollPresented stays false there after a tracked scroll.
#
# Waiting a fixed few milliseconds instead gets the same latency while every
# frame is ready in time and falls apart when one is not: above 1200 pt/s,
# where each frame crosses a row and takes longer to draw, half the frames
# stood still for a refresh and then took two steps.
#
# Every edit sits beside upstream's own lines or after a line 0022 adds, never
# inside what 0022 inserts: its edits recognise themselves by finding their
# text intact, and a tree where that text changed gets it inserted again.
# =============================================================================

PYTHONPATH="$(cd "$(dirname "$0")/../../Script/support" && pwd)" python3 - "$SOURCE_DIR" <<'PY'
import sys

from anchored_edit import Source

source_dir = sys.argv[1]

# --- renderer.State: the last tracked scroll ---------------------------------

state = Source(source_dir, "src/renderer/State.zig")
state.insert_before(
    "/// Mouse state. This only contains state relevant to what renderers\n",
    """/// libghostty-spm (0023): bumped by every `Surface.smoothScrollByTracked`
/// that moved the viewport, with the mutex held. `updateFrame` reads it in
/// the same critical section as the position, so a frame knows the last
/// tracked scroll it holds; see `Surface.smoothScrollPresented`.
scroll_seq: u64 = 0,

""",
)
state.save()

# --- Surface: number the scroll, answer whether its frame is out -------------

surface = Source(source_dir, "src/Surface.zig")
surface.insert_before(
    "/// True if the surface is in read-only mode. When read-only, no input\n",
    """/// libghostty-spm (0023): the sequence number of the last
/// `smoothScrollByTracked` that moved the viewport. Only touched on the
/// apprt thread; mirrored into `renderer_state.scroll_seq` for the renderer.
smooth_scroll_seq: u64 = 0,

""",
)
surface.insert_before(
    "/// This is called when the content scale of the surface changes. The surface\n",
    """/// libghostty-spm (0023): `smoothScrollBy`, and numbers the scroll so the
/// host can ask whether a frame holding it has reached the layer
/// (`smoothScrollPresented`). The number is written in the same critical
/// section as the position, so no frame can hold one without the other.
pub fn smoothScrollByTracked(self: *Surface, up_px: f64) void {
    if (up_px == 0) return;
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        const bar = self.io.terminal.screens.active.pages.scrollbar();
        if (!self.smoothScrollAvailable(bar)) return;
        self.mouse.pending_scroll_y = 0;
        self.smoothScrollViewport(up_px);
        self.smooth_scroll_seq +%= 1;
        self.renderer_state.scroll_seq = self.smooth_scroll_seq;
    }
    self.queueRender() catch {};
}

/// libghostty-spm (0023): true once a frame that holds the last
/// `smoothScrollByTracked` has been handed to the layer (on the render
/// thread's path: queued on the main queue). A host that scrolls from a
/// per-frame callback on the main thread can wait for this before it
/// returns, so the frame is committed with the rest of that turn instead of
/// one refresh later. Lock-free; call it from the thread that scrolls.
pub fn smoothScrollPresented(self: *Surface) bool {
    return self.renderer.scroll_presented.load(.acquire) >= self.smooth_scroll_seq;
}

""",
)
surface.save()

# --- generic renderer: carry the number from the update to the present -------

generic = Source(source_dir, "src/renderer/generic.zig")
generic.insert_after(
    "        draw_mutex: std.Io.Mutex = .init,\n",
    """
        /// libghostty-spm (0023): `State.scroll_seq` as of the last
        /// `updateFrame`, i.e. the last tracked smooth scroll the next drawn
        /// frame holds. Written with the draw mutex held.
        frame_scroll_seq: u64 = 0,

        /// libghostty-spm (0023): the highest `frame_scroll_seq` of a frame
        /// that has been handed to the layer. Written from the frame
        /// completion callback, read by `Surface.smoothScrollPresented`.
        scroll_presented: std.atomic.Value(u64) = .init(0),
""",
)
generic.insert_after(
    "                scroll_frac_px: f32,\n",
    "                // libghostty-spm (0023)\n                scroll_seq: u64,\n",
)
generic.insert_after(
    "                    .scroll_frac_px = scroll_frac_px,\n",
    "                    .scroll_seq = state.scroll_seq,\n",
)
generic.insert_before(
    "                // The scrollbar is only emitted during draws so we also\n",
    """                // libghostty-spm (0023): frames drawn from here on hold
                // this scroll.
                self.frame_scroll_seq = critical.scroll_seq;

""",
)
generic.insert_after(
    """            var frame_ctx = try self.api.beginFrame(self, &frame.target);
            defer frame_ctx.complete(sync);
""",
    """            // libghostty-spm (0023): the frame carries the scroll it holds
            // to its completion callback (graphics APIs that present there).
            if (@hasDecl(@TypeOf(frame_ctx), "setScrollSeq")) {
                frame_ctx.setScrollSeq(self.frame_scroll_seq);
            }
""",
)
generic.insert_before(
    """        // Callback from the graphics API when a frame is completed.
        pub fn frameCompleted(
""",
    """        /// libghostty-spm (0023): a frame holding tracked smooth scroll
        /// `seq` has been handed to the layer. Called from the graphics API's
        /// completion callback, after it presents.
        pub fn scrollFramePresented(self: *Self, seq: u64) void {
            _ = self.scroll_presented.fetchMax(seq, .acq_rel);
        }

""",
)
generic.save()

# --- Metal's frame: the number rides in the completion block -----------------

frame = Source(source_dir, "src/renderer/metal/Frame.zig")
frame.insert_after(
    "            .sync = false,\n",
    "            .scroll_seq = 0,\n",
)
frame.insert_after(
    "    target: *Target,\n    sync: bool,\n",
    """    /// libghostty-spm (0023): the last tracked smooth scroll this frame
    /// holds.
    scroll_seq: u64,
""",
)
frame.insert_before(
    "    block.renderer.frameCompleted(health);\n",
    """    // libghostty-spm (0023): after presenting, so a host waiting on it
    // finds the frame already queued for the layer. An unhealthy frame counts
    // too: nothing better is coming for that scroll.
    block.renderer.scrollFramePresented(block.scroll_seq);

""",
)
frame.insert_before(
    "/// Add a render pass to this frame with the provided attachments.\n",
    """/// libghostty-spm (0023): the last tracked smooth scroll this frame holds.
/// Call before `complete`, which copies the block.
pub fn setScrollSeq(self: *Self, seq: u64) void {
    self.block.scroll_seq = seq;
}

""",
)
frame.save()

# --- C API -------------------------------------------------------------------

embedded = Source(source_dir, "src/apprt/embedded.zig")
embedded.insert_before(
    "    export fn ghostty_surface_ime_point(\n",
    """    /// libghostty-spm (0023): `ghostty_surface_smooth_scroll_by`, numbered
    /// so `ghostty_surface_smooth_scroll_presented` can tell when a frame
    /// holding it has been handed to the layer.
    export fn ghostty_surface_smooth_scroll_by_tracked(surface: *Surface, up_px: f64) void {
        surface.core_surface.smoothScrollByTracked(up_px);
    }

    /// libghostty-spm (0023): whether a frame holding the last
    /// `ghostty_surface_smooth_scroll_by_tracked` has been handed to the
    /// layer.
    export fn ghostty_surface_smooth_scroll_presented(surface: *Surface) bool {
        return surface.core_surface.smoothScrollPresented();
    }

""",
)
embedded.save()

header = Source(source_dir, "include/ghostty.h")
header.insert_before(
    "GHOSTTY_API void ghostty_surface_ime_point(ghostty_surface_t, double*, double*, double*, double*);\n",
    """// libghostty-spm (0023): ghostty_surface_smooth_scroll_by, numbered; and
// whether a frame holding the last numbered scroll has been handed to the
// layer (lock-free; call from the thread that scrolls).
GHOSTTY_API void ghostty_surface_smooth_scroll_by_tracked(ghostty_surface_t, double);
GHOSTTY_API bool ghostty_surface_smooth_scroll_presented(ghostty_surface_t);
""",
)
header.save()
PY
