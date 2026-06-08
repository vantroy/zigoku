//! Zigoku — TUI shell (ROD-71).
//!
//! The libvaxis application skeleton the rest of M3 builds into. It owns:
//!   - vaxis init / alt-screen / teardown,
//!   - the event loop with a clean render/tick split (tick mutates state,
//!     draw is a pure function of state),
//!   - resize handling,
//!   - the worker→UI seam: background work posts into vaxis's event queue via
//!     Loop.postEvent, and the main loop drains it through nextEvent. Here that
//!     seam loads watch History off a background thread; ROD-73's async search
//!     rides the same rail.
//!
//! Landing view is History (locked decision — AllAnime is search-first with no
//! popular feed, so there's nothing to populate a Browse-idle screen with).
//! The polished views land in their own issues: tabs (ROD-72), search (ROD-73),
//! detail pane (ROD-74), history filter/progress bars (ROD-75), toasts (ROD-76).

const std = @import("std");
const vaxis = @import("vaxis");
const colors = @import("colors.zig");
const store_mod = @import("../store.zig");

const Allocator = std.mem.Allocator;
const AnimeRecord = store_mod.AnimeRecord;
const Store = store_mod.Store;

/// Unified event type. vaxis fills key_press / winsize / focus; the rest are our
/// worker→UI messages, posted from background threads and drained in tick().
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    /// History finished loading (owned, gpa-allocated — App takes ownership).
    history_loaded: []AnimeRecord,
    /// A background task failed; payload is a human-readable reason.
    task_error: []const u8,
};

const Loop = vaxis.Loop(Event);

/// Run the TUI to completion. `store` is optional and best-effort, exactly like
/// the CLI path: a DB hiccup means "no history," never a refusal to run.
pub fn run(
    gpa: Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    store: ?*Store,
) !void {
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, gpa, environ_map, .{});
    defer vx.deinit(gpa, writer);

    var loop = Loop.init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    try loop.installResizeHandler();

    try vx.enterAltScreen(writer);
    // Learn terminal caps (kitty graphics/keyboard) before the first paint.
    try vx.queryTerminal(writer, .fromMilliseconds(500));

    // Size the screen to the terminal NOW — vx.window() reads vx.screen, which
    // only resize() populates. Without this the first frame paints at 0×0.
    // Subsequent size changes ride the .winsize event in the loop below.
    if (tty.getWinsize()) |ws| try vx.resize(gpa, writer, ws) else |_| {}

    var app: App = .{};

    // History memory lives in an arena owned here and freed on exit — matching
    // store.loadHistory's arena-in contract. App only reads the slice; in M3
    // history loads once (no re-search churn), so wholesale free is exactly right.
    var hist_arena = std.heap.ArenaAllocator.init(gpa);
    defer hist_arena.deinit();

    // The worker→UI seam: load history off a background thread. It posts the
    // result into the same queue the tty reader feeds; tick() drains it. The
    // thread is short-lived and joined before teardown.
    var hist_thread: ?std.Thread = null;
    // TODO(ROD-75): no cancellation — quitting while loadHistory is mid-query
    // blocks here until it returns. Fine for local SQLite; revisit if a real
    // async fetch lands behind this seam.
    defer if (hist_thread) |t| t.join();
    if (store) |st| {
        hist_thread = std.Thread.spawn(.{}, loadHistoryTask, .{ &loop, hist_arena.allocator(), st }) catch blk: {
            // Couldn't spawn — fall back to a synchronous load so the user still
            // sees their history.
            app.setHistory(st.loadHistory(hist_arena.allocator()) catch &.{});
            break :blk null;
        };
    } else {
        app.history_loading = false;
    }

    // First paint, then the event loop.
    try app.draw(&vx, writer);
    while (!app.should_quit) {
        const event = try loop.nextEvent();
        // Resize is a vaxis-lifecycle concern (it reallocates the screen), so
        // run() owns it — that keeps tick() a pure state fold, testable without
        // a tty. tick() still sees the event; it just doesn't touch the screen.
        if (event == .winsize) try vx.resize(gpa, writer, event.winsize);
        try app.tick(event);
        try app.draw(&vx, writer);
    }
}

/// Background task: pull history and post it back to the UI thread. Errors are
/// reported as a toast-able message rather than crashing the worker.
fn loadHistoryTask(loop: *Loop, arena: Allocator, store: *Store) void {
    const recs = store.loadHistory(arena) catch |err| {
        loop.postEvent(.{ .task_error = @errorName(err) }) catch {};
        return;
    };
    loop.postEvent(.{ .history_loaded = recs }) catch {};
}

const App = struct {
    should_quit: bool = false,

    /// Landing data. Backed by run()'s history arena — App only reads it.
    history: []AnimeRecord = &.{},
    history_loading: bool = true,
    /// Set if the background history load failed.
    load_error: ?[]const u8 = null,

    list_cursor: usize = 0,
    /// Topmost visible row index — the viewport offset for scrolling.
    list_top: usize = 0,

    /// Per-row scratch for formatted meta strings. vaxis stores printed text by
    /// *reference*, not by copy, so anything we print must outlive the matching
    /// vx.render() call. A loop-local stack buffer dangles by render time; this
    /// App-owned buffer persists across the draw→render cycle. Soft cap of 256
    /// slots: a terminal with more than 256 visible history rows renders titles
    /// for the overflow rows without the meta column (no crash, just no meta).
    meta_scratch: [256][48]u8 = undefined,

    fn setHistory(self: *App, recs: []AnimeRecord) void {
        self.history = recs;
        self.history_loading = false;
        if (self.list_cursor >= recs.len) self.list_cursor = if (recs.len == 0) 0 else recs.len - 1;
    }

    // ── tick: fold one event into state ──────────────────────────────────────
    fn tick(self: *App, event: Event) !void {
        switch (event) {
            .key_press => |key| self.onKey(key),
            .winsize => {}, // screen resize is handled in run()'s loop (it owns vx).
            .focus_in, .focus_out => {},
            .history_loaded => |recs| self.setHistory(recs),
            .task_error => |msg| {
                self.load_error = msg;
                self.history_loading = false;
            },
        }
    }

    fn onKey(self: *App, key: vaxis.Key) void {
        // Quit: q, Esc, or Ctrl-C.
        if (key.matches('q', .{}) or
            key.matches(vaxis.Key.escape, .{}) or
            key.matches('c', .{ .ctrl = true }))
        {
            self.should_quit = true;
            return;
        }

        const n = self.history.len;
        if (n == 0) return;

        // vim navigation over the history list (ROD-72 generalizes this).
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (self.list_cursor + 1 < n) self.list_cursor += 1;
        } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.list_cursor > 0) self.list_cursor -= 1;
        } else if (key.matches('g', .{})) {
            self.list_cursor = 0;
        } else if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) {
            // Both forms: terminals that report shift explicitly vs. those that
            // send the bare shifted codepoint.
            self.list_cursor = n - 1;
        }
    }

    // ── draw: pure render from state ─────────────────────────────────────────
    fn draw(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer) !void {
        const win = vx.window();
        win.clear();
        win.fill(.{ .style = .{ .bg = colors.bg_base } });

        const w = win.width;
        const h = win.height;
        if (h < 4 or w < 16) {
            // Too small to lay out — just say so.
            put(win, 0, 0, "terminal too small", style(colors.warn, .{}));
            try vx.render(writer);
            return;
        }

        drawTopBar(win, w);
        self.drawContent(win, h);
        self.drawBottomBar(win, h);

        try vx.render(writer);
    }

    /// §3.4: the top bar is read-only context, not navigation — `地獄 zigoku`
    /// as one primary H1 unit, then a hairline separator. No tabs here: the tab
    /// system + focus model is ROD-72 and needs a designed home (the active-tab
    /// cyan would collide with the focus color if it lived in this bar).
    fn drawTopBar(win: vaxis.Window, w: u16) void {
        put(win, 0, 2, "地獄 zigoku", style(colors.fg, .{ .bold = true }));
        if (w > 16) put(win, 0, 14, "░", style(colors.chrome, .{}));
    }

    fn drawContent(self: *App, win: vaxis.Window, h: u16) void {
        // Row 0 is the top bar; row 1 is intentional breathing room; content
        // starts at row 2 and runs to h-2; the bottom bar owns h-1.
        const top: u16 = 2;
        const visible: u16 = h - 3;
        const body_w: u16 = if (win.width > 2) win.width - 2 else 0;

        const w = win.width;

        if (self.history_loading) {
            // Static placeholder; the animated Braille spinner is ROD-76.
            putClipped(win, top, 2, body_w, "⠋ loading history", style(colors.focus, .{}));
            return;
        }
        if (self.load_error) |msg| {
            // Hard failure → magenta (state.error = state.now, §1.1).
            put(win, top, 2, "history unavailable", style(colors.hot, .{ .bold = true }));
            putClipped(win, top + 1, 2, body_w, msg, style(colors.fg3, .{}));
            return;
        }
        if (self.history.len == 0) {
            // First-run empty state (§9.2): the void, one quiet line, one
            // invitation — both centered. `/` wires up in ROD-73.
            const mid = top + visible / 2;
            centerText(win, mid -| 1, w, "nothing here yet", style(colors.fg3, .{ .italic = true }));
            const action = " to search for a show";
            const total: u16 = 1 + @as(u16, @intCast(action.len));
            const start: u16 = if (w > total) (w - total) / 2 else 0;
            put(win, mid + 1, start, "/", style(colors.focus, .{ .bold = true }));
            putClipped(win, mid + 1, start + 1, w -| (start + 1), action, style(colors.fg2, .{}));
            return;
        }

        // Keep the cursor inside the viewport.
        self.scrollIntoView(visible);

        // Meta only earns its column when the terminal is wide enough to hold it
        // without colliding the title — otherwise the title takes the full width.
        const show_meta = w >= meta_col + 12;
        const title_right: u16 = if (show_meta) meta_col - title_meta_gap else w;
        const title_w: u16 = if (title_right > title_col) title_right - title_col else 0;

        var row: u16 = top;
        var slot: usize = 0;
        var i: usize = self.list_top;
        while (i < self.history.len and row < top + visible) : (i += 1) {
            const rec = self.history[i];
            const selected = i == self.list_cursor;

            // §4.1 focus affordance: the focused row's background shifts to
            // bg.surface (a full-width band), its marker is the ▸ play glyph in
            // focus cyan, and its title goes cyan+bold. Magenta is reserved for
            // the one cursor in the status bar — never a list marker (§8).
            const row_bg = if (selected) colors.bg_surface else colors.bg_base;
            if (selected) fillRow(win, row, w, colors.bg_surface);

            const marker = if (selected) "▸ " else "  ";
            put(win, row, 2, marker, style(colors.focus, .{ .bg = row_bg }));

            const title_style = if (selected)
                style(colors.focus, .{ .bg = row_bg, .bold = true })
            else
                style(colors.fg, .{ .bg = row_bg });
            // Clipped to its column budget so long titles can't bleed into meta.
            putClipped(win, row, title_col, title_w, rec.title, title_style);

            // Format into App-owned scratch (see meta_scratch's note on why a
            // stack buffer would dangle by render time). Skip if we somehow have
            // more visible rows than slots.
            if (show_meta and slot < self.meta_scratch.len) {
                const meta = formatMeta(&self.meta_scratch[slot], rec);
                putClipped(win, row, meta_col, w - meta_col, meta, style(colors.fg3, .{ .bg = row_bg }));
                slot += 1;
            }

            row += 1;
        }
    }

    fn drawBottomBar(self: *App, win: vaxis.Window, h: u16) void {
        const w = win.width;
        const row = h - 1;
        // The signature: a magenta block cursor, terminal-blinked, always alive.
        put(win, row, 2, "▌", style(colors.hot, .{ .blink = true }));

        const help = if (self.history.len == 0)
            "q quit"
        else
            "j/k move · g/G top/bottom · q quit";
        putClipped(win, row, 4, if (w > 4) w - 4 else 0, help, style(colors.fg3, .{}));
    }

    fn scrollIntoView(self: *App, visible: u16) void {
        const v: usize = visible;
        if (self.list_cursor < self.list_top) {
            self.list_top = self.list_cursor;
        } else if (self.list_cursor >= self.list_top + v) {
            self.list_top = self.list_cursor + 1 - v;
        }
    }
};

/// "ep 3/12 · watching" — whatever we actually know. total_episodes can be null
/// (source didn't say), in which case we drop the denominator.
fn formatMeta(buf: []u8, rec: AnimeRecord) []const u8 {
    if (rec.total_episodes) |total| {
        return std.fmt.bufPrint(buf, "ep {d}/{d} · {s}", .{ rec.progress, total, rec.list_status }) catch rec.list_status;
    }
    return std.fmt.bufPrint(buf, "ep {d} · {s}", .{ rec.progress, rec.list_status }) catch rec.list_status;
}

// ── tiny render helpers ─────────────────────────────────────────────────────

fn put(win: vaxis.Window, row: u16, col: u16, text: []const u8, sty: vaxis.Style) void {
    _ = win.printSegment(.{ .text = text, .style = sty }, .{ .row_offset = row, .col_offset = col });
}

/// Like `put`, but clipped to `max_w` columns via a 1-row child window. The
/// child bounds stop a long string from bleeding past its column budget into a
/// neighbour (and the clip lands on a grapheme boundary, so multibyte titles
/// stay valid). max_w == 0 draws nothing.
fn putClipped(win: vaxis.Window, row: u16, col: u16, max_w: u16, text: []const u8, sty: vaxis.Style) void {
    if (max_w == 0) return;
    const child = win.child(.{ .x_off = @intCast(col), .y_off = @intCast(row), .width = max_w, .height = 1 });
    _ = child.printSegment(.{ .text = text, .style = sty }, .{});
}

/// Paint a full-width 1-row band in `bg` — the focused-row background shift.
fn fillRow(win: vaxis.Window, row: u16, w: u16, bg: vaxis.Color) void {
    const child = win.child(.{ .x_off = 0, .y_off = @intCast(row), .width = w, .height = 1 });
    child.fill(.{ .style = .{ .bg = bg } });
}

/// Horizontally centre an ASCII string on `row` (byte length == display width
/// for the ASCII copy this is used with).
fn centerText(win: vaxis.Window, row: u16, w: u16, text: []const u8, sty: vaxis.Style) void {
    const tw: u16 = @intCast(text.len);
    const col: u16 = if (w > tw) (w - tw) / 2 else 0;
    putClipped(win, row, col, w, text, sty);
}

// History-row layout columns. The detail/responsive layout is ROD-72+; this is
// the fixed two-column (title | meta) skeleton.
const title_col: u16 = 4;
const meta_col: u16 = 48;
const title_meta_gap: u16 = 2;

// One style constructor for foreground-on-(void|surface) cells. bg defaults to
// the void so most call sites stay terse; the focused list row passes bg.surface
// to get §4.1's background shift.
fn style(fg: vaxis.Color, opts: struct {
    bg: vaxis.Color = colors.bg_base,
    bold: bool = false,
    italic: bool = false,
    blink: bool = false,
}) vaxis.Style {
    return .{ .fg = fg, .bg = opts.bg, .bold = opts.bold, .italic = opts.italic, .blink = opts.blink };
}

// ── tests: the App state machine (no tty needed) ────────────────────────────

const testing = std.testing;

fn keyEv(cp: u21, mods: vaxis.Key.Modifiers) Event {
    return .{ .key_press = .{ .codepoint = cp, .mods = mods } };
}

fn sampleHistory() [3]AnimeRecord {
    return .{
        .{ .source = "allanime", .source_id = "a", .title = "Frieren", .total_episodes = 28, .progress = 4 },
        .{ .source = "allanime", .source_id = "b", .title = "K-On!", .total_episodes = 13, .progress = 1 },
        .{ .source = "allanime", .source_id = "c", .title = "Bebop", .progress = 0 },
    };
}

test "history_loaded drains into state and clears loading" {
    var app: App = .{};
    try testing.expect(app.history_loading);
    var recs = sampleHistory();
    try app.tick(.{ .history_loaded = &recs });
    try testing.expect(!app.history_loading);
    try testing.expectEqual(@as(usize, 3), app.history.len);
}

test "j/k navigation stays in bounds" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    try testing.expectEqual(@as(usize, 0), app.list_cursor);

    try app.tick(keyEv('k', .{})); // up at top — pinned
    try testing.expectEqual(@as(usize, 0), app.list_cursor);

    try app.tick(keyEv('j', .{}));
    try app.tick(keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 2), app.list_cursor);

    try app.tick(keyEv('j', .{})); // down at bottom — pinned
    try testing.expectEqual(@as(usize, 2), app.list_cursor);

    try app.tick(keyEv('k', .{}));
    try testing.expectEqual(@as(usize, 1), app.list_cursor);
}

test "g/G jump to ends" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    try app.tick(keyEv('G', .{}));
    try testing.expectEqual(@as(usize, 2), app.list_cursor);
    try app.tick(keyEv('g', .{}));
    try testing.expectEqual(@as(usize, 0), app.list_cursor);
}

test "quit keys: q, Esc, Ctrl-C" {
    for ([_]Event{
        keyEv('q', .{}),
        keyEv(vaxis.Key.escape, .{}),
        keyEv('c', .{ .ctrl = true }),
    }) |ev| {
        var app: App = .{};
        try testing.expect(!app.should_quit);
        try app.tick(ev);
        try testing.expect(app.should_quit);
    }
}

test "navigation is a no-op with empty history" {
    var app: App = .{};
    app.setHistory(&.{});
    try app.tick(keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 0), app.list_cursor);
    try testing.expect(!app.should_quit);
}

test "setHistory clamps an out-of-range cursor" {
    var app: App = .{};
    app.list_cursor = 99;
    var recs = sampleHistory();
    app.setHistory(&recs);
    try testing.expectEqual(@as(usize, 2), app.list_cursor);
    app.setHistory(&.{});
    try testing.expectEqual(@as(usize, 0), app.list_cursor);
}

test "scrollIntoView keeps the cursor within the viewport" {
    var app: App = .{};
    // 10 rows, viewport of 4.
    app.list_cursor = 7;
    app.list_top = 0;
    app.scrollIntoView(4);
    try testing.expect(app.list_cursor >= app.list_top);
    try testing.expect(app.list_cursor < app.list_top + 4);
    // Cursor moves back above the window → window follows up.
    app.list_cursor = 2;
    app.scrollIntoView(4);
    try testing.expectEqual(@as(usize, 2), app.list_top);
}

test "formatMeta degrades when total episodes is unknown" {
    var buf: [48]u8 = undefined;
    const known = formatMeta(&buf, .{ .source = "s", .source_id = "i", .title = "T", .total_episodes = 12, .progress = 3, .list_status = "watching" });
    try testing.expectEqualStrings("ep 3/12 · watching", known);
    var buf2: [48]u8 = undefined;
    const unknown = formatMeta(&buf2, .{ .source = "s", .source_id = "i", .title = "T", .progress = 0, .list_status = "planning" });
    try testing.expectEqualStrings("ep 0 · planning", unknown);
}
