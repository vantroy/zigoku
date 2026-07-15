//! AniList metadata enrichment. Not the playback path: providers own
//! search → episodes → resolve → play. AniList is the durable-metadata side rail
//! (cover, synopsis, score, MAL/AniList ids) when a row maps with high confidence.

const std = @import("std");
const domain = @import("domain.zig");
const source = @import("source.zig");
const deadline = @import("util/deadline.zig");
const json_escape = @import("util/json_escape.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const ENDPOINT = "https://graphql.anilist.co";
// Wall-clock ceiling per enrichment POST (ROD-262). No per-read socket timeout in
// std; a silent host would hang a detached worker (ROD-251). 10s: side rail, one round trip.
const ANILIST_DEADLINE_S = 10;
// Shared selection set so search and by-id never drift.
const GQL_FIELDS = "id idMal title{romaji english native} episodes duration averageScore status season seasonYear startDate{year month day} format source countryOfOrigin genres studios(isMain:true){nodes{name}} rankings{rank type year allTime} nextAiringEpisode{episode airingAt} description(asHtml:false) coverImage{large}";
// $page required; enrichBySearch binds page 1.
const GQL_SEARCH = "query($search:String!,$perPage:Int!,$page:Int!){Page(page:$page,perPage:$perPage){media(search:$search,type:ANIME,sort:SEARCH_MATCH){" ++ GQL_FIELDS ++ "}}}";
// Deterministic join when we already have an AniList id (ROD-181); no title matching.
const GQL_BY_ID = "query($id:Int!){Media(id:$id,type:ANIME){" ++ GQL_FIELDS ++ "}}";
// ROD-247 batch: card-signal subset, narrower than GQL_FIELDS on purpose. Discover
// cutover (ROD-336) dropped UI callers; provider_migrate still uses this.
const GQL_BATCH_FIELDS = "id idMal averageScore genres season seasonYear startDate{year}";
// ROD-334 Discover (§9.6): full GQL_FIELDS; sort/season vars; pageInfo.hasNextPage.
const GQL_DISCOVER = "query($page:Int!,$perPage:Int!,$sort:[MediaSort],$season:MediaSeason,$seasonYear:Int){Page(page:$page,perPage:$perPage){pageInfo{hasNextPage} media(type:ANIME,sort:$sort,season:$season,seasonYear:$seasonYear){" ++ GQL_FIELDS ++ "}}}";

// Queries are `{s}`-interpolated into JSON: no quotes/control chars, or the build fails.
comptime {
    @setEvalBranchQuota(4000);
    for (GQL_SEARCH ++ GQL_BY_ID ++ GQL_BATCH_FIELDS ++ GQL_DISCOVER) |c| {
        if (c == '"' or c == '\\' or c < 0x20) {
            @compileError("GraphQL query contains a character that needs JSON escaping; build the request body with std.json instead of {s} interpolation");
        }
    }
}

pub const Metadata = struct {
    anilist_id: ?u64 = null,
    mal_id: ?u64 = null,
    /// True AniList romaji (ROD-312): heals canonical.title off the provider seed.
    title_romaji: ?[]const u8 = null,
    title_english: ?[]const u8 = null,
    title_native: ?[]const u8 = null,
    thumb: ?[]const u8 = null,
    total_episodes: ?u32 = null,
    /// Runtime minutes (ROD-261).
    duration: ?u32 = null,
    year: ?u32 = null,
    season: ?domain.Season = null,
    start_date: ?domain.Date = null,
    status: ?[]const u8 = null,
    /// AniList format → domain.Anime.kind.
    kind: ?[]const u8 = null,
    /// Arena-owned (JSON borrow); worker GPA-copies before arena teardown.
    genres: []const []const u8 = &.{},
    studios: []const []const u8 = &.{},
    description: ?[]const u8 = null,
    score: ?u32 = null,
    /// AniList source enum raw (ROD-261). Not provider `source`.
    source_material: ?[]const u8 = null,
    /// selectRank pick (ROD-261): position, type, year (null year = all-time).
    rank: ?u32 = null,
    rank_type: ?[]const u8 = null,
    rank_year: ?u32 = null,
    /// Absolute next air (unix + ep). Relative airing deltas would go stale (ROD-261).
    next_airing_at: ?i64 = null,
    next_airing_episode: ?u32 = null,
    /// countryOfOrigin; UI surfaces non-JP (ROD-261).
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

// studios{nodes{name}}; empty default if omitted.
const Studios = struct {
    nodes: []const Studio = &.{},
};

// rankings[] entry for selectRank (ROD-261).
const Ranking = struct {
    rank: u32 = 0,
    type: ?[]const u8 = null,
    year: ?u32 = null,
    allTime: bool = false,
};

// nextAiringEpisode absolute air time (ROD-261). Null when finished/unscheduled.
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

const PageInfo = struct {
    hasNextPage: bool = false,
};

const Page = struct {
    media: []Media,
    // GQL_DISCOVER only; null on search/batch.
    pageInfo: ?PageInfo = null,
};

const Data = struct {
    Page: Page,
};

const Resp = struct {
    data: ?Data = null,
};

// by-id: single Media, not Page.
const MediaData = struct {
    Media: ?Media = null,
};

const MediaResp = struct {
    data: ?MediaData = null,
};

// Fill-if-null mapping is workers.applyMetadata (GPA deep-copy). Doing it here would
// alias Metadata slices into the soon-dead parse arena (UAF).

/// Three-state enrich (ROD-278). Only a confirmed answer may stamp freshness:
///   * Metadata: match → stamp
///   * null: confirmed no-match → stamp (negative cache)
///   * error.NoAnswer: transport/timeout/malformed/`data:null` → do not stamp
pub const EnrichError = error{NoAnswer} || Allocator.Error;

pub fn enrich(arena: Allocator, io: Io, show: domain.Anime) EnrichError!?Metadata {
    // Prefer by-id when anilist_id known (ROD-181): exact, no title match.
    if (show.anilist_id) |id| return enrichById(arena, io, id);
    return enrichBySearch(arena, io, show);
}

fn enrichById(arena: Allocator, io: Io, id: u64) EnrichError!?Metadata {
    const body = try std.fmt.allocPrint(
        arena,
        "{{\"query\":\"{s}\",\"variables\":{{\"id\":{d}}}}}",
        .{ GQL_BY_ID, id },
    );
    // Transport miss → NoAnswer (not confirmed no-match).
    const raw = postGql(arena, io, body) orelse return error.NoAnswer;
    return classifyById(arena, raw);
}

/// by-id body → three-state. Split for unit tests without a live fetch.
fn classifyById(arena: Allocator, raw: []const u8) EnrichError!?Metadata {
    // Unparseable / data:null = no answer (retry). Media:null = confirmed no-match.
    const parsed = std.json.parseFromSlice(MediaResp, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return error.NoAnswer;
    const data = parsed.value.data orelse return error.NoAnswer;
    const media = data.Media orelse return null;
    return try mediaToMeta(arena, media);
}

fn enrichBySearch(arena: Allocator, io: Io, show: domain.Anime) EnrichError!?Metadata {
    const title = show.english_name orelse show.name;
    // Empty title: confirmed no-match (stamp), not NoAnswer.
    if (title.len == 0) return null;

    const body = try std.fmt.allocPrint(
        arena,
        "{{\"query\":\"{s}\",\"variables\":{{\"search\":\"{s}\",\"perPage\":8,\"page\":1}}}}",
        .{ GQL_SEARCH, try json_escape.escape(arena, title) },
    );
    const raw = postGql(arena, io, body) orelse return error.NoAnswer;
    return classifyBySearch(arena, show, raw);
}

/// Search body → three-state. Split for unit tests.
fn classifyBySearch(arena: Allocator, show: domain.Anime, raw: []const u8) EnrichError!?Metadata {
    const parsed = std.json.parseFromSlice(Resp, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return error.NoAnswer;
    const data = parsed.value.data orelse return error.NoAnswer;
    // Empty page / no bestMatch: confirmed no-match.
    const best = bestMatch(show, data.Page.media) orelse return null;
    return try mediaToMeta(arena, best);
}

/// Batch enrich by AniList ids (ROD-247). Arena Metadata tagged with anilist_id
/// (order not guaranteed). Three-state like enrich (ROD-278): empty slice stamps;
/// NoAnswer does not.
pub fn enrichBatch(arena: Allocator, io: Io, ids: []const u64) EnrichError![]const Metadata {
    if (ids.len == 0) return &.{};

    // Integers only: safe to interpolate (like GQL_BATCH_FIELDS).
    var ids_buf: std.ArrayList(u8) = .empty;
    try ids_buf.append(arena, '[');
    for (ids, 0..) |id, i| {
        if (i != 0) try ids_buf.append(arena, ',');
        try ids_buf.print(arena, "{d}", .{id});
    }
    try ids_buf.append(arena, ']');

    // perPage = ids.len; AniList caps at 50 (callers chunk). GQL_BATCH_FIELDS as {s}
    // arg (not format concat): contains startDate{year} braces.
    const query = try std.fmt.allocPrint(
        arena,
        "query{{Page(perPage:{d}){{media(id_in:{s},type:ANIME){{{s}}}}}}}",
        .{ ids.len, ids_buf.items, GQL_BATCH_FIELDS },
    );
    const body = try std.fmt.allocPrint(arena, "{{\"query\":\"{s}\"}}", .{query});

    // Transport null → NoAnswer. pageToMetas propagates EnrichError (do not rewrap OOM).
    const raw = postGql(arena, io, body) orelse return error.NoAnswer;
    return pageToMetas(arena, raw);
}

/// Page JSON → Metadata slice. data:null → NoAnswer; empty media → empty slice (ROD-278).
fn pageToMetas(arena: Allocator, raw: []const u8) EnrichError![]const Metadata {
    const parsed = std.json.parseFromSlice(Resp, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return error.NoAnswer;
    const data = parsed.value.data orelse return error.NoAnswer;
    const media = data.Page.media;
    const out = try arena.alloc(Metadata, media.len);
    for (media, 0..) |m, i| out[i] = try mediaToMeta(arena, m);
    return out;
}

/// Discovery search off SourceProvider vtable (ROD-326). page 1-based. Three-state ROD-278.
pub fn search(arena: Allocator, io: Io, query: []const u8, page: u32) EnrichError![]domain.Anime {
    if (query.len == 0) return &.{};
    const raw = postGql(arena, io, try searchBody(arena, query, page)) orelse return error.NoAnswer;
    return pageToAnime(arena, raw);
}

/// search body (JSON-escape untrusted query). Split for unit tests.
fn searchBody(arena: Allocator, query: []const u8, page: u32) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"query\":\"{s}\",\"variables\":{{\"search\":\"{s}\",\"perPage\":{d},\"page\":{d}}}}}",
        .{ GQL_SEARCH, try json_escape.escape(arena, query), source.search_page_size, page },
    );
}

/// Search JSON → rows. data:null → NoAnswer; empty page → empty (ROD-278).
fn pageToAnime(arena: Allocator, raw: []const u8) EnrichError![]domain.Anime {
    const parsed = std.json.parseFromSlice(Resp, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return error.NoAnswer;
    const data = parsed.value.data orelse return error.NoAnswer;
    return mediaToRows(arena, data.Page.media);
}

fn mediaToRows(arena: Allocator, media: []const Media) ![]domain.Anime {
    const out = try arena.alloc(domain.Anime, media.len);
    for (media, 0..) |m, i| out[i] = try metaToAnime(arena, try mediaToMeta(arena, m));
    return out;
}

/// Discover feed axes (ROD-334, §3.8/§9.6). Off the vtable like search.
pub const DiscoverAxis = enum {
    trending,
    popular,
    top_rated,
    this_season,

    /// sort JSON array. Secondary key stabilizes page order under primary ties (§9.6).
    fn sortJson(self: DiscoverAxis) []const u8 {
        return switch (self) {
            .trending => "[\"TRENDING_DESC\",\"POPULARITY_DESC\"]",
            .popular, .this_season => "[\"POPULARITY_DESC\",\"ID_DESC\"]",
            .top_rated => "[\"SCORE_DESC\",\"ID_DESC\"]",
        };
    }
};

/// Discover page size (§9.6). Under AniList's perPage cap of 50.
pub const discover_page_size = 20;

/// One feed page + hasNextPage (§9.6). Rows arena-borrowed.
pub const DiscoverPage = struct {
    rows: []domain.Anime,
    has_next_page: bool,
};

/// One Discover page (ROD-334). page 1-based; now_ms anchors This Season. Three-state ROD-278.
pub fn discover(arena: Allocator, io: Io, axis: DiscoverAxis, page: u32, now_ms: i64) EnrichError!DiscoverPage {
    const raw = postGql(arena, io, try discoverBody(arena, axis, page, now_ms)) orelse return error.NoAnswer;
    return pageToDiscover(arena, raw);
}

/// Axis→variables. season/seasonYear OMITTED off This Season: explicit null would
/// filter season==null; omitted leaves the arg unset (GraphQL).
fn discoverBody(arena: Allocator, axis: DiscoverAxis, page: u32, now_ms: i64) ![]const u8 {
    const season_vars: []const u8 = switch (axis) {
        .this_season => blk: {
            const c = domain.currentCour(now_ms);
            break :blk try std.fmt.allocPrint(
                arena,
                ",\"season\":\"{s}\",\"seasonYear\":{d}",
                .{ seasonEnum(c.season), c.year },
            );
        },
        else => "",
    };
    // sortJson/seasonEnum are fixed literals (JSON-safe).
    return std.fmt.allocPrint(
        arena,
        "{{\"query\":\"{s}\",\"variables\":{{\"page\":{d},\"perPage\":{d},\"sort\":{s}{s}}}}}",
        .{ GQL_DISCOVER, page, discover_page_size, axis.sortJson(), season_vars },
    );
}

fn seasonEnum(s: domain.Season) []const u8 {
    return switch (s) {
        .winter => "WINTER",
        .spring => "SPRING",
        .summer => "SUMMER",
        .fall => "FALL",
    };
}

/// Discover JSON → page. Missing pageInfo → exhausted (stop, don't spin).
fn pageToDiscover(arena: Allocator, raw: []const u8) EnrichError!DiscoverPage {
    const parsed = std.json.parseFromSlice(Resp, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return error.NoAnswer;
    const data = parsed.value.data orelse return error.NoAnswer;
    return .{
        .rows = try mediaToRows(arena, data.Page.media),
        .has_next_page = if (data.Page.pageInfo) |pi| pi.hasNextPage else false,
    };
}

/// meta → Anime (arena-borrowed; worker GPA-copies). id = stringified anilist_id
/// (UI handle only; never provider.episodes/resolve, ROD-328).
fn metaToAnime(arena: Allocator, meta: Metadata) !domain.Anime {
    // Media.id always sets anilist_id.
    const id = try std.fmt.allocPrint(arena, "{d}", .{meta.anilist_id.?});
    const name = meta.title_romaji orelse meta.title_english orelse meta.title_native orelse "";
    return .{
        .id = id,
        .name = name,
        .english_name = meta.title_english,
        .title_romaji = meta.title_romaji,
        .native_name = meta.title_native,
        .mal_id = meta.mal_id,
        .anilist_id = meta.anilist_id,
        .thumb = meta.thumb,
        .total_episodes = meta.total_episodes,
        .duration = meta.duration,
        .year = meta.year,
        .season = meta.season,
        .start_date = meta.start_date,
        .status = meta.status,
        .description = meta.description,
        .genres = meta.genres,
        .score = meta.score,
        .studios = meta.studios,
        .source_material = meta.source_material,
        .rank = meta.rank,
        .rank_type = meta.rank_type,
        .rank_year = meta.rank_year,
        .next_airing_at = meta.next_airing_at,
        .next_airing_episode = meta.next_airing_episode,
        .country = meta.country,
        .kind = meta.kind,
    };
}

/// GraphQL POST outcome: status + body. Push classifies 429/401 (ROD-284);
/// enrichment collapses non-success via postGql.
pub const HttpResult = struct { status: std.http.Status, body: []const u8 };

/// One GraphQL POST. Optional bearer (ROD-284). Status left to caller.
/// Cancelable under withDeadline (ROD-262): stall → Canceled, client frees.
fn fetchGql(arena: Allocator, io: Io, body: []const u8, bearer: ?[]const u8) !HttpResult {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    // Fixed 2 MB cap (ROD-247): unbounded writer could OOM; real replies << 100 KB.
    const resp_buf = try arena.alloc(u8, 2 * 1024 * 1024);
    var resp_w: std.Io.Writer = .fixed(resp_buf);

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

/// Deadline-bounded POST (ROD-262). null on transport/over-cap/timeout.
/// Non-200 status still returned when body arrives; caller classifies.
fn postGqlRaw(arena: Allocator, io: Io, body: []const u8, bearer: ?[]const u8) ?HttpResult {
    return deadline.withDeadline(io, .fromSeconds(ANILIST_DEADLINE_S), fetchGql, .{ arena, io, body, bearer }) catch |e| {
        if (e == error.Timeout)
            log.debug("anilist POST aborted past {d}s deadline", .{ANILIST_DEADLINE_S});
        return null;
    };
}

/// Unauthed enrich POST: any failure → null. Push uses postGqlRaw for status.
fn postGql(arena: Allocator, io: Io, body: []const u8) ?[]const u8 {
    const r = postGqlRaw(arena, io, body, null) orelse return null;
    if (r.status != .ok) return null;
    return r.body;
}

// ── AniList push: SaveMediaListEntry (ROD-284) ───────────────────────────────

/// Local list_status → AniList MediaListStatus. Total outward map; REPEATING is pull-only.
pub fn aniListStatus(s: domain.ListStatus) []const u8 {
    return switch (s) {
        .planning => "PLANNING",
        .watching => "CURRENT",
        .paused => "PAUSED",
        .completed => "COMPLETED",
        .dropped => "DROPPED",
    };
}

/// Push arms (ROD-284): id / 429 RateLimited / 401 Unauthorized / else PushFailed.
pub const PushError = error{ RateLimited, Unauthorized, PushFailed } || Allocator.Error;

const SAVE_MUTATION = "mutation($mediaId:Int,$status:MediaListStatus,$progress:Int){SaveMediaListEntry(mediaId:$mediaId,status:$status,progress:$progress){id}}";

// {s}-interpolated: no JSON-escape chars (comptime).
comptime {
    for (SAVE_MUTATION) |ch| {
        if (ch == '"' or ch == '\\' or ch < 0x20)
            @compileError("SAVE_MUTATION contains a character that needs JSON escaping; build the body with std.json instead of {s} interpolation");
    }
}

/// Upsert watch-state via SaveMediaListEntry (ROD-284). Idempotent on mediaId.
/// Returns list-entry id. bearer from auth.zon; media_id = anime.anilist_id.
pub fn saveMediaListEntry(
    arena: Allocator,
    io: Io,
    bearer: []const u8,
    media_id: i64,
    status: domain.ListStatus,
    progress: i64,
) PushError!i64 {
    // Variables only (never query interpolation). Enum/int literals JSON-safe.
    const body = try std.fmt.allocPrint(
        arena,
        "{{\"query\":\"{s}\",\"variables\":{{\"mediaId\":{d},\"status\":\"{s}\",\"progress\":{d}}}}}",
        .{ SAVE_MUTATION, media_id, aniListStatus(status), progress },
    );
    const r = postGqlRaw(arena, io, body, bearer) orelse return error.PushFailed;
    return classifySave(arena, r);
}

/// HttpResult → PushError. Split for unit tests. 200 without entry id is PushFailed.
fn classifySave(arena: Allocator, r: HttpResult) PushError!i64 {
    switch (r.status) {
        .ok => {},
        .too_many_requests => return error.RateLimited, // 429
        .unauthorized => return error.Unauthorized, // 401
        else => return error.PushFailed,
    }

    const parsed = std.json.parseFromSlice(SaveResp, arena, r.body, .{
        .ignore_unknown_fields = true,
    }) catch return error.PushFailed;
    const data = parsed.value.data orelse return error.PushFailed;
    const entry = data.SaveMediaListEntry orelse return error.PushFailed;
    // Missing id on 200 must not count as success (snapshot would advance falsely).
    return entry.id orelse error.PushFailed;
}

const SaveResp = struct { data: ?SaveData = null };
const SaveData = struct { SaveMediaListEntry: ?SaveEntry = null };
const SaveEntry = struct { id: ?i64 = null };

// ── AniList pull: MediaListCollection (ROD-285) ──────────────────────────────

/// Remote list entry for 3-way merge (ROD-285). status already local (REPEATING → watching).
pub const PulledEntry = struct {
    media_id: i64,
    status: domain.ListStatus,
    progress: i64,
};

/// AniList MediaListStatus → local. REPEATING → watching. Unknown → null (skip).
pub fn fromAniListStatus(s: []const u8) ?domain.ListStatus {
    if (std.mem.eql(u8, s, "CURRENT")) return .watching;
    if (std.mem.eql(u8, s, "PLANNING")) return .planning;
    if (std.mem.eql(u8, s, "PAUSED")) return .paused;
    if (std.mem.eql(u8, s, "COMPLETED")) return .completed;
    if (std.mem.eql(u8, s, "DROPPED")) return .dropped;
    if (std.mem.eql(u8, s, "REPEATING")) return .watching;
    return null;
}

/// Pull arms (ROD-285): RateLimited / Unauthorized / PullFailed.
pub const PullError = error{ RateLimited, Unauthorized, PullFailed } || Allocator.Error;

/// Cap untrusted AniList progress at ingest (ROD-285). Bounds progress*bar_w overflow.
const MAX_SANE_PROGRESS: i64 = 100_000;

fn clampProgress(p: i64) i64 {
    return std.math.clamp(p, 0, MAX_SANE_PROGRESS);
}

// userId is a variable; query constant + comptime guard.
const MLC_QUERY = "query($userId:Int!){MediaListCollection(userId:$userId,type:ANIME){lists{entries{mediaId status progress}}}}";

comptime {
    for (MLC_QUERY) |ch| {
        if (ch == '"' or ch == '\\' or ch < 0x20)
            @compileError("MLC_QUERY contains a character that needs JSON escaping; build the body with std.json instead of {s} interpolation");
    }
}

/// Full remote list in one POST (not paginated) (ROD-285). Deduped by media_id.
/// Over 2 MB fetch cap → PullFailed.
pub fn mediaListCollection(arena: Allocator, io: Io, bearer: []const u8, user_id: i64) PullError![]const PulledEntry {
    const body = try std.fmt.allocPrint(
        arena,
        "{{\"query\":\"{s}\",\"variables\":{{\"userId\":{d}}}}}",
        .{ MLC_QUERY, user_id },
    );
    const r = postGqlRaw(arena, io, body, bearer) orelse return error.PullFailed;
    return classifyMediaList(arena, r);
}

/// Flatten + dedupe lists. Split for unit tests. data:null → PullFailed, not empty list.
fn classifyMediaList(arena: Allocator, r: HttpResult) PullError![]const PulledEntry {
    switch (r.status) {
        .ok => {},
        .too_many_requests => return error.RateLimited, // 429
        .unauthorized => return error.Unauthorized, // 401
        else => return error.PullFailed,
    }

    const parsed = std.json.parseFromSlice(MlcResp, arena, r.body, .{
        .ignore_unknown_fields = true,
    }) catch return error.PullFailed;
    const data = parsed.value.data orelse return error.PullFailed;
    const mlc = data.MediaListCollection orelse return error.PullFailed;

    // Dedupe media_id across status + custom lists.
    var out: std.ArrayList(PulledEntry) = .empty;
    var seen: std.AutoHashMapUnmanaged(i64, usize) = .empty;
    for (mlc.lists) |list| {
        for (list.entries) |e| {
            const media_id = e.mediaId orelse continue;
            const status_str = e.status orelse continue;
            const status = fromAniListStatus(status_str) orelse continue;
            const entry: PulledEntry = .{ .media_id = media_id, .status = status, .progress = clampProgress(e.progress) };
            const gop = try seen.getOrPut(arena, media_id);
            if (gop.found_existing) {
                out.items[gop.value_ptr.*] = entry;
            } else {
                gop.value_ptr.* = out.items.len;
                try out.append(arena, entry);
            }
        }
    }
    return out.toOwnedSlice(arena);
}

// progress defaults 0; optional mediaId/status so bad entries skip.
const MlcEntry = struct { mediaId: ?i64 = null, status: ?[]const u8 = null, progress: i64 = 0 };
const MlcList = struct { entries: []const MlcEntry = &.{} };
const MediaListCollectionT = struct { lists: []const MlcList = &.{} };
const MlcData = struct { MediaListCollection: ?MediaListCollectionT = null };
const MlcResp = struct { data: ?MlcData = null };

fn mediaToMeta(arena: Allocator, m: Media) !Metadata {
    // Free-text C0-stripped (ROD-247). thumb URL validated on fetch; season is enum.
    const sel = selectRank(m.rankings);
    return .{
        .anilist_id = m.id,
        .mal_id = m.idMal,
        .title_romaji = try stripControlsOpt(arena, m.title.romaji),
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

/// Best ranking (ROD-261 §5.3a): contextual > all-time; within tier RATED > POPULAR.
fn selectRank(rankings: []const Ranking) ?SelectedRank {
    var best: ?Ranking = null;
    for (rankings) |r| {
        if (best == null or rankScore(r) > rankScore(best.?)) best = r;
    }
    const b = best orelse return null;
    return .{ .rank = b.rank, .type = b.type, .year = if (b.allTime) null else b.year };
}

/// contextual +2, RATED +1 (§5.3a).
fn rankScore(r: Ranking) i32 {
    var s: i32 = 0;
    if (!r.allTime) s += 2;
    if (r.type) |t| {
        if (std.mem.eql(u8, t, "RATED")) s += 1;
    }
    return s;
}

/// startDate → domain.Date. No year → null.
fn startDate(sd: StartDate) ?domain.Date {
    const y = sd.year orelse return null;
    return .{ .year = y, .month = sd.month, .day = sd.day };
}

/// Flatten studio node names. Empty → &.{} .
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

/// Drop C0 + DEL from AniList text before terminal cells (ROD-247). Explicit defense
/// (not only vaxis zero-width skip). Clean input returned unchanged (no alloc).
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

/// Fuzzy title score (higher = closer; large negative = no overlap). Normalizes then
/// canonSeason. Pub so resolver tier-C (ROD-328) shares the same rule as candidateScore.
pub fn titleScore(a: []const u8, b_opt: ?[]const u8) i32 {
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

/// Explicit "Season N" / "Nth Season" → s<N> (ROD-181). Bare trailing numbers untouched
/// ("86", "Ranma 1/2"). No marker or overflow → s unchanged.
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
        if (dstart == b.len) return s; // "season" with no adjacent number, leave it
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
    // failed push, not a landed one, the snapshot must not advance on it.
    try std.testing.expectError(error.PushFailed, classifySave(a, .{ .status = .ok, .body = "{\"data\":{\"SaveMediaListEntry\":{}}}" }));
}

test "fromAniListStatus maps every remote status, folding REPEATING (ROD-285)" {
    try std.testing.expectEqual(domain.ListStatus.watching, fromAniListStatus("CURRENT").?);
    try std.testing.expectEqual(domain.ListStatus.planning, fromAniListStatus("PLANNING").?);
    try std.testing.expectEqual(domain.ListStatus.paused, fromAniListStatus("PAUSED").?);
    try std.testing.expectEqual(domain.ListStatus.completed, fromAniListStatus("COMPLETED").?);
    try std.testing.expectEqual(domain.ListStatus.dropped, fromAniListStatus("DROPPED").?);
    // REPEATING has no local twin, a re-watch reads as "watching".
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
    // media 100 appears in both its status list and a custom list, one entry out.
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

test "classifyMediaList: clamps an untrusted progress at the ingestion boundary (ROD-285)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A near-i64-max progress (hostile/MITM/devtools-edited) and a negative one, both
    // must land bounded so they can never overflow render's `progress * bar_w` or
    // persist as garbage. A normal value passes through untouched.
    const body =
        \\{"data":{"MediaListCollection":{"lists":[{"entries":[
        \\{"mediaId":1,"status":"CURRENT","progress":9223372036854775807},
        \\{"mediaId":2,"status":"CURRENT","progress":-42},
        \\{"mediaId":3,"status":"CURRENT","progress":12}
        \\]}]}}}
    ;
    const entries = try classifyMediaList(a, .{ .status = .ok, .body = body });
    var byId = std.AutoHashMap(i64, PulledEntry).init(a);
    for (entries) |e| try byId.put(e.media_id, e);
    try std.testing.expectEqual(MAX_SANE_PROGRESS, byId.get(1).?.progress); // capped
    try std.testing.expectEqual(@as(i64, 0), byId.get(2).?.progress); // negative floored
    try std.testing.expectEqual(@as(i64, 12), byId.get(3).?.progress); // normal untouched
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

    // Contextual RATED beats an all-time RATED, and carries its year.
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
    try std.testing.expectEqualStrings("Sousou no Frieren", meta.title_romaji.?); // ROD-312: romaji carried
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
    // A two-card page: one fully populated, one with no genres / null season,
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
    // Fully enriched card, id tags it for join-back, all three signals present.
    try std.testing.expectEqual(@as(?u64, 182255), metas[0].anilist_id);
    try std.testing.expectEqual(@as(?u32, 89), metas[0].score);
    try std.testing.expectEqual(@as(usize, 3), metas[0].genres.len);
    try std.testing.expectEqual(domain.Season.fall, metas[0].season.?);
    try std.testing.expectEqual(@as(u32, 2023), metas[0].start_date.?.year);
    try std.testing.expectEqual(@as(?u32, 2023), metas[0].year);
    // Graceful-degrade card, still id-tagged, but no score/genre/season+year.
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
    // confirmed-empty page, it must error so `enrichBatch` reports no answer and the
    // batch stays un-stamped. Mirrors classifyById/classifyBySearch on the same shape.
    try std.testing.expectError(error.NoAnswer, pageToMetas(a, "{\"data\":null}"));

    // A parsed page with zero media IS a confirmed empty answer → empty slice, no error.
    const empty = try pageToMetas(a, "{\"data\":{\"Page\":{\"media\":[]}}}");
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "pageToAnime maps a search Page to browse rows; id is the stringified anilist_id (ROD-326)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two hits: one fully populated, one with romaji absent so `name` falls through to
    // english (never blank). An unknown field (siteUrl) must be skipped.
    const json =
        \\{"data":{"Page":{"media":[
        \\{"id":182255,"idMal":52991,"title":{"romaji":"Sousou no Frieren","english":"Frieren","native":"葬送のフリーレン"},"episodes":28,"averageScore":89,"season":"FALL","seasonYear":2023,"siteUrl":"x"},
        \\{"id":1,"title":{"romaji":null,"english":"Only English","native":null}}
        \\]}}}
    ;
    const rows = try pageToAnime(a, json);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("182255", rows[0].id);
    try std.testing.expectEqual(@as(?u64, 182255), rows[0].anilist_id);
    try std.testing.expectEqual(@as(?u64, 52991), rows[0].mal_id);
    try std.testing.expectEqualStrings("Sousou no Frieren", rows[0].name);
    try std.testing.expectEqualStrings("Sousou no Frieren", rows[0].title_romaji.?);
    try std.testing.expectEqualStrings("Frieren", rows[0].english_name.?);
    try std.testing.expectEqual(@as(?u32, 28), rows[0].total_episodes);
    try std.testing.expectEqual(domain.Season.fall, rows[0].season.?);
    // AniList carries no per-track count, so eps_sub/eps_dub stay 0.
    try std.testing.expectEqual(@as(u32, 0), rows[0].eps_sub);
    try std.testing.expectEqual(@as(u32, 0), rows[0].eps_dub);
    try std.testing.expectEqualStrings("1", rows[1].id);
    try std.testing.expectEqualStrings("Only English", rows[1].name);
}

test "pageToAnime: {\"data\":null} and malformed are no-answer, an empty page is a confirmed empty answer (ROD-326)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Same three-state contract as pageToMetas: a GraphQL-level error / unparseable
    // bytes are no answer; a parsed-but-empty page is a confirmed no-match.
    try std.testing.expectError(error.NoAnswer, pageToAnime(a, "{\"data\":null}"));
    try std.testing.expectError(error.NoAnswer, pageToAnime(a, "}{"));
    const empty = try pageToAnime(a, "{\"data\":{\"Page\":{\"media\":[]}}}");
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "searchBody carries search/perPage/page, JSON-escapes the query; GQL_SEARCH declares $page (ROD-326)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The operation declares and uses $page, and every hit page fetches exactly the
    // canonical stride the browse load-more footer keys off.
    try std.testing.expect(std.mem.indexOf(u8, GQL_SEARCH, "$page:Int!") != null);
    try std.testing.expect(std.mem.indexOf(u8, GQL_SEARCH, "page:$page") != null);

    // A quote in the query must survive as an escaped JSON string, round-tripping back
    // to the original on parse (proves the escape ran, not raw interpolation).
    const body = try searchBody(a, "Cowboy \"Bebop\"", 3);
    const parsed = try std.json.parseFromSlice(struct {
        variables: struct { search: []const u8, perPage: u32, page: u32 },
    }, a, body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("Cowboy \"Bebop\"", parsed.value.variables.search);
    try std.testing.expectEqual(@as(u32, @intCast(source.search_page_size)), parsed.value.variables.perPage);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.variables.page);
}

test "GQL_DISCOVER requests pageInfo and rides sort/season as variables (ROD-334)" {
    try std.testing.expect(std.mem.indexOf(u8, GQL_DISCOVER, "pageInfo{hasNextPage}") != null);
    try std.testing.expect(std.mem.indexOf(u8, GQL_DISCOVER, "$page:Int!") != null);
    try std.testing.expect(std.mem.indexOf(u8, GQL_DISCOVER, "sort:$sort") != null);
    try std.testing.expect(std.mem.indexOf(u8, GQL_DISCOVER, "season:$season") != null);
    try std.testing.expect(std.mem.indexOf(u8, GQL_DISCOVER, "seasonYear:$seasonYear") != null);
    // The feed reuses the FULL field set: a page arrives enriched, no batch pass (§9.6).
    try std.testing.expect(std.mem.indexOf(u8, GQL_DISCOVER, GQL_FIELDS) != null);
}

test "discoverBody: axis sort + paging vars; season rides only on This Season (ROD-334)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Vars = struct {
        variables: struct {
            page: u32,
            perPage: u32,
            sort: []const []const u8,
            season: ?[]const u8 = null,
            seasonYear: ?u32 = null,
        },
    };

    // Trending: its sort pair, the requested page, the canonical stride, and NO
    // season/seasonYear keys (omitted, not null'd: an explicit null would filter).
    {
        const parsed = try std.json.parseFromSlice(Vars, a, try discoverBody(a, .trending, 3, 0), .{ .ignore_unknown_fields = true });
        const v = parsed.value.variables;
        try std.testing.expectEqual(@as(u32, 3), v.page);
        try std.testing.expectEqual(@as(u32, discover_page_size), v.perPage);
        try std.testing.expectEqual(@as(usize, 2), v.sort.len);
        try std.testing.expectEqualStrings("TRENDING_DESC", v.sort[0]);
        try std.testing.expectEqualStrings("POPULARITY_DESC", v.sort[1]);
        try std.testing.expect(v.season == null);
        try std.testing.expect(v.seasonYear == null);
    }

    // Top Rated: SCORE_DESC with the ID_DESC tiebreak (§9.6 pagination stability).
    {
        const parsed = try std.json.parseFromSlice(Vars, a, try discoverBody(a, .top_rated, 1, 0), .{ .ignore_unknown_fields = true });
        try std.testing.expectEqualStrings("SCORE_DESC", parsed.value.variables.sort[0]);
        try std.testing.expectEqualStrings("ID_DESC", parsed.value.variables.sort[1]);
    }

    // Popular: same sort pair as This Season but with no season filter.
    {
        const parsed = try std.json.parseFromSlice(Vars, a, try discoverBody(a, .popular, 1, 0), .{ .ignore_unknown_fields = true });
        try std.testing.expectEqualStrings("POPULARITY_DESC", parsed.value.variables.sort[0]);
        try std.testing.expectEqualStrings("ID_DESC", parsed.value.variables.sort[1]);
        try std.testing.expect(parsed.value.variables.season == null);
    }

    // This Season at 2026-07-10T00:00:00Z: the current cour rides as season/seasonYear.
    {
        const parsed = try std.json.parseFromSlice(Vars, a, try discoverBody(a, .this_season, 1, 1_783_641_600 * 1000), .{ .ignore_unknown_fields = true });
        const v = parsed.value.variables;
        try std.testing.expectEqualStrings("POPULARITY_DESC", v.sort[0]);
        try std.testing.expectEqualStrings("SUMMER", v.season.?);
        try std.testing.expectEqual(@as(?u32, 2026), v.seasonYear);
    }
}

test "pageToDiscover: rows + hasNextPage; missing pageInfo reads exhausted (ROD-334)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A page with more behind it. The card fields the §3.8 row needs (format →
    // kind, episodes) must survive the mapping.
    const json =
        \\{"data":{"Page":{"pageInfo":{"hasNextPage":true},"media":[
        \\{"id":182255,"idMal":52991,"title":{"romaji":"Sousou no Frieren"},"episodes":28,"format":"TV","averageScore":89,"season":"FALL","seasonYear":2023},
        \\{"id":1,"title":{"english":"Only English"},"format":"MOVIE"}
        \\]}}}
    ;
    const page = try pageToDiscover(a, json);
    try std.testing.expect(page.has_next_page);
    try std.testing.expectEqual(@as(usize, 2), page.rows.len);
    try std.testing.expectEqualStrings("182255", page.rows[0].id);
    try std.testing.expectEqual(@as(?u64, 182255), page.rows[0].anilist_id);
    try std.testing.expectEqualStrings("TV", page.rows[0].kind.?);
    try std.testing.expectEqual(@as(?u32, 28), page.rows[0].total_episodes);
    try std.testing.expectEqualStrings("MOVIE", page.rows[1].kind.?);

    // The last page: an explicit hasNextPage:false gates further fetches.
    const last = try pageToDiscover(a, "{\"data\":{\"Page\":{\"pageInfo\":{\"hasNextPage\":false},\"media\":[]}}}");
    try std.testing.expect(!last.has_next_page);
    try std.testing.expectEqual(@as(usize, 0), last.rows.len);

    // pageInfo absent (API drift) → exhausted, not an infinite next-page spin.
    const drifted = try pageToDiscover(a, "{\"data\":{\"Page\":{\"media\":[]}}}");
    try std.testing.expect(!drifted.has_next_page);

    // Same three-state contract as pageToAnime: GraphQL-level error / unparseable
    // bytes are no answer, never a confirmed-empty page.
    try std.testing.expectError(error.NoAnswer, pageToDiscover(a, "{\"data\":null}"));
    try std.testing.expectError(error.NoAnswer, pageToDiscover(a, "}{"));
}

test "classifyById: three-state map: match / confirmed no-match / no answer (ROD-278)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A real media → a match (Metadata), tagged by id for the caller's join-back.
    const meta = (try classifyById(a, "{\"data\":{\"Media\":{\"id\":182255,\"episodes\":28}}}")).?;
    try std.testing.expectEqual(@as(?u64, 182255), meta.anilist_id);

    // `{"data":{"Media":null}}`, AniList answered: no anime carries that id. This is
    // a CONFIRMED no-match (null), which the refresh path stamps as a negative cache.
    try std.testing.expect((try classifyById(a, "{\"data\":{\"Media\":null}}")) == null);

    // `{"data":null}` (a GraphQL-level error) and unparseable bytes are NOT answers,
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
    // synopsis, BEL/DEL in a studio name, every control byte must be dropped.
    try std.testing.expectEqualStrings("Hero[31m", try stripControls(a, "Hero\x1b[31m"));
    try std.testing.expectEqualStrings("Action]52;c;QQ", try stripControls(a, "Action\x1b]52;c;QQ\x07"));
    try std.testing.expectEqualStrings("A tale.", try stripControls(a, "A \x1btale."));
    try std.testing.expectEqualStrings("Studio", try stripControls(a, "S\x7ftudio"));
    // Clean input is returned unchanged (and not reallocated, same pointer).
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
