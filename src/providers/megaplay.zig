//! megaplay.buzz: a tier-A `SourceProvider` (ROD-359), promoted from a bare
//! stream extractor (ROD-341).
//!
//! megaplay indexes its catalog by MyAnimeList id: `/stream/mal/{mal}/{ep}/{lang}`
//! answers the embed page for that exact MAL episode number (live-verified across
//! a 1998 classic, 1100-episode long-runners, movies and 2025 seasonals). So, like
//! senshi, the show handle IS the stringified MAL id, and episode labels align with
//! true MAL numbering by construction, which keeps the cross-provider watch-state
//! label join (`getResume`/`unionHighWater`) safe with no matching at all.
//!
//! This module replaces the AniPub catalog (ROD-342/350, retired by ROD-359):
//! that third-party catalog had drifted from source truth, corrupting watch
//! state (see the ROD-359 migration comment in store.zig for the mechanism).
//! The direct MAL route needs no third-party catalog at all.
//!
//! The two-step resolve (spike-verified on ROD-340; MAL route on ROD-359):
//!   1. GET /stream/mal/{mal}/{ep}/{sub|dub} → embed HTML; scrape `data-id="N"`,
//!      megaplay's internal id and the ONLY place sub/dub diverges. A show or
//!      episode megaplay doesn't stock answers 200 with NO data-id: a clean
//!      existence probe.
//!   2. GET /stream/getSources?id={data-id} → cleartext JSON: the master m3u8,
//!      softsub vtt tracks, and intro/outro skip stamps. No decryption anywhere.
//!
//! No listing endpoint exists, so `episodes()` probes episode 1 for existence and
//! mints positional labels "1".."N" from the canonical count hint
//! (`domain.expectedEpisodeCount`, ROD-359).
//!
//! The whole delivery chain (master on cdn.mewstream.buzz, segments on rotating
//! *.glimmeron.click, vtts on lostproject.club) 403s without the megaplay
//! referer + a browser UA; megaplay's OWN referer, not senshi's. mpv propagates
//! one --referrer across the chain, so the `StreamLink.referer`/`.user_agent`
//! fields (ROD-309) carry the entire gate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const domain = @import("../domain.zig");
const source = @import("../source.zig");
const log = @import("../log.zig");

const HOST = "https://megaplay.buzz";
// Every downstream CDN host gates on this exact origin.
pub const STREAM_REFERER = "https://megaplay.buzz/";
// A current Chrome UA; no-UA requests 403 on every megaplay host. Keep it
// recent and unremarkable (same posture as senshi's).
const UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

// Bound on the scraped data-id before it's spliced into the getSources URL.
// Real ids are 4–6 digits today.
const max_data_id_len = 20;

/// One subtitle/thumbnail track from getSources `tracks[]`. Softsubs arrive as
/// external vtts (multi-language); a `kind` of "thumbnails" is the seekbar
/// sprite sheet, not a subtitle. `pickSubtitle` selects one onto the
/// StreamLink (ROD-354); the full list is carried through for a future
/// language preference.
pub const Track = struct {
    file: []const u8,
    label: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    default: bool = false,
};

/// An OP/ED skip window in seconds. megaplay hands these for free where AniSkip
/// needs a round-trip; feeding them into the aniskip path is parked (ROD-340).
pub const Skip = struct {
    start: f64,
    end: f64,
};

/// A resolved megaplay stream: the mpv-ready link plus the bonus payload
/// (softsub tracks, skip stamps) the getSources response carries.
pub const Stream = struct {
    link: domain.StreamLink,
    tracks: []const Track = &.{},
    intro: ?Skip = null,
    outro: ?Skip = null,
};

pub const MegaPlay = struct {
    /// Stable identity used by persistence keys `(source_name, show_id)`. The show
    /// handle is the stringified MAL id, same key discipline as senshi.
    pub const source_name = "megaplay";

    /// Human-facing name for user-visible copy (toasts, banners, CLI).
    pub const display_name = "MegaPlay";

    pub fn init() MegaPlay {
        return .{};
    }

    /// Pack this concrete provider into the erased `SourceProvider` the app holds.
    /// `self` must outlive every call made through the returned value.
    pub fn provider(self: *MegaPlay) source.SourceProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: source.SourceProvider.VTable = .{
        .name = nameErased,
        .displayName = displayNameErased,
        .search = searchErased,
        .canonicalKey = canonicalKeyErased,
        .episodes = episodesErased,
        .resolve = resolveErased,
        .coverRequest = coverRequestErased,
    };

    // ── vtable trampolines ───────────────────────────────────────────────────────
    fn nameErased(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return source_name;
    }
    fn displayNameErased(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return display_name;
    }
    fn searchErased(ptr: *anyopaque, arena: Allocator, io: Io, query: []const u8, opts: source.SearchOptions) anyerror![]domain.Anime {
        _ = ptr;
        _ = arena;
        _ = io;
        _ = query;
        _ = opts;
        // No catalog search exists: the MAL route IS the whole index, so a
        // canonical without a mal_id is unreachable here by design (there is
        // nothing for tier C to search). The resolver reads this error as
        // "nothing learned", never an absence verdict (ROD-347), so a show
        // that gains a mal_id later isn't blocked by a stale negative.
        return error.Unsupported;
    }
    fn canonicalKeyErased(ptr: *anyopaque, arena: Allocator, canonical: domain.Anime) anyerror!?[]const u8 {
        _ = ptr;
        // Tier A: the MAL route keys the catalog by mal_id directly, so a
        // canonical with one resolves for free (same shape as senshi). No MAL
        // id → null; there is no tier-C recovery for this provider (see search).
        const mal = canonical.mal_id orelse return null;
        return try std.fmt.allocPrint(arena, "{d}", .{mal});
    }
    fn episodesErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation, count_hint: ?u32) anyerror![]domain.EpisodeNumber {
        const self: *MegaPlay = @ptrCast(@alignCast(ptr));
        return self.episodes(arena, io, show_id, tt, count_hint);
    }
    fn resolveErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) anyerror!domain.StreamLink {
        const self: *MegaPlay = @ptrCast(@alignCast(ptr));
        return self.resolve(arena, io, show_id, ep, tt, quality);
    }
    fn coverRequestErased(ptr: *anyopaque, gpa: Allocator, ref: []const u8) anyerror!source.CoverRequest {
        _ = ptr;
        // megaplay serves no covers and its bindings mint from the canonical
        // entity, whose cover refs are absolute AniList/MAL CDN URLs: pass
        // those through (ungated hosts). Anything relative has no host to
        // resolve against here; reject rather than guess.
        if (ref.len == 0 or !domain.isAbsoluteUrl(ref) or !cleanArg(ref))
            return error.InvalidCoverRef;
        return .{ .url = try gpa.dupe(u8, ref) };
    }

    // ── episodes ──────────────────────────────────────────────────────────────

    pub fn episodes(self: *MegaPlay, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation, count_hint: ?u32) ![]domain.EpisodeNumber {
        _ = self;
        // Track-agnostic list, same as senshi: the probe uses sub (the dominant
        // track; bindings and the ROD-347 cache are per-show, not per-track,
        // so a dub-mode probe must not read a sub-only show as "not stocked").
        // A missing dub surfaces at resolve as a clean error, never a shorter list.
        _ = tt;
        try guardShowId(show_id);
        const html = try request(arena, io, try embedUrl(arena, show_id, "1", .sub), .embed);
        // 200 with no data-id = megaplay doesn't stock this MAL id (the
        // vtable's empty-is-authoritative contract, ROD-347).
        if (parseDataId(html) == null) return try arena.alloc(domain.EpisodeNumber, 0);
        return labels(arena, count_hint orelse 1);
    }

    /// Positional labels "1".."n". A hint-less caller (existence probes, an
    /// unenriched canonical) degrades to one episode, never zero: zero would
    /// collide with megaplay's "not stocked" signal (ROD-347).
    fn labels(arena: Allocator, n: u32) ![]domain.EpisodeNumber {
        // Callers hint through domain.expectedEpisodeCount, which already clamps;
        // re-clamp here so a provider never sizes an alloc off an unbounded value
        // regardless of how the hint arrived (defense in depth, ROD-359).
        const count = @max(@min(n, domain.max_episode_hint), 1);
        const out = try arena.alloc(domain.EpisodeNumber, count);
        for (out, 1..) |*ep, i| ep.* = .{ .raw = try std.fmt.allocPrint(arena, "{d}", .{i}) };
        return out;
    }

    // ── resolve ──────────────────────────────────────────────────────────────────

    /// Resolve one episode into a playable stream: embed page (existence + the
    /// sub/dub fork) then getSources. Two GETs, no decryption.
    pub fn resolve(self: *MegaPlay, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) !domain.StreamLink {
        _ = self;
        // megaplay hands back an adaptive HLS master; mpv picks off the bandwidth
        // ladder. Honoring the quality cap waits on the shared hls.zig extraction,
        // same rationale as senshi (ROD-301 follow-up).
        _ = quality;
        try guardShowId(show_id);
        // Labels are our own episodes() mint: 1-based integers. A cross-provider
        // landing can hand a foreign fractional label ("13.5", senshi's recap
        // slots); no MAL-route address exists for it, so reject clean.
        const n = std.fmt.parseInt(u32, ep.raw, 10) catch return error.InvalidEpisode;
        if (n == 0) return error.InvalidEpisode;

        const embed_url = try embedUrl(arena, show_id, ep.raw, tt);
        const html = try request(arena, io, embed_url, .embed);
        const data_id = parseDataId(html) orelse {
            // Past-end episode, or the requested track is missing (the sub/dub
            // fork lives on this page): distinct from transport failure, and the
            // receipt says which episode the host wouldn't serve.
            log.warn("megaplay embed {s}: no data-id in {d} byte(s) of HTML", .{ embed_url, html.len });
            return error.NoDataId;
        };

        const src_url = try std.fmt.allocPrint(arena, HOST ++ "/stream/getSources?id={s}", .{data_id});
        const raw = try request(arena, io, src_url, .xhr);
        const stream = try mapSources(arena, raw, tt);
        // Softsub pick rides link.sub_url (ROD-354); intro/outro skip stamps
        // still ride `stream` unused, parked until a player seam exists (ROD-340).
        return stream.link;
    }

    /// The MAL-keyed embed URL. `{sub|dub}` is exactly Translation's tagname, so
    /// `str()` (the cross-provider wire literal) is the segment.
    fn embedUrl(arena: Allocator, mal_id: []const u8, ep_label: []const u8, tt: domain.Translation) ![]const u8 {
        return std.fmt.allocPrint(arena, HOST ++ "/stream/mal/{s}/{s}/{s}", .{ mal_id, ep_label, tt.str() });
    }

    // ── the getSources JSON shape ───────────────────────────────────────────────────
    // Cleartext (verified live): {"sources":{"file":"…master.m3u8"},"tracks":[…],
    // "intro":{"start":N,"end":N},"outro":{…}}. Every field tolerated as absent so
    // a host-side shape drift degrades to a clean error, not a parse crash.

    const RawTrack = struct {
        file: ?[]const u8 = null,
        label: ?[]const u8 = null,
        kind: ?[]const u8 = null,
        default: bool = false,
    };
    const RawSkip = struct { start: ?f64 = null, end: ?f64 = null };
    const SourcesResp = struct {
        sources: ?struct { file: ?[]const u8 = null } = null,
        tracks: []RawTrack = &.{},
        intro: ?RawSkip = null,
        outro: ?RawSkip = null,
    };

    /// Map a raw getSources body onto a `Stream`. Pure over the response bytes so
    /// it's unit-testable without the network. `tt` gates the softsub pick: only a
    /// `sub` resolve attaches a subtitle url (a dub is voiced; auto-loading full
    /// dialogue subs over it would be wrong, and a signs-only pick needs the
    /// language preference this deliberately isn't yet).
    fn mapSources(arena: Allocator, raw: []const u8, tt: domain.Translation) !Stream {
        const parsed = try std.json.parseFromSlice(SourcesResp, arena, raw, .{ .ignore_unknown_fields = true });
        const src = parsed.value.sources orelse return error.NoStreamSource;
        const file = src.file orelse return error.NoStreamSource;
        // Host-provided data about to enter mpv's argv: require an absolute
        // http(s) url carrying only clean argv bytes (mirrors senshi/AllAnime).
        if (!domain.isAbsoluteUrl(file) or !cleanArg(file)) return error.BadStreamUrl;

        var tracks: std.ArrayList(Track) = .empty;
        for (parsed.value.tracks) |t| {
            const f = t.file orelse continue;
            if (!domain.isAbsoluteUrl(f) or !cleanArg(f)) continue; // drop, don't fail the stream
            try tracks.append(arena, .{ .file = f, .label = t.label, .kind = t.kind, .default = t.default });
        }

        return .{
            .link = .{
                .url = file,
                .referer = STREAM_REFERER,
                .user_agent = UA,
                // The segment CDN serves its .ts as .jpg (same content-filter dodge
                // as senshi, ROD-301); relax ffmpeg's HLS extension gate.
                .cloaked_segments = true,
                .sub_url = if (tt == .sub) pickSubtitle(tracks.items) else null,
            },
            .tracks = tracks.items,
            .intro = skipFrom(parsed.value.intro),
            .outro = skipFrom(parsed.value.outro),
        };
    }

    /// Pick the one subtitle track to hand mpv: the host's `default` flag wins
    /// (live it marks English), else an English-labeled track, else the first
    /// subtitle at all. Only a `captions` or kind-less track qualifies (both
    /// live-observed as subs); an unknown future kind fails safe as "no pick",
    /// never as a wrong `--sub-file` (the seekbar's "thumbnails" sprite sheet is
    /// the known non-sub). Null when nothing qualifies. Tracks reach here already
    /// argv-vetted by `mapSources`.
    pub fn pickSubtitle(tracks: []const Track) ?[]const u8 {
        var english: ?[]const u8 = null;
        var first: ?[]const u8 = null;
        for (tracks) |t| {
            if (t.kind) |k| if (!std.mem.eql(u8, k, "captions")) continue;
            if (t.default) return t.file;
            const label = t.label orelse "";
            if (english == null and std.ascii.startsWithIgnoreCase(label, "english")) english = t.file;
            if (first == null) first = t.file;
        }
        return english orelse first;
    }

    /// Normalize a raw skip stamp: both ends present, finite, and a positive-width
    /// window; anything else is "no stamp", never a garbage window mpv would jump on.
    fn skipFrom(raw: ?RawSkip) ?Skip {
        const r = raw orelse return null;
        const start = r.start orelse return null;
        const end = r.end orelse return null;
        if (!std.math.isFinite(start) or !std.math.isFinite(end)) return null;
        if (start < 0 or end <= start) return null;
        return .{ .start = start, .end = end };
    }

    /// Scrape the first numeric `data-id` attribute out of the embed HTML. Quoted
    /// (either quote) or bare. Null when no attribute carries digits.
    fn parseDataId(html: []const u8) ?[]const u8 {
        const needle = "data-id=";
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, html, from, needle)) |at| {
            var i = at + needle.len;
            if (i < html.len and (html[i] == '"' or html[i] == '\'')) i += 1;
            const start = i;
            while (i < html.len and std.ascii.isDigit(html[i])) i += 1;
            if (i > start and i - start <= max_data_id_len) return html[start..i];
            from = at + needle.len;
        }
        return null;
    }

    /// The show handle is the stringified MAL id and every id we mint is
    /// digits-only. Enforce that before splicing into a URL path so a corrupt/
    /// hostile id can't smuggle a traversal or a second segment (mirrors senshi).
    fn guardShowId(show_id: []const u8) !void {
        if (show_id.len == 0) return error.InvalidShowId;
        for (show_id) |c| if (!std.ascii.isDigit(c)) return error.InvalidShowId;
    }

    /// True if `s` is safe to place in a fetch URL / mpv argv: printable ASCII only
    /// (0x21–0x7e), rejecting CR/LF, spaces and controls. Mirrors senshi's guard.
    fn cleanArg(s: []const u8) bool {
        for (s) |c| if (c < 0x21 or c > 0x7e) return false;
        return true;
    }

    // ── HTTP ────────────────────────────────────────────────────────────────────────
    // Same helper + error taxonomy as senshi/allanime (ROD-173), pending the shared
    // providers/http.zig extraction (ROD-349). Keep the three in step until then.

    /// What the request is for; picks the header set. Both need the UA + referer
    /// gate; getSources additionally wants the XHR marker its endpoint checks.
    const Kind = enum { embed, xhr };

    fn request(arena: Allocator, io: Io, url: []const u8, kind: Kind) ![]u8 {
        var client: std.http.Client = .{ .allocator = arena, .io = io };
        defer client.deinit();
        var aw: std.Io.Writer.Allocating = .init(arena);
        const extra: []const std.http.Header = switch (kind) {
            .embed => &.{.{ .name = "Referer", .value = STREAM_REFERER }},
            .xhr => &.{
                .{ .name = "Referer", .value = STREAM_REFERER },
                .{ .name = "X-Requested-With", .value = "XMLHttpRequest" },
                .{ .name = "Accept", .value = "application/json" },
            },
        };
        const res = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &aw.writer,
            .headers = .{ .user_agent = .{ .override = UA } },
            .extra_headers = extra,
        }) catch |e| {
            log.warn("megaplay GET {s}: transport {s}", .{ url, @errorName(e) });
            return mapTransportError(e);
        };
        if (res.status.class() != .success) {
            log.warn("megaplay GET {s}: HTTP {d}", .{ url, @intFromEnum(res.status) });
            return statusToError(res.status);
        }
        return aw.writer.buffered();
    }

    /// Classify a non-2xx status (ROD-173): 403/451 = blocked; 5xx = source down;
    /// anything else = the undifferentiated `HttpNotOk` (likely host drift).
    fn statusToError(status: std.http.Status) error{ Forbidden, ServerError, HttpNotOk } {
        return switch (status) {
            .forbidden, .unavailable_for_legal_reasons => error.Forbidden,
            else => switch (status.class()) {
                .server_error => error.ServerError,
                else => error.HttpNotOk,
            },
        };
    }

    /// Map a transport-layer failure to `NetworkDown` when "check your connection"
    /// is the right advice; everything else propagates unchanged.
    fn mapTransportError(e: anyerror) anyerror {
        return switch (e) {
            error.ConnectionRefused,
            error.ConnectionResetByPeer,
            error.HostUnreachable,
            error.NetworkUnreachable,
            error.NetworkDown,
            error.Timeout,
            error.TlsInitializationFailed,
            error.UnknownHostName,
            error.NameServerFailure,
            error.NoAddressReturned,
            error.ResolvConfParseFailed,
            error.DetectingNetworkConfigurationFailed,
            error.InvalidDnsARecord,
            error.InvalidDnsAAAARecord,
            error.InvalidDnsCnameRecord,
            => error.NetworkDown,
            else => e,
        };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseDataId scrapes the first numeric data-id, any quoting" {
    try testing.expectEqualStrings("13458", MegaPlay.parseDataId(
        \\<div id="megaplay-player" data-id="13458" data-lang="sub">
    ).?);
    try testing.expectEqualStrings("13452", MegaPlay.parseDataId("<div data-id='13452'>").?);
    try testing.expectEqualStrings("7", MegaPlay.parseDataId("<div data-id=7 >").?);
    // First numeric one wins across multiple attributes.
    try testing.expectEqualStrings("11", MegaPlay.parseDataId(
        \\<a data-id="11"></a><a data-id="22"></a>
    ).?);
    // The live mal-route shape carries sibling data-realid/-mediaid attributes;
    // data-id must win, not a substring of a longer attribute name.
    try testing.expectEqualStrings("13461", MegaPlay.parseDataId(
        \\<div class="fix-area" id="megaplay-player"
        \\    data-id="13461"
        \\    data-realid="107257"
        \\    data-mediaid="672">
    ).?);
}

test "parseDataId skips empty/non-numeric values and bounds the id" {
    // An empty or junk value keeps scanning to a later real one.
    try testing.expectEqualStrings("42", MegaPlay.parseDataId(
        \\<a data-id=""></a><b data-id="x9"></b><c data-id="42"></c>
    ).?);
    try testing.expect(MegaPlay.parseDataId("<html>no ids here</html>") == null);
    try testing.expect(MegaPlay.parseDataId("") == null);
    // Over-long digit runs are rejected, not spliced into a URL.
    const long = "data-id=\"123456789012345678901\"";
    try testing.expect(MegaPlay.parseDataId(long) == null);
}

test "guardShowId accepts a numeric MAL id, rejects traversal/injection" {
    try MegaPlay.guardShowId("52991");
    try testing.expectError(error.InvalidShowId, MegaPlay.guardShowId(""));
    try testing.expectError(error.InvalidShowId, MegaPlay.guardShowId("../etc"));
    try testing.expectError(error.InvalidShowId, MegaPlay.guardShowId("52991/x"));
    try testing.expectError(error.InvalidShowId, MegaPlay.guardShowId("13458abc"));
}

test "embedUrl splices mal id, episode and track into the MAL route (ROD-359)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings(
        "https://megaplay.buzz/stream/mal/52991/28/sub",
        try MegaPlay.embedUrl(a, "52991", "28", .sub),
    );
    try testing.expectEqualStrings(
        "https://megaplay.buzz/stream/mal/21/1100/dub",
        try MegaPlay.embedUrl(a, "21", "1100", .dub),
    );
}

test "labels mints positional 1..N; a hint-less caller degrades to one episode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const eps = try MegaPlay.labels(a, 28);
    try testing.expectEqual(@as(usize, 28), eps.len);
    try testing.expectEqualStrings("1", eps[0].raw);
    try testing.expectEqualStrings("28", eps[27].raw);
    // Zero normalizes to one episode, never zero (ROD-347: empty means not-stocked).
    try testing.expectEqual(@as(usize, 1), (try MegaPlay.labels(a, 0)).len);
    // A hostile count clamps to the ceiling rather than sizing a giant alloc (ROD-359).
    try testing.expectEqual(@as(usize, domain.max_episode_hint), (try MegaPlay.labels(a, 4_294_967_295)).len);
}

test "canonicalKey derives the stringified mal_id; null without one (ROD-359)" {
    var mp = MegaPlay.init();
    const p = mp.provider();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const key = try p.canonicalKey(arena_state.allocator(), .{
        .id = "154587",
        .name = "Sousou no Frieren",
        .anilist_id = 154587,
        .mal_id = 52991,
    });
    try testing.expectEqualStrings("52991", key.?);
    // No mal_id: no key, and (unlike senshi) no tier-C search to fall to.
    const none = try p.canonicalKey(arena_state.allocator(), .{
        .id = "1",
        .name = "X",
        .anilist_id = 1,
    });
    try testing.expect(none == null);
}

test "resolve rejects foreign/corrupt episode labels before any network" {
    var mp = MegaPlay.init();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // `undefined` Io proves the guard fires before the wire is touched.
    try testing.expectError(error.InvalidEpisode, mp.resolve(a, undefined, "52991", .{ .raw = "13.5" }, .sub, .best));
    try testing.expectError(error.InvalidEpisode, mp.resolve(a, undefined, "52991", .{ .raw = "0" }, .sub, .best));
    try testing.expectError(error.InvalidEpisode, mp.resolve(a, undefined, "52991", .{ .raw = "" }, .sub, .best));
    try testing.expectError(error.InvalidShowId, mp.resolve(a, undefined, "../x", .{ .raw = "1" }, .sub, .best));
}

test "search is structurally unsupported: the MAL route is the whole index" {
    var mp = MegaPlay.init();
    const p = mp.provider();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.Unsupported, p.search(arena_state.allocator(), undefined, "frieren", .{}));
}

test "mapSources maps a live-shaped getSources body (ROD-341)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const raw =
        \\{"sources":{"file":"https://cdn.mewstream.buzz/x/master.m3u8"},
        \\ "tracks":[
        \\   {"file":"https://1oe.lostproject.club/eng.vtt","label":"English","kind":"captions","default":true},
        \\   {"file":"https://1oe.lostproject.club/thumbs.vtt","kind":"thumbnails"},
        \\   {"label":"ghost-no-file","kind":"captions"}],
        \\ "intro":{"start":100,"end":190},
        \\ "outro":{"start":1300,"end":1390},
        \\ "server":2}
    ;
    const s = try MegaPlay.mapSources(a, raw, .sub);
    try testing.expectEqualStrings("https://cdn.mewstream.buzz/x/master.m3u8", s.link.url);
    try testing.expectEqualStrings(STREAM_REFERER, s.link.referer.?);
    try testing.expect(s.link.user_agent != null);
    try testing.expect(s.link.cloaked_segments); // .ts-as-.jpg segments need the relaxed gate
    try testing.expectEqual(@as(usize, 2), s.tracks.len); // the file-less track is dropped
    try testing.expectEqualStrings("English", s.tracks[0].label.?);
    try testing.expect(s.tracks[0].default);
    try testing.expectEqualStrings("thumbnails", s.tracks[1].kind.?);
    try testing.expectEqual(@as(f64, 100), s.intro.?.start);
    try testing.expectEqual(@as(f64, 1390), s.outro.?.end);
    // The softsub seam (ROD-354): sub resolve carries the default vtt…
    try testing.expectEqualStrings("https://1oe.lostproject.club/eng.vtt", s.link.sub_url.?);
    // …a dub resolve never auto-loads one.
    const d = try MegaPlay.mapSources(a, raw, .dub);
    try testing.expect(d.link.sub_url == null);
}

test "pickSubtitle: default wins, english next, first as fallback, thumbnails never (ROD-354)" {
    const thumbs: Track = .{ .file = "https://c/thumbs.vtt", .kind = "thumbnails", .default = true };
    const spanish: Track = .{ .file = "https://c/spa.vtt", .label = "Spanish", .kind = "captions" };
    const english: Track = .{ .file = "https://c/eng.vtt", .label = "English - CR", .kind = "captions" };
    const eng_default: Track = .{ .file = "https://c/eng2.vtt", .label = "English", .kind = "captions", .default = true };
    const bare: Track = .{ .file = "https://c/bare.vtt" }; // no label/kind, live-observed shape

    // default beats an earlier english label; a default thumbnails track is not a sub.
    try testing.expectEqualStrings("https://c/eng2.vtt", MegaPlay.pickSubtitle(&.{ thumbs, english, eng_default }).?);
    // no default: the english label wins over an earlier other language.
    try testing.expectEqualStrings("https://c/eng.vtt", MegaPlay.pickSubtitle(&.{ spanish, english }).?);
    // no default, no english: first subtitle-shaped track.
    try testing.expectEqualStrings("https://c/spa.vtt", MegaPlay.pickSubtitle(&.{ thumbs, spanish }).?);
    try testing.expectEqualStrings("https://c/bare.vtt", MegaPlay.pickSubtitle(&.{bare}).?);
    // nothing but the sprite sheet, or nothing at all: no pick.
    try testing.expect(MegaPlay.pickSubtitle(&.{thumbs}) == null);
    try testing.expect(MegaPlay.pickSubtitle(&.{}) == null);
    // an unknown future kind fails safe (never picked), even flagged default.
    const alien: Track = .{ .file = "https://c/alien.vtt", .kind = "chapters", .default = true };
    try testing.expect(MegaPlay.pickSubtitle(&.{alien}) == null);
    try testing.expectEqualStrings("https://c/spa.vtt", MegaPlay.pickSubtitle(&.{ alien, spanish }).?);
}

test "mapSources: missing or unsafe stream url is a clean error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectError(error.NoStreamSource, MegaPlay.mapSources(a, "{}", .sub));
    try testing.expectError(error.NoStreamSource, MegaPlay.mapSources(a,
        \\{"sources":{}}
    , .sub));
    // Relative url and an argv-unsafe url both refuse to reach mpv.
    try testing.expectError(error.BadStreamUrl, MegaPlay.mapSources(a,
        \\{"sources":{"file":"/x/master.m3u8"}}
    , .sub));
    try testing.expectError(error.BadStreamUrl, MegaPlay.mapSources(a,
        \\{"sources":{"file":"https://cdn/x master.m3u8"}}
    , .sub));
    // An unsafe TRACK url is dropped, not fatal; the stream still resolves,
    // and the dropped track can never become the sub pick.
    const s = try MegaPlay.mapSources(a,
        \\{"sources":{"file":"https://cdn/ok.m3u8"},
        \\ "tracks":[{"file":"/relative.vtt","kind":"captions"}]}
    , .sub);
    try testing.expectEqual(@as(usize, 0), s.tracks.len);
    try testing.expect(s.link.sub_url == null);
}

test "skipFrom rejects degenerate windows, keeps real ones" {
    try testing.expect(MegaPlay.skipFrom(null) == null);
    try testing.expect(MegaPlay.skipFrom(.{ .start = 100, .end = null }) == null);
    try testing.expect(MegaPlay.skipFrom(.{ .start = null, .end = 190 }) == null);
    try testing.expect(MegaPlay.skipFrom(.{ .start = 190, .end = 100 }) == null); // inverted
    try testing.expect(MegaPlay.skipFrom(.{ .start = 100, .end = 100 }) == null); // zero-width
    try testing.expect(MegaPlay.skipFrom(.{ .start = -5, .end = 90 }) == null);
    try testing.expect(MegaPlay.skipFrom(.{ .start = std.math.inf(f64), .end = 190 }) == null);
    const w = MegaPlay.skipFrom(.{ .start = 0, .end = 90 }).?; // an OP at 0:00 is real
    try testing.expectEqual(@as(f64, 0), w.start);
    try testing.expectEqual(@as(f64, 90), w.end);
}

test "coverRequest: absolute canonical covers pass through; relative rejects" {
    var mp = MegaPlay.init();
    const p = mp.provider();

    const abs = try p.coverRequest(testing.allocator, "https://s4.anilist.co/file/cover.jpg");
    defer testing.allocator.free(abs.url);
    try testing.expectEqualStrings("https://s4.anilist.co/file/cover.jpg", abs.url);
    try testing.expect(abs.referer == null);

    try testing.expectError(error.InvalidCoverRef, p.coverRequest(testing.allocator, "/posters/x.webp"));
    try testing.expectError(error.InvalidCoverRef, p.coverRequest(testing.allocator, ""));
    try testing.expectError(error.InvalidCoverRef, p.coverRequest(testing.allocator, "https://cdn/x y.jpg"));
}
