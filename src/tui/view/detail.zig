//! Zigoku — Detail view render pass: poster cover (Kitty / half-block / fallback),
//! metadata header, and the episode grid. Extracted from app.zig along the
//! tick/draw seam (ROD-144). Cover *state* (caches, in-flight tracking, failure
//! cooldown) lives in app.zig; this is the pure render of it.

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const render = @import("../render.zig");

const App = app_mod.App;
const put = render.put;
const putClipped = render.putClipped;
const centerText = render.centerText;
const drawWrappedText = render.drawWrappedText;

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

pub fn drawDetailPane(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer, win: vaxis.Window, w: u16, h: u16, term_w: u16) void {
    if (w < 10) return;

    var row: u16 = 0;

    const info = self.detailRenderInfo();
    const anime = info.anime;

    // Cover art block (§3.3 + §7.3/§7.5).
    // Width stays fixed by layout tier; height is derived from terminal pixel
    // geometry so the panel itself stays poster-shaped instead of cell-tall.
    const cover_w: u16 = if (term_w >= 100) 20 else if (term_w >= 80) 14 else 0;
    const cover_h: u16 = if (term_w >= 100) coverSlotHeight(win, cover_w, 28) else if (term_w >= 80) coverSlotHeight(win, cover_w, 20) else 0;
    if (cover_w > 0 and cover_h > 0) {
        const cover_win = win.child(.{ .x_off = 0, .y_off = row, .width = cover_w, .height = cover_h });
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
        row += cover_h + 1;
    }

    // Title — the selected result's name, or placeholder.
    if (anime != null and !std.mem.eql(u8, info.title, "—")) {
        putClipped(win, row, 0, w, info.title, self.s(self.palette.fg, .{ .bold = true }));
    } else {
        putClipped(win, row, 0, w, info.title, self.s(self.palette.fg3, .{}));
    }
    row += 1;

    // Score — "[--/100]" until AniList enrichment fills `a.score`, then tiered rendering.
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
    putClipped(win, row, 0, w, score_text, score_style);
    row += 1;

    // Hairline — clipped to window width so it never wraps onto the next row.
    // "─" is 3 UTF-8 bytes; we need exactly `cols` glyphs = `cols * 3` bytes.
    if (row < h) {
        const cols: u16 = @min(w, 160);
        put(win, row, 0, ("─" ** 160)[0 .. @as(usize, cols) * 3], self.s(self.palette.chrome, .{}));
    }
    row += 1;

    // Metadata: episode count, falling back to AniList total when needed.
    if (row < h) {
        const meta_style = if (info.has_meta) self.s(self.palette.fg2, .{}) else self.s(self.palette.fg3, .{});
        putClipped(win, row, 0, w, info.meta, meta_style);
        row += 1;
    }

    // Synopsis: real metadata when present, otherwise the existing stub.
    if (row < h) {
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
    }

    if (row < h) row += 1; // blank line before grid

    // Episode grid.
    if (row >= h) return;
    const grid_h: u16 = h - row;
    const grid_win = win.child(.{ .x_off = 0, .y_off = row, .width = w, .height = grid_h });
    drawEpisodeGrid(self, grid_win, w, grid_h);
}

fn drawEpisodeGrid(self: *App, win: vaxis.Window, w: u16, h: u16) void {
    if (self.episode_loading) {
        centerText(win, 0, w, "⠋ loading episodes…", self.s(self.palette.focus, .{}));
        return;
    }
    const eps = self.episode_results orelse {
        // No fetch fired yet (detail pane opened but no item selected).
        return;
    };
    if (eps.len == 0) {
        putClipped(win, 0, 0, w, "no episodes", self.s(self.palette.fg3, .{ .italic = true }));
        return;
    }

    // Each cell is 5 chars wide: "[NN] " or "[NNN]" — allocate 5 per cell.
    const cell_w: u16 = 5;
    const cols: u16 = @max(1, w / cell_w);

    // Scroll so that episode_cursor is in view.
    const cursor_row: usize = self.episode_cursor / cols;
    const viewport_rows: usize = h;
    const view_top: usize = if (cursor_row >= viewport_rows)
        cursor_row + 1 - viewport_rows
    else
        0;

    // §4.6 launching cell: the episode currently resolving/playing renders a
    // spinner in its grid slot. It tracks the SESSION, not episode_cursor — the
    // grid stays navigable during play (you can browse while mpv loads), so the
    // spinner stays pinned to the played episode, and only on the show actually
    // on screen (same_show, mirroring finishPlayback's guard).
    const launching_idx: usize = blk: {
        const here = self.playing and self.session.episode_index > 0 and
            self.detail_for_id != null and self.session.anime_id.len > 0 and
            std.mem.eql(u8, self.session.anime_id, self.detail_for_id.?);
        break :blk if (here) self.session.episode_index - 1 else std.math.maxInt(usize);
    };

    var grid_row: u16 = 0;
    var ep_idx: usize = view_top * cols;
    while (grid_row < h and ep_idx < eps.len) : (grid_row += 1) {
        var col_off: u16 = 0;
        var c: u16 = 0;
        while (c < cols and ep_idx < eps.len) : (c += 1) {
            const ep = eps[ep_idx];
            const focused = ep_idx == self.episode_cursor and self.active_pane == .detail;
            const launching = ep_idx == launching_idx;

            // Use ep_scratch to avoid dangling stack buffers. Index relative
            // to the viewport start so we never alias two live cells.
            const slot = (ep_idx - view_top * cols) % 512;
            const cell_buf = &self.ep_scratch[slot];
            // §4.6: a launching cell shows the current spinner frame in place of
            // its number, in the same `[ ]` shell so it reads as that cell working.
            const cell_text = if (launching)
                std.fmt.bufPrint(cell_buf, "[{s}]", .{self.spinnerChar()}) catch "[?]"
            else
                std.fmt.bufPrint(cell_buf, "[{s}]", .{ep.raw}) catch "[?]";

            // §4.6: watched cells (index below the high-water mark) recede to
            // text.dim; unwatched stay text.muted; the cursor always wins
            // (ROD-131). text.dim is `fg3` alone — matching the completed/dropped
            // convention in history.zig; the `.dim` SGR attr is reserved for the
            // paused semantic (§2.4), so it is deliberately not used here. A
            // launching cell escalates focus→hot past isSlowPath (§4.8), same as
            // every other slow-path spinner; it outranks focus/watched.
            const watched = ep_idx < @as(usize, self.detail_progress);
            const cell_style = if (launching)
                self.s(if (self.isSlowPath()) self.palette.hot else self.palette.focus, .{ .bg = self.palette.bg_surface, .bold = true })
            else if (focused)
                self.s(self.palette.focus, .{ .bg = self.palette.bg_surface, .bold = true })
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
