//! ROD-55 spike — go/no-go for the whole project. **PASS.**
//!
//! Proves the full network stack on Zig 0.16.0 against our real catalog source,
//! AniList (AllAnime is dead behind a Cloudflare JS challenge — see ROD-55 notes):
//!   1. `std.http.Client` HTTPS POST (TLS + system CA bundle)
//!   2. JSON request *body* + custom headers reach the server
//!   3. `std.json` parses the GraphQL response into typed structs
//!
//! Run: `zig build spike-http -- frieren`
//!
//! Throwaway — the real catalog client (ROD-60) lives behind SourceProvider.

const std = @import("std");

const ENDPOINT = "https://graphql.anilist.co";

// Single-line GraphQL (no embedded newlines → trivially JSON-safe).
const GQL = "query($search:String,$perPage:Int){Page(perPage:$perPage){media(search:$search,type:ANIME,sort:SEARCH_MATCH){id title{romaji english} episodes averageScore status seasonYear coverImage{large}}}}";

// ── Response shape (std.json maps struct fields to JSON keys by name) ──────────

const Title = struct { romaji: ?[]const u8 = null, english: ?[]const u8 = null };
const Cover = struct { large: ?[]const u8 = null };
const Media = struct {
    id: u64,
    title: Title = .{},
    episodes: ?u32 = null,
    averageScore: ?u32 = null,
    status: ?[]const u8 = null,
    seasonYear: ?u32 = null,
    coverImage: Cover = .{},
};
const Page = struct { media: []Media };
const Data = struct { Page: Page };
const Resp = struct { data: ?Data = null };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const query = if (args.len > 1) args[1] else "frieren";

    var out_buf: [4096]u8 = undefined;
    var out_fw: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_fw.interface;

    // 1. Build the JSON request body with the search term interpolated.
    const body_json = try std.fmt.allocPrint(
        arena,
        "{{\"query\":\"{s}\",\"variables\":{{\"search\":\"{s}\",\"perPage\":10}}}}",
        .{ GQL, query },
    );

    try out.print("→ searching AniList for \"{s}\"\n\n", .{query});
    try out.flush();

    // 2. POST it.
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    var resp_aw = std.Io.Writer.Allocating.init(arena);
    const res = client.fetch(.{
        .location = .{ .url = ENDPOINT },
        .method = .POST,
        .payload = body_json,
        .response_writer = &resp_aw.writer,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
        },
    }) catch |err| {
        try out.print("✗ fetch failed: {s}\n", .{@errorName(err)});
        try out.flush();
        return err;
    };
    const body = resp_aw.writer.buffered();

    try out.print("status: {d}   body: {d} bytes\n\n", .{ @intFromEnum(res.status), body.len });

    // 3. Parse.
    const parsed = std.json.parseFromSlice(Resp, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        try out.print("✗ JSON parse failed: {s}\nfirst 400 bytes:\n{s}\n", .{
            @errorName(err), body[0..@min(body.len, 400)],
        });
        try out.flush();
        return err;
    };

    const data = parsed.value.data orelse {
        try out.print("✗ no `data` field. first 400 bytes:\n{s}\n", .{body[0..@min(body.len, 400)]});
        try out.flush();
        return;
    };

    try out.print("✓ {d} results:\n", .{data.Page.media.len});
    for (data.Page.media, 0..) |m, i| {
        const title = m.title.english orelse m.title.romaji orelse "(untitled)";
        const eps = m.episodes orelse 0;
        const score = m.averageScore orelse 0;
        const year = m.seasonYear orelse 0;
        try out.print("  {d:>2}. {s}  ·  {d} eps · score {d} · {d}\n", .{ i + 1, title, eps, score, year });
    }
    try out.flush();
}
