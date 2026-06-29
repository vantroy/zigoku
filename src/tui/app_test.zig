//! Zigoku — extracted app state-machine tests.

const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("app.zig");
const event_mod = @import("event.zig");
const workers = @import("workers.zig");
const store_mod = @import("../store.zig");
const source_mod = @import("../source.zig");
const domain = @import("../domain.zig");
const cover_mod = @import("../cover.zig");
const colors = @import("colors.zig");
const detail_view = @import("view/detail.zig");
const history_view = @import("view/history.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const AnimeRecord = store_mod.AnimeRecord;
const SourceProvider = source_mod.SourceProvider;
const Anime = domain.Anime;
const App = app_mod.App;
const SearchController = app_mod.SearchController;
const Toast = app_mod.Toast;
const CoverState = app_mod.CoverState;
const CoverDecision = app_mod.CoverState.Decision;
const Event = event_mod.Event;
const Loop = event_mod.Loop;
const RawCoverCache = workers.RawCoverCache;
const DecodedCoverCache = workers.DecodedCoverCache;
const max_cover_raw_cache_bytes = workers.max_cover_raw_cache_bytes;
const max_cover_decoded_cache_bytes = workers.max_cover_decoded_cache_bytes;
const freeOwnedAnime = workers.freeOwnedAnime;
const coverTask = workers.coverTask;

fn keyEv(cp: u21, mods: vaxis.Key.Modifiers) Event {
    return .{ .key_press = .{ .codepoint = cp, .mods = mods } };
}

fn sampleHistory() [3]AnimeRecord {
    return .{
        .{ .source = "allanime", .source_id = "a", .title = "Frieren", .total_episodes = 28, .progress = 4 },
        .{ .source = "allanime", .source_id = "b", .title = "K-On!", .total_episodes = 13, .progress = 1 },
        .{ .source = "allanime", .source_id = "c", .title = "Bebop", .progress = 0 },
    };
}

fn dummySearchFn(_: *anyopaque, _: Allocator, _: std.Io, _: []const u8, _: source_mod.SearchOptions) anyerror![]Anime {
    return &.{};
}
fn dummyEpisodesFn(_: *anyopaque, _: Allocator, _: std.Io, _: []const u8, _: domain.Translation) anyerror![]domain.EpisodeNumber {
    return &.{};
}
fn dummyResolveFn(_: *anyopaque, _: Allocator, _: std.Io, _: []const u8, _: domain.EpisodeNumber, _: domain.Translation, _: domain.Quality) anyerror!domain.StreamLink {
    return .{ .url = "" };
}

fn dummyNameFn(_: *anyopaque) []const u8 {
    return "allanime";
}

/// A display name distinct from the persistence key, so the toast-copy tests
/// prove the source name is read from the provider seam (provider.displayName())
/// rather than hardcoded anywhere upstream.
fn dummyDisplayNameFn(_: *anyopaque) []const u8 {
    return "TestSrc";
}

fn dummyPopularFn(_: *anyopaque, _: Allocator, _: std.Io, _: source_mod.PopularOptions) anyerror![]Anime {
    return &.{};
}

const dummy_vtable: SourceProvider.VTable = .{
    .name = dummyNameFn,
    .displayName = dummyDisplayNameFn,
    .search = dummySearchFn,
    .popular = dummyPopularFn,
    .episodes = dummyEpisodesFn,
    .resolve = dummyResolveFn,
};

fn dummyProvider() SourceProvider {
    return .{ .ptr = undefined, .vtable = &dummy_vtable };
}

/// A provider whose `episodes` fetch parks until the test releases it — a
/// deterministic stand-in for a slow in-flight network fetch (ROD-179). Per
/// instance state rides on the vtable's `*anyopaque` self.
const GateProvider = struct {
    release: std.atomic.Value(bool) = .init(false),

    fn episodesFn(ptr: *anyopaque, arena: Allocator, _: std.Io, _: []const u8, _: domain.Translation) anyerror![]domain.EpisodeNumber {
        const self: *GateProvider = @ptrCast(@alignCast(ptr));
        // yield() keeps the park from starving the test thread on a single core.
        while (!self.release.load(.acquire)) std.Thread.yield() catch {};
        const eps = try arena.alloc(domain.EpisodeNumber, 1);
        eps[0] = .{ .raw = "1" };
        return eps;
    }
    fn nameFn(_: *anyopaque) []const u8 {
        return "allanime";
    }
    fn displayNameFn(_: *anyopaque) []const u8 {
        return "TestSrc";
    }
    fn searchFn(_: *anyopaque, _: Allocator, _: std.Io, _: []const u8, _: source_mod.SearchOptions) anyerror![]Anime {
        return &.{};
    }
    fn popularFn(_: *anyopaque, _: Allocator, _: std.Io, _: source_mod.PopularOptions) anyerror![]Anime {
        return &.{};
    }
    fn resolveFn(_: *anyopaque, _: Allocator, _: std.Io, _: []const u8, _: domain.EpisodeNumber, _: domain.Translation, _: domain.Quality) anyerror!domain.StreamLink {
        return .{ .url = "" };
    }

    const vtable: SourceProvider.VTable = .{
        .name = nameFn,
        .displayName = displayNameFn,
        .search = searchFn,
        .popular = popularFn,
        .episodes = episodesFn,
        .resolve = resolveFn,
    };

    fn provider(self: *GateProvider) SourceProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

fn initTestLoop() Loop {
    const io = std.testing.io;
    return .{
        .io = io,
        .tty = undefined,
        .vaxis = undefined,
        .queue = .{ .io = io },
    };
}

fn testTick(app: *App, event: Event) !void {
    // Use a properly initialized loop so that background threads spawned during
    // tick() can safely call loop.postEvent() (which locks a mutex via io).
    // tty and vaxis are never accessed by postEvent, so undefined is safe there.
    const io = std.testing.io;
    var loop = initTestLoop();
    try app.tick(event, &loop, io, dummyProvider());
    // Join any threads spawned during tick so they finish using &loop before the
    // stack frame tears down. Without this the thread dereferences a dangling
    // loop pointer in the next test and triggers an ABRT.
    app.episode_drain.drain(); // episode workers detach now (ROD-179); wait them out
    if (app.search_thread) |t| {
        t.join();
        app.search_thread = null;
    }
    if (app.popular_thread) |t| {
        t.join();
        app.popular_thread = null;
    }
    if (app.enrich_thread) |t| {
        t.join();
        app.enrich_thread = null;
    }
    if (app.play_thread) |t| {
        t.join();
        app.play_thread = null;
    }
    // Drain events the threads may have posted; free their owned payloads so the
    // test allocator doesn't report leaks.
    while (loop.queue.tryPop() catch null) |ev| freeTestEvent(app.gpa, ev);
}

fn freeTestEvent(alloc: Allocator, ev: Event) void {
    switch (ev) {
        .episodes_done => |d| {
            for (d.episodes) |ep| alloc.free(ep.raw);
            alloc.free(d.episodes);
            alloc.free(d.for_id);
        },
        .search_done => |d| {
            for (d.results) |r| freeOwnedAnime(alloc, r);
            alloc.free(d.results);
            alloc.free(d.for_query);
        },
        .search_enriched => |d| {
            for (d.results) |r| freeOwnedAnime(alloc, r);
            alloc.free(d.results);
            alloc.free(d.for_query);
        },
        .popular_done => |d| {
            for (d.results) |r| freeOwnedAnime(alloc, r);
            alloc.free(d.results);
        },
        .cover_done => |d| {
            alloc.free(d.rgba);
            alloc.free(d.for_id);
        },
        .cover_error => |id| alloc.free(id),
        .episodes_error => |e| alloc.free(e.for_id),
        // task_error and most other events carry no owned heap payloads.
        else => {},
    }
}

const tiny_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x04, 0x00, 0x00, 0x00, 0xb5, 0x1c, 0x0c,
    0x02, 0x00, 0x00, 0x00, 0x0b, 0x49, 0x44, 0x41,
    0x54, 0x78, 0xda, 0x63, 0xfc, 0xff, 0x1f, 0x00,
    0x03, 0x03, 0x02, 0x00, 0xef, 0x9a, 0xf6, 0x64,
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44,
    0xae, 0x42, 0x60, 0x82,
};

test "history_loaded drains into state and clears loading" {
    var app: App = .{};
    try testing.expect(app.history_loading);
    var recs = sampleHistory();
    try testTick(&app, .{ .history_loaded = &recs });
    try testing.expect(!app.history_loading);
    try testing.expectEqual(@as(usize, 3), app.history.len);
}

test "j/k navigation stays in bounds" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    try testing.expectEqual(@as(usize, 0), app.list_cursor);

    try testTick(&app, keyEv('k', .{})); // up at top — pinned
    try testing.expectEqual(@as(usize, 0), app.list_cursor);

    try testTick(&app, keyEv('j', .{}));
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 2), app.list_cursor);

    try testTick(&app, keyEv('j', .{})); // down at bottom — pinned
    try testing.expectEqual(@as(usize, 2), app.list_cursor);

    try testTick(&app, keyEv('k', .{}));
    try testing.expectEqual(@as(usize, 1), app.list_cursor);
}

test "g/G jump to ends" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    try testTick(&app, keyEv('G', .{}));
    try testing.expectEqual(@as(usize, 2), app.list_cursor);
    try testTick(&app, keyEv('g', .{}));
    try testing.expectEqual(@as(usize, 0), app.list_cursor);
}

test "quit keys: q from browse and Ctrl-C" {
    // q from browse quits.
    var app: App = .{};
    app.active_view = .browse;
    try testing.expect(!app.should_quit);
    try testTick(&app, keyEv('q', .{}));
    try testing.expect(app.should_quit);

    // Ctrl-C always quits.
    app = .{};
    try testing.expect(!app.should_quit);
    try testTick(&app, keyEv('c', .{ .ctrl = true }));
    try testing.expect(app.should_quit);
}

test "scope-tagged count fits cnt_scratch (ROD-211)" {
    // Guards the [16]->[32] bump: the Browse/History count tags bufPrint into
    // App.cnt_scratch, which must hold the longest tag + a multi-digit count (the
    // "·" is 2 bytes). bufPrint errors if the buffer is too small, so a future
    // shrink or a longer label trips this test instead of silently dropping the
    // count at runtime. Buffer is sized from the real field so the two can't drift.
    var buf: @FieldType(App, "cnt_scratch") = undefined;
    _ = try std.fmt.bufPrint(&buf, "[catalogue · {d}]", .{999999});
    _ = try std.fmt.bufPrint(&buf, "[watchlist · {d}]", .{999999});
}

test "navigation is a no-op with empty history" {
    var app: App = .{};
    app.setHistory(&.{});
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 0), app.list_cursor);
    try testing.expect(!app.should_quit);
}

test "setHistory clamps an out-of-range cursor" {
    var app: App = .{};
    app.list_cursor = 99;
    var recs = sampleHistory();
    app.setHistory(&recs);
    try testing.expectEqual(@as(usize, 2), app.list_cursor);
    app.setHistory(&.{});
    try testing.expectEqual(@as(usize, 0), app.list_cursor);
}

test "scrollIntoView keeps the cursor within the viewport" {
    var app: App = .{};
    // 10 rows, viewport of 4.
    app.list_cursor = 7;
    app.list_top = 0;
    app.scrollIntoView(4);
    try testing.expect(app.list_cursor >= app.list_top);
    try testing.expect(app.list_cursor < app.list_top + 4);
    // Cursor moves back above the window → window follows up.
    app.list_cursor = 2;
    app.scrollIntoView(4);
    try testing.expectEqual(@as(usize, 2), app.list_top);
}

test "layout settles the browse viewport from terminal geometry (ROD-155)" {
    var app: App = .{};
    app.active_view = .browse;
    app.list_cursor = 30;
    app.list_top = 0;
    // h=20 → content budget = h-3 = 17 visible rows. The full budget must be
    // used: list_top = cursor + 1 - 17 = 14. Pinning the exact value (not just
    // "cursor visible") is what catches a wrong budget, e.g. a halved visible/2.
    app.layout(20, 80);
    try testing.expectEqual(@as(usize, 14), app.list_top);
}

test "layout settles History's viewport in physical rows incl. group chrome (ROD-139)" {
    // list_top is a physical-row offset now (chrome-aware), not an entry index —
    // so the scroll math walks the real grouped geometry, not cursor arithmetic.
    var recs: [10]store_mod.AnimeRecord = undefined;
    for (&recs) |*r| r.* = .{ .source = "s", .source_id = "x", .title = "T", .list_status = .watching };

    var app: App = .{};
    app.active_view = .history;
    app.history = &recs;
    app.list_cursor = 9; // the last entry
    app.list_top = 0;
    // One "watching" group: header(row 0) + hairline(row 1) + 10×2 entries → 22
    // physical rows. Entry 9's title row = 2 + 2·9 = 20. h=13 → visible = 10 rows.
    // cursor+2 = 22 > 0+10, so list_top = 22 - 10 = 12 (keeps both cursor rows in).
    app.layout(13, 80);
    try testing.expectEqual(@as(usize, 12), app.list_top);
}

test "history cursor walks §5.4 group order, not store load order (ROD-139)" {
    // Load order (last_watched DESC) is scrambled across groups on purpose; the
    // cursor must traverse watching → planning → paused → completed → dropped,
    // preserving load order *within* each group.
    var recs = [_]store_mod.AnimeRecord{
        .{ .source = "s", .source_id = "1", .title = "dropped-A", .list_status = .dropped },
        .{ .source = "s", .source_id = "2", .title = "watching-A", .list_status = .watching },
        .{ .source = "s", .source_id = "3", .title = "planning-A", .list_status = .planning },
        .{ .source = "s", .source_id = "4", .title = "watching-B", .list_status = .watching },
        .{ .source = "s", .source_id = "5", .title = "completed-A", .list_status = .completed },
    };
    var app: App = .{};
    app.active_view = .history;
    app.history = &recs;

    const expected = [_][]const u8{ "watching-A", "watching-B", "planning-A", "completed-A", "dropped-A" };
    for (expected, 0..) |title, i| {
        app.list_cursor = i;
        const rec = app.selectedHistoryRecord() orelse return error.TestUnexpectedNull;
        try testing.expectEqualStrings(title, rec.title);
    }
}

test "history geometry counts headers, hairlines and the inter-group blank (ROD-139)" {
    var recs = [_]store_mod.AnimeRecord{
        .{ .source = "s", .source_id = "1", .title = "w", .list_status = .watching },
        .{ .source = "s", .source_id = "2", .title = "p1", .list_status = .planning },
        .{ .source = "s", .source_id = "3", .title = "p2", .list_status = .planning },
    };
    var app: App = .{};
    app.active_view = .history;
    app.history = &recs;

    // watching: header(0)+hairline(1)+w(2,3) ; blank(4) ; planning: header(5)+
    // hairline(6)+p1(7,8)+p2(9,10) → 11 rows total. Cursor on p2 (ordinal 2).
    app.list_cursor = 2;
    const g = history_view.geometry(&app);
    try testing.expectEqual(@as(u16, 11), g.total);
    try testing.expectEqual(@as(u16, 9), g.cursor_row); // p2's title row
}

test "layout bails when EITHER too-small arm trips (ROD-155)" {
    // The guard is `h < 4 or w < 16` — either arm alone must no-op, so layout()
    // never settles a viewport for a frame draw() would skip. Each case is set
    // up so a non-bailing layout() WOULD move list_top, proving the guard fired.
    {
        // Both arms.
        var app: App = .{};
        app.active_view = .history;
        app.list_cursor = 5;
        app.list_top = 3;
        app.layout(3, 10);
        try testing.expectEqual(@as(usize, 3), app.list_top);
    }
    {
        // Height-only: h=3 (<4), w fine. visible would be 0 → scrollIntoView(1)
        // would push list_top to 5; the guard must keep it at 3.
        var app: App = .{};
        app.active_view = .history;
        app.list_cursor = 5;
        app.list_top = 3;
        app.layout(3, 80);
        try testing.expectEqual(@as(usize, 3), app.list_top);
    }
    {
        // Width-only: w=10 (<16), h fine. visible would be 17 → scrollIntoView
        // would pull list_top to 14; the guard must keep it at 0.
        var app: App = .{};
        app.active_view = .browse;
        app.list_cursor = 30;
        app.list_top = 0;
        app.layout(20, 10);
        try testing.expectEqual(@as(usize, 0), app.list_top);
    }
}

test "paneSplit holds the §3.2 38% list / remainder detail geometry (ROD-113)" {
    // The split is shared by the Browse and wide-History arms, so History's
    // preview column lands exactly where Browse's does at the same width.
    inline for (.{
        .{ .w = 100, .list_w = 38 },
        .{ .w = 120, .list_w = 45 },
        .{ .w = 160, .list_w = 60 },
    }) |c| {
        const sp = App.paneSplit(c.w);
        try testing.expectEqual(@as(u16, c.list_w), sp.list_w);
        // 2-cell left margin + list + 2-cell gap.
        try testing.expectEqual(@as(u16, 2 + c.list_w + 2), sp.detail_x);
        // Detail fills the remainder and never overruns the terminal width.
        try testing.expect(sp.detail_w > 0);
        try testing.expect(sp.detail_x + sp.detail_w < c.w);
    }
}

test "paneSplit clamps the list column to a 30-col floor at narrow widths" {
    const sp = App.paneSplit(60);
    try testing.expectEqual(@as(u16, 30), sp.list_w); // 60*38/100 = 22 → floored to 30
}

test "two-pane split engages at 60, zoom/grid at 100 (ROD-170)" {
    // ROD-170 unified Browse + History on pane_split_min and lowered it 100→60.
    try testing.expectEqual(@as(u16, 60), App.pane_split_min);
    try testing.expectEqual(@as(u16, 100), App.zoom_min);
    // The gating predicate the .history arm uses: w >= pane_split_min.
    try testing.expect(59 < App.pane_split_min);
    try testing.expect(60 >= App.pane_split_min);
    // The two-pane preview engages strictly before the interactive grid/zoom.
    try testing.expect(App.pane_split_min < App.zoom_min);
}

test "detail two-column gate trips at 100 cols and falls back below (ROD-113)" {
    try testing.expectEqual(@as(u16, 100), detail_view.detail_two_col_min);
    try testing.expect(!detail_view.isTwoColumn(99));
    try testing.expect(detail_view.isTwoColumn(100));
    try testing.expect(detail_view.isTwoColumn(160));
}

test "history preview split engages only with a focused record (ROD-113)" {
    // The wide-History split is gated on `selectedHistoryRecord() != null`, so
    // empty/loading/error states (no focused record) keep the single column.
    var app: App = .{};

    // Empty history → no record to preview.
    try testing.expect(app.selectedHistoryRecord() == null);

    // Loading: data hasn't drained yet, so history.len == 0 → still null.
    app.history_loading = true;
    try testing.expect(app.selectedHistoryRecord() == null);

    // Loaded with a valid cursor → a record is focused, split may engage.
    app.history_loading = false;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.list_cursor = 1;
    const rec = app.selectedHistoryRecord();
    try testing.expect(rec != null);
    try testing.expectEqualStrings("K-On!", rec.?.title);
}

test "F2 from browse goes to history" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .browse;
    try testTick(&app, keyEv(vaxis.Key.f2, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .history), app.active_view);
}

test "F2 from history is a no-op" {
    var app: App = .{};
    app.active_view = .history;
    app.active_pane = .list;
    try testTick(&app, keyEv(vaxis.Key.f2, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .history), app.active_view);
}

test "F1 from history switches to browse" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    try testTick(&app, keyEv(vaxis.Key.f1, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
}

test "F1 from browse is a no-op and preserves active_pane" {
    var app: App = .{};
    app.active_view = .browse;
    app.active_pane = .detail;
    try testTick(&app, keyEv(vaxis.Key.f1, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
    // active_pane must not be reset — F1 from Browse is a no-op per §10.2
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .detail), app.active_pane);
}

test "F4 and D from browse open Discover (ROD-239)" {
    inline for (.{ keyEv(vaxis.Key.f4, .{}), keyEv('D', .{}) }) |k| {
        var app: App = .{};
        app.active_view = .browse;
        try testTick(&app, k);
        try testing.expectEqual(@as(@TypeOf(app.active_view), .discover), app.active_view);
    }
}

test "F1 leaves Discover for Browse; F4 in Discover is a no-op (ROD-239)" {
    var app: App = .{};
    app.active_view = .discover;
    try testTick(&app, keyEv(vaxis.Key.f4, .{})); // already in Discover → no-op
    try testing.expectEqual(@as(@TypeOf(app.active_view), .discover), app.active_view);
    try testTick(&app, keyEv(vaxis.Key.f1, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
}

test "D in search mode does not switch to Discover (normal-mode guard, ROD-239)" {
    var app: App = .{};
    app.active_view = .browse;
    app.input_mode = .search;
    try testTick(&app, keyEv('D', .{ .shift = true }));
    // The D→Discover binding is normal-mode only; in search it must fall through
    // to the query buffer, leaving the view untouched.
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
}

test "popular_done lands in its own window slot, not the active one (ROD-239)" {
    var app: App = .{};
    app.gpa = testing.allocator;
    defer app.discover.deinit(testing.allocator);
    app.active_view = .discover;
    app.discover.window = .daily;

    // A one-result WEEKLY page arrives while DAILY is the active window.
    const results = try testing.allocator.alloc(Anime, 1);
    results[0] = try workers.dupeOwnedAnime(testing.allocator, .{ .id = "w1", .name = "Weekly Show", .view_count = 39653 });
    try testTick(&app, .{ .popular_done = .{ .results = results, .window = .weekly, .page = 1 } });

    // Landed in the weekly slot, stamped fresh…
    const weekly = &app.discover.slots[@intFromEnum(source_mod.PopularWindow.weekly)];
    try testing.expectEqual(@as(usize, 1), weekly.results.items.len);
    try testing.expectEqual(@as(u32, 1), weekly.page);
    try testing.expect(weekly.fetched_at > 0);
    try testing.expectEqual(@as(?u64, 39653), weekly.results.items[0].view_count);
    // …and the active daily slot is untouched — no cross-window contamination.
    try testing.expectEqual(@as(usize, 0), app.discover.activeSlot().results.items.len);
}

test "entering Discover with a fresh slot is a cache hit; a stale slot fetches (ROD-239)" {
    // Cache HIT: a slot fetched within the TTL must NOT fire a fetch. Observable:
    // firePopular sets the slot's loading flag before spawning; testTick drains the
    // worker's .popular_done without processing it, so a fired fetch leaves loading
    // set. A hit never calls firePopular, so loading stays false.
    {
        var app: App = .{};
        app.gpa = testing.allocator;
        defer app.discover.deinit(testing.allocator);
        app.active_view = .browse;
        const daily = &app.discover.slots[@intFromEnum(source_mod.PopularWindow.daily)];
        try daily.results.append(testing.allocator, try workers.dupeOwnedAnime(testing.allocator, .{ .id = "d1", .name = "Daily Show" }));
        daily.page = 1;
        daily.fetched_at = store_mod.Store.nowSecs(); // fresh
        try testTick(&app, keyEv('D', .{}));
        try testing.expectEqual(@as(@TypeOf(app.active_view), .discover), app.active_view);
        try testing.expect(!daily.loading); // cache hit — no fetch fired
        try testing.expectEqual(@as(usize, 1), daily.results.items.len); // preserved
    }
    // Cache MISS: an unfetched slot (page 0) fires a page-1 fetch on entry.
    {
        var app: App = .{};
        app.gpa = testing.allocator;
        defer app.discover.deinit(testing.allocator);
        app.active_view = .browse;
        try testTick(&app, keyEv(vaxis.Key.f4, .{}));
        try testing.expectEqual(@as(@TypeOf(app.active_view), .discover), app.active_view);
        // Stale/empty → firePopular ran (loading set; the drained .popular_done that
        // would clear it is freed unprocessed by the test harness).
        try testing.expect(app.discover.activeSlot().loading);
    }
}

test "Discover grid cursor: l advances, g/G jump to ends (ROD-239)" {
    var app: App = .{};
    app.gpa = testing.allocator;
    defer app.discover.deinit(testing.allocator);
    app.active_view = .discover;
    app.term_cols = 120;
    const daily = &app.discover.slots[@intFromEnum(source_mod.PopularWindow.daily)];
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try daily.results.append(testing.allocator, try workers.dupeOwnedAnime(testing.allocator, .{ .id = "x", .name = "Show" }));
    }
    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqual(@as(usize, 1), app.discover.cursor);
    try testTick(&app, keyEv('G', .{}));
    try testing.expectEqual(@as(usize, 4), app.discover.cursor); // last
    try testTick(&app, keyEv('g', .{}));
    try testing.expectEqual(@as(usize, 0), app.discover.cursor); // first
}

test "Discover window keys switch the active window and reset the cursor (ROD-239)" {
    var app: App = .{};
    app.gpa = testing.allocator;
    defer app.discover.deinit(testing.allocator);
    app.active_view = .discover;
    app.discover.window = .daily;
    app.discover.cursor = 3;
    // '2' selects Weekly directly; the cursor resets and the slot (stale) fetches.
    try testTick(&app, keyEv('2', .{}));
    try testing.expectEqual(@as(@TypeOf(app.discover.window), .weekly), app.discover.window);
    try testing.expectEqual(@as(usize, 0), app.discover.cursor);
    // ']' cycles forward Weekly → Monthly.
    try testTick(&app, keyEv(']', .{}));
    try testing.expectEqual(@as(@TypeOf(app.discover.window), .monthly), app.discover.window);
    // '[' cycles back Monthly → Weekly.
    try testTick(&app, keyEv('[', .{}));
    try testing.expectEqual(@as(@TypeOf(app.discover.window), .weekly), app.discover.window);
}

test "Discover Enter opens the detail zoom for the selected card; Esc returns (ROD-239)" {
    var app: App = .{};
    app.gpa = testing.allocator;
    defer app.discover.deinit(testing.allocator);
    defer app.episodes.freeResults(testing.allocator); // Enter fires an episode fetch
    app.active_view = .discover;
    const daily = &app.discover.slots[@intFromEnum(source_mod.PopularWindow.daily)];
    try daily.results.append(testing.allocator, try workers.dupeOwnedAnime(testing.allocator, .{ .id = "z1", .name = "Zoom Me" }));
    app.discover.cursor = 0;

    try testTick(&app, keyEv(vaxis.Key.enter, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .detail), app.active_view);
    try testing.expectEqual(@as(@TypeOf(app.detail_origin), .discover), app.detail_origin);
    // Esc demotes the zoom back to Discover (origin maps home).
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .discover), app.active_view);
}

test "Discover / jumps to Browse search (ROD-239)" {
    var app: App = .{};
    app.active_view = .discover;
    try testTick(&app, keyEv('/', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
    try testing.expectEqual(@as(@TypeOf(app.input_mode), .search), app.input_mode);
}

test "popular_error marks the window failed and clears its spinner (ROD-239)" {
    var app: App = .{};
    app.active_view = .discover;
    const daily = &app.discover.slots[@intFromEnum(source_mod.PopularWindow.daily)];
    daily.loading = true;
    try testTick(&app, .{ .popular_error = .{ .window = .daily, .cause = error.NetworkDown } });
    try testing.expect(!daily.loading);
    try testing.expect(daily.failed); // drives the in-view "can't reach the feed"
}

test "popular_done persists feed rows to the store (persist like search, ROD-239)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    var st = try store_mod.Store.openMemory();
    defer st.close();

    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &st;
    defer app.discover.deinit(testing.allocator);
    app.active_view = .discover;

    const results = try testing.allocator.alloc(Anime, 1);
    results[0] = try workers.dupeOwnedAnime(testing.allocator, .{ .id = "f1", .name = "Feed Show", .view_count = 12345 });
    try testTick(&app, .{ .popular_done = .{ .results = results, .window = .daily, .page = 1 } });

    // The window-agnostic facts landed in the store, shareable with Browse. (The
    // hidden-cache flag is a History-query filter column; getAnime doesn't surface
    // it, so the row's presence + correct facts is the persist proof here.)
    const rec = (try st.getAnime(arena_inst.allocator(), "allanime", "f1")).?;
    try testing.expectEqualStrings("Feed Show", rec.title);
    try testing.expectEqual(@as(?i64, null), rec.year); // no year in the feed payload row
}

test "Discover P adds the selected card to the watchlist (ROD-239)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    var st = try store_mod.Store.openMemory();
    defer st.close();

    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &st;
    defer app.discover.deinit(testing.allocator);
    app.active_view = .discover;
    const daily = &app.discover.slots[@intFromEnum(source_mod.PopularWindow.daily)];
    try daily.results.append(testing.allocator, try workers.dupeOwnedAnime(testing.allocator, .{ .id = "p1", .name = "Plan Me" }));
    app.discover.cursor = 0;

    try testTick(&app, keyEv('P', .{ .shift = true }));
    // The add flags a background history reload and lands a row in the store.
    try testing.expect(app.history_dirty);
    const rec = (try st.getAnime(arena_inst.allocator(), "allanime", "p1")).?;
    try testing.expectEqualStrings("Plan Me", rec.title);
}

test "History p/x/c/w keybinds transition the focused entry, store + memory (ROD-139 C)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var st = try store_mod.Store.openMemory();
    defer st.close();
    try st.upsertAnime(.{ .source = "s", .source_id = "a", .title = "A", .total_episodes = 12 }, 1000, arena);
    try st.recordPlay("s", "a", 3, 2000, true); // watching, progress 3

    const recs = try st.loadHistory(arena);
    var app: App = .{};
    app.gpa = testing.allocator; // needed: setSelectedHistoryStatus dupes key strings for undo
    app.store = &st;
    app.active_view = .history;
    app.active_pane = .list;
    app.history = recs;
    app.list_cursor = 0;
    defer if (app.undo) |u| u.free(testing.allocator); // release undo slot after test

    // p → paused, in BOTH the in-memory record and the store.
    try testTick(&app, keyEv('p', .{}));
    try testing.expectEqual(domain.ListStatus.paused, app.history[0].list_status);
    try testing.expectEqual(domain.ListStatus.paused, (try st.getAnime(arena, "s", "a")).?.list_status);

    // c → completed, and progress snaps to the finale in memory and store.
    try testTick(&app, keyEv('c', .{}));
    try testing.expectEqual(domain.ListStatus.completed, app.history[0].list_status);
    try testing.expectEqual(@as(i64, 12), app.history[0].progress);
    try testing.expectEqual(@as(i64, 12), (try st.getAnime(arena, "s", "a")).?.progress);

    // x → dropped, w → watching (assert store too, not just memory).
    try testTick(&app, keyEv('x', .{}));
    try testing.expectEqual(domain.ListStatus.dropped, app.history[0].list_status);
    try testing.expectEqual(domain.ListStatus.dropped, (try st.getAnime(arena, "s", "a")).?.list_status);
    try testTick(&app, keyEv('w', .{}));
    try testing.expectEqual(domain.ListStatus.watching, app.history[0].list_status);
    try testing.expectEqual(domain.ListStatus.watching, (try st.getAnime(arena, "s", "a")).?.list_status);
    // w (and x before it) leave progress at the completed-snap value by design:
    // re-watching keeps the full bar until a real play moves the high-water.
    try testing.expectEqual(@as(i64, 12), app.history[0].progress);
    try testing.expectEqual(@as(i64, 12), (try st.getAnime(arena, "s", "a")).?.progress);
}

test "Browse P adds the highlighted result to the watchlist as planning (ROD-189)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var st = try store_mod.Store.openMemory();
    defer st.close();

    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.store = &st;
    app.active_view = .browse;
    app.active_pane = .list;
    try app.search.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "x"),
        .name = try std.testing.allocator.dupe(u8, "X"),
    });
    defer {
        for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
        app.search.results.deinit(std.testing.allocator);
        app.episodes.freeResults(app.gpa);
    }

    try testTick(&app, keyEv('P', .{ .shift = true }));

    // The store row landed as a planning, history-visible save with no watch fields.
    const rec = (try st.getAnime(arena, "allanime", "x")).?;
    try testing.expectEqual(domain.ListStatus.planning, rec.list_status);
    try testing.expect(rec.history_visible);
    try testing.expectEqual(@as(i64, 0), rec.progress);
    try testing.expectEqual(@as(i64, 0), rec.play_count);
    // P adds a row not yet in self.history → it flags the run-loop's background
    // reload so the show surfaces in History this session.
    try testing.expect(app.history_dirty);
    // …and confirms with a success toast.
    try testing.expect(app.toast_queue[0] != null);
    try testing.expectEqual(Toast.Kind.success, app.toast_queue[0].?.kind);
}

test "History P re-plans the focused entry, store + memory + undo (ROD-189)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var st = try store_mod.Store.openMemory();
    defer st.close();
    try st.upsertAnime(.{ .source = "s", .source_id = "a", .title = "A", .total_episodes = 12 }, 1000, arena);
    try st.recordPlay("s", "a", 5, 2000, true); // watching, progress 5

    const recs = try st.loadHistory(arena);
    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &st;
    app.active_view = .history;
    app.active_pane = .list;
    app.history = recs;
    app.list_cursor = 0;
    defer if (app.undo) |u| u.free(testing.allocator);

    // P → planning in memory and store; progress preserved (re-plan, not a reset).
    try testTick(&app, keyEv('P', .{ .shift = true }));
    try testing.expectEqual(domain.ListStatus.planning, app.history[0].list_status);
    try testing.expectEqual(domain.ListStatus.planning, (try st.getAnime(arena, "s", "a")).?.list_status);
    try testing.expectEqual(@as(i64, 5), app.history[0].progress);

    // It's undoable like the other manual transitions.
    try testTick(&app, keyEv('u', .{}));
    try testing.expectEqual(domain.ListStatus.watching, app.history[0].list_status);
}

test "History `u` undoes the last status mutation, store + memory (ROD-193)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var st = try store_mod.Store.openMemory();
    defer st.close();
    try st.upsertAnime(.{ .source = "s", .source_id = "a", .title = "A", .total_episodes = 12 }, 1000, arena);
    try st.recordPlay("s", "a", 3, 2000, true); // progress 3

    const recs = try st.loadHistory(arena);
    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &st;
    app.active_view = .history;
    app.active_pane = .list;
    app.history = recs;
    app.list_cursor = 0;
    defer if (app.undo) |u| u.free(testing.allocator);

    // Capture the pre-mutation state — undo must restore exactly this.
    const before_status = app.history[0].list_status;
    try testing.expectEqual(@as(i64, 3), app.history[0].progress);

    // c → completed: the fat-finger snaps progress to the finale.
    try testTick(&app, keyEv('c', .{}));
    try testing.expectEqual(domain.ListStatus.completed, app.history[0].list_status);
    try testing.expectEqual(@as(i64, 12), app.history[0].progress);

    // u → revert to the captured prior state in BOTH memory and store.
    try testTick(&app, keyEv('u', .{}));
    try testing.expectEqual(before_status, app.history[0].list_status);
    try testing.expectEqual(@as(i64, 3), app.history[0].progress);
    try testing.expectEqual(before_status, (try st.getAnime(arena, "s", "a")).?.list_status);
    try testing.expectEqual(@as(i64, 3), (try st.getAnime(arena, "s", "a")).?.progress);

    // Single-level: a second u is a silent no-op (the slot is empty).
    try testTick(&app, keyEv('u', .{}));
    try testing.expectEqual(before_status, app.history[0].list_status);
    try testing.expectEqual(@as(i64, 3), app.history[0].progress);
}

test "History `r` recomputes progress from episode_progress after a clobber (ROD-193)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var st = try store_mod.Store.openMemory();
    defer st.close();
    try st.upsertAnime(.{ .source = "s", .source_id = "a", .title = "A", .total_episodes = 12 }, 1000, arena);
    // The real per-episode truth: eps 1..5 fully watched (0.95 ratio).
    try st.saveProgress("s", "a", .sub, "1", 950, 1000, 1001);
    try st.saveProgress("s", "a", .sub, "2", 950, 1000, 1002);
    try st.saveProgress("s", "a", .sub, "3", 950, 1000, 1003);
    try st.saveProgress("s", "a", .sub, "4", 950, 1000, 1004);
    try st.saveProgress("s", "a", .sub, "5", 950, 1000, 1005);
    // A mis-keyed force-complete clobbers the scalar high-water to the finale.
    try st.setListStatus("s", "a", .completed); // progress → 12

    const recs = try st.loadHistory(arena);
    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &st;
    app.translation = .sub; // recompute is translation-scoped (no column on anime)
    app.active_view = .history;
    app.active_pane = .list;
    app.history = recs;
    app.list_cursor = 0;
    defer if (app.undo) |u| u.free(testing.allocator);

    try testing.expectEqual(@as(i64, 12), app.history[0].progress); // confirm the clobber

    // r → recompute from episode_progress: back to the true high-water (5),
    // in both memory and store.
    try testTick(&app, keyEv('r', .{}));
    try testing.expectEqual(@as(i64, 5), app.history[0].progress);
    try testing.expectEqual(@as(i64, 5), (try st.getAnime(arena, "s", "a")).?.progress);
}

test "History `c` then `r` then `u`: recompute survives, undo is a no-op (ROD-193 review)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var st = try store_mod.Store.openMemory();
    defer st.close();
    try st.upsertAnime(.{ .source = "s", .source_id = "a", .title = "A", .total_episodes = 12 }, 1000, arena);
    // Per-episode truth: eps 1..5 fully watched; scalar high-water 5, watching.
    try st.saveProgress("s", "a", .sub, "1", 950, 1000, 1001);
    try st.saveProgress("s", "a", .sub, "2", 950, 1000, 1002);
    try st.saveProgress("s", "a", .sub, "3", 950, 1000, 1003);
    try st.saveProgress("s", "a", .sub, "4", 950, 1000, 1004);
    try st.saveProgress("s", "a", .sub, "5", 950, 1000, 1005);
    try st.recordPlay("s", "a", 5, 2000, true); // progress 5, watching

    const recs = try st.loadHistory(arena);
    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &st;
    app.translation = .sub;
    app.active_view = .history;
    app.active_pane = .list;
    app.history = recs;
    app.list_cursor = 0;
    defer if (app.undo) |u| u.free(testing.allocator);

    // c → completed, progress snaps to finale (the fat-finger). Pushes undo {watching, 5}.
    try testTick(&app, keyEv('c', .{}));
    try testing.expectEqual(domain.ListStatus.completed, app.history[0].list_status);
    try testing.expectEqual(@as(i64, 12), app.history[0].progress);

    // r → recompute to the true high-water (5) AND invalidate the stale undo entry.
    try testTick(&app, keyEv('r', .{}));
    try testing.expectEqual(@as(i64, 5), app.history[0].progress);

    // u → undo slot was cleared by r, so this is a no-op: the recompute survives.
    try testTick(&app, keyEv('u', .{}));
    try testing.expectEqual(@as(i64, 5), app.history[0].progress);
    try testing.expectEqual(domain.ListStatus.completed, app.history[0].list_status);
    try testing.expectEqual(@as(i64, 5), (try st.getAnime(arena, "s", "a")).?.progress);
}

test "History `r` recompute-to-0 clears the episode resume marker (ROD-193 review)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var st = try store_mod.Store.openMemory();
    defer st.close();
    // No fully_watched rows → recompute yields 0. Clobber first so the row is tracked.
    try st.upsertAnime(.{ .source = "s", .source_id = "a", .title = "A", .total_episodes = 12 }, 1000, arena);
    try st.setListStatus("s", "a", .completed); // progress → 12

    const recs = try st.loadHistory(arena);
    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &st;
    app.translation = .sub;
    app.active_view = .history;
    app.active_pane = .list;
    app.history = recs;
    app.list_cursor = 0;
    defer if (app.undo) |u| u.free(testing.allocator);

    // Bind the episode pane to this exact (source, source_id) with a stale resume
    // marker pointing at episode 0 and a loaded GPA-owned episode list.
    app.episodes.for_id = try testing.allocator.dupe(u8, "a");
    app.episodes.for_source = try testing.allocator.dupe(u8, "s");
    const labels = [_][]const u8{ "1", "2", "3" };
    var view = try testing.allocator.alloc(domain.EpisodeNumber, labels.len);
    for (labels, 0..) |lbl, i| view[i] = .{ .raw = try testing.allocator.dupe(u8, lbl) };
    app.episodes.results = view;
    app.episodes.resume_idx = 0; // the stale marker the old code would have left
    app.episodes.cursor = 0;
    defer app.episodes.freeResults(testing.allocator);

    // r → progress 0; the resume marker must clear (no ▸ on an unwatched ep 0).
    try testTick(&app, keyEv('r', .{}));
    try testing.expectEqual(@as(u32, 0), app.episodes.progress);
    try testing.expectEqual(@as(?usize, null), app.episodes.resume_idx);
}

test "F1/H from History reset the viewport before Browse reads it (ROD-139 H1, ROD-210)" {
    // list_top is a physical-row offset in History but an entry index in Browse —
    // leaving History must clear it so a stale physical value can't leak across.
    // ROD-210 retired the q/Esc → Browse jump; F1 and the H toggle are now the
    // only History → Browse paths, and they own the reset.
    inline for (.{ vaxis.Key.f1, 'H' }) |k| {
        var app: App = .{};
        var recs = sampleHistory();
        app.setHistory(&recs);
        app.active_view = .history;
        app.active_pane = .list;
        app.list_cursor = 4;
        app.list_top = 12; // a History physical-row offset
        try testTick(&app, keyEv(k, .{}));
        try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
        try testing.expectEqual(@as(usize, 0), app.list_top);
        try testing.expectEqual(@as(usize, 0), app.list_cursor);
    }
}

test "H from history toggles to browse" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    try testTick(&app, keyEv('H', .{ .shift = true }));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
}

test "H from browse toggles to history" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .browse;
    try testTick(&app, keyEv('H', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .history), app.active_view);
}

test "F3 / S from any view switches to settings" {
    for ([_]@TypeOf(@as(App, undefined).active_view){ .browse, .history }) |from_view| {
        var app: App = .{};
        app.active_view = from_view;
        try testTick(&app, keyEv(vaxis.Key.f3, .{}));
        try testing.expectEqual(@as(@TypeOf(app.active_view), .settings), app.active_view);
    }
}

test "S from settings is a no-op" {
    var app: App = .{};
    app.active_view = .settings;
    try testTick(&app, keyEv('S', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .settings), app.active_view);
}

test "q from history quits the app — no back-nav (ROD-210)" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    try testing.expect(!app.should_quit);
    try testTick(&app, keyEv('q', .{}));
    // q quits in place — it no longer routes History → Browse.
    try testing.expect(app.should_quit);
    try testing.expectEqual(@as(@TypeOf(app.active_view), .history), app.active_view);
}

test "q from settings saves and quits, staying in the Settings view (ROD-210)" {
    var app: App = .{};
    app.active_view = .settings;
    try testing.expect(!app.should_quit);
    try testTick(&app, keyEv('q', .{}));
    // q persists (leaveSettings — a no-op here since nothing is dirty) then
    // quits; it no longer routes to Browse.
    try testing.expect(app.should_quit);
    try testing.expectEqual(@as(@TypeOf(app.active_view), .settings), app.active_view);
}

test "q from browse quits the app" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .browse;
    try testing.expect(!app.should_quit);
    try testTick(&app, keyEv('q', .{}));
    try testing.expect(app.should_quit);
}

test "Esc from browse detail pane returns to list pane" {
    var app: App = .{};
    app.active_view = .browse;
    app.active_pane = .detail;
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
}

test "Esc from history list is a no-op — stays in History (ROD-210)" {
    var app: App = .{};
    app.active_view = .history;
    app.active_pane = .list;
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    // ROD-210: Esc peels transient layers only; over a base-view list it does
    // nothing (no more History → Browse jump).
    try testing.expectEqual(@as(@TypeOf(app.active_view), .history), app.active_view);
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
    try testing.expect(!app.should_quit);
}

test "Esc from history detail pane returns to the list pane, not Browse (ROD-210)" {
    var app: App = .{};
    app.active_view = .history;
    app.active_pane = .detail;
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    // Peels the pane layer and stays in History — the old contract jumped to
    // Browse on the *next* Esc; the new one never does.
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
    try testing.expectEqual(@as(@TypeOf(app.active_view), .history), app.active_view);
    // A further Esc is a plain no-op.
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .history), app.active_view);
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
}

test "Esc from settings is a no-op — does not jump to Browse (ROD-210)" {
    var app: App = .{};
    app.active_view = .settings;
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .settings), app.active_view);
    try testing.expect(!app.should_quit);
}

test "q typed into a Browse search appends instead of quitting (ROD-210)" {
    var app: App = .{};
    app.active_view = .browse;
    app.input_mode = .search;
    // Feed 'q' with .text populated, as a real terminal does: the input_mode
    // guard must route it to onSearchKey (append), never the quit path. (keyEv
    // leaves .text null, so it can't exercise the append — hence the raw event.)
    try testTick(&app, .{ .key_press = .{ .codepoint = 'q', .text = "q" } });
    try testing.expect(!app.should_quit);
    try testing.expectEqual(@as(@TypeOf(app.input_mode), .search), app.input_mode);
    try testing.expectEqual(@as(usize, 1), app.search.len);
    try testing.expectEqual(@as(u8, 'q'), app.search.query[0]);
}

test "q typed into a History filter appends instead of quitting (ROD-210)" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    app.input_mode = .search;
    try testTick(&app, .{ .key_press = .{ .codepoint = 'q', .text = "q" } });
    try testing.expect(!app.should_quit);
    try testing.expectEqual(@as(@TypeOf(app.input_mode), .search), app.input_mode);
    try testing.expectEqual(@as(usize, 1), app.history_filter_len);
    try testing.expectEqual(@as(u8, 'q'), app.history_filter[0]);
}

test "q from a browse detail pane quits — never backs out (ROD-210)" {
    var app: App = .{};
    app.active_view = .browse;
    app.active_pane = .detail;
    try testTick(&app, keyEv('q', .{}));
    try testing.expect(app.should_quit);
}

test "Esc from browse list pane is a no-op" {
    var app: App = .{};
    app.active_view = .browse;
    app.active_pane = .list;
    try testing.expect(!app.should_quit);
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
    try testing.expect(!app.should_quit);
}

test "h in browse list pane is a no-op (already leftmost)" {
    var app: App = .{};
    app.active_view = .browse;
    app.active_pane = .list;
    try testTick(&app, keyEv('h', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
}

test "l in browse list pane switches to detail pane" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .list;
    app.term_cols = 80; // two-pane width: l focuses the detail pane (ROD-194)
    // l requires a selected result.
    try app.search.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "x"),
        .name = try std.testing.allocator.dupe(u8, "X"),
    });
    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .detail), app.active_pane);
    for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.search.results.deinit(std.testing.allocator);
    app.episodes.freeResults(app.gpa);
}

test "Browse load-more fires on Down arrow at the last result, not just j (ROD-156 parity)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .list;
    // A full page so nav_len % search_page_size == 0 and the cursor can sit at the
    // last row — the exact state that shows the ╌ more ╌ footer.
    const page = source_mod.search_page_size;
    try app.search.results.ensureTotalCapacity(std.testing.allocator, page);
    for (0..page) |i| {
        app.search.results.appendAssumeCapacity(.{
            .id = try std.fmt.allocPrint(std.testing.allocator, "id{d}", .{i}),
            .name = try std.fmt.allocPrint(std.testing.allocator, "n{d}", .{i}),
        });
    }
    app.list_cursor = page - 1;
    app.search.page = 1;
    const q = "kimi"; // fireSearch bails on an empty query
    @memcpy(app.search.query[0..q.len], q);
    app.search.len = q.len;
    defer {
        for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
        app.search.results.deinit(std.testing.allocator);
        app.episodes.freeResults(app.gpa);
    }

    // The regression: the Down arrow used to walk the cursor to the wall without
    // triggering page+1 (only 'j' did). fireSearch flips search_loading before it
    // spawns, so that flag proves the next page was requested.
    try testTick(&app, keyEv(vaxis.Key.down, .{}));
    try testing.expect(app.search.loading);
}

test "h in browse detail pane switches to list pane" {
    var app: App = .{};
    app.active_view = .browse;
    app.active_pane = .detail;
    try testTick(&app, keyEv('h', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
}

test "l in browse detail pane is a no-op (already rightmost)" {
    var app: App = .{};
    app.active_view = .browse;
    app.active_pane = .detail;
    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .detail), app.active_pane);
}

// ROD-194: below pane_split_min Browse has no detail pane to focus into, so
// Enter/Space must open the full-screen zoom (mirroring single-column History).
// The regression: l/Enter flipped active_pane to .detail (lighting the · chip)
// while the content stayed on the list, and Space did nothing.
fn singleColumnBrowse(app: *App) !void {
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .list;
    app.term_cols = 50; // < pane_split_min: single column, no pane
    try app.search.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "x"),
        .name = try std.testing.allocator.dupe(u8, "X"),
    });
}

fn teardownBrowse(app: *App) void {
    for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.search.results.deinit(std.testing.allocator);
    app.episodes.freeResults(app.gpa);
}

test "Enter in single-column browse (<60) opens the zoom + fires episodes (ROD-194)" {
    var app: App = .{};
    try singleColumnBrowse(&app);
    defer teardownBrowse(&app);

    try testTick(&app, keyEv(vaxis.Key.enter, .{}));
    try testing.expectEqual(.detail, app.active_view);
    try testing.expectEqual(.browse, app.detail_origin);
    try testing.expectEqual(.detail, app.active_pane);
    try testing.expectEqualStrings("x", app.episodes.for_id orelse return error.TestExpectationFailed);
}

test "Space in single-column browse (<60) opens the zoom (ROD-194)" {
    var app: App = .{};
    try singleColumnBrowse(&app);
    defer teardownBrowse(&app);

    try testTick(&app, keyEv(vaxis.Key.space, .{}));
    try testing.expectEqual(.detail, app.active_view);
    try testing.expectEqual(.browse, app.detail_origin);
    try testing.expectEqual(.detail, app.active_pane);
    try testing.expectEqualStrings("x", app.episodes.for_id orelse return error.TestExpectationFailed);
}

test "l in single-column browse (<60) is a no-op — no pane to focus, chip stays dim (ROD-194)" {
    var app: App = .{};
    try singleColumnBrowse(&app);
    defer teardownBrowse(&app);

    try testTick(&app, keyEv('l', .{}));
    // The regression was l flipping active_pane to .detail with nothing drawn.
    try testing.expectEqual(.browse, app.active_view);
    try testing.expectEqual(.list, app.active_pane);
}

test "left/right arrows mirror h/l for browse pane switching (ROD-156 #1)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .list;
    app.term_cols = 80; // two-pane width: right/l focus the detail pane (ROD-194)
    try app.search.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "x"),
        .name = try std.testing.allocator.dupe(u8, "X"),
    });
    defer {
        for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
        app.search.results.deinit(std.testing.allocator);
        app.episodes.freeResults(app.gpa);
    }

    // right enters the detail pane (mirrors l).
    try testTick(&app, keyEv(vaxis.Key.right, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .detail), app.active_pane);

    // right in the detail pane is a no-op — and crucially does NOT play (play is
    // enter-gated; right must not be a hidden play trigger).
    try testTick(&app, keyEv(vaxis.Key.right, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .detail), app.active_pane);
    try testing.expect(!app.playing);

    // left steps back to the list (mirrors h).
    try testTick(&app, keyEv(vaxis.Key.left, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);

    // left in the list pane is a no-op (already leftmost).
    try testTick(&app, keyEv(vaxis.Key.left, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
}

test "left/right arrows are no-ops in single-pane history (ROD-156 #1)" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    app.active_pane = .list;
    try testTick(&app, keyEv(vaxis.Key.right, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .history), app.active_view);
    try testTick(&app, keyEv(vaxis.Key.left, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .history), app.active_view);
}

test "browse scrolling fires zero episode fetches; detail entry lazy-loads them (ROD-202)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .list;
    app.term_cols = 80; // wide split browse, list focused — the old hover-prefetch trigger
    try app.search.results.ensureTotalCapacity(std.testing.allocator, 3);
    inline for (.{ "a", "b", "c" }) |id| {
        app.search.results.appendAssumeCapacity(.{
            .id = try std.testing.allocator.dupe(u8, id),
            .name = try std.testing.allocator.dupe(u8, id),
        });
    }
    defer {
        for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
        app.search.results.deinit(std.testing.allocator);
        app.episodes.freeResults(app.gpa);
    }

    // Scroll across the whole list. ROD-202 reverses ROD-156's episode prefetch:
    // the grid loads lazily on detail entry now (parity with History), so cursor
    // motion must leave the episode subsystem completely untouched — nothing
    // fetched, nothing in flight, no show claimed.
    try testTick(&app, keyEv('j', .{}));
    try testTick(&app, keyEv('j', .{}));
    try testTick(&app, keyEv('k', .{}));
    try testing.expect(!app.episodes.loading);
    try testing.expect(app.episodes.for_id == null);

    // Enter the detail pane: *now* the grid loads — the in-flight fetch claims
    // the focused show via episodes.for_id (the cover half of ROD-156 was already
    // tracking the cursor; this is the episode half, deferred to entry).
    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .detail), app.active_pane);
    try testing.expect(app.episodes.for_id != null);
}

test "browse scrolling debounces the cover fetch; discrete nav syncs at once (ROD-202)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .list;
    try app.search.results.ensureTotalCapacity(std.testing.allocator, 3);
    inline for (.{ "a", "b", "c" }) |id| {
        app.search.results.appendAssumeCapacity(.{
            .id = try std.testing.allocator.dupe(u8, id),
            .name = try std.testing.allocator.dupe(u8, id),
        });
    }
    defer {
        for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
        app.search.results.deinit(std.testing.allocator);
        app.episodes.freeResults(app.gpa);
    }

    // Narrow: no preview pane, so the cover doesn't track the cursor — a move must
    // NOT arm the settle debounce (coverTracksCursor() is false).
    app.term_cols = 40;
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 1), app.list_cursor);
    try testing.expectEqual(@as(i64, 0), app.cover_sync_deadline_ms);

    // Wide split browse, list focused: a real key-driven cursor move arms the
    // cover settle instead of fetching on the spot (the ROD-202 fix — a fast
    // scroll re-arms each move and only the settled show fetches in .tick).
    app.term_cols = 80;
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 2), app.list_cursor);
    try testing.expect(app.cover_sync_deadline_ms > 0);

    // A no-op move (j at the bottom) doesn't re-arm.
    app.cover_sync_deadline_ms = 0;
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 2), app.list_cursor);
    try testing.expectEqual(@as(i64, 0), app.cover_sync_deadline_ms);

    // A jump key (g/G) moves the cursor but is a deliberate settle point, NOT a
    // scroll — it must sync the cover at once, not arm the debounce (review fix:
    // only j/k/↓/↑ in normal mode arm). Arm a settle, then
    // jump to top: the jump cancels it.
    app.cover_sync_deadline_ms = 999;
    try testTick(&app, keyEv('g', .{}));
    try testing.expectEqual(@as(usize, 0), app.list_cursor);
    try testing.expectEqual(@as(i64, 0), app.cover_sync_deadline_ms);

    // Discrete nav (focus the detail pane) is not a scroll either: it cancels any
    // pending settle and syncs the cover immediately, so it never lags a keystroke.
    app.cover_sync_deadline_ms = 999;
    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqual(@as(i64, 0), app.cover_sync_deadline_ms);
}

test "cover settle arms in wide history and fires on .tick (ROD-202)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    app.active_pane = .list;

    // Wide history carries the cursor-tracked preview too, so a scroll arms the
    // same settle as Browse — coverTracksCursor() covers history (ROD-113/170).
    app.term_cols = 120;
    try testTick(&app, keyEv('j', .{}));
    try testing.expect(app.cover_sync_deadline_ms > 0);

    // The .tick that finds the deadline due consumes it (fires syncCover — a no-op
    // under builtin.is_test, so the deadline-clear is the observable contract).
    app.cover_sync_deadline_ms = 1; // due in the past
    try testTick(&app, .tick);
    try testing.expectEqual(@as(i64, 0), app.cover_sync_deadline_ms);
}

test "browse list pane detail render info uses selected anime" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .list;
    try app.search.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "x"),
        .name = try std.testing.allocator.dupe(u8, "X"),
        .eps_sub = 12,
    });

    try testing.expect(app.currentDetailAnime() == null);
    const info = app.detailRenderInfo();
    try testing.expect(info.anime != null);
    try testing.expectEqualStrings("X", info.title);
    try testing.expectEqualStrings("12 eps", info.meta);
    try testing.expect(info.has_meta);

    for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.search.results.deinit(std.testing.allocator);
}

test "Browse preview hides a stale episode grid carried over from History detail (ROD-222)" {
    // Repro: a focused History detail loads an episode grid; pressing H toggles to
    // Browse and resets pane focus to .list, but leaves episodes.results loaded
    // (the fetch/clear is lazy — it fires on the next detail entry). The Browse
    // two-pane draws drawDetailPane on every frame, so the grid must be gated on a
    // *focused* detail show or the leftover grid bleeds into the list preview.
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    app.active_pane = .detail; // focused on the History detail — grid is its surface
    app.term_cols = 120;

    // Episodes loaded for the focused History show (as a real fetch would leave them).
    app.episodes.for_id = try std.testing.allocator.dupe(u8, "a");
    app.episodes.for_source = try std.testing.allocator.dupe(u8, "allanime");
    app.episodes.results = try workers.dupEpisodesOwned(app.gpa, &.{ .{ .raw = "1" }, .{ .raw = "2" } });
    defer app.episodes.freeResults(std.testing.allocator);

    // Focused History detail → the grid is its own surface, so it renders.
    try testing.expect(app.episodeGridVisible());

    // H toggles to Browse and resets focus to the list. The stale episodes survive.
    try testTick(&app, keyEv('H', .{ .shift = true }));
    try testing.expectEqual(.browse, app.active_view);
    try testing.expectEqual(.list, app.active_pane);
    try testing.expect(app.episodes.results != null); // stale state still present…

    // …but with the list focused (a preview), the grid must NOT render — even once
    // Browse results arrive under the cursor. This is the bug: previously the grid
    // painted the leftover History episodes against the focused Browse result.
    try app.search.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "z"),
        .name = try std.testing.allocator.dupe(u8, "Zoku"),
        .eps_sub = 12,
    });
    defer {
        for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
        app.search.results.deinit(std.testing.allocator);
    }
    app.list_cursor = 0;
    try testing.expect(!app.episodeGridVisible());

    // Focusing the detail pane (the drill state — the l/Enter→.detail transition
    // itself is covered by "l in browse list pane switches to detail pane") makes
    // the grid eligible again. Set focus directly, matching the detailSyncTarget
    // predicate test; here we assert only what the predicate does given that focus.
    app.active_pane = .detail;
    try testing.expect(app.episodeGridVisible());
}

test "episodeGridVisible is true in the full-screen zoom detail view (ROD-222)" {
    // The third drawDetailPane callsite is the zoom (active_view == .detail), where
    // currentDetailAnime resolves via detail_origin (not active_pane). The grid must
    // stay visible there — the gate only suppresses the unfocused Browse preview.
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .detail;
    app.detail_origin = .history;
    app.active_pane = .detail;
    try testing.expect(app.episodeGridVisible());

    // Browse-origin zoom resolves via selectedAnime — also eligible.
    app.detail_origin = .browse;
    try app.search.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "z"),
        .name = try std.testing.allocator.dupe(u8, "Zoku"),
    });
    defer {
        for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
        app.search.results.deinit(std.testing.allocator);
    }
    try testing.expect(app.episodeGridVisible());
}

test "detailSyncTarget tracks the list cursor in split browse, defers elsewhere (ROD-156)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .list;
    try app.search.results.ensureTotalCapacity(std.testing.allocator, 2);
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "x"),
        .name = try std.testing.allocator.dupe(u8, "X"),
    });
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "y"),
        .name = try std.testing.allocator.dupe(u8, "Y"),
    });
    defer {
        for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
        app.search.results.deinit(std.testing.allocator);
    }

    // Narrow terminal: no split pane, so the cover target defers to
    // currentDetailAnime (null while focused on the list).
    app.term_cols = 40;
    try testing.expect(app.detailSyncTarget() == null);
    try testing.expect(std.meta.eql(app.detailSyncTarget(), app.currentDetailAnime()));

    // Wide terminal, list pane: the detail pane is on-screen, so the cover target
    // is the list cursor even though currentDetailAnime still returns null.
    app.term_cols = 80;
    try testing.expect(app.currentDetailAnime() == null);
    try testing.expectEqualStrings("X", app.detailSyncTarget().?.name);
    app.list_cursor = 1;
    try testing.expectEqualStrings("Y", app.detailSyncTarget().?.name);

    // Focusing the detail pane hands the cover target back to currentDetailAnime.
    app.active_pane = .detail;
    try testing.expect(std.meta.eql(app.detailSyncTarget(), app.currentDetailAnime()));
}

test "detailSyncTarget tracks the history cursor in wide preview mode, no episode prefetch (ROD-156)" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;

    // Narrow (< pane_split_min): no two-pane preview, so the cover path is inert
    // and the target defers to currentDetailAnime (null in the history view).
    app.term_cols = 50;
    try testing.expect(app.detailSyncTarget() == null);

    // Wide (>= pane_split_min): the preview is on-screen, so the cover tracks
    // the focused record as the cursor moves (ROD-170 lowered this gate to 60).
    app.term_cols = 120;
    try testing.expectEqualStrings("Frieren", app.detailSyncTarget().?.name);
    app.list_cursor = 1;
    try testing.expectEqualStrings("K-On!", app.detailSyncTarget().?.name);
}

test "h / l in history view are no-ops (single pane)" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    try testTick(&app, keyEv('h', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
}

test "Enter in history focuses the detail pane + fires episodes at zoom width (ROD-170)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    app.term_cols = 120; // zoom tier: the grid is live, so focus fires the fetch

    try testTick(&app, keyEv(vaxis.Key.enter, .{}));
    // ROD-170: no more full-screen jump — we stay in History and focus the pane.
    try testing.expectEqual(.history, app.active_view);
    try testing.expectEqual(.detail, app.active_pane);
    try testing.expectEqualStrings("a", app.episodes.for_id orelse return error.TestExpectationFailed);

    app.episodes.freeResults(app.gpa);
}

test "Enter in history at 60-99 focuses the preview pane + fetches (ROD-170)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    app.term_cols = 80; // preview tier: focus the pane + fetch (so the zoom is ready)

    try testTick(&app, keyEv(vaxis.Key.enter, .{}));
    try testing.expectEqual(.history, app.active_view);
    try testing.expectEqual(.detail, app.active_pane);
    try testing.expectEqualStrings("a", app.episodes.for_id orelse return error.TestExpectationFailed);

    app.episodes.freeResults(app.gpa);
}

test "Enter in single-column history (<60) opens the zoom + fetches (ROD-170)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    app.term_cols = 50; // no two-pane → Enter opens the zoom directly

    try testTick(&app, keyEv(vaxis.Key.enter, .{}));
    try testing.expectEqual(.detail, app.active_view);
    try testing.expectEqual(.history, app.detail_origin);
    try testing.expectEqual(.detail, app.active_pane);
    try testing.expectEqualStrings("a", app.episodes.for_id orelse return error.TestExpectationFailed);

    app.episodes.freeResults(app.gpa);
}

test "Enter in a 60-99 detail pane zooms instead of playing (ROD-170)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    app.active_pane = .detail; // focused on the gridless preview pane
    app.term_cols = 80;

    // Episodes are loaded (fetched on focus). If Enter wrongly played, it would
    // start this episode — the bug ROD reported. It must drill to the zoom instead.
    app.episodes.results = try workers.dupEpisodesOwned(app.gpa, &.{.{ .raw = "1" }});
    app.episodes.for_id = try std.testing.allocator.dupe(u8, "a");
    app.episodes.cursor = 0;

    try testTick(&app, keyEv(vaxis.Key.enter, .{}));
    try testing.expectEqual(.detail, app.active_view); // drilled into the zoom
    try testing.expectEqual(.detail, app.active_pane); // pane focus carried into the zoom
    try testing.expect(!app.playing); // …and did NOT start playback

    app.episodes.freeResults(app.gpa);
}

test "q from the zoom quits — Esc/h own the demote (ROD-170, ROD-210)" {
    var app: App = .{};
    app.active_view = .detail;
    app.detail_origin = .history;
    app.active_pane = .detail;

    try testTick(&app, keyEv('q', .{}));
    // ROD-210: q quits from anywhere. The zoom→two-pane→list back-out moved
    // entirely onto Esc/h (see the Esc-from-zoom tests below).
    try testing.expect(app.should_quit);
    try testing.expectEqual(.detail, app.active_view); // unchanged — q didn't nav
}

test "q from a focused History detail pane quits — never backs out (ROD-170, ROD-210)" {
    // Pre-ROD-210 this backed one level to the list (the old "q back" help line).
    // The new contract makes q quit unconditionally; Esc/h do the one-level peel.
    var app: App = .{};
    app.active_view = .history;
    app.active_pane = .detail;
    app.term_cols = 120;

    try testTick(&app, keyEv('q', .{}));
    try testing.expect(app.should_quit);
    try testing.expectEqual(.history, app.active_view); // unchanged — q didn't nav
    try testing.expectEqual(.detail, app.active_pane);
}

test "Esc from the zoom demotes to two-pane detail focus (ROD-170)" {
    var app: App = .{};
    app.active_view = .detail;
    app.detail_origin = .history;
    app.active_pane = .detail;
    app.term_cols = 120; // there's room for the pane → demote lands on it

    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    // ROD-170: Esc demotes ONE step (zoom → pane), not all the way to the list.
    try testing.expectEqual(.history, app.active_view);
    try testing.expectEqual(.detail, app.active_pane);
    try testing.expect(!app.should_quit);
}

test "h from the zoom demotes to two-pane detail focus (ROD-170)" {
    var app: App = .{};
    app.active_view = .detail;
    app.detail_origin = .history;
    app.active_pane = .detail;
    app.term_cols = 120;

    try testTick(&app, keyEv('h', .{}));
    try testing.expectEqual(.history, app.active_view);
    try testing.expectEqual(.detail, app.active_pane);
    try testing.expect(!app.should_quit);
}

test "demote from the zoom below pane_split_min lands on the list (ROD-170)" {
    var app: App = .{};
    app.active_view = .detail;
    app.detail_origin = .history;
    app.active_pane = .detail;
    app.term_cols = 50; // no pane to demote to → Esc returns to the single-column list

    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expectEqual(.history, app.active_view);
    try testing.expectEqual(.list, app.active_pane);
}

test "Space promotes a focused History detail pane to the zoom (ROD-170)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    app.active_pane = .detail;
    app.term_cols = 120; // zoom tier

    try testTick(&app, keyEv(vaxis.Key.space, .{}));
    try testing.expectEqual(.detail, app.active_view); // full-screen zoom
    try testing.expectEqual(.history, app.detail_origin); // remembers the origin
    try testing.expectEqual(.detail, app.active_pane);
}

test "Space promotes the Browse detail pane to the zoom too (ROD-170)" {
    var app: App = .{};
    app.active_view = .browse;
    app.active_pane = .detail; // focused on the Browse detail pane
    app.term_cols = 120;

    try testTick(&app, keyEv(vaxis.Key.space, .{}));
    try testing.expectEqual(.detail, app.active_view); // zoomed
    try testing.expectEqual(.browse, app.detail_origin); // remembers Browse as origin

    // …and Space again demotes back to the Browse detail pane.
    try testTick(&app, keyEv(vaxis.Key.space, .{}));
    try testing.expectEqual(.browse, app.active_view);
    try testing.expectEqual(.detail, app.active_pane);
}

test "Space in the zoom demotes back to the two-pane detail focus (ROD-170)" {
    var app: App = .{};
    app.active_view = .detail;
    app.detail_origin = .history;
    app.active_pane = .detail;
    app.term_cols = 120;

    try testTick(&app, keyEv(vaxis.Key.space, .{}));
    try testing.expectEqual(.history, app.active_view);
    try testing.expectEqual(.detail, app.active_pane);
}

test "Space promotes from a 60-99 preview pane to the zoom (ROD-170)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    app.active_pane = .detail;
    app.term_cols = 80; // preview tier: the zoom is how you reach the grid

    try testTick(&app, keyEv(vaxis.Key.space, .{}));
    try testing.expectEqual(.detail, app.active_view); // promoted to the zoom
    try testing.expectEqual(.history, app.detail_origin);
}

test "Space in single-column history (<60) opens the zoom (ROD-170)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    app.active_pane = .list;
    app.term_cols = 50; // no pane to toggle → Space opens the zoom like Enter

    try testTick(&app, keyEv(vaxis.Key.space, .{}));
    try testing.expectEqual(.detail, app.active_view);
    try testing.expectEqual(.history, app.detail_origin);
    try testing.expectEqualStrings("a", app.episodes.for_id orelse return error.TestExpectationFailed);

    app.episodes.freeResults(app.gpa);
}

test "h/l toggle the History detail pane like Browse (ROD-170)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    app.term_cols = 80; // two-pane preview: l focuses (+ fetch), h returns

    try testing.expectEqual(.list, app.active_pane);
    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqual(.detail, app.active_pane);
    try testTick(&app, keyEv('h', .{}));
    try testing.expectEqual(.list, app.active_pane);

    app.episodes.freeResults(app.gpa); // l fetched at 60-99; release for_id
}

test "winsize below pane_split_min clamps History focus back to the list (ROD-170)" {
    var app: App = .{};
    app.active_view = .history;
    app.active_pane = .detail; // was focused at a wide width

    try testTick(&app, .{ .winsize = .{ .rows = 30, .cols = 50, .x_pixel = 0, .y_pixel = 0 } });
    try testing.expectEqual(.list, app.active_pane);
}

test "history detail episodes_done seeds cursor from progress" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .detail;
    app.detail_origin = .history;
    app.active_pane = .detail;
    app.episodes.for_id = try std.testing.allocator.dupe(u8, "a");
    app.episodes.loading = true;

    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 6);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    eps[1] = .{ .raw = try std.testing.allocator.dupe(u8, "2") };
    eps[2] = .{ .raw = try std.testing.allocator.dupe(u8, "3") };
    eps[3] = .{ .raw = try std.testing.allocator.dupe(u8, "4") };
    eps[4] = .{ .raw = try std.testing.allocator.dupe(u8, "5") };
    eps[5] = .{ .raw = try std.testing.allocator.dupe(u8, "6") };
    const for_id = try std.testing.allocator.dupe(u8, "a");

    try testTick(&app, .{ .episodes_done = .{ .episodes = eps, .for_id = for_id } });
    try testing.expectEqual(@as(usize, 4), app.episodes.cursor);
    // ROD-192: no checkpoint → resume marker sits on the next-unwatched cell.
    try testing.expectEqual(@as(?usize, 4), app.episodes.resume_idx);

    app.episodes.freeResults(app.gpa);
    app.episodes.lru.deinit(app.gpa);
}

test "browse detail episodes_done seeds watched-dim from store progress (ROD-163)" {
    // ROD-131 dimmed already-watched cells only on a history-origin open; a show
    // opened from Browse showed progress 0 (no dim) even with real store history.
    // ROD-163 seeds detail_progress from the store on the browse path too, so both
    // origins surface the same watch state. No history record is set — the seed
    // must come from the store, keyed off episodes.for_source / for_id.
    var store = try store_mod.Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "browse-show", .title = "Browse Show", .total_episodes = 6, .progress = 3 }, 1000, std.testing.allocator);

    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.store = &store;
    app.active_view = .detail;
    app.detail_origin = .browse; // the path ROD-131 left unseeded
    app.active_pane = .detail;
    app.episodes.for_id = try std.testing.allocator.dupe(u8, "browse-show");
    app.episodes.for_source = try std.testing.allocator.dupe(u8, "allanime");
    app.episodes.loading = true;

    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 6);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    eps[1] = .{ .raw = try std.testing.allocator.dupe(u8, "2") };
    eps[2] = .{ .raw = try std.testing.allocator.dupe(u8, "3") };
    eps[3] = .{ .raw = try std.testing.allocator.dupe(u8, "4") };
    eps[4] = .{ .raw = try std.testing.allocator.dupe(u8, "5") };
    eps[5] = .{ .raw = try std.testing.allocator.dupe(u8, "6") };
    // Separate dup from episodes.for_id above: the event owns its copy (the real
    // tick() contract), freed by the handler's `defer gpa.free(ev.for_id)`.
    const for_id = try std.testing.allocator.dupe(u8, "browse-show");

    try testTick(&app, .{ .episodes_done = .{ .episodes = eps, .for_id = for_id } });

    // progress 3 → episodes 1..3 dim (the high-water mark), cursor parks on the
    // next-unwatched cell (idx 3); no saved checkpoint → resume marker sits there.
    try testing.expectEqual(@as(u32, 3), app.episodes.progress);
    try testing.expectEqual(@as(usize, 3), app.episodes.cursor);
    try testing.expectEqual(@as(?usize, 3), app.episodes.resume_idx);

    app.episodes.freeResults(app.gpa);
    app.episodes.lru.deinit(app.gpa);
}

test "browse detail cache-hit seeds watched-dim from store progress (ROD-163)" {
    // M2 companion to the episodes_done test above: the SYNCHRONOUS
    // tryCacheHit → applyCached → seedHistoryCursor path must seed the
    // browse-origin dim too. Without it, a second (cached) open from Browse would
    // show nothing dimmed even though the first (async) open did.
    var store = try store_mod.Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "x", .title = "X", .total_episodes = 6, .progress = 3 }, 1000, std.testing.allocator);

    var app: App = .{};
    try singleColumnBrowse(&app); // browse result id "x"; source resolves to provider "allanime"
    defer teardownBrowse(&app);
    defer app.episodes.lru.deinit(app.gpa);
    app.store = &store;

    // Warm LRU hit so the open is synchronous (no fetch thread), exercising the
    // tryCacheHit seed path rather than episodes_done.
    const cached = try workers.dupEpisodesOwned(app.gpa, &.{
        .{ .raw = "1" }, .{ .raw = "2" }, .{ .raw = "3" }, .{ .raw = "4" }, .{ .raw = "5" }, .{ .raw = "6" },
    });
    try app.episodes.lru.putOwned(app.gpa, "allanime\x00x\x00sub", .{
        .episodes = cached,
        .expires_at = std.math.maxInt(i64),
    });

    try testTick(&app, keyEv(vaxis.Key.enter, .{})); // browse → detail, synchronous cache hit

    try testing.expectEqual(.browse, app.detail_origin);
    try testing.expect(app.episode_drain.inflight.load(.acquire) == 0); // cache hit, not a fetch
    // The browse-origin dim seeded from the store: progress 3 → 1..3 dim, cursor 3.
    try testing.expectEqual(@as(u32, 3), app.episodes.progress);
    try testing.expectEqual(@as(usize, 3), app.episodes.cursor);
}

test "history detail resume overrides next-episode cursor" {
    var store = try store_mod.Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "resume-show", .title = "Resume Show", .progress = 3 }, 1000, std.testing.allocator);
    try store.saveProgress("allanime", "resume-show", .sub, "3", 91.5, 1440, 1001);

    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.store = &store;
    var hist = [_]AnimeRecord{
        .{ .source = "allanime", .source_id = "resume-show", .title = "Resume Show", .total_episodes = 6, .progress = 3 },
    };
    app.setHistory(&hist);
    app.active_view = .detail;
    app.detail_origin = .history;
    app.active_pane = .detail;
    app.episodes.for_id = try std.testing.allocator.dupe(u8, "resume-show");
    app.episodes.loading = true;

    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 6);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    eps[1] = .{ .raw = try std.testing.allocator.dupe(u8, "2") };
    eps[2] = .{ .raw = try std.testing.allocator.dupe(u8, "3") };
    eps[3] = .{ .raw = try std.testing.allocator.dupe(u8, "4") };
    eps[4] = .{ .raw = try std.testing.allocator.dupe(u8, "5") };
    eps[5] = .{ .raw = try std.testing.allocator.dupe(u8, "6") };
    const for_id = try std.testing.allocator.dupe(u8, "resume-show");

    try testTick(&app, .{ .episodes_done = .{ .episodes = eps, .for_id = for_id } });
    try testing.expectEqual(@as(usize, 2), app.episodes.cursor);
    // ROD-192: the mid-episode checkpoint wins — resume marks the in-progress
    // cell (current_idx == 2), not the next-unwatched one.
    try testing.expectEqual(@as(?usize, 2), app.episodes.resume_idx);

    app.episodes.freeResults(app.gpa);
    app.episodes.lru.deinit(app.gpa);
}

test "history detail completed show defaults cursor to episode one" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var hist = [_]AnimeRecord{
        .{ .source = "allanime", .source_id = "done", .title = "Done Show", .total_episodes = 4, .progress = 4 },
    };
    app.setHistory(&hist);
    app.active_view = .detail;
    app.detail_origin = .history;
    app.active_pane = .detail;
    app.episodes.for_id = try std.testing.allocator.dupe(u8, "done");
    app.episodes.loading = true;

    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 4);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    eps[1] = .{ .raw = try std.testing.allocator.dupe(u8, "2") };
    eps[2] = .{ .raw = try std.testing.allocator.dupe(u8, "3") };
    eps[3] = .{ .raw = try std.testing.allocator.dupe(u8, "4") };
    const for_id = try std.testing.allocator.dupe(u8, "done");

    try testTick(&app, .{ .episodes_done = .{ .episodes = eps, .for_id = for_id } });
    try testing.expectEqual(@as(usize, 0), app.episodes.cursor);
    // ROD-192: a completed show has nothing to resume — no marker.
    try testing.expectEqual(@as(?usize, null), app.episodes.resume_idx);

    app.episodes.freeResults(app.gpa);
    app.episodes.lru.deinit(app.gpa);
}

test "h / l in settings view are no-ops (single pane)" {
    var app: App = .{};
    app.active_view = .settings;
    try testTick(&app, keyEv('h', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
}

test "navigation j/k — history with data, browse empty (no-op), settings no-op" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);

    // Browse with no results: j is a no-op (nav_len == 0).
    app.active_view = .browse;
    app.list_cursor = 0;
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 0), app.list_cursor);

    // History: j moves cursor.
    app.active_view = .history;
    app.list_cursor = 0;
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 1), app.list_cursor);

    // Settings: j is always a no-op.
    app.active_view = .settings;
    app.list_cursor = 1;
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 1), app.list_cursor);
}

test "/ in Browse enters search mode" {
    var app: App = .{};
    app.active_view = .browse;
    try testing.expectEqual(.normal, app.input_mode);
    try testTick(&app, keyEv('/', .{}));
    try testing.expectEqual(.search, app.input_mode);
}

test "/ in History enters search mode" {
    var app: App = .{};
    app.active_view = .history;
    try testTick(&app, keyEv('/', .{}));
    try testing.expectEqual(.search, app.input_mode);
}

test "search mode: Esc clears query and returns to normal" {
    var app: App = .{};
    app.active_view = .browse;
    app.input_mode = .search;
    app.search.len = 5;
    @memcpy(app.search.query[0..5], "hello");
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expectEqual(.normal, app.input_mode);
    try testing.expectEqual(@as(usize, 0), app.search.len);
}

test "search mode: Enter locks results and returns to normal" {
    var app: App = .{};
    app.active_view = .browse;
    app.input_mode = .search;
    app.search.len = 5;
    @memcpy(app.search.query[0..5], "hello");
    try testTick(&app, keyEv(vaxis.Key.enter, .{}));
    try testing.expectEqual(.normal, app.input_mode);
    try testing.expectEqual(@as(usize, 5), app.search.len); // query preserved
}

test "search mode: Backspace to empty clears results and cancels the debounce" {
    // ROD-219 split regression guard: emptying the query via backspace must drop
    // the results, clear the in-flight flag, and cancel an armed debounce — but
    // stay in search mode (the `.cleared{exit:false}` verdict, vs Esc's exit).
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.input_mode = .search;
    app.search.len = 1;
    app.search.query[0] = 'h';
    app.search.loading = true;
    app.debounce_deadline_ms = 999_999; // an armed (pending) debounce

    // A prior result is present; emptying the query must free + drop it (a missed
    // free trips the testing allocator).
    try app.search.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "id"),
        .name = try std.testing.allocator.dupe(u8, "Owned"),
    });
    defer app.search.results.deinit(std.testing.allocator);

    try testTick(&app, keyEv(vaxis.Key.backspace, .{}));

    try testing.expectEqual(@as(usize, 0), app.search.len);
    try testing.expectEqual(@as(usize, 0), app.search.results.items.len);
    try testing.expectEqual(@as(i64, 0), app.debounce_deadline_ms);
    try testing.expect(!app.search.loading);
    try testing.expectEqual(.search, app.input_mode); // backspace does not exit search mode
}

test "search_done page 1 populates results" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.search.len = 7;
    @memcpy(app.search.query[0..7], "frieren");

    const query_copy = try std.testing.allocator.dupe(u8, "frieren");
    const results_backing = try std.testing.allocator.alloc(Anime, 1);
    results_backing[0] = .{
        .id = try std.testing.allocator.dupe(u8, "abc123"),
        .name = try std.testing.allocator.dupe(u8, "Frieren"),
        .eps_sub = 28,
    };

    try testTick(&app, .{ .search_done = .{ .results = results_backing, .for_query = query_copy, .page = 1 } });
    try testing.expectEqual(@as(usize, 1), app.search.results.items.len);
    try testing.expectEqualStrings("Frieren", app.search.results.items[0].name);
    try testing.expectEqual(@as(u32, 1), app.search.page);
    try testing.expect(!app.search.loading);

    for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.search.results.deinit(std.testing.allocator);
}

test "search_done stale result is discarded" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    // Current query is "frieren"; incoming result is for "bebop" — stale.
    app.search.len = 7;
    @memcpy(app.search.query[0..7], "frieren");

    const query_copy = try std.testing.allocator.dupe(u8, "bebop");
    const results_backing = try std.testing.allocator.alloc(Anime, 1);
    results_backing[0] = .{
        .id = try std.testing.allocator.dupe(u8, "xyz789"),
        .name = try std.testing.allocator.dupe(u8, "Bebop"),
        .eps_sub = 26,
    };

    try testTick(&app, .{ .search_done = .{ .results = results_backing, .for_query = query_copy, .page = 1 } });
    // All stale data freed by tick — results untouched.
    try testing.expectEqual(@as(usize, 0), app.search.results.items.len);
    try testing.expectEqual(@as(u32, 0), app.search.page);

    app.search.results.deinit(std.testing.allocator); // capacity is 0; safe no-op
}

test "search_done page 2 appends to existing results" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.search.len = 4;
    @memcpy(app.search.query[0..4], "test");
    app.search.page = 1;

    // Seed a page-1 result directly.
    try app.search.results.ensureTotalCapacity(std.testing.allocator, 2);
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "id1"),
        .name = try std.testing.allocator.dupe(u8, "Show One"),
        .eps_sub = 12,
    });

    const query_copy = try std.testing.allocator.dupe(u8, "test");
    const results_backing = try std.testing.allocator.alloc(Anime, 1);
    results_backing[0] = .{
        .id = try std.testing.allocator.dupe(u8, "id2"),
        .name = try std.testing.allocator.dupe(u8, "Show Two"),
        .eps_sub = 24,
    };

    try testTick(&app, .{ .search_done = .{ .results = results_backing, .for_query = query_copy, .page = 2 } });
    try testing.expectEqual(@as(usize, 2), app.search.results.items.len);
    try testing.expectEqual(@as(u32, 2), app.search.page);
    try testing.expectEqualStrings("Show One", app.search.results.items[0].name);
    try testing.expectEqualStrings("Show Two", app.search.results.items[1].name);

    for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.search.results.deinit(std.testing.allocator);
}

test "SearchController.clearResults frees owned anime (leak-clean under testing.allocator)" {
    // ROD-219 AC: clearResults must release every owned result. Append rows whose
    // id/name are testing.allocator-owned — exactly as search_done takes ownership
    // of worker-duped Anime — then let clearResults free them. No manual cleanup:
    // a missed free trips the testing allocator's leak check and fails the test.
    var search: SearchController = .{};
    defer search.results.deinit(std.testing.allocator);

    try search.results.ensureTotalCapacity(std.testing.allocator, 2);
    search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "id1"),
        .name = try std.testing.allocator.dupe(u8, "Owned One"),
    });
    search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "id2"),
        .name = try std.testing.allocator.dupe(u8, "Owned Two"),
    });
    search.page = 3;
    search.pending_enrich = .{ .offset = 0, .count = 2 };

    search.clearResults(std.testing.allocator);

    // Buffer emptied + page/enrich reset. The freed elements are gone — the
    // testing allocator would already have flagged a leak if clearResults skipped
    // any owned field above.
    try testing.expectEqual(@as(usize, 0), search.results.items.len);
    try testing.expectEqual(@as(u32, 0), search.page);
    try testing.expect(search.pending_enrich == null);
}

test "search_enriched merges metadata into matching live result" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.search.len = 7;
    @memcpy(app.search.query[0..7], "frieren");

    try app.search.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "id1"),
        .name = try std.testing.allocator.dupe(u8, "Frieren"),
        .eps_sub = 28,
    });

    const query_copy = try std.testing.allocator.dupe(u8, "frieren");
    const enriched = try std.testing.allocator.alloc(Anime, 1);
    enriched[0] = .{
        .id = try std.testing.allocator.dupe(u8, "id1"),
        .name = try std.testing.allocator.dupe(u8, "Frieren"),
        .eps_sub = 28,
        .anilist_id = 154587,
        .thumb = try std.testing.allocator.dupe(u8, "https://img.anili.st/frieren.jpg"),
        .description = try std.testing.allocator.dupe(u8, "Elf mage grief hour"),
        .score = 91,
        .total_episodes = 28,
        .year = 2023,
        .status = try std.testing.allocator.dupe(u8, "FINISHED"),
    };

    try testTick(&app, .{ .search_enriched = .{ .results = enriched, .for_query = query_copy, .offset = 0 } });
    try testing.expectEqual(@as(?u64, 154587), app.search.results.items[0].anilist_id);
    try testing.expectEqual(@as(?u32, 91), app.search.results.items[0].score);
    try testing.expectEqualStrings("Elf mage grief hour", app.search.results.items[0].description orelse "");

    for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.search.results.deinit(std.testing.allocator);
}

test "browse j/k navigates results list" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.search.page = 1;

    try app.search.results.ensureTotalCapacity(std.testing.allocator, 3);
    for (0..3) |_| {
        app.search.results.appendAssumeCapacity(.{
            .id = try std.testing.allocator.dupe(u8, "id"),
            .name = try std.testing.allocator.dupe(u8, "X"),
            .eps_sub = 12,
        });
    }

    try testing.expectEqual(@as(usize, 0), app.list_cursor);
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 1), app.list_cursor);
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 2), app.list_cursor);
    try testTick(&app, keyEv('j', .{})); // pinned (3 % 26 != 0 → no load-more)
    try testing.expectEqual(@as(usize, 2), app.list_cursor);
    try testTick(&app, keyEv('k', .{}));
    try testing.expectEqual(@as(usize, 1), app.list_cursor);

    for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.search.results.deinit(std.testing.allocator);
}

test "view switch resets cursor to 0" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    app.list_cursor = 2;

    // F1 → Browse: cursor resets.
    try testTick(&app, keyEv(vaxis.Key.f1, .{}));
    try testing.expectEqual(.browse, app.active_view);
    try testing.expectEqual(@as(usize, 0), app.list_cursor);

    app.list_cursor = 5;
    // F2 → History: cursor resets.
    try testTick(&app, keyEv(vaxis.Key.f2, .{}));
    try testing.expectEqual(.history, app.active_view);
    try testing.expectEqual(@as(usize, 0), app.list_cursor);
}

test "episode_cursor j/k navigation in detail pane" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .detail;

    // Seed 3 episodes.
    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 3);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    eps[1] = .{ .raw = try std.testing.allocator.dupe(u8, "2") };
    eps[2] = .{ .raw = try std.testing.allocator.dupe(u8, "3") };
    app.episodes.results = eps;
    app.episodes.cursor = 0;

    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 1), app.episodes.cursor);
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 2), app.episodes.cursor);
    try testTick(&app, keyEv('j', .{})); // pinned at last
    try testing.expectEqual(@as(usize, 2), app.episodes.cursor);
    try testTick(&app, keyEv('k', .{}));
    try testing.expectEqual(@as(usize, 1), app.episodes.cursor);
    try testTick(&app, keyEv('g', .{}));
    try testing.expectEqual(@as(usize, 0), app.episodes.cursor);
    try testTick(&app, keyEv('G', .{}));
    try testing.expectEqual(@as(usize, 2), app.episodes.cursor);

    app.episodes.freeResults(app.gpa);
}

test "episodes_done populates episode_results" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    const for_id = try std.testing.allocator.dupe(u8, "anime1");
    app.episodes.for_id = try std.testing.allocator.dupe(u8, "anime1");
    app.episodes.loading = true;

    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 2);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    eps[1] = .{ .raw = try std.testing.allocator.dupe(u8, "2") };

    try testTick(&app, .{ .episodes_done = .{ .episodes = eps, .for_id = for_id } });
    try testing.expect(!app.episodes.loading);
    try testing.expectEqual(@as(usize, 2), app.episodes.results.?.len);

    app.episodes.freeResults(app.gpa);
    app.episodes.lru.deinit(app.gpa);
}

test "episode cache: warm LRU hit opens detail synchronously, no fetch (ROD-130)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history; // cursor 0 → Frieren, source_id "a"
    app.term_cols = 120; // zoom tier: focusing the pane fires the (cached) fetch

    const cached = try workers.dupEpisodesOwned(app.gpa, &.{
        .{ .raw = "1" }, .{ .raw = "2" }, .{ .raw = "3" },
    });
    try app.episodes.lru.putOwned(app.gpa, "allanime\x00a\x00sub", .{
        .episodes = cached,
        .expires_at = std.math.maxInt(i64),
    });

    try testTick(&app, keyEv(vaxis.Key.enter, .{}));

    // Synchronous hit: the detail pane focuses, episodes present, no spinner, no
    // fetch thread. ROD-170: focus is the two-pane detail pane, not a full-screen.
    try testing.expectEqual(.history, app.active_view);
    try testing.expectEqual(.detail, app.active_pane);
    try testing.expect(!app.episodes.loading);
    try testing.expect(app.episode_drain.inflight.load(.acquire) == 0);
    try testing.expectEqual(@as(usize, 3), app.episodes.results.?.len);
    try testing.expectEqualStrings("2", app.episodes.results.?[1].raw);

    app.episodes.freeResults(app.gpa);
    app.episodes.lru.deinit(app.gpa);
}

test "episode cache: a fetch populates the LRU for next time (ROD-130)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .detail;
    app.detail_origin = .history;
    app.active_pane = .detail;
    app.episodes.for_id = try std.testing.allocator.dupe(u8, "a");
    app.episodes.loading = true;

    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 2);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    eps[1] = .{ .raw = try std.testing.allocator.dupe(u8, "2") };
    const for_id = try std.testing.allocator.dupe(u8, "a");

    try testTick(&app, .{ .episodes_done = .{ .episodes = eps, .for_id = for_id } });

    const entry = app.episodes.lru.get("allanime\x00a\x00sub") orelse return error.TestExpectationFailed;
    try testing.expectEqual(@as(usize, 2), entry.episodes.len);
    try testing.expectEqualStrings("1", entry.episodes[0].raw);

    app.episodes.freeResults(app.gpa);
    app.episodes.lru.deinit(app.gpa);
}

test "episode cache: a stale LRU entry is bypassed, not served (ROD-130)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    app.term_cols = 120; // zoom tier: focusing the pane attempts the fetch

    // expires_at in the past → must be ignored, forcing the (empty) dummy fetch.
    const stale = try workers.dupEpisodesOwned(app.gpa, &.{
        .{ .raw = "1" }, .{ .raw = "2" }, .{ .raw = "3" },
    });
    try app.episodes.lru.putOwned(app.gpa, "allanime\x00a\x00sub", .{
        .episodes = stale,
        .expires_at = 0,
    });

    try testTick(&app, keyEv(vaxis.Key.enter, .{}));

    // Stale entry ignored → the async fetch path was taken (loading set, no
    // synchronous results). Had it been served, loading would be false and
    // episode_results would hold the 3 cached entries. (testTick drains the
    // worker's episodes_done without re-applying it, so loading stays set.)
    try testing.expect(app.episodes.loading);
    try testing.expect(app.episodes.results == null);

    app.episodes.freeResults(app.gpa); // frees detail_for_id set on the miss path
    app.episodes.lru.deinit(app.gpa);
}

test "episode cache: evicting displayed show A keeps episode_results valid (ROD-130)" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history; // cursor 0 → Frieren, source_id "a"
    app.term_cols = 120; // zoom tier: focusing the pane fires the (cached) fetch

    const cached = try workers.dupEpisodesOwned(app.gpa, &.{
        .{ .raw = "1" }, .{ .raw = "2" }, .{ .raw = "3" },
    });
    try app.episodes.lru.putOwned(app.gpa, "allanime\x00a\x00sub", .{
        .episodes = cached,
        .expires_at = std.math.maxInt(i64),
    });

    // Sync hit → episode_results is an INDEPENDENT dup of show A's episodes.
    try testTick(&app, keyEv(vaxis.Key.enter, .{}));
    try testing.expectEqual(@as(usize, 3), app.episodes.results.?.len);

    // Flood the cache past capacity so A's LRU entry is evicted + freed.
    var i: usize = 0;
    while (i < workers.episode_lru_cap) : (i += 1) {
        var kb: [32]u8 = undefined;
        const k = try std.fmt.bufPrint(&kb, "filler\x00{d}\x00sub", .{i});
        const fill = try workers.dupEpisodesOwned(app.gpa, &.{.{ .raw = "x" }});
        try app.episodes.lru.putOwned(app.gpa, k, .{ .episodes = fill, .expires_at = std.math.maxInt(i64) });
    }
    try testing.expect(app.episodes.lru.get("allanime\x00a\x00sub") == null); // A evicted

    // The view copy survives eviction intact (Option-B invariant).
    try testing.expectEqual(@as(usize, 3), app.episodes.results.?.len);
    try testing.expectEqualStrings("2", app.episodes.results.?[1].raw);

    app.episodes.freeResults(app.gpa);
    app.episodes.lru.deinit(app.gpa);
}

test "episodes_done stale result is discarded" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    // Current show: "anime2"; incoming event is for "anime1" — stale.
    app.episodes.for_id = try std.testing.allocator.dupe(u8, "anime2");
    app.episodes.loading = true;

    const stale_id = try std.testing.allocator.dupe(u8, "anime1");
    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 1);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };

    try testTick(&app, .{ .episodes_done = .{ .episodes = eps, .for_id = stale_id } });
    // Still loading (wasn't cleared by stale event), episode_results still null.
    try testing.expect(app.episodes.loading);
    try testing.expect(app.episodes.results == null);

    // Cleanup detail_for_id manually.
    if (app.episodes.for_id) |id| {
        std.testing.allocator.free(id);
        app.episodes.for_id = null;
    }
}

test "coverTask decoded-cache hit posts a cloned cover_done event" {
    var loop = initTestLoop();
    var raw_cache: RawCoverCache = .{};
    defer raw_cache.deinit(testing.allocator);
    var decoded_cache: DecodedCoverCache = .{};
    defer decoded_cache.deinit(testing.allocator);

    const decoded = try cover_mod.decodeRgba(testing.allocator, &tiny_png);
    try testing.expect(try decoded_cache.putOwnedBounded(testing.allocator, "https://img/anime.png", decoded, max_cover_decoded_cache_bytes));

    coverTask(
        &loop,
        testing.allocator,
        testing.io,
        try testing.allocator.dupe(u8, "https://img/anime.png"),
        try testing.allocator.dupe(u8, "anime1"),
        &raw_cache,
        &decoded_cache,
    );

    const ev = (loop.queue.tryPop() catch null) orelse return error.TestUnexpectedResult;
    defer freeTestEvent(testing.allocator, ev);
    try testing.expect(ev == .cover_done);
    try testing.expectEqualStrings("anime1", ev.cover_done.for_id);
    try testing.expectEqual(@as(u32, 1), ev.cover_done.width);
    try testing.expectEqual(@as(u32, 1), ev.cover_done.height);
    try testing.expectEqual(@as(usize, 4), ev.cover_done.rgba.len);
    try testing.expect(decoded_cache.get("https://img/anime.png") != null);
}

test "coverTask raw-cache hit decodes once and warms decoded cache" {
    var loop = initTestLoop();
    var raw_cache: RawCoverCache = .{};
    defer raw_cache.deinit(testing.allocator);
    var decoded_cache: DecodedCoverCache = .{};
    defer decoded_cache.deinit(testing.allocator);

    const raw = try testing.allocator.dupe(u8, &tiny_png);
    try testing.expect(try raw_cache.putOwnedBounded(testing.allocator, "https://img/anime.png", raw, max_cover_raw_cache_bytes));

    coverTask(
        &loop,
        testing.allocator,
        testing.io,
        try testing.allocator.dupe(u8, "https://img/anime.png"),
        try testing.allocator.dupe(u8, "anime1"),
        &raw_cache,
        &decoded_cache,
    );

    const ev = (loop.queue.tryPop() catch null) orelse return error.TestUnexpectedResult;
    defer freeTestEvent(testing.allocator, ev);
    try testing.expect(ev == .cover_done);
    try testing.expect(decoded_cache.get("https://img/anime.png") != null);
    try testing.expectEqual(@as(u32, 1), ev.cover_done.width);
    try testing.expectEqual(@as(u32, 1), ev.cover_done.height);
}

test "cover_done fresh result stores decoded cover state" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .detail;
    try app.search.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "anime1"),
        .name = try std.testing.allocator.dupe(u8, "Frieren"),
        .thumb = try std.testing.allocator.dupe(u8, "https://img.anili.st/frieren.jpg"),
        .eps_sub = 28,
    });
    app.cover.for_id = try std.testing.allocator.dupe(u8, "anime1");
    app.cover.loading = true;
    // Seed the in-flight url so a regression that stops freeing it on the keep
    // path is caught — both by the null assertion below and the GPA detector.
    app.cover.inflight_url = try std.testing.allocator.dupe(u8, "https://img.anili.st/frieren.jpg");

    const rgba = try std.testing.allocator.dupe(u8, &[_]u8{ 0xaa, 0xbb, 0xcc, 0xff });
    const for_id = try std.testing.allocator.dupe(u8, "anime1");

    try testTick(&app, .{ .cover_done = .{ .rgba = rgba, .width = 1, .height = 1, .for_id = for_id } });
    try testing.expect(!app.cover.loading);
    try testing.expect(app.cover.pixels != null);
    try testing.expectEqual(@as(u32, 1), app.cover.pixels.?.w);
    try testing.expect(app.cover.inflight_url == null); // keep path frees the in-flight url

    app.cover.clear(app.gpa);
    for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.search.results.deinit(std.testing.allocator);
}

test "cover_done stale result is discarded" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .detail;
    try app.search.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "anime2"),
        .name = try std.testing.allocator.dupe(u8, "Bebop"),
        .thumb = try std.testing.allocator.dupe(u8, "https://img.anili.st/bebop.jpg"),
        .eps_sub = 26,
    });
    app.cover.for_id = try std.testing.allocator.dupe(u8, "anime2");
    app.cover.loading = true;

    const rgba = try std.testing.allocator.dupe(u8, &[_]u8{ 0xaa, 0xbb, 0xcc, 0xff });
    const for_id = try std.testing.allocator.dupe(u8, "anime1");

    try testTick(&app, .{ .cover_done = .{ .rgba = rgba, .width = 1, .height = 1, .for_id = for_id } });
    try testing.expect(app.cover.pixels == null);
    try testing.expect(app.cover.loading);

    app.cover.clear(app.gpa);
    for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.search.results.deinit(std.testing.allocator);
}

test "cover_done while not in detail clears stale loading state" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .list;
    try app.search.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "anime1"),
        .name = try std.testing.allocator.dupe(u8, "Frieren"),
        .thumb = try std.testing.allocator.dupe(u8, "https://img.anili.st/frieren.jpg"),
        .eps_sub = 28,
    });
    app.cover.for_id = try std.testing.allocator.dupe(u8, "anime1");
    app.cover.loading = true;

    const rgba = try std.testing.allocator.dupe(u8, &[_]u8{ 0xaa, 0xbb, 0xcc, 0xff });
    const for_id = try std.testing.allocator.dupe(u8, "anime1");

    try testTick(&app, .{ .cover_done = .{ .rgba = rgba, .width = 1, .height = 1, .for_id = for_id } });
    try testing.expect(!app.cover.loading);
    try testing.expect(app.cover.for_id == null);
    try testing.expect(app.cover.pixels == null);

    for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.search.results.deinit(std.testing.allocator);
}

test "cover_error clears state so a later revisit can refetch" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .detail;
    try app.search.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "anime1"),
        .name = try std.testing.allocator.dupe(u8, "Frieren"),
        .thumb = try std.testing.allocator.dupe(u8, "https://img.anili.st/frieren.jpg"),
        .eps_sub = 28,
    });
    app.cover.for_id = try std.testing.allocator.dupe(u8, "anime1");
    app.cover.loading = true;

    const for_id = try std.testing.allocator.dupe(u8, "anime1");
    try testTick(&app, .{ .cover_error = for_id });
    try testing.expect(!app.cover.loading);
    try testing.expect(app.cover.for_id == null);
    try testing.expect(app.cover.pixels == null);
    try testing.expect(app.cover.failed_for_id != null);
    try testing.expectEqualStrings("anime1", app.cover.failed_for_id.?);

    app.cover.clearFailure(app.gpa);

    for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.search.results.deinit(std.testing.allocator);
}

test "deinitOwnedState releases app-owned runtime resources" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.search.page = 2;

    try app.search.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.search.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "anime1"),
        .name = try std.testing.allocator.dupe(u8, "Frieren"),
        .eps_sub = 28,
    });

    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 1);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    app.episodes.results = eps;
    app.episodes.for_id = try std.testing.allocator.dupe(u8, "anime1");

    app.cover.pixels = .{ .rgba = try std.testing.allocator.dupe(u8, &[_]u8{ 0xaa, 0xbb, 0xcc, 0xff }), .w = 1, .h = 1 };
    app.cover.for_id = try std.testing.allocator.dupe(u8, "anime1");
    app.cover.failed_for_id = try std.testing.allocator.dupe(u8, "anime1");
    app.cover.loading = true;

    var vx: vaxis.Vaxis = undefined;
    var writer: std.Io.Writer = undefined;
    app.deinitOwnedState(&vx, &writer);

    try testing.expectEqual(@as(usize, 0), app.search.results.items.len);
    try testing.expectEqual(@as(u32, 0), app.search.page);
    try testing.expect(app.episodes.results == null);
    try testing.expect(app.episodes.for_id == null);
    try testing.expect(app.cover.pixels == null);
    try testing.expect(app.cover.for_id == null);
    try testing.expect(app.cover.failed_for_id == null);
    try testing.expect(!app.cover.loading);
}

test "search mode: char appends and arms debounce, does not fire immediately" {
    var app: App = .{};
    app.active_view = .browse;
    app.input_mode = .search;
    const k = vaxis.Key{ .codepoint = 'a', .text = "a" };
    try testTick(&app, .{ .key_press = k });
    try testing.expectEqual(@as(usize, 1), app.search.len);
    try testing.expect(!app.search.loading);
    try testing.expect(app.debounce_deadline_ms > 0);
}

test "search mode: h and H append to query instead of triggering navigation" {
    var app: App = .{};
    app.active_view = .browse;
    app.active_pane = .detail;
    app.input_mode = .search;

    try testTick(&app, .{ .key_press = .{ .codepoint = 'h', .text = "h" } });
    try testing.expectEqual(@as(usize, 1), app.search.len);
    try testing.expectEqualStrings("h", app.search.query[0..app.search.len]);
    try testing.expectEqual(.browse, app.active_view);
    try testing.expectEqual(.detail, app.active_pane);

    try testTick(&app, .{ .key_press = .{ .codepoint = 'H', .mods = .{ .shift = true }, .text = "H" } });
    try testing.expectEqual(@as(usize, 2), app.search.len);
    try testing.expectEqualStrings("hH", app.search.query[0..app.search.len]);
    try testing.expectEqual(.browse, app.active_view);
    try testing.expectEqual(.detail, app.active_pane);
}

test "tick advances spinner frame and wraps at 10" {
    var app: App = .{};
    try testing.expectEqual(@as(u8, 0), app.spinner_frame);
    for (0..10) |_| try testTick(&app, .tick);
    try testing.expectEqual(@as(u8, 0), app.spinner_frame);
}

test "tick fires debounced search when deadline has passed" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.search.len = 3;
    @memcpy(app.search.query[0..3], "abc");
    app.debounce_deadline_ms = 1; // well in the past — always expired
    try testTick(&app, .tick);
    try testing.expectEqual(@as(i64, 0), app.debounce_deadline_ms);
    try testing.expect(app.search.loading);
    for (app.search.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.search.results.deinit(std.testing.allocator);
}

test "task_error pushes a persistent error toast" {
    var app: App = .{};
    try testTick(&app, .{ .task_error = "network down" });
    const t = app.toast_queue[0] orelse return error.TestExpectationFailed;
    try testing.expectEqual(Toast.Kind.@"error", t.kind);
    try testing.expect(t.persistent);
    try testing.expectEqualStrings("network down", t.text[0..t.text_len]);
}

test "task_error (Browse failure) never marks History unavailable (ROD-234)" {
    var app: App = .{};
    // A Browse search/enrich error must surface only as a toast — it must not raise
    // the History "unavailable" banner nor stop the history spinner, or a transient
    // network blip would falsely brick the History landing view for the session.
    try testTick(&app, .{ .task_error = "ServerError" });
    try testing.expectEqual(@as(?[]const u8, null), app.load_error);
    try testing.expect(app.history_loading); // still loading; not bricked
}

test "history_load_failed raises the banner and stops the spinner (ROD-234)" {
    var app: App = .{};
    try testTick(&app, .{ .history_load_failed = "DiskCorrupt" });
    try testing.expect(app.load_error != null);
    try testing.expectEqualStrings("DiskCorrupt", app.load_error.?);
    try testing.expect(!app.history_loading);
}

test "a successful history load clears a latched load_error (ROD-234)" {
    var app: App = .{};
    // Simulate a prior history-load failure, then a recovery load.
    try testTick(&app, .{ .history_load_failed = "DiskCorrupt" });
    try testing.expect(app.load_error != null);
    var recs = sampleHistory();
    try testTick(&app, .{ .history_loaded = &recs });
    try testing.expectEqual(@as(?[]const u8, null), app.load_error);
    try testing.expect(!app.history_loading);
}

test "a successful history RELOAD also clears a latched load_error (ROD-234)" {
    // Guard the reload path explicitly: both .history_loaded and .history_reloaded
    // route through setHistory(), so a post-playback reload that succeeds must clear
    // a prior latched banner too. Pins the invariant against a future refactor that
    // decouples .history_reloaded from setHistory.
    var app: App = .{};
    try testTick(&app, .{ .history_load_failed = "DiskCorrupt" });
    try testing.expect(app.load_error != null);
    var recs = sampleHistory();
    try testTick(&app, .{ .history_reloaded = &recs });
    try testing.expectEqual(@as(?[]const u8, null), app.load_error);
    try testing.expect(!app.history_loading);
}

test "task_error truncates an over-long payload to the §4.7 copy budget with … (ROD-166)" {
    var app: App = .{};
    // A 50-char @errorName-style payload, well past the 36-col copy budget.
    try testTick(&app, .{ .task_error = "CertificateBundleLoadFailedAndCouldNotConnectAtAll" });
    const t = app.toast_queue[0] orelse return error.TestExpectationFailed;
    const copy = t.text[0..t.text_len];
    // Packs the full budget: (max_copy_cols - 1) cols of copy + "…" = max_copy_cols,
    // ending in the … affordance. The `==` (not `<=`) rejects a degenerate impl
    // that returns a bare "…".
    try testing.expectEqual(Toast.max_copy_cols, vaxis.gwidth.gwidth(copy, .unicode));
    try testing.expect(std.mem.endsWith(u8, copy, "…"));
}

test "position_update refreshes live playback fields" {
    var app: App = .{};
    app.current_position = 12;
    app.current_duration = 24;

    try testTick(&app, .{ .position_update = .{ .time_pos = 91.5, .duration = 1440 } });
    try testing.expectApproxEqAbs(@as(f64, 91.5), app.current_position, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1440), app.current_duration, 0.001);
}

test "position_update checkpoints playback progress every 30 seconds" {
    var store = try store_mod.Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "show1", .title = "Test Show" }, 1000, std.testing.allocator);

    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &store;
    app.playing = true;
    app.session.source = "allanime";
    app.session.anime_id = try testing.allocator.dupe(u8, "show1");
    app.session.episode_raw = try testing.allocator.dupe(u8, "3");
    app.session.translation = .sub;

    try testTick(&app, .{ .position_update = .{ .time_pos = 29.0, .duration = 1440 } });
    try testing.expect((try store.getResume("allanime", "show1", .sub, "3")) == null);

    try testTick(&app, .{ .position_update = .{ .time_pos = 30.0, .duration = 1440 } });
    const first = (try store.getResume("allanime", "show1", .sub, "3")).?;
    try testing.expectApproxEqAbs(@as(f64, 30.0), first.position_secs, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1440), first.duration_secs, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 30.0), app.session.last_checkpoint_pos, 0.001);

    try testTick(&app, .{ .position_update = .{ .time_pos = 59.0, .duration = 1440 } });
    const second = (try store.getResume("allanime", "show1", .sub, "3")).?;
    try testing.expectApproxEqAbs(@as(f64, 30.0), second.position_secs, 0.001);

    try testTick(&app, .{ .position_update = .{ .time_pos = 60.5, .duration = 1440 } });
    const third = (try store.getResume("allanime", "show1", .sub, "3")).?;
    try testing.expectApproxEqAbs(@as(f64, 60.5), third.position_secs, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 60.5), app.session.last_checkpoint_pos, 0.001);

    try testTick(&app, .{ .play_done = null });
}

test "play_done persists final observed position after checkpoints" {
    var store = try store_mod.Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "show1", .title = "Test Show" }, 1000, std.testing.allocator);

    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &store;
    app.playing = true;
    app.session.source = "allanime";
    app.session.anime_id = try testing.allocator.dupe(u8, "show1");
    app.session.episode_raw = try testing.allocator.dupe(u8, "3");
    app.session.episode_index = 3;
    app.session.translation = .sub;
    app.session.last_checkpoint_pos = 90;

    try store.saveProgress("allanime", "show1", .sub, "3", 90, 1440, 1001);
    try testTick(&app, .{ .play_done = .{ .time_pos = 100, .duration = 1440 } });

    const saved = (try store.getResume("allanime", "show1", .sub, "3")).?;
    try testing.expectApproxEqAbs(@as(f64, 100), saved.position_secs, 0.001);
}

test "play_done ignores non-meaningful final position and preserves checkpoint" {
    var store = try store_mod.Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "show1", .title = "Test Show" }, 1000, std.testing.allocator);

    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &store;
    app.playing = true;
    app.session.source = "allanime";
    app.session.anime_id = try testing.allocator.dupe(u8, "show1");
    app.session.episode_raw = try testing.allocator.dupe(u8, "3");
    app.session.episode_index = 3;
    app.session.translation = .sub;
    app.session.last_checkpoint_pos = 90;

    try store.saveProgress("allanime", "show1", .sub, "3", 90, 1440, 1001);
    try testTick(&app, .{ .play_done = .{ .time_pos = 0, .duration = 1440 } });

    const saved = (try store.getResume("allanime", "show1", .sub, "3")).?;
    try testing.expectApproxEqAbs(@as(f64, 90), saved.position_secs, 0.001);
}

test "play_done clears live playback fields" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.playing = true;
    app.current_position = 91.5;
    app.current_duration = 1440;
    app.session.last_checkpoint_pos = 60;
    app.session.source = "allanime";
    app.session.anime_id = try testing.allocator.dupe(u8, "show1");
    app.session.episode_raw = try testing.allocator.dupe(u8, "3");
    app.session.episode_index = 3;

    try testTick(&app, .{ .play_done = null });
    try testing.expect(!app.playing);
    try testing.expectApproxEqAbs(@as(f64, 0), app.current_position, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0), app.current_duration, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0), app.session.last_checkpoint_pos, 0.001);
    try testing.expectEqual(@as(usize, 0), app.session.anime_id.len);
    try testing.expectEqual(@as(usize, 0), app.session.episode_raw.len);
}

test "play_error with a completed position persists final and records the play" {
    var store = try store_mod.Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "show1", .title = "Test Show" }, 1000, std.testing.allocator);

    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &store;
    app.playing = true;
    app.session.source = "allanime";
    app.session.anime_id = try testing.allocator.dupe(u8, "show1");
    app.session.episode_raw = try testing.allocator.dupe(u8, "3");
    app.session.episode_index = 3;
    app.session.translation = .sub;
    app.session.last_checkpoint_pos = 90;

    // mpv died near the end (>= NATURAL_END_RATIO): completed is derived true,
    // so the play is recorded AND the progress high-water mark advances.
    try testTick(&app, .{ .play_error = .{ .final = .{ .time_pos = 1300, .duration = 1440 }, .cause = error.MpvFailed } });

    const saved = (try store.getResume("allanime", "show1", .sub, "3")).?;
    try testing.expectApproxEqAbs(@as(f64, 1300), saved.position_secs, 0.001);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rec = (try store.getAnime(arena.allocator(), "allanime", "show1")).?;
    try testing.expectEqual(@as(i64, 1), rec.play_count); // recordPlay fired
    try testing.expectEqual(@as(i64, 3), rec.progress);

    // A completed play_error must NOT fire the failure toast (it took the
    // success path; no episode grid here so no success toast either).
    try testing.expect(app.toast_queue[0] == null);
    try testing.expect(!app.playing); // transport reset
}

test "play_done with a partial watch records the play but not the progress (ROD-168)" {
    var store = try store_mod.Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "show1", .title = "Test Show" }, 1000, std.testing.allocator);

    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &store;
    app.playing = true;
    app.session.source = "allanime";
    app.session.anime_id = try testing.allocator.dupe(u8, "show1");
    app.session.episode_raw = try testing.allocator.dupe(u8, "8");
    app.session.episode_index = 8;
    app.session.translation = .sub;

    // The reported bug: play ep 8, watch ~5s of a 24min episode, quit mpv cleanly.
    // It's a real play (in history, resume saved) but FAR below the completion
    // bar — it must not mark ep 8 watched-through.
    try testTick(&app, .{ .play_done = .{ .time_pos = 5, .duration = 1440 } });

    const saved = (try store.getResume("allanime", "show1", .sub, "8")).?;
    try testing.expectApproxEqAbs(@as(f64, 5), saved.position_secs, 0.001); // resume saved

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rec = (try store.getAnime(arena.allocator(), "allanime", "show1")).?;
    try testing.expectEqual(@as(i64, 1), rec.play_count); // counted as a play
    try testing.expectEqual(@as(i64, 0), rec.progress); // but NOT watched-through
}

test "play_error mid-episode is a real play but not watched, and surfaces failure (ROD-168)" {
    var store = try store_mod.Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "show1", .title = "Test Show" }, 1000, std.testing.allocator);

    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &store;
    app.episodes.results = try allocEpisodes(10);
    app.episodes.cursor = 7; // on episode 8
    app.episodes.for_id = try testing.allocator.dupe(u8, "show1");
    app.playing = true;
    app.session.source = "allanime";
    app.session.anime_id = try testing.allocator.dupe(u8, "show1");
    app.session.episode_raw = try testing.allocator.dupe(u8, "8");
    app.session.episode_index = 8;
    app.session.translation = .sub;

    // mpv crashed ~8% in: meaningful (resume + play recorded) but far below the
    // completion bar — not watched-through, cursor holds, and the crash surfaces
    // as a failure toast (not silent, not a false success).
    try testTick(&app, .{ .play_error = .{ .final = .{ .time_pos = 120, .duration = 1440 }, .cause = error.MpvFailed } });

    const saved = (try store.getResume("allanime", "show1", .sub, "8")).?;
    try testing.expectApproxEqAbs(@as(f64, 120), saved.position_secs, 0.001); // resume saved

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rec = (try store.getAnime(arena.allocator(), "allanime", "show1")).?;
    try testing.expectEqual(@as(i64, 1), rec.play_count); // counted as a play
    try testing.expectEqual(@as(i64, 0), rec.progress); // but NOT watched-through

    try testing.expectEqual(@as(usize, 7), app.episodes.cursor); // unmoved
    try testing.expectEqual(@as(u32, 0), app.episodes.progress); // nothing dimmed
    const t = &app.toast_queue[0].?;
    try testing.expectEqual(Toast.Kind.@"error", t.kind);
    try testing.expectEqualStrings("mpv exited with error", t.text[0..t.text_len]);

    app.episodes.freeResults(app.gpa);
}

test "play_error with no observed position skips recordPlay and preserves checkpoint" {
    var store = try store_mod.Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "show1", .title = "Test Show" }, 1000, std.testing.allocator);
    try store.saveProgress("allanime", "show1", .sub, "3", 90, 1440, 1001);

    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &store;
    app.playing = true;
    app.session.source = "allanime";
    app.session.anime_id = try testing.allocator.dupe(u8, "show1");
    app.session.episode_raw = try testing.allocator.dupe(u8, "3");
    app.session.episode_index = 3;
    app.session.translation = .sub;
    app.session.last_checkpoint_pos = 90;

    // mpv died at position 0: non-meaningful, so record_play is derived false.
    try testTick(&app, .{ .play_error = .{ .final = .{ .time_pos = 0, .duration = 1440 }, .cause = error.MpvFailed } });

    const saved = (try store.getResume("allanime", "show1", .sub, "3")).?;
    try testing.expectApproxEqAbs(@as(f64, 90), saved.position_secs, 0.001); // checkpoint preserved

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rec = (try store.getAnime(arena.allocator(), "allanime", "show1")).?;
    try testing.expectEqual(@as(i64, 0), rec.play_count); // recordPlay did NOT fire

    try testing.expect(!app.playing); // transport still reset
}

// --- ROD-131: detail cursor + watched-state reaction after playback ---

/// Allocate `n` 1-based episode cells ("1".."n") for the detail grid. Caller
/// owns them via `app.episodes.freeResults(app.gpa)`.
fn allocEpisodes(n: usize) ![]domain.EpisodeNumber {
    const eps = try testing.allocator.alloc(domain.EpisodeNumber, n);
    errdefer testing.allocator.free(eps);
    var made: usize = 0;
    errdefer for (eps[0..made]) |ep| testing.allocator.free(ep.raw);
    var buf: [8]u8 = undefined;
    while (made < n) : (made += 1) {
        const raw = std.fmt.bufPrint(&buf, "{d}", .{made + 1}) catch unreachable;
        eps[made] = .{ .raw = try testing.allocator.dupe(u8, raw) };
    }
    return eps;
}

test "play_done advances detail cursor to next episode and dims watched" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.episodes.results = try allocEpisodes(6);
    app.episodes.cursor = 2; // on episode 3
    app.episodes.resume_idx = 2; // resume sat on episode 3 before this watch
    app.episodes.for_id = try testing.allocator.dupe(u8, "show1");
    app.playing = true;
    app.session.anime_id = try testing.allocator.dupe(u8, "show1");
    app.session.episode_raw = try testing.allocator.dupe(u8, "3");
    app.session.episode_index = 3;

    try testTick(&app, .{ .play_done = .{ .time_pos = 1400, .duration = 1440 } });

    try testing.expectEqual(@as(usize, 3), app.episodes.cursor); // advanced to episode 4
    try testing.expectEqual(@as(u32, 3), app.episodes.progress); // 1..3 now dim
    try testing.expectEqual(@as(?usize, 3), app.episodes.resume_idx); // ROD-192: resume advanced to ep 4
    const t = &app.toast_queue[0].?;
    try testing.expectEqual(Toast.Kind.success, t.kind);
    try testing.expectEqualStrings("episode 3 done", t.text[0..t.text_len]);

    app.episodes.freeResults(app.gpa);
}

test "play_error with a completed position still advances the detail cursor" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.episodes.results = try allocEpisodes(6);
    app.episodes.cursor = 2; // on episode 3
    app.episodes.resume_idx = 2; // resume sat on episode 3 before this watch
    app.episodes.for_id = try testing.allocator.dupe(u8, "show1");
    app.playing = true;
    app.session.anime_id = try testing.allocator.dupe(u8, "show1");
    app.session.episode_raw = try testing.allocator.dupe(u8, "3");
    app.session.episode_index = 3;

    // mpv died near the end (>= NATURAL_END_RATIO) → completed: the watch counts
    // and the detail pane reacts just like a clean completed exit.
    try testTick(&app, .{ .play_error = .{ .final = .{ .time_pos = 1300, .duration = 1440 }, .cause = error.MpvFailed } });

    try testing.expectEqual(@as(usize, 3), app.episodes.cursor); // advanced to episode 4
    try testing.expectEqual(@as(u32, 3), app.episodes.progress);
    try testing.expectEqual(@as(?usize, 3), app.episodes.resume_idx); // ROD-192: resume advanced
    const t = &app.toast_queue[0].?;
    try testing.expectEqual(Toast.Kind.success, t.kind);
    try testing.expectEqualStrings("episode 3 done", t.text[0..t.text_len]);
    try testing.expect(app.toast_queue[1] == null); // success only, no false failure toast

    app.episodes.freeResults(app.gpa);
}

test "play_done with a partial watch does not advance or dim (ROD-168)" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.episodes.results = try allocEpisodes(6);
    app.episodes.cursor = 2; // on episode 3
    app.episodes.resume_idx = 2; // resume on episode 3
    app.episodes.for_id = try testing.allocator.dupe(u8, "show1");
    app.playing = true;
    app.session.anime_id = try testing.allocator.dupe(u8, "show1");
    app.session.episode_raw = try testing.allocator.dupe(u8, "3");
    app.session.episode_index = 3;

    // Clean quit a few minutes in (< NATURAL_END_RATIO): not a completed watch,
    // so the cursor holds, nothing dims, and no success toast fires.
    try testTick(&app, .{ .play_done = .{ .time_pos = 300, .duration = 1440 } });

    try testing.expectEqual(@as(usize, 2), app.episodes.cursor); // unmoved
    try testing.expectEqual(@as(u32, 0), app.episodes.progress); // nothing dimmed
    try testing.expectEqual(@as(?usize, 2), app.episodes.resume_idx); // ROD-192: partial watch never advances resume
    try testing.expect(app.toast_queue[0] == null); // clean partial quit is silent

    app.episodes.freeResults(app.gpa);
}

test "play_done on the final episode stays put and toasts all caught up" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.episodes.results = try allocEpisodes(6);
    app.episodes.cursor = 5; // on the last episode
    app.episodes.resume_idx = 5; // resume sat on the finale before watching it
    app.episodes.for_id = try testing.allocator.dupe(u8, "show1");
    app.playing = true;
    app.session.anime_id = try testing.allocator.dupe(u8, "show1");
    app.session.episode_raw = try testing.allocator.dupe(u8, "6");
    app.session.episode_index = 6;

    try testTick(&app, .{ .play_done = .{ .time_pos = 1400, .duration = 1440 } });

    try testing.expectEqual(@as(usize, 5), app.episodes.cursor); // no N+1 to move to
    try testing.expectEqual(@as(u32, 6), app.episodes.progress); // whole grid dim
    try testing.expectEqual(@as(?usize, null), app.episodes.resume_idx); // ROD-192: caught up, nothing to resume
    const t = &app.toast_queue[0].?;
    try testing.expectEqual(Toast.Kind.success, t.kind);
    try testing.expectEqualStrings("all caught up", t.text[0..t.text_len]);

    app.episodes.freeResults(app.gpa);
}

test "play_error with no observed position does not advance the cursor" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.episodes.results = try allocEpisodes(6);
    app.episodes.cursor = 2;
    app.episodes.for_id = try testing.allocator.dupe(u8, "show1");
    app.playing = true;
    app.session.anime_id = try testing.allocator.dupe(u8, "show1");
    app.session.episode_raw = try testing.allocator.dupe(u8, "3");
    app.session.episode_index = 3;

    // mpv died at position 0: record_play is derived false — nothing counted.
    try testTick(&app, .{ .play_error = .{ .final = .{ .time_pos = 0, .duration = 1440 }, .cause = error.MpvFailed } });

    try testing.expectEqual(@as(usize, 2), app.episodes.cursor); // unmoved
    try testing.expectEqual(@as(u32, 0), app.episodes.progress); // nothing dimmed
    // §4.10: a failed play no longer advances/dims, but is no longer silent —
    // it surfaces an error toast so the dead playback isn't a mystery.
    const t = &app.toast_queue[0].?;
    try testing.expectEqual(Toast.Kind.@"error", t.kind);
    try testing.expectEqualStrings("mpv exited with error", t.text[0..t.text_len]);

    app.episodes.freeResults(app.gpa);
}

test "episodes_error with a data-shape cause uses the generic fallback copy" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.episodes.loading = true;
    // The error must be for the current detail show or the keep-check drops it
    // (ROD-179) — set a matching for_id so the toast actually fires.
    app.episodes.for_id = try testing.allocator.dupe(u8, "show1");
    defer app.episodes.freeResults(app.gpa);

    // A non-network failure (the show had no episode data) carries no actionable
    // class — it falls back to the generic line, not a misleading network toast.
    try testTick(&app, .{ .episodes_error = .{
        .cause = error.NoEpisodeData,
        .for_id = try testing.allocator.dupe(u8, "show1"),
    } });

    try testing.expect(!app.episodes.loading);
    const t = &app.toast_queue[0].?;
    try testing.expectEqual(Toast.Kind.@"error", t.kind);
    try testing.expectEqualStrings("couldn't load episodes", t.text[0..t.text_len]);
}

test "ROD-229: resumeTargetIndex finds the most-recently-watched row, else null" {
    var app: App = .{};
    app.gpa = testing.allocator;

    // Empty history → nothing to resume.
    var empty: [0]AnimeRecord = .{};
    app.setHistory(&empty);
    try testing.expectEqual(@as(?usize, null), app.resumeTargetIndex());

    // Every row never played (last_watched_at all null) → nothing to resume.
    var never = sampleHistory();
    app.setHistory(&never);
    try testing.expectEqual(@as(?usize, null), app.resumeTargetIndex());

    // Most-recently-watched sits at the top (loadHistory's DESC-NULLS-LAST order).
    var top = sampleHistory();
    top[0].last_watched_at = 1000;
    app.setHistory(&top);
    try testing.expectEqual(@as(?usize, 0), app.resumeTargetIndex());

    // Defensive: the scan still finds a non-null that isn't at index 0.
    var mid = sampleHistory();
    mid[1].last_watched_at = 500;
    app.setHistory(&mid);
    try testing.expectEqual(@as(?usize, 1), app.resumeTargetIndex());
}

test "ROD-229: a failed resume grid fetch demotes the auto-open to History" {
    var app: App = .{};
    app.gpa = testing.allocator;
    // Stand in the post-auto-open state: detail open, fetch in flight, armed.
    app.active_view = .detail;
    app.active_pane = .detail;
    app.detail_origin = .history;
    app.list_cursor = 0;
    app.resume_landing_pending = true;
    app.episodes.loading = true;
    app.episodes.for_id = try testing.allocator.dupe(u8, "a");
    defer app.episodes.freeResults(app.gpa);

    // The grid fetch fails (offline) — the auto-open must not strand a blank pane.
    try testTick(&app, .{ .episodes_error = .{
        .cause = error.NetworkDown,
        .for_id = try testing.allocator.dupe(u8, "a"),
    } });

    try testing.expectEqual(@as(@TypeOf(app.active_view), .history), app.active_view);
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
    try testing.expect(!app.resume_landing_pending);
    // The failure is still surfaced — a demote, not a silent swallow.
    try testing.expect(app.toast_queue[0] != null);
}

test "ROD-229: a user-driven episode fetch failure stays in detail (no demote)" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .detail;
    app.active_pane = .detail;
    app.detail_origin = .history;
    app.resume_landing_pending = false; // a deliberate open, not a resume landing
    app.episodes.loading = true;
    app.episodes.for_id = try testing.allocator.dupe(u8, "a");
    defer app.episodes.freeResults(app.gpa);

    try testTick(&app, .{ .episodes_error = .{
        .cause = error.NetworkDown,
        .for_id = try testing.allocator.dupe(u8, "a"),
    } });

    // Stays put: the user opened this; the toast explains the error in place.
    try testing.expectEqual(@as(@TypeOf(app.active_view), .detail), app.active_view);
}

// Frieren completed+newest (self.history index 0); One Piece watching+older. The
// grouped cursor space renders watching first, so Frieren's ordinal is 1, not 0 —
// seeding the cursor with the raw history index would put One Piece's meta beside
// Frieren's grid (the bug this guards). Shared by the two-pane and zoom cases.
fn twoShowResumeHistory() [2]AnimeRecord {
    return .{
        .{ .source = "allanime", .source_id = "fr", .title = "Frieren", .list_status = .completed, .total_episodes = 12, .progress = 12, .last_watched_at = 2000 },
        .{ .source = "allanime", .source_id = "op", .title = "One Piece", .list_status = .watching, .total_episodes = 1100, .progress = 50, .last_watched_at = 1000 },
    };
}

test "ROD-229: resume landing seeds the grouped ordinal so meta and grid stay on one show" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.config.landing = "last_watched";
    app.term_cols = 120; // wide: the two-pane detail surface (matches manual drill-in)
    var recs = twoShowResumeHistory();

    // The initial history load is the real resume trigger.
    try testTick(&app, .{ .history_loaded = &recs });

    // Wide terminal → two-pane History with the detail pane focused (NOT the
    // full-screen zoom), exactly like pressing l/Enter on the row manually.
    try testing.expectEqual(@as(@TypeOf(app.active_view), .history), app.active_view);
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .detail), app.active_pane);
    // Cursor on Frieren's GROUPED ordinal (1), not its history index (0).
    try testing.expectEqual(@as(usize, 1), app.list_cursor);
    // The invariant the bug broke: the highlighted record (detail meta, via
    // recordAtCursor) and the fetched grid (episodes.for_id) are the same show.
    try testing.expectEqualStrings("fr", app.selectedHistoryRecord().?.source_id);
    try testing.expectEqualStrings("fr", app.episodes.for_id.?);

    app.cover.joinThread();
    app.episodes.freeResults(app.gpa);
}

test "ROD-229: resume landing opens the zoom below zoom_min so the grid is visible" {
    // The 60–99 band is the trap: the two-pane detail renders here, but its
    // in-pane episode grid does NOT (that needs >= zoom_min) — it's a no-grid
    // preview. A resume landing must show the grid, so below zoom_min it opens the
    // full-screen zoom instead of focusing a gridless pane (the regression guard).
    var app: App = .{};
    app.gpa = testing.allocator;
    app.config.landing = "last_watched";
    app.term_cols = 80; // two-pane width, but below zoom_min → no in-pane grid
    var recs = twoShowResumeHistory();

    try testTick(&app, .{ .history_loaded = &recs });

    // The standalone zoom (the grid surface at any width), same grouped target.
    try testing.expectEqual(@as(@TypeOf(app.active_view), .detail), app.active_view);
    try testing.expectEqual(@as(usize, 1), app.list_cursor);
    try testing.expectEqualStrings("fr", app.episodes.for_id.?);

    app.cover.joinThread();
    app.episodes.freeResults(app.gpa);
}

test "ROD-229: resume landing fires only on the first history load, not a reload" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.config.landing = "last_watched";
    app.term_cols = 120;
    var recs = twoShowResumeHistory();

    try testTick(&app, .{ .history_loaded = &recs });
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .detail), app.active_pane); // opened

    // Back out to the list, then deliver a second history load (stands in for a
    // mid-session reload). The one-shot guard must make it a complete no-op.
    app.active_view = .history;
    app.active_pane = .list;
    try testTick(&app, .{ .history_loaded = &recs });
    try testing.expectEqual(@as(@TypeOf(app.active_view), .history), app.active_view);
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane); // not re-opened

    app.cover.joinThread();
    app.episodes.freeResults(app.gpa);
}

test "ROD-229: never-played history under last_watched stays on the History view" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.config.landing = "last_watched";
    app.term_cols = 120;
    // Every row has a null last_watched_at → nothing to resume.
    var recs = sampleHistory();

    try testTick(&app, .{ .history_loaded = &recs });

    // No auto-open: the ROD-228 startup map already left us on History.
    try testing.expectEqual(@as(@TypeOf(app.active_view), .history), app.active_view);
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
    try testing.expect(!app.resume_landing_pending);
}

test "ROD-229: a successful resume grid load clears the demote arm" {
    var app: App = .{};
    app.gpa = testing.allocator;
    // Stand in the post-auto-open state: detail open, fetch in flight, armed.
    app.active_view = .detail;
    app.active_pane = .detail;
    app.detail_origin = .history;
    app.resume_landing_pending = true;
    app.episodes.loading = true;
    app.episodes.for_id = try testing.allocator.dupe(u8, "fr");
    defer app.episodes.freeResults(app.gpa);
    defer app.episodes.lru.deinit(app.gpa); // episodes_done caches into the LRU

    const eps = try testing.allocator.alloc(domain.EpisodeNumber, 2);
    eps[0] = .{ .raw = try testing.allocator.dupe(u8, "1") };
    eps[1] = .{ .raw = try testing.allocator.dupe(u8, "2") };
    try testTick(&app, .{ .episodes_done = .{ .episodes = eps, .for_id = try testing.allocator.dupe(u8, "fr") } });

    // The grid arrived: stay in detail, disarm the demote.
    try testing.expectEqual(@as(@TypeOf(app.active_view), .detail), app.active_view);
    try testing.expect(!app.resume_landing_pending);
}

test "episodes_error names the failure class for network/blocked/server (ROD-173)" {
    const Case = struct { cause: anyerror, copy: []const u8 };
    const cases = [_]Case{
        .{ .cause = error.NetworkDown, .copy = "network unreachable" },
        .{ .cause = error.Forbidden, .copy = "TestSrc blocked us" },
        .{ .cause = error.ServerError, .copy = "TestSrc is down" },
        .{ .cause = error.HttpNotOk, .copy = "TestSrc returned an error" },
    };
    for (cases) |c| {
        var app: App = .{};
        app.gpa = testing.allocator;
        app.episodes.loading = true;
        app.episodes.for_id = try testing.allocator.dupe(u8, "show1");
        defer app.episodes.freeResults(app.gpa);

        try testTick(&app, .{ .episodes_error = .{
            .cause = c.cause,
            .for_id = try testing.allocator.dupe(u8, "show1"),
        } });

        const t = &app.toast_queue[0].?;
        try testing.expectEqual(Toast.Kind.@"error", t.kind);
        try testing.expectEqualStrings(c.copy, t.text[0..t.text_len]);
    }
}

test "play_error names the failure class: source (173) + player-spawn (230)" {
    const Case = struct { cause: anyerror, copy: []const u8 };
    const cases = [_]Case{
        // Source classes (ROD-173).
        .{ .cause = error.NetworkDown, .copy = "network unreachable" },
        .{ .cause = error.Forbidden, .copy = "TestSrc blocked us" },
        .{ .cause = error.ServerError, .copy = "TestSrc is down" },
        .{ .cause = error.HttpNotOk, .copy = "TestSrc returned an error" },
        // Player-spawn classes (ROD-230): mpv missing vs crashed, distinct copy.
        .{ .cause = error.MpvNotFound, .copy = "mpv not found — install mpv" },
        .{ .cause = error.MpvFailed, .copy = "mpv exited with error" },
        // An unclassified cause (resolve produced no playable stream) keeps the
        // generic fallback — the residual after the two families above.
        .{ .cause = error.NoDirectStream, .copy = "playback failed" },
    };
    for (cases) |c| {
        var app: App = .{};
        app.gpa = testing.allocator;
        app.playing = true;

        // No observed position → a genuine non-completed failure that surfaces a
        // toast (the resolve path never produces a final position).
        try testTick(&app, .{ .play_error = .{ .final = null, .cause = c.cause } });

        const t = &app.toast_queue[0].?;
        try testing.expectEqual(Toast.Kind.@"error", t.kind);
        try testing.expectEqualStrings(c.copy, t.text[0..t.text_len]);
    }
}

test "playback for a different show than the detail pane does not advance it" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.episodes.results = try allocEpisodes(6);
    app.episodes.cursor = 2;
    // The detail pane moved to a different show while mpv was backgrounded.
    app.episodes.for_id = try testing.allocator.dupe(u8, "other-show");
    app.playing = true;
    app.session.anime_id = try testing.allocator.dupe(u8, "show1");
    app.session.episode_raw = try testing.allocator.dupe(u8, "3");
    app.session.episode_index = 3;

    try testTick(&app, .{ .play_done = null });

    try testing.expectEqual(@as(usize, 2), app.episodes.cursor); // detail pane untouched
    try testing.expectEqual(@as(u32, 0), app.episodes.progress);
    try testing.expect(app.toast_queue[0] == null);

    app.episodes.freeResults(app.gpa);
}

test "play_error on a different show still surfaces the failure toast" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.episodes.results = try allocEpisodes(6);
    app.episodes.cursor = 2;
    // The detail pane moved to a different show before mpv failed.
    app.episodes.for_id = try testing.allocator.dupe(u8, "other-show");
    app.playing = true;
    app.session.anime_id = try testing.allocator.dupe(u8, "show1");
    app.session.episode_raw = try testing.allocator.dupe(u8, "3");
    app.session.episode_index = 3;

    // No observed position → not counted: no advance/dim (and same_show is
    // false anyway), but the failure is still surfaced regardless of which show
    // the pane is on — the user deserves to know mpv died.
    try testTick(&app, .{ .play_error = .{ .final = null, .cause = error.MpvFailed } });

    try testing.expectEqual(@as(usize, 2), app.episodes.cursor); // unmoved
    try testing.expectEqual(@as(u32, 0), app.episodes.progress); // nothing dimmed
    const t = &app.toast_queue[0].?;
    try testing.expectEqual(Toast.Kind.@"error", t.kind);
    try testing.expectEqualStrings("mpv exited with error", t.text[0..t.text_len]);

    app.episodes.freeResults(app.gpa);
}

test "firePlay: double-play guard is a no-op when playing is true" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .detail;
    app.playing = true;

    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 1);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    app.episodes.results = eps;
    app.episodes.for_id = try std.testing.allocator.dupe(u8, "anime1");

    try testTick(&app, keyEv(vaxis.Key.enter, .{}));

    // Guard held — no thread spawned, playing still true.
    try testing.expect(app.play_thread == null);
    try testing.expect(app.playing);

    std.testing.allocator.free(app.episodes.for_id.?);
    std.testing.allocator.free(eps[0].raw);
    std.testing.allocator.free(eps);
}

test "history filter: reduces nav_len to matching entries only" {
    var hist = sampleHistory(); // Frieren, K-On!, Bebop
    var app: App = .{};
    app.history = &hist;
    app.active_view = .history;

    // No filter: all 3 entries visible.
    try testing.expectEqual(@as(usize, 3), app.filteredHistoryLen());

    // Filter "on" matches K-On! only.
    @memcpy(app.history_filter[0..2], "on");
    app.history_filter_len = 2;
    try testing.expectEqual(@as(usize, 1), app.filteredHistoryLen());

    // Filter "bop" matches Bebop only.
    @memcpy(app.history_filter[0..3], "bop");
    app.history_filter_len = 3;
    try testing.expectEqual(@as(usize, 1), app.filteredHistoryLen());

    // Filter "zzz" matches nothing.
    @memcpy(app.history_filter[0..3], "zzz");
    app.history_filter_len = 3;
    try testing.expectEqual(@as(usize, 0), app.filteredHistoryLen());
}

test "history filter: esc clears filter and resets cursor" {
    var hist = sampleHistory();
    var app: App = .{};
    app.history = &hist;
    app.active_view = .history;
    app.input_mode = .search;
    @memcpy(app.history_filter[0..5], "Frien");
    app.history_filter_len = 5;
    app.list_cursor = 2;
    app.list_top = 1;

    try testTick(&app, keyEv(vaxis.Key.escape, .{}));

    try testing.expectEqual(@as(usize, 0), app.history_filter_len);
    try testing.expectEqual(@as(usize, 0), app.list_cursor);
    try testing.expectEqual(@as(usize, 0), app.list_top);
    try testing.expectEqual(.normal, app.input_mode);
}

test "history 2-row scroll: scrollIntoView with visible/2 keeps cursor in view" {
    var hist = sampleHistory();
    var app: App = .{};
    app.history = &hist;
    app.active_view = .history;
    app.list_cursor = 2;
    app.list_top = 0;

    // visible = 4 terminal rows → 2 entry slots. Cursor at entry 2 must push list_top.
    app.scrollIntoView(4 / 2);
    try testing.expect(app.list_cursor >= app.list_top);
    try testing.expect(app.list_cursor < app.list_top + 2);
}

test "history 2-row scroll: scrollIntoView(0) does not corrupt list_top" {
    var hist = sampleHistory();
    var app: App = .{};
    app.history = &hist;
    app.active_view = .history;
    app.list_cursor = 1;
    app.list_top = 0;

    // Degenerate edge: visible=1 terminal row → visible/2=0 without the @max(1,…) guard.
    // scrollIntoView(0) would set list_top = cursor+1, skipping all entries. Confirm
    // that @max(1, visible/2) keeps list_top sane.
    app.scrollIntoView(@max(1, 1 / 2));
    try testing.expect(app.list_top <= app.list_cursor);
}

// ── Settings tab (ROD-86) ───────────────────────────────────────────────────

test "settings: l/h cycle a preset field and wrap around" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings.cursor = 1; // default_quality, defaults to "best"

    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqualStrings("worst", app.config.default_quality); // best (last) wraps forward to worst (first)
    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqualStrings("480", app.config.default_quality); // worst -> 480
    try testTick(&app, keyEv('h', .{}));
    try testing.expectEqualStrings("worst", app.config.default_quality); // back 480 -> worst
    try testTick(&app, keyEv('h', .{}));
    try testing.expectEqualStrings("best", app.config.default_quality); // wrap back worst -> best
}

test "settings: translation cycle keeps live translation in sync" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings.cursor = 2; // translation, defaults to "sub"

    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqualStrings("dub", app.config.translation);
    try testing.expectEqual(domain.Translation.dub, app.translation);
}

test "settings: palette cycle re-points the live app palette" {
    // Guards the `config_changed` → palette re-sync the controller now owns
    // (the old code set app.palette inside settingsCycle; ROD-161 moved the
    // projection out). Without this, a broken re-sync would leave the live
    // palette stale until restart and no test would notice.
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings.cursor = 7; // palette, defaults to "terminal_ghost"
    try testing.expectEqual(&colors.terminal_ghost, app.palette);

    try testTick(&app, keyEv('l', .{})); // terminal_ghost -> phosphor
    try testing.expectEqualStrings("phosphor", app.config.palette);
    try testing.expectEqual(&colors.phosphor, app.palette);

    try testTick(&app, keyEv('l', .{})); // phosphor -> nord
    try testing.expectEqualStrings("nord", app.config.palette);
    try testing.expectEqual(&colors.nord, app.palette);

    try testTick(&app, keyEv('l', .{})); // nord -> tokyonight
    try testing.expectEqualStrings("tokyonight", app.config.palette);
    try testing.expectEqual(&colors.tokyonight, app.palette);

    try testTick(&app, keyEv('l', .{})); // tokyonight -> terminal_ghost (wrap)
    try testing.expectEqualStrings("terminal_ghost", app.config.palette);
    try testing.expectEqual(&colors.terminal_ghost, app.palette);
}

test "settings: landing cycle steps through all three startup-view presets and wraps" {
    // ROD-229 made resume-landing real, so "last_watched" is back in the cycle.
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings.cursor = app_mod.settings_row_count - 1; // landing view (last row)
    try testing.expectEqualStrings("history", app.config.landing);

    try testTick(&app, keyEv('l', .{})); // history -> browse
    try testing.expectEqualStrings("browse", app.config.landing);

    try testTick(&app, keyEv('l', .{})); // browse -> last_watched
    try testing.expectEqualStrings("last_watched", app.config.landing);

    try testTick(&app, keyEv('l', .{})); // last_watched -> history (forward wrap)
    try testing.expectEqualStrings("history", app.config.landing);

    try testTick(&app, keyEv('h', .{})); // history -> last_watched (reverse wrap)
    try testing.expectEqualStrings("last_watched", app.config.landing);

    try testing.expect(app.settings.dirty);
}

test "settings: space toggles a bool field" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings.cursor = 5; // cover_art, defaults to true

    try testTick(&app, keyEv(vaxis.Key.space, .{}));
    try testing.expect(!app.config.cover_art);
    try testTick(&app, keyEv(vaxis.Key.space, .{}));
    try testing.expect(app.config.cover_art);
}

test "settings: enter edits mpv_path; type+confirm commits, esc cancels" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings.cursor = 0; // mpv_path, defaults to "mpv"

    try testTick(&app, keyEv(vaxis.Key.enter, .{})); // begin edit (buffer seeded "mpv")
    try testing.expect(app.settings.editing);
    try testTick(&app, .{ .key_press = .{ .codepoint = '2', .text = "2" } }); // -> "mpv2"
    try testTick(&app, keyEv(vaxis.Key.enter, .{})); // commit
    try testing.expect(!app.settings.editing);
    try testing.expectEqualStrings("mpv2", app.config.mpv_path);

    // Esc discards the in-progress edit, leaving the committed value intact.
    try testTick(&app, keyEv(vaxis.Key.enter, .{}));
    try testTick(&app, .{ .key_press = .{ .codepoint = 'Z', .text = "Z" } });
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expect(!app.settings.editing);
    try testing.expectEqualStrings("mpv2", app.config.mpv_path);
}

test "settings: empty edit buffer never commits a blank mpv_path" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings.cursor = 0;

    try testTick(&app, keyEv(vaxis.Key.enter, .{})); // buffer = "mpv"
    try testTick(&app, keyEv(vaxis.Key.backspace, .{}));
    try testTick(&app, keyEv(vaxis.Key.backspace, .{}));
    try testTick(&app, keyEv(vaxis.Key.backspace, .{})); // buffer now empty
    try testTick(&app, keyEv(vaxis.Key.enter, .{})); // commit no-op
    try testing.expectEqualStrings("mpv", app.config.mpv_path);
}

test "settings: j/k navigation clamps to the interactive rows" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings.cursor = 0;

    try testTick(&app, keyEv('k', .{})); // already at top — stays
    try testing.expectEqual(@as(usize, 0), app.settings.cursor);

    var n: usize = 0;
    while (n < 20) : (n += 1) try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, app_mod.settings_row_count - 1), app.settings.cursor);
}

test "settings: q with a dirty tab and no config path warns, then quits (ROD-210)" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.config_path = null;

    // Make a real change so the tab is dirty (space toggles cover_art).
    app.settings.cursor = 5; // cover_art toggle row
    try testTick(&app, keyEv(vaxis.Key.space, .{}));
    try testing.expect(app.settings.dirty);

    // q persists on the way out; with no config dir the save warns instead of
    // writing — then the app quits regardless (ROD-210).
    try testTick(&app, keyEv('q', .{}));
    try testing.expect(app.should_quit);
    try testing.expectEqual(.settings, app.active_view);
    const t = app.toast_queue[0] orelse return error.TestExpectationFailed;
    try testing.expectEqual(Toast.Kind.warn, t.kind);
}

test "settings: cycling an out-of-preset value snaps to a valid preset" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings.cursor = 3; // resume_offset; presets {0,3,5,10,15,30}
    app.config.resume_offset_sec = 7; // not a preset (e.g. a hand-edited file)

    try testTick(&app, keyEv('l', .{}));
    // An unrecognized value starts from index 0, so 'l' lands on the second
    // preset — never panics, always snaps back onto a valid value.
    try testing.expectEqual(@as(u32, 3), app.config.resume_offset_sec);
}

// ── Save-to-disk round-trip (verification harness) ───────────────────────────
// These exercise the disk-write path the state-machine tests above can't reach
// (they only cover the null-path branch). Kept as permanent coverage.

const config_mod = @import("../config.zig");

test "settings save round-trip — q writes file, load reads back mutations" {
    const alloc = testing.allocator;

    // Create a temp dir and derive an absolute config path inside it.
    // tmpDir places its directory at .zig-cache/tmp/<hash>/ relative to cwd.
    // We get cwd via std.c.getcwd to construct an absolute path.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
    const cwd_str = std.mem.sliceTo(&cwd_buf, 0);

    // tmpDir sub_path is a base64-encoded random string stored in tmp_dir.sub_path
    const config_path = try std.fmt.allocPrint(alloc, "{s}/.zig-cache/tmp/{s}/config.zon", .{
        cwd_str,
        tmp_dir.sub_path,
    });
    defer alloc.free(config_path);

    // Build an App with a real config_path and several mutated config fields.
    var app: App = .{};
    app.gpa = alloc;
    app.active_view = .settings;
    app.config_path = config_path;

    // Mutate cycle/toggle fields directly — these mirror what h/l/space do.
    app.config.translation = "dub";
    app.config.cover_art = false;
    app.config.default_quality = "720";
    app.config.resume_offset_sec = 10;

    // Drive mpv_path edit through the full UI path: enter → backspace×3 → type → enter.
    app.settings.cursor = 0; // mpv_path row
    try testTick(&app, keyEv(vaxis.Key.enter, .{})); // seeds buffer with "mpv"
    try testTick(&app, keyEv(vaxis.Key.backspace, .{})); // "mp"
    try testTick(&app, keyEv(vaxis.Key.backspace, .{})); // "m"
    try testTick(&app, keyEv(vaxis.Key.backspace, .{})); // ""
    // Type "/alt/mpv" character by character.
    inline for ("/alt/mpv") |ch| {
        try testTick(&app, .{ .key_press = .{ .codepoint = ch, .text = &[_]u8{ch} } });
    }
    try testTick(&app, keyEv(vaxis.Key.enter, .{})); // commit

    try testing.expectEqualStrings("/alt/mpv", app.config.mpv_path);

    // Drive q — leaveSettings sees the dirty tab and calls saveSettings →
    // config_mod.save(), then the app quits (ROD-210).
    try testTick(&app, keyEv('q', .{}));

    // 1. q quit in place — it no longer routes to Browse.
    try testing.expect(app.should_quit);
    try testing.expectEqual(.settings, app.active_view);

    // 2. Toast is .success, not .warn (no-path) or .error (write fail).
    const t = app.toast_queue[0] orelse return error.TestExpectationFailed;
    try testing.expectEqual(Toast.Kind.success, t.kind);

    // 3. File actually exists on disk.
    {
        const f = try std.Io.Dir.openFileAbsolute(testing.io, config_path, .{});
        f.close(testing.io);
    }

    // 4. Load it back and confirm all mutated fields round-tripped.
    var load_arena = std.heap.ArenaAllocator.init(alloc);
    defer load_arena.deinit();
    const loaded = config_mod.load(load_arena.allocator(), testing.io, config_path);

    try testing.expectEqualStrings("dub", loaded.translation);
    try testing.expect(!loaded.cover_art);
    try testing.expectEqualStrings("720", loaded.default_quality);
    try testing.expectEqual(@as(u32, 10), loaded.resume_offset_sec);
    try testing.expectEqualStrings("/alt/mpv", loaded.mpv_path);
}

test "F1/F2/H from a dirty Settings tab persist on the way out (ROD-210 H1)" {
    // Acceptance criterion 2: "switching away via F-key persists settings." With
    // a null config path the save can't write, but the warn toast proves
    // leaveSettings (hence saveSettings) ran — i.e. all three call-sites are
    // wired. Guards against a dropped leaveSettings() on any of F1/F2/H.
    inline for (.{ vaxis.Key.f1, vaxis.Key.f2, 'H' }) |k| {
        var app: App = .{};
        app.gpa = testing.allocator;
        app.active_view = .settings;
        app.config_path = null;
        app.settings.cursor = 5; // cover_art toggle row
        try testTick(&app, keyEv(vaxis.Key.space, .{})); // dirty the tab
        try testing.expect(app.settings.dirty);

        try testTick(&app, keyEv(k, .{}));
        try testing.expect(app.active_view != .settings); // switched away
        const t = app.toast_queue[0] orelse return error.TestExpectationFailed;
        try testing.expectEqual(Toast.Kind.warn, t.kind); // save was attempted
    }
}

test "Ctrl-C from a dirty Settings tab saves before quitting (ROD-210 M2)" {
    const alloc = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
    const cwd_str = std.mem.sliceTo(&cwd_buf, 0);
    const config_path = try std.fmt.allocPrint(alloc, "{s}/.zig-cache/tmp/{s}/config.zon", .{
        cwd_str,
        tmp_dir.sub_path,
    });
    defer alloc.free(config_path);

    var app: App = .{};
    app.gpa = alloc;
    app.active_view = .settings;
    app.config_path = config_path;
    app.settings.cursor = 5; // cover_art toggle (default true → false)
    try testTick(&app, keyEv(vaxis.Key.space, .{}));
    try testing.expect(app.settings.dirty);

    // Ctrl-C persists the dirty tab before the hard quit (ROD-210 — leaveSettings
    // on the Ctrl-C arm), then sets should_quit.
    try testTick(&app, keyEv('c', .{ .ctrl = true }));
    try testing.expect(app.should_quit);
    const t = app.toast_queue[0] orelse return error.TestExpectationFailed;
    try testing.expectEqual(Toast.Kind.success, t.kind);

    // File written and the toggle round-tripped to disk.
    var load_arena = std.heap.ArenaAllocator.init(alloc);
    defer load_arena.deinit();
    const loaded = config_mod.load(load_arena.allocator(), testing.io, config_path);
    try testing.expect(!loaded.cover_art);
}

test "entering settings resets cursor, editing state, and input_mode" {
    var app: App = .{};
    app.gpa = testing.allocator;
    // Dirty state from a prior visit.
    app.settings.cursor = 5;
    app.settings.editing = true;
    app.input_mode = .search;
    app.active_view = .browse;

    // F3 switches to settings — the onKey F3 handler resets these.
    try testTick(&app, keyEv(vaxis.Key.f3, .{}));
    try testing.expectEqual(.settings, app.active_view);
    try testing.expectEqual(@as(usize, 0), app.settings.cursor);
    try testing.expect(!app.settings.editing);
    try testing.expectEqual(.normal, app.input_mode);
}

test "Esc from settings is a no-op and never saves (ROD-210)" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    // config_path is null — if save were called, it would push a warn toast.
    app.config_path = null;

    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    // ROD-210: Esc peels transient layers only; over the Settings list it does
    // nothing (the old jump to Browse is gone).
    try testing.expectEqual(.settings, app.active_view);
    // No toast means save was NOT called.
    try testing.expect(app.toast_queue[0] == null);
}

test "edit mode swallows F-keys — cannot switch views mid-edit" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings.cursor = 0; // mpv_path

    try testTick(&app, keyEv(vaxis.Key.enter, .{})); // enter edit mode
    try testing.expect(app.settings.editing);

    // F1 while editing must be swallowed — stay on settings, still editing.
    try testTick(&app, keyEv(vaxis.Key.f1, .{}));
    try testing.expectEqual(.settings, app.active_view);
    try testing.expect(app.settings.editing);

    // Esc exits edit mode, stays on settings.
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expect(!app.settings.editing);
    try testing.expectEqual(.settings, app.active_view);
}

test "settings: Ctrl-C hard-quits even while editing a text field" {
    // The Ctrl-C emergency quit must work from anywhere, including the modal
    // mpv_path edit field (SettingsState.editKey lets Ctrl-C fall through).
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings.cursor = 0;

    try testTick(&app, keyEv(vaxis.Key.enter, .{})); // enter edit mode
    try testing.expect(app.settings.editing);

    try testTick(&app, keyEv('c', .{ .ctrl = true }));
    try testing.expect(app.should_quit);
}

// ── cover fetch/suppress/retry decision (ROD-110) ────────────────────────────
// `CoverState.Decision.eval` is the pure core of `CoverState.sync`: it decides
// whether to fetch, suppress (cooldown), leave an in-flight/loaded cover alone,
// clear stale state, or do nothing — with no threads or `builtin.is_test` guards.

const cooldown_ms = app_mod.CoverState.retry_cooldown_ms;

fn coverBase() CoverDecision {
    return .{
        .target_id = "a1",
        .target_url = "http://x/a1.jpg",
        .cover_for_id = null,
        .cover_loading = false,
        .has_pixels = false,
        .failed_id = null,
        .failed_url = null,
        .failed_at_ms = 0,
        .now_ms = 100_000,
    };
}

test "cover decision: no target id → none" {
    var d = coverBase();
    d.target_id = null;
    try testing.expectEqual(.none, d.eval());
}

test "cover decision: fresh selection with art → fetch" {
    try testing.expectEqual(.fetch, coverBase().eval());
}

test "cover decision: no art, stale state for another id → clear" {
    var d = coverBase();
    d.target_url = null;
    d.cover_for_id = "other";
    try testing.expectEqual(.clear, d.eval());
}

test "cover decision: no art, no stale state → none" {
    var d = coverBase();
    d.target_url = null;
    d.cover_for_id = "a1"; // same id, nothing to drop
    try testing.expectEqual(.none, d.eval());
}

test "cover decision: already loading this id → up_to_date" {
    var d = coverBase();
    d.cover_for_id = "a1";
    d.cover_loading = true;
    try testing.expectEqual(.up_to_date, d.eval());
}

test "cover decision: pixels already held for this id → up_to_date" {
    var d = coverBase();
    d.cover_for_id = "a1";
    d.has_pixels = true;
    try testing.expectEqual(.up_to_date, d.eval());
}

test "cover decision: recent same-id+url failure within cooldown → suppress" {
    var d = coverBase();
    d.failed_id = "a1";
    d.failed_url = "http://x/a1.jpg";
    d.failed_at_ms = d.now_ms - (cooldown_ms - 1);
    try testing.expectEqual(.suppress, d.eval());
}

test "cover decision: same-id+url failure past cooldown → fetch (auto-retry)" {
    var d = coverBase();
    d.failed_id = "a1";
    d.failed_url = "http://x/a1.jpg";
    d.failed_at_ms = d.now_ms - (cooldown_ms + 1);
    try testing.expectEqual(.fetch, d.eval());
}

test "cover decision: failure but thumb url changed → fetch (recovery)" {
    var d = coverBase();
    d.target_url = "http://x/a1-v2.jpg"; // enrichment swapped the art
    d.failed_id = "a1";
    d.failed_url = "http://x/a1.jpg";
    d.failed_at_ms = d.now_ms - 1; // still inside cooldown, but url differs
    try testing.expectEqual(.fetch, d.eval());
}

test "cover decision: failure recorded for a different id does not suppress" {
    var d = coverBase();
    d.failed_id = "other";
    d.failed_url = "http://x/other.jpg";
    d.failed_at_ms = d.now_ms;
    try testing.expectEqual(.fetch, d.eval());
}

test "cover decision: failure with null url (OOM dupe) does not suppress" {
    // noteFailure stores null when the url dupe OOMs; without a url to
    // compare we can't be sure it's the same fetch, so we retry rather than
    // suppress silently.
    var d = coverBase();
    d.failed_id = "a1";
    d.failed_url = null;
    d.failed_at_ms = d.now_ms;
    try testing.expectEqual(.fetch, d.eval());
}

test "cover decision: live pixels win over a stale same-id failure record" {
    // Defensive: even if a failure record and live pixels coexist for one id,
    // up_to_date must beat suppress so we never blank a good cover.
    var d = coverBase();
    d.cover_for_id = "a1";
    d.has_pixels = true;
    d.failed_id = "a1";
    d.failed_url = "http://x/a1.jpg";
    d.failed_at_ms = d.now_ms;
    try testing.expectEqual(.up_to_date, d.eval());
}

// ── half-block letterbox fit (ROD-110) ───────────────────────────────────────
// `halfBlockFit` letterboxes an image into a cols × rows*2 half-pixel grid,
// aspect-correct using the terminal's pixels-per-cell metrics.

const halfBlockFit = app_mod.CoverState.halfBlockFit;

test "halfBlockFit: square cells (2:1) match the square-half-pixel assumption" {
    // 8x16 cells → pph == 2*ppc → half-pixels are square → metric path and the
    // ppc/pph==0 fallback must agree exactly.
    const portrait_metric = halfBlockFit(225, 319, 20, 30, 8, 16);
    const portrait_square = halfBlockFit(225, 319, 20, 30, 0, 0);
    try testing.expectEqual(portrait_square.w, portrait_metric.w);
    try testing.expectEqual(portrait_square.h, portrait_metric.h);
}

test "halfBlockFit: poster letterboxes within the grid, centered" {
    // 225x319 (aspect 0.705) is slightly wider than the 20x30 square-half-pixel
    // grid (0.667), so it's width-bound: fills width, narrows height, with
    // vertical letterbox bars.
    const fit = halfBlockFit(225, 319, 20, 30, 8, 16);
    try testing.expectEqual(@as(u32, 20), fit.w);
    try testing.expect(fit.h < 30);
    try testing.expectEqual(@as(u32, 0), fit.off_x);
    try testing.expect(fit.off_y > 0); // centered vertically
}

test "halfBlockFit: non-2:1 cells correct aspect vs the naive square fit" {
    // gnome-terminal 8x18 cells: a half-pixel is 8 wide x 9 tall (taller than
    // square). The naive square fit over-allocates height (squishes the poster
    // tall/narrow); the metric fit uses fewer half-rows to keep aspect true.
    const square = halfBlockFit(225, 319, 20, 30, 0, 0); // → 20 x 28
    const corrected = halfBlockFit(225, 319, 20, 30, 8, 18); // → 20 x 25
    try testing.expect(corrected.h < square.h);
}

test "halfBlockFit: degenerate inputs clamp to the grid" {
    const fit = halfBlockFit(0, 0, 20, 30, 8, 16);
    try testing.expectEqual(@as(u32, 20), fit.w);
    try testing.expectEqual(@as(u32, 30), fit.h);
}

test "ROD-238: drainTtyResponses sweeps buffered bytes and leaves the fd non-blocking" {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.SkipZigTest;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    // Stand in for a stray terminal response left in the tty queue at quit.
    const msg = "\x1b_Gi=1;OK\x1b\\";
    _ = std.c.write(fds[1], msg, msg.len);

    app_mod.drainTtyResponses(fds[0]);

    // Swept: the buffer is empty. The drain left the read end non-blocking, so a
    // further read reports WouldBlock instead of hanging (write end still open) —
    // proof it can never wedge the quit path on a drained fd.
    var buf: [32]u8 = undefined;
    try testing.expectError(error.WouldBlock, std.posix.read(fds[0], &buf));
}

test "ROD-179: a superseded episode prefetch is abandoned, not joined" {
    var gate: GateProvider = .{};
    const provider = gate.provider();

    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory(); // [a (Frieren), b (K-On!), c (Bebop)]
    app.setHistory(&recs);
    app.term_cols = 120; // zoom tier: Enter on a history row fires the async fetch

    var loop = initTestLoop();
    const io = std.testing.io;

    // Fire show "a" (cursor 0). No cache entry ⇒ async path ⇒ worker A spawns and
    // parks on the gate, standing in for a slow in-flight network fetch.
    app.active_view = .history;
    app.active_pane = .list;
    app.list_cursor = 0;
    try app.tick(keyEv(vaxis.Key.enter, .{}), &loop, io, provider);
    try testing.expectEqual(@as(usize, 1), app.episode_drain.inflight.load(.acquire));
    try testing.expect(app.episodes.loading);
    try testing.expectEqualStrings("a", app.episodes.for_id.?);

    // Supersede: back to the list, select "b", fire again — while A is still parked.
    // The pre-ROD-179 code joined the prior worker right here; with A wedged on the
    // gate that join would deadlock forever. This tick *returning at all* is the
    // proof the join is gone — the stale fetch is abandoned, not awaited.
    app.active_view = .history;
    app.active_pane = .list;
    app.list_cursor = 1;
    try app.tick(keyEv(vaxis.Key.enter, .{}), &loop, io, provider);
    try testing.expectEqual(@as(usize, 2), app.episode_drain.inflight.load(.acquire));
    try testing.expectEqualStrings("b", app.episodes.for_id.?);

    // Release and reap. drain() returns only once BOTH detached workers (stale A +
    // current B) have finished — the teardown barrier waits them all out.
    gate.release.store(true, .release);
    app.episode_drain.drain();
    try testing.expectEqual(@as(usize, 0), app.episode_drain.inflight.load(.acquire));

    // We drove tick directly, so both workers' episodes_done events sit unread on
    // the queue — drain + free them (A's is the stale one a live handler would
    // keep-check away; here we just reclaim both). Join any cover worker the detail
    // entry may have spawned so nothing outlives the loop frame.
    while (loop.queue.tryPop() catch null) |ev| freeTestEvent(app.gpa, ev);
    app.cover.joinThread();
    app.episodes.freeResults(app.gpa);
}
