//! Zigoku — Browse view list render pass (search results).
//! Extracted from app.zig along the tick/draw seam (ROD-144).

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const render = @import("../render.zig");
const source_mod = @import("../../source.zig");

const App = app_mod.App;
const RenderScratch = app_mod.RenderScratch;
const put = render.put;
const putClipped = render.putClipped;
const fillRow = render.fillRow;
const centerText = render.centerText;

// `self` is `*const App`: this pass reads list state (cursor/viewport/results)
// and writes only `scratch` — the compiler proves it mutates no app state (ROD-155).
pub fn drawBrowseList(self: *const App, scratch: *RenderScratch, win: vaxis.Window, pane_h: u16, pane_w: u16) void {
    const w = pane_w;
    if (self.search_len == 0) {
        const mid = pane_h / 2;
        centerText(win, mid -| 1, w, "no feed yet", self.s(self.palette.fg3, .{ .italic = true }));
        const action = " to start a search";
        const total: u16 = 1 + @as(u16, @intCast(action.len));
        const start: u16 = if (w > total) (w - total) / 2 else 0;
        put(win, mid + 1, start, "/", self.s(self.palette.focus, .{ .bold = true }));
        putClipped(win, mid + 1, start + 1, w -| (start + 1), action, self.s(self.palette.fg2, .{}));
        return;
    }
    const search_pending = self.search_loading or self.debounce_deadline_ms > 0;
    if (search_pending and self.results.items.len == 0) {
        const spin_msg = std.fmt.bufPrint(&scratch.msg, "{s} searching\u{2026}", .{self.spinnerChar()}) catch "⠋ searching\u{2026}";
        centerText(win, pane_h / 2, w, spin_msg, self.s(self.palette.focus, .{}));
        return;
    }
    if (!search_pending and self.results.items.len == 0) {
        const q = self.querySlice();
        const msg = std.fmt.bufPrint(&scratch.msg, "no results for \"{s}\"", .{q}) catch "no results";
        putClipped(win, 0, 0, w, msg, self.s(self.palette.fg3, .{ .italic = true }));
        return;
    }

    // Results list — col offsets relative to list_win (no x=2 leading margin).
    // The viewport (list_top) is settled by app.layout() before this draw pass
    // (ROD-155); here we only read it.
    const list_title_col: u16 = 2; // marker is col 0–1, title starts at 2

    var row: u16 = 0;
    var slot: usize = 0;
    var i: usize = self.list_top;
    while (i < self.results.items.len and row < pane_h) : (i += 1) {
        const a = self.results.items[i];
        const selected = i == self.list_cursor;

        // ROD-194: the selection affordance (band + cyan-bold ▸/title) is earned only
        // when the list pane holds focus. With the detail pane focused the selected row
        // steps down — band drops, ▸ dims, title loses bold — mirroring History so the
        // active pane is unmistakable.
        const list_focused = self.active_pane == .list;
        const sel_focused = selected and list_focused;
        const row_bg = if (sel_focused) self.palette.bg_surface else self.palette.bg_base;
        if (sel_focused) fillRow(win, row, w, self.palette.bg_surface);

        const marker = if (selected) "▸ " else "  ";
        put(win, row, 0, marker, self.s(self.palette.focus, .{ .bg = row_bg, .dim = selected and !list_focused }));

        const title_style = if (selected)
            self.s(self.palette.focus, .{ .bg = row_bg, .bold = list_focused })
        else
            self.s(self.palette.fg, .{ .bg = row_bg });
        // Meta (eps) if pane is wide enough — rarely true in split view.
        const list_meta_col: u16 = 46;
        const show_list_meta = w >= list_meta_col + 8;
        // Title clips short enough to leave room for the meta column. The 2-char
        // gap (title_meta_gap) prevents the last title char from touching the first
        // meta char. Without this guard the title fills the full pane width and
        // its tail bleeds through the meta text (vaxis writes cells; later write wins).
        const title_w: u16 = if (show_list_meta)
            list_meta_col -| list_title_col -| 2
        else if (w > list_title_col) w - list_title_col else 0;
        putClipped(win, row, list_title_col, title_w, a.name, title_style);

        if (show_list_meta and slot < scratch.meta.len) {
            const tt = self.translation;
            const eps = if (tt == .dub) a.eps_dub else a.eps_sub;
            const meta = std.fmt.bufPrint(&scratch.meta[slot], "{d} {s}", .{ eps, tt.str() }) catch "";
            putClipped(win, row, list_meta_col, w - list_meta_col, meta, self.s(self.palette.fg3, .{ .bg = row_bg }));
            slot += 1;
        }
        row += 1;
    }

    // Load-more footer.
    if (row < pane_h and
        self.search_page > 0 and
        self.results.items.len % source_mod.search_page_size == 0 and
        self.results.items.len > 0)
    {
        const footer = if (self.search_loading) "⠋ loading…" else "╌ more ╌";
        const footer_color = if (self.search_loading) self.palette.focus else self.palette.fg3;
        centerText(win, row, w, footer, self.s(footer_color, .{}));
    }
}
