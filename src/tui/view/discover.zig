//! Zigoku — Discover/Popular view render pass (ROD-239).
//! The v0.2 headline feature: a popularity-ranked, window-toggled cover grid.
//! Built in chunks — this one renders the window bar, the loading/empty states,
//! and the navigable grid with GRACEFUL placeholder cells (rank `#N`, no art —
//! covers are ROD-243). Reads DiscoverState through `self.discover.*` and writes
//! only the window + scratch it's handed (the `*const App` + `*RenderScratch`
//! split — ROD-144/155: the pass proves it mutates no app state).

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const render = @import("../render.zig");

const App = app_mod.App;
const RenderScratch = app_mod.RenderScratch;
const Anime = @import("../../domain.zig").Anime;
const put = render.put;
const putClipped = render.putClipped;
const centerText = render.centerText;

/// Card-grid geometry. Two tiers matching the existing cover sizes (DESIGN §3.3):
/// large (>= 80 cols) a 20x7 cover in a 22x11 slot; small (< 80) 14x5 in 16x9.
pub const Geometry = struct {
    cols: u16,
    slot_w: u16,
    slot_h: u16,
    cover_w: u16,
    cover_h: u16,
    rows_visible: u16,
};

/// Resolve the grid geometry for a content area `w` wide by `content_h` tall.
/// `cols = max(1, (w-2)/slot_w)`; the grid sits below the window bar (1 row) and a
/// spacer (1 row), so its height is `content_h - 2`.
pub fn geometry(w: u16, content_h: u16) Geometry {
    const large = w >= 80;
    const slot_w: u16 = if (large) 22 else 16;
    const slot_h: u16 = if (large) 11 else 9;
    const avail_w: u16 = if (w > 2) w - 2 else 0;
    const cols: u16 = @max(1, avail_w / slot_w);
    const grid_h: u16 = if (content_h > 2) content_h - 2 else 0;
    return .{
        .cols = cols,
        .slot_w = slot_w,
        .slot_h = slot_h,
        .cover_w = if (large) 20 else 14,
        .cover_h = if (large) 7 else 5,
        .rows_visible = grid_h / slot_h,
    };
}

/// Column count for a width — the cursor/scroll math in app.zig needs it without
/// a height.
pub fn gridCols(w: u16) u16 {
    return geometry(w, 0).cols;
}

/// Format a raw view count the way the site reads it: `1.4m`, `660.17k`, `892`.
/// Lifetime-safe only while `buf` outlives vx.render() — callers pass scratch.
fn formatViews(buf: []u8, n: u64) []const u8 {
    if (n >= 1_000_000) {
        return std.fmt.bufPrint(buf, "{d}.{d}m", .{ n / 1_000_000, (n % 1_000_000) / 100_000 }) catch "";
    } else if (n >= 1_000) {
        return std.fmt.bufPrint(buf, "{d}.{d:0>2}k", .{ n / 1_000, (n % 1_000) / 10 }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch "";
}

/// Fill a rectangle with `bg` — the placeholder cover cell (graceful no-art).
fn fillRect(win: vaxis.Window, x: u16, y: u16, w: u16, h: u16, bg: vaxis.Color) void {
    if (w == 0 or h == 0) return;
    const child = win.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = w, .height = h });
    child.fill(.{ .style = .{ .bg = bg } });
}

/// The window-toggle segmented bar: active window in state.focus+bold, the rest in
/// text.muted, separator dots in text.dim. Passive — the keys driving it live in
/// app.zig's onDiscoverKey.
fn drawWindowBar(self: *const App, win: vaxis.Window, row: u16) void {
    const labels = [_][]const u8{ "Daily", "Weekly", "Monthly", "All-Time" };
    const active = @intFromEnum(self.discover.window);
    var col: u16 = 2;
    for (labels, 0..) |label, i| {
        const style = if (i == active)
            self.s(self.palette.focus, .{ .bold = true })
        else
            self.s(self.palette.fg2, .{});
        put(win, row, col, label, style);
        col += @as(u16, @intCast(label.len));
        if (i + 1 < labels.len) {
            put(win, row, col + 1, "·", self.s(self.palette.fg3, .{}));
            col += 3;
        }
    }
}

/// One feed card: a placeholder cover cell with the rank centered, then the rank,
/// title, and view-count metadata rows. `vis` indexes the per-frame scratch slots
/// (the formatted rank/views must outlive vx.render — RenderScratch contract).
fn drawCard(self: *const App, scratch: *RenderScratch, win: vaxis.Window, x: u16, y: u16, geo: Geometry, vis: usize, idx: usize, a: Anime, selected: bool) void {
    const bg = self.palette.bg_surface;
    // Placeholder cover (graceful no-art, ROD-239): bg.surface fill, rank centered
    // in text.dim. Covers replace this in ROD-243.
    fillRect(win, x, y, geo.cover_w, geo.cover_h, bg);

    // Rank string — reused for the in-cell placeholder and the metadata row.
    const rank: []const u8 = if (vis < scratch.score.len)
        (std.fmt.bufPrint(&scratch.score[vis], "#{d}", .{idx + 1}) catch "#")
    else
        "#";
    const rank_w: u16 = @intCast(rank.len);
    put(win, y + geo.cover_h / 2, x + (geo.cover_w -| rank_w) / 2, rank, self.s(self.palette.fg3, .{ .bg = bg }));

    // Selection affordance: ▸ at the cover's bottom-left (no box, no row band).
    if (selected) put(win, y + geo.cover_h -| 1, x, "▸", self.s(self.palette.focus, .{ .bg = bg }));

    // Metadata rows under the cover. TOP/NEW are DERIVED render-side (not in the
    // payload, ROD-239): TOP on rank #1 (state.now+bold), NEW on a current-cour
    // release (state.focus+bold). At most one shows.
    const rank_y = y + geo.cover_h;
    put(win, rank_y, x, rank, self.s(self.palette.fg, .{}));
    if (idx == 0) {
        put(win, rank_y, x + rank_w + 1, "TOP", self.s(self.palette.hot, .{ .bold = true }));
    } else if (self.isNewRelease(a)) {
        put(win, rank_y, x + rank_w + 1, "NEW", self.s(self.palette.focus, .{ .bold = true }));
    }

    const title_sty = if (selected)
        self.s(self.palette.focus, .{ .bold = true })
    else
        self.s(self.palette.fg, .{});
    putClipped(win, rank_y + 1, x, geo.cover_w, a.name, title_sty);

    if (a.view_count) |vc| {
        const vs: []const u8 = if (vis < scratch.meta.len) formatViews(&scratch.meta[vis], vc) else "";
        put(win, rank_y + 2, x, vs, self.s(self.palette.fg2, .{}));
    } else {
        put(win, rank_y + 2, x, "—", self.s(self.palette.fg3, .{}));
    }
}

/// Full-canvas Discover pass. `top` is the first content row; `visible` the
/// content height; `w` the full width.
pub fn draw(self: *const App, scratch: *RenderScratch, win: vaxis.Window, top: u16, visible: u16, w: u16) void {
    drawWindowBar(self, win, top);

    const grid_top: u16 = top + 2;
    const geo = geometry(w, visible);
    const slot = self.discover.activeSlot();
    const results = slot.results.items;

    if (results.len == 0) {
        const mid: u16 = grid_top + (if (visible > 2) visible - 2 else 0) / 2;
        if (slot.loading) {
            // A retry sets loading, so the spinner takes precedence over a stale error.
            const msg = std.fmt.bufPrint(&scratch.msg, "{s} loading popular\u{2026}", .{self.spinnerChar()}) catch "loading\u{2026}";
            centerText(win, mid, w, msg, self.s(self.palette.focus, .{}));
        } else if (slot.failed) {
            // §9.3b graceful offline — the feed is unreachable, not empty.
            centerText(win, mid -| 1, w, "[!] can't reach the feed", self.s(self.palette.hot, .{}));
            centerText(win, mid + 1, w, "check your connection", self.s(self.palette.fg3, .{ .italic = true }));
        } else {
            centerText(win, mid, w, "no entries", self.s(self.palette.fg2, .{ .italic = true }));
        }
        return;
    }

    // Visible cards only: from the scrolled top card-row down, capped at the
    // viewport's row budget. `vis` is the scratch slot (0-based, not the rank).
    const startc: usize = self.discover.scroll * geo.cols;
    var vis: usize = 0;
    var i: usize = startc;
    while (i < results.len) : (i += 1) {
        const rel = i - startc;
        const grow = rel / geo.cols;
        if (grow >= geo.rows_visible) break;
        const gcol = rel % geo.cols;
        const x: u16 = 2 + @as(u16, @intCast(gcol)) * geo.slot_w;
        const y: u16 = grid_top + @as(u16, @intCast(grow)) * geo.slot_h;
        drawCard(self, scratch, win, x, y, geo, vis, i, results[i], i == self.discover.cursor);
        vis += 1;
    }

    // Load-more footer, on the row just below the last card slot (no overlap).
    // "loading more…" while the next page is in flight (results already on screen,
    // so it's a page-N fetch, not the initial spinner); "all entries loaded" once
    // the feed is exhausted and the last card is actually in view (ROD-239).
    const footer_y: u16 = grid_top + geo.rows_visible * geo.slot_h;
    if (footer_y < top + visible) {
        if (slot.loading) {
            const msg = std.fmt.bufPrint(&scratch.msg, "{s} loading more\u{2026}", .{self.spinnerChar()}) catch "loading more\u{2026}";
            centerText(win, footer_y, w, msg, self.s(self.palette.fg2, .{ .italic = true }));
        } else if (slot.exhausted and (results.len - 1) / geo.cols < self.discover.scroll + geo.rows_visible) {
            centerText(win, footer_y, w, "all entries loaded", self.s(self.palette.fg3, .{ .italic = true }));
        }
    }
}
