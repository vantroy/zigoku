//! Zigoku — Detail view render pass: poster cover (Kitty / half-block / fallback),
//! metadata header, and the episode grid. Extracted from app.zig along the
//! tick/draw seam (ROD-144). Cover *state* (caches, in-flight tracking, failure
//! cooldown) lives in app.zig; this is the pure render of it.

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const render = @import("../render.zig");
const domain = @import("../../domain.zig");
const store_mod = @import("../../store.zig");

const App = app_mod.App;
const Anime = domain.Anime;
const AnimeRecord = store_mod.AnimeRecord;
const DetailRenderInfo = App.DetailRenderInfo;
const put = render.put;
const putClipped = render.putClipped;
const centerText = render.centerText;
const drawWrappedText = render.drawWrappedText;

/// Width (in cols) at and above which a History-opened detail pane splits into
/// two columns (cover + header left, synopsis + grid right) — ROD-113. Aligns
/// with the §3.2 cover-art tier so the right column is always ≥ ~34 cols.
pub const detail_two_col_min: u16 = 100;

/// Pure predicate for the two-column gate, exposed for tests.
pub fn isTwoColumn(w: u16) bool {
    return w >= detail_two_col_min;
}

/// §3.3 cover-width tier from the effective pane/column width (ROD-170): the
/// cover scales with the pane it lives in, not the terminal. Hard cap 20; 0 below
/// 25 cols (no room for a poster). Pure, exposed for tests.
pub fn coverWidthFor(pane_w: u16) u16 {
    return if (pane_w >= 40) 20 else if (pane_w >= 25) 14 else 0;
}

fn ensureCoverImage(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer) bool {
    if (!vx.caps.kitty_graphics) return false;
    if (self.cover.image != null) return true;
    const px = self.cover.pixels orelse return false;
    if (px.w == 0 or px.h == 0 or px.w > std.math.maxInt(u16) or px.h > std.math.maxInt(u16)) return false;

    const enc_len = std.base64.standard.Encoder.calcSize(px.rgba.len);
    const b64 = self.gpa.alloc(u8, enc_len) catch return false;
    defer self.gpa.free(b64);
    const encoded = std.base64.standard.Encoder.encode(b64, px.rgba);

    self.cover.image = vx.transmitPreEncodedImage(
        writer,
        encoded,
        @intCast(px.w),
        @intCast(px.h),
        .rgba,
    ) catch return false;
    return true;
}

/// Non-Kitty fallback (§7.5, ROD-110 / Mira #5). With decoded pixels we draw
/// a half-block mosaic that preserves the poster's structure; without them
/// (decode failed but a dominant colour survived, or the kitty upload faulted)
/// we degrade to the flat dominant-colour fill that always worked.
fn drawFallbackCover(self: *const App, cover_win: vaxis.Window) void {
    if (self.cover.pixels != null) {
        drawHalfBlockCover(self, cover_win);
    } else {
        cover_win.fill(.{ .style = .{ .bg = self.cover.fallback_color } });
    }
}

/// Sample one half-pixel of the letterboxed cover. `(gx, gy)` is a half-pixel
/// grid coordinate (grid is `cols` wide × `rows*2` tall); cells outside the
/// fitted image region return `bg_base` so the letterbox matte matches the pane
/// (ROD-164 / DESIGN.md §8 footprint fill).
fn sampleHalfBlock(
    self: *const App,
    px: anytype,
    gx: u32,
    gy: u32,
    off_x: u32,
    off_y: u32,
    fit_w: u32,
    fit_h: u32,
) vaxis.Color {
    if (gx < off_x or gy < off_y) return self.palette.bg_base;
    const fx = gx - off_x;
    const fy = gy - off_y;
    if (fx >= fit_w or fy >= fit_h) return self.palette.bg_base;
    const sx = @min(px.w - 1, fx * px.w / fit_w);
    const sy = @min(px.h - 1, fy * px.h / fit_h);
    const idx = (@as(usize, sy) * px.w + sx) * 4;
    return .{ .rgb = .{ px.rgba[idx], px.rgba[idx + 1], px.rgba[idx + 2] } };
}

/// Render decoded cover pixels as a half-block mosaic: each cell packs two
/// vertically-stacked samples via `▀` (upper half = fg, lower half = bg),
/// doubling vertical resolution over a flat fill. The image is letterboxed
/// into the cell grid via `halfBlockFit` (aspect-correct using the terminal's
/// reported cell pixel metrics) so posters stay poster-shaped on non-Kitty
/// terminals regardless of cell aspect ratio.
fn drawHalfBlockCover(self: *const App, cover_win: vaxis.Window) void {
    const px = self.cover.pixels orelse return;
    const cols = cover_win.width;
    const rows = cover_win.height;
    if (cols == 0 or rows == 0 or px.w == 0 or px.h == 0) return;

    const grid_w: u32 = cols;
    const grid_h: u32 = @as(u32, rows) * 2;

    // Terminal pixels per cell, if reported — lets halfBlockFit correct for
    // non-2:1 cells (e.g. gnome-terminal 8x18) instead of squishing posters.
    // 0/0 → square-half-pixel assumption inside halfBlockFit.
    const sw = cover_win.screen.width;
    const sh = cover_win.screen.height;
    const ppc: u32 = if (sw != 0) (std.math.divCeil(u32, @intCast(cover_win.screen.width_pix), sw) catch 0) else 0;
    const pph: u32 = if (sh != 0) (std.math.divCeil(u32, @intCast(cover_win.screen.height_pix), sh) catch 0) else 0;

    const fit = app_mod.CoverState.halfBlockFit(px.w, px.h, grid_w, grid_h, ppc, pph);

    var ry: u16 = 0;
    while (ry < rows) : (ry += 1) {
        const top_y = @as(u32, ry) * 2;
        var cx: u16 = 0;
        while (cx < cols) : (cx += 1) {
            const top = sampleHalfBlock(self, px, cx, top_y, fit.off_x, fit.off_y, fit.w, fit.h);
            const bot = sampleHalfBlock(self, px, cx, top_y + 1, fit.off_x, fit.off_y, fit.w, fit.h);
            put(cover_win, ry, cx, "▀", .{ .fg = top, .bg = bot });
        }
    }
}

fn drawKittyCover(self: *const App, img: vaxis.Image, cover_win: vaxis.Window) void {
    const cols = cover_win.screen.width;
    const rows = cover_win.screen.height;
    if (cols == 0 or rows == 0 or cover_win.width == 0 or cover_win.height == 0) return;

    const pix_per_col = std.math.divCeil(usize, cover_win.screen.width_pix, cols) catch return;
    const pix_per_row = std.math.divCeil(usize, cover_win.screen.height_pix, rows) catch return;
    const slot_w = pix_per_col * cover_win.width;
    const slot_h = pix_per_row * cover_win.height;
    if (slot_w == 0 or slot_h == 0) return;

    const img_w = @as(usize, img.width);
    const img_h = @as(usize, img.height);
    if (img_w == 0 or img_h == 0) return;

    var draw_cols: u16 = cover_win.width;
    var draw_rows: u16 = cover_win.height;

    if (img_w * slot_h > img_h * slot_w) {
        const fit_h_px = @max(@as(usize, 1), (img_h * slot_w) / img_w);
        draw_rows = @intCast(@max(@as(usize, 1), @min(@as(usize, cover_win.height), fit_h_px / pix_per_row)));
    } else if (img_w * slot_h < img_h * slot_w) {
        const fit_w_px = @max(@as(usize, 1), (img_w * slot_h) / img_h);
        draw_cols = @intCast(@max(@as(usize, 1), @min(@as(usize, cover_win.width), fit_w_px / pix_per_col)));
    }

    const draw_win = cover_win.child(.{
        .x_off = @intCast((cover_win.width - draw_cols) / 2),
        .y_off = @intCast((cover_win.height - draw_rows) / 2),
        .width = draw_cols,
        .height = draw_rows,
    });
    img.draw(draw_win, .{ .scale = .fit }) catch drawFallbackCover(self, cover_win);
}

fn coverSlotHeight(win: vaxis.Window, cover_w: u16, max_h: u16) u16 {
    if (cover_w == 0 or max_h == 0) return 0;
    if (win.screen.width == 0 or win.screen.height == 0) return max_h;

    const pix_per_col = std.math.divCeil(u32, win.screen.width_pix, win.screen.width) catch return max_h;
    const pix_per_row = std.math.divCeil(u32, win.screen.height_pix, win.screen.height) catch return max_h;
    if (pix_per_col == 0 or pix_per_row == 0) return max_h;

    const slot_w_px = @as(u32, cover_w) * pix_per_col;
    const desired_h_px = std.math.divCeil(u32, slot_w_px * 3, 2) catch return max_h;
    const cover_h = std.math.divCeil(u32, desired_h_px, pix_per_row) catch return max_h;
    return @intCast(@max(@as(u32, 1), @min(@as(u32, max_h), cover_h)));
}

/// Cover-art block (§3.3 + §7.3/§7.5), drawn at the top of `win`. Returns the
/// rows consumed (cover height + 1 blank spacer), or 0 when the width tier has
/// no cover slot. Shared by the single-/two-column detail layouts and the
/// History preview pane (ROD-113). Width stays fixed by tier; height derives
/// from terminal pixel geometry so the panel stays poster-shaped, not cell-tall.
fn drawCover(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer, win: vaxis.Window, anime: ?Anime, pane_w: u16) u16 {
    // ROD-170 §3.3: the cover scales with the pane it lives in (effective column
    // width), not the terminal — so a persistent two-pane detail gets a poster
    // sized to it instead of to the whole screen. Tiers per §3.3; hard cap 20
    // (the hero block stays "ghostly", not gaudy).
    const cover_w: u16 = coverWidthFor(pane_w);
    if (cover_w == 0) return 0;
    const max_h: u16 = if (pane_w >= 40) 28 else 20;
    const cover_h: u16 = coverSlotHeight(win, cover_w, max_h);
    if (cover_h == 0) return 0;

    const cover_win = win.child(.{ .x_off = 0, .y_off = 0, .width = cover_w, .height = cover_h });
    if (anime) |a| {
        const same_id = self.cover.for_id != null and std.mem.eql(u8, self.cover.for_id.?, a.id);
        const has_pixels = self.cover.pixels != null and same_id;
        const showing_spinner = self.cover.loading and same_id;
        // §8 footprint fill (ROD-164): a rendered poster's slot is bg_base so
        // the fit-matte matches the pane; placeholders keep the bg_surface
        // panel. `drawing_poster` mirrors the exact condition for the
        // has_pixels poster branch below, so the fill matches the branch taken.
        const drawing_poster = a.thumb != null and !showing_spinner and has_pixels;
        cover_win.fill(.{ .style = .{ .bg = if (drawing_poster) self.palette.bg_base else self.palette.bg_surface } });
        if (a.thumb == null) {
            if (cover_h > 1) centerText(cover_win, cover_h / 2, cover_w, "no art yet", self.s(self.palette.fg3, .{ .italic = true }));
        } else if (showing_spinner) {
            const spin = std.fmt.bufPrint(&self.scratch.detail_msg, "{s}", .{self.spinnerChar()}) catch "⠋";
            // §3.6 slow-path: shift cyan → hot once the wait crosses the
            // long-wait threshold (Mira #4), mirroring the bottom-bar spinner.
            const spin_color = if (self.isSlowPath()) self.palette.hot else self.palette.focus;
            centerText(cover_win, cover_h / 2, cover_w, spin, self.s(spin_color, .{}));
        } else if (has_pixels) {
            if (ensureCoverImage(self, vx, writer)) {
                if (self.cover.image) |img| {
                    drawKittyCover(self, img, cover_win);
                } else {
                    drawFallbackCover(self, cover_win);
                }
            } else {
                drawFallbackCover(self, cover_win);
            }
        } else if (cover_h > 1) {
            centerText(cover_win, cover_h / 2, cover_w, "no art yet", self.s(self.palette.fg3, .{ .italic = true }));
        }
    } else {
        cover_win.fill(.{ .style = .{ .bg = self.palette.bg_surface } });
        if (cover_h > 1) centerText(cover_win, cover_h / 2, cover_w, "no art yet", self.s(self.palette.fg3, .{ .italic = true }));
    }
    return cover_h + 1;
}

// ── ROD-141: kanji status chip mapping ───────────────────────────────────────

/// The result of a status→chip lookup: kanji text and which palette field
/// carries its color. Using a field accessor avoids capturing a Palette
/// pointer inside a comptime value; the caller resolves the color at render.
const StatusChip = struct {
    kanji: []const u8,
    /// One of: .hot (state.now), .fg2 (text.muted), .focus (state.focus),
    ///         .fg3 (text.dim), .warn (state.warn).
    color_field: enum { hot, fg2, focus, fg3, warn },
};

/// DESIGN.md §2.3: map an AniList or AllAnime raw status string to the chip
/// definition. Case-insensitive; both vocabularies accepted. Returns null for
/// unknown / empty strings — callers must omit the chip, never render empty.
///
/// AniList vocab: FINISHED / RELEASING / NOT_YET_RELEASED / CANCELLED
/// AllAnime vocab: RELEASING / ongoing (case-insensitive).
pub fn statusChipFor(status: []const u8) ?StatusChip {
    if (std.ascii.eqlIgnoreCase(status, "RELEASING") or
        std.ascii.eqlIgnoreCase(status, "ongoing"))
        return .{ .kanji = "放映中", .color_field = .hot };

    if (std.ascii.eqlIgnoreCase(status, "FINISHED"))
        return .{ .kanji = "完結", .color_field = .fg2 };

    if (std.ascii.eqlIgnoreCase(status, "NOT_YET_RELEASED"))
        return .{ .kanji = "放映前", .color_field = .focus };

    if (std.ascii.eqlIgnoreCase(status, "CANCELLED"))
        return .{ .kanji = "中止", .color_field = .fg3 };

    // Hiatus is not a standard AniList/AllAnime value but is listed in §2.3 for
    // completeness. Map it too in case a future source uses it.
    if (std.ascii.eqlIgnoreCase(status, "HIATUS"))
        return .{ .kanji = "休止中", .color_field = .warn };

    return null;
}

/// Resolve a StatusChip's color from the active palette.
fn chipColor(self: *const App, chip: StatusChip) vaxis.Color {
    return switch (chip.color_field) {
        .hot   => self.palette.hot,
        .fg2   => self.palette.fg2,
        .focus => self.palette.focus,
        .fg3   => self.palette.fg3,
        .warn  => self.palette.warn,
    };
}

// ── ROD-141 minimum synopsis cap (ROD-137 grid constraint) ───────────────────

/// Minimum guaranteed grid rows at the worst supported geometry (35-row terminal).
/// Used by synopsisCap to reserve enough rows for a usable episode grid.
const min_grid_rows: u16 = 2;

/// How many synopsis rows to allow in the single-column layout, given the
/// remaining height after all header rows have been placed and the grid's
/// minimum reservation is subtracted.
///
/// ROD-137/ROD-141 constraint: at 35-row terminal, the episode grid must have
/// ≥2 visible rows for a ≥28-episode show. The cap is:
///     max(1, remaining_h - (1 spacer + min_grid_rows))
/// where `remaining_h = h - header_rows_so_far`.
fn synopsisCap(remaining_h: u16) u16 {
    const reserved: u16 = 1 + min_grid_rows; // 1 spacer + 2 grid rows
    if (remaining_h <= reserved) return 1;
    return remaining_h - reserved;
}

// ── draw helpers ─────────────────────────────────────────────────────────────

/// Title (bold name or "—" placeholder). Returns the next free row.
fn drawTitle(self: *App, win: vaxis.Window, w: u16, info: DetailRenderInfo, start_row: u16) u16 {
    if (info.anime != null and !std.mem.eql(u8, info.title, "—")) {
        putClipped(win, start_row, 0, w, info.title, self.s(self.palette.fg, .{ .bold = true }));
    } else {
        putClipped(win, start_row, 0, w, info.title, self.s(self.palette.fg3, .{}));
    }
    return start_row + 1;
}

/// Alternate title rows (ROD-141): english_name if it differs from the romaji
/// name already on the title line; native_name in italic (foreign-language rule
/// DESIGN.md §1.3). Both are nullable — emit only present, non-empty values.
/// Returns the next free row.
fn drawAltTitles(self: *App, win: vaxis.Window, w: u16, h: u16, anime: Anime, start_row: u16) u16 {
    var row = start_row;

    // English name — only if it meaningfully differs from the displayed title.
    if (anime.english_name) |eng| {
        if (eng.len > 0 and !std.mem.eql(u8, eng, anime.name) and row < h) {
            putClipped(win, row, 0, w, eng, self.s(self.palette.fg2, .{}));
            row += 1;
        }
    }

    // Native name — italic per the foreign-language rule (§1.3).
    if (anime.native_name) |nat| {
        if (nat.len > 0 and row < h) {
            putClipped(win, row, 0, w, nat, self.s(self.palette.fg2, .{ .italic = true }));
            row += 1;
        }
    }

    return row;
}

/// Kanji chips row (ROD-141, DESIGN.md §2.3 / §4.4): status chip followed by
/// season+year chip on a single line, two spaces between them. Chips are plain
/// text spans (no box), flush at column 0 to align with the title stack (§4.4).
/// Emits nothing when both are absent. Returns the next free row.
fn drawChips(self: *App, win: vaxis.Window, h: u16, anime: Anime, start_row: u16) u16 {
    if (start_row >= h) return start_row;

    const status_chip: ?StatusChip = if (anime.status) |st|
        (if (st.len > 0) statusChipFor(st) else null)
    else
        null;

    // Season chip: "冬 2026" etc. Only when both season and year are present.
    const has_season = anime.season != null and anime.year != null;

    if (status_chip == null and !has_season) return start_row; // nothing to emit

    // Render the whole row as one `win.print` of styled segments so vaxis
    // advances wide-glyph (kanji) cell widths in a single consistent pass while
    // each span keeps its own color (§2.3). Two spaces separate the two chips.
    // Chips sit flush at col 0, aligning with the title/alt-title stack above —
    // §4.4's "leading space" is for the chip rendered *inline after the title*;
    // here it lives on its own row, so a leading indent would only misalign it
    // (Mira review).
    //
    // CRITICAL: the season text must live in App-owned storage, not a stack
    // local. vaxis cells hold a *slice* into the segment text (not a copy), and
    // the frame isn't emitted until `render()` — well after this function
    // returns. A stack buffer would dangle and render as garbage (ROD-141).
    const fg3 = self.s(self.palette.fg3, .{});
    const season_text: []const u8 = if (has_season)
        std.fmt.bufPrint(&self.detail_season_buf, "{s} {d}", .{ anime.season.?.kanji(), anime.year.? }) catch ""
    else
        "";

    var segs: [3]vaxis.Segment = undefined;
    var n: usize = 0;
    if (status_chip) |chip| {
        segs[n] = .{ .text = chip.kanji, .style = self.s(chipColor(self, chip), .{}) };
        n += 1;
    }
    if (season_text.len > 0) {
        // Two-space gap before the season chip when a status chip precedes it.
        if (status_chip != null) {
            segs[n] = .{ .text = "  ", .style = fg3 };
            n += 1;
        }
        segs[n] = .{ .text = season_text, .style = self.s(self.palette.focus, .{}) };
        n += 1;
    }
    // wrap: .none — these prints target the multi-row pane window, so without it
    // a chip straddling the pane edge would fold onto the next row (the hairline).
    _ = win.print(segs[0..n], .{ .row_offset = start_row, .col_offset = 0, .wrap = .none });

    return start_row + 1;
}

/// Score line — "[--/100]" until AniList enrichment fills `a.score`, then tiered
/// rendering per §2.2. Genres (if any) follow on the same line separated by
/// ` · ` (§4.3 mock format). Returns the next free row.
fn drawScore(self: *App, win: vaxis.Window, w: u16, anime: ?Anime, start_row: u16) u16 {
    const score_text: []const u8 = if (anime) |a| blk: {
        if (a.score) |score| {
            if (score >= 91) {
                break :blk std.fmt.bufPrint(&self.detail_score_buf, "✦ [{d}/100]", .{score}) catch "[--/100]";
            }
            break :blk std.fmt.bufPrint(&self.detail_score_buf, "[{d}/100]", .{score}) catch "[--/100]";
        }
        break :blk "[--/100]";
    } else "[--/100]";
    const score_style = if (anime) |a| blk: {
        if (a.score) |score| {
            if (score >= 91) break :blk self.s(self.palette.hot, .{ .bold = true });
            if (score >= 76) break :blk self.s(self.palette.fg, .{});
            if (score >= 51) break :blk self.s(self.palette.fg2, .{});
        }
        break :blk self.s(self.palette.fg3, .{});
    } else self.s(self.palette.fg3, .{});

    // Render the score, then genres, as chained `win.print`s, advancing by the
    // print's *returned* cursor column. Tracking columns by slice length drifts:
    // the "✦" star (3 bytes, 1 col) and the " · " separator's "·" (2 bytes, 1 col)
    // each overcount, opening phantom gaps before the genres (ROD-141 / Mira
    // review). Letting vaxis report the real display column closes them.
    // wrap: .none on every print — these target the multi-row pane window, so a
    // segment reaching the pane edge must stop, not fold onto the next row (which
    // would overwrite the hairline with genre text at narrow widths).
    var col = win.print(
        &.{.{ .text = score_text, .style = score_style }},
        .{ .row_offset = start_row, .col_offset = 0, .wrap = .none },
    ).col;

    // ROD-141 genres: " · Genre1 · Genre2…" appended to the score line.
    // Only emitted when genres is non-empty (§9.1: omit entirely when null/empty).
    if (anime) |a| {
        for (a.genres) |genre| {
            if (col >= w) break;
            col = win.print(&.{
                .{ .text = " · ", .style = self.s(self.palette.fg3, .{}) },
                .{ .text = genre, .style = self.s(self.palette.fg2, .{}) },
            }, .{ .row_offset = start_row, .col_offset = col, .wrap = .none }).col;
        }
    }

    return start_row + 1;
}

/// Hairline divider — clipped to width so it never wraps onto the next row.
/// "─" is 3 UTF-8 bytes; we need exactly `cols` glyphs = `cols * 3` bytes.
fn drawHairline(self: *App, win: vaxis.Window, w: u16, row: u16) void {
    const cols: u16 = @min(w, 160);
    put(win, row, 0, ("─" ** 160)[0 .. @as(usize, cols) * 3], self.s(self.palette.chrome, .{}));
}

/// Title + chips + score/genres + hairline + episode-count metadata stack
/// (ROD-141). Returns the next free row. `h` bounds each step so a short pane
/// never overdraws.
fn drawHeader(self: *App, win: vaxis.Window, w: u16, h: u16, info: DetailRenderInfo, start_row: u16) u16 {
    var row = drawTitle(self, win, w, info, start_row);

    // Alternate titles (english + native) — only present when the Anime has them.
    if (info.anime) |a| {
        if (row < h) row = drawAltTitles(self, win, w, h, a, row);
    }

    // Kanji chips: status + season/year. Omitted entirely when both are absent.
    if (info.anime) |a| {
        if (row < h) row = drawChips(self, win, h, a, row);
    }

    row = drawScore(self, win, w, info.anime, row);

    // Hairline. The row advance sits inside the height guard (the original inline
    // code advanced unconditionally) — only divergent at pane h≤2, which
    // layout()'s h<4 guard already rules out, so this is a tidy-up, not a
    // behavior change. Elara ROD-113 N2.
    if (row < h) {
        drawHairline(self, win, w, row);
        row += 1;
    }

    // Metadata: episode count, falling back to AniList total when needed.
    if (row < h) {
        const meta_style = if (info.has_meta) self.s(self.palette.fg2, .{}) else self.s(self.palette.fg3, .{});
        putClipped(win, row, 0, w, info.meta, meta_style);
        row += 1;
    }
    return row;
}

/// Synopsis — the real description when present, otherwise the null-degrade
/// stub. Word-wraps within `w`, capped at `max_lines` rows.
/// Returns the next free row.
fn drawSynopsisLimited(self: *App, win: vaxis.Window, w: u16, h: u16, anime: ?Anime, start_row: u16, max_lines: u16) u16 {
    var row = start_row;
    if (row >= h) return row;
    const cap = @min(max_lines, h - row);
    if (anime) |a| {
        if (a.description) |desc| {
            const lines_written = drawWrappedText(win, row, 0, w, cap, desc, self.s(self.palette.fg2, .{}));
            // If we hit the cap (description likely continues), place a "…" ellipsis
            // marker at the trailing edge of the last rendered line (DESIGN.md §1.3
            // / line ~95: "synopsis ellipsis marker"). The marker is italic text.dim.
            // Truncation is inferred when lines_written >= cap — an exact cap-fill
            // from a perfectly-fitting description is a false positive, but the visual
            // cost is a dim "…" at the end of an already-complete line: acceptable.
            if (lines_written >= cap and cap > 0 and w > 0) {
                // "…" is 3 UTF-8 bytes but 1 display column. Place at the last col.
                const ellipsis_col: u16 = w - 1;
                put(win, row + cap - 1, ellipsis_col, "…", self.s(self.palette.fg3, .{ .italic = true }));
            }
            row += lines_written;
        } else {
            putClipped(win, row, 0, w, "no synopsis yet", self.s(self.palette.fg2, .{ .italic = true }));
            row += 1;
        }
    } else {
        putClipped(win, row, 0, w, "no synopsis yet", self.s(self.palette.fg2, .{ .italic = true }));
        row += 1;
    }
    return row;
}

/// Synopsis — uncapped variant used in the two-column layout where the right
/// column is dedicated to synopsis + grid (no header rows competing for height).
fn drawSynopsis(self: *App, win: vaxis.Window, w: u16, h: u16, anime: ?Anime, start_row: u16) u16 {
    var row = start_row;
    if (row >= h) return row;
    if (anime) |a| {
        if (a.description) |desc| {
            row += drawWrappedText(win, row, 0, w, h - row, desc, self.s(self.palette.fg2, .{}));
        } else {
            putClipped(win, row, 0, w, "no synopsis yet", self.s(self.palette.fg2, .{ .italic = true }));
            row += 1;
        }
    } else {
        putClipped(win, row, 0, w, "no synopsis yet", self.s(self.palette.fg2, .{ .italic = true }));
        row += 1;
    }
    return row;
}

/// Episode grid placement: a blank spacer row, then the grid filling the rest
/// of `win` below `start_row`.
fn drawGrid(self: *App, win: vaxis.Window, w: u16, h: u16, start_row: u16) void {
    var row = start_row;
    if (row < h) row += 1; // blank line before grid
    if (row >= h) return;
    const grid_h: u16 = h - row;
    const grid_win = win.child(.{ .x_off = 0, .y_off = row, .width = w, .height = grid_h });
    drawEpisodeGrid(self, grid_win, w, grid_h);
}

pub fn drawDetailPane(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer, win: vaxis.Window, w: u16, h: u16, term_w: u16, two_col: bool) void {
    if (w < 10) return;

    const info = self.detailRenderInfo();

    // Two-column layout (ROD-113): cover + header on the left (~38%), synopsis +
    // episode grid on the right. Only engaged for History-opened detail at wide
    // widths; the narrow Browse preview and sub-100-col terminals keep the
    // single vertical stack. Mirrors the §3.2 list/detail split grammar.
    // Gate on terminal width, not the pane width `w`: the pane is `term_w - 2`,
    // so a `w`-based gate would lag the History list preview's ≥100 boundary by
    // 2 cols (you'd get a preview but a single-column detail at 100–101 cols).
    // Elara/Astra ROD-113 review.
    if (two_col and isTwoColumn(term_w)) {
        // Floor of 20 keeps the 20-col cover block fitting the left column even
        // when the gate drops (ROD-170's persistent-pane threshold). Dead at the
        // current ≥100 gate (38-col min) but load-bearing once the gate lowers.
        const left_w: u16 = @max(20, (w * 38) / 100);
        const right_x: u16 = left_w + 2; // 2-cell gap, no border (§3.1)
        const right_w: u16 = if (w > right_x) w - right_x else 0;
        const left_win = win.child(.{ .x_off = 0, .y_off = 0, .width = left_w, .height = h });
        const right_win = win.child(.{ .x_off = @intCast(right_x), .y_off = 0, .width = right_w, .height = h });

        const lrow = drawCover(self, vx, writer, left_win, info.anime, w);
        _ = drawHeader(self, left_win, left_w, h, info, lrow);

        // Two-column: synopsis gets the full right column height minus the grid
        // reservation — no synopsis cap needed here, the column is dedicated.
        const rrow = drawSynopsis(self, right_win, right_w, h, info.anime, 0);
        drawGrid(self, right_win, right_w, h, rrow);
        return;
    }

    // Single-column layout: cap synopsis to leave ≥2 grid rows (ROD-137).
    // Row budget math (worst case, 35-row terminal, cover ~7 rows + 1 spacer):
    //   cover=8, title=1, [alt_titles≤2], chips≤1, score=1, hl=1, meta=1, hl=1
    //   → header uses ≤16 rows, leaving ≥16 for synopsis+grid at h=32.
    //   synopsisCap reserves 1 spacer + 2 grid rows = 3, so max synopsis = h - header - 3.
    var row: u16 = drawCover(self, vx, writer, win, info.anime, w);
    row = drawHeader(self, win, w, h, info, row);
    const cap = synopsisCap(if (h > row) h - row else 0);
    row = drawSynopsisLimited(self, win, w, h, info.anime, row, cap);
    drawGrid(self, win, w, h, row);
}

/// History list preview pane (ROD-113): cover + title + score + status +
/// synopsis for the focused history entry, in a single narrow column. No
/// episode grid — that is a detail-view affordance, not a preview one. Fed an
/// explicit record because `detailRenderInfo` resolves to null in the History
/// list view (active_view == .history), so the pane cannot read it from state.
pub fn drawHistoryPreview(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer, win: vaxis.Window, w: u16, h: u16, rec: AnimeRecord) void {
    if (w < 10) return;
    const anime = App.animeFromHistoryRecord(rec);

    var row: u16 = drawCover(self, vx, writer, win, anime, w);

    if (row < h) {
        if (anime.name.len > 0) {
            putClipped(win, row, 0, w, anime.name, self.s(self.palette.fg, .{ .bold = true }));
        } else {
            putClipped(win, row, 0, w, "—", self.s(self.palette.fg3, .{}));
        }
        row += 1;
    }

    if (row < h) row = drawScore(self, win, w, anime, row);

    if (row < h) {
        drawHairline(self, win, w, row);
        row += 1;
    }

    // Kanji chips (ROD-141): status chip then season/year chip. The history
    // row itself shows progress + list_status, so the airing-status kanji is
    // the complementary fact here (matches §5.4a preview mock).
    // Fallback: if no chip resolves (status null/unknown), show list_status in
    // text.muted as a last resort so the pane is never entirely silent.
    if (row < h) {
        const chips_row = row;
        row = drawChips(self, win, h, anime, row);
        if (row == chips_row) {
            // No chip was emitted (status absent/unknown) — fall back to the
            // watchlist status label so the preview isn't silent about state.
            putClipped(win, chips_row, 0, w, rec.list_status.str(), self.s(self.palette.fg2, .{}));
            row = chips_row + 1;
        }
    }

    _ = drawSynopsis(self, win, w, h, anime, row);
}

fn drawEpisodeGrid(self: *App, win: vaxis.Window, w: u16, h: u16) void {
    if (self.episodes.loading) {
        if (h > 0) centerText(win, 0, w, "⠋ loading episodes…", self.s(self.palette.focus, .{}));
        return;
    }
    const eps = self.episodes.results orelse {
        // No fetch fired yet (detail pane opened but no item selected).
        return;
    };
    if (eps.len == 0) {
        // §4.6 absent state: a show the source returned with genuinely zero
        // episodes. Centered + text.dim italic to match the cover/feed/history
        // empties ("no art yet", "no feed yet", "nothing here yet") so it reads
        // as a deliberate "nothing here", not a pane that left-aligned a row.
        if (h > 1) centerText(win, h / 2, w, "no episodes", self.s(self.palette.fg3, .{ .italic = true }));
        return;
    }

    // Each cell is 5 chars wide: "[NN] " or "[NNN]" — allocate 5 per cell.
    const cell_w: u16 = 5;
    const cols: u16 = @max(1, w / cell_w);

    // Scroll so that the episode cursor is in view.
    const cursor_row: usize = self.episodes.cursor / cols;
    const viewport_rows: usize = h;
    const view_top: usize = if (cursor_row >= viewport_rows)
        cursor_row + 1 - viewport_rows
    else
        0;

    // §4.6 launching cell: the episode currently resolving/playing renders a
    // spinner in its grid slot. It tracks the SESSION, not the episode cursor —
    // the grid stays navigable during play (you can browse while mpv loads), so
    // the spinner stays pinned to the played episode, and only on the show
    // actually on screen (same_show, mirroring finishPlayback's guard).
    const launching_idx: usize = blk: {
        const here = self.playing and self.session.episode_index > 0 and
            self.episodes.for_id != null and self.session.anime_id.len > 0 and
            std.mem.eql(u8, self.session.anime_id, self.episodes.for_id.?);
        // sentinel: no real episode index can reach maxInt(usize), so no cell matches.
        break :blk if (here) self.session.episode_index - 1 else std.math.maxInt(usize);
    };

    var grid_row: u16 = 0;
    var ep_idx: usize = view_top * cols;
    while (grid_row < h and ep_idx < eps.len) : (grid_row += 1) {
        var col_off: u16 = 0;
        var c: u16 = 0;
        while (c < cols and ep_idx < eps.len) : (c += 1) {
            const ep = eps[ep_idx];
            const focused = ep_idx == self.episodes.cursor and self.active_pane == .detail;
            const launching = ep_idx == launching_idx;
            // §5.3 (ROD-192): the resume cell — where the user continues from —
            // carries a `▸` glyph. It is the only cell that earns a glyph: the
            // arrow is the heaviest mark in the grid because resume is the most
            // actionable cell (§5.x: "always the most visually prominent cell").
            // Watched cells deliberately stay glyph-free and recede via color —
            // a filled glyph there would weigh *more* than the action arrow,
            // inverting the hierarchy. A launching cell owns the slot outright.
            const is_resume = !launching and
                (if (self.episodes.resume_idx) |ri| ep_idx == ri else false);
            // ROD-192 review (Mira NIT-2): the `▸` needs a free column inside the
            // 5-wide `[..]` shell, which only exists for ≤2-char labels. For a
            // 3-digit or non-numeric resume label (`123`, `SP1`) the glyph would
            // clip to a bracket-less `[▸12`, which reads as broken. Drop the glyph
            // there and lean on the state.now color alone to mark resume.
            const resume_glyph = is_resume and ep.raw.len < 3;

            // Use ep_scratch to avoid dangling stack buffers. Index relative
            // to the viewport start so we never alias two live cells.
            const slot = (ep_idx - view_top * cols) % 512;
            const cell_buf = &self.ep_scratch[slot];
            // §4.6: a launching cell shows the current spinner frame in place of
            // its number, in the same `[ ]` shell so it reads as that cell working.
            const cell_text = if (launching)
                std.fmt.bufPrint(cell_buf, "[{s}]", .{self.spinnerChar()}) catch "[?]"
            else if (resume_glyph)
                std.fmt.bufPrint(cell_buf, "[▸{s}]", .{ep.raw}) catch "[?]"
            else
                std.fmt.bufPrint(cell_buf, "[{s}]", .{ep.raw}) catch "[?]";

            // §4.6/§5.3: watched cells (index below the high-water mark) recede to
            // text.dim; the resume cell lights state.now (magenta) + bold — the
            // loudest token in the grid, per §5.x ("most visually prominent cell");
            // unwatched stay text.muted; the cursor always wins (ROD-131). text.dim
            // is `fg3` alone — matching the completed/dropped convention in
            // history.zig; the `.dim` SGR attr is reserved for the paused semantic
            // (§2.4), so it is deliberately not used here. A launching cell escalates
            // focus→hot past isSlowPath (§4.8), same as every other slow-path
            // spinner; it outranks focus/resume/watched. Resume reads apart from the
            // focus cursor by HUE — resume is state.now (magenta), the cursor is
            // state.focus (cyan) + the bg.surface band that is the cursor's alone
            // (§5.x lists bg.surface on resume too, but sharing it would blur the
            // cursor, so the band stays cursor-only — color carries resume).
            const watched = ep_idx < @as(usize, self.episodes.progress);
            const cell_style = if (launching)
                self.s(if (self.isSlowPath()) self.palette.hot else self.palette.focus, .{ .bg = self.palette.bg_surface, .bold = true })
            else if (focused)
                self.s(self.palette.focus, .{ .bg = self.palette.bg_surface, .bold = true })
            else if (is_resume)
                self.s(self.palette.hot, .{ .bold = true })
            else if (watched)
                self.s(self.palette.fg3, .{})
            else
                self.s(self.palette.fg2, .{});

            if (focused or launching) {
                const cell_win = win.child(.{
                    .x_off = @intCast(col_off),
                    .y_off = @intCast(grid_row),
                    .width = cell_w,
                    .height = 1,
                });
                cell_win.fill(.{ .style = .{ .bg = self.palette.bg_surface } });
                _ = cell_win.printSegment(.{ .text = cell_text, .style = cell_style }, .{});
            } else {
                putClipped(win, grid_row, col_off, cell_w, cell_text, cell_style);
            }

            col_off += cell_w;
            ep_idx += 1;
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "statusChipFor: AniList vocab" {
    const t = std.testing;

    // Airing → 放映中, state.now
    const airing = statusChipFor("RELEASING").?;
    try t.expectEqualStrings("放映中", airing.kanji);
    try t.expectEqual(.hot, airing.color_field);

    // Completed → 完結, text.muted
    const done = statusChipFor("FINISHED").?;
    try t.expectEqualStrings("完結", done.kanji);
    try t.expectEqual(.fg2, done.color_field);

    // Not yet aired → 放映前, state.focus
    const soon = statusChipFor("NOT_YET_RELEASED").?;
    try t.expectEqualStrings("放映前", soon.kanji);
    try t.expectEqual(.focus, soon.color_field);

    // Cancelled → 中止, text.dim
    const cancelled = statusChipFor("CANCELLED").?;
    try t.expectEqualStrings("中止", cancelled.kanji);
    try t.expectEqual(.fg3, cancelled.color_field);
}

test "statusChipFor: AllAnime vocab" {
    const t = std.testing;

    // AllAnime sends "RELEASING" (same) and "ongoing" (lowercase alias).
    const rel = statusChipFor("RELEASING").?;
    try t.expectEqualStrings("放映中", rel.kanji);

    const ongoing = statusChipFor("ongoing").?;
    try t.expectEqualStrings("放映中", ongoing.kanji);
}

test "statusChipFor: case-insensitivity" {
    const t = std.testing;

    try t.expect(statusChipFor("releasing") != null);
    try t.expect(statusChipFor("Finished") != null);
    try t.expect(statusChipFor("not_yet_released") != null);
    try t.expect(statusChipFor("ONGOING") != null);
}

test "statusChipFor: null on unknown/empty" {
    const t = std.testing;

    try t.expect(statusChipFor("") == null);
    try t.expect(statusChipFor("unknown") == null);
    try t.expect(statusChipFor("AIRING") == null); // not a valid vocab word
}

test "coverWidthFor: tiers off the pane width, capped at 20 (ROD-170 §3.3)" {
    const t = std.testing;

    // >= 40 cols → 20-col cover (the hard cap).
    try t.expectEqual(@as(u16, 20), coverWidthFor(40));
    try t.expectEqual(@as(u16, 20), coverWidthFor(70));
    try t.expectEqual(@as(u16, 20), coverWidthFor(200)); // never grows past 20

    // 25..39 → 14-col cover (narrow two-pane detail / preview band).
    try t.expectEqual(@as(u16, 14), coverWidthFor(25));
    try t.expectEqual(@as(u16, 14), coverWidthFor(39));

    // < 25 → no cover (no room for a poster).
    try t.expectEqual(@as(u16, 0), coverWidthFor(24));
    try t.expectEqual(@as(u16, 0), coverWidthFor(0));
}

test "synopsisCap: reserves spacer + min grid rows" {
    const t = std.testing;

    // When remaining_h is exactly the reservation, cap floors to 1.
    try t.expectEqual(@as(u16, 1), synopsisCap(3)); // 3 == 1 spacer + 2 grid rows

    // Normal case: cap = remaining - reservation.
    try t.expectEqual(@as(u16, 5), synopsisCap(8));  // 8 - 3 = 5
    try t.expectEqual(@as(u16, 12), synopsisCap(15)); // 15 - 3 = 12

    // Edge: remaining less than reservation → floor to 1.
    try t.expectEqual(@as(u16, 1), synopsisCap(0));
    try t.expectEqual(@as(u16, 1), synopsisCap(1));
    try t.expectEqual(@as(u16, 1), synopsisCap(2));
}
