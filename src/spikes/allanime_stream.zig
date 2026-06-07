//! ROD-62 spike — resolve a playable AllAnime stream, from Zig.
//!
//! Proves the *working* recipe (reverse-engineered from anipy-cli, which works
//! where ani-nexus-tui died): the door AllAnime slammed on GET is wide open to
//! POST. Full chain in our own stack:
//!   1. POST search  (Apollo persisted query — sha256 hash, not a query string)
//!   2. POST get_video (persisted query, Referer: youtu-chan.com)
//!   3. base64 + AES-256-GCM decrypt the `tobeparsed` payload
//!   4. pull the direct tools.fast4speed.rsvp 1080p URL out of sourceUrls
//!
//! Credit: the POST-not-GET insight, the Apollo persisted-query hashes, and the
//! AES-256-GCM `tobeparsed` scheme were all learned by studying anipy-cli
//! (GPL-3.0) — https://github.com/sdaqo/anipy-cli — specifically
//! api/src/anipy_api/provider/providers/allanime_provider.py. Reimplemented in
//! Zig from the observed protocol; no code was copied.
//!
//! Run: `zig build spike-stream -- frieren`

const std = @import("std");

const API = "https://api.allanime.day/api";
const UA = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36";

// Apollo persisted-query hashes (the server identifies the GraphQL op by these).
const HASH_SEARCH = "a24c500a1b765c68ae1d8dd85174931f661c71369c89b92b88b75a725afc471c";
const HASH_VIDEO = "d405d0edd690624b66baba3068e0edc3ac90f1597d898a1ec8db4e5c43c00fec";

// AES-256-GCM key seed for the `tobeparsed` blob (key = sha256(seed)).
const GCM_SEED = "Xot36i3lK3:v1";

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

// `extensions` is a JSON *string* whose contents are themselves JSON, so the
// inner quotes are backslash-escaped. Built at comptime; only the hash differs.
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

// search response
const Edge = struct { _id: []const u8, name: ?[]const u8 = null };
const Shows = struct { edges: []Edge };
const SData = struct { shows: Shows };
const SResp = struct { data: ?SData = null };

// video response (encrypted)
const VData = struct { tobeparsed: ?[]const u8 = null };
const VResp = struct { data: ?VData = null };

// decrypted payload
const Src = struct { sourceName: ?[]const u8 = null, sourceUrl: ?[]const u8 = null };
const Ep = struct { sourceUrls: []Src };
const Dec = struct { episode: Ep };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const query = if (args.len > 1) args[1] else "frieren";

    var out_buf: [4096]u8 = undefined;
    var out_fw: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_fw.interface;

    // 1. Search (POST + persisted query; `variables` is an object in the body).
    const search_body = try std.fmt.allocPrint(
        arena,
        "{{\"variables\":{{\"search\":{{\"query\":\"{s}\"}},\"limit\":26,\"page\":1,\"translationType\":\"sub\",\"countryOrigin\":\"ALL\"}},\"extensions\":\"{s}\"}}",
        .{ query, EXT_SEARCH },
    );
    try out.print("→ POST search \"{s}\"\n", .{query});
    try out.flush();

    const sbody = try post(arena, io, search_body, "https://allmanga.to/");
    const sresp = try std.json.parseFromSlice(SResp, arena, sbody, .{ .ignore_unknown_fields = true });
    const sdata = sresp.value.data orelse return error.NoSearchData;
    if (sdata.shows.edges.len == 0) {
        try out.writeAll("  no results\n");
        try out.flush();
        return;
    }
    const show = sdata.shows.edges[0];
    try out.print("  → {s}  (id {s})\n\n", .{ show.name orelse "?", show._id });

    // 2. get_video (POST + persisted query; `variables` is a JSON *string*).
    var vb = std.Io.Writer.Allocating.init(arena);
    const vw = &vb.writer;
    try vw.writeAll("{\"variables\":\"{\\\"showId\\\":\\\"");
    try vw.writeAll(show._id);
    try vw.writeAll("\\\",\\\"translationType\\\":\\\"sub\\\",\\\"episodeString\\\":\\\"1\\\"}\",\"extensions\":\"");
    try vw.writeAll(EXT_VIDEO);
    try vw.writeAll("\"}");

    try out.writeAll("→ POST resolve episode 1 (sub)\n");
    try out.flush();

    const vbody = try post(arena, io, vb.writer.buffered(), "https://youtu-chan.com/");
    const vresp = try std.json.parseFromSlice(VResp, arena, vbody, .{ .ignore_unknown_fields = true });
    const tbp = (vresp.value.data orelse return error.NoVideoData).tobeparsed orelse {
        try out.writeAll("  response was plain (not `tobeparsed`) — spike only handles the encrypted form\n");
        try out.flush();
        return;
    };

    // 3. base64 decode + AES-256-GCM decrypt.
    var key: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(GCM_SEED, &key, .{});

    const b64 = std.base64.standard.Decoder;
    const raw = try arena.alloc(u8, try b64.calcSizeForSlice(tbp));
    try b64.decode(raw, tbp);
    if (raw.len < 1 + 12 + 16) return error.BlobTooSmall;

    const nonce: [12]u8 = raw[1..][0..12].*; // raw[0] is a 1-byte prefix
    const tag: [16]u8 = raw[raw.len - 16 ..][0..16].*;
    const ciphertext = raw[13 .. raw.len - 16];
    const plain = try arena.alloc(u8, ciphertext.len);
    try Aes256Gcm.decrypt(plain, ciphertext, tag, "", nonce, key);

    try out.print("  ✓ AES-256-GCM decrypt OK ({d} bytes)\n\n", .{plain.len});

    // 4. Parse decrypted JSON → list providers, extract the direct fast4speed URL.
    const decoded = try std.json.parseFromSlice(Dec, arena, plain, .{ .ignore_unknown_fields = true });
    try out.writeAll("  providers:\n");
    var playable: ?[]const u8 = null;
    for (decoded.value.episode.sourceUrls) |s| {
        const name = s.sourceName orelse "?";
        const url = s.sourceUrl orelse "";
        const trunc = url[0..@min(url.len, 52)];
        try out.print("    {s:<10} {s}{s}\n", .{ name, trunc, if (url.len > 52) "…" else "" });
        if (playable == null and std.mem.indexOf(u8, url, "tools.fast4speed.rsvp") != null) {
            playable = url;
        }
    }

    if (playable) |u| {
        try out.print("\n✓ PLAYABLE stream (1080p, direct):\n  {s}\n", .{u});
    } else {
        try out.writeAll("\n(no direct fast4speed link; the rest need the XOR-0x38 decipher + follow — ROD-62 proper)\n");
    }
    try out.flush();
}
