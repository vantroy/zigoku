//! AniList metadata enrichment for Zigoku.
//!
//! This is deliberately **not** the playback path. AllAnime remains the source of
//! truth for search -> episodes -> resolve -> play. AniList is an enrichment side
//! rail that gives us durable metadata (cover art, synopsis, score, MAL/AniList ids)
//! when we can map a provider row to a single media entry with high confidence.

const std = @import("std");
const domain = @import("domain.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const ENDPOINT = "https://graphql.anilist.co";
// Shared selection set so the search and by-id queries can never drift apart.
const GQL_FIELDS = "id idMal title{romaji english native} episodes averageScore status season seasonYear startDate{year month day} format genres studios{nodes{name}} description(asHtml:false) coverImage{large}";
const GQL_SEARCH = "query($search:String!,$perPage:Int!){Page(perPage:$perPage){media(search:$search,type:ANIME,sort:SEARCH_MATCH){" ++ GQL_FIELDS ++ "}}}";
// Deterministic join: when AllAnime handed us an AniList id (mined from the
// cover url, ROD-181) we look the media up directly — no title matching.
const GQL_BY_ID = "query($id:Int!){Media(id:$id,type:ANIME){" ++ GQL_FIELDS ++ "}}";

// Both queries are interpolated raw into a JSON body with `{s}`, so they must
// contain nothing that needs JSON-string escaping. Enforce at comptime rather
// than reaching for std.json.stringify on a constant — if someone adds a quote
// or control char to the selection set, this fails the build, not a 400 at runtime.
comptime {
    for (GQL_SEARCH ++ GQL_BY_ID) |c| {
        if (c == '"' or c == '\\' or c < 0x20) {
            @compileError("GraphQL query contains a character that needs JSON escaping; build the request body with std.json instead of {s} interpolation");
        }
    }
}

pub const Metadata = struct {
    anilist_id: ?u64 = null,
    mal_id: ?u64 = null,
    title_english: ?[]const u8 = null,
    title_native: ?[]const u8 = null,
    thumb: ?[]const u8 = null,
    total_episodes: ?u32 = null,
    year: ?u32 = null,
    season: ?domain.Season = null,
    start_date: ?domain.Date = null,
    status: ?[]const u8 = null,
    /// AniList `format` (TV/MOVIE/OVA…) — populates `domain.Anime.kind`.
    kind: ?[]const u8 = null,
    /// Arena-owned at the call site (borrowed from the parsed JSON); the worker
    /// deep-copies into GPA before arena teardown. Empty slice = none provided.
    genres: []const []const u8 = &.{},
    studios: []const []const u8 = &.{},
    description: ?[]const u8 = null,
    score: ?u32 = null,
};

const Title = struct {
    romaji: ?[]const u8 = null,
    english: ?[]const u8 = null,
    native: ?[]const u8 = null,
};

const Cover = struct {
    large: ?[]const u8 = null,
};

const StartDate = struct {
    year: ?u32 = null,
    month: ?u32 = null,
    day: ?u32 = null,
};

const Studio = struct {
    name: ?[]const u8 = null,
};

// AniList nests studios as `studios{nodes{name}}`; default to an empty node list
// so a media entry that omits the field parses without error.
const Studios = struct {
    nodes: []const Studio = &.{},
};

const Media = struct {
    id: u64,
    idMal: ?u64 = null,
    title: Title = .{},
    episodes: ?u32 = null,
    averageScore: ?u32 = null,
    status: ?[]const u8 = null,
    season: ?[]const u8 = null,
    seasonYear: ?u32 = null,
    startDate: StartDate = .{},
    format: ?[]const u8 = null,
    genres: []const []const u8 = &.{},
    studios: Studios = .{},
    description: ?[]const u8 = null,
    coverImage: Cover = .{},
};

const Page = struct {
    media: []Media,
};

const Data = struct {
    Page: Page,
};

const Resp = struct {
    data: ?Data = null,
};

// by-id response shape: a single `Media` rather than a `Page` of them.
const MediaData = struct {
    Media: ?Media = null,
};

const MediaResp = struct {
    data: ?MediaData = null,
};

// NOTE: the show ← Metadata fill-if-null mapping lives in `workers.enrichTask`,
// not here. It has to: each filled field is deep-copied into GPA as it goes, so
// nothing aliases the parse arena that `Metadata`'s slices borrow from. A
// standalone `apply(show, meta)` helper would hand back a struct pointing into
// that soon-dead arena — a UAF trap — so there deliberately isn't one.

pub fn enrich(arena: Allocator, io: Io, show: domain.Anime) !?Metadata {
    // Deterministic path: AllAnime gave us the AniList id (mined from the cover
    // url, ROD-181). Look the media up by id — exact, no title matching, so the
    // "Nth Season" mismatch and sequel-ambiguity failures simply don't apply.
    if (show.anilist_id) |id| return enrichById(arena, io, id);
    return enrichBySearch(arena, io, show);
}

fn enrichById(arena: Allocator, io: Io, id: u64) !?Metadata {
    const body = try std.fmt.allocPrint(
        arena,
        "{{\"query\":\"{s}\",\"variables\":{{\"id\":{d}}}}}",
        .{ GQL_BY_ID, id },
    );
    const raw = postGql(arena, io, body) orelse return null;
    const parsed = std.json.parseFromSlice(MediaResp, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    const data = parsed.value.data orelse return null;
    const media = data.Media orelse return null;
    return try mediaToMeta(arena, media);
}

fn enrichBySearch(arena: Allocator, io: Io, show: domain.Anime) !?Metadata {
    const search = show.english_name orelse show.name;
    if (search.len == 0) return null;

    const body = try std.fmt.allocPrint(
        arena,
        "{{\"query\":\"{s}\",\"variables\":{{\"search\":\"{s}\",\"perPage\":8}}}}",
        .{ GQL_SEARCH, try jsonEscape(arena, search) },
    );
    const raw = postGql(arena, io, body) orelse return null;
    const parsed = std.json.parseFromSlice(Resp, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    const data = parsed.value.data orelse return null;
    const best = bestMatch(show, data.Page.media) orelse return null;
    return try mediaToMeta(arena, best);
}

/// POST a GraphQL body to AniList; returns the response bytes (arena-owned) or
/// null on transport/HTTP failure. Caller parses the shape it expects.
fn postGql(arena: Allocator, io: Io, body: []const u8) ?[]const u8 {
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

fn mediaToMeta(arena: Allocator, m: Media) !Metadata {
    return .{
        .anilist_id = m.id,
        .mal_id = m.idMal,
        .title_english = m.title.english,
        .title_native = m.title.native,
        .thumb = m.coverImage.large,
        .total_episodes = m.episodes,
        .year = m.seasonYear,
        .season = if (m.season) |s| domain.Season.fromString(s) else null,
        .start_date = startDate(m.startDate),
        .status = m.status,
        .kind = m.format,
        .genres = m.genres, // arena-borrowed; the worker deep-copies into GPA
        .studios = try studioNames(arena, m.studios),
        .description = if (m.description) |d| try sanitizeDescription(arena, d) else null,
        .score = m.averageScore,
    };
}

/// Lift AniList's `startDate` into a `domain.Date`. The year anchors the date —
/// without it AniList sends `{year:null,month:null,day:null}`, which is "no date"
/// (e.g. an unannounced show), not a partial one.
fn startDate(sd: StartDate) ?domain.Date {
    const y = sd.year orelse return null;
    return .{ .year = y, .month = sd.month, .day = sd.day };
}

/// Flatten `studios{nodes{name}}` into a flat name slice, dropping any node that
/// somehow lacks a name. Arena-owned (slice + borrowed name bytes); the worker
/// deep-copies into GPA. Returns `&.{}` when there are no studios.
fn studioNames(arena: Allocator, s: Studios) ![]const []const u8 {
    var count: usize = 0;
    for (s.nodes) |node| {
        if (node.name != null) count += 1;
    }
    if (count == 0) return &.{};
    const out = try arena.alloc([]const u8, count); // exact fit, no slack slots
    var i: usize = 0;
    for (s.nodes) |node| {
        if (node.name) |name| {
            out[i] = name;
            i += 1;
        }
    }
    return out;
}

fn bestMatch(show: domain.Anime, media: []const Media) ?Media {
    if (media.len == 0) return null;

    var best_idx: ?usize = null;
    var best_score: i32 = std.math.minInt(i32);
    var second_score: i32 = std.math.minInt(i32);

    for (media, 0..) |m, i| {
        const score = candidateScore(show, m);
        if (score > best_score) {
            second_score = best_score;
            best_score = score;
            best_idx = i;
        } else if (score > second_score) {
            second_score = score;
        }
    }

    const idx = best_idx orelse return null;
    if (best_score < 1200) return null;
    if (second_score >= 0 and best_score - second_score < 250) return null;
    return media[idx];
}

fn candidateScore(show: domain.Anime, m: Media) i32 {
    var score: i32 = std.math.minInt(i32) / 4;

    score = @max(score, titleScore(show.name, m.title.romaji));
    score = @max(score, titleScore(show.name, m.title.english));
    score = @max(score, titleScore(show.name, m.title.native));
    if (show.english_name) |eng| {
        score = @max(score, titleScore(eng, m.title.romaji));
        score = @max(score, titleScore(eng, m.title.english));
        score = @max(score, titleScore(eng, m.title.native));
    }
    if (score < 0) return score;

    const avail_eps = @max(show.eps_sub, show.eps_dub);
    if (avail_eps > 0) {
        if (m.episodes) |episodes| {
            if (episodes + 2 < avail_eps) return -4000; // impossible or wildly wrong
            const diff = absDiffU32(avail_eps, episodes);
            if (diff == 0) {
                score += 180;
            } else if (diff <= 1) {
                score += 120;
            } else if (diff <= 3) {
                score += 60;
            } else if (episodes < avail_eps) {
                score -= 120;
            }
        }
    }

    if (show.year) |year| {
        if (m.seasonYear) |my| {
            const diff = absDiffU32(year, my);
            if (diff == 0) {
                score += 120;
            } else if (diff == 1) {
                score += 40;
            } else {
                score -= 160;
            }
        }
    }

    return score;
}

fn titleScore(a: []const u8, b_opt: ?[]const u8) i32 {
    const b = b_opt orelse return -5000;
    if (a.len == 0 or b.len == 0) return -5000;

    var buf_a: [256]u8 = undefined;
    var buf_b: [256]u8 = undefined;
    var sbuf_a: [256]u8 = undefined;
    var sbuf_b: [256]u8 = undefined;
    const na = canonSeason(&sbuf_a, normalizeTitle(&buf_a, a));
    const nb = canonSeason(&sbuf_b, normalizeTitle(&buf_b, b));
    if (na.len == 0 or nb.len == 0) return -5000;

    if (std.mem.eql(u8, na, nb)) return 1600;
    if (std.mem.startsWith(u8, nb, na) or std.mem.startsWith(u8, na, nb)) return 1250;
    if (std.mem.indexOf(u8, nb, na) != null or std.mem.indexOf(u8, na, nb) != null) return 900;
    return -5000;
}

/// Canonicalize an explicit "Season N" / "Nth Season" marker in an
/// already-normalized title to a single `s<N>` token, so AllAnime's `…season2`
/// reconciles with AniList's `…2ndseason` form (ROD-181, the fuzzy fallback for
/// the ~13% of shows with no mineable AniList id). Only the explicit `season`
/// keyword is coerced — a bare trailing number ("title 2") is left alone, as it
/// is too ambiguous to fold safely (cf. "86", "Ranma 1/2"). Returns `s` verbatim
/// when there is no season marker or on any buffer overflow.
fn canonSeason(out: []u8, s: []const u8) []const u8 {
    const kw = "season";
    const idx = std.mem.indexOf(u8, s, kw) orelse return s;
    const before = s[0..idx];
    const after = s[idx + kw.len ..];

    // Form A: digits directly after the keyword ("season2").
    var dlen: usize = 0;
    while (dlen < after.len and std.ascii.isDigit(after[dlen])) dlen += 1;
    var num: []const u8 = after[0..dlen];
    var base_pre: []const u8 = before;
    var tail: []const u8 = after[dlen..];

    if (dlen == 0) {
        // Form B: digits (+ ordinal) directly before the keyword ("2ndseason").
        var b = before;
        inline for (.{ "st", "nd", "rd", "th" }) |ord| {
            if (std.mem.endsWith(u8, b, ord)) {
                b = b[0 .. b.len - ord.len];
                break;
            }
        }
        var dstart = b.len;
        while (dstart > 0 and std.ascii.isDigit(b[dstart - 1])) dstart -= 1;
        if (dstart == b.len) return s; // "season" with no adjacent number — leave it
        num = b[dstart..];
        base_pre = b[0..dstart];
        tail = after;
    }

    var n: usize = 0;
    inline for (.{ base_pre, "s", num, tail }) |part| {
        if (n + part.len > out.len) return s; // overflow → bail to original
        @memcpy(out[n .. n + part.len], part);
        n += part.len;
    }
    return out[0..n];
}

fn normalizeTitle(buf: []u8, s: []const u8) []const u8 {
    var out_len: usize = 0;
    for (s) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        if (c < 0x80) {
            if (std.ascii.isAlphanumeric(c)) {
                if (out_len == buf.len) break;
                buf[out_len] = std.ascii.toLower(c);
                out_len += 1;
            }
            continue;
        }
        if (out_len == buf.len) break;
        buf[out_len] = c;
        out_len += 1;
    }
    return buf[0..out_len];
}

fn absDiffU32(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

fn sanitizeDescription(arena: Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_tag = false;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (in_tag) {
            if (c == '>') in_tag = false;
            continue;
        }
        if (c == '<') {
            in_tag = true;
            continue;
        }
        if (c == '&') {
            if (std.mem.startsWith(u8, raw[i..], "&amp;")) {
                try out.append(arena, '&');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "&quot;")) {
                try out.append(arena, '"');
                i += 5;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "&#039;")) {
                try out.append(arena, '\'');
                i += 5;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "&lt;")) {
                try out.append(arena, '<');
                i += 3;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "&gt;")) {
                try out.append(arena, '>');
                i += 3;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "&mdash;")) {
                try out.append(arena, '-');
                try out.append(arena, '-');
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "&ndash;")) {
                try out.append(arena, '-');
                i += 6;
                continue;
            }
        }
        if (c == '\n' or c == '\r' or c == '\t') {
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') try out.append(arena, ' ');
            continue;
        }
        try out.append(arena, c);
    }
    return std.mem.trim(u8, out.items, " ");
}

fn jsonEscape(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        else => if (c < 0x20) {
            const hex = "0123456789abcdef";
            try out.appendSlice(arena, "\\u00");
            try out.append(arena, hex[(c >> 4) & 0xf]);
            try out.append(arena, hex[c & 0xf]);
        } else try out.append(arena, c),
    };
    return out.items;
}

test "normalizeTitle folds ASCII punctuation and whitespace" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("frierenbeyondjourneysend", normalizeTitle(&buf, "Frieren: Beyond Journey's End"));
}

test "titleScore prefers exact over prefix over substring" {
    try std.testing.expect(titleScore("Frieren", "Frieren") > titleScore("Frieren", "Frieren Season 2"));
    try std.testing.expect(titleScore("Frieren", "Frieren Season 2") > titleScore("Frieren", "The World of Frieren"));
}

test "canonSeason: reconciles Season N and Nth Season, leaves the rest (ROD-181)" {
    var buf: [256]u8 = undefined;
    // Form A ("season<n>") and Form B ("<n>ordinal season") collapse identically.
    try std.testing.expectEqualStrings("frierens2", canonSeason(&buf, "frierenseason2"));
    try std.testing.expectEqualStrings("frierens2", canonSeason(&buf, "frieren2ndseason"));
    try std.testing.expectEqualStrings("ks3", canonSeason(&buf, "k3rdseason"));
    // Form B without an ordinal: a bare digit directly before the keyword.
    try std.testing.expectEqualStrings("titles2", canonSeason(&buf, "title2season"));
    // No keyword → verbatim. Bare trailing number → intentionally NOT coerced.
    try std.testing.expectEqualStrings("frieren", canonSeason(&buf, "frieren"));
    try std.testing.expectEqualStrings("loghorizon2", canonSeason(&buf, "loghorizon2"));
    // "season" with no adjacent number is left alone (e.g. a literal word).
    try std.testing.expectEqualStrings("seasonsoflife", canonSeason(&buf, "seasonsoflife"));
}

test "titleScore reconciles 'Season N' vs 'Nth Season' (ROD-181)" {
    // The exact failing pair: AllAnime '… Season 2' vs AniList '… 2nd Season'.
    try std.testing.expectEqual(@as(i32, 1600), titleScore("Sousou no Frieren Season 2", "Sousou no Frieren 2nd Season"));
    // A base title must still not score as an exact match for its sequel.
    try std.testing.expect(titleScore("Frieren Season 2", "Frieren") < 1600);
}

test "bestMatch rejects ambiguous close titles" {
    const show: domain.Anime = .{ .id = "x", .name = "Bleach" };
    const candidates = [_]Media{
        .{ .id = 1, .title = .{ .romaji = "Bleach" } },
        .{ .id = 2, .title = .{ .english = "Bleach" } },
    };
    try std.testing.expect(bestMatch(show, &candidates) == null);
}

test "bestMatch accepts unique exact title with episode sanity" {
    const show: domain.Anime = .{ .id = "x", .name = "Frieren", .eps_sub = 28 };
    const candidates = [_]Media{
        .{ .id = 1, .title = .{ .romaji = "Frieren" }, .episodes = 28 },
        .{ .id = 2, .title = .{ .romaji = "Frieren Specials" }, .episodes = 3 },
    };
    const best = bestMatch(show, &candidates) orelse return error.TestExpectationFailed;
    try std.testing.expectEqual(@as(u64, 1), best.id);
}

test "mediaToMeta maps the widened by-id response shape (ROD-140)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The exact by-id response shape, with every widened field populated and an
    // unknown field (siteUrl) that ignore_unknown_fields must skip.
    const json =
        \\{"data":{"Media":{"id":182255,"idMal":52991,"title":{"romaji":"Sousou no Frieren","english":"Frieren: Beyond Journey's End","native":"葬送のフリーレン"},"episodes":28,"averageScore":89,"status":"FINISHED","season":"FALL","seasonYear":2023,"startDate":{"year":2023,"month":9,"day":29},"format":"TV","genres":["Adventure","Drama","Fantasy"],"studios":{"nodes":[{"name":"Madhouse"}]},"description":"<i>An elf</i> &amp; her party.","coverImage":{"large":"https://img/large.jpg"},"siteUrl":"https://anilist.co/anime/182255"}}}
    ;
    const parsed = try std.json.parseFromSlice(MediaResp, a, json, .{ .ignore_unknown_fields = true });
    const meta = try mediaToMeta(a, parsed.value.data.?.Media.?);

    try std.testing.expectEqual(@as(?u64, 182255), meta.anilist_id);
    try std.testing.expectEqualStrings("葬送のフリーレン", meta.title_native.?);
    try std.testing.expectEqual(domain.Season.fall, meta.season.?);
    try std.testing.expectEqual(@as(u32, 2023), meta.start_date.?.year);
    try std.testing.expectEqual(@as(?u32, 9), meta.start_date.?.month);
    try std.testing.expectEqual(@as(?u32, 29), meta.start_date.?.day);
    try std.testing.expectEqualStrings("TV", meta.kind.?);
    try std.testing.expectEqual(@as(usize, 3), meta.genres.len);
    try std.testing.expectEqualStrings("Fantasy", meta.genres[2]);
    try std.testing.expectEqual(@as(usize, 1), meta.studios.len);
    try std.testing.expectEqualStrings("Madhouse", meta.studios[0]);
    try std.testing.expectEqualStrings("An elf & her party.", meta.description.?);
}

test "sanitizeDescription strips tags and decodes common entities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "Hello & goodbye \"hero\" -- now",
        try sanitizeDescription(arena.allocator(), "<i>Hello</i> &amp; goodbye &quot;hero&quot; &mdash; now"),
    );
}
