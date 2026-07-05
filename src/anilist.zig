//! AniList metadata enrichment for Zigoku.
//!
//! This is deliberately **not** the playback path. AllAnime remains the source of
//! truth for search -> episodes -> resolve -> play. AniList is an enrichment side
//! rail that gives us durable metadata (cover art, synopsis, score, MAL/AniList ids)
//! when we can map a provider row to a single media entry with high confidence.

const std = @import("std");
const domain = @import("domain.zig");
const deadline = @import("util/deadline.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const ENDPOINT = "https://graphql.anilist.co";
// Wall-clock ceiling on any single enrichment POST (ROD-262). std exposes no
// per-read socket timeout, so a reachable-but-silent AniList would otherwise hang
// the worker forever (a real hazard once ROD-251 detached these fetches — each
// stuck one leaks a thread + the 2 MB buffer below). Tighter than AllAnime's 20 s:
// enrichment is a background side rail, not the user-blocking playback path, and
// one GraphQL POST (even a 50-id batch) is a single round trip.
const ANILIST_DEADLINE_S = 10;
// Shared selection set so the search and by-id queries can never drift apart.
const GQL_FIELDS = "id idMal title{romaji english native} episodes duration averageScore status season seasonYear startDate{year month day} format source countryOfOrigin genres studios(isMain:true){nodes{name}} rankings{rank type year allTime} nextAiringEpisode{episode airingAt} description(asHtml:false) coverImage{large}";
const GQL_SEARCH = "query($search:String!,$perPage:Int!){Page(perPage:$perPage){media(search:$search,type:ANIME,sort:SEARCH_MATCH){" ++ GQL_FIELDS ++ "}}}";
// Deterministic join: when AllAnime handed us an AniList id (mined from the
// cover url, ROD-181) we look the media up directly — no title matching.
const GQL_BY_ID = "query($id:Int!){Media(id:$id,type:ANIME){" ++ GQL_FIELDS ++ "}}";
// ROD-247 batched Discover enrichment: the card-signal subset only. Deliberately
// NARROWER than GQL_FIELDS — no `description`, title, or studios — so one fetch
// hydrating a whole page (~30-50 cards) stays light. The synopsis stays lazy-on-
// zoom (workers.discoverEnrichTask, keyed on `description == null`); fetching
// dozens of synopses per page would be bytes for text nobody's reading yet. Keep
// this set and GQL_FIELDS divergent on purpose.
const GQL_BATCH_FIELDS = "id averageScore genres season seasonYear startDate{year}";

// Both queries are interpolated raw into a JSON body with `{s}`, so they must
// contain nothing that needs JSON-string escaping. Enforce at comptime rather
// than reaching for std.json.stringify on a constant — if someone adds a quote
// or control char to the selection set, this fails the build, not a 400 at runtime.
comptime {
    for (GQL_SEARCH ++ GQL_BY_ID ++ GQL_BATCH_FIELDS) |c| {
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
    /// Per-episode runtime in minutes (ROD-261).
    duration: ?u32 = null,
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
    /// AniList `source` enum (MANGA/LIGHT_NOVEL/ORIGINAL…), stored raw and
    /// prettified at render (ROD-261). Named `source_material` to avoid clashing
    /// with the provider `source` key used across the store.
    source_material: ?[]const u8 = null,
    /// The single ranking selected from AniList's `rankings` array by `selectRank`
    /// (ROD-261): rank position, type ("RATED"/"POPULAR"), and year — null year
    /// means an all-time ranking. Rendered rail-only as `#{rank} {type} {year}`.
    rank: ?u32 = null,
    rank_type: ?[]const u8 = null,
    rank_year: ?u32 = null,
    /// Next-episode airing (ROD-261): the absolute `airingAt` unix timestamp and
    /// the episode number. Persisted absolute so the countdown recomputes from the
    /// live clock at render, surviving restarts (the relative `timeUntilAiring`
    /// would go stale). Present only for currently-airing shows.
    next_airing_at: ?i64 = null,
    next_airing_episode: ?u32 = null,
    /// AniList `countryOfOrigin` (JP/CN/KR…) — surfaced only when not JP (ROD-261).
    country: ?[]const u8 = null,
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

// One entry of AniList's `rankings` array (ROD-261). `type` is RATED or POPULAR;
// `allTime` distinguishes an all-time ranking from a year/season-scoped one. We
// keep only what `selectRank` needs to pick and render the best one.
const Ranking = struct {
    rank: u32 = 0,
    type: ?[]const u8 = null,
    year: ?u32 = null,
    allTime: bool = false,
};

// AniList `nextAiringEpisode` (ROD-261) — the next episode's absolute airing
// timestamp. Null on the media entirely for a finished/unscheduled show.
const NextAiring = struct {
    episode: ?u32 = null,
    airingAt: ?i64 = null,
};

const Media = struct {
    id: u64,
    idMal: ?u64 = null,
    title: Title = .{},
    episodes: ?u32 = null,
    duration: ?u32 = null,
    averageScore: ?u32 = null,
    status: ?[]const u8 = null,
    season: ?[]const u8 = null,
    seasonYear: ?u32 = null,
    startDate: StartDate = .{},
    format: ?[]const u8 = null,
    source: ?[]const u8 = null,
    countryOfOrigin: ?[]const u8 = null,
    genres: []const []const u8 = &.{},
    studios: Studios = .{},
    rankings: []const Ranking = &.{},
    nextAiringEpisode: ?NextAiring = null,
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

/// The three-state enrich contract (ROD-278). Callers that stamp an enrichment
/// freshness clock (the refresh-on-view path) MUST distinguish a confirmed answer
/// from a failed fetch: only a confirmed answer may advance the clock.
///   * `Metadata`        — a confirmed match.            → stamp fresh
///   * `null`            — a *confirmed* no-match: AniList was reached and
///                         definitively returned nothing (no such id, no search
///                         hit, or nothing to look up). → stamp fresh (negative cache)
///   * `error.NoAnswer`  — no confirmed answer: transport error, timeout, non-200,
///                         over-cap body, a malformed 200, or a `{"data":null}`
///                         GraphQL-level error. → DON'T stamp; retry on next view.
/// Value (incl. `null`) means "AniList answered"; the error arm means "it didn't."
pub const EnrichError = error{NoAnswer} || Allocator.Error;

pub fn enrich(arena: Allocator, io: Io, show: domain.Anime) EnrichError!?Metadata {
    // Deterministic path: AllAnime gave us the AniList id (mined from the cover
    // url, ROD-181). Look the media up by id — exact, no title matching, so the
    // "Nth Season" mismatch and sequel-ambiguity failures simply don't apply.
    if (show.anilist_id) |id| return enrichById(arena, io, id);
    return enrichBySearch(arena, io, show);
}

fn enrichById(arena: Allocator, io: Io, id: u64) EnrichError!?Metadata {
    const body = try std.fmt.allocPrint(
        arena,
        "{{\"query\":\"{s}\",\"variables\":{{\"id\":{d}}}}}",
        .{ GQL_BY_ID, id },
    );
    // postGql returns null on any transport failure (network/timeout/non-200/
    // over-cap) — that is "no answer", not a confirmed no-match, so it errors.
    const raw = postGql(arena, io, body) orelse return error.NoAnswer;
    return classifyById(arena, raw);
}

/// Map a by-id AniList response body to the three-state contract. Split from the
/// POST so the null-vs-error classification is unit-testable without a live fetch.
fn classifyById(arena: Allocator, raw: []const u8) EnrichError!?Metadata {
    // A 200 we can't parse, or a `{"data":null}` GraphQL-level error, is a
    // malformed/failed answer — not a no-match. Error so the row retries.
    const parsed = std.json.parseFromSlice(MediaResp, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return error.NoAnswer;
    const data = parsed.value.data orelse return error.NoAnswer;
    // `{"data":{"Media":null}}` IS a confirmed answer: no anime carries that id.
    const media = data.Media orelse return null;
    return try mediaToMeta(arena, media);
}

fn enrichBySearch(arena: Allocator, io: Io, show: domain.Anime) EnrichError!?Metadata {
    const search = show.english_name orelse show.name;
    // Nothing to look up — a confirmed "no title, no possible match", not a fetch
    // failure. Return null so the refresh path stamps it (negative cache) rather
    // than re-attempting a doomed search on every view.
    if (search.len == 0) return null;

    const body = try std.fmt.allocPrint(
        arena,
        "{{\"query\":\"{s}\",\"variables\":{{\"search\":\"{s}\",\"perPage\":8}}}}",
        .{ GQL_SEARCH, try jsonEscape(arena, search) },
    );
    const raw = postGql(arena, io, body) orelse return error.NoAnswer;
    return classifyBySearch(arena, show, raw);
}

/// Map a search AniList response body to the three-state contract. Split from the
/// POST so the null-vs-error classification is unit-testable without a live fetch.
fn classifyBySearch(arena: Allocator, show: domain.Anime, raw: []const u8) EnrichError!?Metadata {
    const parsed = std.json.parseFromSlice(Resp, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return error.NoAnswer;
    const data = parsed.value.data orelse return error.NoAnswer;
    // Reached AniList and ran the match: an empty page or a page where nothing
    // clears bestMatch's guard is a confirmed no-match, not a fetch failure.
    const best = bestMatch(show, data.Page.media) orelse return null;
    return try mediaToMeta(arena, best);
}

/// Batch-enrich a page of Discover cards in ONE AniList round trip (ROD-247).
/// `ids` are AniList media ids the caller mined from cover thumbs; cards without
/// one are filtered out upstream. Returns an arena-owned `Metadata` per returned
/// media, each tagged with its `anilist_id` (via `mediaToMeta`) so the caller can
/// join results back to cards by id — AniList does not guarantee response order
/// matches `ids`.
///
/// Same three-state contract as `enrich` (ROD-278), so the caller can gate a
/// freshness stamp on whether AniList actually answered:
///   * a non-empty (or empty) slice — AniList was REACHED: the page hydrates from
///     the returned media; an empty slice is a confirmed "no matches for these ids"
///     (or nothing to fetch — `ids.len == 0`). The caller may stamp fresh.
///   * `error.NoAnswer` — a transport/HTTP/over-cap/timeout miss or a malformed 200
///     (postGql returned null, or the body wouldn't parse). The whole page degrades
///     to `[--]` AND the caller must NOT stamp — a failed batch fetch would otherwise
///     burn the freshness clock on a page of un-enriched cards.
pub fn enrichBatch(arena: Allocator, io: Io, ids: []const u64) EnrichError![]const Metadata {
    if (ids.len == 0) return &.{};

    // `id_in:[1,2,3]` — integers only, so the list is JSON-safe interpolated raw,
    // the same trust basis as the comptime-guarded GQL_BATCH_FIELDS.
    var ids_buf: std.ArrayList(u8) = .empty;
    try ids_buf.append(arena, '[');
    for (ids, 0..) |id, i| {
        if (i != 0) try ids_buf.append(arena, ',');
        try ids_buf.print(arena, "{d}", .{id});
    }
    try ids_buf.append(arena, ']');

    // `perPage:{d}` is `ids.len`, which relies on AniList capping Page.perPage at 50:
    // the caller feeds at most one feed page (popular_page_size = 30 in source.zig), so
    // ids.len ≤ 50 holds today. If the feed page size is ever raised past 50, AniList
    // 400s the whole query → postGql returns null → error.NoAnswer → the page degrades
    // to `[--]` and stays un-stamped. Chunk the ids (or clamp perPage) before that line.
    //
    // GQL_BATCH_FIELDS is passed as a `{s}` ARG, never concatenated into the format
    // string — it contains `startDate{year}`, whose braces the format parser would
    // read as a `{year}` placeholder ("too few arguments"). As an arg its contents
    // are data, not format syntax.
    const query = try std.fmt.allocPrint(
        arena,
        "query{{Page(perPage:{d}){{media(id_in:{s},type:ANIME){{{s}}}}}}}",
        .{ ids.len, ids_buf.items, GQL_BATCH_FIELDS },
    );
    const body = try std.fmt.allocPrint(arena, "{{\"query\":\"{s}\"}}", .{query});

    // A transport miss (null response) is "no answer" — error so the caller leaves
    // the page un-stamped. pageToMetas classifies the rest of the three-state contract
    // (malformed 200 / {"data":null} → error.NoAnswer, empty page → &.{}) and returns
    // the same EnrichError set, so it propagates directly — no re-wrap (which would
    // relabel a genuine OutOfMemory as NoAnswer and lose the diagnostic).
    const raw = postGql(arena, io, body) orelse return error.NoAnswer;
    return pageToMetas(arena, raw);
}

/// Parse a `Page`-shaped AniList response into one `Metadata` per media. Split
/// from `enrichBatch` so the mapping is unit-testable without a live POST (same
/// seam as `mediaToMeta`). Arena-borrowed slices; the worker deep-copies to GPA.
///
/// Classifies `data == null` the same way `classifyById`/`classifyBySearch` do
/// (ROD-278): a `{"data":null}` body is a GraphQL-level execution error (a 200 with
/// no data), NOT a confirmed-empty page — return `error.NoAnswer` so `enrichBatch`
/// reports "no answer" and the caller leaves the page un-stamped. A parsed page with
/// zero media IS a confirmed empty answer and returns an empty slice.
fn pageToMetas(arena: Allocator, raw: []const u8) EnrichError![]const Metadata {
    // A malformed 200 (unparseable body) is a failed answer, not an empty page —
    // error, same as classifyById/classifyBySearch, so pageToMetas honors the
    // three-state contract on its own (and is unit-testable for it).
    const parsed = std.json.parseFromSlice(Resp, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return error.NoAnswer;
    const data = parsed.value.data orelse return error.NoAnswer;
    const media = data.Page.media;
    const out = try arena.alloc(Metadata, media.len);
    for (media, 0..) |m, i| out[i] = try mediaToMeta(arena, m);
    return out;
}

/// The raw HTTP outcome of one GraphQL POST — the status code kept alongside the
/// body so an authed caller (the ROD-284 push) can distinguish a 429 rate-limit
/// from a 401 from a hard failure. Enrichment collapses all of it to null; see
/// `postGql`.
pub const HttpResult = struct { status: std.http.Status, body: []const u8 };

/// One GraphQL POST to AniList. `bearer`, when present, rides as an
/// `Authorization: Bearer` header — null for the unauthenticated enrichment
/// queries, set for the authed push mutations (ROD-284). Returns the raw {status,
/// body}: the status check is deliberately the caller's, because enrichment wants
/// "non-200 → null" while the push branches on 429/401 vs. success.
///
/// One POST, run as a cancelable unit of concurrency by `withDeadline` (ROD-262).
/// Kept `!`-returning so the deadline race can tell a real result from a timeout:
/// on a stalled fetch the deadline's cancel turns the blocked recv into
/// error.Canceled, so this frame unwinds — freeing `client` — instead of hanging.
fn fetchGql(arena: Allocator, io: Io, body: []const u8, bearer: ?[]const u8) !HttpResult {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    // Cap the response at a fixed buffer rather than an unbounded Allocating writer
    // (ROD-247): a hostile/MITM'd server could otherwise dribble a multi-GB body and
    // OOM the process. Any real AniList reply (even a 50-id batch) is well under
    // 100 KB; 2 MB is a 20× margin. An over-cap body overflows the fixed writer →
    // fetch errors → null (graceful "no enrichment"), mirroring the cover path.
    const resp_buf = try arena.alloc(u8, 2 * 1024 * 1024);
    var resp_w: std.Io.Writer = .fixed(resp_buf);

    // Content-Type/Accept are constant; Authorization is optional, built into the
    // arena and appended only when a token is supplied. A fixed 3-slot array keeps
    // the header set on the stack — no allocation for the common unauthed case.
    var header_buf: [3]std.http.Header = .{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json" },
        undefined,
    };
    var headers: []const std.http.Header = header_buf[0..2];
    if (bearer) |tok| {
        header_buf[2] = .{ .name = "Authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{tok}) };
        headers = header_buf[0..3];
    }

    const res = try client.fetch(.{
        .location = .{ .url = ENDPOINT },
        .method = .POST,
        .payload = body,
        .response_writer = &resp_w,
        .extra_headers = headers,
    });
    return .{ .status = res.status, .body = resp_w.buffered() };
}

/// A GraphQL POST bounded by `ANILIST_DEADLINE_S` (ROD-262), returning the raw
/// {status, body} or null when the request never completes — transport error,
/// over-cap body, or the deadline firing. The HTTP status inside a returned result
/// may still be non-200; classifying that is the caller's job. Shared by
/// enrichment (`postGql`) and the authed push (`saveMediaListEntry`).
fn postGqlRaw(arena: Allocator, io: Io, body: []const u8, bearer: ?[]const u8) ?HttpResult {
    return deadline.withDeadline(io, .fromSeconds(ANILIST_DEADLINE_S), fetchGql, .{ arena, io, body, bearer }) catch |e| {
        if (e == error.Timeout)
            log.debug("anilist POST aborted past {d}s deadline", .{ANILIST_DEADLINE_S});
        return null;
    };
}

/// Enrichment POST: the unauthenticated queries. Every failure — network error,
/// non-200, over-cap body, or the deadline firing — collapses to `null`, the "no
/// enrichment" signal every caller already handles. The push path uses
/// `postGqlRaw` directly so it can see the status code.
fn postGql(arena: Allocator, io: Io, body: []const u8) ?[]const u8 {
    const r = postGqlRaw(arena, io, body, null) orelse return null;
    if (r.status != .ok) return null;
    return r.body;
}

// ── AniList push: SaveMediaListEntry (ROD-284) ───────────────────────────────

/// Map a local list status to AniList's `MediaListStatus` enum. Total and clean:
/// AniList's REPEATING has no local twin, but it only arises on *pull* (ROD-285) —
/// every local status maps outward to exactly one AniList value.
pub fn aniListStatus(s: domain.ListStatus) []const u8 {
    return switch (s) {
        .planning => "PLANNING",
        .watching => "CURRENT",
        .paused => "PAUSED",
        .completed => "COMPLETED",
        .dropped => "DROPPED",
    };
}

/// A push either lands (AniList returns the upserted entry id), hits a rate limit
/// (429 — the engine backs off), finds the token rejected (401 — re-auth needed,
/// stop the run), or fails otherwise. Distinct arms so the ROD-284 engine reacts
/// per case instead of collapsing everything to "didn't work".
pub const PushError = error{ RateLimited, Unauthorized, PushFailed } || Allocator.Error;

const SAVE_MUTATION = "mutation($mediaId:Int,$status:MediaListStatus,$progress:Int){SaveMediaListEntry(mediaId:$mediaId,status:$status,progress:$progress){id}}";

// Interpolated raw into the JSON body with `{s}` (like the enrichment queries), so
// it must carry nothing that needs JSON-string escaping — enforced at comptime.
comptime {
    for (SAVE_MUTATION) |ch| {
        if (ch == '"' or ch == '\\' or ch < 0x20)
            @compileError("SAVE_MUTATION contains a character that needs JSON escaping; build the body with std.json instead of {s} interpolation");
    }
}

/// Upsert one show's watch-state to AniList via `SaveMediaListEntry` (ROD-284).
/// Idempotent — AniList upserts keyed on `mediaId`, so re-pushing an unchanged row
/// is a no-op on their side. Returns the media-list entry id on success. `bearer`
/// is the OAuth access token (auth.zon); `media_id` is `anime.anilist_id`.
pub fn saveMediaListEntry(
    arena: Allocator,
    io: Io,
    bearer: []const u8,
    media_id: i64,
    status: domain.ListStatus,
    progress: i64,
) PushError!i64 {
    // Values ride as GraphQL variables — never interpolated into the query — so a
    // media id or status can't break out of the string. The status enum passes as a
    // JSON string, which AniList accepts for a MediaListStatus variable. The values
    // are all integers or a fixed enum literal, so the variables object is JSON-safe
    // built with `{d}`/`{s}` on the same trust basis as GQL_BATCH_FIELDS.
    const body = try std.fmt.allocPrint(
        arena,
        "{{\"query\":\"{s}\",\"variables\":{{\"mediaId\":{d},\"status\":\"{s}\",\"progress\":{d}}}}}",
        .{ SAVE_MUTATION, media_id, aniListStatus(status), progress },
    );
    const r = postGqlRaw(arena, io, body, bearer) orelse return error.PushFailed;
    return classifySave(arena, r);
}

/// Map the raw {status, body} of a SaveMediaListEntry POST to the PushError
/// contract. Split from the POST so the branching is unit-testable without a live
/// mutation. A 200 whose body carries no `SaveMediaListEntry.id` (a GraphQL-level
/// error, or `{"data":null}`) is a failed push, not a silent success.
fn classifySave(arena: Allocator, r: HttpResult) PushError!i64 {
    switch (r.status) {
        .ok => {},
        .too_many_requests => return error.RateLimited, // 429 — engine backs off
        .unauthorized => return error.Unauthorized, // 401 — token re-auth
        else => return error.PushFailed,
    }

    const parsed = std.json.parseFromSlice(SaveResp, arena, r.body, .{
        .ignore_unknown_fields = true,
    }) catch return error.PushFailed;
    const data = parsed.value.data orelse return error.PushFailed;
    const entry = data.SaveMediaListEntry orelse return error.PushFailed;
    // `id` is `?i64`: a 200 whose entry object omits `id` (a `{}` — API/schema drift,
    // or a MITM) is "field present but empty", which must NOT read as a landed push.
    // Only a real id counts, or the snapshot would advance on a push that never was.
    return entry.id orelse error.PushFailed;
}

const SaveResp = struct { data: ?SaveData = null };
const SaveData = struct { SaveMediaListEntry: ?SaveEntry = null };
const SaveEntry = struct { id: ?i64 = null };

// ── AniList pull: MediaListCollection (ROD-285) ──────────────────────────────

/// One reconciled entry from the remote list: the AniList media id (== our
/// `anilist_id`) plus the (status, progress) AniList currently holds. This is the
/// remote leg of the ROD-285 3-way merge; the reconcile engine joins it to a local
/// row by `media_id`. REPEATING has already been folded to `.watching` by
/// `fromAniListStatus`, so `status` is always a local `domain.ListStatus`.
pub const PulledEntry = struct {
    media_id: i64,
    status: domain.ListStatus,
    progress: i64,
};

/// Map an AniList `MediaListStatus` to the local `domain.ListStatus`. AniList's
/// REPEATING (a re-watch) has no local twin, so it folds to `.watching` — a
/// re-watch is still "currently watching" locally. An unrecognized status (API/
/// schema drift, a value we don't model) returns null so the reconcile engine
/// skips that entry rather than guessing a status onto a local row.
pub fn fromAniListStatus(s: []const u8) ?domain.ListStatus {
    if (std.mem.eql(u8, s, "CURRENT")) return .watching;
    if (std.mem.eql(u8, s, "PLANNING")) return .planning;
    if (std.mem.eql(u8, s, "PAUSED")) return .paused;
    if (std.mem.eql(u8, s, "COMPLETED")) return .completed;
    if (std.mem.eql(u8, s, "DROPPED")) return .dropped;
    if (std.mem.eql(u8, s, "REPEATING")) return .watching; // re-watch → watching (no local twin)
    return null;
}

/// A pull either lands (the whole collection), hits a rate limit (429), finds the
/// token rejected (401 — re-auth needed), or fails otherwise. Same arm shape as
/// `PushError` so the ROD-285 engine reacts per case; distinct type because pull
/// has no `PushFailed`-vs-success entry-id nuance — a failed fetch is just
/// `PullFailed`.
pub const PullError = error{ RateLimited, Unauthorized, PullFailed } || Allocator.Error;

// `userId` rides as a GraphQL variable (never interpolated into the query), so the
// query is a constant with nothing to escape — comptime-guarded like the others.
const MLC_QUERY = "query($userId:Int!){MediaListCollection(userId:$userId,type:ANIME){lists{entries{mediaId status progress}}}}";

comptime {
    for (MLC_QUERY) |ch| {
        if (ch == '"' or ch == '\\' or ch < 0x20)
            @compileError("MLC_QUERY contains a character that needs JSON escaping; build the body with std.json instead of {s} interpolation");
    }
}

/// Pull the user's whole anime list from AniList in one round trip (ROD-285).
/// `MediaListCollection` is NOT paginated — it returns every list (status lists +
/// any custom lists) in a single response — so one POST covers the account.
/// `bearer` is the OAuth access token; `user_id` is the AniList id the token was
/// minted for (cached in auth.zon at login — AniList doesn't infer it from the
/// token). Entries are deduped by `media_id` (a show in a custom list appears under
/// both its status list and the custom one, carrying identical entry data).
///
/// The response rides `fetchGql`'s 2 MB fixed cap. Each entry is three scalar fields
/// (~45 bytes of JSON), so that holds tens of thousands of entries — well past any
/// real list. A pathologically huge one overflows the cap → the fetch errors →
/// `error.PullFailed`, which the engine reports as a failed pull, not a crash.
pub fn mediaListCollection(arena: Allocator, io: Io, bearer: []const u8, user_id: i64) PullError![]const PulledEntry {
    // `userId` is an integer, JSON-safe interpolated as a variable value on the same
    // trust basis as saveMediaListEntry's `mediaId`.
    const body = try std.fmt.allocPrint(
        arena,
        "{{\"query\":\"{s}\",\"variables\":{{\"userId\":{d}}}}}",
        .{ MLC_QUERY, user_id },
    );
    const r = postGqlRaw(arena, io, body, bearer) orelse return error.PullFailed;
    return classifyMediaList(arena, r);
}

/// Map the raw {status, body} of a MediaListCollection POST to the PullError
/// contract, flattening + deduping the lists into one entry slice. Split from the
/// POST so the branching and the flatten/dedup are unit-testable without a live
/// query. A 200 whose body carries no `MediaListCollection` (a GraphQL-level error,
/// or `{"data":null}`) is a failed pull, not an empty list.
fn classifyMediaList(arena: Allocator, r: HttpResult) PullError![]const PulledEntry {
    switch (r.status) {
        .ok => {},
        .too_many_requests => return error.RateLimited, // 429 — engine backs off
        .unauthorized => return error.Unauthorized, // 401 — token re-auth
        else => return error.PullFailed,
    }

    const parsed = std.json.parseFromSlice(MlcResp, arena, r.body, .{
        .ignore_unknown_fields = true,
    }) catch return error.PullFailed;
    const data = parsed.value.data orelse return error.PullFailed;
    const mlc = data.MediaListCollection orelse return error.PullFailed;

    // Dedupe by media_id: the same entry rides both its status list and any custom
    // list it's in, with identical (status, progress) — collapse to one. `seen` maps
    // media_id → index in `out` so a duplicate overwrites rather than double-counts.
    var out: std.ArrayList(PulledEntry) = .empty;
    var seen: std.AutoHashMapUnmanaged(i64, usize) = .empty;
    for (mlc.lists) |list| {
        for (list.entries) |e| {
            const media_id = e.mediaId orelse continue; // an entry with no media is unusable
            const status_str = e.status orelse continue; // no status → nothing to reconcile
            const status = fromAniListStatus(status_str) orelse continue; // unknown enum → skip
            const entry: PulledEntry = .{ .media_id = media_id, .status = status, .progress = e.progress };
            const gop = try seen.getOrPut(arena, media_id);
            if (gop.found_existing) {
                out.items[gop.value_ptr.*] = entry; // dup across lists — last wins (identical anyway)
            } else {
                gop.value_ptr.* = out.items.len;
                try out.append(arena, entry);
            }
        }
    }
    return out.toOwnedSlice(arena);
}

// MediaListCollection response shape: lists of entries, each carrying just the
// three fields the reconcile needs. `progress` defaults to 0 (AniList sends 0, not
// null, for an unstarted entry); `mediaId`/`status` are optional so a malformed
// entry parses and is skipped rather than failing the whole pull.
const MlcEntry = struct { mediaId: ?i64 = null, status: ?[]const u8 = null, progress: i64 = 0 };
const MlcList = struct { entries: []const MlcEntry = &.{} };
const MediaListCollectionT = struct { lists: []const MlcList = &.{} };
const MlcData = struct { MediaListCollection: ?MediaListCollectionT = null };
const MlcResp = struct { data: ?MlcData = null };

fn mediaToMeta(arena: Allocator, m: Media) !Metadata {
    // Every free-text field is C0-stripped (ROD-247) — these are third-party strings
    // that render straight to terminal cells; see stripControls. thumb is a URL
    // (validated separately on fetch), season is an enum, the rest are scalars.
    const sel = selectRank(m.rankings);
    return .{
        .anilist_id = m.id,
        .mal_id = m.idMal,
        .title_english = try stripControlsOpt(arena, m.title.english),
        .title_native = try stripControlsOpt(arena, m.title.native),
        .thumb = m.coverImage.large,
        .total_episodes = m.episodes,
        .duration = m.duration,
        .year = m.seasonYear,
        .season = if (m.season) |s| domain.Season.fromString(s) else null,
        .start_date = startDate(m.startDate),
        .status = try stripControlsOpt(arena, m.status),
        .kind = try stripControlsOpt(arena, m.format),
        .genres = try stripControlsList(arena, m.genres), // arena-owned; worker deep-copies into GPA
        .studios = try studioNames(arena, m.studios),
        .description = if (m.description) |d| try stripControls(arena, try sanitizeDescription(arena, d)) else null,
        .score = m.averageScore,
        .source_material = try stripControlsOpt(arena, m.source),
        .rank = if (sel) |r| r.rank else null,
        .rank_type = if (sel) |r| try stripControlsOpt(arena, r.type) else null,
        .rank_year = if (sel) |r| r.year else null,
        .next_airing_at = if (m.nextAiringEpisode) |na| na.airingAt else null,
        .next_airing_episode = if (m.nextAiringEpisode) |na| na.episode else null,
        .country = try stripControlsOpt(arena, m.countryOfOrigin),
    };
}

const SelectedRank = struct { rank: u32, type: ?[]const u8, year: ?u32 };

/// Pick the single most meaningful ranking from AniList's `rankings` array
/// (ROD-261, §5.3a): a *contextual* (year/season-scoped) ranking beats an
/// all-time one, and within a tier RATED beats POPULAR. `year` is carried only
/// for a contextual pick — an all-time ranking renders without one. Null when the
/// array is empty.
fn selectRank(rankings: []const Ranking) ?SelectedRank {
    var best: ?Ranking = null;
    for (rankings) |r| {
        if (best == null or rankScore(r) > rankScore(best.?)) best = r;
    }
    const b = best orelse return null;
    return .{ .rank = b.rank, .type = b.type, .year = if (b.allTime) null else b.year };
}

/// Preference score: contextual (+2) dominates type (RATED +1), so a contextual
/// POPULAR still outranks an all-time RATED — the tier ordering §5.3a specifies.
fn rankScore(r: Ranking) i32 {
    var s: i32 = 0;
    if (!r.allTime) s += 2;
    if (r.type) |t| {
        if (std.mem.eql(u8, t, "RATED")) s += 1;
    }
    return s;
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
            out[i] = try stripControls(arena, name);
            i += 1;
        }
    }
    return out;
}

/// Drop C0 control bytes (0x00–0x1F) and DEL (0x7F) from an AniList-sourced string
/// before it reaches a terminal cell (ROD-247 hardening). The escape-injection vector
/// — an OSC/CSI sequence smuggled in a genre or synopsis — is blocked downstream by
/// vaxis skipping zero-width graphemes, but that's an *implicit* framework property
/// (it breaks under `.word` wrap, or if the text is logged/exported). Stripping at
/// ingestion makes the defense explicit, mode-independent, and testable. Returns the
/// input unchanged when it's already clean (the common case — no allocation).
fn stripControls(arena: Allocator, raw: []const u8) ![]const u8 {
    var has_ctrl = false;
    for (raw) |c| {
        if (c < 0x20 or c == 0x7F) {
            has_ctrl = true;
            break;
        }
    }
    if (!has_ctrl) return raw;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, raw.len);
    for (raw) |c| {
        if (c < 0x20 or c == 0x7F) continue;
        out.appendAssumeCapacity(c);
    }
    return out.items;
}

fn stripControlsOpt(arena: Allocator, raw: ?[]const u8) !?[]const u8 {
    return if (raw) |r| try stripControls(arena, r) else null;
}

fn stripControlsList(arena: Allocator, list: []const []const u8) ![]const []const u8 {
    if (list.len == 0) return &.{};
    const out = try arena.alloc([]const u8, list.len);
    for (list, 0..) |s, i| out[i] = try stripControls(arena, s);
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

test "aniListStatus maps every local status to its AniList enum (ROD-284)" {
    try std.testing.expectEqualStrings("PLANNING", aniListStatus(.planning));
    try std.testing.expectEqualStrings("CURRENT", aniListStatus(.watching));
    try std.testing.expectEqualStrings("PAUSED", aniListStatus(.paused));
    try std.testing.expectEqualStrings("COMPLETED", aniListStatus(.completed));
    try std.testing.expectEqualStrings("DROPPED", aniListStatus(.dropped));
}

test "classifySave: id on 200, distinct errors for 429/401/failure (ROD-284)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 200 carrying the upserted entry id → success.
    try std.testing.expectEqual(
        @as(i64, 55),
        try classifySave(a, .{ .status = .ok, .body = "{\"data\":{\"SaveMediaListEntry\":{\"id\":55}}}" }),
    );

    // 429 → RateLimited (engine backs off); 401 → Unauthorized (token re-auth).
    try std.testing.expectError(error.RateLimited, classifySave(a, .{ .status = @enumFromInt(429), .body = "" }));
    try std.testing.expectError(error.Unauthorized, classifySave(a, .{ .status = @enumFromInt(401), .body = "" }));

    // 200 with no data (GraphQL-level error) and a 5xx both → PushFailed, never a
    // silent success.
    try std.testing.expectError(error.PushFailed, classifySave(a, .{ .status = .ok, .body = "{\"data\":null}" }));
    try std.testing.expectError(error.PushFailed, classifySave(a, .{ .status = @enumFromInt(500), .body = "oops" }));

    // 200 with the entry present but `id` omitted → "field present but empty" is a
    // failed push, not a landed one — the snapshot must not advance on it.
    try std.testing.expectError(error.PushFailed, classifySave(a, .{ .status = .ok, .body = "{\"data\":{\"SaveMediaListEntry\":{}}}" }));
}

test "fromAniListStatus maps every remote status, folding REPEATING (ROD-285)" {
    try std.testing.expectEqual(domain.ListStatus.watching, fromAniListStatus("CURRENT").?);
    try std.testing.expectEqual(domain.ListStatus.planning, fromAniListStatus("PLANNING").?);
    try std.testing.expectEqual(domain.ListStatus.paused, fromAniListStatus("PAUSED").?);
    try std.testing.expectEqual(domain.ListStatus.completed, fromAniListStatus("COMPLETED").?);
    try std.testing.expectEqual(domain.ListStatus.dropped, fromAniListStatus("DROPPED").?);
    // REPEATING has no local twin — a re-watch reads as "watching".
    try std.testing.expectEqual(domain.ListStatus.watching, fromAniListStatus("REPEATING").?);
    // An unknown enum is skipped by the caller, not guessed.
    try std.testing.expect(fromAniListStatus("SOMETHING_NEW") == null);
    try std.testing.expect(fromAniListStatus("") == null);
}

test "classifyMediaList: flattens lists, maps status, keeps progress (ROD-285)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two lists (Watching + Completed), one entry each. REPEATING folds to watching;
    // a null-status entry is skipped. mediaId tags each for the local join-back.
    const body =
        \\{"data":{"MediaListCollection":{"lists":[
        \\{"entries":[{"mediaId":100,"status":"CURRENT","progress":5},{"mediaId":101,"status":"REPEATING","progress":2}]},
        \\{"entries":[{"mediaId":200,"status":"COMPLETED","progress":12},{"mediaId":300,"status":null,"progress":0}]}
        \\]}}}
    ;
    const entries = try classifyMediaList(a, .{ .status = .ok, .body = body });
    try std.testing.expectEqual(@as(usize, 3), entries.len); // the null-status entry dropped

    // Order is list-then-entry; assert by scanning (dedup uses insertion order).
    var byId = std.AutoHashMap(i64, PulledEntry).init(a);
    for (entries) |e| try byId.put(e.media_id, e);
    try std.testing.expectEqual(domain.ListStatus.watching, byId.get(100).?.status);
    try std.testing.expectEqual(@as(i64, 5), byId.get(100).?.progress);
    try std.testing.expectEqual(domain.ListStatus.watching, byId.get(101).?.status); // REPEATING → watching
    try std.testing.expectEqual(domain.ListStatus.completed, byId.get(200).?.status);
    try std.testing.expectEqual(@as(i64, 12), byId.get(200).?.progress);
}

test "classifyMediaList: dedupes an entry shared across custom lists (ROD-285)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // media 100 appears in both its status list and a custom list — one entry out.
    const body =
        \\{"data":{"MediaListCollection":{"lists":[
        \\{"entries":[{"mediaId":100,"status":"CURRENT","progress":5}]},
        \\{"entries":[{"mediaId":100,"status":"CURRENT","progress":5}]}
        \\]}}}
    ;
    const entries = try classifyMediaList(a, .{ .status = .ok, .body = body });
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(i64, 100), entries[0].media_id);
}

test "classifyMediaList: distinct errors for 429/401, failure on malformed/no-data (ROD-285)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 429 → RateLimited (engine backs off); 401 → Unauthorized (token re-auth).
    try std.testing.expectError(error.RateLimited, classifyMediaList(a, .{ .status = @enumFromInt(429), .body = "" }));
    try std.testing.expectError(error.Unauthorized, classifyMediaList(a, .{ .status = @enumFromInt(401), .body = "" }));
    // A 200 with no data (GraphQL-level error) and a 5xx both → PullFailed, never an
    // empty-list "success" that would strand the whole collection.
    try std.testing.expectError(error.PullFailed, classifyMediaList(a, .{ .status = .ok, .body = "{\"data\":null}" }));
    try std.testing.expectError(error.PullFailed, classifyMediaList(a, .{ .status = @enumFromInt(500), .body = "oops" }));
    try std.testing.expectError(error.PullFailed, classifyMediaList(a, .{ .status = .ok, .body = "not json" }));
    // A reachable account with an empty list is a confirmed empty answer → empty slice.
    const empty = try classifyMediaList(a, .{ .status = .ok, .body = "{\"data\":{\"MediaListCollection\":{\"lists\":[]}}}" });
    try std.testing.expectEqual(@as(usize, 0), empty.len);
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

test "selectRank prefers contextual over all-time, RATED over POPULAR (ROD-261)" {
    // Empty → no pick.
    try std.testing.expect(selectRank(&.{}) == null);

    // Contextual RATED beats an all-time RATED — and carries its year.
    {
        const rankings = [_]Ranking{
            .{ .rank = 42, .type = "RATED", .allTime = true },
            .{ .rank = 3, .type = "RATED", .year = 2016, .allTime = false },
        };
        const sel = selectRank(&rankings) orelse return error.TestExpectationFailed;
        try std.testing.expectEqual(@as(u32, 3), sel.rank);
        try std.testing.expectEqual(@as(?u32, 2016), sel.year);
    }

    // Tier dominates type: a contextual POPULAR still beats an all-time RATED.
    {
        const rankings = [_]Ranking{
            .{ .rank = 5, .type = "RATED", .allTime = true },
            .{ .rank = 1, .type = "POPULAR", .year = 2016, .allTime = false },
        };
        const sel = selectRank(&rankings) orelse return error.TestExpectationFailed;
        try std.testing.expectEqual(@as(u32, 1), sel.rank);
        try std.testing.expectEqualStrings("POPULAR", sel.type.?);
    }

    // Within the all-time tier, RATED wins the tie-break; year is dropped.
    {
        const rankings = [_]Ranking{
            .{ .rank = 88, .type = "POPULAR", .allTime = true },
            .{ .rank = 42, .type = "RATED", .allTime = true },
        };
        const sel = selectRank(&rankings) orelse return error.TestExpectationFailed;
        try std.testing.expectEqual(@as(u32, 42), sel.rank);
        try std.testing.expectEqualStrings("RATED", sel.type.?);
        try std.testing.expectEqual(@as(?u32, null), sel.year);
    }
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

test "pageToMetas maps a batch Page, tagging each card by id (ROD-247)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A two-card page: one fully populated, one with no genres / null season —
    // the card that must degrade to [--] and no season chip. An unknown field
    // (siteUrl) must be skipped by ignore_unknown_fields.
    const json =
        \\{"data":{"Page":{"media":[
        \\{"id":182255,"averageScore":89,"genres":["Adventure","Drama","Fantasy"],"season":"FALL","seasonYear":2023,"startDate":{"year":2023},"siteUrl":"x"},
        \\{"id":1,"averageScore":null,"genres":[],"season":null,"seasonYear":null,"startDate":{"year":null}}
        \\]}}}
    ;
    const metas = try pageToMetas(a, json);
    try std.testing.expectEqual(@as(usize, 2), metas.len);
    // Fully enriched card — id tags it for join-back, all three signals present.
    try std.testing.expectEqual(@as(?u64, 182255), metas[0].anilist_id);
    try std.testing.expectEqual(@as(?u32, 89), metas[0].score);
    try std.testing.expectEqual(@as(usize, 3), metas[0].genres.len);
    try std.testing.expectEqual(domain.Season.fall, metas[0].season.?);
    try std.testing.expectEqual(@as(u32, 2023), metas[0].start_date.?.year);
    try std.testing.expectEqual(@as(?u32, 2023), metas[0].year);
    // Graceful-degrade card — still id-tagged, but no score/genre/season+year.
    try std.testing.expectEqual(@as(?u64, 1), metas[1].anilist_id);
    try std.testing.expectEqual(@as(?u32, null), metas[1].score);
    try std.testing.expectEqual(@as(usize, 0), metas[1].genres.len);
    try std.testing.expect(metas[1].season == null);
    try std.testing.expect(metas[1].start_date == null);
    try std.testing.expectEqual(@as(?u32, null), metas[1].year);
}

test "pageToMetas: {\"data\":null} is no-answer, an empty page is a confirmed empty answer (ROD-278)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A `{"data":null}` body is a GraphQL-level execution error (200, no data), NOT a
    // confirmed-empty page — it must error so `enrichBatch` reports no answer and the
    // batch stays un-stamped. Mirrors classifyById/classifyBySearch on the same shape.
    try std.testing.expectError(error.NoAnswer, pageToMetas(a, "{\"data\":null}"));

    // A parsed page with zero media IS a confirmed empty answer → empty slice, no error.
    const empty = try pageToMetas(a, "{\"data\":{\"Page\":{\"media\":[]}}}");
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "classifyById: three-state map — match / confirmed no-match / no answer (ROD-278)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A real media → a match (Metadata), tagged by id for the caller's join-back.
    const meta = (try classifyById(a, "{\"data\":{\"Media\":{\"id\":182255,\"episodes\":28}}}")).?;
    try std.testing.expectEqual(@as(?u64, 182255), meta.anilist_id);

    // `{"data":{"Media":null}}` — AniList answered: no anime carries that id. This is
    // a CONFIRMED no-match (null), which the refresh path stamps as a negative cache.
    try std.testing.expect((try classifyById(a, "{\"data\":{\"Media\":null}}")) == null);

    // `{"data":null}` (a GraphQL-level error) and unparseable bytes are NOT answers —
    // they must error so the refresh path leaves the row un-stamped and retries.
    try std.testing.expectError(error.NoAnswer, classifyById(a, "{\"data\":null}"));
    try std.testing.expectError(error.NoAnswer, classifyById(a, "not json at all"));
}

test "classifyBySearch: empty/no-match page is null, malformed is no-answer (ROD-278)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const show: domain.Anime = .{ .id = "x", .name = "Nonexistent Show" };

    // Reached AniList, ran the match, page had nothing (or nothing cleared bestMatch's
    // guard) → CONFIRMED no-match (null), stamped as a negative cache.
    try std.testing.expect((try classifyBySearch(a, show, "{\"data\":{\"Page\":{\"media\":[]}}}")) == null);

    // `{"data":null}` and unparseable bytes → no answer → error, so the row retries.
    try std.testing.expectError(error.NoAnswer, classifyBySearch(a, show, "{\"data\":null}"));
    try std.testing.expectError(error.NoAnswer, classifyBySearch(a, show, "}{"));
}

test "stripControls drops C0 + DEL bytes from AniList text (ROD-247)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // CSI colour smuggled in a title, OSC-52 clipboard in a genre, a lone ESC in a
    // synopsis, BEL/DEL in a studio name — every control byte must be dropped.
    try std.testing.expectEqualStrings("Hero[31m", try stripControls(a, "Hero\x1b[31m"));
    try std.testing.expectEqualStrings("Action]52;c;QQ", try stripControls(a, "Action\x1b]52;c;QQ\x07"));
    try std.testing.expectEqualStrings("A tale.", try stripControls(a, "A \x1btale."));
    try std.testing.expectEqualStrings("Studio", try stripControls(a, "S\x7ftudio"));
    // Clean input is returned unchanged (and not reallocated — same pointer).
    const clean = "Slice of Life";
    try std.testing.expectEqual(clean.ptr, (try stripControls(a, clean)).ptr);
}

test "sanitizeDescription strips tags and decodes common entities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "Hello & goodbye \"hero\" -- now",
        try sanitizeDescription(arena.allocator(), "<i>Hello</i> &amp; goodbye &quot;hero&quot; &mdash; now"),
    );
}
