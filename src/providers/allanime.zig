//! AllAnime — the first (and currently only) `SourceProvider`.
//!
//! The working recipe — POST not GET (Cloudflare only challenges GET), Apollo
//! *persisted-query* sha256 hashes instead of query strings, and an AES-256-GCM
//! `tobeparsed` blob — was reverse-engineered from anipy-cli (GPL-3.0,
//! https://github.com/sdaqo/anipy-cli) by observing its protocol and
//! reimplemented here in Zig. No code was copied. See ROD-91 / ROD-62 / ROD-55.
//!
//! AllAnime is fragile by nature. Every site-specific fact — endpoint, hashes,
//! referers, the decrypt scheme — is quarantined in this one file behind
//! `source.SourceProvider`. When it dies: replace this file, not the app.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const domain = @import("../domain.zig");
const source = @import("../source.zig");

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

const API = "https://api.allanime.day/api";
// An old Chrome UA. AllAnime accepts it and it keeps us unremarkable.
const UA = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36";

// Apollo persisted-query hashes — the server identifies each GraphQL op by these
// instead of accepting a raw query string. Captured from anipy-cli's traffic.
const HASH_SEARCH = "a24c500a1b765c68ae1d8dd85174931f661c71369c89b92b88b75a725afc471c";
const HASH_EPISODES = "043448386c7a686bc2aabfbb6b80f6074e795d350df48015023b079527b0848a";
const HASH_VIDEO = "d405d0edd690624b66baba3068e0edc3ac90f1597d898a1ec8db4e5c43c00fec";

// AES-256-GCM key seed for the `tobeparsed` blob (key = sha256(seed)).
const GCM_SEED = "Xot36i3lK3:v1";

// Referers the API / CDN gate on, per operation.
const REFERER_API = "https://allmanga.to/"; // search + episodes
const REFERER_VIDEO = "https://youtu-chan.com/"; // get_video
const STREAM_REFERER = "https://allanime.day"; // mpv → fast4speed CDN

// `extensions` is sent as a JSON *string* whose value is itself JSON, so its
// inner quotes are backslash-escaped. Built at comptime; only the hash varies.
fn extJson(comptime hash: []const u8) []const u8 {
    return "{\\\"persistedQuery\\\":{\\\"version\\\":1,\\\"sha256Hash\\\":\\\"" ++ hash ++ "\\\"}}";
}
const EXT_SEARCH = extJson(HASH_SEARCH);
const EXT_EPISODES = extJson(HASH_EPISODES);
const EXT_VIDEO = extJson(HASH_VIDEO);

/// Provider state. Stateless today, but the struct gives the vtable a real
/// `self` and a home for future config (debug logging, timeouts — ROD-92).
pub const AllAnime = struct {
    pub fn init() AllAnime {
        return .{};
    }

    /// Package this concrete provider into the erased `SourceProvider` the app
    /// holds. `self` must outlive every call made through the returned value.
    pub fn provider(self: *AllAnime) source.SourceProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: source.SourceProvider.VTable = .{
        .search = searchErased,
        .episodes = episodesErased,
        .resolve = resolveErased,
    };

    // ── vtable trampolines: recover the typed self from the erased ptr ──────────
    fn searchErased(ptr: *anyopaque, arena: Allocator, io: Io, query: []const u8, opts: source.SearchOptions) anyerror![]domain.Anime {
        const self: *AllAnime = @ptrCast(@alignCast(ptr));
        return self.search(arena, io, query, opts);
    }
    fn episodesErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation) anyerror![]domain.EpisodeNumber {
        const self: *AllAnime = @ptrCast(@alignCast(ptr));
        return self.episodes(arena, io, show_id, tt);
    }
    fn resolveErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation) anyerror!domain.StreamLink {
        const self: *AllAnime = @ptrCast(@alignCast(ptr));
        return self.resolve(arena, io, show_id, ep, tt);
    }

    // ── search ─────────────────────────────────────────────────────────────────

    const AvailEps = struct { sub: u32 = 0, dub: u32 = 0 };
    const SEdge = struct { _id: []const u8, name: ?[]const u8 = null, availableEpisodes: AvailEps = .{} };
    const SShows = struct { edges: []SEdge };
    const SData = struct { shows: SShows };
    const SResp = struct { data: ?SData = null };

    pub fn search(self: *AllAnime, arena: Allocator, io: Io, query: []const u8, opts: source.SearchOptions) ![]domain.Anime {
        _ = self;
        // For search, `variables` is a plain object (not stringified — that's the
        // quirk that differs per persisted op). Only the query needs escaping.
        const q = try jsonEscape(arena, query);
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"variables\":{{\"search\":{{\"query\":\"{s}\"}},\"limit\":26,\"page\":1,\"translationType\":\"{s}\",\"countryOrigin\":\"ALL\"}},\"extensions\":\"{s}\"}}",
            .{ q, opts.translation.str(), EXT_SEARCH },
        );

        const raw = try post(arena, io, body, REFERER_API);
        const parsed = try std.json.parseFromSlice(SResp, arena, raw, .{ .ignore_unknown_fields = true });
        const data = parsed.value.data orelse return error.NoSearchData;

        var list: std.ArrayList(domain.Anime) = .empty;
        for (data.shows.edges) |e| {
            try list.append(arena, .{
                .id = e._id,
                .name = e.name orelse "(untitled)",
                .eps_sub = e.availableEpisodes.sub,
                .eps_dub = e.availableEpisodes.dub,
            });
        }

        // Rank best-match-first. AllAnime returns rough relevance order; we
        // sharpen it with an explicit title-match score (ROD-60). No `score`
        // field comes back from AllAnime, so episode count is the only tie-break.
        std.mem.sort(domain.Anime, list.items, RankCtx{ .query = query, .tt = opts.translation }, rankGreater);

        if (list.items.len > opts.limit) list.shrinkRetainingCapacity(opts.limit);
        return list.items;
    }

    // ── episodes ─────────────────────────────────────────────────────────────────

    const EpDetail = struct { sub: []const []const u8 = &.{}, dub: []const []const u8 = &.{} };
    const EShow = struct { availableEpisodesDetail: EpDetail = .{} };
    const EData = struct { show: ?EShow = null };
    const EResp = struct { data: ?EData = null };

    pub fn episodes(self: *AllAnime, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation) ![]domain.EpisodeNumber {
        _ = self;
        // Here `variables` IS a stringified JSON value: `"{\"_id\":\"...\"}"`.
        const inner = try std.fmt.allocPrint(arena, "{{\"_id\":\"{s}\"}}", .{show_id});
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"variables\":\"{s}\",\"extensions\":\"{s}\"}}",
            .{ try jsonEscape(arena, inner), EXT_EPISODES },
        );

        const raw = try post(arena, io, body, REFERER_API);
        const parsed = try std.json.parseFromSlice(EResp, arena, raw, .{ .ignore_unknown_fields = true });
        const show = (parsed.value.data orelse return error.NoEpisodeData).show orelse return error.ShowNotFound;
        const arr = switch (tt) {
            .sub => show.availableEpisodesDetail.sub,
            .dub => show.availableEpisodesDetail.dub,
        };

        const eps = try arena.alloc(domain.EpisodeNumber, arr.len);
        for (arr, 0..) |e, i| eps[i] = .{ .raw = e };
        std.mem.sort(domain.EpisodeNumber, eps, {}, domain.EpisodeNumber.lessThan);
        return eps;
    }

    // ── resolve ──────────────────────────────────────────────────────────────────

    const VData = struct { tobeparsed: ?[]const u8 = null };
    const VResp = struct { data: ?VData = null };
    const Src = struct { sourceName: ?[]const u8 = null, sourceUrl: ?[]const u8 = null };
    const DecEp = struct { sourceUrls: []Src };
    const Dec = struct { episode: DecEp };

    pub fn resolve(self: *AllAnime, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation) !domain.StreamLink {
        _ = self;
        const inner = try std.fmt.allocPrint(
            arena,
            "{{\"showId\":\"{s}\",\"translationType\":\"{s}\",\"episodeString\":\"{s}\"}}",
            .{ show_id, tt.str(), ep.raw },
        );
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"variables\":\"{s}\",\"extensions\":\"{s}\"}}",
            .{ try jsonEscape(arena, inner), EXT_VIDEO },
        );

        const raw = try post(arena, io, body, REFERER_VIDEO);
        const parsed = try std.json.parseFromSlice(VResp, arena, raw, .{ .ignore_unknown_fields = true });
        const tbp = (parsed.value.data orelse return error.NoVideoData).tobeparsed orelse return error.NotEncrypted;

        const plain = try decryptTobeparsed(arena, tbp);
        const decoded = try std.json.parseFromSlice(Dec, arena, plain, .{ .ignore_unknown_fields = true });

        // v0.1: take the direct fast4speed 1080p URL when present. The other
        // providers hand back `--<hex>` paths that need XOR-0x38 decipher + m3u8
        // follow — that's ROD-92 (post-v0.1). Until then, clean failure.
        for (decoded.value.episode.sourceUrls) |s| {
            const url = s.sourceUrl orelse continue;
            if (std.mem.indexOf(u8, url, "tools.fast4speed.rsvp") != null) {
                return .{ .url = url, .resolution = 1080, .referer = STREAM_REFERER };
            }
        }
        return error.NoDirectStream;
    }

    // ── internals ────────────────────────────────────────────────────────────────

    /// One POST to the AllAnime GraphQL endpoint. Returns the response body
    /// (lives in `arena`). Errors `HttpNotOk` on any non-200 — the caller maps it.
    fn post(arena: Allocator, io: Io, body: []const u8, referer: []const u8) ![]u8 {
        var client: std.http.Client = .{ .allocator = arena, .io = io };
        defer client.deinit();
        var aw: std.Io.Writer.Allocating = .init(arena);
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

    /// base64-decode then AES-256-GCM-decrypt the `tobeparsed` blob.
    /// Layout of the decoded bytes: [0]=1-byte prefix, [1..13]=nonce,
    /// [13..len-16]=ciphertext, [len-16..]=GCM tag. Key = sha256(GCM_SEED).
    fn decryptTobeparsed(arena: Allocator, tbp: []const u8) ![]u8 {
        var key: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(GCM_SEED, &key, .{});

        const b64 = std.base64.standard.Decoder;
        const raw = try arena.alloc(u8, try b64.calcSizeForSlice(tbp));
        try b64.decode(raw, tbp);
        if (raw.len < 1 + 12 + 16) return error.BlobTooSmall;

        const nonce: [12]u8 = raw[1..][0..12].*;
        const tag: [16]u8 = raw[raw.len - 16 ..][0..16].*;
        const ciphertext = raw[13 .. raw.len - 16];
        const plain = try arena.alloc(u8, ciphertext.len);
        try Aes256Gcm.decrypt(plain, ciphertext, tag, "", nonce, key);
        return plain;
    }

    // ── ranking ──────────────────────────────────────────────────────────────────

    const RankCtx = struct { query: []const u8, tt: domain.Translation };

    /// Relevance score: a big title-match bonus dominates, with a gentle
    /// log-scaled episode-count nudge to break ties toward the fuller series
    /// (a 28-episode show beats a 1-episode side-story of the same name).
    fn relevance(name: []const u8, query: []const u8, eps: u32) f64 {
        var s: f64 = 0;
        if (std.ascii.eqlIgnoreCase(name, query)) {
            s = 1000;
        } else if (std.ascii.startsWithIgnoreCase(name, query)) {
            s = 500;
        } else if (std.ascii.indexOfIgnoreCase(name, query) != null) {
            s = 250;
        }
        s += std.math.log2(@as(f64, @floatFromInt(eps)) + 2.0);
        return s;
    }

    /// `std.mem.sort` comparator — higher relevance sorts first (descending).
    fn rankGreater(ctx: RankCtx, a: domain.Anime, b: domain.Anime) bool {
        return relevance(a.name, ctx.query, a.episodeCount(ctx.tt)) >
            relevance(b.name, ctx.query, b.episodeCount(ctx.tt));
    }
};

/// Escape a UTF-8 string so it can sit inside a JSON string literal. We hand-roll
/// the request bodies (the persisted-query `extensions` field forces awkward
/// nested escaping that std.json's stringifier won't reproduce verbatim), so any
/// user-supplied text — the search query, mainly — must be escaped or a stray `"`
/// breaks the body. Covers the JSON mandatory escapes; control chars pass through
/// as-is, which is fine for anime titles.
fn jsonEscape(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        else => try out.append(arena, c),
    };
    return out.items;
}

test "jsonEscape escapes quotes and backslashes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("a\\\"b", try jsonEscape(a, "a\"b"));
    try std.testing.expectEqualStrings("c\\\\d", try jsonEscape(a, "c\\d"));
    try std.testing.expectEqualStrings("plain", try jsonEscape(a, "plain"));
}
