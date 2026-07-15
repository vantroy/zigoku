//! Discover view render pass (ROD-239, AniList-backed ROD-336).
//! Axis-toggled cover grid over AniList ranking axes (§3.8/§9.6). Graceful
//! placeholder cells when art is missing (covers: ROD-243). Reads DiscoverState
//! via `self.discover.*`; writes only the window + RenderScratch (`*const App`
//! split, ROD-144/155).

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const render = @import("../render.zig");
const cover_render = @import("../cover_render.zig");

const App = app_mod.App;
const RenderScratch = app_mod.RenderScratch;
const Anime = @import("../../domain.zig").Anime;
const put = render.put;
const putClipped = render.putClipped;
const centerText = render.centerText;

/// Card-grid geometry. Large (>= 80 cols): 20x7 cover in 22x11 slot; small: 14x5 in 16x9.
pub const Geometry = struct {
    cols: u16,
    slot_w: u16,
    slot_h: u16,
    cover_w: u16,
    cover_h: u16,
    rows_visible: u16,
};

// AniList posters ~2:3 portrait.
const POSTER_H_NUM: u32 = 142;
const POSTER_W_DEN: u32 = 100;

/// Cover-box height so a ~2:3 poster fills `cover_w` (ROD-247). Uses terminal cell
/// pixels; 0 metrics (tmux/headless) fall back to pre-fill height. Never shorter
/// than fallback; clamps u16 for non-physical pixel reports.
fn coverHeight(cover_w: u16, fallback: u16, cell_w_px: u16, cell_h_px: u16) u16 {
    if (cell_w_px == 0 or cell_h_px == 0) return fallback;
    const den = @as(u32, cell_h_px) * POSTER_W_DEN;
    const num = @as(u32, cover_w) * @as(u32, cell_w_px) * POSTER_H_NUM;
    const h: u32 = (num + den / 2) / den;
    return @intCast(@min(@as(u32, std.math.maxInt(u16)), @max(@as(u32, fallback), h)));
}

/// Grid geometry for content area `w` x `content_h`. Grid sits below axis bar + spacer.
/// Cell pixels size cover fill (ROD-247); pass 0 when only cols matter.
pub fn geometry(w: u16, content_h: u16, cell_w_px: u16, cell_h_px: u16) Geometry {
    const large = w >= 80;
    const slot_w: u16 = if (large) 22 else 16;
    const cover_w: u16 = if (large) 20 else 14;
    const cover_h: u16 = coverHeight(cover_w, if (large) 7 else 5, cell_w_px, cell_h_px);
    const slot_h: u16 = cover_h + 4; // 3 meta rows + 1 gap (ROD-247)
    const avail_w: u16 = if (w > 2) w - 2 else 0;
    const cols: u16 = @max(1, avail_w / slot_w);
    const grid_h: u16 = if (content_h > 2) content_h - 2 else 0;
    return .{
        .cols = cols,
        .slot_w = slot_w,
        .slot_h = slot_h,
        .cover_w = cover_w,
        .cover_h = cover_h,
        .rows_visible = grid_h / slot_h,
    };
}

/// Column count for width only (cursor/scroll math; cover pixels irrelevant).
pub fn gridCols(w: u16) u16 {
    return geometry(w, 0, 0, 0).cols;
}

/// AniList format → short card label (§3.8). Unmapped → null (dim placeholder dash).
fn formatLabel(kind: []const u8) ?[]const u8 {
    const map = [_][2][]const u8{
        .{ "TV", "TV" },
        .{ "TV_SHORT", "TV" },
        .{ "MOVIE", "Movie" },
        .{ "SPECIAL", "Spec" },
        .{ "OVA", "OVA" },
        .{ "ONA", "ONA" },
        .{ "MUSIC", "Music" },
    };
    for (map) |m| {
        if (std.mem.eql(u8, m[0], kind)) return m[1];
    }
    return null;
}

/// Format+episodes cell: `TV · 24ep`, bare `Movie`, or `TV · ??ep` (ROD-336).
/// Null when format unmapped. `buf` must outlive vx.render() (scratch).
fn formatKindEps(buf: []u8, a: Anime) ?[]const u8 {
    const kind = a.kind orelse return null;
    const label = formatLabel(kind) orelse return null;
    if (std.mem.eql(u8, kind, "MOVIE")) return label;
    if (a.total_episodes) |n| {
        return std.fmt.bufPrint(buf, "{s} \u{00B7} {d}ep", .{ label, n }) catch label;
    }
    return std.fmt.bufPrint(buf, "{s} \u{00B7} ??ep", .{label}) catch label;
}

/// AniList genre → monochrome BMP glyph (ROD-247). Ambient texture on the card;
/// full list lives in zoom detail. Unmapped → "".
const GenreGlyph = struct { name: []const u8, glyph: []const u8 };
const genre_glyphs = [_]GenreGlyph{
    .{ .name = "Action", .glyph = "\u{2694}" }, // ⚔
    .{ .name = "Adventure", .glyph = "\u{2691}" }, // ⚑
    .{ .name = "Comedy", .glyph = "\u{263A}" }, // ☺
    .{ .name = "Drama", .glyph = "\u{25C6}" }, // ◆
    .{ .name = "Ecchi", .glyph = "\u{2668}" }, // ♨
    .{ .name = "Fantasy", .glyph = "\u{269C}" }, // ⚜
    .{ .name = "Horror", .glyph = "\u{2620}" }, // ☠
    .{ .name = "Mahou Shoujo", .glyph = "\u{273F}" }, // ✿
    .{ .name = "Mecha", .glyph = "\u{2699}" }, // ⚙
    .{ .name = "Music", .glyph = "\u{266A}" }, // ♪
    .{ .name = "Mystery", .glyph = "\u{25C8}" }, // ◈
    .{ .name = "Psychological", .glyph = "\u{25D0}" }, // ◐
    .{ .name = "Romance", .glyph = "\u{2665}" }, // ♥
    .{ .name = "Sci-Fi", .glyph = "\u{2B21}" }, // ⬡
    .{ .name = "Slice of Life", .glyph = "\u{2756}" }, // ❖
    .{ .name = "Sports", .glyph = "\u{25CE}" }, // ◎
    .{ .name = "Supernatural", .glyph = "\u{263D}" }, // ☽
    .{ .name = "Thriller", .glyph = "\u{21AF}" }, // ↯
};

fn genreGlyph(name: []const u8) []const u8 {
    for (genre_glyphs) |g| {
        if (std.mem.eql(u8, g.name, name)) return g.glyph;
    }
    return "";
}

/// Fill a rectangle with `bg` (placeholder cover cell).
fn fillRect(win: vaxis.Window, x: u16, y: u16, w: u16, h: u16, bg: vaxis.Color) void {
    if (w == 0 or h == 0) return;
    const child = win.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = w, .height = h });
    child.fill(.{ .style = .{ .bg = bg } });
}

/// Axis-toggle bar (§3.8): `[1] Trending · …` (ROD-248). Keys live in onDiscoverKey.
fn drawAxisBar(self: *const App, win: vaxis.Window, row: u16) void {
    const labels = [_][]const u8{ "Trending", "Popular", "Top Rated", "This Season" };
    // Static `[N]` literals: vaxis holds slices by ref; bufPrint would dangle.
    const keys = [_][]const u8{ "[1]", "[2]", "[3]", "[4]" };
    const active = @intFromEnum(self.discover.axis);
    var col: u16 = 2;
    for (labels, keys, 0..) |label, keyhint, i| {
        const on = i == active;
        // Key hint fg2 off-axis (legible teaching); focus on active so the entry reads as a unit.
        const key_sty = if (on) self.s(self.palette.focus, .{}) else self.s(self.palette.fg2, .{});
        const label_sty = if (on) self.s(self.palette.focus, .{ .bold = true }) else self.s(self.palette.fg2, .{});
        put(win, row, col, keyhint, key_sty);
        col += @as(u16, @intCast(keyhint.len)) + 1;
        put(win, row, col, label, label_sty);
        col += @as(u16, @intCast(label.len));
        if (i + 1 < labels.len) {
            put(win, row, col + 1, "·", self.s(self.palette.fg3, .{}));
            col += 3;
        }
    }
}

/// One feed card. `vis` indexes per-frame scratch (rank/title/format must outlive vx.render).
fn drawCard(self: *const App, scratch: *RenderScratch, win: vaxis.Window, x: u16, y: u16, geo: Geometry, vis: usize, idx: usize, a: Anime, selected: bool) void {
    const rank: []const u8 = if (vis < scratch.score.len)
        (std.fmt.bufPrint(&scratch.score[vis], "#{d}", .{idx + 1}) catch "#")
    else
        "#";
    const rank_w: u16 = @intCast(rank.len);

    drawCoverCell(self, win, x, y, geo, rank, rank_w, a);

    // TOP/NEW derived render-side (ROD-239): TOP on #1; NEW on current-cour (not payload).
    const rank_y = y + geo.cover_h;
    // Selection marker on rank row only (never cover art / Kitty mask). Left gutter x-1;
    // x >= 2 so x-1 is always a safe empty cell (ROD-243).
    if (selected) put(win, rank_y, x - 1, "▸", self.s(self.palette.focus, .{}));
    put(win, rank_y, x, rank, self.s(self.palette.fg, .{}));
    const badge_x = x + rank_w + 1;
    if (idx == 0) {
        put(win, rank_y, badge_x, "TOP", self.s(self.palette.hot, .{ .bold = true }));
    } else if (self.discover.axis != .this_season and self.isNewRelease(a)) {
        // NEW suppressed on This Season: every card is this-cour, badge would be noise (§3.8).
        put(win, rank_y, badge_x, "NEW", self.s(self.palette.focus, .{ .bold = true }));
    }

    // Score badge right-anchored (ROD-247). Cap 91+ at fg so TOP keeps sole hot pointer.
    if (vis < scratch.disc_badge.len) {
        const badge: []const u8 = if (a.score) |sc|
            std.fmt.bufPrint(&scratch.disc_badge[vis], "[{d}]", .{sc}) catch "[--]"
        else
            "[--]";
        const bx = x + geo.cover_w -| @as(u16, @intCast(badge.len));
        const badge_style = if ((a.score orelse 0) >= 91)
            self.s(self.palette.fg, .{})
        else
            self.scoreStyle(a.score, null);
        put(win, rank_y, bx, badge, badge_style);
    }

    const title_sty = if (selected)
        self.s(self.palette.focus, .{ .bold = true })
    else
        self.s(self.palette.fg, .{});
    // Truncate with "…" (ROD-245); past 256-slot scratch cap fall back to silent clip.
    const card_title = a.displayTitle(self.config.titleLanguageEnum());
    if (vis < scratch.title.len) {
        const t = render.truncateToWidth(&scratch.title[vis], card_title, geo.cover_w);
        put(win, rank_y + 1, x, t, title_sty);
    } else {
        putClipped(win, rank_y + 1, x, geo.cover_w, card_title, title_sty);
    }

    const fmt_cell: ?[]const u8 = if (vis < scratch.meta.len)
        formatKindEps(&scratch.meta[vis], a)
    else
        null;
    if (fmt_cell) |fc| {
        put(win, rank_y + 2, x, fc, self.s(self.palette.fg2, .{}));
    } else {
        put(win, rank_y + 2, x, "—", self.s(self.palette.fg3, .{}));
    }

    // Genre glyphs right-anchored on format row (ROD-247). Up to two; scratch-backed.
    if (vis < scratch.disc_genre.len) {
        var glen: usize = 0;
        var shown: usize = 0;
        for (a.genres) |gname| {
            if (shown >= 2) break;
            const sym = genreGlyph(gname);
            if (sym.len == 0) continue;
            const sep: []const u8 = if (shown > 0) " " else "";
            if (glen + sep.len + sym.len > scratch.disc_genre[vis].len) break;
            @memcpy(scratch.disc_genre[vis][glen .. glen + sep.len], sep);
            glen += sep.len;
            @memcpy(scratch.disc_genre[vis][glen .. glen + sym.len], sym);
            glen += sym.len;
            shown += 1;
        }
        if (glen > 0) {
            const glyphs = scratch.disc_genre[vis][0..glen];
            const gw: u16 = @intCast(vaxis.gwidth.gwidth(glyphs, .unicode));
            // text.dim: ambient; fg2 competed with left meta.
            put(win, rank_y + 2, x + geo.cover_w -| gw, glyphs, self.s(self.palette.fg3, .{}));
        }
    }
}

/// Cover cell: Kitty image, half-block mosaic, or bg.surface + centered `#N` (ROD-243).
fn drawCoverCell(self: *const App, win: vaxis.Window, x: u16, y: u16, geo: Geometry, rank: []const u8, rank_w: u16, a: Anime) void {
    if (a.thumb) |thumb| {
        if (self.discover_covers.getConst(thumb)) |slot| {
            if (slot.image) |img| {
                const cover_win = win.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = geo.cover_w, .height = geo.cover_h });
                // §8 matte: bg_base so fit-letterbox matches canvas.
                cover_win.fill(.{ .style = .{ .bg = self.palette.bg_base } });
                if (cover_render.drawKittyFit(img, cover_win)) return;
            } else if (slot.pixels) |px| {
                const cover_win = win.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = geo.cover_w, .height = geo.cover_h });
                cover_win.fill(.{ .style = .{ .bg = self.palette.bg_base } });
                cover_render.drawHalfBlock(cover_win, .{ .rgba = px.rgba, .w = px.w, .h = px.h }, self.palette.bg_base);
                return;
            }
        }
    }
    const bg = self.palette.bg_surface;
    fillRect(win, x, y, geo.cover_w, geo.cover_h, bg);
    put(win, y + geo.cover_h / 2, x + (geo.cover_w -| rank_w) / 2, rank, self.s(self.palette.fg3, .{ .bg = bg }));
}

/// Full-canvas Discover pass. `top` first content row; `visible` content height; `w` width.
pub fn draw(self: *const App, scratch: *RenderScratch, win: vaxis.Window, top: u16, visible: u16, w: u16) void {
    drawAxisBar(self, win, top);

    const grid_top: u16 = top + 2;
    const cp = self.cellPx();
    const geo = geometry(w, visible, cp[0], cp[1]);
    const slot = self.discover.activeSlot();
    const results = slot.results.items;

    if (results.len == 0) {
        const mid: u16 = grid_top + (if (visible > 2) visible - 2 else 0) / 2;
        if (slot.loading) {
            // Retry sets loading: spinner over stale error. Slow path ~3s (§4.8/§5.6).
            const slow = self.isSlowPath();
            const label: []const u8 = if (slow) "taking a moment\u{2026}" else "loading feed\u{2026}";
            const color = if (slow) self.palette.hot else self.palette.focus;
            const msg = std.fmt.bufPrint(&scratch.msg, "{s} {s}", .{ self.spinnerChar(), label }) catch label;
            centerText(win, mid, w, msg, self.s(color, .{}));
        } else if (slot.failed) {
            // Offline, not empty (§9.3b).
            centerText(win, mid -| 1, w, "[!] can't reach the feed", self.s(self.palette.hot, .{ .bold = true }));
            centerText(win, mid + 1, w, "check your connection", self.s(self.palette.fg2, .{ .italic = true }));
        } else {
            centerText(win, mid, w, "no entries", self.s(self.palette.fg2, .{ .italic = true }));
        }
        return;
    }

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

    const footer_y: u16 = grid_top + geo.rows_visible * geo.slot_h;
    const content_bottom: u16 = top + visible;

    // Peek row (ROD-247): leftover band shows tops of next cover row ("more below").
    // Covers only, clamped to band so never overdraws bottom bar.
    const peek_band: u16 = content_bottom -| footer_y;
    const peek_start: usize = startc + @as(usize, geo.rows_visible) * geo.cols;
    const peeked = peek_band >= 3 and peek_start < results.len;
    if (peeked) {
        var pgeo = geo;
        pgeo.cover_h = peek_band;
        var c: usize = 0;
        while (c < geo.cols and peek_start + c < results.len) : (c += 1) {
            const px: u16 = 2 + @as(u16, @intCast(c)) * geo.slot_w;
            const a = results[peek_start + c];
            const prank: []const u8 = if (vis < scratch.score.len)
                (std.fmt.bufPrint(&scratch.score[vis], "#{d}", .{peek_start + c + 1}) catch "#")
            else
                "#";
            drawCoverCell(self, win, px, footer_y, pgeo, prank, @intCast(prank.len), a);
            vis += 1;
        }
    }

    // Load-more footer only when no peek occupies the band.
    if (!peeked and footer_y < content_bottom) {
        if (slot.loading) {
            const msg = std.fmt.bufPrint(&scratch.msg, "{s} loading more\u{2026}", .{self.spinnerChar()}) catch "loading more\u{2026}";
            centerText(win, footer_y, w, msg, self.s(self.palette.fg2, .{ .italic = true }));
        } else if (slot.exhausted and results.len > 0 and (results.len - 1) / geo.cols < self.discover.scroll + geo.rows_visible) {
            // `results.len > 0` guards `len - 1` underflow on future refactors.
            centerText(win, footer_y, w, "all entries loaded", self.s(self.palette.fg3, .{}));
        }
    }
}

const testing = std.testing;

test "truncateToWidth clips to the card cover_w with a trailing … at both tiers (ROD-245)" {
    var buf: [80]u8 = undefined;
    const wide = "Ore dake Level Up na Ken"; // 24 cols, wider than either tier

    const large = geometry(120, 40, 0, 0);
    try testing.expectEqual(@as(u16, 20), large.cover_w);
    const cut_l = render.truncateToWidth(&buf, wide, large.cover_w);
    try testing.expect(std.mem.endsWith(u8, cut_l, "\u{2026}"));
    try testing.expect(vaxis.gwidth.gwidth(cut_l, .unicode) <= large.cover_w);

    const small = geometry(70, 40, 0, 0);
    try testing.expectEqual(@as(u16, 14), small.cover_w);
    const cut_s = render.truncateToWidth(&buf, wide, small.cover_w);
    try testing.expect(std.mem.endsWith(u8, cut_s, "\u{2026}"));
    try testing.expect(vaxis.gwidth.gwidth(cut_s, .unicode) <= small.cover_w);

    try testing.expectEqualStrings("Frieren", render.truncateToWidth(&buf, "Frieren", large.cover_w));
}

test "geometry: covers grow to fill width from cell pixels, fall back when unknown (ROD-247)" {
    const fb = geometry(120, 40, 0, 0);
    try testing.expectEqual(@as(u16, 7), fb.cover_h);
    try testing.expectEqual(@as(u16, 11), fb.slot_h);

    // Cells ~10×22 px: ~2:3 poster at 20 cols → cover_h ≈ 13.
    const a = geometry(120, 40, 10, 22);
    try testing.expectEqual(@as(u16, 13), a.cover_h);
    try testing.expectEqual(@as(u16, 17), a.slot_h);
    try testing.expect(a.cover_h > fb.cover_h);
    try testing.expectEqual(fb.cols, a.cols);
    try testing.expect(a.rows_visible <= fb.rows_visible);
}

test "formatKindEps: TV·Nep, bare Movie, ??ep for unannounced, null for unmapped (ROD-336)" {
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("TV \u{00B7} 24ep", formatKindEps(&buf, .{ .id = "a", .name = "n", .kind = "TV", .total_episodes = 24 }).?);
    try testing.expectEqualStrings("TV \u{00B7} ??ep", formatKindEps(&buf, .{ .id = "a", .name = "n", .kind = "TV", .total_episodes = null }).?);
    try testing.expectEqualStrings("Movie", formatKindEps(&buf, .{ .id = "a", .name = "n", .kind = "MOVIE", .total_episodes = 1 }).?);
    try testing.expectEqualStrings("Spec \u{00B7} 2ep", formatKindEps(&buf, .{ .id = "a", .name = "n", .kind = "SPECIAL", .total_episodes = 2 }).?);
    try testing.expectEqualStrings("TV \u{00B7} 6ep", formatKindEps(&buf, .{ .id = "a", .name = "n", .kind = "TV_SHORT", .total_episodes = 6 }).?);
    try testing.expect(formatKindEps(&buf, .{ .id = "a", .name = "n" }) == null);
    try testing.expect(formatKindEps(&buf, .{ .id = "a", .name = "n", .kind = "MIXTAPE" }) == null);
}

test "drawCard suppresses NEW on the This Season axis (ROD-336)" {
    const t = std.testing;
    var app: App = .{};
    app.gpa = t.allocator;
    app.now_ms = 1_783_641_600_000; // 2026-07-10 → Summer 2026 cour
    const scratch = try t.allocator.create(app_mod.RenderScratch);
    defer t.allocator.destroy(scratch);

    var screen = try vaxis.Screen.init(t.allocator, .{ .rows = 24, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(t.allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 40, .height = 24, .screen = &screen };

    const geo = geometry(40, 22, 0, 0);
    const a: Anime = .{ .id = "1", .name = "New Show", .season = .summer, .year = 2026 };
    const x: u16 = 2;
    const badge_x: u16 = x + 3; // rank "#2" + gap
    const rank_row: u16 = geo.cover_h;

    app.discover.axis = .trending;
    drawCard(&app, scratch, win, x, 0, geo, 0, 1, a, false);
    try t.expectEqualStrings("N", win.readCell(badge_x, rank_row).?.char.grapheme);

    win.clear();
    app.discover.axis = .this_season;
    drawCard(&app, scratch, win, x, 0, geo, 0, 1, a, false);
    try t.expect(!std.mem.eql(u8, "N", win.readCell(badge_x, rank_row).?.char.grapheme));
}

test "drawCard renders the primary title under title_language (ROD-205)" {
    const t = std.testing;
    var app: App = .{};
    app.gpa = t.allocator;
    const scratch = try t.allocator.create(app_mod.RenderScratch);
    defer t.allocator.destroy(scratch);

    var screen = try vaxis.Screen.init(t.allocator, .{ .rows = 24, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(t.allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 40, .height = 24, .screen = &screen };

    const geo = geometry(40, 22, 0, 0);
    const a: Anime = .{
        .id = "fr",
        .name = "Sousou no Frieren",
        .english_name = "Frieren: Beyond Journey's End",
        .native_name = "葬送のフリーレン",
    };
    const x: u16 = 2;
    const title_row: u16 = geo.cover_h + 1;
    const vis = scratch.title.len; // force putClipped fallback

    app.config.title_language = "romaji";
    drawCard(&app, scratch, win, x, 0, geo, vis, 1, a, false);
    try t.expectEqualStrings("S", win.readCell(x, title_row).?.char.grapheme);

    app.config.title_language = "native";
    drawCard(&app, scratch, win, x, 0, geo, vis, 1, a, false);
    try t.expectEqualStrings("葬", win.readCell(x, title_row).?.char.grapheme);
}
