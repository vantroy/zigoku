//! megaplay.buzz: the stream host behind AniPub's episode embeds (ROD-341).
//!
//! This is an *extractor*, not a `SourceProvider`: AniPub's catalog module
//! (ROD-342) owns search/episodes and calls in here with an episode's realid to
//! turn it into a playable stream. Standalone and inert until that wiring lands
//! (the ROD-326/334 "foundation merges anytime" pattern).
//!
//! The two-step recipe (spike-verified on ROD-340, 2026-07-10):
//!   1. GET /stream/s-2/{realid}/{sub|dub}  → embed HTML; scrape `data-id="N"`,
//!      megaplay's internal id and the ONLY place sub/dub diverges.
//!   2. GET /stream/getSources?id={data-id} → cleartext JSON: the master m3u8,
//!      softsub vtt tracks, and intro/outro skip stamps. No decryption anywhere.
//!
//! Do NOT shortcut step 1: getSources answers a realid directly too, but with a
//! DIFFERENT, unverified stream that ignores the sub/dub choice. The embed
//! scrape is what megaplay's own player does; always resolve through it.
//!
//! The whole delivery chain (master on cdn.mewstream.buzz, segments on rotating
//! *.glimmeron.click, vtts on lostproject.club) 403s without the megaplay
//! referer + a browser UA; megaplay's OWN referer, not AniPub's and not
//! senshi's. mpv propagates one --referrer across the chain, so the
//! `StreamLink.referer`/`.user_agent` fields (ROD-309) carry the entire gate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const domain = @import("../domain.zig");
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

/// Resolve an AniPub episode `realid` (from /v1/api/details ep[] links, e.g.
/// "107259") + track into a playable stream. Two GETs; everything lives in
/// `arena`.
pub fn resolve(arena: Allocator, io: Io, realid: []const u8, tt: domain.Translation) !Stream {
    try guardRealId(realid);

    // Step 1: the embed page. AniPub only stores /sub realids, but the realid
    // is lang-agnostic at this layer: the {sub|dub} path segment is where the
    // track forks, yielding a distinct data-id per track (spike: Frieren ep1
    // sub=13458, dub=13452).
    // {sub|dub} is exactly Translation's tagname, so `str()` (the cross-provider
    // wire literal) is the segment; no provider-local lookup needed.
    const embed_url = try std.fmt.allocPrint(arena, HOST ++ "/stream/s-2/{s}/{s}", .{ realid, tt.str() });
    const html = try request(arena, io, embed_url, .embed);
    const data_id = parseDataId(html) orelse {
        log.warn("megaplay embed {s}: no data-id in {d} byte(s) of HTML", .{ embed_url, html.len });
        return error.NoDataId;
    };

    // Step 2: the sources JSON for that data-id.
    const src_url = try std.fmt.allocPrint(arena, HOST ++ "/stream/getSources?id={s}", .{data_id});
    const raw = try request(arena, io, src_url, .xhr);
    return mapSources(arena, raw, tt);
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
/// subtitle at all. "thumbnails" tracks (the seekbar sprite sheet) are never
/// subtitles. Null when nothing qualifies. Tracks reach here already
/// argv-vetted by `mapSources`.
pub fn pickSubtitle(tracks: []const Track) ?[]const u8 {
    var english: ?[]const u8 = null;
    var first: ?[]const u8 = null;
    for (tracks) |t| {
        if (t.kind) |k| if (std.mem.eql(u8, k, "thumbnails")) continue;
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

/// An AniPub realid is a numeric id parsed out of the ep[] links. Enforce
/// digits-only before splicing it into a URL path, so a corrupt/hostile value
/// can't smuggle a traversal or a second segment (mirrors senshi.guardShowId).
fn guardRealId(realid: []const u8) !void {
    if (realid.len == 0) return error.InvalidRealId;
    for (realid) |c| if (!std.ascii.isDigit(c)) return error.InvalidRealId;
}

/// True if `s` is safe to place in a fetch URL / mpv argv: printable ASCII only
/// (0x21–0x7e), rejecting CR/LF, spaces and controls. Mirrors senshi's guard.
fn cleanArg(s: []const u8) bool {
    for (s) |c| if (c < 0x21 or c > 0x7e) return false;
    return true;
}

// ── HTTP ────────────────────────────────────────────────────────────────────────
// Same helper + error taxonomy as senshi/allanime (ROD-173), pending the shared
// providers/http.zig extraction (ROD-302). Keep the three in step until then.

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

// ── Tests ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseDataId scrapes the first numeric data-id, any quoting" {
    try testing.expectEqualStrings("13458", parseDataId(
        \\<div id="megaplay-player" data-id="13458" data-lang="sub">
    ).?);
    try testing.expectEqualStrings("13452", parseDataId("<div data-id='13452'>").?);
    try testing.expectEqualStrings("7", parseDataId("<div data-id=7 >").?);
    // First numeric one wins across multiple attributes.
    try testing.expectEqualStrings("11", parseDataId(
        \\<a data-id="11"></a><a data-id="22"></a>
    ).?);
}

test "parseDataId skips empty/non-numeric values and bounds the id" {
    // An empty or junk value keeps scanning to a later real one.
    try testing.expectEqualStrings("42", parseDataId(
        \\<a data-id=""></a><b data-id="x9"></b><c data-id="42"></c>
    ).?);
    try testing.expect(parseDataId("<html>no ids here</html>") == null);
    try testing.expect(parseDataId("") == null);
    // Over-long digit runs are rejected, not spliced into a URL.
    const long = "data-id=\"123456789012345678901\"";
    try testing.expect(parseDataId(long) == null);
}

test "guardRealId accepts a numeric realid, rejects traversal/injection" {
    try guardRealId("107259");
    try testing.expectError(error.InvalidRealId, guardRealId(""));
    try testing.expectError(error.InvalidRealId, guardRealId("../etc"));
    try testing.expectError(error.InvalidRealId, guardRealId("107259/x"));
    try testing.expectError(error.InvalidRealId, guardRealId("13458abc"));
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
    const s = try mapSources(a, raw, .sub);
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
    const d = try mapSources(a, raw, .dub);
    try testing.expect(d.link.sub_url == null);
}

test "pickSubtitle: default wins, english next, first as fallback, thumbnails never (ROD-354)" {
    const thumbs: Track = .{ .file = "https://c/thumbs.vtt", .kind = "thumbnails", .default = true };
    const spanish: Track = .{ .file = "https://c/spa.vtt", .label = "Spanish", .kind = "captions" };
    const english: Track = .{ .file = "https://c/eng.vtt", .label = "English - CR", .kind = "captions" };
    const eng_default: Track = .{ .file = "https://c/eng2.vtt", .label = "English", .kind = "captions", .default = true };
    const bare: Track = .{ .file = "https://c/bare.vtt" }; // no label/kind, live-observed shape

    // default beats an earlier english label; a default thumbnails track is not a sub.
    try testing.expectEqualStrings("https://c/eng2.vtt", pickSubtitle(&.{ thumbs, english, eng_default }).?);
    // no default: the english label wins over an earlier other language.
    try testing.expectEqualStrings("https://c/eng.vtt", pickSubtitle(&.{ spanish, english }).?);
    // no default, no english: first subtitle-shaped track.
    try testing.expectEqualStrings("https://c/spa.vtt", pickSubtitle(&.{ thumbs, spanish }).?);
    try testing.expectEqualStrings("https://c/bare.vtt", pickSubtitle(&.{bare}).?);
    // nothing but the sprite sheet, or nothing at all: no pick.
    try testing.expect(pickSubtitle(&.{thumbs}) == null);
    try testing.expect(pickSubtitle(&.{}) == null);
}

test "mapSources: missing or unsafe stream url is a clean error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectError(error.NoStreamSource, mapSources(a, "{}", .sub));
    try testing.expectError(error.NoStreamSource, mapSources(a,
        \\{"sources":{}}
    , .sub));
    // Relative url and an argv-unsafe url both refuse to reach mpv.
    try testing.expectError(error.BadStreamUrl, mapSources(a,
        \\{"sources":{"file":"/x/master.m3u8"}}
    , .sub));
    try testing.expectError(error.BadStreamUrl, mapSources(a,
        \\{"sources":{"file":"https://cdn/x master.m3u8"}}
    , .sub));
    // An unsafe TRACK url is dropped, not fatal; the stream still resolves,
    // and the dropped track can never become the sub pick.
    const s = try mapSources(a,
        \\{"sources":{"file":"https://cdn/ok.m3u8"},
        \\ "tracks":[{"file":"/relative.vtt","kind":"captions"}]}
    , .sub);
    try testing.expectEqual(@as(usize, 0), s.tracks.len);
    try testing.expect(s.link.sub_url == null);
}

test "skipFrom rejects degenerate windows, keeps real ones" {
    try testing.expect(skipFrom(null) == null);
    try testing.expect(skipFrom(.{ .start = 100, .end = null }) == null);
    try testing.expect(skipFrom(.{ .start = null, .end = 190 }) == null);
    try testing.expect(skipFrom(.{ .start = 190, .end = 100 }) == null); // inverted
    try testing.expect(skipFrom(.{ .start = 100, .end = 100 }) == null); // zero-width
    try testing.expect(skipFrom(.{ .start = -5, .end = 90 }) == null);
    try testing.expect(skipFrom(.{ .start = std.math.inf(f64), .end = 190 }) == null);
    const w = skipFrom(.{ .start = 0, .end = 90 }).?; // an OP at 0:00 is real
    try testing.expectEqual(@as(f64, 0), w.start);
    try testing.expectEqual(@as(f64, 90), w.end);
}
