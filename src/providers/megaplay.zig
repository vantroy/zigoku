//! megaplay.buzz: tier-A `SourceProvider` (ROD-359; promoted from ROD-341 extractor).
//!
//! Catalog is MAL-keyed: `/stream/mal/{mal}/{ep}/{lang}`. Show handle = stringified
//! MAL id; episode labels are true MAL numbers, so cross-provider watch-state join
//! needs no matching. Replaces the retired AniPub catalog (ROD-342/350 → ROD-359).
//!
//! Two-step resolve:
//!   1. GET embed → scrape `data-id` (only sub/dub fork). 200 with no data-id = not stocked.
//!   2. GET /stream/getSources?id=… → cleartext JSON (master m3u8, softsubs, skip stamps).
//!
//! No listing endpoint: `episodes()` probes ep 1, mints "1".."N" from
//! `domain.expectedEpisodeCount` (ROD-359). Whole CDN chain 403s without megaplay
//! referer + browser UA (`StreamLink` fields, ROD-309).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const domain = @import("../domain.zig");
const source = @import("../source.zig");
const log = @import("../log.zig");
const http = @import("http.zig");
const fetchguard = @import("../util/fetchguard.zig");

const HOST = "https://megaplay.buzz";
// Every downstream CDN host gates on this exact origin.
pub const STREAM_REFERER = "https://megaplay.buzz/";
// Current Chrome UA; no-UA requests 403 on every megaplay host.
const UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

// Bound on scraped data-id before URL splice. Real ids are 4–6 digits today.
const max_data_id_len = 20;

/// Softsub/thumbnail track from getSources `tracks[]`. `kind` "thumbnails" is the
/// seekbar sprite, not a subtitle. `pickSubtitle` selects one (ROD-354).
pub const Track = struct {
    file: []const u8,
    label: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    default: bool = false,
};

/// OP/ED skip window (seconds). Parked until a player seam exists (ROD-340).
pub const Skip = struct {
    start: f64,
    end: f64,
};

/// Resolved stream: mpv-ready link plus getSources bonus payload.
pub const Stream = struct {
    link: domain.StreamLink,
    tracks: []const Track = &.{},
    intro: ?Skip = null,
    outro: ?Skip = null,
};

pub const MegaPlay = struct {
    /// Persistence key `(source_name, show_id)`. Show handle = stringified MAL id.
    pub const source_name = "megaplay";

    pub const display_name = "MegaPlay";

    pub fn init() MegaPlay {
        return .{};
    }

    /// `self` must outlive every call through the returned value.
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
        // No catalog: MAL route is the index. Unsupported = "nothing learned", never
        // an absence verdict (ROD-347), so a later mal_id is not blocked by a stale negative.
        return error.Unsupported;
    }
    fn canonicalKeyErased(ptr: *anyopaque, arena: Allocator, canonical: domain.Anime) anyerror!?[]const u8 {
        _ = ptr;
        // Tier A: mal_id → free key (senshi shape). No mal_id → null; no tier-C recovery.
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
        // No covers; absolute AniList/MAL CDN refs pass through. Relative → reject.
        if (ref.len == 0 or !domain.isAbsoluteUrl(ref) or !cleanArg(ref))
            return error.InvalidCoverRef;
        return .{ .url = try gpa.dupe(u8, ref) };
    }

    // ── episodes ──────────────────────────────────────────────────────────────

    pub fn episodes(self: *MegaPlay, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation, count_hint: ?u32) ![]domain.EpisodeNumber {
        _ = self;
        // Track-agnostic: probe sub always. Bindings/ROD-347 cache are per-show, so a
        // dub-mode probe must not read a sub-only show as not stocked. Missing dub
        // surfaces at resolve.
        _ = tt;
        try guardShowId(show_id);
        const html = try request(arena, io, try embedUrl(arena, show_id, "1", .sub), .embed);
        // 200 with no data-id = not stocked (empty-is-authoritative, ROD-347).
        if (parseDataId(html) == null) return try arena.alloc(domain.EpisodeNumber, 0);
        return labels(arena, count_hint orelse 1);
    }

    /// Positional "1".."n". Hint-less degrades to 1, never 0 (0 collides with not-stocked, ROD-347).
    fn labels(arena: Allocator, n: u32) ![]domain.EpisodeNumber {
        // Re-clamp: never size an alloc off an unbounded hint (ROD-359).
        const count = @max(@min(n, domain.max_episode_hint), 1);
        const out = try arena.alloc(domain.EpisodeNumber, count);
        for (out, 1..) |*ep, i| ep.* = .{ .raw = try std.fmt.allocPrint(arena, "{d}", .{i}) };
        return out;
    }

    // ── resolve ──────────────────────────────────────────────────────────────────

    /// Embed (existence + sub/dub fork) then getSources. Two GETs, no decryption.
    pub fn resolve(self: *MegaPlay, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) !domain.StreamLink {
        _ = self;
        // Adaptive HLS master; quality cap waits on shared hls.zig (ROD-301 follow-up).
        _ = quality;
        try guardShowId(show_id);
        // Own mint is 1-based integers. Foreign fractional labels (senshi "13.5") have
        // no MAL-route address.
        const n = std.fmt.parseInt(u32, ep.raw, 10) catch return error.InvalidEpisode;
        if (n == 0) return error.InvalidEpisode;

        const embed_url = try embedUrl(arena, show_id, ep.raw, tt);
        const html = try request(arena, io, embed_url, .embed);
        const data_id = parseDataId(html) orelse {
            // Past-end or missing track (sub/dub fork lives here), not transport failure.
            log.warn("megaplay embed {s}: no data-id in {d} byte(s) of HTML", .{ embed_url, html.len });
            return error.NoDataId;
        };

        const src_url = try std.fmt.allocPrint(arena, HOST ++ "/stream/getSources?id={s}", .{data_id});
        const raw = try request(arena, io, src_url, .xhr);
        var stream = try mapSources(arena, raw, tt);
        // Softsub pick (ROD-354). Host `default` sometimes marks signs-only over dialogue
        // (ROD-377); with ≥2 English tracks, upgrade to highest-cue by content. Never
        // downgrades below metadata pick.
        if (tt == .sub) if (stream.link.sub_url) |baseline| {
            const cands = try englishCaptions(arena, stream.tracks);
            if (cands.len >= 2) {
                if (refineSubtitleByCues(arena, io, cands, baseline)) |best| stream.link.sub_url = best;
            }
        };
        // intro/outro still unused until player seam (ROD-340).
        return stream.link;
    }

    /// MAL-keyed embed URL. `{sub|dub}` is Translation's wire tag (`str()`).
    fn embedUrl(arena: Allocator, mal_id: []const u8, ep_label: []const u8, tt: domain.Translation) ![]const u8 {
        return std.fmt.allocPrint(arena, HOST ++ "/stream/mal/{s}/{s}/{s}", .{ mal_id, ep_label, tt.str() });
    }

    // ── getSources JSON ─────────────────────────────────────────────────────────
    // Cleartext: sources.file, tracks[], intro/outro. Absent fields degrade cleanly.

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

    /// Pure over response bytes (unit-testable). Softsub only on `sub` resolve
    /// (auto-loading dialogue over dub would be wrong).
    fn mapSources(arena: Allocator, raw: []const u8, tt: domain.Translation) !Stream {
        const parsed = try std.json.parseFromSlice(SourcesResp, arena, raw, .{ .ignore_unknown_fields = true });
        const src = parsed.value.sources orelse return error.NoStreamSource;
        const file = src.file orelse return error.NoStreamSource;
        // Host data → mpv argv: absolute http(s) + clean argv bytes only.
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
                // Segment CDN serves .ts as .jpg (content-filter dodge, ROD-301).
                .cloaked_segments = true,
                .sub_url = if (tt == .sub) pickSubtitle(tracks.items) else null,
            },
            .tracks = tracks.items,
            .intro = skipFrom(parsed.value.intro),
            .outro = skipFrom(parsed.value.outro),
        };
    }

    /// Host `default` wins, else English-labeled, else first subtitle-shaped track.
    /// Unknown kind fails safe (never wrong `--sub-file`). Tracks already argv-vetted.
    pub fn pickSubtitle(tracks: []const Track) ?[]const u8 {
        var english: ?[]const u8 = null;
        var first: ?[]const u8 = null;
        for (tracks) |t| {
            if (!isSubtitleTrack(t)) continue;
            if (t.default) return t.file;
            const label = t.label orelse "";
            if (english == null and std.ascii.startsWithIgnoreCase(label, "english")) english = t.file;
            if (first == null) first = t.file;
        }
        return english orelse first;
    }

    /// `captions` or kind-less = sub. `thumbnails` and unknown kinds are not.
    fn isSubtitleTrack(t: Track) bool {
        const k = t.kind orelse return true;
        return std.mem.eql(u8, k, "captions");
    }

    /// Cap English subtitle probes per resolve (hostile getSources flood guard).
    const max_subtitle_probes = 6;

    /// English-labeled captions in host order, capped (ROD-377 multi-English disambiguation).
    fn englishCaptions(arena: Allocator, tracks: []const Track) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (tracks) |t| {
            if (out.items.len >= max_subtitle_probes) break;
            if (!isSubtitleTrack(t)) continue;
            const label = t.label orelse continue;
            if (!std.ascii.startsWithIgnoreCase(label, "english")) continue;
            try out.append(arena, t.file);
        }
        return out.items;
    }

    /// Upgrade metadata pick only when a candidate has strictly more cues. Probe failure
    /// drops that candidate, not the decision; failed baseline keeps metadata (ROD-377).
    fn refineSubtitleByCues(arena: Allocator, io: Io, candidates: []const []const u8, baseline: []const u8) ?[]const u8 {
        var best = baseline;
        var best_cues = probeCues(arena, io, baseline) catch return null;
        for (candidates) |url| {
            if (std.mem.eql(u8, url, baseline)) continue;
            const cues = probeCues(arena, io, url) catch continue;
            if (cues > best_cues) {
                best = url;
                best_cues = cues;
            }
        }
        return if (std.mem.eql(u8, best, baseline)) null else best;
    }

    /// Count cue markers in one vtt. SSRF-guarded + redirect-refused (ROD-266);
    /// body counted only, never handed to argv.
    fn probeCues(arena: Allocator, io: Io, url: []const u8) !usize {
        try fetchguard.guardFetchUrl(url);
        const body = try http.request(arena, io, .{
            .method = .GET,
            .url = url,
            .user_agent = UA,
            .extra_headers = &.{.{ .name = "Referer", .value = STREAM_REFERER }},
            .redirect_behavior = .not_allowed,
            .tag = "megaplay-sub",
        });
        return std.mem.count(u8, body, " --> ");
    }

    /// Both ends present, finite, positive-width; else no stamp (never garbage mpv jump).
    fn skipFrom(raw: ?RawSkip) ?Skip {
        const r = raw orelse return null;
        const start = r.start orelse return null;
        const end = r.end orelse return null;
        if (!std.math.isFinite(start) or !std.math.isFinite(end)) return null;
        if (start < 0 or end <= start) return null;
        return .{ .start = start, .end = end };
    }

    /// First numeric `data-id` (quoted or bare). Null when none.
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

    /// Digits-only before URL path splice (mirrors senshi).
    fn guardShowId(show_id: []const u8) !void {
        if (show_id.len == 0) return error.InvalidShowId;
        for (show_id) |c| if (!std.ascii.isDigit(c)) return error.InvalidShowId;
    }

    /// Printable ASCII only (0x21–0x7e): safe in fetch URL / mpv argv.
    fn cleanArg(s: []const u8) bool {
        for (s) |c| if (c < 0x21 or c > 0x7e) return false;
        return true;
    }

    // ── HTTP ────────────────────────────────────────────────────────────────────────

    const Kind = enum { embed, xhr };

    /// Shared http.zig taxonomy (ROD-349); any 2xx is success.
    fn request(arena: Allocator, io: Io, url: []const u8, kind: Kind) ![]u8 {
        const extra: []const std.http.Header = switch (kind) {
            .embed => &.{.{ .name = "Referer", .value = STREAM_REFERER }},
            .xhr => &.{
                .{ .name = "Referer", .value = STREAM_REFERER },
                .{ .name = "X-Requested-With", .value = "XMLHttpRequest" },
                .{ .name = "Accept", .value = "application/json" },
            },
        };
        return http.request(arena, io, .{
            .method = .GET,
            .url = url,
            .user_agent = UA,
            .extra_headers = extra,
            .tag = "megaplay",
        });
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
    try testing.expectEqualStrings("11", MegaPlay.parseDataId(
        \\<a data-id="11"></a><a data-id="22"></a>
    ).?);
    // data-id must win over sibling data-realid / data-mediaid.
    try testing.expectEqualStrings("13461", MegaPlay.parseDataId(
        \\<div class="fix-area" id="megaplay-player"
        \\    data-id="13461"
        \\    data-realid="107257"
        \\    data-mediaid="672">
    ).?);
}

test "parseDataId skips empty/non-numeric values and bounds the id" {
    try testing.expectEqualStrings("42", MegaPlay.parseDataId(
        \\<a data-id=""></a><b data-id="x9"></b><c data-id="42"></c>
    ).?);
    try testing.expect(MegaPlay.parseDataId("<html>no ids here</html>") == null);
    try testing.expect(MegaPlay.parseDataId("") == null);
    // Over-long digit runs rejected, not spliced into a URL.
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
    // Zero → one (ROD-347: empty means not-stocked). Hostile count clamps (ROD-359).
    try testing.expectEqual(@as(usize, 1), (try MegaPlay.labels(a, 0)).len);
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
    // No mal_id: no key, no tier-C search.
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
    // `undefined` Io proves the guard fires before the wire.
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
    try testing.expect(s.link.cloaked_segments);
    try testing.expectEqual(@as(usize, 2), s.tracks.len);
    try testing.expectEqualStrings("English", s.tracks[0].label.?);
    try testing.expect(s.tracks[0].default);
    try testing.expectEqualStrings("thumbnails", s.tracks[1].kind.?);
    try testing.expectEqual(@as(f64, 100), s.intro.?.start);
    try testing.expectEqual(@as(f64, 1390), s.outro.?.end);
    try testing.expectEqualStrings("https://1oe.lostproject.club/eng.vtt", s.link.sub_url.?);
    const d = try MegaPlay.mapSources(a, raw, .dub);
    try testing.expect(d.link.sub_url == null);
}

test "pickSubtitle: default wins, english next, first as fallback, thumbnails never (ROD-354)" {
    const thumbs: Track = .{ .file = "https://c/thumbs.vtt", .kind = "thumbnails", .default = true };
    const spanish: Track = .{ .file = "https://c/spa.vtt", .label = "Spanish", .kind = "captions" };
    const english: Track = .{ .file = "https://c/eng.vtt", .label = "English - CR", .kind = "captions" };
    const eng_default: Track = .{ .file = "https://c/eng2.vtt", .label = "English", .kind = "captions", .default = true };
    const bare: Track = .{ .file = "https://c/bare.vtt" };

    try testing.expectEqualStrings("https://c/eng2.vtt", MegaPlay.pickSubtitle(&.{ thumbs, english, eng_default }).?);
    try testing.expectEqualStrings("https://c/eng.vtt", MegaPlay.pickSubtitle(&.{ spanish, english }).?);
    try testing.expectEqualStrings("https://c/spa.vtt", MegaPlay.pickSubtitle(&.{ thumbs, spanish }).?);
    try testing.expectEqualStrings("https://c/bare.vtt", MegaPlay.pickSubtitle(&.{bare}).?);
    try testing.expect(MegaPlay.pickSubtitle(&.{thumbs}) == null);
    try testing.expect(MegaPlay.pickSubtitle(&.{}) == null);
    const alien: Track = .{ .file = "https://c/alien.vtt", .kind = "chapters", .default = true };
    try testing.expect(MegaPlay.pickSubtitle(&.{alien}) == null);
    try testing.expectEqualStrings("https://c/spa.vtt", MegaPlay.pickSubtitle(&.{ alien, spanish }).?);
}

test "englishCaptions: only english-labeled caption tracks, host order (ROD-377)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const eng_signs: Track = .{ .file = "https://c/eng-3.vtt", .label = "English", .kind = "captions", .default = true };
    const eng_2: Track = .{ .file = "https://c/eng-4.vtt", .label = "English 2", .kind = "captions" };
    const eng_bare: Track = .{ .file = "https://c/eng-bare.vtt", .label = "English" };
    const spanish: Track = .{ .file = "https://c/spa.vtt", .label = "Spanish", .kind = "captions" };
    const thumbs: Track = .{ .file = "https://c/thumbs.vtt", .label = "English", .kind = "thumbnails" };
    const unlabeled: Track = .{ .file = "https://c/bare.vtt", .kind = "captions" };

    // Kind-less "English" qualifies; Spanish, thumbs (even labeled English), unlabeled do not.
    const got = try MegaPlay.englishCaptions(a, &.{ eng_signs, spanish, eng_2, thumbs, eng_bare, unlabeled });
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("https://c/eng-3.vtt", got[0]);
    try testing.expectEqualStrings("https://c/eng-4.vtt", got[1]);
    try testing.expectEqualStrings("https://c/eng-bare.vtt", got[2]);

    const one = try MegaPlay.englishCaptions(a, &.{ eng_2, spanish });
    try testing.expectEqual(@as(usize, 1), one.len);
    const none = try MegaPlay.englishCaptions(a, &.{ spanish, thumbs });
    try testing.expectEqual(@as(usize, 0), none.len);

    var flood: [12]Track = undefined;
    for (&flood) |*t| t.* = eng_2;
    const capped = try MegaPlay.englishCaptions(a, &flood);
    try testing.expectEqual(@as(usize, 6), capped.len);
}

test "mapSources: missing or unsafe stream url is a clean error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectError(error.NoStreamSource, MegaPlay.mapSources(a, "{}", .sub));
    try testing.expectError(error.NoStreamSource, MegaPlay.mapSources(a,
        \\{"sources":{}}
    , .sub));
    try testing.expectError(error.BadStreamUrl, MegaPlay.mapSources(a,
        \\{"sources":{"file":"/x/master.m3u8"}}
    , .sub));
    try testing.expectError(error.BadStreamUrl, MegaPlay.mapSources(a,
        \\{"sources":{"file":"https://cdn/x master.m3u8"}}
    , .sub));
    // Unsafe track dropped, not fatal; cannot become the sub pick.
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
    try testing.expect(MegaPlay.skipFrom(.{ .start = 190, .end = 100 }) == null);
    try testing.expect(MegaPlay.skipFrom(.{ .start = 100, .end = 100 }) == null);
    try testing.expect(MegaPlay.skipFrom(.{ .start = -5, .end = 90 }) == null);
    try testing.expect(MegaPlay.skipFrom(.{ .start = std.math.inf(f64), .end = 190 }) == null);
    const w = MegaPlay.skipFrom(.{ .start = 0, .end = 90 }).?;
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
