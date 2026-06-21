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

    // The view-label chip after the separator (§10.3b). ROD-186: Browse's old
    // `⠋ search` spinner stub retires — search status lives in the bottom bar — so
    // every view now reads a static identity chip in state.focus.
    const chip_col: u16 = 16;
    const chip: []const u8 = switch (self.active_view) {
        .history => "Watchlist",
        .detail => switch (self.detail_origin) {
            .browse => "Browse",
            .history => "Watchlist",
        },
        .settings => "Settings",
        .browse => "Browse",
    };
    put(win, 0, chip_col, chip, self.s(self.palette.focus, .{}));

    // ROD-186: the season/year chip rides two spaces after the view label, in
    // text.muted (fg2) so it reads as metadata beside the cyan identity chip and
    // never competes with the cyan `·` dot at the right edge (Mira header ruling).
    // Content (App.topBarSeasonChip): the selected show's season+year, falling back
    // to the current cour; "" in Settings and for unenriched shows in the zoom.
    const season = self.topBarSeasonChip();
    if (season.len > 0) {
        // chip is ASCII; one kanji is 3 bytes / 2 display cells, so display width
        // is byte len minus the kanji's extra byte.
        const season_w: u16 = @as(u16, @intCast(season.len)) - 1;
        const season_col: u16 = chip_col + @as(u16, @intCast(chip.len)) + 2;
        // Drop the chip before it would crowd the `·` at w-2 (keep ≥3 cells of air).
        if (w > season_col + season_w + 4) {
            put(win, 0, season_col, season, self.s(self.palette.fg2, .{}));
        }
    }

    // Render the · indicator right-aligned (§10.3b). ROD-170: History is now a
    // two-pane view, so it dims on list focus / lights on detail focus exactly
    // like Browse. The zoom (.detail) and single-pane Settings stay lit.
    const dot_color = switch (self.active_view) {
        .browse, .history => if (self.active_pane == .detail) self.palette.focus else self.palette.fg3,
        .detail, .settings => self.palette.focus,
    };
    if (w > 2) put(win, 0, w - 2, "·", self.s(dot_color, .{}));
}

pub fn drawBottomBar(self: *App, win: vaxis.Window, h: u16) void {
    const w = win.width;
    const row = h - 1;

    // Search mode in Browse: suppress ▌, show /query_ + count.
    if (self.active_view == .browse and self.input_mode == .search) {
        const q = self.querySlice();
        put(win, row, 1, "/", self.s(self.palette.focus, .{ .bold = true }));
        const cursor_col: u16 = 2 + @as(u16, @intCast(q.len));
        if (q.len > 0) {
            putClipped(win, row, 2, cursor_col -| 2, q, self.s(self.palette.fg, .{ .bold = true }));
        }
        if (cursor_col < w) put(win, row, cursor_col, "_", self.s(self.palette.focus, .{ .bold = true }));
        // Right-aligned count (text.muted = fg2 per §3.5).
        const cnt: []const u8 = if ((self.search_loading or self.debounce_deadline_ms > 0) and self.results.items.len == 0)
            "…"
        else if (self.results.items.len > 0)
            std.fmt.bufPrint(&self.cnt_scratch, "[{d} results]", .{self.results.items.len}) catch ""
        else if (self.search_len > 0)
            "[0 results]"
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
            std.fmt.bufPrint(&self.cnt_scratch, "[{d}]", .{n}) catch ""
        else
            "[0]";
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
    const any_loading = self.search_loading or self.history_loading or
        self.episodes.loading or self.cover.loading or self.debounce_deadline_ms > 0 or
        self.playing;
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

    const help: []const u8 = switch (self.active_view) {
        .browse => switch (self.active_pane) {
            .list => "hjkl · / search · F1/F2/F3 views · q quit",
            // ROD-170: detail pane can promote to the full-screen zoom with Space.
            .detail => "hjkl scroll · h back · enter play · space zoom · q back",
        },
        // ROD-170: History is a two-pane like Browse. List focus keeps the
        // ROD-139 watch-state transitions (p/x/c/w); detail focus mirrors the
        // Browse detail line, adding the Space zoom only where the grid lives
        // (>= zoom_min) — in the 60-99 preview band there is nothing to play/zoom.
        .history => if (self.history.len == 0)
            "/ search · F1 browse · q quit"
        else switch (self.active_pane) {
            .list => "jk move · l/enter detail · p/x/c/w status · F1/F2/F3 · q quit",
            // At >= zoom_min the grid is in-pane (enter plays); in the 60-99
            // preview band there is no grid, so enter/space drill into the zoom.
            .detail => if (w >= App.zoom_min)
                "hjkl scroll · h back · enter play · space zoom · q back"
            else
                "enter/space zoom · h back · q back",
        },
        // The full-screen zoom: Space or Esc demote back to the pane; q backs out.
        .detail => "hjkl scroll · enter play · space/esc back · q back",
        .settings => if (self.settings.editing)
            "type to edit · enter confirm · esc cancel"
        else
            "hjkl navigate · space toggle · enter edit · esc cancel · q save & back",
    };
    putClipped(win, row, 3, if (w > 3) w - 3 else 0, help, self.s(self.palette.fg3, .{}));
}

pub fn drawToasts(self: *App, win: vaxis.Window, h: u16) void {
    if (h < 4) return;
    var row: u16 = h -| 2;
    // Iterate newest-first (index 2→0) so the most recent toast anchors at h-2.
    var qi: usize = self.toast_queue.len;
    while (qi > 0) {
        qi -= 1;
        // Borrow the queue slot by pointer, never a value copy: vaxis stores the
        // grapheme as a *slice* into the text we hand `printSegment` (Cell.char
        // is []const u8, not an owned buffer), and the tty flush dereferences it
        // after every draw pass has returned. A `const t = slot.* orelse …` copy
        // would back those cells with this function's stack frame, which is dead
        // (and partially overwritten — "epi" survives, the tail rots) by flush.
        // `text` is an inline [80]u8 in the App-owned toast_queue, so the grapheme
        // sub-slices stay valid until the next tick() nils the slot — well after
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
        put(win, row, pre_col, prefix, self.s(fg_color, .{ .bold = true, .bg = self.palette.bg_elevated }));
        const txt_col: u16 = pre_col + pre_w;
        const txt_w: u16 = if (toast_w > pre_w) toast_w - pre_w else 0;
        putClipped(win, row, txt_col, txt_w, t.text[0..t.text_len], self.s(fg_color, .{ .bg = self.palette.bg_elevated }));
        row -|= 1;
    }
}
