#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# =============================================================================
# Keep DEC 2026 synchronized output active across a resize
# =============================================================================
#
# A TUI clears and repaints inside one synchronized-output transaction, and
# the renderer holds its last frame until the program ends it. Upstream's
# Terminal.resize() ends the transaction itself, on every valid resize, so a
# resize that lands between the clear and the repaint puts the empty grid on
# screen: the whole pane blinks. Measured on device, 291 of 1201 frames blank
# during a resize animation, 0 of 1200 with this patch.
#
# The mode now ends only when the program ends it, or when termio's one-second
# watchdog does (src/termio/Thread.zig, sync_reset_ms), which is what bounds a
# program that never finishes its frame.
#
# Two edits, both exact anchors (Script/support/anchored_edit.py):
#   - Terminal.resize() no longer clears the mode.
#   - libghostty-vt's stream Handler.resize() reported the end of the render
#     hold whenever the mode was on before the resize; it now reports it only
#     when the mode is actually off afterwards.
#
# The tests asserting resize ends synchronized output are updated with exact
# anchors, retaining their geometry and callback checks.
# =============================================================================

PYTHONPATH="$(cd "$(dirname "$0")/../../Script/support" && pwd)" python3 - "$SOURCE_DIR" <<'PY'
import sys

from anchored_edit import Source

source_dir = sys.argv[1]

src = Source(source_dir, "src/terminal/Terminal.zig")
src.replace(
    """    self.modes.set(.synchronized_output, false);

    // If our cols/rows didn't change, skip grid work but still apply pixels.
""",
    """    // libghostty-spm: synchronized output stays as the program left it. A
    // resize must not present the half-drawn frame the mode is hiding; the
    // termio watchdog still ends a transaction nobody finishes.

    // If our cols/rows didn't change, skip grid work but still apply pixels.
""",
)
src.replace(
    """test "Terminal: resize resets synchronized output" {
""",
    """test "Terminal: resize preserves synchronized output" {
""",
)
src.replace(
    """    t.modes.set(.synchronized_output, true);
    try t.resize(alloc, .{ .cols = 10, .rows = 5 });
    try testing.expect(!t.modes.get(.synchronized_output));
""",
    """    t.modes.set(.synchronized_output, true);
    try t.resize(alloc, .{ .cols = 10, .rows = 5 });
    try testing.expect(t.modes.get(.synchronized_output));
""",
)
src.replace(
    """            try testing.expectEqual(@as(u32, 72), t.height_px);
            try testing.expect(!t.modes.get(.synchronized_output));
            try testing.expect(t.flags.dirty.clear);
""",
    """            try testing.expectEqual(@as(u32, 72), t.height_px);
            try testing.expect(t.modes.get(.synchronized_output));
            try testing.expect(t.flags.dirty.clear);
""",
)
src.save()

src = Source(source_dir, "src/terminal/stream_terminal.zig")
src.replace(
    """        try self.terminal.resize(self.terminal.gpa(), value);
        if (sync) self.renderHold(false);
""",
    """        try self.terminal.resize(self.terminal.gpa(), value);
        if (sync and !self.terminal.modes.get(.synchronized_output)) self.renderHold(false);
""",
)
src.replace(
    """        /// when VT input resets the mode, on a full reset, and on a resize
        /// through `Handler.resize`. The calls always come in pairs:
""",
    """        /// when VT input resets the mode or on a full reset. A resize
        /// preserves the hold. The calls always come in pairs:
""",
)
src.replace(
    """        // Resize always turns off synchronized output, ending its hold.
""",
    """        // A resize keeps synchronized output active until the program ends it.
""",
)
src.replace(
    """    // Resize
    S.len = 0;
    s.nextSlice("\\x1b[?2026h");
    try s.handler.resize(.{ .cols = 80, .rows = 24 });
    try s.handler.resize(.{ .cols = 80, .rows = 24 });
    try testing.expectEqualSlices(bool, &.{ true, false }, S.events[0..S.len]);
""",
    """    // Resize preserves the hold; an explicit reset ends it once.
    S.len = 0;
    s.nextSlice("\\x1b[?2026h");
    try s.handler.resize(.{ .cols = 80, .rows = 24 });
    try s.handler.resize(.{ .cols = 80, .rows = 24 });
    try testing.expectEqualSlices(bool, &.{true}, S.events[0..S.len]);
    s.nextSlice("\\x1b[?2026l");
    try testing.expectEqualSlices(bool, &.{ true, false }, S.events[0..S.len]);
""",
)
src.replace(
    """test "resize clears synchronized output on unchanged cell dimensions" {
""",
    """test "resize preserves synchronized output on unchanged cell dimensions" {
""",
)
src.replace(
    """    try testing.expect(!t.modes.get(.synchronized_output));
    try testing.expectEqual(@as(u32, 720), t.width_px);
""",
    """    try testing.expect(t.modes.get(.synchronized_output));
    try testing.expectEqual(@as(u32, 720), t.width_px);
""",
)
src.save()

src = Source(source_dir, "src/terminal/c/terminal.zig")
src.replace(
    """test "resize disables synchronized output" {
""",
    """test "resize preserves synchronized output" {
""",
)
src.replace(
    """    // The terminal-level reset must run even if grid work is unnecessary.
    try testing.expectEqual(Result.success, resize(t, 80, 24, 9, 18));
    try testing.expect(!zt.modes.get(.synchronized_output));
""",
    """    // A resize with unchanged cell dimensions keeps synchronized output.
    try testing.expectEqual(Result.success, resize(t, 80, 24, 9, 18));
    try testing.expect(zt.modes.get(.synchronized_output));
""",
)
src.save()
PY

echo "[+] synchronized output preserved across resize"
