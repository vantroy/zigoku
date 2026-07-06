//! Zigoku — Browse view list render pass (search results).
//! Extracted from app.zig along the tick/draw seam (ROD-144).

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const render = @import("../render.zig");
const source_mod = @import("../../source.zig");

const App = app_mod.App;
const RenderScratch = app_mod.RenderScratch;
const put = render.put;
const putClipped = render.putClipped;
const fillRow = render.fillRow;
const centerText = render.centerText;
const centerKeyHint = render.centerKeyHint;

// `self` is `*const App`: this pass reads list state (cursor/viewport/results)
// and writes only `scratch` — the compiler proves it mutates no app state (ROD-155).
pub fn drawBrowseList(self: *const App, scratch: *RenderScratch, win: vaxis.Window, pane_h: u16, pane_w: u16) void {
    const w = pane_w;
    if (self.search.len == 0) {
        // First-run absent state (§9.5): name the view, then teach its two
        // actions. Browse is search-first and never auto-fills, so "no feed yet"
        // read as broken/waiting — this says what to do instead (ROD-211).
        const mid = pane_h / 2;
        centerText(win, mid -| 2, w, "search the catalogue", self.s(self.palette.fg2, .{ .italic = true }));
        centerKeyHint(win, mid, w, "/", self.s(self.palette.focus, .{ .bold = true }), "  type a show name to begin", self.s(self.palette.fg2, .{}));
        centerKeyHint(win, mid + 2, w, "P", self.s(self.palette.focus, .{ .bold = true }), "  save a result to your watchlist", self.s(self.palette.fg3, .{}));
        return;
    }
    const search_pending = self.search.loading or self.debounce_deadline_ms > 0;
    if (search_pending and self.search.results.items.len == 0) {
        const spin_msg = std.fmt.bufPrint(&scratch.msg, "{s} searching\u{2026}", .{self.spinnerChar()}) catch "⠋ searching\u{2026}";
        centerText(win, pane_h / 2, w, spin_msg, self.s(self.palette.focus, .{}));
        return;
    }
    if (!search_pending and self.search.results.items.len == 0) {
        // Centered to match the §9.5 absent state (ROD-211), not stranded
        // top-left. The bottom-bar search prompt stays visible (chrome.zig), so
        // the user keeps their query and the next-step hint sits under it.
        const q = self.search.querySlice();
        const mid = pane_h / 2;
        const msg = std.fmt.bufPrint(&scratch.msg, "no results for \"{s}\"", .{q}) catch "no results";
        centerText(win, mid -| 1, w, msg, self.s(self.palette.fg2, .{ .italic = true }));
        centerText(win, mid + 1, w, "try a different spelling", self.s(self.palette.fg3, .{ .italic = true }));
        return;
    }

    // Results list — col offsets relative to list_win (no x=2 leading margin).
    // The viewport (list_top) is settled by app.layout() before this draw pass
    // (ROD-155); here we only read it.
    const list_title_col: u16 = 2; // marker is col 0–1, title starts at 2

    var row: u16 = 0;
    var slot: usize = 0;
    var i: usize = self.list_top;
    while (i < self.search.results.items.len and row < pane_h) : (i += 1) {
        const a = self.search.results.items[i];
        const selected = i == self.list_cursor;

        // ROD-194: the selection affordance (band + cyan-bold ▸/title) is earned only
        // when the list pane holds focus. With the detail pane focused the selected row
        // steps down — band drops, ▸ dims, title loses bold — mirroring History so the
        // active pane is unmistakable.
        const list_focused = self.active_pane == .list;
        const sel_focused = selected and list_focused;
        const row_bg = if (sel_focused) self.palette.bg_surface else self.palette.bg_base;
        if (sel_focused) fillRow(win, row, w, self.palette.bg_surface);

        const marker = if (selected) "▸ " else "  ";
        put(win, row, 0, marker, self.s(self.palette.focus, .{ .bg = row_bg, .dim = selected and !list_focused }));

        const title_style = if (selected)
            self.s(self.palette.focus, .{ .bg = row_bg, .bold = list_focused })
        else
            self.s(self.palette.fg, .{ .bg = row_bg });
        // ── Meta zone: AniList score (right) + episode count (left) ──────────
        // §4.1/§4.3: the row is glyph + title + score, the score taking the
        // rightmost `score_w` cols, right-anchored and §2.2 tier-coloured. All
        // columns are PANE-RELATIVE: the dominant Browse layout is the split list
        // pane (~38% of the terminal, `PaneSplit.list_w`), so a fixed meta column
        // would fall outside it.
        //
        // Priority on a tight pane is title > score > eps. The title is the primary
        // identifier, so it falls off last; the eps count is the first meta to drop
        // (it gets two floors below). The score is a tiny, high-value badge worth
        // clipping a long title slightly for, so it persists down to a small title
        // floor (`min_title`). The eps count, by contrast, only appears once the
        // title still clears a *comfortable* width (`comfort_title`) — so it drops
        // before the title gets squeezed, never the other way round (ROD-226).
        //
        // Compact list form `[NN]` (no `/100`): the denominator is redundant in a
        // tight row — the tier colour already reads it as a score. The detail pane
        // keeps the full §4.3 `[NN/100]`, where the line has room.
        const score_w: u16 = 5; // "[100]" = 5 chars
        const eps_w: u16 = 9; // "1000 sub" worst case + slack
        const meta_gap: u16 = 2; // keeps the title/eps/score fields from touching
        const min_title: u16 = 12; // score may clip the title down to this (it's tiny + high-value)
        const comfort_title: u16 = 28; // eps appears only while the title still clears this
        // Fixed left edges of the score / eps fields (independent of the per-row
        // score-string length, so the title width never jitters between rows).
        const score_zone: u16 = w -| score_w;
        const show_score = score_zone >= list_title_col + min_title + meta_gap;
        const eps_zone: u16 = score_zone -| meta_gap -| eps_w;
        const show_eps = show_score and eps_zone >= list_title_col + comfort_title + meta_gap;
        // Title clips before the leftmost meta field it has to make room for. The
        // gap prevents the last title char from touching the meta (vaxis writes
        // cells; the later write wins, so without it the title tail bleeds through).
        const title_right: u16 = if (show_eps) eps_zone else if (show_score) score_zone else w;
        const title_w: u16 = if (show_score or show_eps)
            title_right -| list_title_col -| meta_gap
        else if (w > list_title_col) w - list_title_col else 0;
        // Primary label under the title-language preference (ROD-205); the resolver
        // returns a borrow of one of `a`'s title fields, same lifetime as `a.name`.
        putClipped(win, row, list_title_col, title_w, a.displayTitle(self.config.titleLanguageEnum()), title_style);

        if (show_score and slot < scratch.score.len) {
            // Score, right-anchored against the pane edge. A null score (unenriched
            // / no AniList hit) degrades to a static "[--]" — no buffer needed; the
            // tier colour comes from the shared App.scoreStyle so the detail pane
            // and this row can never drift.
            const score_str: []const u8 = if (a.score) |sc|
                std.fmt.bufPrint(&scratch.score[slot], "[{d}]", .{sc}) catch "[--]"
            else
                "[--]";
            const score_at: u16 = w -| @as(u16, @intCast(score_str.len));
            put(win, row, score_at, score_str, self.scoreStyle(a.score, row_bg));

            // Episode count, right-aligned within its field so it clusters against
            // the score instead of leaving a loose gap before it (ROD-226).
            // Only rendered when the pane seats it (the `show_eps` floor).
            if (show_eps and slot < scratch.meta.len) {
                const tt = self.translation;
                const eps = if (tt == .dub) a.eps_dub else a.eps_sub;
                const meta = std.fmt.bufPrint(&scratch.meta[slot], "{d} {s}", .{ eps, tt.str() }) catch "";
                const eps_len: u16 = @min(@as(u16, @intCast(meta.len)), eps_w);
                const eps_at: u16 = eps_zone + (eps_w - eps_len); // right-align within [eps_zone, eps_zone+eps_w)
                putClipped(win, row, eps_at, eps_len, meta, self.s(self.palette.fg3, .{ .bg = row_bg }));
            }
            slot += 1;
        }
        row += 1;
    }

    // Load-more footer.
    if (row < pane_h and
        self.search.page > 0 and
        self.search.results.items.len % source_mod.search_page_size == 0 and
        self.search.results.items.len > 0)
    {
        const footer = if (self.search.loading) "⠋ loading…" else "╌ more ╌";
        const footer_color = if (self.search.loading) self.palette.focus else self.palette.fg3;
        centerText(win, row, w, footer, self.s(footer_color, .{}));
    }
}

test "drawBrowseList renders the primary title under title_language (ROD-205)" {
    const t = std.testing;
    var app: App = .{};
    app.gpa = t.allocator;
    defer app.search.results.deinit(t.allocator);
    try app.search.results.append(t.allocator, .{
        .id = "fr",
        .name = "Sousou no Frieren",
        .english_name = "Frieren: Beyond Journey's End",
        .native_name = "葬送のフリーレン",
    });
    app.search.len = 1; // nonzero query length → skip the first-run absent state

    const scratch = try t.allocator.create(RenderScratch);
    defer t.allocator.destroy(scratch);

    var screen = try vaxis.Screen.init(t.allocator, .{ .rows = 12, .cols = 60, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(t.allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 12, .screen = &screen };

    // First result row is row 0; the title starts at list_title_col (col 2).
    app.config.title_language = "romaji";
    drawBrowseList(&app, scratch, win, 12, 60);
    try t.expectEqualStrings("S", win.readCell(2, 0).?.char.grapheme); // "Sousou no Frieren"

    app.config.title_language = "english";
    drawBrowseList(&app, scratch, win, 12, 60);
    try t.expectEqualStrings("F", win.readCell(2, 0).?.char.grapheme); // "Frieren: Beyond…"
}
