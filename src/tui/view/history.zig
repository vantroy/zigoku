//! History (Watchlist) list render pass.
//! Extracted from app.zig (ROD-144). Viewport settled by app.layout() before draw
//! (ROD-155). `*const App`; only writes go to RenderScratch.
//!
//! ROD-139: entries grouped by watch-state (§5.4). `list_cursor` is an entry ordinal
//! (nav skips headers); `list_top` is a physical row offset. One `walk()` drives
//! measure, selection, and paint so chrome layout has a single definition.

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const render = @import("../render.zig");
const domain = @import("../../domain.zig");
const store = @import("../../store.zig");

const App = app_mod.App;
const RenderScratch = app_mod.RenderScratch;
const AnimeRecord = store.AnimeRecord;
const ListStatus = domain.ListStatus;
const put = render.put;
const putClipped = render.putClipped;
const fillRow = render.fillRow;
const centerText = render.centerText;
const centerKeyHint = render.centerKeyHint;
const drawProgressBar = render.drawProgressBar;
const title_col = render.title_col;

/// Static hairline for group rules (mirrors settings.zig). vaxis holds the slice
/// until render; a stack buffer would dangle. Sliced to width at draw time.
const hairline_cols = 256;
const hairline = "─" ** hairline_cols;

// ── Layout walk ──────────────────────────────────────────────────────────────
// Grouped layout defined once. walk emits §5.4 order with physical rows.
// Measure and paint both drive it so chrome budget cannot disagree.
// Per-group cost: [1 blank if not first] + 1 header + 1 hairline + 2·N.
// O(groups · N); a frame may walk up to three times (layout, recordAtCursor, draw).

fn groupCount(self: *const App, status: ListStatus) usize {
    var n: usize = 0;
    for (self.history) |rec| {
        if (rec.list_status == status and self.historyEntryVisible(rec)) n += 1;
    }
    return n;
}

fn walk(self: *const App, ctx: anytype) u16 {
    var phys: u16 = 0;
    var ordinal: usize = 0;
    var first_group = true;
    for (ListStatus.group_order) |status| {
        const count = groupCount(self, status);
        if (count == 0) continue; // empty groups hidden (§5.4)

        if (!first_group) {
            ctx.onBlank(phys);
            phys += 1;
        }
        first_group = false;

        ctx.onHeader(phys, status, count);
        phys += 1;
        ctx.onHairline(phys);
        phys += 1;

        for (self.history, 0..) |rec, idx| {
            if (rec.list_status != status or !self.historyEntryVisible(rec)) continue;
            ctx.onEntry(phys, rec, idx, ordinal, ordinal == self.list_cursor);
            phys += 2;
            ordinal += 1;
        }
    }
    return phys;
}

/// Physical-row geometry for app.layout() (`list_top` chrome-aware scroll).
pub const Geometry = struct {
    /// Title row of the cursor entry, 0-based from full list top.
    cursor_row: u16 = 0,
    /// Full list height in physical rows (groups, headers, hairlines, blanks).
    total: u16 = 0,
};

/// Measure/select context: cursor entry physical row + record in one walk.
const ScanCtx = struct {
    cursor: usize,
    // No match (filter hides all): rec null, total 0; layout short-circuits max_top.
    cursor_row: u16 = 0,
    rec: ?AnimeRecord = null,
    index: ?usize = null, // self.history index for mutation

    fn onBlank(_: *ScanCtx, _: u16) void {}
    fn onHeader(_: *ScanCtx, _: u16, _: ListStatus, _: usize) void {}
    fn onHairline(_: *ScanCtx, _: u16) void {}
    fn onEntry(self: *ScanCtx, phys: u16, rec: AnimeRecord, idx: usize, ordinal: usize, _: bool) void {
        if (ordinal == self.cursor) {
            self.cursor_row = phys;
            self.rec = rec;
            self.index = idx;
        }
    }
};

fn scan(self: *const App) struct { geom: Geometry, rec: ?AnimeRecord, index: ?usize } {
    var ctx = ScanCtx{ .cursor = self.list_cursor };
    const total = walk(self, &ctx);
    return .{ .geom = .{ .cursor_row = ctx.cursor_row, .total = total }, .rec = ctx.rec, .index = ctx.index };
}

pub fn geometry(self: *const App) Geometry {
    return scan(self).geom;
}

/// Record under cursor in §5.4 grouped order (same order paint uses).
/// Null when empty or filter hides every row.
pub fn recordAtCursor(self: *const App) ?AnimeRecord {
    return scan(self).rec;
}

/// Cursor entry's index into self.history (for in-place mutation). Null if unfocused.
pub fn indexAtCursor(self: *const App) ?usize {
    return scan(self).index;
}

/// First self.history index matching source + source_id (applyUndo ROD-193, recompute).
pub fn indexById(self: *const App, source: []const u8, source_id: []const u8) ?usize {
    for (self.history, 0..) |rec, i| {
        if (std.mem.eql(u8, rec.source, source) and std.mem.eql(u8, rec.source_id, source_id)) {
            return i;
        }
    }
    return null;
}

/// ROD-229: list_cursor ordinal for this key in §5.4 order, or null if filtered/absent.
/// Inverse of recordAtCursor. Distinct from indexById (raw history index is NOT cursor space).
pub fn ordinalOf(self: *const App, source: []const u8, source_id: []const u8) ?usize {
    const Ctx = struct {
        want_source: []const u8,
        want_id: []const u8,
        found: ?usize = null,
        fn onBlank(_: *@This(), _: u16) void {}
        fn onHeader(_: *@This(), _: u16, _: ListStatus, _: usize) void {}
        fn onHairline(_: *@This(), _: u16) void {}
        fn onEntry(c: *@This(), _: u16, rec: AnimeRecord, _: usize, ordinal: usize, _: bool) void {
            if (c.found != null) return;
            if (std.mem.eql(u8, rec.source, c.want_source) and std.mem.eql(u8, rec.source_id, c.want_id))
                c.found = ordinal;
        }
    };
    var ctx = Ctx{ .want_source = source, .want_id = source_id };
    _ = walk(self, &ctx);
    return ctx.found;
}

// ── Paint ────────────────────────────────────────────────────────────────────

const DrawCtx = struct {
    self: *const App,
    win: vaxis.Window,
    scratch: *RenderScratch,
    top: u16,
    visible: u16,
    list_top: u16,
    w: u16,
    title_w: u16,
    bar_w: u16,
    bar_avail: u16, // cols from title_col to list right edge (clips frac)
    slot: usize = 0,
    header_i: usize = 0,

    fn rowVisible(c: *const DrawCtx, phys: u16) bool {
        return phys >= c.list_top and phys < c.list_top + c.visible;
    }
    fn screen(c: *const DrawCtx, phys: u16) u16 {
        return c.top + (phys - c.list_top);
    }

    fn onBlank(_: *DrawCtx, _: u16) void {}

    fn onHairline(c: *DrawCtx, phys: u16) void {
        if (!c.rowVisible(phys)) return;
        const cols: u16 = @min(c.w, hairline_cols);
        put(c.win, c.screen(phys), 0, hairline[0 .. cols * 3], c.self.s(c.self.palette.chrome, .{}));
    }

    fn onHeader(c: *DrawCtx, phys: u16, status: ListStatus, count: usize) void {
        if (!c.rowVisible(phys)) return;
        const self = c.self;
        const row = c.screen(phys);
        const glyph: []const u8 = switch (status) {
            .watching => "▸",
            .planning => "○",
            .paused => "◐",
            .completed => "●",
            .dropped => "·",
        };
        const gstyle = switch (status) {
            .watching => self.s(self.palette.focus, .{}),
            .planning => self.s(self.palette.fg2, .{}),
            .paused => self.s(self.palette.focus, .{ .dim = true }),
            .completed, .dropped => self.s(self.palette.fg3, .{}),
        };
        put(c.win, row, 2, glyph, gstyle);
        const label = status.str();
        put(c.win, row, 4, label, self.s(self.palette.fg, .{ .bold = true }));
        if (c.header_i < c.scratch.hist_header.len) {
            const buf = &c.scratch.hist_header[c.header_i];
            const cnt = std.fmt.bufPrint(buf, " ({d})", .{count}) catch "";
            // ListStatus tags are ASCII (byte len == display width).
            put(c.win, row, 4 + @as(u16, @intCast(label.len)), cnt, self.s(self.palette.fg2, .{}));
            c.header_i += 1;
        }
    }

    fn onEntry(c: *DrawCtx, phys: u16, rec: AnimeRecord, _: usize, _: usize, selected: bool) void {
        // Both title + bar rows must fit; layout keeps cursor entry fully in viewport.
        if (!c.rowVisible(phys) or !c.rowVisible(phys + 1)) return;
        if (c.slot >= c.scratch.bar.len) return;
        const self = c.self;
        const row = c.screen(phys);

        const is_completed = rec.list_status == .completed;
        const is_dropped = rec.list_status == .dropped;
        const is_watching = rec.list_status == .watching;
        const is_paused = rec.list_status == .paused;

        // §4.1 + ROD-194: full focus (band + cyan ▸ + bold title) only when selected
        // AND list pane focused. Detail-focused selected row steps down.
        const list_focused = self.active_pane == .list;
        const sel_focused = selected and list_focused;
        const row_bg = if (sel_focused) self.palette.bg_surface else self.palette.bg_base;
        if (sel_focused) {
            fillRow(c.win, row, c.w, self.palette.bg_surface);
            fillRow(c.win, row + 1, c.w, self.palette.bg_surface);
        }

        // Selected ▸ overrides; watching also ▸. Unselected status glyphs step off
        // focus (ROD-194) so watching cannot impersonate the cursor.
        const marker: []const u8 =
            if (selected or is_watching) "▸ " else if (is_completed) "● " else if (is_paused) "◐ " else if (is_dropped) "· " else "○ ";
        const marker_color =
            if (selected) self.palette.focus else if (is_dropped) self.palette.fg3 else self.palette.fg2;
        const marker_dim = (selected and !list_focused) or (is_paused and !selected);
        put(c.win, row, 2, marker, self.s(marker_color, .{ .bg = row_bg, .dim = marker_dim }));

        const de_emphasized = is_completed or is_dropped;
        const title_style = if (selected)
            self.s(self.palette.focus, .{ .bg = row_bg, .bold = list_focused })
        else if (de_emphasized)
            self.s(self.palette.fg3, .{ .bg = row_bg })
        else
            self.s(self.palette.fg, .{ .bg = row_bg });
        // Title under title_language (ROD-205). Filter matches all forms (ROD-299).
        const row_title = domain.preferredTitle(rec.title, rec.title_english, rec.native_name, self.config.titleLanguageEnum());
        putClipped(c.win, row, title_col, c.title_w, row_title, title_style);

        // Title-only on row 1; episode count on bar only (ROD-227). Right-meta deferred.

        drawProgressBar(c.win, row + 1, title_col, c.bar_w, c.bar_avail, rec, row_bg, &c.scratch.bar[c.slot], self.palette, selected, list_focused);
        c.slot += 1;
    }
};

/// Render Watchlist list body. `*const App`: mutates only scratch (ROD-155).
pub fn draw(self: *const App, scratch: *RenderScratch, win: vaxis.Window, top: u16, visible: u16, w: u16, body_w: u16) void {
    if (self.history_loading) {
        const hist_spin = std.fmt.bufPrint(&scratch.msg, "{s} loading history", .{self.spinnerChar()}) catch "⠋ loading history";
        putClipped(win, top, 2, body_w, hist_spin, self.s(self.palette.focus, .{}));
        return;
    }
    if (self.load_error) |msg| {
        put(win, top, 2, "history unavailable", self.s(self.palette.hot, .{ .bold = true }));
        putClipped(win, top + 1, 2, body_w, msg, self.s(self.palette.fg3, .{}));
        return;
    }
    if (self.history.len == 0) {
        // First-run absent (§9.5): point at Discover (ROD-247/254), not Browse `/`.
        // Content-height child so the block cannot overdraw the top bar (ROD-254).
        const pane = win.child(.{ .y_off = top, .width = w, .height = visible });
        const mid = visible / 2;
        centerText(pane, mid -| 2, w, "nothing watched yet", self.s(self.palette.fg2, .{ .italic = true }));
        centerKeyHint(pane, mid, w, "D", self.s(self.palette.focus, .{ .bold = true }), "  see what's popular", self.s(self.palette.fg2, .{}));
        centerKeyHint(pane, mid + 2, w, "B", self.s(self.palette.focus, .{ .bold = true }), "  search for a show", self.s(self.palette.fg3, .{}));
        return;
    }

    // Title full pane width (no right-meta column; ROD-227).
    const title_w: u16 = if (w > title_col) w - title_col else 0;
    // Bar from title_col to list edge (ROD-170 bleed). Cap 24, floor 8; ~16 for frac.
    const bar_avail: u16 = w -| (title_col - 2);
    const bar_w: u16 = @min(24, @max(8, bar_avail -| 16));

    var ctx = DrawCtx{
        .self = self,
        .win = win,
        .scratch = scratch,
        .top = top,
        .visible = visible,
        .list_top = @intCast(self.list_top),
        .w = w,
        .title_w = title_w,
        .bar_w = bar_w,
        .bar_avail = bar_avail,
    };
    _ = walk(self, &ctx);
}
