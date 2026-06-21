//! Zigoku — History (Watchlist) view list render pass.
//! Extracted from app.zig along the tick/draw seam (ROD-144). Driven by
//! app.drawContent's `.history` arm; reads list state (the viewport is settled
//! by app.layout() before the draw pass — ROD-155). Takes `*const App`; its
//! only writes are to the passed-in RenderScratch.
//!
//! ROD-139: entries render grouped by watch-state (§5.4) — a status header +
//! `border.hair` rule per group, in `ListStatus.group_order`. `list_cursor` is
//! an *entry* ordinal (nav skips headers for free); `list_top` is a *physical
//! row* offset (chrome-aware scroll). A single `walk()` drives measure,
//! selection and paint so the group/chrome layout has exactly one definition.

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
const formatMeta = render.formatMeta;
const drawProgressBar = render.drawProgressBar;
const title_col = render.title_col;
const meta_col = render.meta_col;
const title_meta_gap = render.title_meta_gap;

/// Static-lifetime hairline source for the group rules — mirrors
/// settings.zig's `settings_hairline`: vaxis keeps the slice by reference until
/// vx.render(), so a stack buffer would dangle. Sliced to width at draw time.
const hairline_cols = 256;
const hairline = "─" ** hairline_cols;

// ── Layout walk ──────────────────────────────────────────────────────────────
//
// The grouped layout is defined once, here. `walk` emits, in §5.4 order, every
// physical element of the filtered list with its physical row, invoking `ctx`'s
// callbacks. Measure (geometry/selection) and paint (draw) both drive it, so the
// chrome budget — header + hairline + the blank row before each group but the
// first — can never disagree between scroll math and what's painted.
//
// Per-group physical cost: [1 blank if not first] + 1 header + 1 hairline + 2·N.
// `ctx` must expose: onBlank(phys), onHeader(phys, status, count),
// onHairline(phys), onEntry(phys, rec, idx, ordinal, selected) — where `idx` is
// the record's index into self.history (for callers that mutate it). Returns
// total rows.
//
// Cost: each walk is O(groups · N) — one `groupCount` scan per group plus the
// entry scan. A wide History frame drives up to THREE walks (layout→geometry,
// drawContent→recordAtCursor, draw), which is fine for real watchlist sizes.
// Before adding a fourth caller, cache a single walk per frame instead.

fn groupCount(self: *const App, status: ListStatus) usize {
    var n: usize = 0;
    for (self.history) |rec| {
        if (rec.list_status == status and self.historyEntryVisible(rec.title)) n += 1;
    }
    return n;
}

fn walk(self: *const App, ctx: anytype) u16 {
    var phys: u16 = 0;
    var ordinal: usize = 0;
    var first_group = true;
    for (ListStatus.group_order) |status| {
        const count = groupCount(self, status);
        if (count == 0) continue; // empty groups are hidden entirely (§5.4)

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
            if (rec.list_status != status or !self.historyEntryVisible(rec.title)) continue;
            ctx.onEntry(phys, rec, idx, ordinal, ordinal == self.list_cursor);
            phys += 2;
            ordinal += 1;
        }
    }
    return phys;
}

/// Physical-row geometry of the grouped, filtered list — what app.layout() needs
/// to settle `list_top` (the chrome-aware scroll offset).
pub const Geometry = struct {
    /// Title row of the cursor's entry, 0-based from the top of the full list.
    cursor_row: u16 = 0,
    /// Full list height in physical rows (all groups, headers, hairlines, blanks).
    total: u16 = 0,
};

/// Measure/select context: captures the cursor entry's physical row and record
/// in one walk. Drawing callbacks are no-ops here.
const ScanCtx = struct {
    cursor: usize,
    // Defaults to 0 when the cursor matches no entry (e.g. a filter hides every
    // row): `rec` stays null and `geometry().total` is 0, which app.layout()
    // short-circuits (max_top = 0) — so cursor_row=0 is never read as a real row.
    cursor_row: u16 = 0,
    rec: ?AnimeRecord = null,
    index: ?usize = null, // self.history index of the cursor entry (for mutation)

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

/// The record under the cursor in §5.4 grouped order — the same ordering the
/// renderer paints, so the highlighted row and the focused record never diverge.
pub fn recordAtCursor(self: *const App) ?AnimeRecord {
    if (self.history.len == 0) return null;
    return scan(self).rec;
}

/// The cursor entry's index into self.history (grouped order) — for callers that
/// mutate the record in place (e.g. a manual status change). Null if no entry is
/// focused (empty history or a filter hiding every row).
pub fn indexAtCursor(self: *const App) ?usize {
    if (self.history.len == 0) return null;
    return scan(self).index;
}

// ── Paint ────────────────────────────────────────────────────────────────────

const DrawCtx = struct {
    self: *const App,
    win: vaxis.Window,
    scratch: *RenderScratch,
    top: u16, // screen row of the viewport's first content row
    visible: u16, // viewport height in physical rows
    list_top: u16, // physical-row offset of the viewport into the full list
    w: u16, // effective list width (narrowed in the wide-preview split)
    show_meta: bool,
    title_w: u16,
    bar_w: u16,
    slot: usize = 0, // RenderScratch meta/bar slot
    header_i: usize = 0, // RenderScratch hist_header slot

    fn rowVisible(c: *const DrawCtx, phys: u16) bool {
        return phys >= c.list_top and phys < c.list_top + c.visible;
    }
    fn screen(c: *const DrawCtx, phys: u16) u16 {
        return c.top + (phys - c.list_top);
    }

    fn onBlank(_: *DrawCtx, _: u16) void {
        // Nothing to paint — the void background shows through the separator.
    }

    fn onHairline(c: *DrawCtx, phys: u16) void {
        if (!c.rowVisible(phys)) return;
        const cols: u16 = @min(c.w, hairline_cols);
        put(c.win, c.screen(phys), 0, hairline[0 .. cols * 3], c.self.s(c.self.palette.chrome, .{}));
    }

    fn onHeader(c: *DrawCtx, phys: u16, status: ListStatus, count: usize) void {
        if (!c.rowVisible(phys)) return;
        const self = c.self;
        const row = c.screen(phys);
        // §2.4 status glyph at its own color (chrome weight, never the focus
        // cursor) so the header's spine aligns with its entries' markers.
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
        // Label: text.primary + bold (§1.3 H1). Count: text.muted, separate span.
        const label = status.str();
        put(c.win, row, 4, label, self.s(self.palette.fg, .{ .bold = true }));
        if (c.header_i < c.scratch.hist_header.len) {
            const buf = &c.scratch.hist_header[c.header_i];
            const cnt = std.fmt.bufPrint(buf, " ({d})", .{count}) catch "";
            // `label.len` doubles as the column advance because every ListStatus
            // tag is ASCII (byte length == display width); revisit if a non-ASCII
            // status label is ever added.
            put(c.win, row, 4 + @as(u16, @intCast(label.len)), cnt, self.s(self.palette.fg2, .{}));
            c.header_i += 1;
        }
    }

    fn onEntry(c: *DrawCtx, phys: u16, rec: AnimeRecord, _: usize, _: usize, selected: bool) void {
        // Both rows (title + bar) must fit; a bottom-edge partial is skipped —
        // app.layout()'s History arm guarantees the cursor's entry is never the
        // partial one (it keeps cursor_row..+2 inside the viewport).
        if (!c.rowVisible(phys) or !c.rowVisible(phys + 1)) return;
        if (c.slot >= c.scratch.bar.len) return; // out of scratch slots
        const self = c.self;
        const row = c.screen(phys);

        const is_completed = rec.list_status == .completed;
        const is_dropped = rec.list_status == .dropped;
        const is_watching = rec.list_status == .watching;
        const is_paused = rec.list_status == .paused;

        // §4.1 focus affordance: the focused row gets a full-width bg.surface band,
        // the ▸ play glyph in focus cyan, and a cyan+bold title.
        const row_bg = if (selected) self.palette.bg_surface else self.palette.bg_base;
        if (selected) {
            fillRow(c.win, row, c.w, self.palette.bg_surface);
            fillRow(c.win, row + 1, c.w, self.palette.bg_surface);
        }

        // §2.4 watchlist status glyphs. Focus ▸ overrides when selected. Colors:
        // watching/paused=focus(+dim for paused), dropped=fg3, completed=●, else ○.
        const marker: []const u8 =
            if (selected or is_watching) "▸ " else if (is_completed) "● " else if (is_paused) "◐ " else if (is_dropped) "· " else "○ ";
        const marker_color =
            if (selected or is_watching or is_paused) self.palette.focus else if (is_dropped) self.palette.fg3 else self.palette.fg2;
        const marker_dim = is_paused and !selected;
        put(c.win, row, 2, marker, self.s(marker_color, .{ .bg = row_bg, .dim = marker_dim }));

        // §4.1: completed/dropped rows use text.dim for title; watching/planning fg.
        const de_emphasized = is_completed or is_dropped;
        const title_style = if (selected)
            self.s(self.palette.focus, .{ .bg = row_bg, .bold = true })
        else if (de_emphasized)
            self.s(self.palette.fg3, .{ .bg = row_bg })
        else
            self.s(self.palette.fg, .{ .bg = row_bg });
        putClipped(c.win, row, title_col, c.title_w, rec.title, title_style);

        if (c.show_meta and c.slot < c.scratch.meta.len) {
            const meta = formatMeta(&c.scratch.meta[c.slot], rec);
            putClipped(c.win, row, meta_col, c.w - meta_col, meta, self.s(self.palette.fg3, .{ .bg = row_bg }));
        }

        // Row 2: §4.5 progress bar (inherits row_bg for the focus band).
        drawProgressBar(c.win, row + 1, title_col, c.bar_w, rec, row_bg, &c.scratch.bar[c.slot], self.palette);
        c.slot += 1;
    }
};

/// Render the Watchlist list body. `top`/`visible`/`w`/`body_w` are the
/// content-area geometry computed by app.drawContent. `self` is `*const App`:
/// this pass reads list state and writes only `scratch`, so the compiler proves
/// it mutates no app state (ROD-155).
pub fn draw(self: *const App, scratch: *RenderScratch, win: vaxis.Window, top: u16, visible: u16, w: u16, body_w: u16) void {
    if (self.history_loading) {
        const hist_spin = std.fmt.bufPrint(&scratch.msg, "{s} loading history", .{self.spinnerChar()}) catch "⠋ loading history";
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

    // Meta only earns its column when the terminal is wide enough to hold it
    // without colliding the title — otherwise the title takes the full width.
    const show_meta = w >= meta_col + 12;
    const title_right: u16 = if (show_meta) meta_col - title_meta_gap else w;
    const title_w: u16 = if (title_right > title_col) title_right - title_col else 0;
    // Bar width: clamp to [16, 24] columns — saturating sub avoids underflow.
    const bar_w: u16 = @min(24, @max(16, w -| 20));

    var ctx = DrawCtx{
        .self = self,
        .win = win,
        .scratch = scratch,
        .top = top,
        .visible = visible,
        .list_top = @intCast(self.list_top),
        .w = w,
        .show_meta = show_meta,
        .title_w = title_w,
        .bar_w = bar_w,
    };
    _ = walk(self, &ctx);
}
