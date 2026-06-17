//! Zigoku — persistent chrome render passes (top bar, bottom bar, toasts).
//! Extracted from app.zig along the tick/draw seam (ROD-144). These are the
//! frame around the content area, drawn on every view.

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const render = @import("../render.zig");

const App = app_mod.App;
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

    // Render the chip after the separator (§10.3b).
    const chip_col: u16 = 16;
    const chip: []const u8 = switch (self.active_view) {
        .history => "Watchlist",
        .detail => switch (self.detail_origin) {
            .browse => std.fmt.bufPrint(&self.chip_buf, "{s} search", .{self.spinnerChar()}) catch "⠋ search",
            .history => "Watchlist",
        },
        .settings => "Settings",
        .browse => std.fmt.bufPrint(&self.chip_buf, "{s} search", .{self.spinnerChar()}) catch "⠋ search",
    };
    put(win, 0, chip_col, chip, self.s(self.palette.focus, .{}));

    // Render the · indicator right-aligned (§10.3b).
    const dot_color = switch (self.active_view) {
        .browse => if (self.active_pane == .detail) self.palette.focus else self.palette.fg3,
        .history, .detail, .settings => self.palette.focus,
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
    const any_loading = self.search_loading or self.history_loading or
        self.episode_loading or self.cover.loading or self.debounce_deadline_ms > 0;
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
            .detail => "hjkl scroll · h back · enter play · q back",
        },
        .history => if (self.history.len == 0)
            "/ search · F1 browse · q quit"
        else
            "jk move · enter open · F1 browse · F3 settings · q quit",
        .detail => "hjkl scroll · h back · enter play · q back",
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
        const t = self.toast_queue[qi] orelse continue;
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
        // §4.7: right-aligned, max 40 display columns.
        // All prefixes are exactly 4 display cells regardless of UTF-8 byte length
        // ([✓] = 6 bytes but 4 cells; ASCII variants are 4 bytes = 4 cells).
        const pre_w: u16 = 4;
        const txt_len: u16 = @intCast(t.text_len);
        const toast_w: u16 = @min(pre_w + txt_len, @min(40, w -| 2));
        const pre_col: u16 = if (w > toast_w + 1) w - toast_w - 1 else 0;
        fillRow(win, row, w, self.palette.bg_elevated);
        put(win, row, pre_col, prefix, self.s(fg_color, .{ .bold = true, .bg = self.palette.bg_elevated }));
        const txt_col: u16 = pre_col + pre_w;
        const txt_w: u16 = if (toast_w > pre_w) toast_w - pre_w else 0;
        putClipped(win, row, txt_col, txt_w, t.text[0..t.text_len], self.s(fg_color, .{ .bg = self.palette.bg_elevated }));
        row -|= 1;
    }
}
