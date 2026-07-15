//! Browse view list render (search results). Extracted from app.zig (ROD-144).

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

// `*const App`: reads list state; writes only `scratch` (ROD-155).
pub fn drawBrowseList(self: *const App, scratch: *RenderScratch, win: vaxis.Window, pane_h: u16, pane_w: u16) void {
    const w = pane_w;
    if (self.search.len == 0) {
        // First-run absent (§9.5 / ROD-211): search-first, never auto-fills; teach / and P.
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
        // Centered like absent state; bottom-bar keeps the query (chrome.zig).
        const q = self.search.querySlice();
        const mid = pane_h / 2;
        const msg = std.fmt.bufPrint(&scratch.msg, "no results for \"{s}\"", .{q}) catch "no results";
        centerText(win, mid -| 1, w, msg, self.s(self.palette.fg2, .{ .italic = true }));
        centerText(win, mid + 1, w, "try a different spelling", self.s(self.palette.fg3, .{ .italic = true }));
        return;
    }

    // Viewport settled by app.layout() before draw (ROD-155).
    const list_title_col: u16 = 2; // marker col 0-1

    var row: u16 = 0;
    var slot: usize = 0;
    var i: usize = self.list_top;
    while (i < self.search.results.items.len and row < pane_h) : (i += 1) {
        const a = self.search.results.items[i];
        const selected = i == self.list_cursor;

        // ROD-194: band + cyan-bold only when list pane focused; detail focus steps row down.
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

        // Meta zone (§4.1/§4.3, ROD-226): glyph + title + score [NN] right-anchored.
        // Pane-relative (split list ~38%). Priority on tight width: title > score > eps.
        // Score persists to min_title; eps only when title clears comfort_title.
        // Fixed score/eps left edges so title width does not jitter row-to-row.
        const score_w: u16 = 5; // "[100]"
        const eps_w: u16 = 9; // "1000 sub" worst case
        const meta_gap: u16 = 2;
        const min_title: u16 = 12;
        const comfort_title: u16 = 28;
        const score_zone: u16 = w -| score_w;
        const show_score = score_zone >= list_title_col + min_title + meta_gap;
        const eps_zone: u16 = score_zone -| meta_gap -| eps_w;
        const show_eps = show_score and eps_zone >= list_title_col + comfort_title + meta_gap;
        // Gap so title tail cannot bleed under meta (later write wins).
        const title_right: u16 = if (show_eps) eps_zone else if (show_score) score_zone else w;
        const title_w: u16 = if (show_score or show_eps)
            title_right -| list_title_col -| meta_gap
        else if (w > list_title_col) w - list_title_col else 0;
        // ROD-205: borrow of a title field; same lifetime as `a.name`.
        putClipped(win, row, list_title_col, title_w, a.displayTitle(self.config.titleLanguageEnum()), title_style);

        if (show_score and slot < scratch.score.len) {
            // Null score → "[--]"; tier via App.scoreStyle (shared with detail).
            const score_str: []const u8 = if (a.score) |sc|
                std.fmt.bufPrint(&scratch.score[slot], "[{d}]", .{sc}) catch "[--]"
            else
                "[--]";
            const score_at: u16 = w -| @as(u16, @intCast(score_str.len));
            put(win, row, score_at, score_str, self.scoreStyle(a.score, row_bg));

            // Right-align within eps field (ROD-226). Track-agnostic total when
            // per-track is 0 (senshi-style / AniList hits); never show false "0 dub".
            if (show_eps and slot < scratch.meta.len) {
                const tt = self.translation;
                const per_track = if (tt == .dub) a.eps_dub else a.eps_sub;
                const meta = if (per_track > 0)
                    std.fmt.bufPrint(&scratch.meta[slot], "{d} {s}", .{ per_track, tt.str() }) catch ""
                else if (a.total_episodes) |t|
                    std.fmt.bufPrint(&scratch.meta[slot], "{d} ep", .{t}) catch ""
                else
                    "[--]";
                const eps_len: u16 = @min(@as(u16, @intCast(meta.len)), eps_w);
                const eps_at: u16 = eps_zone + (eps_w - eps_len);
                putClipped(win, row, eps_at, eps_len, meta, self.s(self.palette.fg3, .{ .bg = row_bg }));
            }
            slot += 1;
        }
        row += 1;
    }

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
    app.search.len = 1;

    const scratch = try t.allocator.create(RenderScratch);
    defer t.allocator.destroy(scratch);

    var screen = try vaxis.Screen.init(t.allocator, .{ .rows = 12, .cols = 60, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(t.allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 12, .screen = &screen };

    app.config.title_language = "romaji";
    drawBrowseList(&app, scratch, win, 12, 60);
    try t.expectEqualStrings("S", win.readCell(2, 0).?.char.grapheme);

    app.config.title_language = "english";
    drawBrowseList(&app, scratch, win, 12, 60);
    try t.expectEqualStrings("F", win.readCell(2, 0).?.char.grapheme);
}

test "drawBrowseList shows the track-agnostic total for a zero-per-track AniList hit (ROD-327)" {
    const t = std.testing;
    var app: App = .{};
    app.gpa = t.allocator;
    defer app.search.results.deinit(t.allocator);
    // AniList hit: no per-track counts, populated total; never false "0 sub".
    try app.search.results.append(t.allocator, .{
        .id = "182255",
        .name = "Sousou no Frieren",
        .anilist_id = 182255,
        .eps_sub = 0,
        .eps_dub = 0,
        .total_episodes = 28,
    });
    app.search.len = 1;
    app.translation = .sub;
    app.config.title_language = "romaji";

    const scratch = try t.allocator.create(RenderScratch);
    defer t.allocator.destroy(scratch);
    var screen = try vaxis.Screen.init(t.allocator, .{ .rows = 12, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(t.allocator);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 80, .height = 12, .screen = &screen };

    drawBrowseList(&app, scratch, win, 12, 80);

    var buf: [80]u8 = undefined;
    var n: usize = 0;
    var col: u16 = 0;
    while (col < 80) : (col += 1) {
        const cell = win.readCell(col, 0) orelse continue;
        const g = cell.char.grapheme;
        if (g.len == 1 and n < buf.len) {
            buf[n] = g[0];
            n += 1;
        }
    }
    const row0 = buf[0..n];
    try t.expect(std.mem.indexOf(u8, row0, "28 ep") != null);
    try t.expect(std.mem.indexOf(u8, row0, "0 sub") == null);
}
