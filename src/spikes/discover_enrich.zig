//! ROD-247 spike — batched AniList enrichment for Discover cards. THROWAWAY.
//!
//! Decision gate (Rod's call): is ONE batched AniList round trip per feed page an
//! acceptable cost, and does AniList reliably supply score + genres + season where
//! the AllAnime popular feed nulls them ~2/3 of fetches (measured ROD-245/250)?
//!
//! What this measures — and what it deliberately doesn't:
//!   * MEASURES the network cost of the *new* request ROD-247 adds: one batched
//!     `media(id_in:[...])` call hydrating a whole page of cards at once. Times it,
//!     repeats R times to show the latency spread AND whether score/season come
//!     back stable (the feed flaked all-null↔all-present between fetches; is the
//!     AniList side actually steady? this answers it).
//!   * MEASURES the fill rate: of the ids requested, how many come back with a
//!     non-null score / non-empty genres / a season+year pair (the chip needs
//!     both halves — that's the field the feed could never supply).
//!   * Does NOT exercise AllAnime. The ~30/30 mineable-id rate from cover thumbs
//!     is already measured live (ROD-247 writeup); re-deriving it isn't the gate.
//!     We stand in for "the feed handed us N ids" by pulling N real currently-
//!     popular ids from AniList itself (sort:POPULARITY_DESC) — same id space,
//!     since the mined ids ARE AniList ids.
//!
//! Run: `zig build spike-enrich`            (defaults: 30 ids, 3 repeats)
//!      `zig build spike-enrich -- 30 5`    (page_size repeats)
//!
//! Throwaway — if the gate passes, the real path generalizes workers.discoverEnrichTask
//! from one-card-on-zoom to one-batched-call-per-page (see ROD-247 acceptance).

const std = @import("std");

const ENDPOINT = "https://graphql.anilist.co";

// Step 1 — stand in for the feed page: N real currently-popular AniList ids.
const GQL_POPULAR_IDS = "query($n:Int!){Page(perPage:$n){media(sort:POPULARITY_DESC,type:ANIME){id}}}";

// Step 2 — THE THING UNDER TEST. Exactly the card-level field set ROD-247 names:
// score badge + genre tag + season/year chip. id_in takes the page's ids in one
// shot. ids are ints → JSON-safe when interpolated raw into the query string.
const GQL_BATCH_FIELDS = "id averageScore genres season seasonYear startDate{year}";

// ── Response shapes ───────────────────────────────────────────────────────────

const IdOnly = struct { id: u64 };
const IdPage = struct { media: []IdOnly };
const IdData = struct { Page: IdPage };
const IdResp = struct { data: ?IdData = null };

const SD = struct { year: ?u32 = null };
const Media = struct {
    id: u64,
    averageScore: ?u32 = null,
    genres: []const []const u8 = &.{},
    season: ?[]const u8 = null,
    seasonYear: ?u32 = null,
    startDate: SD = .{},
};
const Page = struct { media: []Media };
const Data = struct { Page: Page };
const Resp = struct { data: ?Data = null };

const Fill = struct {
    returned: usize = 0,
    score: usize = 0,
    genres: usize = 0,
    season: usize = 0,
    chip: usize = 0, // season AND a year — what the top-bar chip actually needs
    latency_us: i64 = 0,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    const page_size: u32 = if (args.len > 1) (std.fmt.parseInt(u32, args[1], 10) catch 30) else 30;
    const repeats: u32 = if (args.len > 2) (std.fmt.parseInt(u32, args[2], 10) catch 3) else 3;

    var out_buf: [8192]u8 = undefined;
    var out_fw: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_fw.interface;

    try out.print("ROD-247 spike — batched AniList enrichment\n", .{});
    try out.print("page_size={d}  repeats={d}  endpoint={s}\n\n", .{ page_size, repeats, ENDPOINT });
    try out.flush();

    // ── Step 1: fetch a page of real popular ids (the "feed page") ─────────────
    const ids_body = try std.fmt.allocPrint(
        arena,
        "{{\"query\":\"{s}\",\"variables\":{{\"n\":{d}}}}}",
        .{ GQL_POPULAR_IDS, page_size },
    );
    const ids_raw = postGql(arena, io, ids_body) orelse {
        try out.print("✗ couldn't fetch popular ids (transport/HTTP). Aborting.\n", .{});
        try out.flush();
        return;
    };
    const ids_parsed = std.json.parseFromSlice(IdResp, arena, ids_raw, .{ .ignore_unknown_fields = true }) catch {
        try out.print("✗ popular-id response didn't parse.\n", .{});
        try out.flush();
        return;
    };
    const id_data = ids_parsed.value.data orelse {
        try out.print("✗ popular-id response had no `data`.\n", .{});
        try out.flush();
        return;
    };
    const ids = id_data.Page.media;
    try out.print("→ seeded {d} popular ids (stand-in for one feed page)\n\n", .{ids.len});

    // Build the id_in list once: "[1,2,3,...]".
    var list: std.ArrayList(u8) = .empty;
    try list.append(arena, '[');
    for (ids, 0..) |m, i| {
        if (i != 0) try list.append(arena, ',');
        try list.print(arena, "{d}", .{m.id});
    }
    try list.append(arena, ']');
    const id_in = list.items;

    const batch_query = try std.fmt.allocPrint(
        arena,
        "query{{Page(perPage:{d}){{media(id_in:{s},type:ANIME){{{s}}}}}}}",
        .{ page_size, id_in, GQL_BATCH_FIELDS },
    );
    const batch_body = try std.fmt.allocPrint(arena, "{{\"query\":\"{s}\"}}", .{batch_query});

    // ── Step 2: time the batched enrichment call, R times ─────────────────────
    try out.print("repeat   latency   returned  score   genres  season  chip(s+y)\n", .{});
    try out.print("------   -------   --------  ------  ------  ------  ---------\n", .{});
    try out.flush();

    var fills: std.ArrayList(Fill) = .empty;
    for (0..repeats) |r| {
        const t0 = std.Io.Timestamp.now(io, .awake);
        const raw = postGql(arena, io, batch_body) orelse {
            try out.print("  {d:>2}     FETCH FAILED\n", .{r + 1});
            try out.flush();
            continue;
        };
        const elapsed = t0.untilNow(io, .awake).toMicroseconds();

        const parsed = std.json.parseFromSlice(Resp, arena, raw, .{ .ignore_unknown_fields = true }) catch {
            try out.print("  {d:>2}     PARSE FAILED ({d:.0}ms)\n", .{ r + 1, ms(elapsed) });
            try out.flush();
            continue;
        };
        const data = parsed.value.data orelse {
            try out.print("  {d:>2}     NO DATA ({d:.0}ms)\n", .{ r + 1, ms(elapsed) });
            try out.flush();
            continue;
        };

        var f: Fill = .{ .latency_us = elapsed };
        for (data.Page.media) |m| {
            f.returned += 1;
            if (m.averageScore != null) f.score += 1;
            if (m.genres.len > 0) f.genres += 1;
            if (m.season != null) f.season += 1;
            if (m.season != null and m.startDate.year != null) f.chip += 1;
        }
        try fills.append(arena, f);

        try out.print("  {d:>2}    {d:>5.0}ms      {d:>3}/{d:<3}  {d:>3}/{d:<2}  {d:>3}/{d:<2}  {d:>3}/{d:<2}  {d:>3}/{d:<2}\n", .{
            r + 1,      ms(elapsed), f.returned,
            ids.len,    f.score,     f.returned,
            f.genres,   f.returned,  f.season,
            f.returned, f.chip,      f.returned,
        });
        try out.flush();
    }

    // ── Verdict aids ──────────────────────────────────────────────────────────
    if (fills.items.len == 0) {
        try out.print("\n✗ no successful batched calls. Gate: inconclusive (network).\n", .{});
        try out.flush();
        return;
    }
    var lo: i64 = std.math.maxInt(i64);
    var hi: i64 = 0;
    var sum: i64 = 0;
    for (fills.items) |f| {
        lo = @min(lo, f.latency_us);
        hi = @max(hi, f.latency_us);
        sum += f.latency_us;
    }
    const avg = @divTrunc(sum, @as(i64, @intCast(fills.items.len)));

    // Worst-case fill across all repeats (the "looks broken" risk lives in the tail).
    var worst_score: usize = std.math.maxInt(usize);
    var worst_chip: usize = std.math.maxInt(usize);
    for (fills.items) |f| {
        worst_score = @min(worst_score, f.score);
        worst_chip = @min(worst_chip, f.chip);
    }

    try out.print("\nlatency (batched call, the ROD-247 per-page cost):\n", .{});
    try out.print("  min {d:.0}ms   avg {d:.0}ms   max {d:.0}ms   over {d} call(s)\n", .{ ms(lo), ms(avg), ms(hi), fills.items.len });
    try out.print("\nreliability (worst single repeat — the feed flaked ~2/3; does AniList?):\n", .{});
    try out.print("  score badge:  {d}/{d} cards filled at worst\n", .{ worst_score, ids.len });
    try out.print("  season chip:  {d}/{d} cards had season+year at worst\n", .{ worst_chip, ids.len });
    try out.print("\nContrast: AllAnime feed gave season 0/30 every fetch, score null ~2/3.\n", .{});
    try out.flush();
}

fn ms(us: i64) f64 {
    return @as(f64, @floatFromInt(us)) / std.time.us_per_ms;
}

/// POST a GraphQL body to AniList; returns response bytes (arena-owned) or null
/// on transport/HTTP failure. Mirrors anilist.postGql so the spike measures the
/// same call shape the real path uses.
fn postGql(arena: std.mem.Allocator, io: std.Io, body: []const u8) ?[]const u8 {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    var resp_aw = std.Io.Writer.Allocating.init(arena);
    const res = client.fetch(.{
        .location = .{ .url = ENDPOINT },
        .method = .POST,
        .payload = body,
        .response_writer = &resp_aw.writer,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
        },
    }) catch return null;
    if (res.status != .ok) return null;
    return resp_aw.writer.buffered();
}
