//! Detail view render: poster cover (Kitty / half-block / fallback), metadata
//! header, and episode grid (ROD-144). Cover *state* lives in app.zig; this is
//! the pure render of it.

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const workers = @import("../workers.zig");
const render = @import("../render.zig");
const cover_render = @import("../cover_render.zig");
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

/// Pane width at which History detail splits two-column (ROD-113). Measured
/// against the detail *pane*, not the terminal (ROD-258). At the threshold:
/// ~38-col left (cover+header), ~60-col right (synopsis+grid).
pub const detail_two_col_min: u16 = 100;

/// Two-column gate on pane width, not terminal (ROD-258). Exposed for tests.
pub fn isTwoColumn(pane_w: u16) bool {
    return pane_w >= detail_two_col_min;
}

/// §3.3 cover-width tier off effective pane width (ROD-170). Cap 20; 0 below 25.
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

/// Non-Kitty fallback (§7.5, ROD-110): half-block when pixels exist, else flat
/// dominant colour (decode failed or kitty upload faulted).
fn drawFallbackCover(self: *const App, cover_win: vaxis.Window) void {
    if (self.cover.pixels != null) {
        drawHalfBlockCover(self, cover_win);
    } else {
        cover_win.fill(.{ .style = .{ .bg = self.cover.fallback_color } });
    }
}

/// Half-block mosaic via shared `cover_render` sampler (ROD-243). `bg_base` is
/// the letterbox matte so fit-fill matches the pane (ROD-164 §8).
fn drawHalfBlockCover(self: *const App, cover_win: vaxis.Window) void {
    const px = self.cover.pixels orelse return;
    cover_render.drawHalfBlock(cover_win, .{ .rgba = px.rgba, .w = px.w, .h = px.h }, self.palette.bg_base);
}

fn drawKittyCover(self: *const App, img: vaxis.Image, cover_win: vaxis.Window) void {
    if (!cover_render.drawKittyFit(img, cover_win)) drawFallbackCover(self, cover_win);
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

/// Cover-art block (§3.3 + §7.3/§7.5) at the top of `win`. Returns rows
/// consumed (height + 1 spacer), or 0 when the width tier has no slot. Shared by
/// single-/two-column detail and History preview (ROD-113). Width is tier-fixed;
/// height comes from terminal pixel geometry so the panel stays poster-shaped.
fn drawCover(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer, win: vaxis.Window, anime: ?Anime, pane_w: u16, max_h_override: ?u16) u16 {
    // ROD-170 §3.3: scale to pane/column width, not the terminal.
    const cover_w: u16 = coverWidthFor(pane_w);
    if (cover_w == 0) return 0;
    const base_max_h: u16 = if (pane_w >= 40) 28 else 20;
    // ROD-137: single-column passes a grid-protecting cap; two-col left / History
    // preview pass null (no grid competes for height).
    const max_h: u16 = if (max_h_override) |cap| @min(base_max_h, cap) else base_max_h;
    if (max_h == 0) return 0;
    const cover_h: u16 = coverSlotHeight(win, cover_w, max_h);
    if (cover_h == 0) return 0;
    // ROD-137: below min_cover_rows the poster reads as a glitch; drop it so the
    // header anchors identity. Only on the capped (single-column) path.
    // Intentional cliff: no-geometry terminal first shows cover past h≈19
    // (coverHeightCap(19)=6); a sub-6-row sliver looks broken, so jump discrete.
    if (max_h_override != null and cover_h < min_cover_rows) return 0;

    const cover_win = win.child(.{ .x_off = 0, .y_off = 0, .width = cover_w, .height = cover_h });
    if (anime) |a| {
        const same_id = self.cover.for_id != null and std.mem.eql(u8, self.cover.for_id.?, a.id);
        const has_pixels = self.cover.pixels != null and same_id;
        const showing_spinner = self.cover.loading and same_id;
        // §8 footprint (ROD-164): poster slot is bg_base (fit-matte matches pane);
        // placeholders keep bg_surface. `drawing_poster` mirrors the has_pixels
        // branch below so fill and draw take the same path.
        const drawing_poster = a.thumb != null and !showing_spinner and has_pixels;
        cover_win.fill(.{ .style = .{ .bg = if (drawing_poster) self.palette.bg_base else self.palette.bg_surface } });
        if (a.thumb == null) {
            if (cover_h > 1) centerText(cover_win, cover_h / 2, cover_w, "no art yet", self.s(self.palette.fg3, .{ .italic = true }));
        } else if (showing_spinner) {
            const spin = std.fmt.bufPrint(&self.scratch.detail_msg, "{s}", .{self.spinnerChar()}) catch "⠋";
            // §3.6 slow-path: cyan → hot past long-wait, same as bottom-bar spinner.
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

/// status→chip: kanji + palette field. Field accessor avoids capturing a Palette
/// pointer in a comptime value; caller resolves color at render.
const StatusChip = struct {
    kanji: []const u8,
    /// .hot / .fg2 / .focus / .fg3 / .warn (state.now, text.muted, …).
    color_field: enum { hot, fg2, focus, fg3, warn },
};

/// DESIGN.md §2.3: AniList or AllAnime status → chip. Case-insensitive; null for
/// unknown/empty (omit the chip, never render empty).
/// AniList: FINISHED / RELEASING / NOT_YET_RELEASED / CANCELLED
/// AllAnime: RELEASING / ongoing
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

    // §2.3 lists Hiatus even though AniList/AllAnime never send it; mapped in case a future source does.
    if (std.ascii.eqlIgnoreCase(status, "HIATUS"))
        return .{ .kanji = "休止中", .color_field = .warn };

    return null;
}

fn chipColor(self: *const App, chip: StatusChip) vaxis.Color {
    return switch (chip.color_field) {
        .hot => self.palette.hot,
        .fg2 => self.palette.fg2,
        .focus => self.palette.focus,
        .fg3 => self.palette.fg3,
        .warn => self.palette.warn,
    };
}

// ── ROD-141 / ROD-137 single-column row budget ───────────────────────────────

/// Min grid rows at worst supported geometry (35-row terminal).
const min_grid_rows: u16 = 2;

/// Worst-case rows `drawHeader` can advance: title + 2 alts + chips + score +
/// hairline + meta = 7. Cover is drawn first, so its cap assumes this max.
/// KEEP IN SYNC with `drawHeader`. (`drawScore` advances unconditionally; vaxis
/// clips past-window prints so the frame stays intact.)
const max_header_rows: u16 = 7;

/// Min synopsis rows so a shrunk-cover pane still reads as detail (ROD-137).
const min_synopsis_rows: u16 = 2;

/// Below this, 20-col poster is a smear; capped single-column path drops it (ROD-137).
const min_cover_rows: u16 = 6;

/// Blank row `drawCover` folds into its return after the poster.
const cover_spacer_rows: u16 = 1;
/// Caption row above the episode grid (provider surface, ROD-397). Always reserved.
const grid_caption_rows: u16 = 1;

/// Single-column reservation below the cover (ROD-137): trailing cover spacer +
/// max header + min synopsis + grid spacer + min grid. Single source for
/// synopsisCap and the invariant test.
const cover_reserve: u16 = cover_spacer_rows + max_header_rows + min_synopsis_rows + grid_caption_rows + min_grid_rows;

/// Synopsis rows in single-column: max(1, remaining_h - (grid_spacer + min_grid)).
/// ROD-137/ROD-141: at 35-row terminal the grid must keep ≥2 visible rows.
fn synopsisCap(remaining_h: u16) u16 {
    const reserved: u16 = grid_caption_rows + min_grid_rows;
    if (remaining_h <= reserved) return 1;
    return remaining_h - reserved;
}

/// Cap single-column cover height (ROD-137) so cover + worst-case header + min
/// synopsis + min grid always fit. Needed when no pixel geometry makes
/// coverSlotHeight return the full 28-row aesthetic cap (synopsisCap only clamps
/// synopsis, never the cover). 0 when the pane is too short. Exposed for tests.
fn coverHeightCap(h: u16) u16 {
    return if (h > cover_reserve) h - cover_reserve else 0;
}

// ── draw helpers ─────────────────────────────────────────────────────────────

/// Title (bold name or empty placeholder). Returns next free row.
fn drawTitle(self: *App, win: vaxis.Window, w: u16, info: DetailRenderInfo, start_row: u16) u16 {
    if (info.anime != null and !std.mem.eql(u8, info.title, "—")) {
        putClipped(win, start_row, 0, w, info.title, self.s(self.palette.fg, .{ .bold = true }));
    } else {
        putClipped(win, start_row, 0, w, info.title, self.s(self.palette.fg3, .{}));
    }
    return start_row + 1;
}

/// Non-primary title forms in romaji→english→native order (ROD-141 / ROD-205
/// §9.1a). Skip empty or byte-equal to primary. Native italic (§1.3); others plain fg2.
fn drawAltTitles(self: *App, win: vaxis.Window, w: u16, h: u16, anime: Anime, primary: []const u8, start_row: u16) u16 {
    var row = start_row;

    // `primary` is the exact title-line string, not re-resolved (no drift). Equality
    // against the *resolved* primary de-dupes fallbacks (e.g. english null → romaji
    // as primary must not reappear as an alt).
    var buf: [2]domain.TitleRow = undefined;
    for (domain.altTitles(anime.name, anime.english_name, anime.native_name, primary, &buf)) |alt| {
        if (row >= h) break;
        putClipped(win, row, 0, w, alt.text, self.s(self.palette.fg2, .{ .italic = alt.native }));
        row += 1;
    }

    return row;
}

/// Kanji chips row (ROD-141, §2.3 / §4.4): status, season+year, airing countdown,
/// origin; plain spans flush at col 0; two spaces between chips. Empty when all absent.
fn drawChips(self: *App, win: vaxis.Window, h: u16, anime: Anime, start_row: u16) u16 {
    if (start_row >= h) return start_row;

    const status_chip: ?StatusChip = if (anime.status) |st|
        (if (st.len > 0) statusChipFor(st) else null)
    else
        null;

    const has_season = anime.season != null and anime.year != null;

    // CRITICAL: chip text must live in App-owned storage, not a stack local.
    // vaxis cells hold a *slice* into segment text; the frame emits only at
    // `render()`, after this returns. A stack buffer dangles (ROD-141).
    const fg3 = self.s(self.palette.fg3, .{});
    const season_text: []const u8 = if (has_season)
        std.fmt.bufPrint(&self.detail_season_buf, "{s} {d}", .{ anime.season.?.kanji(), anime.year.? }) catch ""
    else
        "";

    // Airing countdown (ROD-261, §4.4): live from wall clock (`now_ms` is Clock.real).
    const now_secs = @divFloor(self.now_ms, 1000);
    const airing_text: []const u8 = airingChipText(&self.detail_airing_buf, anime, now_secs) orelse "";

    // Non-JP origin (ROD-261, §4.4): bare country code, dimmest, last. JP is default
    // (show nothing). Borrows gpa-owned `anime.country` (frame-lived).
    const origin_text: []const u8 = if (anime.country) |cc|
        (if (cc.len > 0 and !std.mem.eql(u8, cc, "JP")) cc else "")
    else
        "";

    if (status_chip == null and !has_season and airing_text.len == 0 and origin_text.len == 0)
        return start_row;

    // One `win.print` of styled segments so wide-glyph widths stay consistent
    // while each span keeps its color (§2.3). Up to 4 chips → 7 slots with gaps.
    var segs: [7]vaxis.Segment = undefined;
    var n: usize = 0;
    if (status_chip) |chip| {
        segs[n] = .{ .text = chip.kanji, .style = self.s(chipColor(self, chip), .{}) };
        n += 1;
    }
    if (season_text.len > 0) {
        if (n > 0) {
            segs[n] = .{ .text = "  ", .style = fg3 };
            n += 1;
        }
        segs[n] = .{ .text = season_text, .style = self.s(self.palette.focus, .{}) };
        n += 1;
    }
    if (airing_text.len > 0) {
        if (n > 0) {
            segs[n] = .{ .text = "  ", .style = fg3 };
            n += 1;
        }
        // Same `state.now` register as the RELEASING status chip.
        segs[n] = .{ .text = airing_text, .style = self.s(self.palette.hot, .{}) };
        n += 1;
    }
    if (origin_text.len > 0) {
        if (n > 0) {
            segs[n] = .{ .text = "  ", .style = fg3 };
            n += 1;
        }
        segs[n] = .{ .text = origin_text, .style = fg3 };
        n += 1;
    }
    // wrap: .none: multi-row pane; without it a chip at the edge folds onto the hairline.
    _ = win.print(segs[0..n], .{ .row_offset = start_row, .col_offset = 0, .wrap = .none });

    return start_row + 1;
}

/// Airing chip "Ep{n} · {countdown}" (ROD-261, §4.4), or null when not airing,
/// episode missing, or countdown lapsed (`airingAt ≤ now`: stale enrich is worse
/// than none). Single coarsest unit (Nd / Nh / Nm) from live `now_secs`.
fn airingChipText(buf: []u8, anime: Anime, now_secs: i64) ?[]const u8 {
    const at = anime.next_airing_at orelse return null;
    const ep = anime.next_airing_episode orelse return null;
    const remaining = at - now_secs;
    if (remaining <= 0) return null;
    const day = 24 * 60 * 60;
    const hour = 60 * 60;
    if (remaining >= day)
        return std.fmt.bufPrint(buf, "Ep{d} · {d}d", .{ ep, @divFloor(remaining, day) }) catch null;
    if (remaining >= hour)
        return std.fmt.bufPrint(buf, "Ep{d} · {d}h", .{ ep, @divFloor(remaining, hour) }) catch null;
    return std.fmt.bufPrint(buf, "Ep{d} · {d}m", .{ ep, @divFloor(remaining, 60) }) catch null;
}

/// Score line: "[--/100]" until enrich fills `a.score`, then tiered §2.2.
/// Genres follow on the same line with ` · ` (§4.3). Returns next free row.
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
    // §2.2 via shared App.scoreStyle (ROD-226); Browse list uses the same map.
    // Detail uses palette default bg (null).
    const score_style = self.scoreStyle(if (anime) |a| a.score else null, null);

    // Advance by print's *returned* column, not slice length: "✦" and "·" are
    // multi-byte / 1-col and would open phantom gaps (ROD-141). wrap: .none so a
    // segment at the pane edge stops instead of folding onto the hairline.
    var col = win.print(
        &.{.{ .text = score_text, .style = score_style }},
        .{ .row_offset = start_row, .col_offset = 0, .wrap = .none },
    ).col;

    // ROD-141: " · Genre…" on the score line; omit when empty (§9.1).
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

/// Hairline clipped to width. "─" is 3 UTF-8 bytes; `cols` glyphs = `cols * 3` bytes.
fn drawHairline(self: *App, win: vaxis.Window, w: u16, row: u16) void {
    const cols: u16 = @min(w, 160);
    put(win, row, 0, ("─" ** 160)[0 .. @as(usize, cols) * 3], self.s(self.palette.chrome, .{}));
}

/// Title + chips + score/genres + hairline + meta (ROD-141). `h` bounds each step.
fn drawHeader(self: *App, win: vaxis.Window, w: u16, h: u16, info: DetailRenderInfo, start_row: u16, bloom: bool) u16 {
    var row = drawTitle(self, win, w, info, start_row);

    if (info.anime) |a| {
        if (row < h) row = drawAltTitles(self, win, w, h, a, info.title, row);
    }

    if (info.anime) |a| {
        if (row < h) row = drawChips(self, win, h, a, row);
    }

    row = drawScore(self, win, w, info.anime, row);

    // Hairline advance is height-guarded (ROD-113 N2). layout() already rejects h<4.
    if (row < h) {
        drawHairline(self, win, w, row);
        row += 1;
    }

    // Metadata (ROD-260): same fields as compact `·` line or bloomed rail (`bloom`).
    const fields = self.detailMetaFields();
    if (bloom) {
        row = drawMetaRail(self, win, w, h, fields, row);
    } else if (row < h) {
        row = drawMetaLine(self, win, w, fields, row);
    }
    return row;
}

/// Provider caption (ROD-397): registry names with the serving ▸ marker · pin ·
/// dim [v]. wrap=.none clips the tail, so print order is priority order: [v] sheds
/// first (it is in the help bar too), then pin, then the names.
fn drawProviderCaption(self: *App, win: vaxis.Window, fields: []const App.MetaField, row: u16) void {
    var provider: ?App.MetaField = null;
    var pinned: ?App.MetaField = null;
    for (fields) |f| {
        if (!f.caption) continue;
        if (std.mem.eql(u8, f.label, "Provider")) provider = f;
        if (std.mem.eql(u8, f.label, "Pinned")) pinned = f;
    }
    const p = provider orelse return;
    var col = win.print(
        &.{.{ .text = p.value, .style = self.s(if (p.dim) self.palette.fg3 else self.palette.fg2, .{}) }},
        .{ .row_offset = row, .col_offset = 0, .wrap = .none },
    ).col;
    if (pinned) |pf| {
        col = win.print(&.{
            .{ .text = " · ", .style = self.s(self.palette.fg3, .{}) },
            .{ .text = "pin ", .style = self.s(self.palette.fg2, .{}) },
            .{ .text = pf.value, .style = self.s(self.palette.fg2, .{}) },
        }, .{ .row_offset = row, .col_offset = col, .wrap = .none }).col;
    }
    _ = win.print(
        &.{.{ .text = " · [v]", .style = self.s(self.palette.fg3, .{}) }},
        .{ .row_offset = row, .col_offset = col, .wrap = .none },
    );
}

/// Compact meta line (ROD-260): values joined by ` · `, one row. Cursor by print
/// return so long values clip at the edge; separator only *between* fields (§9.1).
fn drawMetaLine(self: *App, win: vaxis.Window, w: u16, fields: []const App.MetaField, start_row: u16) u16 {
    var col: u16 = 0;
    // `printed` drives the separator so rail_only (Rank, ROD-261) leaves no orphan ` · `.
    var printed: usize = 0;
    for (fields) |f| {
        if (f.rail_only or f.caption) continue;
        if (col >= w) break;
        if (printed > 0) {
            col = win.print(
                &.{.{ .text = " · ", .style = self.s(self.palette.fg3, .{}) }},
                .{ .row_offset = start_row, .col_offset = col, .wrap = .none },
            ).col;
            if (col >= w) break;
        }
        const val_style = self.s(if (f.dim) self.palette.fg3 else self.palette.fg2, .{});
        col = win.print(&.{
            .{ .text = f.value, .style = val_style },
            .{ .text = f.unit, .style = val_style },
        }, .{ .row_offset = start_row, .col_offset = col, .wrap = .none }).col;
        printed += 1;
    }
    return start_row + 1;
}

/// Meta rail (ROD-260): `Label  Value` top-down by priority; short panes drop
/// lowest fields first. Fixed 8-col label gutter; values align at col 10. Rail
/// label is the unit (no compact ` eps` suffix).
fn drawMetaRail(self: *App, win: vaxis.Window, w: u16, h: u16, fields: []const App.MetaField, start_row: u16) u16 {
    const label_w: u16 = 8; // longest label ("Episodes"); values past 2-space gap
    const value_x: u16 = label_w + 2;
    var row = start_row;
    for (fields) |f| {
        if (f.caption) continue;
        if (row >= h) break;
        // Clip label to gutter so over-length labels never bleed into values (ROD-260).
        putClipped(win, row, 0, @min(w, label_w), f.label, self.s(self.palette.fg3, .{}));
        if (value_x < w) {
            const val_style = self.s(if (f.dim) self.palette.fg3 else self.palette.fg2, .{});
            putClipped(win, row, value_x, w - value_x, f.value, val_style);
        }
        row += 1;
    }
    return row;
}

/// Synopsis: description or null-degrade stub; wrap within `w`, cap at `max_lines`.
fn drawSynopsisLimited(self: *App, win: vaxis.Window, w: u16, h: u16, anime: ?Anime, start_row: u16, max_lines: u16) u16 {
    var row = start_row;
    if (row >= h) return row;
    const cap = @min(max_lines, h - row);
    if (anime) |a| {
        if (a.description) |desc| {
            const lines_written = drawWrappedText(win, row, 0, w, cap, desc, self.s(self.palette.fg2, .{}));
            // Cap hit → "…" at last col (§1.3). lines_written >= cap can false-positive
            // an exact fit; dim trailing "…" is acceptable.
            if (lines_written >= cap and cap > 0 and w > 0) {
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

/// Uncapped synopsis for two-column right column (no header competing for height).
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

/// First grid-body row below the caption (ROD-397): reserves exactly
/// grid_caption_rows when it fits, so grid height never depends on whether the
/// caption painted a provider. Keeps the ROD-137 floor across the relocation.
fn gridBodyRow(start_row: u16, h: u16) u16 {
    return if (start_row < h) start_row + grid_caption_rows else start_row;
}

/// Provider caption, then the episode grid fills the rest below it (ROD-397).
fn drawGrid(self: *App, win: vaxis.Window, w: u16, h: u16, start_row: u16, fields: []const App.MetaField) void {
    if (start_row < h) drawProviderCaption(self, win, fields, start_row);
    const row = gridBodyRow(start_row, h);
    if (row >= h) return;
    const grid_h: u16 = h - row;
    const grid_win = win.child(.{ .x_off = 0, .y_off = row, .width = w, .height = grid_h });
    drawEpisodeGrid(self, grid_win, w, grid_h);
}

pub fn drawDetailPane(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer, win: vaxis.Window, w: u16, h: u16, two_col: bool) void {
    if (w < 10) return;

    const info = self.detailRenderInfo();

    // ROD-222: grid is focused-detail only. Browse two-pane draws this every frame
    // (list focus included); without the gate a stale grid bleeds into preview.
    // episodeGridVisible is false when no detail show is focused; synopsis reclaims rows.
    const show_grid = self.episodeGridVisible();

    // Two-column (ROD-113): cover+header left (~38%), synopsis+grid right.
    // Gate on pane width `w`, not terminal (ROD-258): History co-visible detail is
    // `term - list`, and a term-width gate force-split ~58-col panes into a ~22-col
    // cover that clipped meta. Below detail_two_col_min, single-column stack.
    if (two_col and isTwoColumn(w)) {
        // Floor 20 keeps the 20-col cover fitting if the gate ever lowers (ROD-170).
        // Dead at current ≥100 (38-col min left) but required once the gate drops.
        const left_w: u16 = @max(20, (w * 38) / 100);
        const right_x: u16 = left_w + 2; // 2-cell gap, no border (§3.1)
        const right_w: u16 = if (w > right_x) w - right_x else 0;
        const left_win = win.child(.{ .x_off = 0, .y_off = 0, .width = left_w, .height = h });
        const right_win = win.child(.{ .x_off = @intCast(right_x), .y_off = 0, .width = right_w, .height = h });

        const lrow = drawCover(self, vx, writer, left_win, info.anime, w, null);
        // Left ends at header; synopsis/grid are right. Metadata blooms to rail (ROD-260).
        _ = drawHeader(self, left_win, left_w, h, info, lrow, true);

        // Right column is dedicated: no synopsis cap. Dropping the grid leaves empty
        // bottom rows; no relayout (unlike single-column reclaim).
        const rrow = drawSynopsis(self, right_win, right_w, h, info.anime, 0);
        if (show_grid) drawGrid(self, right_win, right_w, h, rrow, self.detailMetaFields());
        return;
    }

    // Single-column (ROD-137): coverHeightCap so cover can't starve the grid when
    // no pixel geometry returns the full 28-row aesthetic; synopsisCap leaves ≥2
    // grid rows. Worst case 35-row terminal: cover=19, synopsis=2, grid=2 (invariant test).
    var row: u16 = drawCover(self, vx, writer, win, info.anime, w, coverHeightCap(h));
    // Compact meta (no room to bloom) (ROD-260).
    row = drawHeader(self, win, w, h, info, row, false);
    if (show_grid) {
        const cap = synopsisCap(if (h > row) h - row else 0);
        row = drawSynopsisLimited(self, win, w, h, info.anime, row, cap);
        drawGrid(self, win, w, h, row, self.detailMetaFields());
    } else {
        // Preview: no grid reservation; synopsis takes remaining height (ROD-222).
        _ = drawSynopsis(self, win, w, h, info.anime, row);
    }
}

/// History preview (ROD-113): cover + header stack + synopsis, no episode grid.
/// Explicit `rec` because detailRenderInfo is null when active_view == .history.
pub fn drawHistoryPreview(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer, win: vaxis.Window, w: u16, h: u16, rec: AnimeRecord) void {
    if (w < 10) return;
    const anime = App.animeFromHistoryRecord(rec);

    var row: u16 = drawCover(self, vx, writer, win, anime, w, null);

    // Primary under title-language pref (ROD-205); empty-backstop. Same string
    // the alt stack de-dupes against.
    const primary = anime.displayTitle(self.config.titleLanguageEnum());
    if (row < h) {
        if (primary.len > 0) {
            putClipped(win, row, 0, w, primary, self.s(self.palette.fg, .{ .bold = true }));
        } else {
            putClipped(win, row, 0, w, "—", self.s(self.palette.fg3, .{}));
        }
        row += 1;
    }

    if (row < h) row = drawAltTitles(self, win, w, h, anime, primary, row);

    // Chips ABOVE score/hairline to match drawHeader §4.4 order so the row does
    // not jump when preview focuses into full detail (ROD-261). Fallback list_status
    // when no chip resolves.
    if (row < h) {
        const chips_row = row;
        row = drawChips(self, win, h, anime, row);
        if (row == chips_row) {
            putClipped(win, chips_row, 0, w, rec.list_status.str(), self.s(self.palette.fg2, .{}));
            row = chips_row + 1;
        }
    }

    if (row < h) row = drawScore(self, win, w, anime, row);

    if (row < h) {
        drawHairline(self, win, w, row);
        row += 1;
    }

    // Compact meta from preview anime; detailMetaFields can't read nav here.
    if (row < h) row = drawMetaLine(self, win, w, self.detailMetaFieldsFor(anime), row);

    _ = drawSynopsis(self, win, w, h, anime, row);
}

/// Scratch slot for grid cell at `ep_idx`, or null past `cap` (ROD-396 F1).
/// Consecutive cells claim consecutive slots; null → borrow owned label (no wrap
/// into an occupied slot). Precondition: `ep_idx >= view_top*cols`.
fn scratchSlotFor(ep_idx: usize, view_top: usize, cols: u16, cap: usize) ?usize {
    const slot = ep_idx - view_top * cols;
    return if (slot < cap) slot else null;
}

fn drawEpisodeGrid(self: *App, win: vaxis.Window, w: u16, h: u16) void {
    if (self.episodes.unbound) {
        // ROD-329: Play inert; distinct from zero-episode empty (§4.6).
        if (h > 1) centerText(win, h / 2, w, "no source available", self.s(self.palette.fg3, .{ .italic = true }));
        return;
    }
    if (self.episodes.loading) {
        if (h > 0) centerText(win, 0, w, "⠋ loading episodes…", self.s(self.palette.focus, .{}));
        return;
    }
    const eps = self.episodes.results orelse {
        return;
    };
    if (eps.len == 0) {
        // §4.6: genuine zero episodes; centered dim italic like other empties.
        if (h > 1) centerText(win, h / 2, w, "no episodes", self.s(self.palette.fg3, .{ .italic = true }));
        return;
    }

    // Cell width 5: "[NN] " / "[NNN]".
    const cell_w: u16 = 5;
    const cols: u16 = @max(1, w / cell_w);

    const cursor_row: usize = self.episodes.cursor / cols;
    const viewport_rows: usize = h;
    const view_top: usize = if (cursor_row >= viewport_rows)
        cursor_row + 1 - viewport_rows
    else
        0;

    // §4.6 launching cell tracks the SESSION, not the cursor: grid stays
    // navigable during play; spinner pins to the played ep on the on-screen show
    // (same_show, mirrors finishPlayback).
    const launching_idx: usize = blk: {
        const here = self.playing and self.session.episode_index > 0 and
            self.episodes.for_id != null and self.session.anime_id.len > 0 and
            std.mem.eql(u8, self.session.anime_id, self.episodes.for_id.?);
        // sentinel: no real index reaches maxInt(usize).
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
            // §5.3 (ROD-192): only resume earns a glyph (`▸`); watched stay glyph-free
            // and recede by color (a filled mark would invert hierarchy vs the arrow).
            // Launching owns the slot outright.
            const is_resume = !launching and
                (if (self.episodes.resume_idx) |ri| ep_idx == ri else false);
            // `▸` needs a free column inside the 5-wide shell: only ≤2-char labels.
            // 3-digit / non-numeric would clip to `[▸12`; drop glyph, keep hot color.
            const resume_glyph = is_resume and ep.raw.len < 3;

            // Unique scratch slot per cell; past cap borrow owned label (ROD-396 F1).
            const cell_text = blk: {
                const slot = scratchSlotFor(ep_idx, view_top, cols, self.ep_scratch.len) orelse
                    break :blk ep.raw;
                const cell_buf = &self.ep_scratch[slot];
                if (launching) break :blk std.fmt.bufPrint(cell_buf, "[{s}]", .{self.spinnerChar()}) catch "[?]";
                if (resume_glyph) break :blk std.fmt.bufPrint(cell_buf, "[▸{s}]", .{ep.raw}) catch "[?]";
                break :blk std.fmt.bufPrint(cell_buf, "[{s}]", .{ep.raw}) catch "[?]";
            };

            // §4.6/§5.3: watched → fg3; resume → hot+bold; unwatched → fg2; cursor
            // wins (ROD-131). text.dim is fg3 alone (history.zig); `.dim` SGR is
            // paused semantic (§2.4), unused here. Launching escalates focus→hot
            // past isSlowPath (§4.8). Resume vs cursor by HUE only: resume hot,
            // cursor focus + bg_surface (sharing bg would blur the cursor).
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

    const airing = statusChipFor("RELEASING").?;
    try t.expectEqualStrings("放映中", airing.kanji);
    try t.expectEqual(.hot, airing.color_field);

    const done = statusChipFor("FINISHED").?;
    try t.expectEqualStrings("完結", done.kanji);
    try t.expectEqual(.fg2, done.color_field);

    const soon = statusChipFor("NOT_YET_RELEASED").?;
    try t.expectEqualStrings("放映前", soon.kanji);
    try t.expectEqual(.focus, soon.color_field);

    const cancelled = statusChipFor("CANCELLED").?;
    try t.expectEqualStrings("中止", cancelled.kanji);
    try t.expectEqual(.fg3, cancelled.color_field);
}

test "statusChipFor: AllAnime vocab" {
    const t = std.testing;

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
    try t.expect(statusChipFor("AIRING") == null); // not AniList/AllAnime vocab
}

test "airingChipText: coarsest unit, lapse, and missing data (ROD-261)" {
    const t = std.testing;
    var buf: [24]u8 = undefined;
    const base: Anime = .{ .id = "x", .name = "X", .next_airing_episode = 14 };

    // Coarsest unit only: 3d 5h → "3d".
    var d = base;
    d.next_airing_at = 1000 + 3 * 24 * 60 * 60 + 5 * 60 * 60;
    try t.expectEqualStrings("Ep14 · 3d", airingChipText(&buf, d, 1000).?);

    var h = base;
    h.next_airing_at = 1000 + 5 * 60 * 60;
    try t.expectEqualStrings("Ep14 · 5h", airingChipText(&buf, h, 1000).?);

    var m = base;
    m.next_airing_at = 1000 + 20 * 60;
    try t.expectEqualStrings("Ep14 · 20m", airingChipText(&buf, m, 1000).?);

    // Lapsed → null (stale countdown worse than none).
    var lapsed = base;
    lapsed.next_airing_at = 900;
    try t.expect(airingChipText(&buf, lapsed, 1000) == null);

    try t.expect(airingChipText(&buf, base, 1000) == null);
    var no_ep: Anime = .{ .id = "x", .name = "X" };
    no_ep.next_airing_at = 1000 + 24 * 60 * 60;
    try t.expect(airingChipText(&buf, no_ep, 1000) == null);
}

test "coverWidthFor: tiers off the pane width, capped at 20 (ROD-170 §3.3)" {
    const t = std.testing;

    try t.expectEqual(@as(u16, 20), coverWidthFor(40));
    try t.expectEqual(@as(u16, 20), coverWidthFor(70));
    try t.expectEqual(@as(u16, 20), coverWidthFor(200));

    try t.expectEqual(@as(u16, 14), coverWidthFor(25));
    try t.expectEqual(@as(u16, 14), coverWidthFor(39));

    try t.expectEqual(@as(u16, 0), coverWidthFor(24));
    try t.expectEqual(@as(u16, 0), coverWidthFor(0));
}

test "synopsisCap: reserves spacer + min grid rows" {
    const t = std.testing;

    try t.expectEqual(@as(u16, 1), synopsisCap(3)); // exactly reservation → floor 1
    try t.expectEqual(@as(u16, 5), synopsisCap(8));
    try t.expectEqual(@as(u16, 12), synopsisCap(15));
    try t.expectEqual(@as(u16, 1), synopsisCap(0));
    try t.expectEqual(@as(u16, 1), synopsisCap(1));
    try t.expectEqual(@as(u16, 1), synopsisCap(2));
}

test "coverHeightCap: bounds the cover to protect the grid (ROD-137)" {
    const t = std.testing;

    // 35-row terminal → pane h=32: cover = h - cover_reserve(13) = 19.
    try t.expectEqual(@as(u16, 19), coverHeightCap(32));
    // Cap grows; drawCover @min with aesthetic 28/20 still wins at draw time.
    try t.expectEqual(@as(u16, 27), coverHeightCap(40));
    try t.expectEqual(@as(u16, 0), coverHeightCap(cover_reserve));
    try t.expectEqual(@as(u16, 0), coverHeightCap(10));
    try t.expectEqual(@as(u16, 0), coverHeightCap(0));
    try t.expectEqual(@as(u16, 1), coverHeightCap(cover_reserve + 1));
}

test "ROD-397: gridBodyRow reserves exactly the caption row, provider-independent" {
    const t = std.testing;
    // Exactly grid_caption_rows reserved when the row fits, 0 past the pane floor;
    // gridBodyRow takes no fields, so provider presence can't move the grid.
    try t.expectEqual(@as(u16, 1), grid_caption_rows);

    try t.expectEqual(@as(u16, 6), gridBodyRow(5, 32));
    try t.expectEqual(@as(u16, 1), gridBodyRow(0, 2));
    try t.expectEqual(@as(u16, 32), gridBodyRow(32, 32));
    try t.expectEqual(@as(u16, 33), gridBodyRow(33, 32));

    var start: u16 = 0;
    while (start < 40) : (start += 1) {
        const reserved = gridBodyRow(start, 32) - start;
        try t.expectEqual(@as(u16, if (start < 32) 1 else 0), reserved);
    }
}

/// No-pixel-geometry single-column budget (coverSlotHeight returns full cap).
/// Mirrors drawDetailPane; returns resulting episode-grid row count.
fn worstCaseGridRows(h: u16) u16 {
    const cap = coverHeightCap(h);
    const after_cover: u16 = if (cap < min_cover_rows) 0 else cap + cover_spacer_rows;
    const header = @min(max_header_rows, h -| after_cover);
    const after_header = after_cover + header;
    std.debug.assert(after_header <= h); // drifted constant would underflow
    const remaining = h - after_header;
    const synopsis = @min(synopsisCap(remaining), remaining);
    const after_synopsis = after_header + synopsis;
    const after_spacer = @min(h, after_synopsis + grid_caption_rows);
    return h - after_spacer;
}

test "ROD-137 invariant: worst-case single-column keeps >= min_grid_rows across heights" {
    const t = std.testing;
    // Sweep pins the budget: shrink any reserve and some height fails. h ≥ 11
    // hosts header + synopsis + min_grid_rows; upper bound past aesthetic cover
    // cap (28) exercises synopsis-absorbs-slack. Includes cover-drop (h ≤ 18)
    // and the h≈19 cliff.
    var h: u16 = 11;
    while (h <= 60) : (h += 1) {
        try t.expect(worstCaseGridRows(h) >= min_grid_rows);
    }
}

test "ROD-137 invariant: exact budget at the DoD geometry (35-row terminal, pane h=32)" {
    const t = std.testing;
    // cover 19 + spacer, 7-row header, 2-line synopsis, grid spacer, 2 grid rows.
    const h: u16 = 32;
    try t.expectEqual(@as(u16, 19), coverHeightCap(h));
    try t.expectEqual(min_grid_rows, worstCaseGridRows(h));
    const after_header = (coverHeightCap(h) + cover_spacer_rows) + max_header_rows;
    try t.expectEqual(min_synopsis_rows, synopsisCap(h - after_header));
}

// ── ROD-396 F1: episode-grid scratch aliasing ────────────────────────────────

test "scratchSlotFor: unique consecutive slots, degrades to null past the cap (ROD-396 F1)" {
    const t = std.testing;
    const cap: usize = 4;
    const cols: u16 = 2;
    const view_top: usize = 3; // base = 6

    try t.expectEqual(@as(?usize, 0), scratchSlotFor(6, view_top, cols, cap));
    try t.expectEqual(@as(?usize, 1), scratchSlotFor(7, view_top, cols, cap));
    try t.expectEqual(@as(?usize, 3), scratchSlotFor(9, view_top, cols, cap));
    // At/past cap → null (borrow path); never slot == cap.
    try t.expectEqual(@as(?usize, null), scratchSlotFor(10, view_top, cols, cap));
    try t.expectEqual(@as(?usize, null), scratchSlotFor(11, view_top, cols, cap));

    // Invariant the `% len` bug broke: non-null slots stay distinct (no N→N-len alias).
    var seen = [_]bool{false} ** 4;
    for (6..6 + 20) |ep_idx| {
        if (scratchSlotFor(ep_idx, view_top, cols, cap)) |slot| {
            try t.expect(slot < cap);
            try t.expect(!seen[slot]);
            seen[slot] = true;
        }
    }
}

test "drawEpisodeGrid: cell 0 and cell 512 never alias past the old 512-slot cap (ROD-396 F1)" {
    const t = std.testing;
    // >512 cells used to wrap slot 512 onto 0 (cell 0 showed "[513]"). Cell 0
    // must be "1", cell 512 "513".
    var app: App = .{};
    app.gpa = t.allocator;
    app.active_pane = .list; // putClipped path (nothing focused)

    var raw: [700][4]u8 = undefined;
    var proto: [700]domain.EpisodeNumber = undefined;
    for (0..700) |i| proto[i] = .{ .raw = std.fmt.bufPrint(&raw[i], "{d}", .{i + 1}) catch unreachable };
    app.episodes.results = try workers.dupEpisodesOwned(app.gpa, &proto);
    defer app.episodes.freeResults(t.allocator);

    var screen = try vaxis.Screen.init(t.allocator, .{ .rows = 15, .cols = 200, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(t.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 200,
        .height = 15,
        .screen = &screen,
    };

    drawEpisodeGrid(&app, win, 200, 15);

    try t.expectEqualStrings("[", win.readCell(0, 0).?.char.grapheme);
    try t.expectEqualStrings("1", win.readCell(1, 0).?.char.grapheme);
    // Cell 512 at grid col 32, row 12 → x=160: "[513]".
    try t.expectEqualStrings("[", win.readCell(160, 12).?.char.grapheme);
    try t.expectEqualStrings("5", win.readCell(161, 12).?.char.grapheme);
    try t.expectEqualStrings("1", win.readCell(162, 12).?.char.grapheme);
    try t.expectEqualStrings("3", win.readCell(163, 12).?.char.grapheme);
}

// ── ROD-231: Watchlist/History detail title-parity ───────────────────────────

test "ROD-231/ROD-205: drawAltTitles de-dupes the two non-primary forms against the resolved primary" {
    const t = std.testing;
    var app: App = .{};

    var screen = try vaxis.Screen.init(t.allocator, .{ .rows = 8, .cols = 60, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(t.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 60,
        .height = 8,
        .screen = &screen,
    };

    const both: Anime = .{
        .id = "ks",
        .name = "Kimetsu no Yaiba",
        .english_name = "Demon Slayer: Kimetsu no Yaiba",
        .native_name = "鬼滅の刃",
    };

    // Romaji primary: english then native; only native italic (§1.3).
    try t.expectEqual(@as(u16, 2), drawAltTitles(&app, win, 60, 8, both, both.name, 0));
    try t.expectEqualStrings("D", win.readCell(0, 0).?.char.grapheme);
    try t.expectEqualStrings("鬼", win.readCell(0, 1).?.char.grapheme);
    try t.expect(!win.readCell(0, 0).?.style.italic);
    try t.expect(win.readCell(0, 1).?.style.italic);

    // English primary: romaji + native.
    try t.expectEqual(@as(u16, 2), drawAltTitles(&app, win, 60, 8, both, both.english_name.?, 0));
    try t.expectEqualStrings("K", win.readCell(0, 0).?.char.grapheme);
    try t.expectEqualStrings("鬼", win.readCell(0, 1).?.char.grapheme);
    try t.expect(!win.readCell(0, 0).?.style.italic);

    // Native primary: romaji + english, both plain.
    try t.expectEqual(@as(u16, 2), drawAltTitles(&app, win, 60, 8, both, both.native_name.?, 0));
    try t.expectEqualStrings("K", win.readCell(0, 0).?.char.grapheme);
    try t.expectEqualStrings("D", win.readCell(0, 1).?.char.grapheme);
    try t.expect(!win.readCell(0, 1).?.style.italic);

    // English byte-equal to romaji → skipped; only native.
    const eng_dupe: Anime = .{
        .id = "fr",
        .name = "Frieren",
        .english_name = "Frieren",
        .native_name = "葬送のフリーレン",
    };
    try t.expectEqual(@as(u16, 4), drawAltTitles(&app, win, 60, 8, eng_dupe, eng_dupe.name, 3));
    try t.expectEqualStrings("葬", win.readCell(0, 3).?.char.grapheme);

    // No alts → no rows (no blank line).
    const none: Anime = .{ .id = "y", .name = "Solo" };
    try t.expectEqual(@as(u16, 5), drawAltTitles(&app, win, 60, 8, none, none.name, 5));
}

test "ROD-231: animeFromHistoryRecord carries english + native title to the renderer" {
    const t = std.testing;
    // History/Watchlist preview maps store row → Anime; these fields must survive.
    const rec: AnimeRecord = .{
        .source = "allanime",
        .source_id = "ks",
        .title = "Kimetsu no Yaiba",
        .title_english = "Demon Slayer: Kimetsu no Yaiba",
        .native_name = "鬼滅の刃",
    };
    const a = App.animeFromHistoryRecord(rec);
    try t.expectEqualStrings("Demon Slayer: Kimetsu no Yaiba", a.english_name.?);
    try t.expectEqualStrings("鬼滅の刃", a.native_name.?);
}

test "ROD-261: animeFromHistoryRecord carries the enrichment-expansion fields" {
    const t = std.testing;
    // Full ROD-261 set through the store→Anime map (rail/chips depend on it).
    const studios = [_][]const u8{"Madhouse"};
    const rec: AnimeRecord = .{
        .source = "allanime",
        .source_id = "fr",
        .title = "Frieren",
        .studios = &studios,
        .duration = 24,
        .source_material = "MANGA",
        .rank = 1,
        .rank_type = "RATED",
        .rank_year = 2023,
        .next_airing_at = 1_700_000_000,
        .next_airing_episode = 15,
        .country = "JP",
    };
    const a = App.animeFromHistoryRecord(rec);
    try t.expectEqual(@as(usize, 1), a.studios.len);
    try t.expectEqualStrings("Madhouse", a.studios[0]);
    try t.expectEqual(@as(?u32, 24), a.duration);
    try t.expectEqualStrings("MANGA", a.source_material.?);
    try t.expectEqual(@as(?u32, 1), a.rank);
    try t.expectEqualStrings("RATED", a.rank_type.?);
    try t.expectEqual(@as(?u32, 2023), a.rank_year);
    try t.expectEqual(@as(?i64, 1_700_000_000), a.next_airing_at);
    try t.expectEqual(@as(?u32, 15), a.next_airing_episode);
    try t.expectEqualStrings("JP", a.country.?);
}
