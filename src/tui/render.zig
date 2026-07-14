//! Zigoku — shared TUI render helpers.

const std = @import("std");
const vaxis = @import("vaxis");
const colors = @import("colors.zig");
const store_mod = @import("../store.zig");
const domain = @import("../domain.zig");

const AnimeRecord = store_mod.AnimeRecord;

// ── tiny render helpers ─────────────────────────────────────────────────────

/// §4.5 + ROD-194: the bar fill color. `state.focus` (cyan) means "the focused cursor
/// row" everywhere (▸, title, bar), so it is granted ONLY to the selected row while the
/// list pane holds keyboard focus, and there it OVERRIDES the status color (a selected
/// completed/planning row's bar is cyan too, so the cursor always owns the single
/// brightest bar; the §4.1 repro fix). Off that one row everything steps down:
///   - selected but list unfocused (detail pane active): fg2, all statuses.
///   - unselected watching/paused: fg2 (status can't out-shout the cursor; the ▸/◐ glyph
///     still carries the status identity).
///   - unselected planning: chrome (empty-bar tint, §4.5).
///   - unselected completed/dropped: fg3 (text.dim).
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

/// Ceiling on the `progress` operand of the fill multiply (`p * bar_w`) so it can't
/// overflow i64 on a corrupt/hostile value. `bar_w` is a u16 (≤ 65535), so 1e9 keeps
/// the product ≤ ~6.5e13, far under i64 max, while dwarfing any real episode count
/// (One Piece ~1100). Only reached when `progress < total_episodes`; at/above total the
/// bar is already full. See drawProgressBar and ROD-285's MAX_SANE_PROGRESS.
const PROGRESS_MULT_CEILING: i64 = 1_000_000_000;

/// How many of `bar_w` cells to fill for `progress` of `total_episodes` watched. Pure and
/// overflow-proof so it's testable without a vaxis window and can't panic on a
/// corrupt/hostile `progress` (see PROGRESS_MULT_CEILING). `total_episodes` null or <= 0
/// uses the "unknown length" heuristic (a third-full stub when any progress exists).
fn progressFill(progress: i64, total_episodes: ?i64, bar_w: u16) u16 {
    const total = total_episodes orelse return if (progress > 0) bar_w / 3 else 0;
    if (total <= 0) return if (progress > 0) bar_w / 3 else 0;
    const p = @max(0, progress);
    // Full bar once watched >= the episode count. Deciding this BEFORE the multiply means
    // `p * bw` only runs with p < total, and capping p at PROGRESS_MULT_CEILING keeps that
    // product from overflowing i64 on a corrupt/hostile progress/total (a belt to ROD-285's
    // ingestion clamp: ReleaseSafe turns an overflow here into a render-loop panic, so guard
    // it at the use site too, not only at the trust boundary).
    if (p >= total) return bar_w;
    const bw: i64 = @intCast(bar_w);
    const f = @divTrunc(@min(p, PROGRESS_MULT_CEILING) * bw, total);
    return @intCast(@min(bw, f));
}

/// The numerator for the "N / M eps" fraction: the watch high-water, floored at 0 and
/// clamped so it never exceeds a real (positive) total. A stale high-water above a shrunken
/// total (AniList's planned count overwritten by a smaller aired count once airing, ROD-297)
/// would otherwise render a nonsensical "14 / 2"; since `progressFill` already paints a full
/// bar once progress >= total, the clamped "2 / 2" matches what the user sees. Display heal
/// only; separating planned vs aired in the data model is the structural follow-up. The
/// `@max(0, …)` floor mirrors `progressFill`'s use-site defense (see PROGRESS_MULT_CEILING).
/// A non-positive total (the AllAnime `total_episodes = 0` quirk) has no denominator to
/// clamp against, so the floored progress passes through, preserving the "N / 0" display.
fn clampFrac(progress: i64, total: i64) i64 {
    const p = @max(0, progress);
    if (total <= 0) return p;
    return @min(p, total);
}

/// §4.5 progress bar for a history row. `row_bg` is the row background (bg.surface for the
/// focused entry while the list has focus, bg.base otherwise). `frac_buf` must be App-owned
/// (vaxis holds a reference until the next render). `avail` is the total columns for the
/// whole "[bar]  N / M eps" element from `col` (caller-computed against the list's right
/// edge), and the frac is clipped to it so it can't bleed into a neighbour.
/// `selected`/`list_focused` gate the §4.1 selection affordance into the fill (ROD-194).
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
    // Clip the frac to whatever the bar row budget leaves after the bracketed bar,
    // so a narrow two-pane list never bleeds "N / M eps" into the detail pane
    // (ROD-170). `avail` is the cols from `col` to the list's right edge.
    const frac_col = col + 1 + bar_w + 1;
    const frac_max = avail -| (1 + bar_w + 1);
    putClipped(win, row, frac_col, frac_max, frac, style(frac_color, .{ .bg = row_bg }));
}

/// Truncate `text` to at most `max_cols` display columns, copying into `buf` and appending
/// a single-column "…" only when truncation actually happened (ROD-166, §4.7). Cuts on
/// grapheme-cluster boundaries (never splits a multibyte cluster) and measures real display
/// width (gwidth), so a wide CJK glyph counts as its 2 columns. Unlike `putClipped` (which
/// clips silently), this leaves a "…" affordance so the user knows the copy was cut. Returns
/// the slice of `buf` written. The copy stops early if the next cluster + "…" would overflow
/// `buf`, so a [80]u8 caller can never overrun regardless of input density.
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

/// Horizontally centre a string on `row` by display width (gwidth), so a
/// multibyte spinner/ellipsis or a CJK title counts the cells it paints, not its
/// bytes. Byte length would over-count and shove the text left of centre (ROD-396
/// F5); for a pure-ASCII copy gwidth == byte length, so those callers are unchanged.
pub fn centerText(win: vaxis.Window, row: u16, w: u16, text: []const u8, sty: vaxis.Style) void {
    const tw: u16 = @intCast(vaxis.gwidth.gwidth(text, .unicode));
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

/// One wrapped line: the space-trimmed slice to paint and how many bytes of
/// `text` it consumes (the line plus any trailing break space skipped). `advance`
/// is always ≥ 1 for non-empty input, so a caller loop can never stall.
const WrapLine = struct { line: []const u8, advance: usize };

/// Greedy word-wrap of the front of `text` into one line ≤ `max_w` display
/// columns. Breaks at the last space that fits; a run with no fitting space
/// (CJK synopses have none) hard-breaks on a grapheme-cluster boundary measured
/// in columns, never at a raw byte offset. A byte cut at `max_w` shears a
/// multibyte cluster mid-sequence and mojibakes the next line (ROD-252). Callers
/// pass `max_w > 0` and `text.len > 0`.
fn nextWrappedLine(text: []const u8, max_w: u16) WrapLine {
    var cols: u16 = 0;
    var consumed: usize = 0; // bytes of whole clusters that fit within max_w cols
    var break_at: usize = 0; // bytes up to and including the last fitting space (0 = none)
    var first_len: usize = 0; // first cluster's byte length, the forced-progress floor
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        const cluster = g.bytes(text);
        if (first_len == 0) first_len = cluster.len;
        const gw = vaxis.gwidth.gwidth(cluster, .unicode);
        if (cols + gw > max_w) {
            // Prefer the last word break; else hard-cut at the last cluster that
            // fit; else (not even one fits) take the first cluster so we progress.
            const cut = if (break_at > 0) break_at else if (consumed > 0) consumed else first_len;
            var adv = cut;
            while (adv < text.len and text[adv] == ' ') : (adv += 1) {}
            return .{ .line = std.mem.trim(u8, text[0..cut], " "), .advance = adv };
        }
        cols += gw;
        consumed += cluster.len;
        if (cluster.len == 1 and cluster[0] == ' ') break_at = consumed;
    }
    // Whole remainder fits on this line.
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

test "progressFill: proportional, clamped, and overflow-proof on a hostile progress (ROD-285)" {
    // Normal proportional fill.
    try std.testing.expectEqual(@as(u16, 12), progressFill(6, 12, 24)); // half of 24
    try std.testing.expectEqual(@as(u16, 0), progressFill(0, 12, 24));
    // At/over the episode count → full bar (never over-fills).
    try std.testing.expectEqual(@as(u16, 24), progressFill(12, 12, 24));
    try std.testing.expectEqual(@as(u16, 24), progressFill(99, 12, 24));
    // Unknown/zero total → the third-full "some progress" stub.
    try std.testing.expectEqual(@as(u16, 8), progressFill(3, null, 24));
    try std.testing.expectEqual(@as(u16, 0), progressFill(0, null, 24));
    try std.testing.expectEqual(@as(u16, 8), progressFill(3, 0, 24));
    // Negative progress floors to empty, not a wrap.
    try std.testing.expectEqual(@as(u16, 0), progressFill(-5, 12, 24));
    // The overflow vector review flagged (ROD-285): a near-i64-max progress must NOT
    // overflow `p * bar_w` (ReleaseSafe would panic the render loop) — it saturates.
    try std.testing.expectEqual(@as(u16, 24), progressFill(std.math.maxInt(i64), 12, 24));
    // And even with a corrupt-huge total (so p < total, forcing the multiply path),
    // the capped operand keeps the product from overflowing.
    _ = progressFill(std.math.maxInt(i64) - 1, std.math.maxInt(i64), 40); // must not panic
}

test "clampFrac: caps the shown numerator at a real total (ROD-297)" {
    // Progress within the total is shown verbatim.
    try std.testing.expectEqual(@as(i64, 2), clampFrac(2, 12));
    // The bug: a stale high-water above a shrunken total renders as the total,
    // never "14 / 2" — the planned count was overwritten by the smaller aired count.
    try std.testing.expectEqual(@as(i64, 2), clampFrac(14, 2));
    // Exactly caught up passes through unchanged.
    try std.testing.expectEqual(@as(i64, 12), clampFrac(12, 12));
    // AllAnime `total_episodes = 0` quirk: no real denominator, so a positive
    // progress passes through (keeps the pre-existing "N / 0" display, not "0 / 0").
    try std.testing.expectEqual(@as(i64, 5), clampFrac(5, 0));
    // A negative total is treated the same as the 0 quirk.
    try std.testing.expectEqual(@as(i64, 5), clampFrac(5, -3));
    // Negative progress floors to empty, mirroring progressFill's use-site defense
    // against a trust-boundary-crossed value — never "-5 / 12" or a negative in
    // the 0-quirk branch.
    try std.testing.expectEqual(@as(i64, 0), clampFrac(-5, 12));
    try std.testing.expectEqual(@as(i64, 0), clampFrac(-5, 0));
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
    // with "…" instead of shearing a 3-byte glyph mid-sequence.
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

test "centerText: centres by display width, not byte length (ROD-396 F5)" {
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 1, .cols = 10, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 10, .height = 1, .screen = &screen };

    // "評" is one cluster: 2 display columns but 3 bytes. In a width-10 row it must
    // centre at (10-2)/2 = 4. The byte-based math would use (10-3)/2 = 3 and shove
    // it a column left, so the primary cell landing at 4 is what discriminates the fix.
    centerText(win, 0, 10, "評", .{});
    try testing.expectEqualStrings("評", win.readCell(4, 0).?.char.grapheme);
}

test "nextWrappedLine: greedy ASCII word-wrap matches the byte-based original (ROD-252)" {
    // A word that ends exactly at the budget still breaks at the prior space: the
    // trailing space is what overflows, so "the quick" (9 cols) yields "the" then
    // re-wraps "quick brown". Pinned so the grapheme rewrite kept the old wrap points.
    const w = nextWrappedLine("the quick brown", 9);
    try testing.expectEqualStrings("the", w.line);
    try testing.expectEqual(@as(usize, 4), w.advance); // consumes "the " incl. the break space

    // A run with no fitting space hard-breaks at the column budget.
    const hard = nextWrappedLine("abcdefgh", 5);
    try testing.expectEqualStrings("abcde", hard.line);
    try testing.expectEqual(@as(usize, 5), hard.advance);

    // Whole remainder fits → one line, consume everything.
    const whole = nextWrappedLine("hi there", 20);
    try testing.expectEqualStrings("hi there", whole.line);
    try testing.expectEqual(@as(usize, 8), whole.advance);

    // Extra spaces at the break are all skipped, not re-emitted as a blank cluster.
    const spaced = nextWrappedLine("ab  cd", 3);
    try testing.expectEqualStrings("ab", spaced.line);
    try testing.expectEqual(@as(usize, 4), spaced.advance); // "ab" + both spaces
}

test "nextWrappedLine: CJK breaks on a cluster boundary, never mid-codepoint (ROD-252)" {
    // The bug: byte-cutting at max_w slices a 3-byte cluster mid-sequence. A 5-col
    // budget fits two 2-col glyphs (4 cols); the third would overflow, so the line
    // ends at the boundary between 京 and 都: valid UTF-8, within budget.
    const w = nextWrappedLine("東京都市", 5);
    try testing.expectEqualStrings("東京", w.line);
    try testing.expectEqual(@as(usize, 6), w.advance); // two 3-byte clusters
    try testing.expect(std.unicode.utf8ValidateSlice(w.line));
    try testing.expect(vaxis.gwidth.gwidth(w.line, .unicode) <= 5);

    // A single glyph wider than the whole budget still advances (no stall) and
    // stays a valid, un-sheared cluster; putClipped clips the paint to the column.
    const one = nextWrappedLine("東", 1);
    try testing.expectEqualStrings("東", one.line);
    try testing.expectEqual(@as(usize, 3), one.advance);
    try testing.expect(std.unicode.utf8ValidateSlice(one.line));
}

test "nextWrappedLine: every wrapped line of a CJK-heavy synopsis is valid and in budget (ROD-252)" {
    // Walk a mixed ASCII/CJK synopsis end to end the way drawWrappedText does and
    // assert the invariants the byte-cut violated: each line is valid UTF-8, never
    // exceeds the column budget, and the loop always makes progress.
    const synopsis = "勇者パーティを追放された魔法使い the mage sets out 東の国へ alone";
    const max_w: u16 = 12;
    var i: usize = 0;
    var lines: usize = 0;
    while (i < synopsis.len) {
        const w = nextWrappedLine(synopsis[i..], max_w);
        try testing.expect(w.advance >= 1); // progress guaranteed
        try testing.expect(std.unicode.utf8ValidateSlice(w.line));
        try testing.expect(vaxis.gwidth.gwidth(w.line, .unicode) <= max_w);
        i += w.advance;
        lines += 1;
        try testing.expect(lines <= synopsis.len); // loop can't run away
    }
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
