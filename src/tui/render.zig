//! Zigoku — shared TUI render helpers.

const std = @import("std");
const vaxis = @import("vaxis");
const colors = @import("colors.zig");
const store_mod = @import("../store.zig");

const AnimeRecord = store_mod.AnimeRecord;

/// "ep 3/12 · watching" — whatever we actually know. total_episodes can be null
/// (source didn't say), in which case we drop the denominator.
pub fn formatMeta(buf: []u8, rec: AnimeRecord) []const u8 {
    if (rec.total_episodes) |total| {
        return std.fmt.bufPrint(buf, "ep {d}/{d} · {s}", .{ rec.progress, total, rec.list_status }) catch rec.list_status;
    }
    return std.fmt.bufPrint(buf, "ep {d} · {s}", .{ rec.progress, rec.list_status }) catch rec.list_status;
}

// ── tiny render helpers ─────────────────────────────────────────────────────

/// §4.5 progress bar for a history row. `row_bg` is the row's background color
/// (bg.surface for the focused entry, bg.base otherwise). `frac_buf` must be
/// App-owned — vaxis holds a reference until the next render call.
pub fn drawProgressBar(win: vaxis.Window, row: u16, col: u16, bar_w: u16, rec: AnimeRecord, row_bg: vaxis.Color, frac_buf: []u8) void {
    const is_planning = std.mem.eql(u8, rec.list_status, "planning");
    const is_watching = std.mem.eql(u8, rec.list_status, "watching");
    const is_paused = std.mem.eql(u8, rec.list_status, "paused");

    const filled: u16 = if (is_planning) 0 else blk: {
        if (rec.total_episodes) |total| {
            if (total <= 0) break :blk if (rec.progress > 0) bar_w / 3 else 0;
            const bw: i64 = @intCast(bar_w);
            const f = @divTrunc(@max(0, rec.progress) * bw, total);
            break :blk @intCast(@min(bw, f));
        }
        break :blk if (rec.progress > 0) bar_w / 3 else 0;
    };

    const fill_color = if (is_watching or is_paused) colors.focus else colors.fg3;
    const frac_color = if (is_watching or is_paused) colors.fg2 else colors.fg3;

    put(win, row, col, "[", style(colors.fg3, .{ .bg = row_bg }));
    var c: u16 = 0;
    while (c < bar_w) : (c += 1) {
        if (c < filled) {
            put(win, row, col + 1 + c, "█", style(fill_color, .{ .bg = row_bg, .dim = is_paused }));
        } else {
            put(win, row, col + 1 + c, "░", style(colors.chrome, .{ .bg = row_bg }));
        }
    }
    put(win, row, col + 1 + bar_w, "]", style(colors.fg3, .{ .bg = row_bg }));

    const frac: []const u8 = if (rec.total_episodes) |total|
        std.fmt.bufPrint(frac_buf, "  {d} / {d} eps", .{ rec.progress, total }) catch ""
    else
        std.fmt.bufPrint(frac_buf, "  {d} / ? eps", .{rec.progress}) catch "";
    put(win, row, col + 1 + bar_w + 1, frac, style(frac_color, .{ .bg = row_bg }));
}

pub fn put(win: vaxis.Window, row: u16, col: u16, text: []const u8, sty: vaxis.Style) void {
    _ = win.printSegment(.{ .text = text, .style = sty }, .{ .row_offset = row, .col_offset = col });
}

/// Like `put`, but clipped to `max_w` columns via a 1-row child window. The
/// child bounds stop a long string from bleeding past its column budget into a
/// neighbour (and the clip lands on a grapheme boundary, so multibyte titles
/// stay valid). max_w == 0 draws nothing.
pub fn putClipped(win: vaxis.Window, row: u16, col: u16, max_w: u16, text: []const u8, sty: vaxis.Style) void {
    if (max_w == 0) return;
    const child = win.child(.{ .x_off = @intCast(col), .y_off = @intCast(row), .width = max_w, .height = 1 });
    _ = child.printSegment(.{ .text = text, .style = sty }, .{});
}

/// Paint a full-width 1-row band in `bg` — the focused-row background shift.
pub fn fillRow(win: vaxis.Window, row: u16, w: u16, bg: vaxis.Color) void {
    const child = win.child(.{ .x_off = 0, .y_off = @intCast(row), .width = w, .height = 1 });
    child.fill(.{ .style = .{ .bg = bg } });
}

/// Horizontally centre an ASCII string on `row` (byte length == display width
/// for the ASCII copy this is used with).
pub fn centerText(win: vaxis.Window, row: u16, w: u16, text: []const u8, sty: vaxis.Style) void {
    const tw: u16 = @intCast(text.len);
    const col: u16 = if (w > tw) (w - tw) / 2 else 0;
    putClipped(win, row, col, w, text, sty);
}

pub fn drawWrappedText(win: vaxis.Window, start_row: u16, start_col: u16, max_w: u16, max_rows: u16, text: []const u8, sty: vaxis.Style) u16 {
    if (max_w == 0 or max_rows == 0 or text.len == 0) return 0;

    var row: u16 = 0;
    var i: usize = 0;
    while (i < text.len and row < max_rows) {
        const remaining = text[i..];
        if (remaining.len <= max_w) {
            putClipped(win, start_row + row, start_col, max_w, std.mem.trim(u8, remaining, " "), sty);
            return row + 1;
        }

        var cut: usize = max_w;
        while (cut > 0 and remaining[cut - 1] != ' ') : (cut -= 1) {}
        if (cut == 0) cut = max_w;

        const line = std.mem.trim(u8, remaining[0..cut], " ");
        putClipped(win, start_row + row, start_col, max_w, line, sty);
        row += 1;
        i += cut;
        while (i < text.len and text[i] == ' ') : (i += 1) {}
    }
    return row;
}

// History-row layout columns. The detail/responsive layout is ROD-72+; this is
// the fixed two-column (title | meta) skeleton.
pub const title_col: u16 = 4;
pub const meta_col: u16 = 48;
pub const title_meta_gap: u16 = 2;

// One style constructor for foreground-on-(void|surface) cells. bg defaults to
// the void so most call sites stay terse; the focused list row passes bg.surface
// to get §4.1's background shift.
pub fn style(fg: vaxis.Color, opts: struct {
    bg: vaxis.Color = colors.bg_base,
    bold: bool = false,
    italic: bool = false,
    blink: bool = false,
    dim: bool = false,
}) vaxis.Style {
    return .{ .fg = fg, .bg = opts.bg, .bold = opts.bold, .italic = opts.italic, .blink = opts.blink, .dim = opts.dim };
}
