//! Zigoku — History (Watchlist) view list render pass.
//! Extracted from app.zig along the tick/draw seam (ROD-144). Driven by
//! app.drawContent's `.history` arm; reads state — the only mutation is scroll
//! viewport adjustment via the (still app-owned) scrollIntoView helper.

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const render = @import("../render.zig");

const App = app_mod.App;
const put = render.put;
const putClipped = render.putClipped;
const fillRow = render.fillRow;
const centerText = render.centerText;
const formatMeta = render.formatMeta;
const drawProgressBar = render.drawProgressBar;
const title_col = render.title_col;
const meta_col = render.meta_col;
const title_meta_gap = render.title_meta_gap;

/// Render the Watchlist list body. `top`/`visible`/`w`/`body_w` are the
/// content-area geometry computed by app.drawContent.
pub fn draw(self: *App, win: vaxis.Window, top: u16, visible: u16, w: u16, body_w: u16) void {
    // History view — existing list rendering.
    if (self.history_loading) {
        const hist_spin = std.fmt.bufPrint(&self.no_results_buf, "{s} loading history", .{self.spinnerChar()}) catch "⠋ loading history";
        putClipped(win, top, 2, body_w, hist_spin, self.s(self.palette.focus, .{}));
        return;
    }
    if (self.load_error) |msg| {
        // Hard failure → magenta (state.error = state.now, §1.1).
        put(win, top, 2, "history unavailable", self.s(self.palette.hot, .{ .bold = true }));
        putClipped(win, top + 1, 2, body_w, msg, self.s(self.palette.fg3, .{}));
        return;
    }
    if (self.history.len == 0) {
        // First-run empty state (§9.2): the void, one quiet line, one
        // invitation — both centered. `/` wires up in ROD-73.
        const mid = top + visible / 2;
        centerText(win, mid -| 1, w, "nothing here yet", self.s(self.palette.fg3, .{ .italic = true }));
        const action = " to search for a show";
        const total: u16 = 1 + @as(u16, @intCast(action.len));
        const start: u16 = if (w > total) (w - total) / 2 else 0;
        put(win, mid + 1, start, "/", self.s(self.palette.focus, .{ .bold = true }));
        putClipped(win, mid + 1, start + 1, w -| (start + 1), action, self.s(self.palette.fg2, .{}));
        return;
    }

    // Each history entry occupies 2 rows (title + progress bar).
    // @max(1, ...) guards against visible=1 producing a zero slot count
    // which would corrupt list_top via scrollIntoView's arithmetic.
    self.scrollIntoView(@max(1, visible / 2));

    // Meta only earns its column when the terminal is wide enough to hold it
    // without colliding the title — otherwise the title takes the full width.
    const show_meta = w >= meta_col + 12;
    const title_right: u16 = if (show_meta) meta_col - title_meta_gap else w;
    const title_w: u16 = if (title_right > title_col) title_right - title_col else 0;
    // Bar width: clamp to [16, 24] columns — saturating sub avoids underflow.
    const bar_w: u16 = @min(24, @max(16, w -| 20));

    var row: u16 = top;
    var slot: usize = 0;
    var visible_i: usize = 0;
    var i: usize = 0;
    while (i < self.history.len) : (i += 1) {
        const rec = self.history[i];
        if (!self.historyEntryVisible(rec.title)) continue;
        if (visible_i < self.list_top) {
            visible_i += 1;
            continue;
        }
        if (row + 1 >= top + visible) break;

        const selected = visible_i == self.list_cursor;

        // §4.1 focus affordance: the focused row's background shifts to
        // bg.surface (a full-width band), its marker is the ▸ play glyph in
        // focus cyan, and its title goes cyan+bold. Magenta is reserved for
        // the one cursor in the status bar — never a list marker (§8).
        const is_completed = std.mem.eql(u8, rec.list_status, "completed");
        const is_dropped = std.mem.eql(u8, rec.list_status, "dropped");
        const is_watching = std.mem.eql(u8, rec.list_status, "watching");
        const is_paused = std.mem.eql(u8, rec.list_status, "paused");

        const row_bg = if (selected) self.palette.bg_surface else self.palette.bg_base;
        if (selected) {
            fillRow(win, row, w, self.palette.bg_surface);
            fillRow(win, row + 1, w, self.palette.bg_surface);
        }

        // §2.4 watchlist status glyphs. Focus `▸` overrides when selected.
        // Colors: watching/paused=focus(+dim for paused), dropped=fg3, else fg2.
        const marker: []const u8 =
            if (selected or is_watching) "▸ " else if (is_completed) "● " else if (is_paused) "◐ " else if (is_dropped) "· " else "○ ";
        const marker_color =
            if (selected or is_watching or is_paused) self.palette.focus else if (is_dropped) self.palette.fg3 else self.palette.fg2;
        // §2.4: paused = state.focus + dim (SGR 2), but not when focused row.
        const marker_dim = is_paused and !selected;
        put(win, row, 2, marker, self.s(marker_color, .{ .bg = row_bg, .dim = marker_dim }));

        // §4.1: completed/dropped rows use text.dim for title; watching/planning fg.
        const de_emphasized = is_completed or is_dropped;
        const title_style = if (selected)
            self.s(self.palette.focus, .{ .bg = row_bg, .bold = true })
        else if (de_emphasized)
            self.s(self.palette.fg3, .{ .bg = row_bg })
        else
            self.s(self.palette.fg, .{ .bg = row_bg });
        putClipped(win, row, title_col, title_w, rec.title, title_style);

        if (show_meta and slot < self.meta_scratch.len) {
            const meta = formatMeta(&self.meta_scratch[slot], rec);
            putClipped(win, row, meta_col, w - meta_col, meta, self.s(self.palette.fg3, .{ .bg = row_bg }));
        }

        // Row 2: §4.5 progress bar (inherits row_bg for the focus band).
        if (slot < self.bar_scratch.len) {
            drawProgressBar(win, row + 1, title_col, bar_w, rec, row_bg, &self.bar_scratch[slot], self.palette);
        }

        slot += 1;
        row += 2;
        visible_i += 1;
    }
}
