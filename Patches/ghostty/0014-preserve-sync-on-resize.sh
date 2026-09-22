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
# Upstream's unit tests that assert the old behaviour ("resize resets
# synchronized output" and friends) are left as they are: nothing in this
# repository runs them, and rewriting them is what made this patch drift.
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
src.save()
PY

echo "[+] synchronized output preserved across resize"
