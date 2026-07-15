//! Shared TUI render helpers.

const std = @import("std");
const vaxis = @import("vaxis");
const colors = @import("colors.zig");
const store_mod = @import("../store.zig");
const domain = @import("../domain.zig");

const AnimeRecord = store_mod.AnimeRecord;

// ── tiny render helpers ─────────────────────────────────────────────────────

/// §4.5 + ROD-194: bar fill. Cyan (`pal.focus`) only for selected + list-focused;
/// that overrides status so the cursor owns the brightest bar (§4.1).
/// Else: selected/unfocused → fg2; unselected watching/paused → fg2;
/// planning → chrome; completed/dropped → fg3.
pub fn barFillColor(rec: AnimeRecord, selected: bool, list_focused: bool, pal: *const colors.Palette) vaxis.Color {
    if (selected) return if (list_focused) pal.focus else pal.fg2;
    return switch (rec.list_status) {
        .watching, .paused => pal.fg2,
        .planning => pal.chrome,
        else => pal.fg3,
    };
}

/// §4.5 + ROD-194: frac text is fg2 only on selected + list-focused watching/paused; else fg3.
pub fn barFracColor(rec: AnimeRecord, selected: bool, list_focused: bool, pal: *const colors.Palette) vaxis.Color {
    const is_progressing = rec.list_status == .watching or rec.list_status == .paused;
    return if (selected and list_focused and is_progressing) pal.fg2 else pal.fg3;
}

/// Cap on `progress` for `p * bar_w` so a hostile value cannot overflow i64
/// (ReleaseSafe panics the render loop). Belt for ROD-285 ingestion clamp.
const PROGRESS_MULT_CEILING: i64 = 1_000_000_000;

/// Pure fill width. Null/non-positive total → third-full stub if any progress.
fn progressFill(progress: i64, total_episodes: ?i64, bar_w: u16) u16 {
    const total = total_episodes orelse return if (progress > 0) bar_w / 3 else 0;
    if (total <= 0) return if (progress > 0) bar_w / 3 else 0;
    const p = @max(0, progress);
    // Full bar once p >= total. Cap p so `p * bw` cannot overflow i64
    // (ReleaseSafe would panic the render loop; belt for ROD-285).
    if (p >= total) return bar_w;
    const bw: i64 = @intCast(bar_w);
    const f = @divTrunc(@min(p, PROGRESS_MULT_CEILING) * bw, total);
    return @intCast(@min(bw, f));
}

/// Display numerator: floor at 0, cap at positive total so stale high-water never
/// shows "14 / 2" when total shrank (ROD-297). Non-positive total passes through
/// (AllAnime total=0 quirk keeps "N / 0"). Display heal only.
fn clampFrac(progress: i64, total: i64) i64 {
    const p = @max(0, progress);
    if (total <= 0) return p;
    return @min(p, total);
}

/// §4.5 progress bar. `frac_buf` must be App-owned (vaxis holds a ref until next
/// render). `avail` is cols from `col` to list right edge; frac is clipped so it
/// cannot bleed into the neighbour (ROD-170). selected/list_focused gate ROD-194 fill.
pub fn drawProgressBar(win: vaxis.Window, row: u16, col: u16, bar_w: u16, avail: u16, rec: AnimeRecord, row_bg: vaxis.Color, frac_buf: []u8, pal: *const colors.Palette, selected: bool, list_focused: bool) void {
    const is_paused = rec.list_status == .paused;

    const filled: u16 = progressFill(rec.progress, rec.total_episodes, bar_w);

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
        std.fmt.bufPrint(frac_buf, "  {d} / {d} eps", .{ clampFrac(rec.progress, total), total }) catch ""
    else
        std.fmt.bufPrint(frac_buf, "  {d} / ? eps", .{rec.progress}) catch "";
    // Clip frac to remaining budget so a narrow list never bleeds into detail (ROD-170).
    const frac_col = col + 1 + bar_w + 1;
    const frac_max = avail -| (1 + bar_w + 1);
    putClipped(win, row, frac_col, frac_max, frac, style(frac_color, .{ .bg = row_bg }));
}

/// Truncate to max_cols display columns into `buf`, append "…" only when cut
/// (ROD-166, §4.7). Cuts on grapheme boundaries; measures gwidth. Returns slice of buf.
pub fn truncateToWidth(buf: []u8, text: []const u8, max_cols: u16) []const u8 {
    if (max_cols == 0) return buf[0..0];
    // Fast path only when both column budget and byte buffer fit. Column-narrow
    // but byte-dense input falls through so we cut on a cluster boundary + "…".
    if (vaxis.gwidth.gwidth(text, .unicode) <= max_cols and text.len <= buf.len) {
        @memcpy(buf[0..text.len], text);
        return buf[0..text.len];
    }
    const ellipsis = "…"; // U+2026: 1 display column, 3 UTF-8 bytes.
    if (buf.len < ellipsis.len) return buf[0..0];
    // Reserve one column for the trailing "…" (max_cols ≥ 1 here).
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

/// Like put, clipped to max_w columns via a 1-row child window.
pub fn putClipped(win: vaxis.Window, row: u16, col: u16, max_w: u16, text: []const u8, sty: vaxis.Style) void {
    if (max_w == 0) return;
    const child = win.child(.{ .x_off = @intCast(col), .y_off = @intCast(row), .width = max_w, .height = 1 });
    _ = child.printSegment(.{ .text = text, .style = sty }, .{});
}

/// Paint a full-width 1-row band in bg (focused-row background shift).
pub fn fillRow(win: vaxis.Window, row: u16, w: u16, bg: vaxis.Color) void {
    const child = win.child(.{ .x_off = 0, .y_off = @intCast(row), .width = w, .height = 1 });
    child.fill(.{ .style = .{ .bg = bg } });
}

/// Centre text on row by display width (gwidth), not bytes (ROD-396 F5).
pub fn centerText(win: vaxis.Window, row: u16, w: u16, text: []const u8, sty: vaxis.Style) void {
    const tw: u16 = @intCast(vaxis.gwidth.gwidth(text, .unicode));
    const col: u16 = if (w > tw) (w - tw) / 2 else 0;
    putClipped(win, row, col, w, text, sty);
}

/// Centered "<key><rest>" with separate styles; width is combined gwidth (ROD-211).
pub fn centerKeyHint(win: vaxis.Window, row: u16, w: u16, key: []const u8, key_sty: vaxis.Style, rest: []const u8, rest_sty: vaxis.Style) void {
    const key_w: u16 = @intCast(vaxis.gwidth.gwidth(key, .unicode));
    const total: u16 = key_w + @as(u16, @intCast(vaxis.gwidth.gwidth(rest, .unicode)));
    const start: u16 = if (w > total) (w - total) / 2 else 0;
    put(win, row, start, key, key_sty);
    putClipped(win, row, start + key_w, w -| (start + key_w), rest, rest_sty);
}

/// One wrapped line: paint slice and byte advance (always ≥ 1 for non-empty input).
const WrapLine = struct { line: []const u8, advance: usize };

/// Greedy wrap into one line ≤ max_w display cols. Space break preferred; no
/// fitting space (CJK) hard-breaks on grapheme boundary, never mid-cluster (ROD-252).
fn nextWrappedLine(text: []const u8, max_w: u16) WrapLine {
    var cols: u16 = 0;
    var consumed: usize = 0; // bytes of whole clusters that fit within max_w cols
    var break_at: usize = 0; // bytes up to and including the last fitting space (0 = none)
    var first_len: usize = 0; // first cluster byte length (forced-progress floor)
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        const cluster = g.bytes(text);
        if (first_len == 0) first_len = cluster.len;
        const gw = vaxis.gwidth.gwidth(cluster, .unicode);
        if (cols + gw > max_w) {
            // Last word break, else last fitting cluster, else first cluster (progress).
            const cut = if (break_at > 0) break_at else if (consumed > 0) consumed else first_len;
            var adv = cut;
            while (adv < text.len and text[adv] == ' ') : (adv += 1) {}
            return .{ .line = std.mem.trim(u8, text[0..cut], " "), .advance = adv };
        }
        cols += gw;
        consumed += cluster.len;
        if (cluster.len == 1 and cluster[0] == ' ') break_at = consumed;
    }
    return .{ .line = std.mem.trim(u8, text, " "), .advance = text.len };
}

pub fn drawWrappedText(win: vaxis.Window, start_row: u16, start_col: u16, max_w: u16, max_rows: u16, text: []const u8, sty: vaxis.Style) u16 {
    if (max_w == 0 or max_rows == 0 or text.len == 0) return 0;

    var row: u16 = 0;
    var i: usize = 0;
    while (i < text.len and row < max_rows) {
        const w = nextWrappedLine(text[i..], max_w);
        putClipped(win, start_row + row, start_col, max_w, w.line, sty);
        row += 1;
        i += w.advance;
    }
    return row;
}

// History-row title column. Episode count lives on the row-2 bar only (ROD-227).
pub const title_col: u16 = 4;

// Always pass explicit bg; default is terminal_ghost, not palette-aware. App uses App.s().
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

test "progressFill: proportional, clamped, and overflow-proof on a hostile progress (ROD-285)" {
    try std.testing.expectEqual(@as(u16, 12), progressFill(6, 12, 24)); // half of 24
    try std.testing.expectEqual(@as(u16, 0), progressFill(0, 12, 24));
    try std.testing.expectEqual(@as(u16, 24), progressFill(12, 12, 24));
    try std.testing.expectEqual(@as(u16, 24), progressFill(99, 12, 24));
    try std.testing.expectEqual(@as(u16, 8), progressFill(3, null, 24));
    try std.testing.expectEqual(@as(u16, 0), progressFill(0, null, 24));
    try std.testing.expectEqual(@as(u16, 8), progressFill(3, 0, 24));
    try std.testing.expectEqual(@as(u16, 0), progressFill(-5, 12, 24));
    // Near-i64-max must not overflow `p * bar_w` (ReleaseSafe panics the render loop).
    try std.testing.expectEqual(@as(u16, 24), progressFill(std.math.maxInt(i64), 12, 24));
    // Corrupt-huge total forces the multiply path; capped operand must not panic.
    _ = progressFill(std.math.maxInt(i64) - 1, std.math.maxInt(i64), 40);
}

test "clampFrac: caps the shown numerator at a real total (ROD-297)" {
    try std.testing.expectEqual(@as(i64, 2), clampFrac(2, 12));
    // Stale high-water above a shrunken total → show total, not "14 / 2".
    try std.testing.expectEqual(@as(i64, 2), clampFrac(14, 2));
    try std.testing.expectEqual(@as(i64, 12), clampFrac(12, 12));
    // AllAnime total=0: pass through (keeps "N / 0", not "0 / 0").
    try std.testing.expectEqual(@as(i64, 5), clampFrac(5, 0));
    try std.testing.expectEqual(@as(i64, 5), clampFrac(5, -3));
    // Negative progress floors to 0 (use-site defense if trust boundary missed it).
    try std.testing.expectEqual(@as(i64, 0), clampFrac(-5, 12));
    try std.testing.expectEqual(@as(i64, 0), clampFrac(-5, 0));
}

test "barFillColor: focus cyan is the cursor, and the cursor overrides status (ROD-194)" {
    const pal = &colors.terminal_ghost;
    // Selected + list-focused owns brightest bar regardless of status (§4.1 / ROD-194).
    try testing.expectEqual(pal.focus, barFillColor(mkRec(.watching), true, true, pal));
    try testing.expectEqual(pal.focus, barFillColor(mkRec(.completed), true, true, pal));
    try testing.expectEqual(pal.focus, barFillColor(mkRec(.planning), true, true, pal));

    try testing.expectEqual(pal.fg2, barFillColor(mkRec(.watching), true, false, pal));
    try testing.expectEqual(pal.fg2, barFillColor(mkRec(.completed), true, false, pal));

    try testing.expectEqual(pal.fg2, barFillColor(mkRec(.watching), false, true, pal));
    try testing.expectEqual(pal.fg2, barFillColor(mkRec(.paused), false, true, pal));

    try testing.expectEqual(pal.chrome, barFillColor(mkRec(.planning), false, true, pal));
    try testing.expectEqual(pal.fg3, barFillColor(mkRec(.completed), false, true, pal));
    try testing.expectEqual(pal.fg3, barFillColor(mkRec(.dropped), false, true, pal));
}

test "truncateToWidth: short copy is passed through verbatim (ROD-166)" {
    var buf: [80]u8 = undefined;
    try testing.expectEqualStrings("network down", truncateToWidth(&buf, "network down", 36));
    // Exactly at budget is not truncation: no ellipsis.
    try testing.expectEqualStrings("123456", truncateToWidth(&buf, "123456", 6));
}

test "truncateToWidth: long copy is cut on a boundary with a trailing … (ROD-166)" {
    var buf: [80]u8 = undefined;
    // 8 ASCII chars, budget 5 → 4 cols of text + "…" = 5 display columns.
    try testing.expectEqualStrings("abcd…", truncateToWidth(&buf, "abcdefgh", 5));
    const out = truncateToWidth(&buf, "abcdefgh", 5);
    try testing.expectEqual(@as(u16, 5), vaxis.gwidth.gwidth(out, .unicode));
}

test "truncateToWidth: never splits a multibyte cluster, counts display width (ROD-166)" {
    var buf: [80]u8 = undefined;
    // CJK glyph = 2 cols / 3 bytes. Budget 5 → two glyphs + "…".
    const out = truncateToWidth(&buf, "東京都市", 5);
    try testing.expectEqualStrings("東京…", out);
    try testing.expectEqual(@as(u16, 5), vaxis.gwidth.gwidth(out, .unicode));
}

test "truncateToWidth: byte-dense but column-narrow input falls off the fast path safely (ROD-166)" {
    // 3 CJK glyphs = 6 cols / 9 bytes into 8-byte buf: fits columns, not bytes.
    // Fast path rejects; cut on cluster boundary with "…" instead of mid-glyph shear.
    var buf: [8]u8 = undefined;
    const out = truncateToWidth(&buf, "東京都", 10);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    try testing.expect(std.mem.endsWith(u8, out, "…"));
}

test "truncateToWidth: a single grapheme wider than the budget yields just … (ROD-166)" {
    var buf: [80]u8 = undefined;
    try testing.expectEqualStrings("…", truncateToWidth(&buf, "東", 1));
    try testing.expectEqualStrings("", truncateToWidth(&buf, "anything", 0));
}

test "centerText: centres by display width, not byte length (ROD-396 F5)" {
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 1, .cols = 10, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 10, .height = 1, .screen = &screen };

    // "評" = 2 cols / 3 bytes. Centre at (10-2)/2 = 4; byte math would land at 3.
    centerText(win, 0, 10, "評", .{});
    try testing.expectEqualStrings("評", win.readCell(4, 0).?.char.grapheme);
}

test "nextWrappedLine: greedy ASCII word-wrap matches the byte-based original (ROD-252)" {
    // Word ending exactly at budget still breaks at prior space.
    const w = nextWrappedLine("the quick brown", 9);
    try testing.expectEqualStrings("the", w.line);
    try testing.expectEqual(@as(usize, 4), w.advance); // "the " incl. break space

    const hard = nextWrappedLine("abcdefgh", 5);
    try testing.expectEqualStrings("abcde", hard.line);
    try testing.expectEqual(@as(usize, 5), hard.advance);

    const whole = nextWrappedLine("hi there", 20);
    try testing.expectEqualStrings("hi there", whole.line);
    try testing.expectEqual(@as(usize, 8), whole.advance);

    const spaced = nextWrappedLine("ab  cd", 3);
    try testing.expectEqualStrings("ab", spaced.line);
    try testing.expectEqual(@as(usize, 4), spaced.advance); // "ab" + both spaces
}

test "nextWrappedLine: CJK breaks on a cluster boundary, never mid-codepoint (ROD-252)" {
    // Byte-cut at max_w would shear a 3-byte cluster. 5-col budget → two 2-col glyphs.
    const w = nextWrappedLine("東京都市", 5);
    try testing.expectEqualStrings("東京", w.line);
    try testing.expectEqual(@as(usize, 6), w.advance);
    try testing.expect(std.unicode.utf8ValidateSlice(w.line));
    try testing.expect(vaxis.gwidth.gwidth(w.line, .unicode) <= 5);

    // Glyph wider than budget still advances (no stall); putClipped clips paint.
    const one = nextWrappedLine("東", 1);
    try testing.expectEqualStrings("東", one.line);
    try testing.expectEqual(@as(usize, 3), one.advance);
    try testing.expect(std.unicode.utf8ValidateSlice(one.line));
}

test "nextWrappedLine: every wrapped line of a CJK-heavy synopsis is valid and in budget (ROD-252)" {
    // End-to-end: each line valid UTF-8, ≤ max_w cols, always progresses.
    const synopsis = "勇者パーティを追放された魔法使い the mage sets out 東の国へ alone";
    const max_w: u16 = 12;
    var i: usize = 0;
    var lines: usize = 0;
    while (i < synopsis.len) {
        const w = nextWrappedLine(synopsis[i..], max_w);
        try testing.expect(w.advance >= 1);
        try testing.expect(std.unicode.utf8ValidateSlice(w.line));
        try testing.expect(vaxis.gwidth.gwidth(w.line, .unicode) <= max_w);
        i += w.advance;
        lines += 1;
        try testing.expect(lines <= synopsis.len);
    }
}

test "barFracColor: text.muted only on the selected, list-focused watching/paused row (ROD-194)" {
    const pal = &colors.terminal_ghost;
    try testing.expectEqual(pal.fg2, barFracColor(mkRec(.watching), true, true, pal));
    try testing.expectEqual(pal.fg2, barFracColor(mkRec(.paused), true, true, pal));

    try testing.expectEqual(pal.fg3, barFracColor(mkRec(.watching), true, false, pal));
    try testing.expectEqual(pal.fg3, barFracColor(mkRec(.completed), true, true, pal));
    try testing.expectEqual(pal.fg3, barFracColor(mkRec(.watching), false, true, pal));
}
