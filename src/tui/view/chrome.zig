//! Persistent chrome: top bar, bottom bar, toasts (ROD-144). Frame around content.

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const render = @import("../render.zig");

const App = app_mod.App;
const Toast = app_mod.Toast;
const put = render.put;
const putClipped = render.putClipped;
const fillRow = render.fillRow;

/// §3.4: top bar is read-only context (`地獄 zigoku` + hairline). Tab focus is ROD-72.
pub fn drawTopBar(self: *App, win: vaxis.Window, w: u16) void {
    put(win, 0, 2, "地獄 zigoku", self.s(self.palette.fg, .{ .bold = true }));
    if (w > 16) put(win, 0, 14, "░", self.s(self.palette.chrome, .{}));

    // Tab strip (§3.4/§10.3b, ROD-250): bracketed view keys; zoom follows detail_origin.
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
    // Width tiers (§3.4): full ≥64, keys-only ≥40, single label below.
    const full = w >= 64;
    var col: u16 = strip_col;
    if (w >= 40) {
        for (keys, labels, 0..) |keyhint, label, i| {
            const on = i == active_idx;
            // Inactive [X] at fg2 (muted), not dim (near-invisible on bg_base).
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
        // Too narrow: single active label.
        const single = [_][]const u8{ "Browse", "History", "Discover", "Settings" };
        put(win, 0, strip_col, single[active_idx], self.s(self.palette.focus, .{ .bold = true }));
    }

    // Season chip after full strip only (ROD-186/247). Drops first under width pressure.
    if (full) {
        const season = self.topBarSeasonChip();
        if (season.len > 0) {
            // kanji: 3 bytes / 2 cells → display width = len - 1.
            const season_w: u16 = @as(u16, @intCast(season.len)) - 1;
            const season_col: u16 = col + 2;
            if (w > season_col + season_w + 4) {
                put(win, 0, season_col, season, self.s(self.palette.fg2, .{}));
            }
        }
    }

    // Right · (§10.3b). Two-pane dims on list focus (ROD-170); single-pane stays lit.
    const dot_color = switch (self.active_view) {
        .browse, .history => if (self.active_pane == .detail) self.palette.focus else self.palette.fg3,
        // Single-pane (Discover full-canvas, ROD-239).
        .detail, .settings, .discover => self.palette.focus,
    };
    if (w > 2) put(win, 0, w - 2, "·", self.s(dot_color, .{}));
}

// §10.5 help: keybind runs bold fg2, words fg3. INVARIANT: concat of `t` = flat string (test).
const HelpSeg = struct { t: []const u8, bold: bool };
fn key(t: []const u8) HelpSeg {
    return .{ .t = t, .bold = true };
}
fn txt(t: []const u8) HelpSeg {
    return .{ .t = t, .bold = false };
}

const help_browse_list = [_]HelpSeg{ key("hjkl"), txt(" · "), key("/"), txt(" find anime · "), key("P"), txt(" save · "), key("q"), txt(" quit") };
// Browse/History detail focus: two-pane grammar (ROD-170/259).
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

    // ROD-220 delete confirm: whole bar is the danger prompt; input frozen.
    if (self.confirm_delete) |idx| {
        if (idx < self.history.len) {
            const title = self.history[idx].title;
            var col: u16 = 1;

            // Danger glyph replaces ▌.
            putClipped(win, row, col, w -| col, "[!] ", self.s(self.palette.hot, .{ .bold = true }));
            col += 4;
            const pre = "delete \"";
            putClipped(win, row, col, w -| col, pre, self.s(self.palette.fg2, .{}));
            col += @intCast(pre.len);

            // Title budget after fixed tail (app_test drift-guards tail_cols).
            const tail_cols: u16 = 48;
            const budget: u16 = (w -| col) -| tail_cols;
            const shown: []const u8 = if (vaxis.gwidth.gwidth(title, .unicode) <= budget)
                title
            else
                render.truncateToWidth(&self.confirm_scratch, title, budget);
            putClipped(win, row, col, w -| col, shown, self.s(self.palette.fg, .{ .bold = true }));
            col += @intCast(vaxis.gwidth.gwidth(shown, .unicode));

            // Tail pieces. `·` is 1 display col (advance by 1, not .len).
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

    // Browse search: /query_ + count.
    if (self.active_view == .browse and self.input_mode == .search) {
        const q = self.search.querySlice();
        put(win, row, 1, "/", self.s(self.palette.focus, .{ .bold = true }));
        const cursor_col: u16 = 2 + @as(u16, @intCast(q.len));
        if (q.len > 0) {
            putClipped(win, row, 2, cursor_col -| 2, q, self.s(self.palette.fg, .{ .bold = true }));
        }
        if (cursor_col < w) put(win, row, cursor_col, "_", self.s(self.palette.focus, .{ .bold = true }));
        // Right-aligned count (§3.5 muted).
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
            // Suppress count if it would collide with the cursor.
            if (cnt_col > cursor_col + 1) {
                putClipped(win, row, cnt_col, @as(u16, @intCast(cnt.len)), cnt, self.s(self.palette.fg2, .{}));
            }
        }
        return;
    }

    // History search: /filter_ + count.
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

    // Loading (incl. playing, §4.10): spinner replaces ▌.
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
        // §3.7: cursor at col 1.
        put(win, row, 1, "▌", self.s(self.palette.hot, .{ .blink = true }));
    }

    const help: []const HelpSeg = switch (self.active_view) {
        .browse => switch (self.active_pane) {
            .list => &help_browse_list,
            .detail => &help_detail_pane,
        },
        // ROD-170: History two-pane; list keeps ROD-139 status keys.
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
    // §3.7: help starts col 3. Advance by gwidth (`·` is 1 cell).
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
    // Newest-first so most recent anchors at h-2.
    var qi: usize = self.toast_queue.len;
    while (qi > 0) {
        qi -= 1;
        // Pointer into toast_queue, never a value copy: vaxis Cell.char slices the text we
        // hand printSegment; a stack copy dies before tty flush. App-owned [80]u8 stays live
        // until tick() nils the slot (after this draw's vx.render).
        const t = if (self.toast_queue[qi]) |*slot| slot else continue;
        if (row < 1) break;
        // §4.7 color map.
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
        // §4.7: success/error bold on glyph+body; info/warn plain (ROD-163).
        const bold = switch (t.kind) {
            .success, .@"error" => true,
            .info, .warn => false,
        };
        const w = win.width;
        // §4.7 right-align, max_box_cols. Copy pre-truncated in pushToast (ROD-166).
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

// ROD-387: concat of help segments must equal the flat §10.5 string.
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
