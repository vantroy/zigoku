//! Zigoku — shared TUI render helpers.

const std = @import("std");
const vaxis = @import("vaxis");
const colors = @import("colors.zig");
const store_mod = @import("../store.zig");
const domain = @import("../domain.zig");

const AnimeRecord = store_mod.AnimeRecord;

// ── tiny render helpers ─────────────────────────────────────────────────────

/// §4.5 + ROD-194: the bar fill color. `state.focus` (cyan) means "the focused
/// cursor row" everywhere (▸, title, bar), so it is granted ONLY to the selected
/// row while the list pane holds keyboard focus — and there it OVERRIDES the
/// status color (a selected completed/planning row's bar is cyan too, so the
/// cursor always owns the single brightest bar; this is the §4.1 repro fix). Off
/// that one row everything steps down:
///   - selected but list unfocused (detail pane active) → fg2, all statuses (the
///     row recedes but is still "where you are")
///   - unselected watching/paused → fg2 (status, not selection — can't out-shout
///     the cursor; the ▸/◐ glyph still carries the status identity)
///   - unselected planning → chrome (empty-bar tint, §4.5)
///   - unselected completed/dropped → fg3 (text.dim)
/// Pure so the rule can be unit-tested without a render pass.
pub fn barFillColor(rec: AnimeRecord, selected: bool, list_focused: bool, pal: *const colors.Palette) vaxis.Color {
    if (selected) return if (list_focused) pal.focus else pal.fg2;
    return switch (rec.list_status) {
        .watching, .paused => pal.fg2,
        .planning => pal.chrome,
        else => pal.fg3,
    };
}

/// §4.5 + ROD-194: the episode-fraction text color. It earns text.muted (fg2)
/// only on the selected, list-focused watching/paused row (where the bar is the
/// bright cursor bar); every other row keeps it dim (fg3) so it never competes.
pub fn barFracColor(rec: AnimeRecord, selected: bool, list_focused: bool, pal: *const colors.Palette) vaxis.Color {
    const is_progressing = rec.list_status == .watching or rec.list_status == .paused;
    return if (selected and list_focused and is_progressing) pal.fg2 else pal.fg3;
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
    const frac_color = barFracColor(rec, selected, list_focused, pal);

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

/// Truncate `text` to at most `max_cols` display columns, copying the result
/// into `buf` and appending a single-column "…" when (and only when) truncation
/// actually happened (ROD-166, §4.7). Cuts on grapheme-cluster boundaries via
/// vaxis's iterator, so a multibyte cluster is never split — and measures real
/// display width (gwidth), so a wide CJK glyph counts as the 2 columns it paints.
///
/// Unlike `putClipped` (which clips silently at the cell grid), this leaves a "…"
/// affordance so the user knows the copy was cut. Returns the slice of `buf`
/// written. The copy stops early if the next cluster + "…" would overflow `buf`,
/// so a [80]u8 caller can never overrun regardless of how byte-dense the input
/// is (the toast budget is 36 cols / well within 80 bytes for any real copy).
pub fn truncateToWidth(buf: []u8, text: []const u8, max_cols: u16) []const u8 {
    if (max_cols == 0) return buf[0..0];
    // Fast path only when the copy fits BOTH the column budget AND the byte
    // buffer — a string can be ≤ max_cols columns yet byte-denser than `buf`
    // (multibyte clusters), and a plain `@min` clip there would shear a cluster
    // mid-sequence with no "…" affordance. Such input falls through to the
    // grapheme-walking path below, which cuts on a boundary and appends "…".
    if (vaxis.gwidth.gwidth(text, .unicode) <= max_cols and text.len <= buf.len) {
        @memcpy(buf[0..text.len], text);
        return buf[0..text.len];
    }
    const ellipsis = "…"; // U+2026: 1 display column, 3 UTF-8 bytes.
    if (buf.len < ellipsis.len) return buf[0..0];
    // Reserve one column for the "…" we are about to append (max_cols ≥ 1 here,
    // guarded at the top).
    const budget: u16 = max_cols - 1;
    var cols: u16 = 0;
    var len: usize = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        const cluster = g.bytes(text);
        const gw = vaxis.gwidth.gwidth(cluster, .unicode);
        if (cols + gw > budget) break;
        if (len + cluster.len + ellipsis.len > buf.len) break;
        @memcpy(buf[len .. len + cluster.len], cluster);
        len += cluster.len;
        cols += gw;
    }
    @memcpy(buf[len .. len + ellipsis.len], ellipsis);
    return buf[0 .. len + ellipsis.len];
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

/// Draw a centered "<key><rest>" hint as one unit: the `key` glyph in `key_sty`,
/// the trailing `rest` in `rest_sty`, centred together by combined *display*
/// width (gwidth, so a wide glyph counts the cells it paints — no ASCII-only
/// assumption). The first-run absent states use this for their "<key>  <action>"
/// lines (ROD-211).
pub fn centerKeyHint(win: vaxis.Window, row: u16, w: u16, key: []const u8, key_sty: vaxis.Style, rest: []const u8, rest_sty: vaxis.Style) void {
    const key_w: u16 = @intCast(vaxis.gwidth.gwidth(key, .unicode));
    const total: u16 = key_w + @as(u16, @intCast(vaxis.gwidth.gwidth(rest, .unicode)));
    const start: u16 = if (w > total) (w - total) / 2 else 0;
    put(win, row, start, key, key_sty);
    putClipped(win, row, start + key_w, w -| (start + key_w), rest, rest_sty);
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

// History-row layout column. Row 1 is title-only (the episode count lives on the
// row-2 progress bar, not duplicated up here — ROD-227); the §5.4 right-meta
// (resume/season/status chips) is deferred, so there is no meta column to reserve.
pub const title_col: u16 = 4;

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

test "barFillColor: focus cyan is the cursor, and the cursor overrides status (ROD-194)" {
    const pal = &colors.terminal_ghost;
    // The selected, list-focused row owns the brightest bar REGARDLESS of status —
    // this is the §4.1 repro fix (a selected completed row must out-rank an
    // unselected watching one). state.focus here means "the cursor", not "watching".
    try testing.expectEqual(pal.focus, barFillColor(mkRec(.watching), true, true, pal));
    try testing.expectEqual(pal.focus, barFillColor(mkRec(.completed), true, true, pal));
    try testing.expectEqual(pal.focus, barFillColor(mkRec(.planning), true, true, pal));

    // Selected but the detail pane has focus → the row recedes to fg2 (all statuses).
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

test "truncateToWidth: short copy is passed through verbatim (ROD-166)" {
    var buf: [80]u8 = undefined;
    try testing.expectEqualStrings("network down", truncateToWidth(&buf, "network down", 36));
    // Exactly at the budget is not truncation — no ellipsis.
    try testing.expectEqualStrings("123456", truncateToWidth(&buf, "123456", 6));
}

test "truncateToWidth: long copy is cut on a boundary with a trailing … (ROD-166)" {
    var buf: [80]u8 = undefined;
    // 8 ASCII chars, budget 5 → 4 cols of text + "…" = 5 display columns.
    try testing.expectEqualStrings("abcd…", truncateToWidth(&buf, "abcdefgh", 5));
    // The result is one byte longer than the budget (… is 3 bytes) but 5 cols wide.
    const out = truncateToWidth(&buf, "abcdefgh", 5);
    try testing.expectEqual(@as(u16, 5), vaxis.gwidth.gwidth(out, .unicode));
}

test "truncateToWidth: never splits a multibyte cluster, counts display width (ROD-166)" {
    var buf: [80]u8 = undefined;
    // Each CJK glyph is 2 display columns / 3 bytes. Budget 5 leaves 4 cols for
    // text (one reserved for …): two glyphs (4 cols) fit, the third does not.
    const out = truncateToWidth(&buf, "東京都市", 5);
    try testing.expectEqualStrings("東京…", out);
    try testing.expectEqual(@as(u16, 5), vaxis.gwidth.gwidth(out, .unicode));
}

test "truncateToWidth: byte-dense but column-narrow input falls off the fast path safely (ROD-166)" {
    // 3 CJK glyphs = 6 display cols / 9 bytes, into an 8-byte buf with a generous
    // column budget. It fits the columns but NOT the bytes — the fast path's
    // `text.len <= buf.len` guard rejects it so it cuts on a cluster boundary
    // with "…" instead of shearing a 3-byte glyph mid-sequence (Elara M1 / Nyra).
    var buf: [8]u8 = undefined;
    const out = truncateToWidth(&buf, "東京都", 10);
    try testing.expect(std.unicode.utf8ValidateSlice(out)); // never mid-cluster
    try testing.expect(std.mem.endsWith(u8, out, "…"));
}

test "truncateToWidth: a single grapheme wider than the budget yields just … (ROD-166)" {
    // A 2-col glyph against a 1-col budget can't fit even one cluster → "…".
    var buf: [80]u8 = undefined;
    try testing.expectEqualStrings("…", truncateToWidth(&buf, "東", 1));
    // max_cols == 0 is a 0-column budget: empty, not even "…".
    try testing.expectEqualStrings("", truncateToWidth(&buf, "anything", 0));
}

test "barFracColor: text.muted only on the selected, list-focused watching/paused row (ROD-194)" {
    const pal = &colors.terminal_ghost;
    // The one bright-frac case: it rides along with the bright cursor bar.
    try testing.expectEqual(pal.fg2, barFracColor(mkRec(.watching), true, true, pal));
    try testing.expectEqual(pal.fg2, barFracColor(mkRec(.paused), true, true, pal));

    // Cursor row but detail-focused, or a non-progressing status → dim.
    try testing.expectEqual(pal.fg3, barFracColor(mkRec(.watching), true, false, pal));
    try testing.expectEqual(pal.fg3, barFracColor(mkRec(.completed), true, true, pal));
    // Unselected watching → dim (the frac never competes off the cursor row).
    try testing.expectEqual(pal.fg3, barFracColor(mkRec(.watching), false, true, pal));
}
