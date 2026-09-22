#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# =============================================================================
# Hold the last frame while a shell redraws the prompt a resize erased
# =============================================================================
#
# A resize erases the prompt the cursor is on so the shell can redraw it
# (Screen.clearPromptForRedraw), and the renderer presented that erased grid
# for as long as the shell took to answer SIGWINCH: the last line blinked on
# every resize. Measured on device with a shell that answers 150 ms late,
# 398 of 1201 frames had no prompt; 0 of 1201 with this patch.
#
# The erase stays, so reflow leaves no stale prompt behind (`redraw=0` was
# the alternative and gives that up). What changes is presentation:
#
#   - Screen.prompt_redraw records that a *visible* prompt was erased, and
#     how many non-empty input cells the whole prompt held before the erase.
#   - The renderer keeps its last frame while that is set, as it does for
#     synchronized output.
#   - OSC 133 B says the prompt is drawn. It says nothing about the input
#     after it, which the shell draws next and possibly in another write, so
#     the hold then continues until at least the erased input cells are back
#     on the prompt, or a short grace passes. OSC 133 C (a command started)
#     and a full reset end it outright.
#   - A terminal-owned generation restarts the input grace even when resize
#     and B arrive between frames. An input-only `redraw=last` continuation
#     completes when its input returns, without requiring another B.
#   - The renderer bounds the whole wait itself: from the first frame it
#     held, never extended by later resizes, and released whichever path set
#     the flag (termio's resize, DECCOLM, mode 3 — all reach Screen.resize).
#     It schedules its own wake for the deadline through animationWake, the
#     hook the render thread already polls after every frame. No termio
#     timer, no message, nothing to forget to arm.
#
# Exact anchors only (Script/support/anchored_edit.py).
# =============================================================================

PYTHONPATH="$(cd "$(dirname "$0")/../../Script/support" && pwd)" python3 - "$SOURCE_DIR" <<'PY'
import sys

from anchored_edit import Source

source_dir = sys.argv[1]

# ── src/terminal/Screen.zig ──────────────────────────────────────────────────
src = Source(source_dir, "src/terminal/Screen.zig")
src.insert_before(
    "/// Dirty flags for the renderer.\ndirty: Dirty = .{},\n",
    """/// Set from the moment a resize erased a visible prompt until the shell
/// has drawn it again (OSC 133 B, then the input after it) or the renderer
/// gives up waiting. The renderer keeps presenting its last frame meanwhile,
/// so the erased prompt is never on screen, and bounds the wait itself.
prompt_redraw: PromptRedraw = .{},
/// Advances at each visible erase, even if the renderer misses the prompt phase.
/// Kept across hold completion and reset so a later redraw has a new identity.
prompt_redraw_generation: u64 = 0,

""",
)
src.insert_after(
    "pub fn reset(self: *Screen) void {\n",
    """    // Whatever prompt a resize erased went with the rest of the screen.
    self.prompt_redraw = .{};

""",
)
src.insert_before(
    "        switch (redraw) {\n            .false => unreachable,\n",
    """        // The input on the prompt before the erase, counted over the same
        // rows promptInputCells counts afterwards — the whole prompt, not
        // just the rows cleared, so a `.last` erase that keeps the rows
        // above is measured against what they still hold.
        const input_before = self.promptInputCells();
        var visible = false;
        var input_only = redraw == .last;
        if (input_only) {
            for (self.cursor.page_pin.node.page().getCells(self.cursor.page_row)) |cell| {
                if (!cell.isEmpty() and cell.semantic_content != .input) {
                    input_only = false;
                    break;
                }
            }
        }

""",
)
src.replace(
    """                const cells = page.getCells(row);
                self.clearCells(page, row, cells);
            },

            .true => {
""",
    """                const cells = page.getCells(row);
                self.clearPromptCells(page, row, cells, &visible);
            },

            .true => {
""",
)
src.replace(
    """                    const cells = page.getCells(row);
                    self.clearCells(page, row, cells);
                }
            },
        }
    }
}
""",
    """                    const cells = page.getCells(row);
                    self.clearPromptCells(page, row, cells, &visible);
                }
            },
        }

        // An empty prompt changes nothing the user can see, so there is
        // nothing to hold a frame for. A visible one has to be drawn again
        // from the start, remembering the most input seen on the prompt.
        // An input-only continuation does not need a new prompt marker.
        if (visible) {
            self.prompt_redraw_generation +%= 1;
            self.prompt_redraw.state = if (input_only) .input_only else .prompt;
            self.prompt_redraw.input_cells = @max(
                self.prompt_redraw.input_cells,
                input_before,
            );
        }
    }
}

/// See the `prompt_redraw` field.
pub const PromptRedraw = struct {
    state: State = .none,

    /// Non-empty input cells the prompt held before the erase, counted by
    /// promptInputCells. OSC 133 B proves only that the prompt is drawn;
    /// the input area after it counts as drawn once promptInputCells is
    /// back to at least this.
    input_cells: usize = 0,

    pub const State = enum {
        none,
        /// Waiting for the shell to draw the prompt (OSC 133 B).
        prompt,
        /// The prompt is drawn; waiting for the input after it.
        input,
        /// Only input cells were erased; a continuation redraw need not send B.
        input_only,
    };
};

/// Clear one prompt row for a shell redraw, noting whether it had anything
/// on it.
fn clearPromptCells(
    self: *Screen,
    page: *Page,
    row: *Row,
    cells: []Cell,
    visible: *bool,
) void {
    for (cells) |cell| {
        if (cell.isEmpty()) continue;
        visible.* = true;
        break;
    }
    self.clearCells(page, row, cells);
}

/// The shell drew the prompt a resize erased (OSC 133 B). What may still be
/// missing is the input after it, if the erase removed any.
pub fn promptRedrawn(self: *Screen) void {
    if (self.prompt_redraw.state != .prompt) return;
    self.prompt_redraw.state = if (self.prompt_redraw.input_cells == 0)
        .none
    else
        .input;
}

/// Non-empty input cells on the prompt the cursor is on, from its first row
/// down: what a shell redraw after clearPromptForRedraw has put back so far.
pub fn promptInputCells(self: *const Screen) usize {
    var prompt_it = self.cursor.page_pin.promptIterator(.left_up, null);
    const start = prompt_it.next() orelse return 0;

    var count: usize = 0;
    var it = start.rowIterator(.right_down, null);
    while (it.next()) |pin| {
        const page = pin.node.page();
        const row = pin.rowAndCell().row;
        for (page.getCells(row)) |cell| {
            if (cell.isEmpty()) continue;
            if (cell.semantic_content == .input) count += 1;
        }
    }
    return count;
}
""",
)
src.save()

# ── src/terminal/Terminal.zig ────────────────────────────────────────────────
src = Source(source_dir, "src/terminal/Terminal.zig")
src.insert_after(
    "                .input = .clear_explicit,\n            });\n",
    """
            // The prompt a resize erased is back on the grid.
            self.screens.active.promptRedrawn();
""",
)
src.insert_after(
    "                .input = .clear_eol,\n            });\n",
    "            self.screens.active.promptRedrawn();\n",
)
src.insert_after(
    '            // "End of input, and start of output."\n'
    "            self.screens.active.cursorSetSemanticContent(.output);\n",
    """
            // A command is running; no prompt redraw is coming any more.
            self.screens.active.prompt_redraw = .{};
""",
)
src.append(
    """
test "Terminal: semantic prompt redraw after resize" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try testing.expectEqual(.none, t.screens.active.prompt_redraw.state);

    // The resize erases the prompt; the screen waits for the shell.
    try t.resize(alloc, .{ .cols = 20, .rows = 5 });
    try testing.expectEqual(.prompt, t.screens.active.prompt_redraw.state);
    try testing.expectEqual(0, t.screens.active.prompt_redraw.input_cells);

    // The shell draws its prompt again and marks where input starts.
    t.carriageReturn();
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ ") |c| try t.print(c);
    try testing.expectEqual(.prompt, t.screens.active.prompt_redraw.state);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try testing.expectEqual(.none, t.screens.active.prompt_redraw.state);
}

test "Terminal: semantic prompt redraw waits for the input after the prompt" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    for ("ls -a") |c| try t.print(c);

    // The erase took the input as well as the prompt.
    try t.resize(alloc, .{ .cols = 20, .rows = 5 });
    try testing.expectEqual(.prompt, t.screens.active.prompt_redraw.state);
    try testing.expectEqual(5, t.screens.active.prompt_redraw.input_cells);

    // The prompt alone does not end the wait: the input is still to come.
    t.carriageReturn();
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try testing.expectEqual(.input, t.screens.active.prompt_redraw.state);
    try testing.expectEqual(0, t.screens.active.promptInputCells());

    // The redrawn input is what the renderer counts against the erase.
    for ("ls -a") |c| try t.print(c);
    try testing.expectEqual(5, t.screens.active.promptInputCells());

    // A command starting ends the wait whatever was drawn.
    try t.semanticPrompt(.init(.end_input_start_output));
    try testing.expectEqual(.none, t.screens.active.prompt_redraw.state);
}

test "Terminal: semantic prompt redraw starts over on the next resize" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    for ("ls -a") |c| try t.print(c);

    try t.resize(alloc, .{ .cols = 20, .rows = 5 });
    t.carriageReturn();
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try testing.expectEqual(.input, t.screens.active.prompt_redraw.state);

    // Another resize before the input is back: the shell has to draw the
    // prompt again first, and the input to wait for is still all of it.
    try t.resize(alloc, .{ .cols = 30, .rows = 5 });
    try testing.expectEqual(.prompt, t.screens.active.prompt_redraw.state);
    try testing.expectEqual(5, t.screens.active.prompt_redraw.input_cells);
}

test "Terminal: semantic prompt redraw=last measures the rows it keeps" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    t.flags.shell_redraws_prompt = .last;

    // Two input lines; only the one with the cursor is erased.
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    for ("hello") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("world") |c| try t.print(c);
    try testing.expectEqual(10, t.screens.active.promptInputCells());

    try t.resize(alloc, .{ .cols = 20, .rows = 5 });
    try testing.expectEqual(.input_only, t.screens.active.prompt_redraw.state);
    try testing.expectEqual(10, t.screens.active.prompt_redraw.input_cells);

    // The kept row alone is not the redraw; only the erased one brought
    // back reaches the count the hold is measured against.
    try testing.expectEqual(5, t.screens.active.promptInputCells());
    for ("world") |c| try t.print(c);
    try testing.expectEqual(10, t.screens.active.promptInputCells());
}

test "Terminal: semantic prompt redraw wait ends with a full reset" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try t.resize(alloc, .{ .cols = 20, .rows = 5 });
    try testing.expectEqual(.prompt, t.screens.active.prompt_redraw.state);

    t.fullReset();
    try testing.expectEqual(.none, t.screens.active.prompt_redraw.state);
}

test "Terminal: semantic prompt no redraw wait during command output" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try t.semanticPrompt(.init(.end_input_start_output));
    for ("out") |c| try t.print(c);

    try t.resize(alloc, .{ .cols = 20, .rows = 5 });
    try testing.expectEqual(.none, t.screens.active.prompt_redraw.state);
}
""",
)
src.save()

# ── src/renderer/generic.zig ─────────────────────────────────────────────────
src = Source(source_dir, "src/renderer/generic.zig")
src.insert_after(
    "        kitty_animation_next_ms: ?u64 = null,\n",
    """
        /// The frame hold for a prompt redraw after a resize (see
        /// Screen.prompt_redraw and PromptRedrawHold). Render thread only.
        prompt_redraw_hold: PromptRedrawHold = .{},
""",
)
src.insert_before(
    "pub fn Renderer(comptime GraphicsAPI: type) type {\n",
    """/// The renderer's side of `Screen.prompt_redraw`: for how long a frame
/// stays held while the shell redraws the prompt a resize erased. The
/// terminal says what it is waiting for; this decides when to stop
/// waiting, and is kept free of the renderer so the timing can be tested.
///
/// The whole hold is bounded from the first frame held (`hold_ms`); the
/// resizes that keep arriving during a drag restart the terminal's wait
/// but never this clock. Once the prompt is drawn (OSC 133 B) with input
/// still to come, a second, shorter clock bounds that (`input_grace_ms`),
/// and it starts over for every prompt redraw: a resize between B and the
/// input puts the terminal back to waiting for the prompt, and the grace
/// for the next B must not be spent already.
pub const PromptRedrawHold = struct {
    /// How long a frame is held from the first frame held. A shell answers
    /// SIGWINCH in a few milliseconds; one that never redraws shows its
    /// erased prompt this late.
    pub const hold_ms: u64 = 500;

    /// Once the prompt is drawn, how much longer the frame is held for the
    /// input after it. A redraw arrives in one write; this covers one split
    /// in two. A shell that draws less input than before (zsh drops RPROMPT
    /// from a line it no longer fits) waits this long.
    pub const input_grace_ms: u64 = 50;

    /// When the first frame was held, and when the prompt was first seen
    /// drawn with input still to come.
    held_since: ?std.Io.Timestamp = null,
    input_since: ?std.Io.Timestamp = null,
    generation: ?u64 = null,

    pub const Wait = struct {
        state: terminal.Screen.PromptRedraw.State,
        generation: u64 = 0,
        /// Input cells the prompt had before the erase, and has now.
        input_cells: usize = 0,
        restored: usize = 0,
    };

    /// Whether the frame stays held, given what the terminal is waiting
    /// for at `now`. Ends the hold (and forgets it) when it does not.
    pub fn update(self: *PromptRedrawHold, now: std.Io.Timestamp, wait: Wait) bool {
        switch (wait.state) {
            .none => {
                self.* = .{};
                return false;
            },
            // A prompt redraw is starting (again): the input grace, if
            // one was running, belongs to the previous redraw.
            .prompt => self.input_since = null,
            .input, .input_only => {},
        }

        // Resize and B can both arrive between frames. The terminal's
        // generation survives that unobserved transition; only the input
        // grace restarts, never the overall hold deadline.
        if (self.generation == null or self.generation.? != wait.generation) {
            self.generation = wait.generation;
            self.input_since = null;
        }

        const held_since = self.held_since orelse now;
        self.held_since = held_since;
        if (msSince(held_since, now) >= hold_ms) {
            self.* = .{};
            return false;
        }
        if (wait.state == .prompt) return true;

        // The prompt is drawn. The input counts as drawn once what the
        // erase took is back, and a shell that draws less gets the grace.
        if (wait.restored >= wait.input_cells) {
            self.* = .{};
            return false;
        }
        // No B is expected for an input-only continuation. Its restored
        // cells complete the redraw; otherwise the overall deadline applies.
        if (wait.state == .input_only) return true;
        const input_since = self.input_since orelse now;
        self.input_since = input_since;
        if (msSince(input_since, now) >= input_grace_ms) {
            self.* = .{};
            return false;
        }
        return true;
    }

    fn updateScreen(self: *PromptRedrawHold, now: std.Io.Timestamp, screen: *const terminal.Screen) bool {
        const redraw = screen.prompt_redraw;
        return self.update(now, .{
            .state = redraw.state,
            .generation = screen.prompt_redraw_generation,
            .input_cells = redraw.input_cells,
            .restored = switch (redraw.state) {
                .input, .input_only => screen.promptInputCells(),
                .none, .prompt => 0,
            },
        });
    }

    /// Milliseconds until the hold ends on its own, while one is on.
    pub fn wakeIn(self: *const PromptRedrawHold, now: std.Io.Timestamp) ?u64 {
        const held_since = self.held_since orelse return null;
        var due = hold_ms -| msSince(held_since, now);
        if (self.input_since) |input_since| {
            due = @min(due, input_grace_ms -| msSince(input_since, now));
        }
        return due;
    }

    fn msSince(since: std.Io.Timestamp, now: std.Io.Timestamp) u64 {
        return @intCast(@divTrunc(
            since.durationTo(now).nanoseconds,
            std.time.ns_per_ms,
        ));
    }

    fn at(ms: u64) std.Io.Timestamp {
        return .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms };
    }
};

test "prompt redraw hold: bounded from the first frame held" {
    const testing = std.testing;
    var hold: PromptRedrawHold = .{};
    const prompt: PromptRedrawHold.Wait = .{ .state = .prompt };

    try testing.expect(hold.update(PromptRedrawHold.at(0), prompt));
    try testing.expectEqual(500, hold.wakeIn(PromptRedrawHold.at(0)).?);

    // Resizes keep the terminal waiting for the prompt; the clock stays.
    try testing.expect(hold.update(PromptRedrawHold.at(200), prompt));
    try testing.expect(hold.update(PromptRedrawHold.at(499), prompt));
    try testing.expectEqual(1, hold.wakeIn(PromptRedrawHold.at(499)).?);
    try testing.expect(!hold.update(PromptRedrawHold.at(500), prompt));
    try testing.expectEqual(null, hold.wakeIn(PromptRedrawHold.at(500)));

    // A new hold after that is a new clock.
    try testing.expect(hold.update(PromptRedrawHold.at(600), prompt));
    try testing.expectEqual(500, hold.wakeIn(PromptRedrawHold.at(600)).?);
}

test "prompt redraw hold: prompt drawn, input back" {
    const testing = std.testing;
    var hold: PromptRedrawHold = .{};

    try testing.expect(hold.update(PromptRedrawHold.at(0), .{ .state = .prompt }));
    try testing.expect(hold.update(PromptRedrawHold.at(10), .{ .state = .input, .input_cells = 5, .restored = 2 }));
    try testing.expectEqual(40, hold.wakeIn(PromptRedrawHold.at(20)).?);
    try testing.expect(!hold.update(PromptRedrawHold.at(20), .{ .state = .input, .input_cells = 5, .restored = 5 }));
    try testing.expectEqual(null, hold.wakeIn(PromptRedrawHold.at(20)));
}

test "prompt redraw hold: input grace bounds a shell that draws less" {
    const testing = std.testing;
    var hold: PromptRedrawHold = .{};
    const input: PromptRedrawHold.Wait = .{ .state = .input, .input_cells = 5, .restored = 3 };

    try testing.expect(hold.update(PromptRedrawHold.at(0), .{ .state = .prompt }));
    try testing.expect(hold.update(PromptRedrawHold.at(10), input));
    try testing.expect(hold.update(PromptRedrawHold.at(59), input));
    try testing.expect(!hold.update(PromptRedrawHold.at(60), input));
}

test "prompt redraw hold: input grace starts over with each prompt redraw" {
    const testing = std.testing;
    var hold: PromptRedrawHold = .{};
    const input: PromptRedrawHold.Wait = .{ .state = .input, .input_cells = 5, .restored = 0 };

    try testing.expect(hold.update(PromptRedrawHold.at(0), .{ .state = .prompt }));
    try testing.expect(hold.update(PromptRedrawHold.at(10), input));

    // Another resize before the input came back: the terminal waits for
    // the prompt again, and the grace runs from the next B, not the last.
    try testing.expect(hold.update(PromptRedrawHold.at(30), .{ .state = .prompt }));
    try testing.expectEqual(470, hold.wakeIn(PromptRedrawHold.at(30)).?);
    try testing.expect(hold.update(PromptRedrawHold.at(70), input));
    try testing.expect(hold.update(PromptRedrawHold.at(119), input));
    try testing.expect(!hold.update(PromptRedrawHold.at(120), input));
}

test "prompt redraw hold: the whole hold still ends at its deadline" {
    const testing = std.testing;
    var hold: PromptRedrawHold = .{};
    const input: PromptRedrawHold.Wait = .{ .state = .input, .input_cells = 5, .restored = 0 };

    try testing.expect(hold.update(PromptRedrawHold.at(0), .{ .state = .prompt }));
    try testing.expect(hold.update(PromptRedrawHold.at(480), input));
    try testing.expectEqual(20, hold.wakeIn(PromptRedrawHold.at(480)).?);
    try testing.expect(!hold.update(PromptRedrawHold.at(500), input));
}

test "prompt redraw hold: nothing to wait for" {
    const testing = std.testing;
    var hold: PromptRedrawHold = .{};

    try testing.expect(hold.update(PromptRedrawHold.at(0), .{ .state = .prompt }));
    try testing.expect(!hold.update(PromptRedrawHold.at(5), .{ .state = .none }));
    try testing.expectEqual(null, hold.wakeIn(PromptRedrawHold.at(5)));
}

test "prompt redraw hold: resize and B between frames restart only the input grace" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    var hold: PromptRedrawHold = .{};

    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    for ("hello") |c| try t.print(c);
    try t.resize(alloc, .{ .cols = 20, .rows = 5 });
    try testing.expect(hold.updateScreen(PromptRedrawHold.at(0), t.screens.active));
    t.carriageReturn();
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try testing.expect(hold.updateScreen(PromptRedrawHold.at(10), t.screens.active));
    const first_generation = t.screens.active.prompt_redraw_generation;

    // No renderer call between this resize and B: both observed frames
    // have state .input, but the old grace has already expired at 70 ms.
    try t.resize(alloc, .{ .cols = 30, .rows = 5 });
    t.carriageReturn();
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try testing.expectEqual(first_generation + 1, t.screens.active.prompt_redraw_generation);
    try testing.expect(hold.updateScreen(PromptRedrawHold.at(70), t.screens.active));
    try testing.expectEqual(50, hold.wakeIn(PromptRedrawHold.at(70)).?);
    try testing.expect(hold.updateScreen(PromptRedrawHold.at(119), t.screens.active));

    // Another unobserved transition near the overall deadline must not
    // postpone that deadline, even though its input grace starts anew.
    try t.resize(alloc, .{ .cols = 40, .rows = 5 });
    t.carriageReturn();
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try testing.expect(hold.updateScreen(PromptRedrawHold.at(480), t.screens.active));
    try testing.expectEqual(20, hold.wakeIn(PromptRedrawHold.at(480)).?);
    try testing.expect(!hold.updateScreen(PromptRedrawHold.at(500), t.screens.active));
}

test "prompt redraw hold: last input line completes without B" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    t.flags.shell_redraws_prompt = .last;
    var hold: PromptRedrawHold = .{};

    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    for ("hello") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("world") |c| try t.print(c);
    try t.resize(alloc, .{ .cols = 20, .rows = 5 });

    // Retained hello must not count as restoration of the missing world.
    try testing.expect(hold.updateScreen(PromptRedrawHold.at(0), t.screens.active));
    for ("wor") |c| try t.print(c);
    try testing.expect(hold.updateScreen(PromptRedrawHold.at(150), t.screens.active));
    for ("ld") |c| try t.print(c);
    try testing.expect(!hold.updateScreen(PromptRedrawHold.at(160), t.screens.active));
    try testing.expectEqual(null, hold.wakeIn(PromptRedrawHold.at(160)));
}

test "prompt redraw hold: last line containing prompt still requires B" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    t.flags.shell_redraws_prompt = .last;
    var hold: PromptRedrawHold = .{};

    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    for ("hello") |c| try t.print(c);
    try t.resize(alloc, .{ .cols = 20, .rows = 5 });
    try testing.expectEqual(.prompt, t.screens.active.prompt_redraw.state);
    try testing.expect(hold.updateScreen(PromptRedrawHold.at(0), t.screens.active));
    for ("hello") |c| try t.print(c);
    try testing.expect(hold.updateScreen(PromptRedrawHold.at(150), t.screens.active));
    try testing.expect(!hold.updateScreen(PromptRedrawHold.at(500), t.screens.active));
}

""",
)
src.replace(
    """            // An update wake includes a draw, so it wins ties.
            if (kitty_delay) |k| {
                if (shader_delay == null or k <= shader_delay.?) {
                    return .{ .delay_ms = k, .kind = .update };
                }
            }
""",
    """            // A frame held for a prompt redraw (see updateFrame) is let
            // go at its deadline whether or not the shell ever redraws;
            // wake to present the grid then.
            const hold_delay: ?u64 = hold: {
                const now: std.Io.Timestamp = .now(global.io(), .awake);
                const due = self.prompt_redraw_hold.wakeIn(now) orelse break :hold null;
                break :hold @max(due, draw_interval_ms);
            };

            // The next frame update due: a Kitty frame or the end of a
            // prompt redraw hold, whichever comes first.
            const update_delay: ?u64 = if (kitty_delay) |k|
                (if (hold_delay) |h| @min(k, h) else k)
            else
                hold_delay;

            // An update wake includes a draw, so it wins ties.
            if (update_delay) |u| {
                if (shader_delay == null or u <= shader_delay.?) {
                    return .{ .delay_ms = u, .kind = .update };
                }
            }
""",
)
src.insert_before(
    "        /// True if our renderer is using vsync. If true, the renderer or apprt\n",
    """        /// Whether the frame stays held for a prompt redraw; see updateFrame.
        /// Called on the render thread with the terminal state locked.
        fn promptRedrawHeld(self: *Self, t: *terminal.Terminal) bool {
            const screen = t.screens.active;
            const state = screen.prompt_redraw.state;
            if (self.prompt_redraw_hold.updateScreen(.now(global.io(), .awake), screen)) return true;

            // Every screen, so a switch cannot bring a stale hold back.
            if (state != .none) {
                var it = t.screens.all.iterator();
                while (it.next()) |entry| entry.value.*.prompt_redraw = .{};
            }
            return false;
        }

""",
)
src.insert_after(
    """                    log.debug("synchronized output started, skipping render", .{});
                    return;
                }
""",
    """
                // A resize erased the prompt and the shell has not drawn it
                // again yet. Keep the last frame, as for synchronized output.
                // The wait is bounded here, by the thread that honors it, so
                // every path that starts one has the same exit; animationWake
                // schedules the wake for the deadline.
                if (self.promptRedrawHeld(state.terminal)) {
                    log.debug("prompt redraw pending, skipping render", .{});
                    return;
                }
""",
)
src.save()
PY

echo "[+] prompt redraw frame hold applied"
