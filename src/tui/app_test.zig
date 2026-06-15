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

const Allocator = std.mem.Allocator;
const testing = std.testing;
const AnimeRecord = store_mod.AnimeRecord;
const SourceProvider = source_mod.SourceProvider;
const Anime = domain.Anime;
const App = app_mod.App;
const Toast = app_mod.Toast;
const CoverDecision = app_mod.CoverDecision;
const Event = event_mod.Event;
const Loop = event_mod.Loop;
const formatMeta = @import("render.zig").formatMeta;
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
fn dummyResolveFn(_: *anyopaque, _: Allocator, _: std.Io, _: []const u8, _: domain.EpisodeNumber, _: domain.Translation) anyerror!domain.StreamLink {
    return .{ .url = "" };
}

fn dummyNameFn(_: *anyopaque) []const u8 {
    return "allanime";
}

const dummy_vtable: SourceProvider.VTable = .{
    .name = dummyNameFn,
    .search = dummySearchFn,
    .episodes = dummyEpisodesFn,
    .resolve = dummyResolveFn,
};

fn dummyProvider() SourceProvider {
    return .{ .ptr = undefined, .vtable = &dummy_vtable };
}

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
    if (app.episode_thread) |t| {
        t.join();
        app.episode_thread = null;
    }
    if (app.search_thread) |t| {
        t.join();
        app.search_thread = null;
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
        .cover_done => |d| {
            alloc.free(d.rgba);
            alloc.free(d.for_id);
        },
        .cover_error => |id| alloc.free(id),
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

test "formatMeta degrades when total episodes is unknown" {
    var buf: [48]u8 = undefined;
    const known = formatMeta(&buf, .{ .source = "s", .source_id = "i", .title = "T", .total_episodes = 12, .progress = 3, .list_status = "watching" });
    try testing.expectEqualStrings("ep 3/12 · watching", known);
    var buf2: [48]u8 = undefined;
    const unknown = formatMeta(&buf2, .{ .source = "s", .source_id = "i", .title = "T", .progress = 0, .list_status = "planning" });
    try testing.expectEqualStrings("ep 0 · planning", unknown);
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

test "q from history returns to browse without quitting" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    try testing.expect(!app.should_quit);
    try testTick(&app, keyEv('q', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
    try testing.expect(!app.should_quit);
}

test "q from settings returns to browse without quitting" {
    var app: App = .{};
    app.active_view = .settings;
    try testing.expect(!app.should_quit);
    try testTick(&app, keyEv('q', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
    try testing.expect(!app.should_quit);
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

test "Esc from history returns to browse" {
    var app: App = .{};
    app.active_view = .history;
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
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
    // l requires a selected result.
    try app.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "x"),
        .name = try std.testing.allocator.dupe(u8, "X"),
    });
    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .detail), app.active_pane);
    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
    app.freeEpisodeResults();
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

test "browse list pane detail render info uses selected anime" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .list;
    try app.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.results.appendAssumeCapacity(.{
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

    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
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

test "Enter in history opens standalone detail view" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;

    try testTick(&app, keyEv(vaxis.Key.enter, .{}));
    try testing.expectEqual(.detail, app.active_view);
    try testing.expectEqual(.history, app.detail_origin);
    try testing.expectEqual(.detail, app.active_pane);
    try testing.expectEqualStrings("a", app.detail_for_id orelse return error.TestExpectationFailed);

    app.freeEpisodeResults();
}

test "q from history-opened detail returns to history" {
    var app: App = .{};
    app.active_view = .detail;
    app.detail_origin = .history;
    app.active_pane = .detail;

    try testTick(&app, keyEv('q', .{}));
    try testing.expectEqual(.history, app.active_view);
    try testing.expectEqual(.list, app.active_pane);
    try testing.expect(!app.should_quit);
}

test "Esc from history-opened detail returns to history" {
    var app: App = .{};
    app.active_view = .detail;
    app.detail_origin = .history;
    app.active_pane = .detail;

    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expectEqual(.history, app.active_view);
    try testing.expectEqual(.list, app.active_pane);
    try testing.expect(!app.should_quit);
}

test "h from history-opened detail returns to history" {
    var app: App = .{};
    app.active_view = .detail;
    app.detail_origin = .history;
    app.active_pane = .detail;

    try testTick(&app, keyEv('h', .{}));
    try testing.expectEqual(.history, app.active_view);
    try testing.expectEqual(.list, app.active_pane);
    try testing.expect(!app.should_quit);
}

test "history detail episodes_done seeds cursor from progress" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .detail;
    app.detail_origin = .history;
    app.active_pane = .detail;
    app.detail_for_id = try std.testing.allocator.dupe(u8, "a");
    app.episode_loading = true;

    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 6);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    eps[1] = .{ .raw = try std.testing.allocator.dupe(u8, "2") };
    eps[2] = .{ .raw = try std.testing.allocator.dupe(u8, "3") };
    eps[3] = .{ .raw = try std.testing.allocator.dupe(u8, "4") };
    eps[4] = .{ .raw = try std.testing.allocator.dupe(u8, "5") };
    eps[5] = .{ .raw = try std.testing.allocator.dupe(u8, "6") };
    const for_id = try std.testing.allocator.dupe(u8, "a");

    try testTick(&app, .{ .episodes_done = .{ .episodes = eps, .for_id = for_id } });
    try testing.expectEqual(@as(usize, 4), app.episode_cursor);

    app.freeEpisodeResults();
}

test "history detail resume overrides next-episode cursor" {
    var store = try store_mod.Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "resume-show", .title = "Resume Show", .progress = 3 }, 1000);
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
    app.detail_for_id = try std.testing.allocator.dupe(u8, "resume-show");
    app.episode_loading = true;

    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 6);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    eps[1] = .{ .raw = try std.testing.allocator.dupe(u8, "2") };
    eps[2] = .{ .raw = try std.testing.allocator.dupe(u8, "3") };
    eps[3] = .{ .raw = try std.testing.allocator.dupe(u8, "4") };
    eps[4] = .{ .raw = try std.testing.allocator.dupe(u8, "5") };
    eps[5] = .{ .raw = try std.testing.allocator.dupe(u8, "6") };
    const for_id = try std.testing.allocator.dupe(u8, "resume-show");

    try testTick(&app, .{ .episodes_done = .{ .episodes = eps, .for_id = for_id } });
    try testing.expectEqual(@as(usize, 2), app.episode_cursor);

    app.freeEpisodeResults();
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
    app.detail_for_id = try std.testing.allocator.dupe(u8, "done");
    app.episode_loading = true;

    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 4);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    eps[1] = .{ .raw = try std.testing.allocator.dupe(u8, "2") };
    eps[2] = .{ .raw = try std.testing.allocator.dupe(u8, "3") };
    eps[3] = .{ .raw = try std.testing.allocator.dupe(u8, "4") };
    const for_id = try std.testing.allocator.dupe(u8, "done");

    try testTick(&app, .{ .episodes_done = .{ .episodes = eps, .for_id = for_id } });
    try testing.expectEqual(@as(usize, 0), app.episode_cursor);

    app.freeEpisodeResults();
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
    app.search_len = 5;
    @memcpy(app.search_query[0..5], "hello");
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expectEqual(.normal, app.input_mode);
    try testing.expectEqual(@as(usize, 0), app.search_len);
}

test "search mode: Enter locks results and returns to normal" {
    var app: App = .{};
    app.active_view = .browse;
    app.input_mode = .search;
    app.search_len = 5;
    @memcpy(app.search_query[0..5], "hello");
    try testTick(&app, keyEv(vaxis.Key.enter, .{}));
    try testing.expectEqual(.normal, app.input_mode);
    try testing.expectEqual(@as(usize, 5), app.search_len); // query preserved
}

test "search_done page 1 populates results" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.search_len = 7;
    @memcpy(app.search_query[0..7], "frieren");

    const query_copy = try std.testing.allocator.dupe(u8, "frieren");
    const results_backing = try std.testing.allocator.alloc(Anime, 1);
    results_backing[0] = .{
        .id = try std.testing.allocator.dupe(u8, "abc123"),
        .name = try std.testing.allocator.dupe(u8, "Frieren"),
        .eps_sub = 28,
    };

    try testTick(&app, .{ .search_done = .{ .results = results_backing, .for_query = query_copy, .page = 1 } });
    try testing.expectEqual(@as(usize, 1), app.results.items.len);
    try testing.expectEqualStrings("Frieren", app.results.items[0].name);
    try testing.expectEqual(@as(u32, 1), app.search_page);
    try testing.expect(!app.search_loading);

    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
}

test "search_done stale result is discarded" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    // Current query is "frieren"; incoming result is for "bebop" — stale.
    app.search_len = 7;
    @memcpy(app.search_query[0..7], "frieren");

    const query_copy = try std.testing.allocator.dupe(u8, "bebop");
    const results_backing = try std.testing.allocator.alloc(Anime, 1);
    results_backing[0] = .{
        .id = try std.testing.allocator.dupe(u8, "xyz789"),
        .name = try std.testing.allocator.dupe(u8, "Bebop"),
        .eps_sub = 26,
    };

    try testTick(&app, .{ .search_done = .{ .results = results_backing, .for_query = query_copy, .page = 1 } });
    // All stale data freed by tick — results untouched.
    try testing.expectEqual(@as(usize, 0), app.results.items.len);
    try testing.expectEqual(@as(u32, 0), app.search_page);

    app.results.deinit(std.testing.allocator); // capacity is 0; safe no-op
}

test "search_done page 2 appends to existing results" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.search_len = 4;
    @memcpy(app.search_query[0..4], "test");
    app.search_page = 1;

    // Seed a page-1 result directly.
    try app.results.ensureTotalCapacity(std.testing.allocator, 2);
    app.results.appendAssumeCapacity(.{
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
    try testing.expectEqual(@as(usize, 2), app.results.items.len);
    try testing.expectEqual(@as(u32, 2), app.search_page);
    try testing.expectEqualStrings("Show One", app.results.items[0].name);
    try testing.expectEqualStrings("Show Two", app.results.items[1].name);

    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
}

test "search_enriched merges metadata into matching live result" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.search_len = 7;
    @memcpy(app.search_query[0..7], "frieren");

    try app.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.results.appendAssumeCapacity(.{
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
    try testing.expectEqual(@as(?u64, 154587), app.results.items[0].anilist_id);
    try testing.expectEqual(@as(?u32, 91), app.results.items[0].score);
    try testing.expectEqualStrings("Elf mage grief hour", app.results.items[0].description orelse "");

    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
}

test "browse j/k navigates results list" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.search_page = 1;

    try app.results.ensureTotalCapacity(std.testing.allocator, 3);
    for (0..3) |_| {
        app.results.appendAssumeCapacity(.{
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

    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
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
    app.episode_results = eps;
    app.episode_cursor = 0;

    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 1), app.episode_cursor);
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 2), app.episode_cursor);
    try testTick(&app, keyEv('j', .{})); // pinned at last
    try testing.expectEqual(@as(usize, 2), app.episode_cursor);
    try testTick(&app, keyEv('k', .{}));
    try testing.expectEqual(@as(usize, 1), app.episode_cursor);
    try testTick(&app, keyEv('g', .{}));
    try testing.expectEqual(@as(usize, 0), app.episode_cursor);
    try testTick(&app, keyEv('G', .{}));
    try testing.expectEqual(@as(usize, 2), app.episode_cursor);

    app.freeEpisodeResults();
}

test "episodes_done populates episode_results" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    const for_id = try std.testing.allocator.dupe(u8, "anime1");
    app.detail_for_id = try std.testing.allocator.dupe(u8, "anime1");
    app.episode_loading = true;

    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 2);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    eps[1] = .{ .raw = try std.testing.allocator.dupe(u8, "2") };

    try testTick(&app, .{ .episodes_done = .{ .episodes = eps, .for_id = for_id } });
    try testing.expect(!app.episode_loading);
    try testing.expectEqual(@as(usize, 2), app.episode_results.?.len);

    app.freeEpisodeResults();
}

test "episodes_done stale result is discarded" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    // Current show: "anime2"; incoming event is for "anime1" — stale.
    app.detail_for_id = try std.testing.allocator.dupe(u8, "anime2");
    app.episode_loading = true;

    const stale_id = try std.testing.allocator.dupe(u8, "anime1");
    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 1);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };

    try testTick(&app, .{ .episodes_done = .{ .episodes = eps, .for_id = stale_id } });
    // Still loading (wasn't cleared by stale event), episode_results still null.
    try testing.expect(app.episode_loading);
    try testing.expect(app.episode_results == null);

    // Cleanup detail_for_id manually.
    if (app.detail_for_id) |id| {
        std.testing.allocator.free(id);
        app.detail_for_id = null;
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
    try app.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "anime1"),
        .name = try std.testing.allocator.dupe(u8, "Frieren"),
        .thumb = try std.testing.allocator.dupe(u8, "https://img.anili.st/frieren.jpg"),
        .eps_sub = 28,
    });
    app.cover_for_id = try std.testing.allocator.dupe(u8, "anime1");
    app.cover_loading = true;

    const rgba = try std.testing.allocator.dupe(u8, &[_]u8{ 0xaa, 0xbb, 0xcc, 0xff });
    const for_id = try std.testing.allocator.dupe(u8, "anime1");

    try testTick(&app, .{ .cover_done = .{ .rgba = rgba, .width = 1, .height = 1, .for_id = for_id } });
    try testing.expect(!app.cover_loading);
    try testing.expect(app.cover_pixels != null);
    try testing.expectEqual(@as(u32, 1), app.cover_pixels.?.w);

    app.clearCoverState();
    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
}

test "cover_done stale result is discarded" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .detail;
    try app.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "anime2"),
        .name = try std.testing.allocator.dupe(u8, "Bebop"),
        .thumb = try std.testing.allocator.dupe(u8, "https://img.anili.st/bebop.jpg"),
        .eps_sub = 26,
    });
    app.cover_for_id = try std.testing.allocator.dupe(u8, "anime2");
    app.cover_loading = true;

    const rgba = try std.testing.allocator.dupe(u8, &[_]u8{ 0xaa, 0xbb, 0xcc, 0xff });
    const for_id = try std.testing.allocator.dupe(u8, "anime1");

    try testTick(&app, .{ .cover_done = .{ .rgba = rgba, .width = 1, .height = 1, .for_id = for_id } });
    try testing.expect(app.cover_pixels == null);
    try testing.expect(app.cover_loading);

    app.clearCoverState();
    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
}

test "cover_done while not in detail clears stale loading state" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .list;
    try app.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "anime1"),
        .name = try std.testing.allocator.dupe(u8, "Frieren"),
        .thumb = try std.testing.allocator.dupe(u8, "https://img.anili.st/frieren.jpg"),
        .eps_sub = 28,
    });
    app.cover_for_id = try std.testing.allocator.dupe(u8, "anime1");
    app.cover_loading = true;

    const rgba = try std.testing.allocator.dupe(u8, &[_]u8{ 0xaa, 0xbb, 0xcc, 0xff });
    const for_id = try std.testing.allocator.dupe(u8, "anime1");

    try testTick(&app, .{ .cover_done = .{ .rgba = rgba, .width = 1, .height = 1, .for_id = for_id } });
    try testing.expect(!app.cover_loading);
    try testing.expect(app.cover_for_id == null);
    try testing.expect(app.cover_pixels == null);

    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
}

test "cover_error clears state so a later revisit can refetch" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .detail;
    try app.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "anime1"),
        .name = try std.testing.allocator.dupe(u8, "Frieren"),
        .thumb = try std.testing.allocator.dupe(u8, "https://img.anili.st/frieren.jpg"),
        .eps_sub = 28,
    });
    app.cover_for_id = try std.testing.allocator.dupe(u8, "anime1");
    app.cover_loading = true;

    const for_id = try std.testing.allocator.dupe(u8, "anime1");
    try testTick(&app, .{ .cover_error = for_id });
    try testing.expect(!app.cover_loading);
    try testing.expect(app.cover_for_id == null);
    try testing.expect(app.cover_pixels == null);
    try testing.expect(app.cover_failed_for_id != null);
    try testing.expectEqualStrings("anime1", app.cover_failed_for_id.?);

    app.clearCoverFailure();

    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
}

test "deinitOwnedState releases app-owned runtime resources" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.search_page = 2;

    try app.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "anime1"),
        .name = try std.testing.allocator.dupe(u8, "Frieren"),
        .eps_sub = 28,
    });

    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 1);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    app.episode_results = eps;
    app.detail_for_id = try std.testing.allocator.dupe(u8, "anime1");

    app.cover_pixels = .{ .rgba = try std.testing.allocator.dupe(u8, &[_]u8{ 0xaa, 0xbb, 0xcc, 0xff }), .w = 1, .h = 1 };
    app.cover_for_id = try std.testing.allocator.dupe(u8, "anime1");
    app.cover_failed_for_id = try std.testing.allocator.dupe(u8, "anime1");
    app.cover_loading = true;

    var vx: vaxis.Vaxis = undefined;
    var writer: std.Io.Writer = undefined;
    app.deinitOwnedState(&vx, &writer);

    try testing.expectEqual(@as(usize, 0), app.results.items.len);
    try testing.expectEqual(@as(u32, 0), app.search_page);
    try testing.expect(app.episode_results == null);
    try testing.expect(app.detail_for_id == null);
    try testing.expect(app.cover_pixels == null);
    try testing.expect(app.cover_for_id == null);
    try testing.expect(app.cover_failed_for_id == null);
    try testing.expect(!app.cover_loading);
}

test "search mode: char appends and arms debounce, does not fire immediately" {
    var app: App = .{};
    app.active_view = .browse;
    app.input_mode = .search;
    const k = vaxis.Key{ .codepoint = 'a', .text = "a" };
    try testTick(&app, .{ .key_press = k });
    try testing.expectEqual(@as(usize, 1), app.search_len);
    try testing.expect(!app.search_loading);
    try testing.expect(app.debounce_deadline_ms > 0);
}

test "search mode: h and H append to query instead of triggering navigation" {
    var app: App = .{};
    app.active_view = .browse;
    app.active_pane = .detail;
    app.input_mode = .search;

    try testTick(&app, .{ .key_press = .{ .codepoint = 'h', .text = "h" } });
    try testing.expectEqual(@as(usize, 1), app.search_len);
    try testing.expectEqualStrings("h", app.search_query[0..app.search_len]);
    try testing.expectEqual(.browse, app.active_view);
    try testing.expectEqual(.detail, app.active_pane);

    try testTick(&app, .{ .key_press = .{ .codepoint = 'H', .mods = .{ .shift = true }, .text = "H" } });
    try testing.expectEqual(@as(usize, 2), app.search_len);
    try testing.expectEqualStrings("hH", app.search_query[0..app.search_len]);
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
    app.search_len = 3;
    @memcpy(app.search_query[0..3], "abc");
    app.debounce_deadline_ms = 1; // well in the past — always expired
    try testTick(&app, .tick);
    try testing.expectEqual(@as(i64, 0), app.debounce_deadline_ms);
    try testing.expect(app.search_loading);
    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
}

test "task_error pushes a persistent error toast" {
    var app: App = .{};
    try testTick(&app, .{ .task_error = "network down" });
    const t = app.toast_queue[0] orelse return error.TestExpectationFailed;
    try testing.expectEqual(Toast.Kind.@"error", t.kind);
    try testing.expect(t.persistent);
    try testing.expectEqualStrings("network down", t.text[0..t.text_len]);
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
    try store.upsertAnime(.{ .source = "allanime", .source_id = "show1", .title = "Test Show" }, 1000);

    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &store;
    app.playing = true;
    app.playing_source = "allanime";
    app.playing_anime_id = try testing.allocator.dupe(u8, "show1");
    app.playing_episode_raw = try testing.allocator.dupe(u8, "3");
    app.playing_translation = .sub;

    try testTick(&app, .{ .position_update = .{ .time_pos = 29.0, .duration = 1440 } });
    try testing.expect((try store.getResume("allanime", "show1", .sub, "3")) == null);

    try testTick(&app, .{ .position_update = .{ .time_pos = 30.0, .duration = 1440 } });
    const first = (try store.getResume("allanime", "show1", .sub, "3")).?;
    try testing.expectApproxEqAbs(@as(f64, 30.0), first.position_secs, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1440), first.duration_secs, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 30.0), app.last_checkpoint_pos, 0.001);

    try testTick(&app, .{ .position_update = .{ .time_pos = 59.0, .duration = 1440 } });
    const second = (try store.getResume("allanime", "show1", .sub, "3")).?;
    try testing.expectApproxEqAbs(@as(f64, 30.0), second.position_secs, 0.001);

    try testTick(&app, .{ .position_update = .{ .time_pos = 60.5, .duration = 1440 } });
    const third = (try store.getResume("allanime", "show1", .sub, "3")).?;
    try testing.expectApproxEqAbs(@as(f64, 60.5), third.position_secs, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 60.5), app.last_checkpoint_pos, 0.001);

    try testTick(&app, .{ .play_done = null });
}

test "play_done persists final observed position after checkpoints" {
    var store = try store_mod.Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "show1", .title = "Test Show" }, 1000);

    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &store;
    app.playing = true;
    app.playing_source = "allanime";
    app.playing_anime_id = try testing.allocator.dupe(u8, "show1");
    app.playing_episode_raw = try testing.allocator.dupe(u8, "3");
    app.playing_episode_index = 3;
    app.playing_translation = .sub;
    app.last_checkpoint_pos = 90;

    try store.saveProgress("allanime", "show1", .sub, "3", 90, 1440, 1001);
    try testTick(&app, .{ .play_done = .{ .time_pos = 100, .duration = 1440 } });

    const saved = (try store.getResume("allanime", "show1", .sub, "3")).?;
    try testing.expectApproxEqAbs(@as(f64, 100), saved.position_secs, 0.001);
}

test "play_done ignores non-meaningful final position and preserves checkpoint" {
    var store = try store_mod.Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "show1", .title = "Test Show" }, 1000);

    var app: App = .{};
    app.gpa = testing.allocator;
    app.store = &store;
    app.playing = true;
    app.playing_source = "allanime";
    app.playing_anime_id = try testing.allocator.dupe(u8, "show1");
    app.playing_episode_raw = try testing.allocator.dupe(u8, "3");
    app.playing_episode_index = 3;
    app.playing_translation = .sub;
    app.last_checkpoint_pos = 90;

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
    app.last_checkpoint_pos = 60;
    app.playing_source = "allanime";
    app.playing_anime_id = try testing.allocator.dupe(u8, "show1");
    app.playing_episode_raw = try testing.allocator.dupe(u8, "3");
    app.playing_episode_index = 3;

    try testTick(&app, .{ .play_done = null });
    try testing.expect(!app.playing);
    try testing.expectApproxEqAbs(@as(f64, 0), app.current_position, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0), app.current_duration, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0), app.last_checkpoint_pos, 0.001);
    try testing.expectEqual(@as(usize, 0), app.playing_anime_id.len);
    try testing.expectEqual(@as(usize, 0), app.playing_episode_raw.len);
}

test "firePlay: double-play guard is a no-op when playing is true" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .detail;
    app.playing = true;

    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 1);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    app.episode_results = eps;
    app.detail_for_id = try std.testing.allocator.dupe(u8, "anime1");

    try testTick(&app, keyEv(vaxis.Key.enter, .{}));

    // Guard held — no thread spawned, playing still true.
    try testing.expect(app.play_thread == null);
    try testing.expect(app.playing);

    std.testing.allocator.free(app.detail_for_id.?);
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
    app.settings_cursor = 1; // default_quality, defaults to "1080"

    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqualStrings("best", app.config.default_quality); // 1080 -> best
    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqualStrings("480", app.config.default_quality); // wrap best -> 480
    try testTick(&app, keyEv('h', .{}));
    try testing.expectEqualStrings("best", app.config.default_quality); // wrap back 480 -> best
}

test "settings: subtitle-language cycle keeps live translation in sync" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings_cursor = 2; // subtitle_language, defaults to "sub"

    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqualStrings("dub", app.config.translation);
    try testing.expectEqual(domain.Translation.dub, app.translation);
}

test "settings: space toggles a bool field" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings_cursor = 5; // cover_art, defaults to true

    try testTick(&app, keyEv(vaxis.Key.space, .{}));
    try testing.expect(!app.config.cover_art);
    try testTick(&app, keyEv(vaxis.Key.space, .{}));
    try testing.expect(app.config.cover_art);
}

test "settings: enter edits mpv_path; type+confirm commits, esc cancels" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings_cursor = 0; // mpv_path, defaults to "mpv"

    try testTick(&app, keyEv(vaxis.Key.enter, .{})); // begin edit (buffer seeded "mpv")
    try testing.expect(app.settings_editing);
    try testTick(&app, .{ .key_press = .{ .codepoint = '2', .text = "2" } }); // -> "mpv2"
    try testTick(&app, keyEv(vaxis.Key.enter, .{})); // commit
    try testing.expect(!app.settings_editing);
    try testing.expectEqualStrings("mpv2", app.config.mpv_path);

    // Esc discards the in-progress edit, leaving the committed value intact.
    try testTick(&app, keyEv(vaxis.Key.enter, .{}));
    try testTick(&app, .{ .key_press = .{ .codepoint = 'Z', .text = "Z" } });
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expect(!app.settings_editing);
    try testing.expectEqualStrings("mpv2", app.config.mpv_path);
}

test "settings: empty edit buffer never commits a blank mpv_path" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings_cursor = 0;

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
    app.settings_cursor = 0;

    try testTick(&app, keyEv('k', .{})); // already at top — stays
    try testing.expectEqual(@as(usize, 0), app.settings_cursor);

    var n: usize = 0;
    while (n < 20) : (n += 1) try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, app_mod.settings_row_count - 1), app.settings_cursor);
}

test "settings: q with no config path warns and returns to browse" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.config_path = null;

    try testTick(&app, keyEv('q', .{}));
    try testing.expectEqual(.browse, app.active_view);
    const t = app.toast_queue[0] orelse return error.TestExpectationFailed;
    try testing.expectEqual(Toast.Kind.warn, t.kind);
}

test "settings: cycling an out-of-preset value snaps to a valid preset" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings_cursor = 3; // resume_offset; presets {0,3,5,10,15,30}
    app.config.resume_offset_sec = 7; // not a preset (e.g. a hand-edited file)

    try testTick(&app, keyEv('l', .{}));
    // An unrecognized value starts from index 0, so 'l' lands on the second
    // preset — never panics, always snaps back onto a valid value.
    try testing.expectEqual(@as(u32, 3), app.config.resume_offset_sec);
}

// ── Save-to-disk round-trip (originally Astra's verification harness) ────────
// These exercise the disk-write path the state-machine tests above can't reach
// (they only cover the null-path branch). Kept as permanent coverage.

const config_mod = @import("../config.zig");

test "astra: settings save round-trip — q writes file, load reads back mutations" {
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
    app.settings_cursor = 0; // mpv_path row
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

    // Drive q — this calls saveSettings → config_mod.save().
    try testTick(&app, keyEv('q', .{}));

    // 1. App returned to browse.
    try testing.expectEqual(.browse, app.active_view);

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

test "astra: entering settings resets cursor, editing state, and input_mode" {
    var app: App = .{};
    app.gpa = testing.allocator;
    // Dirty state from a prior visit.
    app.settings_cursor = 5;
    app.settings_editing = true;
    app.input_mode = .search;
    app.active_view = .browse;

    // F3 switches to settings — the onKey F3 handler resets these.
    try testTick(&app, keyEv(vaxis.Key.f3, .{}));
    try testing.expectEqual(.settings, app.active_view);
    try testing.expectEqual(@as(usize, 0), app.settings_cursor);
    try testing.expect(!app.settings_editing);
    try testing.expectEqual(.normal, app.input_mode);
}

test "astra: Esc from settings returns to browse without calling save" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    // config_path is null — if save were called, it would push a warn toast.
    app.config_path = null;

    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expectEqual(.browse, app.active_view);
    // No toast means save was NOT called.
    try testing.expect(app.toast_queue[0] == null);
}

test "astra: edit mode swallows F-keys — cannot switch views mid-edit" {
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings_cursor = 0; // mpv_path

    try testTick(&app, keyEv(vaxis.Key.enter, .{})); // enter edit mode
    try testing.expect(app.settings_editing);

    // F1 while editing must be swallowed — stay on settings, still editing.
    try testTick(&app, keyEv(vaxis.Key.f1, .{}));
    try testing.expectEqual(.settings, app.active_view);
    try testing.expect(app.settings_editing);

    // Esc exits edit mode, stays on settings.
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expect(!app.settings_editing);
    try testing.expectEqual(.settings, app.active_view);
}

test "settings: Ctrl-C hard-quits even while editing a text field" {
    // The Ctrl-C emergency quit must work from anywhere, including the modal
    // mpv_path edit field (onSettingsEditKey lets Ctrl-C fall through).
    var app: App = .{};
    app.gpa = testing.allocator;
    app.active_view = .settings;
    app.settings_cursor = 0;

    try testTick(&app, keyEv(vaxis.Key.enter, .{})); // enter edit mode
    try testing.expect(app.settings_editing);

    try testTick(&app, keyEv('c', .{ .ctrl = true }));
    try testing.expect(app.should_quit);
}

// ── cover fetch/suppress/retry decision (ROD-110, Elara #2) ──────────────────
// `CoverDecision.eval` is the pure core of `syncCover`: it decides whether to
// fetch, suppress (cooldown), leave an in-flight/loaded cover alone, clear stale
// state, or do nothing — with no threads or `builtin.is_test` guards.

const cooldown_ms = app_mod.cover_retry_cooldown_ms;

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
    // noteCoverFailure stores null when the url dupe OOMs; without a url to
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

// ── half-block letterbox fit (ROD-110, Mira S2) ──────────────────────────────
// `halfBlockFit` letterboxes an image into a cols × rows*2 half-pixel grid,
// aspect-correct using the terminal's pixels-per-cell metrics.

const halfBlockFit = app_mod.halfBlockFit;

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
