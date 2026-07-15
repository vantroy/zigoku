//! Shared cover-art rendering (ROD-243): pixel → terminal for detail and Discover.
//! Fit math (`halfBlockFit`) lives in `cover_state.zig`; this module consumes it.

const std = @import("std");
const vaxis = @import("vaxis");
const cover_mod = @import("../cover.zig");
const render = @import("render.zig");
const CoverState = @import("cover_state.zig").CoverState;

pub const Pixels = cover_mod.Pixels;

/// Kitty image fitted + centered in `win` (aspect vs cell pixel metrics).
/// false on degenerate geometry / draw fault (caller falls back).
pub fn drawKittyFit(img: vaxis.Image, win: vaxis.Window) bool {
    const cols = win.screen.width;
    const rows = win.screen.height;
    if (cols == 0 or rows == 0 or win.width == 0 or win.height == 0) return false;

    const pix_per_col = std.math.divCeil(usize, win.screen.width_pix, cols) catch return false;
    const pix_per_row = std.math.divCeil(usize, win.screen.height_pix, rows) catch return false;
    const slot_w = pix_per_col * win.width;
    const slot_h = pix_per_row * win.height;
    if (slot_w == 0 or slot_h == 0) return false;

    const img_w = @as(usize, img.width);
    const img_h = @as(usize, img.height);
    if (img_w == 0 or img_h == 0) return false;

    var draw_cols: u16 = win.width;
    var draw_rows: u16 = win.height;

    if (img_w * slot_h > img_h * slot_w) {
        const fit_h_px = @max(@as(usize, 1), (img_h * slot_w) / img_w);
        draw_rows = @intCast(@max(@as(usize, 1), @min(@as(usize, win.height), fit_h_px / pix_per_row)));
    } else if (img_w * slot_h < img_h * slot_w) {
        const fit_w_px = @max(@as(usize, 1), (img_w * slot_h) / img_h);
        draw_cols = @intCast(@max(@as(usize, 1), @min(@as(usize, win.width), fit_w_px / pix_per_col)));
    }

    const draw_win = win.child(.{
        .x_off = @intCast((win.width - draw_cols) / 2),
        .y_off = @intCast((win.height - draw_rows) / 2),
        .width = draw_cols,
        .height = draw_rows,
    });
    img.draw(draw_win, .{ .scale = .fit }) catch return false;
    return true;
}

/// One half-pixel sample on a `cols × rows*2` grid; outside fit returns `base` (ROD-164 matte).
fn sampleHalfBlock(px: Pixels, gx: u32, gy: u32, off_x: u32, off_y: u32, fit_w: u32, fit_h: u32, base: vaxis.Color) vaxis.Color {
    if (gx < off_x or gy < off_y) return base;
    const fx = gx - off_x;
    const fy = gy - off_y;
    if (fx >= fit_w or fy >= fit_h) return base;
    const sx = @min(px.w - 1, fx * px.w / fit_w);
    const sy = @min(px.h - 1, fy * px.h / fit_h);
    const idx = (@as(usize, sy) * px.w + sx) * 4;
    return .{ .rgb = .{ px.rgba[idx], px.rgba[idx + 1], px.rgba[idx + 2] } };
}

/// Half-block mosaic: each cell is `▀` (fg top / bg bottom). Letterboxed via halfBlockFit.
pub fn drawHalfBlock(win: vaxis.Window, px: Pixels, base: vaxis.Color) void {
    const cols = win.width;
    const rows = win.height;
    if (cols == 0 or rows == 0 or px.w == 0 or px.h == 0) return;

    const grid_w: u32 = cols;
    const grid_h: u32 = @as(u32, rows) * 2;

    // Cell metrics for non-2:1 correction; 0/0 → square half-pixel assumption.
    const sw = win.screen.width;
    const sh = win.screen.height;
    const ppc: u32 = if (sw != 0) (std.math.divCeil(u32, @intCast(win.screen.width_pix), sw) catch 0) else 0;
    const pph: u32 = if (sh != 0) (std.math.divCeil(u32, @intCast(win.screen.height_pix), sh) catch 0) else 0;

    const fit = CoverState.halfBlockFit(px.w, px.h, grid_w, grid_h, ppc, pph);

    var ry: u16 = 0;
    while (ry < rows) : (ry += 1) {
        const top_y = @as(u32, ry) * 2;
        var cx: u16 = 0;
        while (cx < cols) : (cx += 1) {
            const top = sampleHalfBlock(px, cx, top_y, fit.off_x, fit.off_y, fit.w, fit.h, base);
            const bot = sampleHalfBlock(px, cx, top_y + 1, fit.off_x, fit.off_y, fit.w, fit.h, base);
            render.put(win, ry, cx, "▀", .{ .fg = top, .bg = bot });
        }
    }
}
