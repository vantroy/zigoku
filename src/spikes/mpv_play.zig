//! ROD-57 spike — the M0 victory lap: search → resolve → **play in mpv**, from Zig.
//!
//! Reuses the proven AllAnime resolver (ROD-62 spike) and hands the stream to
//! mpv via std.process.spawn. This is the whole point of the project running in
//! one command.
//!
//!   zig build spike-mpv                       # play Frieren ep1 in an mpv window
//!   zig build spike-mpv -- "bocchi"           # play something else
//!   zig build spike-mpv -- frieren --frames=1 --vo=null --no-audio   # headless probe
//!
//! Anything after the query is passed straight through to mpv.

const std = @import("std");

const API = "https://api.allanime.day/api";
const UA = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36";
const HASH_SEARCH = "a24c500a1b765c68ae1d8dd85174931f661c71369c89b92b88b75a725afc471c";
const HASH_VIDEO = "d405d0edd690624b66baba3068e0edc3ac90f1597d898a1ec8db4e5c43c00fec";
const GCM_SEED = "Xot36i3lK3:v1";
const STREAM_REFERER = "https://allanime.day";

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

const EXT_SEARCH = "{\\\"persistedQuery\\\":{\\\"version\\\":1,\\\"sha256Hash\\\":\\\"" ++ HASH_SEARCH ++ "\\\"}}";
const EXT_VIDEO = "{\\\"persistedQuery\\\":{\\\"version\\\":1,\\\"sha256Hash\\\":\\\"" ++ HASH_VIDEO ++ "\\\"}}";

fn post(arena: std.mem.Allocator, io: std.Io, body: []const u8, referer: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    var aw = std.Io.Writer.Allocating.init(arena);
    const res = try client.fetch(.{
        .location = .{ .url = API },
        .method = .POST,
        .payload = body,
        .response_writer = &aw.writer,
        .headers = .{ .user_agent = .{ .override = UA } },
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Referer", .value = referer },
        },
    });
    if (res.status != .ok) return error.HttpNotOk;
    return aw.writer.buffered();
}

const Edge = struct { _id: []const u8, name: ?[]const u8 = null };
const Shows = struct { edges: []Edge };
const SData = struct { shows: Shows };
const SResp = struct { data: ?SData = null };

const VData = struct { tobeparsed: ?[]const u8 = null };
const VResp = struct { data: ?VData = null };

const Src = struct { sourceName: ?[]const u8 = null, sourceUrl: ?[]const u8 = null };
const Ep = struct { sourceUrls: []Src };
const Dec = struct { episode: Ep };

const Resolved = struct { title: []const u8, url: []const u8 };

/// Search AllAnime → resolve episode 1 (sub) → return a direct playable URL.
fn resolveStream(arena: std.mem.Allocator, io: std.Io, query: []const u8) !Resolved {
    const search_body = try std.fmt.allocPrint(
        arena,
        "{{\"variables\":{{\"search\":{{\"query\":\"{s}\"}},\"limit\":26,\"page\":1,\"translationType\":\"sub\",\"countryOrigin\":\"ALL\"}},\"extensions\":\"{s}\"}}",
        .{ query, EXT_SEARCH },
    );
    const sbody = try post(arena, io, search_body, "https://allmanga.to/");
    const sresp = try std.json.parseFromSlice(SResp, arena, sbody, .{ .ignore_unknown_fields = true });
    const sdata = sresp.value.data orelse return error.NoSearchData;
    if (sdata.shows.edges.len == 0) return error.NoResults;
    const show = sdata.shows.edges[0];

    var vb = std.Io.Writer.Allocating.init(arena);
    const vw = &vb.writer;
    try vw.writeAll("{\"variables\":\"{\\\"showId\\\":\\\"");
    try vw.writeAll(show._id);
    try vw.writeAll("\\\",\\\"translationType\\\":\\\"sub\\\",\\\"episodeString\\\":\\\"1\\\"}\",\"extensions\":\"");
    try vw.writeAll(EXT_VIDEO);
    try vw.writeAll("\"}");

    const vbody = try post(arena, io, vb.writer.buffered(), "https://youtu-chan.com/");
    const vresp = try std.json.parseFromSlice(VResp, arena, vbody, .{ .ignore_unknown_fields = true });
    const tbp = (vresp.value.data orelse return error.NoVideoData).tobeparsed orelse return error.NotEncrypted;

    var key: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(GCM_SEED, &key, .{});
    const b64 = std.base64.standard.Decoder;
    const raw = try arena.alloc(u8, try b64.calcSizeForSlice(tbp));
    try b64.decode(raw, tbp);
    if (raw.len < 1 + 12 + 16) return error.BlobTooSmall;
    const nonce: [12]u8 = raw[1..][0..12].*;
    const tag: [16]u8 = raw[raw.len - 16 ..][0..16].*;
    const plain = try arena.alloc(u8, raw.len - 13 - 16);
    try Aes256Gcm.decrypt(plain, raw[13 .. raw.len - 16], tag, "", nonce, key);

    const decoded = try std.json.parseFromSlice(Dec, arena, plain, .{ .ignore_unknown_fields = true });
    for (decoded.value.episode.sourceUrls) |s| {
        const url = s.sourceUrl orelse continue;
        if (std.mem.indexOf(u8, url, "tools.fast4speed.rsvp") != null) {
            return .{ .title = show.name orelse query, .url = url };
        }
    }
    return error.NoDirectStream;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const query = if (args.len > 1) args[1] else "frieren";
    const extra_mpv_args = if (args.len > 2) args[2..] else &.{};

    var out_buf: [4096]u8 = undefined;
    var out_fw: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_fw.interface;

    try out.print("→ resolving \"{s}\" ep1 from AllAnime…\n", .{query});
    try out.flush();

    const stream = resolveStream(arena, io, query) catch |err| {
        try out.print("✗ resolve failed: {s}\n", .{@errorName(err)});
        try out.flush();
        return err;
    };
    try out.print("  ✓ {s}\n  ▶ launching mpv…\n", .{stream.title});
    try out.flush();

    // Build the mpv command: url + Referer header, then any pass-through args.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "mpv");
    try argv.append(arena, stream.url);
    try argv.append(arena, "--http-header-fields-append=Referer: " ++ STREAM_REFERER);
    try argv.append(arena, "--force-media-title=zigoku");
    for (extra_mpv_args) |a| try argv.append(arena, a);

    var child = std.process.spawn(io, .{ .argv = argv.items }) catch |err| {
        try out.print("✗ couldn't launch mpv: {s}  (is mpv on PATH?)\n", .{@errorName(err)});
        try out.flush();
        return err;
    };
    const term = try child.wait(io);

    switch (term) {
        .exited => |code| try out.print("\n✓ mpv exited ({d}). That was Zigoku, end to end.\n", .{code}),
        else => try out.print("\nmpv ended: {any}\n", .{term}),
    }
    try out.flush();
}
