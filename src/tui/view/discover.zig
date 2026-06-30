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
const cover_render = @import("../cover_render.zig");

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

// AniList cover posters cluster around a 2:3 portrait (~1.42 tall:wide).
const POSTER_H_NUM: u32 = 142; // poster height:width numerator
const POSTER_W_DEN: u32 = 100; // …denominator

/// Cover-box height in cells that makes a ~2:3 poster FILL `cover_w` columns rather
/// than pillarbox inside a too-short box (ROD-247). Terminal cells are taller than
/// wide, so `cover_w * (cell_w_px/cell_h_px) * poster_h_over_w` lands well above the
/// old fixed 7/5. Derived from the terminal's reported cell pixels; when those are
/// unknown (tmux/headless/tests report 0 — kitty covers don't render there anyway)
/// it falls back to the pre-fill height. Never shorter than that fallback.
fn coverHeight(cover_w: u16, fallback: u16, cell_w_px: u16, cell_h_px: u16) u16 {
    if (cell_w_px == 0 or cell_h_px == 0) return fallback;
    const den = @as(u32, cell_h_px) * POSTER_W_DEN;
    if (den == 0) return fallback;
    const num = @as(u32, cover_w) * @as(u32, cell_w_px) * POSTER_H_NUM;
    const h: u32 = (num + den / 2) / den; // round to nearest cell
    return @intCast(@max(@as(u32, fallback), h));
}

/// Resolve the grid geometry for a content area `w` wide by `content_h` tall.
/// `cols = max(1, (w-2)/slot_w)`; the grid sits below the window bar (1 row) and a
/// spacer (1 row), so its height is `content_h - 2`. `cell_w_px`/`cell_h_px` are the
/// terminal's per-cell pixel size (0 when unreported) — they size the cover so it
/// fills its width (ROD-247); pass 0 where only `cols` is needed.
pub fn geometry(w: u16, content_h: u16, cell_w_px: u16, cell_h_px: u16) Geometry {
    const large = w >= 80;
    const slot_w: u16 = if (large) 22 else 16;
    const cover_w: u16 = if (large) 20 else 14;
    const cover_h: u16 = coverHeight(cover_w, if (large) 7 else 5, cell_w_px, cell_h_px);
    const slot_h: u16 = cover_h + 4; // 3 meta rows + 1 gap row (ROD-247)
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

/// Column count for a width — the cursor/scroll math in app.zig needs it without
/// a height. Cover pixels are irrelevant to `cols`, so pass 0.
pub fn gridCols(w: u16) u16 {
    return geometry(w, 0, 0, 0).cols;
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

/// AniList's fixed genre vocabulary mapped to monochrome BMP symbols (ROD-247).
/// On a popularity grid the genre text is repetitive mush, so the card shows it as
/// ambient glyph texture rather than a precise label — the full list lives in the
/// zoom detail pane. Monochrome (not emoji) so it renders deterministically over
/// tmux/Kitty/SSH; width is measured via gwidth at the call site. Unmapped → "".
const GenreGlyph = struct { name: []const u8, glyph: []const u8 };
const genre_glyphs = [_]GenreGlyph{
    .{ .name = "Action", .glyph = "\u{2694}" }, // ⚔ crossed swords
    .{ .name = "Adventure", .glyph = "\u{2691}" }, // ⚑ flag
    .{ .name = "Comedy", .glyph = "\u{263A}" }, // ☺ smiling face
    .{ .name = "Drama", .glyph = "\u{25C6}" }, // ◆ diamond
    .{ .name = "Ecchi", .glyph = "\u{2668}" }, // ♨ hot springs
    .{ .name = "Fantasy", .glyph = "\u{269C}" }, // ⚜ fleur-de-lis (de-starred, ROD-247)
    .{ .name = "Horror", .glyph = "\u{2620}" }, // ☠ skull
    .{ .name = "Mahou Shoujo", .glyph = "\u{273F}" }, // ✿ flower
    .{ .name = "Mecha", .glyph = "\u{2699}" }, // ⚙ gear
    .{ .name = "Music", .glyph = "\u{266A}" }, // ♪ note
    .{ .name = "Mystery", .glyph = "\u{25C8}" }, // ◈ diamond-in-diamond
    .{ .name = "Psychological", .glyph = "\u{25D0}" }, // ◐ half circle
    .{ .name = "Romance", .glyph = "\u{2665}" }, // ♥ heart
    .{ .name = "Sci-Fi", .glyph = "\u{2B21}" }, // ⬡ hexagon
    .{ .name = "Slice of Life", .glyph = "\u{2756}" }, // ❖ ornament
    .{ .name = "Sports", .glyph = "\u{25CE}" }, // ◎ bullseye
    .{ .name = "Supernatural", .glyph = "\u{263D}" }, // ☽ crescent moon (de-starred, ROD-247)
    .{ .name = "Thriller", .glyph = "\u{21AF}" }, // ↯ lightning
};

fn genreGlyph(name: []const u8) []const u8 {
    for (genre_glyphs) |g| {
        if (std.mem.eql(u8, g.name, name)) return g.glyph;
    }
    return "";
}

/// Fill a rectangle with `bg` — the placeholder cover cell (graceful no-art).
fn fillRect(win: vaxis.Window, x: u16, y: u16, w: u16, h: u16, bg: vaxis.Color) void {
    if (w == 0 or h == 0) return;
    const child = win.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = w, .height = h });
    child.fill(.{ .style = .{ .bg = bg } });
}

/// The window-toggle segmented bar: each window prefixed with its `1`-`4`
/// direct-select key (ROD-248) — `[1] Daily · [2] Weekly · …` — so the bar teaches
/// its own bindings. Active window in state.focus+bold, the rest in text.muted,
/// separator dots in text.dim. Passive — the keys driving it live in app.zig's
/// onDiscoverKey.
fn drawWindowBar(self: *const App, win: vaxis.Window, row: u16) void {
    const labels = [_][]const u8{ "Daily", "Weekly", "Monthly", "All-Time" };
    // Static `[N]` literals — vaxis holds the printed slice by reference, so a
    // bufPrint'd scratch would dangle; the keys are fixed (1-4), so literals fit.
    const keys = [_][]const u8{ "[1]", "[2]", "[3]", "[4]" };
    const active = @intFromEnum(self.discover.window);
    var col: u16 = 2;
    for (labels, keys, 0..) |label, keyhint, i| {
        const on = i == active;
        // The `[N]` hint reads at text.muted (fg2) off the active window — legible,
        // since it's the binding we're teaching (text.dim buries it against bg_base);
        // it lifts to the focus tone on the active one so that entry reads as a unit.
        const key_sty = if (on) self.s(self.palette.focus, .{}) else self.s(self.palette.fg2, .{});
        const label_sty = if (on) self.s(self.palette.focus, .{ .bold = true }) else self.s(self.palette.fg2, .{});
        put(win, row, col, keyhint, key_sty);
        col += @as(u16, @intCast(keyhint.len)) + 1; // "[N] "
        put(win, row, col, label, label_sty);
        col += @as(u16, @intCast(label.len));
        if (i + 1 < labels.len) {
            put(win, row, col + 1, "·", self.s(self.palette.fg3, .{}));
            col += 3;
        }
    }
}

/// One feed card: a placeholder cover cell with the rank centered, then the rank,
/// title, and view-count metadata rows. `vis` indexes the per-frame scratch slots
/// (the formatted rank/title/views must outlive vx.render — RenderScratch contract).
fn drawCard(self: *const App, scratch: *RenderScratch, win: vaxis.Window, x: u16, y: u16, geo: Geometry, vis: usize, idx: usize, a: Anime, selected: bool) void {
    // Rank string — reused for the in-cell placeholder and the metadata row.
    const rank: []const u8 = if (vis < scratch.score.len)
        (std.fmt.bufPrint(&scratch.score[vis], "#{d}", .{idx + 1}) catch "#")
    else
        "#";
    const rank_w: u16 = @intCast(rank.len);

    // Cover cell: real art (Kitty image, or a half-block mosaic on non-Kitty
    // terminals) once the slot has it; else the graceful rank placeholder (ROD-243).
    drawCoverCell(self, win, x, y, geo, rank, rank_w, a);

    // Metadata rows under the cover. TOP/NEW are DERIVED render-side (not in the
    // payload, ROD-239): TOP on rank #1 (state.now+bold), NEW on a current-cour
    // release (state.focus+bold). At most one shows.
    const rank_y = y + geo.cover_h;
    // Selection marker (ROD-243): on the rank row (never the cover art, so it can't
    // mask a Kitty image), in the left gutter at x-1 so the rank, badge, and title
    // stay column-anchored at x whether or not the card is selected. x >= 2 (the
    // §3.7 left margin / inter-card gap) so x-1 >= 1 is always a safe empty cell.
    if (selected) put(win, rank_y, x - 1, "▸", self.s(self.palette.focus, .{}));
    put(win, rank_y, x, rank, self.s(self.palette.fg, .{}));
    const badge_x = x + rank_w + 1;
    if (idx == 0) {
        put(win, rank_y, badge_x, "TOP", self.s(self.palette.hot, .{ .bold = true }));
    } else if (self.isNewRelease(a)) {
        put(win, rank_y, badge_x, "NEW", self.s(self.palette.focus, .{ .bold = true }));
    }

    // Score badge (ROD-247), right-anchored at the cover edge on the rank row so it
    // never collides with the left-anchored rank + TOP/NEW. `[NN]` tier-coloured per
    // §2.2; `[--]` for an unenriched / unrated / no-id card. Renders every frame so
    // the column doesn't jump when the page batch-enrich lands.
    if (vis < scratch.disc_badge.len) {
        const badge: []const u8 = if (a.score) |sc|
            std.fmt.bufPrint(&scratch.disc_badge[vis], "[{d}]", .{sc}) catch "[--]"
        else
            "[--]";
        const bx = x + geo.cover_w -| @as(u16, @intCast(badge.len));
        // On a card, `hot` is reserved for the TOP rank pointer (§0: one magenta
        // pointer per row) — cap the 91+ score tier at `fg` so a top-scored #1 card
        // doesn't paint TOP and the badge both in hot+bold and cancel each other.
        // The lower tiers keep the shared scoreStyle ladder.
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
    // Truncate to the card width with a trailing "…" affordance (ROD-245) rather
    // than putClipped's silent cell-boundary clip (DESIGN §2.1/§3.8). The truncated
    // copy lives in scratch so it outlives vx.render(); past the 256-slot cap we
    // fall back to the silent clip (no scratch slot to hold an ellipsised copy).
    if (vis < scratch.title.len) {
        const t = render.truncateToWidth(&scratch.title[vis], a.name, geo.cover_w);
        put(win, rank_y + 1, x, t, title_sty);
    } else {
        putClipped(win, rank_y + 1, x, geo.cover_w, a.name, title_sty);
    }

    if (a.view_count) |vc| {
        const vs: []const u8 = if (vis < scratch.meta.len) formatViews(&scratch.meta[vis], vc) else "";
        put(win, rank_y + 2, x, vs, self.s(self.palette.fg2, .{}));
    } else {
        put(win, rank_y + 2, x, "—", self.s(self.palette.fg3, .{}));
    }

    // Genre glyphs (ROD-247) ride the view-count row, right-anchored at the cover
    // edge — mirrors the score badge column above, and frees the 4th meta row back
    // to a gap so the grid breathes. Up to two genres as monochrome symbols (ambient
    // texture, not a label — the full list is in the zoom). Built straight into
    // disc_genre[vis] so it outlives vx.render(); skipped for unenriched / unmapped.
    if (vis < scratch.disc_genre.len) {
        var glen: usize = 0;
        var shown: usize = 0;
        for (a.genres) |gname| {
            if (shown >= 2) break;
            const sym = genreGlyph(gname);
            if (sym.len == 0) continue;
            const sep: []const u8 = if (shown > 0) " " else ""; // space so two glyphs don't smush
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
            // text.dim: ambient texture, not a label. fg2 was tried and reverted — it
            // made the glyphs compete with the view-count; the space (above) is what
            // fixed legibility, not brightness.
            put(win, rank_y + 2, x + geo.cover_w -| gw, glyphs, self.s(self.palette.fg3, .{}));
        }
    }
}

/// Draw the card's cover cell: the slot's transmitted Kitty image (fitted), else a
/// half-block mosaic when pixels exist without Kitty graphics, else the graceful
/// `bg.surface` + centered `#N` placeholder for loading / no-art cards (ROD-243).
fn drawCoverCell(self: *const App, win: vaxis.Window, x: u16, y: u16, geo: Geometry, rank: []const u8, rank_w: u16, a: Anime) void {
    if (a.thumb) |thumb| {
        if (self.discover_covers.getConst(thumb)) |slot| {
            if (slot.image) |img| {
                const cover_win = win.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = geo.cover_w, .height = geo.cover_h });
                // §8 matte: bg_base so the fit-letterbox matches the canvas, not the
                // placeholder panel.
                cover_win.fill(.{ .style = .{ .bg = self.palette.bg_base } });
                if (cover_render.drawKittyFit(img, cover_win)) return;
                // placement faulted → fall through to the placeholder
            } else if (slot.pixels) |px| {
                const cover_win = win.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = geo.cover_w, .height = geo.cover_h });
                cover_win.fill(.{ .style = .{ .bg = self.palette.bg_base } });
                cover_render.drawHalfBlock(cover_win, .{ .rgba = px.rgba, .w = px.w, .h = px.h }, self.palette.bg_base);
                return;
            }
        }
    }
    // Graceful placeholder (ROD-239): bg.surface fill, rank centered in text.dim.
    const bg = self.palette.bg_surface;
    fillRect(win, x, y, geo.cover_w, geo.cover_h, bg);
    put(win, y + geo.cover_h / 2, x + (geo.cover_w -| rank_w) / 2, rank, self.s(self.palette.fg3, .{ .bg = bg }));
}

/// Full-canvas Discover pass. `top` is the first content row; `visible` the
/// content height; `w` the full width.
pub fn draw(self: *const App, scratch: *RenderScratch, win: vaxis.Window, top: u16, visible: u16, w: u16) void {
    drawWindowBar(self, win, top);

    const grid_top: u16 = top + 2;
    const cp = self.cellPx();
    const geo = geometry(w, visible, cp[0], cp[1]);
    const slot = self.discover.activeSlot();
    const results = slot.results.items;

    if (results.len == 0) {
        const mid: u16 = grid_top + (if (visible > 2) visible - 2 else 0) / 2;
        if (slot.loading) {
            // A retry sets loading, so the spinner takes precedence over a stale
            // error. After ~3s the slow path escalates focus→hot + "taking a
            // moment…", matching the bottom-bar spinner (§4.8/§5.6).
            const slow = self.isSlowPath();
            const label: []const u8 = if (slow) "taking a moment\u{2026}" else "loading popular\u{2026}";
            const color = if (slow) self.palette.hot else self.palette.focus;
            const msg = std.fmt.bufPrint(&scratch.msg, "{s} {s}", .{ self.spinnerChar(), label }) catch label;
            centerText(win, mid, w, msg, self.s(color, .{}));
        } else if (slot.failed) {
            // §9.3b graceful offline — the feed is unreachable, not empty. Heading
            // is state.now+bold (§4.7); the sub-line is text.muted, an actionable hint.
            centerText(win, mid -| 1, w, "[!] can't reach the feed", self.s(self.palette.hot, .{ .bold = true }));
            centerText(win, mid + 1, w, "check your connection", self.s(self.palette.fg2, .{ .italic = true }));
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

    const footer_y: u16 = grid_top + geo.rows_visible * geo.slot_h;
    const content_bottom: u16 = top + visible;

    // Peek row (ROD-247): fill the leftover band below the last full row with the
    // TOP of the next card-row's covers, so the grid signals "more below" instead of
    // leaving dead space. Covers only — the meta would fall outside the band — and
    // the cover height is clamped to the band so it can never overdraw the bottom
    // bar. Kitty art scales to the band, so it reads best when the leftover is tall
    // (a short band narrows the poster); a clean bottom-crop isn't possible since
    // vaxis sizes images to the window rather than cropping.
    const peek_band: u16 = content_bottom -| footer_y;
    const peek_start: usize = startc + @as(usize, geo.rows_visible) * geo.cols;
    const peeked = peek_band >= 3 and peek_start < results.len;
    if (peeked) {
        var pgeo = geo;
        pgeo.cover_h = peek_band; // bound the cover to the band; never spills past content
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

    // Load-more footer, on the row just below the last card slot — only when no peek
    // row occupies that band. "loading more…" while the next page is in flight
    // (results already on screen, so it's a page-N fetch, not the initial spinner);
    // "all entries loaded" once the feed is exhausted and the last card is in view.
    if (!peeked and footer_y < content_bottom) {
        if (slot.loading) {
            const msg = std.fmt.bufPrint(&scratch.msg, "{s} loading more\u{2026}", .{self.spinnerChar()}) catch "loading more\u{2026}";
            centerText(win, footer_y, w, msg, self.s(self.palette.fg2, .{ .italic = true }));
        } else if (slot.exhausted and results.len > 0 and (results.len - 1) / geo.cols < self.discover.scroll + geo.rows_visible) {
            // `results.len > 0` is already guaranteed by the empty-state early
            // return above; kept explicit so a future refactor can't reintroduce a
            // usize underflow on `results.len - 1`. Plain text.dim — a status fact,
            // not an annotation (§1.3 reserves italic for those).
            centerText(win, footer_y, w, "all entries loaded", self.s(self.palette.fg3, .{}));
        }
    }
}

const testing = std.testing;

test "truncateToWidth clips to the card cover_w with a trailing … at both tiers (ROD-245)" {
    // The title row gets exactly `cover_w` columns; a wider title must cut on a
    // grapheme boundary with the "…" affordance (§2.1/§3.8), and a title that fits
    // must pass through untouched (no spurious ellipsis). truncateToWidth owns the
    // cut — this pins the card's contract at its real per-tier widths.
    var buf: [80]u8 = undefined;
    const wide = "Ore dake Level Up na Ken"; // 24 cols, wider than either tier

    const large = geometry(120, 40, 0, 0); // w >= 80 → cover_w 20
    try testing.expectEqual(@as(u16, 20), large.cover_w);
    const cut_l = render.truncateToWidth(&buf, wide, large.cover_w);
    try testing.expect(std.mem.endsWith(u8, cut_l, "\u{2026}"));
    try testing.expect(vaxis.gwidth.gwidth(cut_l, .unicode) <= large.cover_w);

    const small = geometry(70, 40, 0, 0); // w < 80 → cover_w 14
    try testing.expectEqual(@as(u16, 14), small.cover_w);
    const cut_s = render.truncateToWidth(&buf, wide, small.cover_w);
    try testing.expect(std.mem.endsWith(u8, cut_s, "\u{2026}"));
    try testing.expect(vaxis.gwidth.gwidth(cut_s, .unicode) <= small.cover_w);

    // A title that already fits the wider tier is returned verbatim.
    try testing.expectEqualStrings("Frieren", render.truncateToWidth(&buf, "Frieren", large.cover_w));
}

test "geometry: covers grow to fill width from cell pixels, fall back when unknown (ROD-247)" {
    // Unknown pixel metrics (tmux/headless report 0) → the pre-fill fallback box.
    const fb = geometry(120, 40, 0, 0);
    try testing.expectEqual(@as(u16, 7), fb.cover_h);
    try testing.expectEqual(@as(u16, 11), fb.slot_h); // cover_h + 4 meta rows

    // Cells ~10×22 px (taller than wide): a ~2:3 poster needs a taller box to fill
    // the 20-col width → 20 * 10/22 * 1.42 ≈ 13. slot_h tracks cover_h + 4.
    const a = geometry(120, 40, 10, 22);
    try testing.expectEqual(@as(u16, 13), a.cover_h);
    try testing.expectEqual(@as(u16, 17), a.slot_h);
    try testing.expect(a.cover_h > fb.cover_h); // grew to fill width
    try testing.expectEqual(fb.cols, a.cols); // cover height never moves the column count
    // Fewer card rows survive the taller slot — the accepted trade for filled covers.
    try testing.expect(a.rows_visible <= fb.rows_visible);
}
