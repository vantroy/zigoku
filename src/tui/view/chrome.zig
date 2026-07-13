//! Zigoku — persistent chrome render passes (top bar, bottom bar, toasts).
//! Extracted from app.zig along the tick/draw seam (ROD-144). These are the
//! frame around the content area, drawn on every view.

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const render = @import("../render.zig");

const App = app_mod.App;
const Toast = app_mod.Toast;
const put = render.put;
const putClipped = render.putClipped;
const fillRow = render.fillRow;

/// §3.4: the top bar is read-only context, not navigation — `地獄 zigoku`
/// as one primary H1 unit, then a hairline separator. No tabs here: the tab
/// system + focus model is ROD-72 and needs a designed home (the active-tab
/// cyan would collide with the focus color if it lived in this bar).
pub fn drawTopBar(self: *App, win: vaxis.Window, w: u16) void {
    put(win, 0, 2, "地獄 zigoku", self.s(self.palette.fg, .{ .bold = true }));
    if (w > 16) put(win, 0, 14, "░", self.s(self.palette.chrome, .{}));

    // View tab strip after the separator (§3.4/§10.3b, ROD-250): all four views,
    // the active one highlighted, each bracketing its view-switch key — the same
    // passive idiom as the §3.8 axis bar (no tab focus model; the bracketed
    // letters just fire the existing normal-mode binds). In the zoom the active tab
    // follows detail_origin, so it still reads "where you came from". Every segment
    // is a static literal — no scratch lifetime concern.
    const strip_col: u16 = 16;
    const active_idx: usize = switch (self.active_view) {
        .browse => 0,
        .history => 1,
        .discover => 2,
        .settings => 3,
        .detail => switch (self.detail_origin) {
            .browse => 0,
            .history => 1,
            .discover => 2,
        },
    };
    const keys = [_][]const u8{ "[B]", "[H]", "[D]", "[S]" };
    const labels = [_][]const u8{ "rowse", "istory", "iscover", "ettings" };
    // Width tiers (§3.4): the full strip (cols 16–61) must clear the right `·`;
    // below w=64 abbreviate to the bracketed keys only; below w=40, a single label.
    const full = w >= 64;
    var col: u16 = strip_col;
    if (w >= 40) {
        for (keys, labels, 0..) |keyhint, label, i| {
            const on = i == active_idx;
            // The bracketed key is the whole point of the strip, so an inactive
            // `[X]` reads at text.muted (fg2) — NOT text.dim, which is near-invisible
            // against bg_base and buries the very hint we're teaching. Abbreviated:
            // the bracket carries the active weight (no label follows). Full: the
            // bracket stays plain focus and the label carries the bold.
            const key_sty = if (on) self.s(self.palette.focus, .{ .bold = !full }) else self.s(self.palette.fg2, .{});
            put(win, 0, col, keyhint, key_sty);
            col += @as(u16, @intCast(keyhint.len));
            if (full) {
                const label_sty = if (on) self.s(self.palette.focus, .{ .bold = true }) else self.s(self.palette.fg2, .{});
                put(win, 0, col, label, label_sty);
                col += @as(u16, @intCast(label.len));
            }
            if (i + 1 < keys.len) {
                put(win, 0, col + 1, "·", self.s(self.palette.fg3, .{}));
                col += 3;
            }
        }
    } else {
        // Too narrow for the strip — fall back to the single active label.
        const single = [_][]const u8{ "Browse", "History", "Discover", "Settings" };
        put(win, 0, strip_col, single[active_idx], self.s(self.palette.focus, .{ .bold = true }));
    }

    // Season/year chip two cells after the full strip, in text.muted (ROD-186) —
    // metadata beside the strip, never crowding the right `·`. Only in the full
    // strip (it drops first under width pressure). Content via topBarSeasonChip:
    // the selected show's season+year, current-cour fallback for list views, the
    // focused show's season in the zoom; the selected card's season in Discover once
    // enriched (ROD-247); "" in Settings.
    if (full) {
        const season = self.topBarSeasonChip();
        if (season.len > 0) {
            // one kanji is 3 bytes / 2 display cells, so display width = len - 1.
            const season_w: u16 = @as(u16, @intCast(season.len)) - 1;
            const season_col: u16 = col + 2;
            if (w > season_col + season_w + 4) {
                put(win, 0, season_col, season, self.s(self.palette.fg2, .{}));
            }
        }
    }

    // Render the · indicator right-aligned (§10.3b). ROD-170: History is now a
    // two-pane view, so it dims on list focus / lights on detail focus exactly
    // like Browse. The zoom (.detail) and single-pane Settings stay lit.
    const dot_color = switch (self.active_view) {
        .browse, .history => if (self.active_pane == .detail) self.palette.focus else self.palette.fg3,
        // Single-pane surfaces keep the dot lit (Discover is full-canvas, ROD-239).
        .detail, .settings, .discover => self.palette.focus,
    };
    if (w > 2) put(win, 0, w - 2, "·", self.s(dot_color, .{}));
}

// §10.5 idle help line: a run of text with the keybind characters promoted.
// `bold` runs render fg2 + bold (the keybind chars); the rest render fg3. Splitting
// the line into explicit runs (rather than parsing keys out of the string) is what
// lets multi-char keys (`enter`/`space`/`esc`) and key letters buried in words
// (`find`, `back`) land on the right emphasis. Concatenating each array's `t` fields
// reproduces the flat string, so width and wording are unchanged from the pre-split
// render, so only the per-key styling is new.
const HelpSeg = struct { t: []const u8, bold: bool };
fn key(t: []const u8) HelpSeg {
    return .{ .t = t, .bold = true };
}
fn txt(t: []const u8) HelpSeg {
    return .{ .t = t, .bold = false };
}

const help_browse_list = [_]HelpSeg{ key("hjkl"), txt(" · "), key("/"), txt(" find anime · "), key("P"), txt(" save · "), key("q"), txt(" quit") };
// Shared by Browse detail-focus and History detail-focus: symmetric two-pane
// grammar (ROD-170), and the in-pane grid renders at every two-pane width
// (ROD-259), so `enter` plays and `space` promotes to the zoom.
const help_detail_pane = [_]HelpSeg{ key("hjkl"), txt(" scroll · "), key("h"), txt(" back · "), key("enter"), txt(" play · "), key("v"), txt(" provider · "), key("space"), txt(" zoom · "), key("q"), txt(" quit") };
const help_history_empty = [_]HelpSeg{ key("D"), txt(" discover · "), key("B"), txt(" browse · "), key("q"), txt(" quit") };
const help_history_list = [_]HelpSeg{ key("jk"), txt(" move · "), key("/"), txt(" filter · "), key("l"), txt("/"), key("enter"), txt(" detail · "), key("p"), txt("/"), key("x"), txt("/"), key("c"), txt("/"), key("w"), txt("/"), key("P"), txt(" status · "), key("X"), txt(" delete · "), key("r"), txt("/"), key("u"), txt(" reset/undo · "), key("q"), txt(" quit") };
const help_zoom = [_]HelpSeg{ key("hjkl"), txt(" scroll · "), key("enter"), txt(" play · "), key("v"), txt(" provider · "), key("space"), txt("/"), key("esc"), txt(" back · "), key("q"), txt(" quit") };
const help_discover = [_]HelpSeg{ key("hjkl"), txt(" move · "), key("enter"), txt(" open · "), key("P"), txt(" save · "), key("["), txt(" "), key("]"), txt(" axis · "), key("/"), txt(" search · "), key("q"), txt(" quit") };
const help_settings_edit = [_]HelpSeg{ txt("type to edit · "), key("enter"), txt(" confirm · "), key("esc"), txt(" cancel") };
const help_settings = [_]HelpSeg{ key("hjkl"), txt(" navigate · "), key("space"), txt(" toggle · "), key("enter"), txt(" edit · "), key("q"), txt(" save+quit") };

pub fn drawBottomBar(self: *App, win: vaxis.Window, h: u16) void {
    const w = win.width;
    const row = h - 1;

    // ROD-220 hard-delete confirm: a third bottom-bar mode alongside normal/search.
    // Replace the whole bar with the danger prompt; the ▌ is suppressed (input is
    // frozen behind the confirm). `input_mode` stays .normal while armed, so the
    // search branches below never fire concurrently.
    if (self.confirm_delete) |idx| {
        if (idx < self.history.len) {
            const title = self.history[idx].title;
            var col: u16 = 1;

            // "[!] " danger glyph in state.now, replacing the ▌ (the toast [!] glyph).
            putClipped(win, row, col, w -| col, "[!] ", self.s(self.palette.hot, .{ .bold = true }));
            col += 4;
            const pre = "delete \"";
            putClipped(win, row, col, w -| col, pre, self.s(self.palette.fg2, .{}));
            col += @intCast(pre.len);

            // Title (text.primary + bold) gets the width left after the fixed tail, so
            // the y/esc hints stay on-screen; "…"-truncate when the title overruns.
            // Display width of the fixed seg1..cancel tail rendered below. A drift
            // guard test (app_test.zig "confirm tail width matches ...") fails if the
            // tail wording changes without bumping this.
            const tail_cols: u16 = 48;
            const budget: u16 = (w -| col) -| tail_cols;
            const shown: []const u8 = if (vaxis.gwidth.gwidth(title, .unicode) <= budget)
                title
            else
                render.truncateToWidth(&self.confirm_scratch, title, budget);
            putClipped(win, row, col, w -| col, shown, self.s(self.palette.fg, .{ .bold = true }));
            col += @intCast(vaxis.gwidth.gwidth(shown, .unicode));

            // Tail in pieces: the y/esc keybind hints take the app's hint treatment
            // (hot/fg2 + bold; there is no underline style token, and the ROD-220
            // "underline" wording is deferred to the DESIGN doc). `·` is 2 bytes /
            // 1 display column, so advance col by 1 for it, not by .len.
            const seg1 = "\"? episode history gone ";
            putClipped(win, row, col, w -| col, seg1, self.s(self.palette.fg2, .{}));
            col += @intCast(seg1.len);
            putClipped(win, row, col, w -| col, "· ", self.s(self.palette.fg3, .{}));
            col += 2;
            putClipped(win, row, col, w -| col, "y", self.s(self.palette.hot, .{ .bold = true }));
            col += 1;
            putClipped(win, row, col, w -| col, " confirm ", self.s(self.palette.fg2, .{}));
            col += 9;
            putClipped(win, row, col, w -| col, "· ", self.s(self.palette.fg3, .{}));
            col += 2;
            putClipped(win, row, col, w -| col, "esc", self.s(self.palette.fg2, .{ .bold = true }));
            col += 3;
            putClipped(win, row, col, w -| col, " cancel", self.s(self.palette.fg2, .{}));
        }
        return;
    }

    // Search mode in Browse: suppress ▌, show /query_ + count.
    if (self.active_view == .browse and self.input_mode == .search) {
        const q = self.search.querySlice();
        put(win, row, 1, "/", self.s(self.palette.focus, .{ .bold = true }));
        const cursor_col: u16 = 2 + @as(u16, @intCast(q.len));
        if (q.len > 0) {
            putClipped(win, row, 2, cursor_col -| 2, q, self.s(self.palette.fg, .{ .bold = true }));
        }
        if (cursor_col < w) put(win, row, cursor_col, "_", self.s(self.palette.focus, .{ .bold = true }));
        // Right-aligned count (text.muted = fg2 per §3.5).
        const cnt: []const u8 = if ((self.search.loading or self.debounce_deadline_ms > 0) and self.search.results.items.len == 0)
            "…"
        else if (self.search.results.items.len > 0)
            std.fmt.bufPrint(&self.cnt_scratch, "[catalogue · {d}]", .{self.search.results.items.len}) catch ""
        else if (self.search.len > 0)
            "[catalogue · 0]"
        else
            "";
        if (cnt.len > 0) {
            const cnt_col: u16 = if (w > @as(u16, @intCast(cnt.len)) + 1) w - @as(u16, @intCast(cnt.len)) - 1 else 0;
            // Overlap guard: suppress count if it would collide with the cursor.
            if (cnt_col > cursor_col + 1) {
                putClipped(win, row, cnt_col, @as(u16, @intCast(cnt.len)), cnt, self.s(self.palette.fg2, .{}));
            }
        }
        return;
    }

    // Search mode in History: suppress ▌, show /filter_ + filtered count.
    if (self.active_view == .history and self.input_mode == .search) {
        const q = self.history_filter[0..self.history_filter_len];
        put(win, row, 1, "/", self.s(self.palette.focus, .{ .bold = true }));
        const cursor_col: u16 = 2 + @as(u16, @intCast(q.len));
        if (q.len > 0) {
            putClipped(win, row, 2, cursor_col -| 2, q, self.s(self.palette.fg, .{ .bold = true }));
        }
        if (cursor_col < w) put(win, row, cursor_col, "_", self.s(self.palette.focus, .{ .bold = true }));
        const n = self.filteredHistoryLen();
        const cnt: []const u8 = if (q.len == 0)
            ""
        else if (n > 0)
            std.fmt.bufPrint(&self.cnt_scratch, "[history · {d}]", .{n}) catch ""
        else
            "[history · 0]";
        if (cnt.len > 0) {
            const cnt_col: u16 = if (w > @as(u16, @intCast(cnt.len)) + 1) w - @as(u16, @intCast(cnt.len)) - 1 else 0;
            if (cnt_col > cursor_col + 1) {
                putClipped(win, row, cnt_col, @as(u16, @intCast(cnt.len)), cnt, self.s(self.palette.fg2, .{}));
            }
        }
        return;
    }

    // When anything is loading, replace the ▌ with an animated spinner.
    // §4.10: `playing` is the secondary signal — the episode-cell spinner (§4.6)
    // is the primary affordance — but folding it in keeps the ▌ from sitting idle
    // while playback resolves, and gives the bar one coherent busy story.
    const any_loading = self.search.loading or self.history_loading or
        self.episodes.loading or self.cover.loading or self.debounce_deadline_ms > 0 or
        self.playing or self.discover.activeSlot().loading;
    if (any_loading) {
        const spin_color: vaxis.Color = if (self.isSlowPath())
            self.palette.hot
        else
            self.palette.focus;
        put(win, row, 1, self.spinnerChar(), self.s(spin_color, .{}));
    } else {
        // §3.7: 1-cell left padding within the bar → cursor at col 1.
        put(win, row, 1, "▌", self.s(self.palette.hot, .{ .blink = true }));
    }

    const help: []const HelpSeg = switch (self.active_view) {
        .browse => switch (self.active_pane) {
            .list => &help_browse_list,
            .detail => &help_detail_pane,
        },
        // ROD-170: History is a two-pane like Browse. List focus keeps the
        // ROD-139 watch-state transitions (p/x/c/w); detail focus mirrors Browse.
        .history => if (self.history.len == 0)
            &help_history_empty
        else switch (self.active_pane) {
            .list => &help_history_list,
            .detail => &help_detail_pane,
        },
        .detail => &help_zoom,
        .discover => &help_discover,
        .settings => if (self.settings.editing) &help_settings_edit else &help_settings,
    };
    // §3.7: 1-cell left padding within the bar → keybind runs start at col 3.
    // `·` is 2 bytes / 1 display column, so advance by gwidth, not `.len`.
    var col: u16 = 3;
    for (help) |seg| {
        if (col >= w) break;
        const sty = if (seg.bold)
            self.s(self.palette.fg2, .{ .bold = true })
        else
            self.s(self.palette.fg3, .{});
        putClipped(win, row, col, w -| col, seg.t, sty);
        col += @intCast(vaxis.gwidth.gwidth(seg.t, .unicode));
    }
}

pub fn drawToasts(self: *App, win: vaxis.Window, h: u16) void {
    if (h < 4) return;
    var row: u16 = h -| 2;
    // Iterate newest-first (index 2→0) so the most recent toast anchors at h-2.
    var qi: usize = self.toast_queue.len;
    while (qi > 0) {
        qi -= 1;
        // Borrow the queue slot by pointer, never a value copy: vaxis stores the grapheme as
        // a SLICE into the text we hand `printSegment` (Cell.char is []const u8, not owned),
        // and the tty flush dereferences it after every draw pass returns. A `const t =
        // slot.* orelse …` copy would back those cells with this dead stack frame (partially
        // overwritten by flush). `text` is an inline [80]u8 in the App-owned toast_queue, so
        // the grapheme sub-slices stay valid until the next tick() nils the slot, well after
        // vx.render() consumes them in this same draw().
        const t = if (self.toast_queue[qi]) |*slot| slot else continue;
        if (row < 1) break;
        // §4.7 color map: info=[~] fg2(text.muted), success=[✓] fg(state.success),
        //   error=[!] hot, warn=[!] warn.
        const fg_color: vaxis.Color = switch (t.kind) {
            .@"error" => self.palette.hot,
            .warn => self.palette.warn,
            .success => self.palette.fg,
            .info => self.palette.fg2,
        };
        const prefix: []const u8 = switch (t.kind) {
            .@"error", .warn => "[!] ",
            .success => "[✓] ",
            .info => "[~] ",
        };
        // §4.7 styling table: success (state.success) and error (state.now) carry
        // bold across the whole toast — glyph *and* body; info/warn are plain.
        // Was prefix-only-bold for every kind (ROD-76), which under-bolded the
        // success/error bodies (ROD-163) and over-bolded the info/warn glyphs.
        // One foreground treatment per kind now. (The ticket cited "success only",
        // but §4.7 mandates bold for error too — the table is the source of truth.)
        const bold = switch (t.kind) {
            .success, .@"error" => true,
            .info, .warn => false,
        };
        const w = win.width;
        // §4.7: right-aligned, capped at Toast.max_box_cols display columns (the
        // box, glyph prefix included). All prefixes are exactly Toast.glyph_cols
        // display cells regardless of UTF-8 byte length ([✓] = 6 bytes but 4
        // cells; ASCII variants are 4 bytes = 4 cells). The copy is pre-truncated
        // to Toast.max_copy_cols in pushToast (ROD-166), so this clip is now just
        // the physical safety net.
        const pre_w: u16 = Toast.glyph_cols;
        const txt_len: u16 = @intCast(t.text_len);
        const toast_w: u16 = @min(pre_w + txt_len, @min(Toast.max_box_cols, w -| 2));
        const pre_col: u16 = if (w > toast_w + 1) w - toast_w - 1 else 0;
        fillRow(win, row, w, self.palette.bg_elevated);
        put(win, row, pre_col, prefix, self.s(fg_color, .{ .bold = bold, .bg = self.palette.bg_elevated }));
        const txt_col: u16 = pre_col + pre_w;
        const txt_w: u16 = if (toast_w > pre_w) toast_w - pre_w else 0;
        putClipped(win, row, txt_col, txt_w, t.text[0..t.text_len], self.s(fg_color, .{ .bold = bold, .bg = self.palette.bg_elevated }));
        row -|= 1;
    }
}

// ROD-387: the idle help line was split into per-keybind runs so the keys render
// bold; concatenating a run array's text back together must reproduce the flat
// string it replaced, so the visible wording and column budget (§10.5) are
// unchanged. A future edit that drifts a segment's wording or spacing trips this.
test "help segment arrays reproduce their §10.5 flat strings (ROD-387)" {
    const cases = .{
        .{ &help_browse_list, "hjkl · / find anime · P save · q quit" },
        .{ &help_detail_pane, "hjkl scroll · h back · enter play · v provider · space zoom · q quit" },
        .{ &help_history_empty, "D discover · B browse · q quit" },
        .{ &help_history_list, "jk move · / filter · l/enter detail · p/x/c/w/P status · X delete · r/u reset/undo · q quit" },
        .{ &help_zoom, "hjkl scroll · enter play · v provider · space/esc back · q quit" },
        .{ &help_discover, "hjkl move · enter open · P save · [ ] axis · / search · q quit" },
        .{ &help_settings_edit, "type to edit · enter confirm · esc cancel" },
        .{ &help_settings, "hjkl navigate · space toggle · enter edit · q save+quit" },
    };
    inline for (cases) |c| {
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        for (c[0]) |seg| {
            @memcpy(buf[len .. len + seg.t.len], seg.t);
            len += seg.t.len;
        }
        try std.testing.expectEqualStrings(c[1], buf[0..len]);
    }
}
