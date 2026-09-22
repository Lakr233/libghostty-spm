#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# =============================================================================
# Replay without replies: ghostty_surface_write_buffer_replay
# =============================================================================
#
# A host that reattaches to a running session feeds the surface the bytes it
# missed. Those bytes hold queries (DA, DSR, OSC 10/11, title reports) the
# program already had answered once; answering them again types garbage into
# the shell. The replay entry point parses exactly as write_buffer does and
# discards, at their origin, the messages whose only effect is a reply.
#
# The suppression flag is only valid while the terminal-state mutex is held.
# Every writer in stream_handler.zig that releases that mutex clears the flag
# for the window, or another thread's message would be dropped as replay. The
# expect_count lines below are tripwires for that: when upstream adds another
# place that unlocks the mutex, this patch stops and has to be read again.
#
# Exact anchors only (Script/support/anchored_edit.py): nothing here applies
# with fuzz, and a missing or ambiguous anchor fails the build.
# =============================================================================

PYTHONPATH="$(cd "$(dirname "$0")/../../Script/support" && pwd)" python3 - "$SOURCE_DIR" <<'PY'
import sys

from anchored_edit import Source

source_dir = sys.argv[1]

# ── include/ghostty.h ────────────────────────────────────────────────────────
src = Source(source_dir, "include/ghostty.h")
src.insert_after(
    "GHOSTTY_API void ghostty_surface_write_buffer(ghostty_surface_t, const uint8_t*, uintptr_t);\n",
    "GHOSTTY_API void ghostty_surface_write_buffer_replay(ghostty_surface_t, const uint8_t*, uintptr_t);\n",
)
src.save()

# ── src/apprt/embedded.zig ───────────────────────────────────────────────────
src = Source(source_dir, "src/apprt/embedded.zig")
src.insert_before(
    "    export fn ghostty_surface_process_exit(\n",
    """    /// Process host output as reconstructed history. The parser and terminal
    /// state are updated exactly as with ghostty_surface_write_buffer, but
    /// terminal protocol responses caused by this buffer are discarded at
    /// their origin. The suppression flag is set under the terminal-state
    /// mutex and cleared whenever the parser releases it mid-call, so a
    /// response another thread produces in that window is not discarded.
    export fn ghostty_surface_write_buffer_replay(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        if (len == 0) return;
        surface.core_surface.io.processOutputSuppressingResponses(ptr[0..len]);
    }

""",
)
src.save()

# ── src/apprt/surface.zig ────────────────────────────────────────────────────
src = Source(source_dir, "src/apprt/surface.zig")
src.insert_before(
    "    pub const ReportTitleStyle = enum {\n",
    """    /// Discard parser-originated surface requests whose eventual effect is a
    /// terminal protocol response. These requests must not escape a
    /// reconstructed-history replay scope through the asynchronous surface
    /// mailbox.
    ///
    /// `kitty_clipboard_read`/`kitty_clipboard_write` are deliberately not
    /// covered here: the receiver takes ownership of the boxed request state
    /// and must destroy it, and this classifier only knows how to drop a
    /// message, not release owned state (see `termio.Message.write_alloc`
    /// for the pattern this would need). Replaying reconstructed history
    /// that contains a Kitty clipboard protocol sequence can still leak a
    /// confirmation to the host; this is a pre-existing gap, not a
    /// regression, since Kitty clipboard support did not exist when replay
    /// suppression was introduced.
    pub fn discardIfTerminalResponse(self: Message) bool {
        return switch (self) {
            .report_title, .clipboard_read => true,
            else => false,
        };
    }

""",
)
src.insert_before(
    'test "DesktopNotification init" {\n',
    """test "replay response classification for surface messages" {
    const testing = std.testing;

    try testing.expect((Message{ .report_title = .csi_21_t }).discardIfTerminalResponse());
    try testing.expect((Message{ .clipboard_read = .standard }).discardIfTerminalResponse());

    const bell: Message = .ring_bell;
    try testing.expect(!bell.discardIfTerminalResponse());
}

""",
)
src.save()

# ── src/termio/Termio.zig ────────────────────────────────────────────────────
src = Source(source_dir, "src/termio/Termio.zig")
src.insert_before(
    "/// Process output from readdata but the lock is already held.\n"
    "fn processOutputLocked(self: *Termio, buf: []const u8) void {\n",
    """/// Process reconstructed terminal history without sending protocol replies
/// back to the host. Response suppression is scoped to this parser call while
/// the terminal-state mutex is held. The prior suppression state is restored
/// before this call returns.
pub fn processOutputSuppressingResponses(self: *Termio, buf: []const u8) void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    const previous = self.terminal_stream.handler.suppress_terminal_responses;
    self.terminal_stream.handler.suppress_terminal_responses = true;
    defer self.terminal_stream.handler.suppress_terminal_responses = previous;

    self.processOutputLocked(buf);
}

""",
)
src.save()

# ── src/termio/message.zig ───────────────────────────────────────────────────
src = Source(source_dir, "src/termio/message.zig")
src.insert_before(
    "    /// Free resources owned by a message that will not be processed.\n",
    """    /// Discard messages whose only effect is sending terminal protocol bytes
    /// to the backend. Returns false for state and lifecycle messages that
    /// still need to be processed during reconstructed-history replay.
    pub fn discardIfTerminalResponse(self: Message) bool {
        switch (self) {
            .color_scheme_report,
            .size_report,
            .focused,
            .write_small,
            .write_stable,
            => return true,

            .write_alloc => |value| {
                value.alloc.free(value.data);
                return true;
            },

            else => return false,
        }
    }

""",
)
src.append(
    """
test "replay response classification frees owned writes and preserves state" {
    const testing = std.testing;

    try testing.expect((Message{ .write_stable = "response" }).discardIfTerminalResponse());

    const owned = try testing.allocator.dupe(u8, "allocated response");
    try testing.expect((Message{ .write_alloc = .{
        .alloc = testing.allocator,
        .data = owned,
    } }).discardIfTerminalResponse());

    try testing.expect(!(Message{ .linefeed_mode = true }).discardIfTerminalResponse());
}
""",
)
src.save()

# ── src/termio/stream_handler.zig ────────────────────────────────────────────
src = Source(source_dir, "src/termio/stream_handler.zig")

# Tripwires: the three writers below are every place the parser gives up the
# terminal-state mutex. One more and the flag handling has to be extended.
src.expect_count("self.renderer_state.mutex.unlock(global.io());", 2)
src.expect_count("self.termio_mailbox.send(", 1)

src.insert_before(
    "    /// This is set to true when we've seen a title escape sequence. We use\n",
    """    /// When true, parser-originated messages that would write terminal
    /// protocol responses back to the backend are discarded. This is used by
    /// host-managed replay and is changed only while the terminal-state mutex
    /// is held. The writers below release that mutex when a mailbox is full,
    /// so each clears the flag for that window: a message another thread
    /// sends meanwhile (changeConfig's color_scheme_report) must not be
    /// discarded as part of the replay.
    suppress_terminal_responses: bool = false,

""",
)
src.replace(
    """        msg: apprt.surface.Message,
    ) void {
        // See messageWriter which has similar logic and explains why
        // we may have to do this.
        if (self.surface_mailbox.push(msg, .{ .instant = {} }) == 0) {
            self.renderer_state.mutex.unlock(global.io());
""",
    """        msg: apprt.surface.Message,
    ) void {
        if (self.suppress_terminal_responses and msg.discardIfTerminalResponse()) {
            return;
        }
        // See messageWriter which has similar logic and explains why
        // we may have to do this.
        if (self.surface_mailbox.push(msg, .{ .instant = {} }) == 0) {
            const suppress = self.suppress_terminal_responses;
            self.suppress_terminal_responses = false;
            defer self.suppress_terminal_responses = suppress;
            self.renderer_state.mutex.unlock(global.io());
""",
)
src.replace(
    """    inline fn messageWriter(self: *StreamHandler, msg: termio.Message) void {
        self.termio_mailbox.send(msg, self.renderer_state.mutex);
""",
    """    inline fn messageWriter(self: *StreamHandler, msg: termio.Message) void {
        if (self.suppress_terminal_responses and msg.discardIfTerminalResponse()) {
            return;
        }
        // send releases the mutex when the termio mailbox is full.
        const suppress = self.suppress_terminal_responses;
        self.suppress_terminal_responses = false;
        defer self.suppress_terminal_responses = suppress;
        self.termio_mailbox.send(msg, self.renderer_state.mutex);
""",
)
src.replace(
    """        // and then try again.
        self.renderer_state.mutex.unlock(global.io());
""",
    """        // and then try again.
        const suppress = self.suppress_terminal_responses;
        self.suppress_terminal_responses = false;
        defer self.suppress_terminal_responses = suppress;
        self.renderer_state.mutex.unlock(global.io());
""",
)
src.save()
PY

echo "[+] replay response suppression applied"
