//! Jikan — MyAnimeList ID resolver.
//!
//! AniSkip (ROD-83) keys its skip-timestamps on a MyAnimeList id. AllAnime hands
//! us none, and while AniList usually rides `idMal` along through the enrichment
//! bridge (see `anilist.zig`), that mapping can miss. Jikan is the unofficial MAL
//! REST API — no auth, free — and is our fallback to turn a title into a MAL id.
//!
//! This is a side rail, not the playback path. On any failure (network, empty
//! results, junk JSON) we return `error.NotFound` and callers degrade gracefully.
//!
//! Rate limit: Jikan enforces ~3 req/s. Interactive single calls need no throttle.
//! Batched callers should `std.Thread.sleep(400 * std.time.ns_per_ms)` between hits.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ENDPOINT = "https://api.jikan.moe/v4/anime";

/// One entry in Jikan's `data` array. We only need the id; everything else is
/// ignored at parse time.
const Entry = struct {
    mal_id: ?u32 = null,
};

const Resp = struct {
    data: []Entry = &.{},
};

/// Resolve a show title to its MyAnimeList id via Jikan's search endpoint.
///
/// Returns the first result's `mal_id`. On network error, non-200, unparseable
/// body, or no usable result, returns `error.NotFound`. Allocations come from
/// `arena`, so the caller frees everything by dropping the arena.
pub fn resolveId(arena: Allocator, io: Io, title: []const u8) error{ NotFound, OutOfMemory }!u32 {
    if (title.len == 0) return error.NotFound;

    const url = try std.fmt.allocPrint(arena, "{s}?q={s}&limit=3", .{ ENDPOINT, try urlEncode(arena, title) });

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    var resp_aw = std.Io.Writer.Allocating.init(arena);
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &resp_aw.writer,
        .extra_headers = &.{
            .{ .name = "Accept", .value = "application/json" },
        },
    }) catch return error.NotFound;
    if (res.status != .ok) return error.NotFound;

    const parsed = std.json.parseFromSlice(Resp, arena, resp_aw.writer.buffered(), .{
        .ignore_unknown_fields = true,
    }) catch return error.NotFound;

    return firstId(parsed.value.data) orelse error.NotFound;
}

/// First entry carrying a usable (non-zero) MAL id. Factored out so the
/// selection rule is unit-testable without touching the network.
fn firstId(entries: []const Entry) ?u32 {
    for (entries) |e| {
        if (e.mal_id) |id| {
            if (id > 0) return id;
        }
    }
    return null;
}

/// Percent-encode `s` for use in a query-string value. Keeps RFC 3986 unreserved
/// characters as-is; everything else becomes `%XX`.
fn urlEncode(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(arena, c);
        } else {
            try out.append(arena, '%');
            try out.append(arena, hex[(c >> 4) & 0xf]);
            try out.append(arena, hex[c & 0xf]);
        }
    }
    return out.items;
}

test "firstId returns first non-zero id" {
    const entries = [_]Entry{
        .{ .mal_id = null },
        .{ .mal_id = 0 },
        .{ .mal_id = 52991 },
        .{ .mal_id = 1 },
    };
    try std.testing.expectEqual(@as(?u32, 52991), firstId(&entries));
}

test "firstId returns null when no usable id" {
    const entries = [_]Entry{ .{ .mal_id = null }, .{ .mal_id = 0 } };
    try std.testing.expectEqual(@as(?u32, null), firstId(&entries));
    try std.testing.expectEqual(@as(?u32, null), firstId(&.{}));
}

test "urlEncode escapes spaces and punctuation, preserves unreserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "Frieren%3A%20Beyond%20Journey%27s%20End",
        try urlEncode(arena.allocator(), "Frieren: Beyond Journey's End"),
    );
    try std.testing.expectEqualStrings(
        "a-b_c.d~e",
        try urlEncode(arena.allocator(), "a-b_c.d~e"),
    );
}

test "resolveId rejects empty title without hitting the network" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.NotFound, resolveId(arena.allocator(), undefined, ""));
}

test "parse Jikan response shape and pick first id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\{"data":[{"mal_id":52991,"title":"Frieren"},{"mal_id":12345,"title":"Other"}]}
    ;
    const parsed = try std.json.parseFromSlice(Resp, arena.allocator(), body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(?u32, 52991), firstId(parsed.value.data));
}
