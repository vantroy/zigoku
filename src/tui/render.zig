//! Zigoku — shared TUI render helpers.

const std = @import("std");
const vaxis = @import("vaxis");
const colors = @import("colors.zig");
const store_mod = @import("../store.zig");
const domain = @import("../domain.zig");

const AnimeRecord = store_mod.AnimeRecord;

/// "ep 3/12 · watching" — whatever we actually know. total_episodes can be null
/// (source didn't say), in which case we drop the denominator.
pub fn formatMeta(buf: []u8, rec: AnimeRecord) []const u8 {
    const status = rec.list_status.str();
    if (rec.total_episodes) |total| {
        return std.fmt.bufPrint(buf, "ep {d}/{d} · {s}", .{ rec.progress, total, status }) catch status;
    }
    return std.fmt.bufPrint(buf, "ep {d} · {s}", .{ rec.progress, status }) catch status;
}

// ── tiny render helpers ─────────────────────────────────────────────────────

/// §4.5 + ROD-194: the bar fill color. `state.focus` (cyan) is reserved for the
/// selection affordance, so it is granted ONLY to the selected row while the list
/// pane holds keyboard focus. Everything else steps down:
///   - selected but list unfocused (detail pane active) → fg2 (the row recedes)
///   - unselected watching/paused → fg2 (status, not selection — can't out-shout
///     the cursor; the ▸/◐ glyph still carries the status identity)
///   - unselected planning → chrome (empty-bar tint, §4.5)
///   - everything else (completed/dropped) → fg3
/// Pure so the rule can be unit-tested without a render pass.
pub fn barFillColor(rec: AnimeRecord, selected: bool, list_focused: bool, pal: *const colors.Palette) vaxis.Color {
    if (selected) return if (list_focused) pal.focus else pal.fg2;
    return switch (rec.list_status) {
        .watching, .paused => pal.fg2,
        .planning => pal.chrome,
        else => pal.fg3,
    };
}

/// §4.5 progress bar for a history row. `row_bg` is the row's background color
/// (bg.surface for the focused entry while the list pane has focus, bg.base
/// otherwise). `frac_buf` must be App-owned — vaxis holds a reference until the
/// next render call. `avail` is the total columns available for the whole
/// "[bar]  N / M eps" element starting at `col` (caller-computed against the
/// list's right edge, accounting for the left margin) — the frac is clipped to it
/// so it can't bleed into a neighbour. `selected`/`list_focused` gate the §4.1
/// selection affordance into the fill (ROD-194).
pub fn drawProgressBar(win: vaxis.Window, row: u16, col: u16, bar_w: u16, avail: u16, rec: AnimeRecord, row_bg: vaxis.Color, frac_buf: []u8, pal: *const colors.Palette, selected: bool, list_focused: bool) void {
    const is_watching = rec.list_status == .watching;
    const is_paused = rec.list_status == .paused;

    const filled: u16 = blk: {
        if (rec.total_episodes) |total| {
            if (total <= 0) break :blk if (rec.progress > 0) bar_w / 3 else 0;
            const bw: i64 = @intCast(bar_w);
            const f = @divTrunc(@max(0, rec.progress) * bw, total);
            break :blk @intCast(@min(bw, f));
        }
        break :blk if (rec.progress > 0) bar_w / 3 else 0;
    };

    const fill_color = barFillColor(rec, selected, list_focused, pal);
    // The fraction text earns text.muted (fg2) only when the bar is the selected,
    // list-focused row's; otherwise it stays dim (fg3) so it never competes.
    const frac_color = if (selected and list_focused and (is_watching or is_paused)) pal.fg2 else pal.fg3;

    put(win, row, col, "[", style(pal.fg3, .{ .bg = row_bg }));
    var c: u16 = 0;
    while (c < bar_w) : (c += 1) {
        if (c < filled) {
            put(win, row, col + 1 + c, "█", style(fill_color, .{ .bg = row_bg, .dim = is_paused }));
        } else {
            put(win, row, col + 1 + c, "░", style(pal.chrome, .{ .bg = row_bg }));
        }
    }
    put(win, row, col + 1 + bar_w, "]", style(pal.fg3, .{ .bg = row_bg }));

    const frac: []const u8 = if (rec.total_episodes) |total|
        std.fmt.bufPrint(frac_buf, "  {d} / {d} eps", .{ rec.progress, total }) catch ""
    else
        std.fmt.bufPrint(frac_buf, "  {d} / ? eps", .{rec.progress}) catch "";
    // Clip the frac to whatever the bar row budget leaves after the bracketed bar,
    // so a narrow two-pane list never bleeds "N / M eps" into the detail pane
    // (ROD-170). `avail` is the cols from `col` to the list's right edge.
    const frac_col = col + 1 + bar_w + 1;
    const frac_max = avail -| (1 + bar_w + 1);
    putClipped(win, row, frac_col, frac_max, frac, style(frac_color, .{ .bg = row_bg }));
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

// Style helper for drawProgressBar. Always call with an explicit `bg` — the
// default is pinned to terminal_ghost and is not palette-aware. App draw methods
// use App.s() instead, which carries the live palette.
fn style(fg: vaxis.Color, opts: struct {
    bg: vaxis.Color = colors.bg_base,
    bold: bool = false,
    italic: bool = false,
    blink: bool = false,
    dim: bool = false,
}) vaxis.Style {
    return .{ .fg = fg, .bg = opts.bg, .bold = opts.bold, .italic = opts.italic, .blink = opts.blink, .dim = opts.dim };
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn mkRec(status: domain.ListStatus) AnimeRecord {
    return .{ .source = "s", .source_id = "i", .title = "t", .list_status = status };
}

test "barFillColor: focus cyan is reserved for the selected, list-focused row (ROD-194)" {
    const pal = &colors.terminal_ghost;
    // The ONE case that earns state.focus: selected AND the list pane has focus.
    try testing.expectEqual(pal.focus, barFillColor(mkRec(.watching), true, true, pal));
    try testing.expectEqual(pal.focus, barFillColor(mkRec(.completed), true, true, pal));

    // Selected but the detail pane has focus → the row recedes to fg2.
    try testing.expectEqual(pal.fg2, barFillColor(mkRec(.watching), true, false, pal));
    try testing.expectEqual(pal.fg2, barFillColor(mkRec(.completed), true, false, pal));

    // Unselected watching/paused step OFF focus → fg2 (can't impersonate the cursor).
    try testing.expectEqual(pal.fg2, barFillColor(mkRec(.watching), false, true, pal));
    try testing.expectEqual(pal.fg2, barFillColor(mkRec(.paused), false, true, pal));

    // Unselected planning keeps the empty-bar chrome tint; the rest are dim.
    try testing.expectEqual(pal.chrome, barFillColor(mkRec(.planning), false, true, pal));
    try testing.expectEqual(pal.fg3, barFillColor(mkRec(.completed), false, true, pal));
    try testing.expectEqual(pal.fg3, barFillColor(mkRec(.dropped), false, true, pal));
}
