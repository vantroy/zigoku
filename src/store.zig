//! Zigoku — persistence (M2: ROD-65..69).
//!
//! One `Store` over raw SQLite C-interop (`@cImport` libsqlite3, no wrapper —
//! the raw API is the point, this is a learning project). Holds the watch
//! history, per-episode resume positions, and a status-aware episode-list cache.
//!
//! ## Why the key is `(source, source_id)` and not `anilist_id`
//!
//! The ROD-56 spike keyed everything on AniList's integer `Media.id`. That was
//! correct under the *old* split-sources design (AniList catalog + AllAnime
//! stream). M1 reversed that: the thing you search IS the thing you play, and
//! its identity is the **provider's** opaque show handle (`domain.Anime.id` —
//! AllAnime's Mongo `_id`). `anilist_id`/`mal_id` aren't even fetched yet (they
//! arrive with the M3/M4/M5 enrichment layer), so keying on them would make
//! every row a NULL primary key.
//!
//! `domain` is deliberately source-agnostic and `SourceProvider` is a swap
//! seam, so the natural key is the pair `(source, source_id)`: when a provider
//! rots and we swap it, its id namespace can't collide with the dead one's.
//! `anilist_id`/`mal_id` ride along as nullable enrichment columns.
//!
//! Likewise `episode` is **TEXT**, not INTEGER: `domain.EpisodeNumber.raw` is a
//! string because anime labels aren't integers ("1.5" recaps, "SP1" specials).

const std = @import("std");
const builtin = @import("builtin");
const domain = @import("domain.zig");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("time.h");
});
const paths = @import("paths.zig");

// NoHomeDir/Unsupported are NOT here: `Store` itself only ever sees a
// pre-resolved path. `defaultDbPath` reaches those through `paths.Error` and
// carries them via its inferred error set — keeping them out of `Store.Error`
// stops a reader from writing handlers for errors `Store` can't produce.
pub const Error = error{ Open, Exec, Prepare, Step, Bind, OutOfMemory, SchemaTooNew };

/// Schema version this build expects. Bump + add a `MIGRATION_Vn` + a branch in
/// `migrate` when the shape changes — never ALTER-and-ignore.
const SCHEMA_VERSION: c_int = 11;

/// Milliseconds SQLite waits on a held write lock before giving up with SQLITE_BUSY,
/// set once per connection in `open` (ROD-287). Two processes now share one DB as a
/// normal pattern — the TUI plus a standalone/cron'd `zigoku sync` — so a writer can
/// find the write lock held by the other. WAL lets readers through unblocked, so this
/// only gates writer-vs-writer contention; the catch (caught in review) is that the
/// TUI performs its checkpoint/recordPlay writes ON the render/input thread, so a long
/// wait here freezes the UI, not just a background task. We keep it short on purpose:
/// real collisions resolve far below this (a one-time migration is <20ms, a lone
/// markSynced or checkpoint UPDATE is sub-ms), so 250ms is ~10x the realistic worst
/// case yet caps a foreground stall at a quarter-second. If a genuinely stuck peer ever
/// burns the whole budget, failing fast is the right call for a render loop — a dropped
/// checkpoint is recoverable, and a timed-out `open()` falls back to no-store and
/// recovers next launch. NB this does NOT cover the WAL-mode flip in `open`; SQLite
/// skips its busy handler for that lock upgrade, so `enableWal` retries it by hand.
const BUSY_TIMEOUT_MS: c_int = 250;

/// `enableWal` retry budget: attempts × backoff. The WAL-mode flip can return
/// SQLITE_BUSY under a fresh-open race that `busy_timeout` doesn't cover (see
/// `enableWal`), so we retry it manually. 100 × 5ms is a 500ms ceiling — orders of
/// magnitude above the microseconds the winner actually needs, so it converges on the
/// first retry or two in practice; the ceiling only bounds a pathologically wedged peer.
const WAL_RETRY_LIMIT: usize = 100;
const WAL_RETRY_BACKOFF_MS: c_int = 5;

/// Resume thresholds (ROD-67). `fully_watched` is recorded past 95%; the
/// natural-end window (80%) is where the player path stops offering a mid-episode
/// resume and treats the episode as effectively done.
pub const WATCHED_RATIO = 0.95;
pub const NATURAL_END_RATIO = 0.80;

const SqliteDb = ?*c.sqlite3;
const Stmt = ?*c.sqlite3_stmt;

const MIGRATION_V1 =
    \\CREATE TABLE anime (
    \\    source          TEXT    NOT NULL,             -- provider name, e.g. 'allanime'
    \\    source_id       TEXT    NOT NULL,             -- provider-opaque show id
    \\    title           TEXT    NOT NULL,             -- romaji / native display name
    \\    title_english   TEXT,
    \\    mal_id          INTEGER,                      -- enrichment (AniSkip, M5)
    \\    anilist_id      INTEGER,                      -- enrichment (metadata, M3+)
    \\    cover_url       TEXT,                         -- enrichment (cover art, M4)
    \\    total_episodes  INTEGER,                      -- for the tracked translation; NULL if unknown/ongoing
    \\    list_status     TEXT    NOT NULL DEFAULT 'planning', -- watching|completed|planning|paused|dropped
    \\    user_rating     REAL,                         -- our own 0-10 score
    \\    notes           TEXT,
    \\    play_count      INTEGER NOT NULL DEFAULT 0,
    \\    progress        INTEGER NOT NULL DEFAULT 0,   -- count of episodes watched through
    \\    added_at        INTEGER NOT NULL,             -- unix seconds
    \\    last_watched_at INTEGER,                      -- unix seconds, NULL until first play
    \\    PRIMARY KEY (source, source_id)
    \\);
    \\CREATE INDEX idx_anime_last_watched ON anime(last_watched_at DESC);
    \\CREATE INDEX idx_anime_list_status  ON anime(list_status);
    \\CREATE TABLE episode_progress (
    \\    source        TEXT NOT NULL,
    \\    source_id     TEXT NOT NULL,
    \\    translation   TEXT NOT NULL,                  -- 'sub' | 'dub' — resume tracked per track
    \\    episode       TEXT NOT NULL,                  -- raw label: "1", "1.5", "SP1"
    \\    position_secs REAL NOT NULL DEFAULT 0,        -- resume point
    \\    duration_secs REAL NOT NULL DEFAULT 0,        -- 0 = unknown
    \\    fully_watched INTEGER NOT NULL DEFAULT 0,     -- bool: >= WATCHED_RATIO
    \\    updated_at    INTEGER NOT NULL,
    \\    PRIMARY KEY (source, source_id, translation, episode),
    \\    FOREIGN KEY (source, source_id) REFERENCES anime(source, source_id) ON DELETE CASCADE
    \\);
    \\CREATE TABLE episode_cache (
    \\    source        TEXT NOT NULL,
    \\    source_id     TEXT NOT NULL,
    \\    translation   TEXT NOT NULL,                  -- separate rows per track = free sub/dub invalidation
    \\    episodes_blob TEXT NOT NULL,                  -- newline-joined raw episode labels
    \\    fetched_at    INTEGER NOT NULL,
    \\    expires_at    INTEGER NOT NULL,               -- fetched_at + status-aware TTL
    \\    PRIMARY KEY (source, source_id, translation),
    \\    FOREIGN KEY (source, source_id) REFERENCES anime(source, source_id) ON DELETE CASCADE
    \\);
;

const MIGRATION_V2 =
    \\ALTER TABLE anime ADD COLUMN year INTEGER;
    \\ALTER TABLE anime ADD COLUMN status TEXT;
    \\ALTER TABLE anime ADD COLUMN description TEXT;
    \\ALTER TABLE anime ADD COLUMN score INTEGER;
;

const MIGRATION_V3 =
    \\ALTER TABLE anime ADD COLUMN history_visible INTEGER NOT NULL DEFAULT 1;
;

const MIGRATION_V4 =
    \\UPDATE anime
    \\SET history_visible = CASE
    \\    WHEN last_watched_at IS NOT NULL
    \\      OR play_count > 0
    \\      OR progress > 0
    \\      OR user_rating IS NOT NULL
    \\      OR notes IS NOT NULL
    \\      OR list_status != 'planning'
    \\    THEN 1
    \\    ELSE 0
    \\END;
;

// ROD-185: persist the ROD-140 enrichment widening so History (which reads only
// the store via animeFromHistoryRecord) shows the season chip / native title /
// genres, not just the V2 subset. `season` stores the canonical lowercase tag
// (@tagName, round-trips through domain.Season.fromString). `genres` is a
// '\n'-joined blob — display-only, never queried by genre, so it mirrors
// episode_cache.episodes_blob rather than earning a normalized side table.
const MIGRATION_V5 =
    \\ALTER TABLE anime ADD COLUMN season       TEXT;
    \\ALTER TABLE anime ADD COLUMN native_name  TEXT;
    \\ALTER TABLE anime ADD COLUMN kind         TEXT;
    \\ALTER TABLE anime ADD COLUMN start_year   INTEGER;
    \\ALTER TABLE anime ADD COLUMN start_month  INTEGER;
    \\ALTER TABLE anime ADD COLUMN start_day    INTEGER;
    \\ALTER TABLE anime ADD COLUMN genres       TEXT;    -- '\n'-joined; see note above
;

// ROD-182: enrichment content (status/score/description/…) rode alongside the
// immutable `anilist_id` with no clock, so a show enriched once kept month-old
// status/score forever. This column stamps the last successful AniList pull so a
// status-aware TTL (`enrichmentTtl`) can drive refresh-on-view. NULL = never
// enriched, or a row predating v6 — both read as stale (`enrichmentStale`), which
// is also the backfill predicate for pre-ROD-181 rows that never got an id join.
// It rides `anime` (not a side table like episode_cache) because the freshness
// key IS the row's own `status`, so the TTL is computed at read from live columns.
//
// `enrichment_fieldset_version` records WHICH set of enriched columns a row was
// last filled under (see `ENRICHMENT_FIELDSET_VERSION`). Widening the persisted
// enrichment (e.g. ROD-261 adds studios/source/duration) leaves old rows fresh by
// the clock but missing the new columns — a 30d-finished row would never backfill
// them. Bumping the constant marks every older-fieldset row stale regardless of
// clock, so the new columns heal on next view instead of waiting out the TTL.
const MIGRATION_V6 =
    \\ALTER TABLE anime ADD COLUMN enrichment_fetched_at       INTEGER;
    \\ALTER TABLE anime ADD COLUMN enrichment_fieldset_version INTEGER;
;

// ROD-261: the first field of the AniList "shopping trip" widening to land in the
// store. `studios` was already fetched (`GQL_FIELDS`) and carried on domain.Anime,
// but never persisted — so History (which never re-enriches in place) always
// rendered an empty studios list. Same '\n'-joined-blob shape as `genres`; the
// ENRICHMENT_FIELDSET_VERSION bump alongside this heals rows enriched before the
// column existed (see the note above MIGRATION_V6).
const MIGRATION_V7 =
    \\ALTER TABLE anime ADD COLUMN studios TEXT;    -- '\n'-joined; same shape as genres
;

// ROD-261: per-episode runtime in minutes, the second field of the AniList
// widening. A plain nullable scalar (mirrors total_episodes); the fieldset bump
// alongside heals rows enriched before the column existed.
const MIGRATION_V8 =
    \\ALTER TABLE anime ADD COLUMN duration INTEGER;
;

// ROD-261: adaptation source + the pre-selected AniList ranking. `source` is the
// raw enum (prettified at render). The ranking is stored pre-selected (selectRank
// chose the best row at enrich time) as three scalars — position, type, and year
// (null year = an all-time ranking) — rather than a raw blob, so render just
// composes them. The fieldset bump alongside heals rows enriched before these.
const MIGRATION_V9 =
    \\ALTER TABLE anime ADD COLUMN source_material TEXT;
    \\ALTER TABLE anime ADD COLUMN rank            INTEGER;
    \\ALTER TABLE anime ADD COLUMN rank_type       TEXT;
    \\ALTER TABLE anime ADD COLUMN rank_year       INTEGER;
;

// ROD-261 chips slice: the next-episode airing (stored ABSOLUTE — `airingAt` unix
// seconds + episode — so the countdown recomputes from the live clock at render,
// never a stale relative delta) and `countryOfOrigin` for the non-JP marker. Not
// rail fields: these ride the §4.4 chips row, but they persist like any other
// enrichment. The fieldset bump alongside heals rows enriched before them.
const MIGRATION_V10 =
    \\ALTER TABLE anime ADD COLUMN next_airing_at      INTEGER;
    \\ALTER TABLE anime ADD COLUMN next_airing_episode INTEGER;
    \\ALTER TABLE anime ADD COLUMN country             TEXT;
;

// ROD-284: AniList push delta-tracking. `synced_status`/`synced_progress` snapshot
// the (list_status, progress) pair last accepted by AniList (SaveMediaListEntry).
// A row is dirty — needs pushing — when it has an `anilist_id` and its live pair
// differs from this snapshot (or the snapshot is NULL: never synced). Snapshot-vs-
// live, NOT a `synced_at` clock: `last_watched_at` only moves on playback, so a
// wall-clock watermark would silently miss a manual drop/pause. Both NULL for
// every pre-v11 row → the first push treats the whole engaged library as dirty and
// backfills the snapshot. This pair is also the last-known-synced baseline the
// ROD-285 pull/reconcile 3-way merge will read, so it isn't push-only scaffolding.
const MIGRATION_V11 =
    \\ALTER TABLE anime ADD COLUMN synced_status   TEXT;
    \\ALTER TABLE anime ADD COLUMN synced_progress INTEGER;
;

// ── Records ─────────────────────────────────────────────────────────────────

/// A library/history row. Text fields returned from `loadHistory` are owned by
/// the arena passed to it.
pub const AnimeRecord = struct {
    source: []const u8,
    source_id: []const u8,
    title: []const u8,
    title_english: ?[]const u8 = null,
    mal_id: ?i64 = null,
    anilist_id: ?i64 = null,
    cover_url: ?[]const u8 = null,
    year: ?i64 = null,
    status: ?[]const u8 = null,
    description: ?[]const u8 = null,
    score: ?i64 = null,
    total_episodes: ?i64 = null,
    /// ROD-261: per-episode runtime in minutes (AniList `duration`).
    duration: ?i64 = null,
    /// ROD-261: raw AniList adaptation source enum (prettified at render). Named
    /// `source_material`, not `source` — `source` is the provider PK key above.
    source_material: ?[]const u8 = null,
    /// ROD-261: the pre-selected ranking — position, type ("RATED"/"POPULAR"),
    /// and year (null = all-time). Composed into `#{rank} {type} {year}` at render.
    rank: ?i64 = null,
    rank_type: ?[]const u8 = null,
    rank_year: ?i64 = null,
    /// ROD-261: next-episode airing, stored absolute (unix seconds) + episode, so
    /// the §4.4 countdown recomputes from the live clock. `country` = AniList
    /// countryOfOrigin (non-JP marker).
    next_airing_at: ?i64 = null,
    next_airing_episode: ?i64 = null,
    country: ?[]const u8 = null,
    // ROD-185 enrichment. `season` is the canonical lowercase tag; `genres` is
    // the split list (arena-owned on read, borrowed from domain on construct) —
    // the '\n' blob lives only in the column, joined at upsert / split at load.
    season: ?[]const u8 = null,
    native_name: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    start_year: ?i64 = null,
    start_month: ?i64 = null,
    start_day: ?i64 = null,
    genres: []const []const u8 = &.{},
    /// ROD-261: main animation studios, same '\n'-blob shape and borrowed/owned
    /// contract as `genres` — the column joins at upsert, splits at load.
    studios: []const []const u8 = &.{},
    /// ROD-182: unix seconds of the last successful AniList enrichment pull, or
    /// null if never enriched (also null for rows written before the v6 column).
    /// Drives `enrichmentStale` → refresh-on-view; never touched by user edits.
    enrichment_fetched_at: ?i64 = null,
    /// ROD-182: the `ENRICHMENT_FIELDSET_VERSION` this row was last enriched under;
    /// null = never enriched / pre-v6. Lets a field-set widening (ROD-261) mark old
    /// rows stale by version, not just by clock. Stamped alongside `fetched_at`.
    enrichment_fieldset_version: ?i64 = null,
    list_status: domain.ListStatus = .planning,
    user_rating: ?f64 = null,
    notes: ?[]const u8 = null,
    play_count: i64 = 0,
    progress: i64 = 0,
    added_at: i64 = 0,
    last_watched_at: ?i64 = null,
    /// Whether this row should appear in the History view. Search-only metadata
    /// cache rows stay hidden until the user explicitly tracks or plays them.
    history_visible: bool = true,

    /// Build a row from a freshly-searched show. Only carries what the source
    /// gives us; user state (status/rating/notes/counts) takes table defaults
    /// and is preserved across re-searches by `upsertAnime`.
    pub fn fromDomain(source: []const u8, a: domain.Anime, tt: domain.Translation) AnimeRecord {
        const eps = a.episodeCount(tt);
        return .{
            .source = source,
            .source_id = a.id,
            .title = a.name,
            .title_english = a.english_name,
            // A corrupt provider id past i64 range degrades to "not provided"
            // rather than panicking on the cast.
            .mal_id = if (a.mal_id) |m| std.math.cast(i64, m) else null,
            .anilist_id = if (a.anilist_id) |x| std.math.cast(i64, x) else null,
            .cover_url = a.thumb,
            .year = if (a.year) |y| std.math.cast(i64, y) else null,
            .status = a.status,
            .description = a.description,
            .score = if (a.score) |s| std.math.cast(i64, s) else null,
            .total_episodes = if (a.total_episodes) |n| @intCast(n) else if (eps > 0) @intCast(eps) else null,
            .duration = if (a.duration) |d| @intCast(d) else null,
            .source_material = a.source_material,
            .rank = if (a.rank) |r| @intCast(r) else null,
            .rank_type = a.rank_type,
            .rank_year = if (a.rank_year) |y| @intCast(y) else null,
            .next_airing_at = a.next_airing_at,
            .next_airing_episode = if (a.next_airing_episode) |e| @intCast(e) else null,
            .country = a.country,
            // Store the canonical tag ("winter"…) so it round-trips through
            // domain.Season.fromString on the way back out.
            .season = if (a.season) |s| @tagName(s) else null,
            .native_name = a.native_name,
            .kind = a.kind,
            .start_year = if (a.start_date) |d| @intCast(d.year) else null,
            .start_month = if (a.start_date) |d| if (d.month) |m| @intCast(m) else null else null,
            .start_day = if (a.start_date) |d| if (d.day) |dd| @intCast(dd) else null else null,
            .genres = a.genres,
            .studios = a.studios,
        };
    }

    /// Rebuild a `domain.Date` from the split start_year/month/day columns. A
    /// missing or out-of-range year collapses the whole date to null (a date with
    /// no year isn't a date); month/day independently degrade to "not provided".
    pub fn startDate(rec: AnimeRecord) ?domain.Date {
        const y = rec.start_year orelse return null;
        const year = std.math.cast(u32, y) orelse return null;
        return .{
            .year = year,
            .month = if (rec.start_month) |m| std.math.cast(u32, m) else null,
            .day = if (rec.start_day) |d| std.math.cast(u32, d) else null,
        };
    }
};

pub const Resume = struct {
    position_secs: f64,
    duration_secs: f64,
    fully_watched: bool,

    /// The offset to hand mpv's `--start`. Returns 0 once past the natural-end
    /// window or already fully watched — no point dropping the viewer two
    /// minutes from the credits.
    pub fn startSeconds(self: Resume) u64 {
        if (self.fully_watched) return 0;
        if (self.duration_secs > 0 and self.position_secs / self.duration_secs >= NATURAL_END_RATIO) return 0;
        if (self.position_secs <= 0) return 0;
        // NaN slips past every comparison above; a corrupt huge value overflows
        // the cast. Either way, just start from the top.
        const u64_max_f: f64 = @floatFromInt(std.math.maxInt(u64));
        if (!std.math.isFinite(self.position_secs) or self.position_secs >= u64_max_f) return 0;
        return @intFromFloat(self.position_secs);
    }

    /// `startSeconds`, rewound by `rewind_sec` so the viewer drops back into
    /// context instead of mid-action (ROD-84, `Config.resume_offset_sec`). Only
    /// the value handed to mpv's `--start` should use this; `startSeconds` stays
    /// the raw "is there a resume point" truth for UI cursor seeding. A rewind
    /// past the start just begins from the top (saturating).
    pub fn startSecondsRewound(self: Resume, rewind_sec: u32) u64 {
        const raw = self.startSeconds();
        if (raw == 0) return 0; // top-of-episode / natural-end / watched — nothing to rewind
        return raw -| rewind_sec;
    }
};

// ── Store ───────────────────────────────────────────────────────────────────

pub const Store = struct {
    db: SqliteDb,

    /// Open (creating if needed) the DB at `path`, set WAL + foreign keys, and
    /// migrate to the current schema. `path` must be null-terminated.
    ///
    /// Threading: this single connection handle is shared across threads — the
    /// main loop (getAnime/upsertAnime/episode-cache) and the history worker can
    /// touch it concurrently during startup, and interrupt() is called on it from
    /// the main thread at quit. That sharing is only safe under SQLite's serialized
    /// threading mode. We rely on it by NOT passing SQLITE_OPEN_NOMUTEX (which would
    /// downgrade to multi-thread mode, where one connection is not safe across
    /// threads). Do not add NOMUTEX/FULLMUTEX here without auditing every
    /// cross-thread call site. The assert below trips loud if a build links a
    /// non-serialized SQLite.
    pub fn open(path: [:0]const u8) Error!Store {
        std.debug.assert(c.sqlite3_threadsafe() == 1); // 1 = serialized (see Threading note)
        var db: SqliteDb = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
        if (c.sqlite3_open_v2(path.ptr, &db, flags, null) != c.SQLITE_OK) {
            std.log.err("store: open failed: {s}", .{c.sqlite3_errmsg(db)});
            _ = c.sqlite3_close(db);
            return error.Open;
        }
        var self: Store = .{ .db = db };
        errdefer self.close();
        // Bound lock-contention waits before the first statement runs so migrate()'s
        // BEGIN IMMEDIATE — and every later writer — sits out a concurrent holder
        // instead of erroring immediately (ROD-287). See BUSY_TIMEOUT_MS. The WAL flip
        // is the one thing this can't rescue, so it gets its own retry (enableWal).
        _ = c.sqlite3_busy_timeout(self.db, BUSY_TIMEOUT_MS);
        try self.enableWal();
        try self.exec("PRAGMA foreign_keys = ON;");
        try self.migrate();
        return self;
    }

    /// A private in-memory DB — for tests. Each call is an isolated, blank store.
    pub fn openMemory() Error!Store {
        return open(":memory:");
    }

    /// Abort any statement currently running on this connection. `sqlite3_interrupt`
    /// is documented thread-safe regardless of threading mode, and a no-op when no
    /// statement is running. Used on quit to abandon an in-flight loadHistory so
    /// teardown doesn't block on the query (ROD-179). (The broader cross-thread
    /// sharing of this handle — see open() — relies on serialized mode, not this
    /// call specifically.)
    pub fn interrupt(self: *Store) void {
        _ = c.sqlite3_interrupt(self.db);
    }

    pub fn close(self: *Store) void {
        _ = c.sqlite3_close(self.db);
        self.db = null;
    }

    /// Current unix time in seconds. Injected at call sites so tests stay
    /// deterministic (they pass fixed values; the app passes this).
    pub fn nowSecs() i64 {
        return @intCast(c.time(null));
    }

    // ── ROD-66: anime history CRUD + load_all ────────────────────────────────

    /// Insert a show, or refresh *source-derived* metadata if it already exists.
    /// Deliberately does NOT touch user state on conflict (play_count, progress,
    /// list_status, user_rating, notes, added_at, last_watched_at, and the ROD-284
    /// sync snapshot synced_status/synced_progress) — re-running a search must never
    /// wipe the viewer's history, nor reset the AniList sync snapshot (which would
    /// make every re-viewed show spuriously, permanently dirty). The invariant is
    /// simply that none of those columns appear in the `ON CONFLICT DO UPDATE SET`
    /// clause below; keep it that way when adding columns.
    ///
    /// `cover_url` breaks the plain COALESCE "new-if-present" rule to prefer a
    /// fetchable absolute url over a relative ref (ROD-267): a stored AniList/MAL
    /// cover is never clobbered by a later `mcovers/…` re-search, so an enriched
    /// cover stays put on surfaces that never re-enrich (History). "Absolute" is a
    /// case-sensitive `http(s)://` GLOB — it mirrors `domain.isAbsoluteUrl` so the
    /// two layers can't drift; a looser `LIKE 'http%'` let non-URL "http…" garbage
    /// stick or clobber a good cover (ROD-267 review). Note a new absolute *does*
    /// replace a stored absolute here (unlike the in-memory merge, which never
    /// churns absolute→absolute) — benign, the re-persisted URL is ~always the same.
    /// `scratch` joins the genres and studios lists into '\n' blobs for binding
    /// (only touched when the respective list is non-empty); pass an arena — like
    /// `putCachedEpisodes`, the joins aren't freed here, they ride the caller's
    /// arena to teardown. It is safe to pass a non-arena (e.g. `testing.allocator`)
    /// ONLY when both `a.genres` and `a.studios` are empty — then nothing is
    /// allocated and the lifetime contract is moot.
    pub fn upsertAnime(self: *Store, a: AnimeRecord, now: i64, scratch: Allocator) Error!void {
        const sql =
            \\INSERT INTO anime (source, source_id, title, title_english, mal_id, anilist_id,
            \\    cover_url, year, status, description, score, total_episodes,
            \\    list_status, user_rating, notes, play_count, progress, added_at, last_watched_at, history_visible,
            \\    season, native_name, kind, start_year, start_month, start_day, genres,
            \\    enrichment_fetched_at, enrichment_fieldset_version, studios, duration,
            \\    source_material, rank, rank_type, rank_year,
            \\    next_airing_at, next_airing_episode, country)
            \\VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            \\ON CONFLICT(source, source_id) DO UPDATE SET
            \\    title          = excluded.title,
            \\    title_english  = COALESCE(excluded.title_english, anime.title_english),
            \\    mal_id         = COALESCE(excluded.mal_id, anime.mal_id),
            \\    anilist_id     = COALESCE(excluded.anilist_id, anime.anilist_id),
            \\    cover_url      = CASE
            \\        WHEN excluded.cover_url GLOB 'http://*' OR excluded.cover_url GLOB 'https://*' THEN excluded.cover_url
            \\        WHEN anime.cover_url GLOB 'http://*' OR anime.cover_url GLOB 'https://*' THEN anime.cover_url
            \\        ELSE COALESCE(excluded.cover_url, anime.cover_url)
            \\    END,
            \\    year           = COALESCE(excluded.year, anime.year),
            \\    status         = COALESCE(excluded.status, anime.status),
            \\    description    = COALESCE(excluded.description, anime.description),
            \\    score          = COALESCE(excluded.score, anime.score),
            \\    total_episodes = COALESCE(excluded.total_episodes, anime.total_episodes),
            \\    season         = COALESCE(excluded.season, anime.season),
            \\    native_name    = COALESCE(excluded.native_name, anime.native_name),
            \\    kind           = COALESCE(excluded.kind, anime.kind),
            \\    start_year     = COALESCE(excluded.start_year, anime.start_year),
            \\    start_month    = COALESCE(excluded.start_month, anime.start_month),
            \\    start_day      = COALESCE(excluded.start_day, anime.start_day),
            \\    genres         = COALESCE(excluded.genres, anime.genres),
            \\    history_visible = MAX(excluded.history_visible, anime.history_visible),
            \\    enrichment_fetched_at = COALESCE(excluded.enrichment_fetched_at, anime.enrichment_fetched_at),
            \\    enrichment_fieldset_version = COALESCE(excluded.enrichment_fieldset_version, anime.enrichment_fieldset_version),
            \\    studios        = COALESCE(excluded.studios, anime.studios),
            \\    duration       = COALESCE(excluded.duration, anime.duration),
            \\    source_material = COALESCE(excluded.source_material, anime.source_material),
            \\    rank           = COALESCE(excluded.rank, anime.rank),
            \\    rank_type      = COALESCE(excluded.rank_type, anime.rank_type),
            \\    rank_year      = COALESCE(excluded.rank_year, anime.rank_year),
            \\    next_airing_at = COALESCE(excluded.next_airing_at, anime.next_airing_at),
            \\    next_airing_episode = COALESCE(excluded.next_airing_episode, anime.next_airing_episode),
            \\    country        = COALESCE(excluded.country, anime.country)
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        try bindText(stmt, 1, a.source);
        try bindText(stmt, 2, a.source_id);
        try bindText(stmt, 3, a.title);
        try bindOptText(stmt, 4, a.title_english);
        try bindOptI64(stmt, 5, a.mal_id);
        try bindOptI64(stmt, 6, a.anilist_id);
        try bindOptText(stmt, 7, a.cover_url);
        try bindOptI64(stmt, 8, a.year);
        try bindOptText(stmt, 9, a.status);
        try bindOptText(stmt, 10, a.description);
        try bindOptI64(stmt, 11, a.score);
        try bindOptI64(stmt, 12, a.total_episodes);
        try bindText(stmt, 13, a.list_status.str());
        try bindOptF64(stmt, 14, a.user_rating);
        try bindOptText(stmt, 15, a.notes);
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 16, a.play_count));
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 17, a.progress));
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 18, if (a.added_at != 0) a.added_at else now));
        try bindOptI64(stmt, 19, a.last_watched_at);
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 20, if (a.history_visible) 1 else 0));
        try bindOptText(stmt, 21, a.season);
        try bindOptText(stmt, 22, a.native_name);
        try bindOptText(stmt, 23, a.kind);
        try bindOptI64(stmt, 24, a.start_year);
        try bindOptI64(stmt, 25, a.start_month);
        try bindOptI64(stmt, 26, a.start_day);
        // Empty list → bind NULL so the COALESCE preserves any genres already
        // persisted by an earlier enrichment (same "re-search never wipes" rule
        // the scalar fields lean on).
        if (a.genres.len == 0) {
            try checkBind(stmt, c.sqlite3_bind_null(stmt, 27));
        } else {
            try bindText(stmt, 27, try joinStrBlob(scratch, a.genres));
        }
        try bindOptI64(stmt, 28, a.enrichment_fetched_at);
        try bindOptI64(stmt, 29, a.enrichment_fieldset_version);
        // Same empty→NULL rule as genres, so a re-search that carries no studios
        // never wipes a list an earlier enrichment persisted (ROD-261).
        if (a.studios.len == 0) {
            try checkBind(stmt, c.sqlite3_bind_null(stmt, 30));
        } else {
            try bindText(stmt, 30, try joinStrBlob(scratch, a.studios));
        }
        try bindOptI64(stmt, 31, a.duration);
        try bindOptText(stmt, 32, a.source_material);
        try bindOptI64(stmt, 33, a.rank);
        try bindOptText(stmt, 34, a.rank_type);
        try bindOptI64(stmt, 35, a.rank_year);
        try bindOptI64(stmt, 36, a.next_airing_at);
        try bindOptI64(stmt, 37, a.next_airing_episode);
        try bindOptText(stmt, 38, a.country);

        try self.stepDone(stmt);
    }

    /// Canonical enrichment-persist path (ROD-280): map a freshly-fetched domain row
    /// into the store, set `history_visible`, and — ONLY when `stamp_fresh` — advance
    /// the enrichment freshness clock (`enrichment_fetched_at` +
    /// `enrichment_fieldset_version`), then upsert.
    ///
    /// `stamp_fresh` must be true only when AniList returned a *confirmed* answer (a
    /// match or a confirmed no-match), never on a transport/parse failure — see the
    /// ROD-278 `EnrichError` contract. Folding the gate here means it lives in ONE
    /// place: search (`persistResults`), Discover (`persistSlot`), and the
    /// refresh-on-view handler all route through this, so a new caller can't
    /// reintroduce an un-gated stamp (the class of bug ROD-278 fixed across 3 sites).
    ///
    /// `now` timestamps both the stamp and `upsertAnime`'s `added_at` default — pass
    /// one value per page so a batch shares a timestamp. `scratch` is the genres-blob
    /// arena, same contract as `upsertAnime`.
    pub fn upsertEnriched(
        self: *Store,
        source: []const u8,
        anime: domain.Anime,
        tt: domain.Translation,
        visible: bool,
        stamp_fresh: bool,
        now: i64,
        scratch: Allocator,
    ) Error!void {
        var rec = AnimeRecord.fromDomain(source, anime, tt);
        rec.history_visible = visible;
        if (stamp_fresh) {
            rec.enrichment_fetched_at = now;
            rec.enrichment_fieldset_version = ENRICHMENT_FIELDSET_VERSION;
        }
        return self.upsertAnime(rec, now, scratch);
    }

    /// All shows, most-recently-watched first (then most-recently-added). Every
    /// text field is duped into `arena`.
    pub fn loadHistory(self: *Store, arena: Allocator) Error![]AnimeRecord {
        const sql =
            \\SELECT source, source_id, title, title_english, mal_id, anilist_id, cover_url,
            \\    year, status, description, score, total_episodes, list_status,
            \\    user_rating, notes, play_count, progress, added_at, last_watched_at,
            \\    season, native_name, kind, start_year, start_month, start_day, genres,
            \\    enrichment_fetched_at, enrichment_fieldset_version, studios, duration,
            \\    source_material, rank, rank_type, rank_year,
            \\    next_airing_at, next_airing_episode, country
            \\FROM anime
            \\WHERE history_visible != 0
            \\ORDER BY last_watched_at DESC NULLS LAST, added_at DESC
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        var rows: std.ArrayList(AnimeRecord) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try rows.append(arena, .{
                .source = try dupeText(arena, stmt, 0) orelse "",
                .source_id = try dupeText(arena, stmt, 1) orelse "",
                .title = try dupeText(arena, stmt, 2) orelse "",
                .title_english = try dupeText(arena, stmt, 3),
                .mal_id = colOptI64(stmt, 4),
                .anilist_id = colOptI64(stmt, 5),
                .cover_url = try dupeText(arena, stmt, 6),
                .year = colOptI64(stmt, 7),
                .status = try dupeText(arena, stmt, 8),
                .description = try dupeText(arena, stmt, 9),
                .score = colOptI64(stmt, 10),
                .total_episodes = colOptI64(stmt, 11),
                .list_status = colStatus(stmt, 12),
                .user_rating = colOptF64(stmt, 13),
                .notes = try dupeText(arena, stmt, 14),
                .play_count = c.sqlite3_column_int64(stmt, 15),
                .progress = c.sqlite3_column_int64(stmt, 16),
                .added_at = c.sqlite3_column_int64(stmt, 17),
                .last_watched_at = colOptI64(stmt, 18),
                .season = try dupeText(arena, stmt, 19),
                .native_name = try dupeText(arena, stmt, 20),
                .kind = try dupeText(arena, stmt, 21),
                .start_year = colOptI64(stmt, 22),
                .start_month = colOptI64(stmt, 23),
                .start_day = colOptI64(stmt, 24),
                .genres = try dupeStrBlob(arena, stmt, 25),
                .enrichment_fetched_at = colOptI64(stmt, 26),
                .enrichment_fieldset_version = colOptI64(stmt, 27),
                .studios = try dupeStrBlob(arena, stmt, 28),
                .duration = colOptI64(stmt, 29),
                .source_material = try dupeText(arena, stmt, 30),
                .rank = colOptI64(stmt, 31),
                .rank_type = try dupeText(arena, stmt, 32),
                .rank_year = colOptI64(stmt, 33),
                .next_airing_at = colOptI64(stmt, 34),
                .next_airing_episode = colOptI64(stmt, 35),
                .country = try dupeText(arena, stmt, 36),
                .history_visible = true,
            });
        }
        return rows.toOwnedSlice(arena);
    }

    // ── AniList sync (ROD-284) ────────────────────────────────────────────────

    /// The minimal projection the AniList push needs for one dirty row: the PK to
    /// stamp the snapshot back onto, the media id to target, and the (status,
    /// progress) pair to send. `title` rides along only for the CLI's log line.
    /// `anilist_id` is non-optional here — `loadDirtyForSync` filters out the rows
    /// that lack one (no id → nothing to push them to).
    pub const SyncRow = struct {
        source: []const u8,
        source_id: []const u8,
        title: []const u8,
        anilist_id: i64,
        list_status: domain.ListStatus,
        progress: i64,
    };

    /// Rows whose local (list_status, progress) differs from what AniList last
    /// accepted — the push work-list (ROD-284). Scoped to the engaged library
    /// (`history_visible`, the same gate as `loadHistory`) so a merely-browsed
    /// search-cache row never floods the user's AniList planning list, and to rows
    /// carrying an `anilist_id` (no id → no push target). A NULL snapshot
    /// (`synced_status IS NULL`) reads as never-synced, so the first run returns the
    /// whole engaged, id-bearing library. Text fields are duped into `arena`.
    pub fn loadDirtyForSync(self: *Store, arena: Allocator) Error![]SyncRow {
        const sql =
            \\SELECT source, source_id, title, anilist_id, list_status, progress
            \\FROM anime
            \\WHERE history_visible != 0
            \\  AND anilist_id IS NOT NULL
            \\  AND (synced_status IS NULL
            \\       OR synced_status <> list_status
            \\       OR synced_progress IS NULL
            \\       OR synced_progress <> progress)
            \\ORDER BY last_watched_at DESC NULLS LAST, added_at DESC
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        var rows: std.ArrayList(SyncRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try rows.append(arena, .{
                .source = try dupeText(arena, stmt, 0) orelse "",
                .source_id = try dupeText(arena, stmt, 1) orelse "",
                .title = try dupeText(arena, stmt, 2) orelse "",
                .anilist_id = c.sqlite3_column_int64(stmt, 3),
                .list_status = colStatus(stmt, 4),
                .progress = c.sqlite3_column_int64(stmt, 5),
            });
        }
        return rows.toOwnedSlice(arena);
    }

    /// Record that AniList accepted `(status, progress)` for one show — advance the
    /// sync snapshot so the row reads clean on `loadDirtyForSync` until it changes
    /// again. Called once per successful `SaveMediaListEntry`.
    pub fn markSynced(
        self: *Store,
        source: []const u8,
        source_id: []const u8,
        status: domain.ListStatus,
        progress: i64,
    ) Error!void {
        const sql =
            \\UPDATE anime
            \\SET synced_status = ?, synced_progress = ?
            \\WHERE source = ? AND source_id = ?
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, status.str());
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 2, progress));
        try bindText(stmt, 3, source);
        try bindText(stmt, 4, source_id);
        try self.stepDone(stmt);
    }

    /// How many engaged rows can't be pushed for lack of an `anilist_id` (ROD-284).
    /// The push's work-list (`loadDirtyForSync`) filters these out — there's no
    /// media to target — so this count is how the CLI reports "the rest" it skipped:
    /// shows with no AniList link yet (enrichment never resolved an id).
    pub fn countEngagedWithoutAniListId(self: *Store) Error!i64 {
        const stmt = try self.prepare("SELECT COUNT(*) FROM anime WHERE history_visible != 0 AND anilist_id IS NULL");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.Step;
        return c.sqlite3_column_int64(stmt, 0);
    }

    /// The titles behind `countEngagedWithoutAniListId` — the engaged shows that can't
    /// be pushed for lack of an `anilist_id` — so `zigoku sync` can list *which* shows
    /// have no AniList link yet (enrichment never resolved one), not just how many. The
    /// actionable half: the user can re-open these to re-enrich. Most-recently-active
    /// first (matches the push work-list ordering); titles duped into `arena`.
    pub fn loadEngagedWithoutAniListId(self: *Store, arena: Allocator) Error![]const []const u8 {
        const sql =
            \\SELECT title FROM anime
            \\WHERE history_visible != 0 AND anilist_id IS NULL
            \\ORDER BY last_watched_at DESC NULLS LAST, added_at DESC
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        var out: std.ArrayList([]const u8) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try out.append(arena, try dupeText(arena, stmt, 0) orelse "");
        }
        return out.toOwnedSlice(arena);
    }

    /// One local row eligible for pull/reconcile (ROD-285): the join key + PK to
    /// write back through, the current local (list_status, progress), and the
    /// last-synced snapshot — the 3-way-merge ancestor. `synced_status`/
    /// `synced_progress` are optional: NULL = never synced (no ancestor), which the
    /// merge treats as a first-contact bootstrap. `anilist_id` is non-optional —
    /// `loadReconcileRows` filters out rows without one (nothing to join a remote
    /// entry to).
    pub const ReconcileRow = struct {
        source: []const u8,
        source_id: []const u8,
        anilist_id: i64,
        list_status: domain.ListStatus,
        progress: i64,
        synced_status: ?domain.ListStatus,
        synced_progress: ?i64,
    };

    /// The pull/reconcile candidate set (ROD-285): every engaged, id-bearing row,
    /// with its last-synced snapshot for the 3-way merge. Same gate as
    /// `loadDirtyForSync` (engaged + `anilist_id`) but NOT filtered to dirty rows —
    /// reconcile must see clean rows too, since a *remote* change lands on a row that
    /// is locally unchanged. Restricting to the engaged library (`history_visible`)
    /// keeps a merely-browsed search-cache row from being reshaped by a remote list;
    /// importing onto browsed/absent rows is a deliberate follow-up, not v1. Text
    /// fields are duped into `arena`.
    pub fn loadReconcileRows(self: *Store, arena: Allocator) Error![]ReconcileRow {
        const sql =
            \\SELECT source, source_id, anilist_id, list_status, progress, synced_status, synced_progress
            \\FROM anime
            \\WHERE history_visible != 0
            \\  AND anilist_id IS NOT NULL
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        var rows: std.ArrayList(ReconcileRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try rows.append(arena, .{
                .source = try dupeText(arena, stmt, 0) orelse "",
                .source_id = try dupeText(arena, stmt, 1) orelse "",
                .anilist_id = c.sqlite3_column_int64(stmt, 2),
                .list_status = colStatus(stmt, 3),
                .progress = c.sqlite3_column_int64(stmt, 4),
                .synced_status = colOptStatus(stmt, 5),
                .synced_progress = colOptI64(stmt, 6),
            });
        }
        return rows.toOwnedSlice(arena);
    }

    /// Apply a reconciled pull to one row (ROD-285) — but only if the row still holds
    /// the `(expected_status, expected_progress)` pair the merge was computed from.
    /// Sets the merged local (list_status, progress) AND advances the sync snapshot to
    /// what AniList now holds, in one guarded UPDATE. Returns `true` when the write
    /// landed, `false` when the guard matched zero rows — i.e. a concurrent writer (the
    /// TUI's `recordPlay`/`setListStatus`) moved the row between the bulk
    /// `loadReconcileRows` read and this write. `reconcileAll` computes the merge from a
    /// point-in-time snapshot with no transaction spanning the loop, so without this
    /// guard a mid-flight local edit would be silently clobbered (a lost update); the
    /// guard turns that race into a skip that simply re-reconciles next run. This
    /// matters more once ROD-286 runs sync in-process alongside the live TUI.
    ///
    /// The snapshot becomes the *remote* pair (server truth), not the merged pair — so
    /// if the merge kept a locally-ahead value (a conflict resolved local-authoritative,
    /// or a higher local progress), the row reads dirty against the snapshot and the
    /// next push carries that delta back up. The two directions compose: pull sets the
    /// baseline to the server, push closes any remaining local→remote gap.
    pub fn applyPulled(
        self: *Store,
        source: []const u8,
        source_id: []const u8,
        status: domain.ListStatus,
        progress: i64,
        synced_status: domain.ListStatus,
        synced_progress: i64,
        expected_status: domain.ListStatus,
        expected_progress: i64,
    ) Error!bool {
        const sql =
            \\UPDATE anime
            \\SET list_status = ?, progress = ?, synced_status = ?, synced_progress = ?
            \\WHERE source = ? AND source_id = ?
            \\  AND list_status = ? AND progress = ?
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, status.str());
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 2, progress));
        try bindText(stmt, 3, synced_status.str());
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 4, synced_progress));
        try bindText(stmt, 5, source);
        try bindText(stmt, 6, source_id);
        try bindText(stmt, 7, expected_status.str());
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 8, expected_progress));
        try self.stepDone(stmt);
        // sqlite3_changes counts rows the WHERE matched — 0 means the guard failed
        // (the row changed underneath us), not an error.
        return c.sqlite3_changes(self.db) > 0;
    }

    /// Full stored metadata for one show, or null if it was never persisted.
    pub fn getAnime(self: *Store, arena: Allocator, source: []const u8, source_id: []const u8) Error!?AnimeRecord {
        const sql =
            \\SELECT source, source_id, title, title_english, mal_id, anilist_id, cover_url,
            \\    year, status, description, score, total_episodes, list_status,
            \\    user_rating, notes, play_count, progress, added_at, last_watched_at,
            \\    season, native_name, kind, start_year, start_month, start_day, genres,
            \\    enrichment_fetched_at, enrichment_fieldset_version, history_visible, studios, duration,
            \\    source_material, rank, rank_type, rank_year,
            \\    next_airing_at, next_airing_episode, country
            \\FROM anime
            \\WHERE source = ? AND source_id = ?
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, source);
        try bindText(stmt, 2, source_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return .{
            .source = try dupeText(arena, stmt, 0) orelse "",
            .source_id = try dupeText(arena, stmt, 1) orelse "",
            .title = try dupeText(arena, stmt, 2) orelse "",
            .title_english = try dupeText(arena, stmt, 3),
            .mal_id = colOptI64(stmt, 4),
            .anilist_id = colOptI64(stmt, 5),
            .cover_url = try dupeText(arena, stmt, 6),
            .year = colOptI64(stmt, 7),
            .status = try dupeText(arena, stmt, 8),
            .description = try dupeText(arena, stmt, 9),
            .score = colOptI64(stmt, 10),
            .total_episodes = colOptI64(stmt, 11),
            .list_status = colStatus(stmt, 12),
            .user_rating = colOptF64(stmt, 13),
            .notes = try dupeText(arena, stmt, 14),
            .play_count = c.sqlite3_column_int64(stmt, 15),
            .progress = c.sqlite3_column_int64(stmt, 16),
            .added_at = c.sqlite3_column_int64(stmt, 17),
            .last_watched_at = colOptI64(stmt, 18),
            .season = try dupeText(arena, stmt, 19),
            .native_name = try dupeText(arena, stmt, 20),
            .kind = try dupeText(arena, stmt, 21),
            .start_year = colOptI64(stmt, 22),
            .start_month = colOptI64(stmt, 23),
            .start_day = colOptI64(stmt, 24),
            .genres = try dupeStrBlob(arena, stmt, 25),
            .enrichment_fetched_at = colOptI64(stmt, 26),
            .enrichment_fieldset_version = colOptI64(stmt, 27),
            // ROD-182: surface real visibility (loadHistory hardcodes true since it
            // only returns visible rows) so refresh-on-view can gate on "tracked".
            .history_visible = c.sqlite3_column_int64(stmt, 28) != 0,
            .studios = try dupeStrBlob(arena, stmt, 29),
            .duration = colOptI64(stmt, 30),
            .source_material = try dupeText(arena, stmt, 31),
            .rank = colOptI64(stmt, 32),
            .rank_type = try dupeText(arena, stmt, 33),
            .rank_year = colOptI64(stmt, 34),
            .next_airing_at = colOptI64(stmt, 35),
            .next_airing_episode = colOptI64(stmt, 36),
            .country = try dupeText(arena, stmt, 37),
        };
    }

    /// (status, progress high-water, total episodes) for one show, or null if it
    /// isn't tracked. The minimal read the watch-state machine needs — no arena, no
    /// full AnimeRecord — and a uniform unknown-show guard for the transition paths.
    const StatusRow = struct { status: domain.ListStatus, progress: i64, total: ?i64 };
    fn statusRow(self: *Store, source: []const u8, source_id: []const u8) Error!?StatusRow {
        const stmt = try self.prepare("SELECT list_status, progress, total_episodes FROM anime WHERE source = ? AND source_id = ?");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, source);
        try bindText(stmt, 2, source_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return .{
            .status = colStatus(stmt, 0),
            .progress = c.sqlite3_column_int64(stmt, 1),
            .total = colOptI64(stmt, 2),
        };
    }

    /// Record a play of `episode_index` (1-based) and advance the watch-state
    /// machine (ROD-139 §1). Always bumps play_count, last_watched_at and history
    /// visibility — a play is a play. The `progress` high-water only advances when
    /// `completed` (ROD-168): a partial watch belongs in history but must not mark
    /// the episode watched-through.
    ///
    /// The new `list_status` is decided by `ListStatus.afterPlay` — a pure function
    /// of (current status, post-play progress, total). We read the row first so the
    /// transition lives in testable Zig, not a SQL CASE. Unknown show → silent
    /// no-op (nothing to play).
    pub fn recordPlay(self: *Store, source: []const u8, source_id: []const u8, episode_index: i64, now: i64, completed: bool) Error!void {
        const cur = try self.statusRow(source, source_id) orelse return;
        const new_progress = if (completed) @max(cur.progress, episode_index) else cur.progress;
        const new_status = domain.ListStatus.afterPlay(cur.status, new_progress, cur.total);

        const sql =
            \\UPDATE anime
            \\SET play_count = play_count + 1,
            \\    last_watched_at = ?,
            \\    progress = ?,
            \\    list_status = ?,
            \\    history_visible = 1
            \\WHERE source = ? AND source_id = ?
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 1, now));
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 2, new_progress));
        try bindText(stmt, 3, new_status.str());
        try bindText(stmt, 4, source);
        try bindText(stmt, 5, source_id);
        try self.stepDone(stmt);
    }

    /// Manually set the watch-state (ROD-139 §1 manual transitions: pause / drop /
    /// force-complete / re-plan / resume-to-watching). Unlike `recordPlay` this
    /// never bumps play_count or last_watched_at — moving a show to paused/dropped
    /// is not a watch event. It does make the row history-visible: an explicit
    /// status means the user is tracking it. Force-complete snaps `progress` up to
    /// `total_episodes` (when it's a real count) so the bar reads full; every other
    /// transition leaves progress untouched. Unknown show → silent no-op.
    pub fn setListStatus(self: *Store, source: []const u8, source_id: []const u8, status: domain.ListStatus) Error!void {
        const cur = try self.statusRow(source, source_id) orelse return;
        // Snap to the finale on force-complete — but only for a real total. The
        // `t > 0` guard mirrors `ListStatus.afterPlay`: AllAnime's
        // `total_episodes = 0` quirk must not reset progress to zero.
        var new_progress = cur.progress;
        if (status == .completed) {
            if (cur.total) |t| {
                if (t > 0) new_progress = t;
            }
        }

        const sql =
            \\UPDATE anime
            \\SET list_status = ?,
            \\    progress = ?,
            \\    history_visible = 1
            \\WHERE source = ? AND source_id = ?
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, status.str());
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 2, new_progress));
        try bindText(stmt, 3, source);
        try bindText(stmt, 4, source_id);
        try self.stepDone(stmt);
    }

    /// Restore an exact (list_status, progress) pair for undo (ROD-193 §B).
    /// Unlike `setListStatus`, this writes `progress` verbatim and never applies
    /// the force-complete snap — undo must reinstate the captured prior value, not
    /// re-derive it. Mirrors `setListStatus`'s `history_visible = 1` so an undone
    /// row stays on the watchlist.
    pub fn restoreListStatus(self: *Store, source: []const u8, source_id: []const u8, status: domain.ListStatus, progress: i64) Error!void {
        const sql =
            \\UPDATE anime
            \\SET list_status = ?,
            \\    progress = ?,
            \\    history_visible = 1
            \\WHERE source = ? AND source_id = ?
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, status.str());
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 2, progress));
        try bindText(stmt, 3, source);
        try bindText(stmt, 4, source_id);
        try self.stepDone(stmt);
    }

    // ── ROD-193: recompute progress from episode_progress ────────────────────

    /// Recompute `anime.progress` for one show from its `episode_progress` rows
    /// (ROD-193). Returns the new high-water so the caller can patch in-memory
    /// state without a re-read.
    ///
    /// **Strategy A — sorted-index:** collect all `episode_progress` rows for
    /// (source, source_id, translation), sort them by `EpisodeNumber.sortKey`
    /// (ascending, matching the detail grid), then set `progress` to the 1-based
    /// index of the last row whose `fully_watched = 1`. If no row is
    /// fully-watched the result is 0. Rows for episodes that have never been
    /// started are not present in `episode_progress`, so the count reflects only
    /// what was started and finished.
    ///
    /// **Named contract:** progress is the 1-based ordinal of the last
    /// fully-watched episode among the rows present — not a count of total watched
    /// episodes, not an absolute episode number. Gap-watching (e.g. only eps 3 and
    /// 5 fully watched, nothing else stored) produces a result of 2 (index of the
    /// last fully-watched row in the sorted 2-row slice), intentionally
    /// under-counting. This is the single source of truth for recompute semantics.
    ///
    /// Translation-scoped on purpose: `anime.progress` tracks the last-watched
    /// high-water for the tracked translation; mixing sub and dub rows would give
    /// a meaningless combined count. Accepted limitation (ROD-193 review): if the
    /// session's translation has no rows but another does (watched dub, recomputing
    /// in sub), this returns 0 — single-translation usage, not worth the machinery.
    ///
    /// This is recompute-only: no episode_progress rows are deleted. A show with
    /// no fully_watched rows recomputes to 0.
    pub fn recomputeProgress(self: *Store, scratch: Allocator, source: []const u8, source_id: []const u8, tt: domain.Translation) Error!i64 {
        // 1. Fetch all episode_progress rows for this (source, source_id, translation).
        const sql_sel =
            \\SELECT episode, fully_watched FROM episode_progress
            \\WHERE source = ? AND source_id = ? AND translation = ?
        ;
        const stmt = try self.prepare(sql_sel);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, source);
        try bindText(stmt, 2, source_id);
        try bindText(stmt, 3, tt.str());

        // 2. Collect rows into a scratch-allocated list; dupe labels into scratch.
        const Row = struct { ep: domain.EpisodeNumber, watched: bool };
        var rows: std.ArrayList(Row) = .empty;
        while (true) {
            switch (c.sqlite3_step(stmt)) {
                c.SQLITE_ROW => {
                    const label_ptr = c.sqlite3_column_text(stmt, 0);
                    const label_len: usize = if (label_ptr != null) @intCast(c.sqlite3_column_bytes(stmt, 0)) else 0;
                    const label = if (label_ptr != null) try scratch.dupe(u8, label_ptr[0..label_len]) else try scratch.dupe(u8, "");
                    const fw = c.sqlite3_column_int64(stmt, 1) != 0;
                    try rows.append(scratch, .{ .ep = .{ .raw = label }, .watched = fw });
                },
                c.SQLITE_DONE => break,
                else => return error.Step,
            }
        }

        // 3. Sort by EpisodeNumber.sortKey (ascending), matching the detail grid.
        std.mem.sort(Row, rows.items, {}, struct {
            fn lessThan(_: void, a: Row, b: Row) bool {
                return a.ep.sortKey() < b.ep.sortKey();
            }
        }.lessThan);

        // 4. high_water = 1-based index of the LAST row with fully_watched=1.
        var high_water: i64 = 0;
        for (rows.items, 0..) |row, i| {
            if (row.watched) high_water = @intCast(i + 1);
        }

        // 5. UPDATE anime SET progress = ? WHERE source = ? AND source_id = ?
        const sql_upd = "UPDATE anime SET progress = ? WHERE source = ? AND source_id = ?";
        const upd = try self.prepare(sql_upd);
        defer _ = c.sqlite3_finalize(upd);
        try checkBind(upd, c.sqlite3_bind_int64(upd, 1, high_water));
        try bindText(upd, 2, source);
        try bindText(upd, 3, source_id);
        try self.stepDone(upd);

        return high_water;
    }

    // ── ROD-67: episode resume read/write ────────────────────────────────────

    /// Upsert the resume point for one (show, track, episode). `fully_watched`
    /// is derived from the ratio so callers never have to compute it.
    pub fn saveProgress(
        self: *Store,
        source: []const u8,
        source_id: []const u8,
        tt: domain.Translation,
        episode: []const u8,
        position_secs: f64,
        duration_secs: f64,
        now: i64,
    ) Error!void {
        const watched: i64 = if (duration_secs > 0 and position_secs / duration_secs >= WATCHED_RATIO) 1 else 0;
        const sql =
            \\INSERT INTO episode_progress
            \\    (source, source_id, translation, episode, position_secs, duration_secs, fully_watched, updated_at)
            \\VALUES (?,?,?,?,?,?,?,?)
            \\ON CONFLICT(source, source_id, translation, episode) DO UPDATE SET
            \\    position_secs = excluded.position_secs,
            \\    duration_secs = excluded.duration_secs,
            \\    fully_watched = excluded.fully_watched,
            \\    updated_at    = excluded.updated_at
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, source);
        try bindText(stmt, 2, source_id);
        try bindText(stmt, 3, tt.str());
        try bindText(stmt, 4, episode);
        try checkBind(stmt, c.sqlite3_bind_double(stmt, 5, position_secs));
        try checkBind(stmt, c.sqlite3_bind_double(stmt, 6, duration_secs));
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 7, watched));
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 8, now));
        try self.stepDone(stmt);
    }

    /// The saved resume point, or null if this episode was never started.
    pub fn getResume(
        self: *Store,
        source: []const u8,
        source_id: []const u8,
        tt: domain.Translation,
        episode: []const u8,
    ) Error!?Resume {
        const sql =
            \\SELECT position_secs, duration_secs, fully_watched FROM episode_progress
            \\WHERE source = ? AND source_id = ? AND translation = ? AND episode = ?
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, source);
        try bindText(stmt, 2, source_id);
        try bindText(stmt, 3, tt.str());
        try bindText(stmt, 4, episode);
        switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => return .{
                .position_secs = c.sqlite3_column_double(stmt, 0),
                .duration_secs = c.sqlite3_column_double(stmt, 1),
                .fully_watched = c.sqlite3_column_int64(stmt, 2) != 0,
            },
            c.SQLITE_DONE => return null,
            else => return error.Step,
        }
    }

    // ── ROD-68: episode-list cache with status-aware TTL ──────────────────────

    /// TTL in seconds for a cached episode list, keyed off airing status:
    /// finished shows almost never change (7d), ongoing ones gain an episode a
    /// week (6h keeps "new ep?" snappy), unknown splits the difference (24h).
    pub fn cacheTtl(airing_status: ?[]const u8) i64 {
        // eqIgnoreCase folds case on both sides, so only distinct *words* are
        // worth listing (AllAnime "RELEASING" vs an AniList-ish "ongoing").
        const s = airing_status orelse return 24 * 60 * 60;
        if (eqIgnoreCase(s, "FINISHED")) return 7 * 24 * 60 * 60;
        if (eqIgnoreCase(s, "RELEASING") or eqIgnoreCase(s, "ongoing")) return 6 * 60 * 60;
        return 24 * 60 * 60;
    }

    // ── ROD-182: enrichment-content TTL (status/score/description drift) ────────

    /// The current version of the *persisted enrichment field set* — the columns an
    /// enrich pull fills (`anilist.GQL_FIELDS` → `upsertAnime`). BUMP THIS whenever a
    /// migration adds enrichment columns that a fresh enrich would populate (ROD-261:
    /// studios/source/duration → 2). A row stamped below this reads stale in
    /// `enrichmentStale` no matter its clock, so widened columns heal on next view
    /// rather than waiting out the TTL. Not a schema knob — `SCHEMA_VERSION` gates
    /// migrations; this gates enrichment freshness, and the two move independently.
    pub const ENRICHMENT_FIELDSET_VERSION: i64 = 5; // ROD-261: +studios/duration/source/rank, +airing/country

    /// TTL in seconds for cached *enrichment metadata* on the `anime` row, keyed
    /// off airing status. A deliberately longer curve than `cacheTtl` (which
    /// governs the episode LIST): a score, synopsis, or status flips far slower
    /// than a weekly episode drop, so we refresh conservatively — a finished show
    /// is all but frozen (30d), an airing one can flip RELEASING→FINISHED and gain
    /// votes (1d), an unknown/unmodelled status splits the difference (7d). The
    /// "never enriched" case is NOT modelled here — that's `fetched_at == null` in
    /// `enrichmentStale`, so a fetched-but-status-null row still gets 7d of grace
    /// instead of re-fetching on every single view.
    pub fn enrichmentTtl(airing_status: ?[]const u8) i64 {
        const s = airing_status orelse return 7 * 24 * 60 * 60;
        if (eqIgnoreCase(s, "FINISHED")) return 30 * 24 * 60 * 60;
        if (eqIgnoreCase(s, "RELEASING") or eqIgnoreCase(s, "ongoing")) return 24 * 60 * 60;
        return 7 * 24 * 60 * 60;
    }

    /// Whether a row's persisted enrichment is stale enough to refresh on view.
    /// Stale when ANY of:
    ///   * `fetched_at` is null — never enriched, or a row predating the v6 column;
    ///     also the backfill predicate for pre-ROD-181 rows with no `anilist_id`.
    ///   * `fieldset_version` predates `ENRICHMENT_FIELDSET_VERSION` — the row was
    ///     filled under a narrower column set, so widened columns are missing (null
    ///     version → treated as 0, i.e. older than any real field set).
    ///   * the clock has passed `fetched_at + enrichmentTtl(status)`.
    /// Pure — unit-tested without a DB.
    pub fn enrichmentStale(fetched_at: ?i64, fieldset_version: ?i64, airing_status: ?[]const u8, now: i64) bool {
        const t = fetched_at orelse return true;
        if ((fieldset_version orelse 0) < ENRICHMENT_FIELDSET_VERSION) return true;
        return now >= t + enrichmentTtl(airing_status);
    }

    pub fn putCachedEpisodes(
        self: *Store,
        source: []const u8,
        source_id: []const u8,
        tt: domain.Translation,
        episodes: []const domain.EpisodeNumber,
        airing_status: ?[]const u8,
        now: i64,
        scratch: Allocator,
    ) Error!void {
        // Join raw labels with '\n' — labels never contain newlines.
        var blob: std.ArrayList(u8) = .empty;
        for (episodes, 0..) |e, i| {
            if (i != 0) try blob.append(scratch, '\n');
            try blob.appendSlice(scratch, e.raw);
        }
        const sql =
            \\INSERT INTO episode_cache (source, source_id, translation, episodes_blob, fetched_at, expires_at)
            \\VALUES (?,?,?,?,?,?)
            \\ON CONFLICT(source, source_id, translation) DO UPDATE SET
            \\    episodes_blob = excluded.episodes_blob,
            \\    fetched_at    = excluded.fetched_at,
            \\    expires_at    = excluded.expires_at
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, source);
        try bindText(stmt, 2, source_id);
        try bindText(stmt, 3, tt.str());
        try bindText(stmt, 4, blob.items);
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 5, now));
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 6, now + cacheTtl(airing_status)));
        try self.stepDone(stmt);
    }

    /// Cached episode list if present AND unexpired, else null (caller refetches).
    /// Results are duped into `arena`.
    pub fn getCachedEpisodes(
        self: *Store,
        arena: Allocator,
        source: []const u8,
        source_id: []const u8,
        tt: domain.Translation,
        now: i64,
    ) Error!?[]domain.EpisodeNumber {
        const sql =
            \\SELECT episodes_blob, expires_at FROM episode_cache
            \\WHERE source = ? AND source_id = ? AND translation = ?
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, source);
        try bindText(stmt, 2, source_id);
        try bindText(stmt, 3, tt.str());
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        const expires_at = c.sqlite3_column_int64(stmt, 1);
        if (now >= expires_at) return null; // stale → treat as a miss

        const blob = (try dupeText(arena, stmt, 0)) orelse "";
        if (blob.len == 0) return &.{};

        var list: std.ArrayList(domain.EpisodeNumber) = .empty;
        var it = std.mem.splitScalar(u8, blob, '\n');
        while (it.next()) |label| {
            try list.append(arena, .{ .raw = label });
        }
        return try list.toOwnedSlice(arena);
    }

    // ── internals ────────────────────────────────────────────────────────────

    /// Switch the journal to WAL, retrying on SQLITE_BUSY. This can't ride on
    /// `busy_timeout` (ROD-287, caught in review): when two fresh connections race to
    /// promote the journal delete→WAL for the first time, the loser needs a brief
    /// exclusive lock the winner holds, and SQLite deliberately does NOT run the busy
    /// handler for that lock upgrade — running it could deadlock two mutually-waiting
    /// upgraders — so the pragma returns SQLITE_BUSY at once regardless of the timeout.
    /// We retry by hand: the winner finishes WAL setup in microseconds, after which the
    /// loser's retry sees the journal already in WAL and returns without needing the
    /// lock at all, so this converges in a round or two on any real filesystem. Bounded
    /// so a truly wedged peer surfaces as error.Exec (best-effort no-store) instead of
    /// hanging open() forever. Uses sqlite3_sleep — a portable VFS-backed backoff — so
    /// the store layer needn't thread an Io handle through just for this.
    fn enableWal(self: *Store) Error!void {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const rc = c.sqlite3_exec(self.db, "PRAGMA journal_mode = WAL;", null, null, null);
            if (rc == c.SQLITE_OK) return;
            // Match on the PRIMARY result code (low byte). If a future caller ever
            // enables extended result codes on this connection, BUSY/LOCKED would
            // arrive as SQLITE_BUSY_* / SQLITE_LOCKED_* and stop matching the bare
            // constants — silently turning a normal contention wobble into a first-try
            // error.Exec. Masking keeps the retry robust to that (ROD-287 re-review).
            const primary = rc & 0xff;
            if ((primary == c.SQLITE_BUSY or primary == c.SQLITE_LOCKED) and attempt < WAL_RETRY_LIMIT) {
                _ = c.sqlite3_sleep(WAL_RETRY_BACKOFF_MS);
                continue;
            }
            std.log.err("store: enable WAL failed (rc={d}): {s}", .{ rc, c.sqlite3_errmsg(self.db) });
            return error.Exec;
        }
    }

    fn migrate(self: *Store) Error!void {
        // Fast path: read the version WITHOUT a write lock (reads never block under
        // WAL). The common case — an already-current DB — writes nothing, so routine
        // opens (every launch, every `zigoku sync`) never contend for the write lock.
        var v = try self.userVersion();
        // A DB written by a newer Zigoku knows a schema we don't. Refuse it as a
        // real error (the best-effort caller falls back to no persistence) rather
        // than asserting our way into a panic — and before taking any write lock.
        if (v > SCHEMA_VERSION) return error.SchemaTooNew;
        if (v == SCHEMA_VERSION) return; // nothing to migrate

        // A migration is needed. Run the whole check-and-apply under ONE write
        // transaction (ROD-287). BEGIN IMMEDIATE takes the write lock up front, and
        // busy_timeout (set in open) makes a second opener racing the same schema
        // window wait for us rather than erroring with 'duplicate column name'.
        // Atomicity is the real prize: the ALTERs and the version bump commit
        // together or roll back together, so an interrupted migrate can never leave
        // the half-applied state (columns added, user_version un-bumped) that used to
        // brick every future open. (This prevents NEW half-applied states; it does
        // not heal one an older build already wrote — that needs idempotent ALTERs.)
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};

        // Re-read under the lock: whoever we just waited out may have already migrated.
        v = try self.userVersion();
        if (v > SCHEMA_VERSION) return error.SchemaTooNew; // errdefer rolls back
        if (v == SCHEMA_VERSION) {
            try self.exec("COMMIT;"); // someone else finished the ladder; nothing to do
            return;
        }

        if (v < 1) {
            try self.exec(MIGRATION_V1);
            v = 1;
        }
        if (v < 2) {
            try self.exec(MIGRATION_V2);
            v = 2;
        }
        if (v < 3) {
            try self.exec(MIGRATION_V3);
            v = 3;
        }
        if (v < 4) {
            try self.exec(MIGRATION_V4);
            v = 4;
        }
        if (v < 5) {
            try self.exec(MIGRATION_V5);
            v = 5;
        }
        if (v < 6) {
            try self.exec(MIGRATION_V6);
            v = 6;
        }
        if (v < 7) {
            try self.exec(MIGRATION_V7);
            v = 7;
        }
        if (v < 8) {
            try self.exec(MIGRATION_V8);
            v = 8;
        }
        if (v < 9) {
            try self.exec(MIGRATION_V9);
            v = 9;
        }
        if (v < 10) {
            try self.exec(MIGRATION_V10);
            v = 10;
        }
        if (v < 11) {
            try self.exec(MIGRATION_V11);
            v = 11;
        }
        // Invariant: the ladder must have reached the target. Under the old code a
        // forgotten `if (v < N)` branch (a dev bumps SCHEMA_VERSION but skips the step)
        // left the DB stuck at the old version — annoying but honest. Here the final
        // bump below is unconditional, so the same slip would stamp a half-applied
        // schema as current under ReleaseFast, where `std.debug.assert` compiles out —
        // the exact bug this ticket closes. So we check for real, in every build mode,
        // and unwind through the errdefer instead of trusting a strippable assert.
        if (v != SCHEMA_VERSION) return error.Exec;

        // One bump at the end: the whole ladder commits atomically below, so per-step
        // bumps would be redundant. Derived from SCHEMA_VERSION so it can't drift.
        try self.exec(std.fmt.comptimePrint("PRAGMA user_version = {d};", .{SCHEMA_VERSION}));
        try self.exec("COMMIT;");
    }

    fn userVersion(self: *Store) Error!c_int {
        const stmt = try self.prepare("PRAGMA user_version;");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.Step;
        return c.sqlite3_column_int(stmt, 0);
    }

    fn exec(self: *Store, sql: [*c]const u8) Error!void {
        var errmsg: [*c]u8 = null;
        if (c.sqlite3_exec(self.db, sql, null, null, &errmsg) != c.SQLITE_OK) {
            std.log.err("store: exec failed: {s}", .{errmsg});
            c.sqlite3_free(errmsg);
            return error.Exec;
        }
    }

    fn prepare(self: *Store, sql: [*c]const u8) Error!Stmt {
        var stmt: Stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            std.log.err("store: prepare failed: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.Prepare;
        }
        return stmt;
    }

    fn stepDone(self: *Store, stmt: Stmt) Error!void {
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            std.log.err("store: step failed: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.Step;
        }
    }
};

// ── Default DB location ───────────────────────────────────────────────────────

/// `{dataDir}/zigoku.db` (see `paths.dataDir`). Creates the directory
/// (best-effort) and returns a null-terminated path. The error set is inferred so
/// `paths.Error` (incl. `Unsupported` on Windows) propagates to the caller.
pub fn defaultDbPath(arena: Allocator) ![:0]const u8 {
    const dir = try paths.dataDir(arena);
    paths.ensureDir(dir);
    return std.fmt.allocPrintSentinel(arena, "{s}/zigoku.db", .{dir}, 0);
}

// ── C-API binding/reading helpers ─────────────────────────────────────────────

// SQLite's text/blob destructor sentinels. `@cImport` can't surface these —
// they're function-pointer macro casts (`(sqlite3_destructor_type)0` and `-1`),
// not enum values — so we name them locally. SQLITE_STATIC tells SQLite the
// buffer outlives the step, so it binds by reference without copying;
// SQLITE_TRANSIENT makes SQLite copy the bytes for callers whose slice does not.
const SQLITE_STATIC: c.sqlite3_destructor_type = null;
const SQLITE_TRANSIENT: c.sqlite3_destructor_type = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

// Map a `sqlite3_bind_*` return code to the module error set. Side-effect-free
// (no logging) so the failure path is unit-testable without tripping the test
// runner's logged-error guard; `checkBind` wraps it with the diagnostic log.
fn bindCode(code: c_int) Error!void {
    if (code != c.SQLITE_OK) return error.Bind;
}

// Check a `sqlite3_bind_*` return code, mirroring `prepare`/`stepDone`: a non-OK
// code is logged and surfaced as `error.Bind` rather than discarded. A swallowed
// failure would let the statement execute with a NULL where a value was expected —
// silent data corruption. Reachable via SQLITE_RANGE (a column index drifting past
// a schema change) and SQLITE_NOMEM/SQLITE_TOOBIG on pathological inputs.
//
// The bind helpers hold only a `Stmt`, not the `*Store`, so we recover the owning
// connection with `sqlite3_db_handle(stmt)` to read its error message.
fn checkBind(stmt: Stmt, code: c_int) Error!void {
    bindCode(code) catch |e| {
        std.log.err("store: bind failed: {s}", .{c.sqlite3_errmsg(c.sqlite3_db_handle(stmt))});
        return e;
    };
}

fn bindText(stmt: Stmt, idx: c_int, s: []const u8) Error!void {
    // SQLITE_STATIC: caller guarantees `s` outlives the step (always true here —
    // bind args live in the calling method's frame across its single step).
    return checkBind(stmt, c.sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), SQLITE_STATIC));
}
fn bindOptText(stmt: Stmt, idx: c_int, s: ?[]const u8) Error!void {
    if (s) |x| return bindText(stmt, idx, x);
    return checkBind(stmt, c.sqlite3_bind_null(stmt, idx));
}
fn bindOptI64(stmt: Stmt, idx: c_int, v: ?i64) Error!void {
    if (v) |x| return checkBind(stmt, c.sqlite3_bind_int64(stmt, idx, x));
    return checkBind(stmt, c.sqlite3_bind_null(stmt, idx));
}
fn bindOptF64(stmt: Stmt, idx: c_int, v: ?f64) Error!void {
    if (v) |x| return checkBind(stmt, c.sqlite3_bind_double(stmt, idx, x));
    return checkBind(stmt, c.sqlite3_bind_null(stmt, idx));
}

fn dupeText(arena: Allocator, stmt: Stmt, idx: c_int) Error!?[]const u8 {
    const ptr = c.sqlite3_column_text(stmt, idx);
    if (ptr == null) return null;
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, idx));
    return try arena.dupe(u8, ptr[0..n]);
}
/// Read a `list_status` column straight into the enum — no arena alloc, since the
/// status is a fixed vocabulary, not free text. NULL/unknown → `planning` (matches
/// the column default and `ListStatus.fromString`).
fn colStatus(stmt: Stmt, idx: c_int) domain.ListStatus {
    const ptr = c.sqlite3_column_text(stmt, idx);
    if (ptr == null) return .planning;
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, idx));
    return domain.ListStatus.fromString(ptr[0..n]);
}
fn colOptI64(stmt: Stmt, idx: c_int) ?i64 {
    if (c.sqlite3_column_type(stmt, idx) == c.SQLITE_NULL) return null;
    return c.sqlite3_column_int64(stmt, idx);
}
/// Like `colStatus`, but preserves the NULL-vs-set distinction: a NULL column
/// returns null (never synced), not `.planning`. The ROD-285 reconcile needs this —
/// a NULL snapshot means "no 3-way-merge ancestor", which is a different case from a
/// snapshot of `planning`.
fn colOptStatus(stmt: Stmt, idx: c_int) ?domain.ListStatus {
    if (c.sqlite3_column_type(stmt, idx) == c.SQLITE_NULL) return null;
    return colStatus(stmt, idx);
}
fn colOptF64(stmt: Stmt, idx: c_int) ?f64 {
    if (c.sqlite3_column_type(stmt, idx) == c.SQLITE_NULL) return null;
    return c.sqlite3_column_double(stmt, idx);
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// A string list persists as a single '\n'-joined blob (display-only — never
// queried by element, so a column beats a side table). Genre and studio names
// never contain newlines, the same guarantee episode labels lean on in
// episode_cache. Shared by both `genres` and `studios` (ROD-261).
fn joinStrBlob(scratch: Allocator, items: []const []const u8) Error![]const u8 {
    var blob: std.ArrayList(u8) = .empty;
    for (items, 0..) |g, i| {
        if (i != 0) try blob.append(scratch, '\n');
        try blob.appendSlice(scratch, g);
    }
    return blob.items;
}

/// Split a stored '\n'-blob column back into an arena-owned list. A NULL/empty
/// column is an empty list, never a one-element list of "".
fn dupeStrBlob(arena: Allocator, stmt: Stmt, idx: c_int) Error![]const []const u8 {
    const blob = (try dupeText(arena, stmt, idx)) orelse return &.{};
    if (blob.len == 0) return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |g| try list.append(arena, g);
    return list.toOwnedSlice(arena);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const T_SOURCE = "allanime";

test "open + migrate sets user_version" {
    var s = try Store.openMemory();
    defer s.close();
    try testing.expectEqual(SCHEMA_VERSION, try s.userVersion());
}

/// Absolute, null-terminated path to a file inside a fresh test tmp dir. `:memory:`
/// can't be shared between connections, so the concurrent-opener tests below need a
/// real file. The caller owns `tmp_dir` — it must outlive the returned path.
fn tmpDbPath(arena: Allocator, tmp_dir: *std.testing.TmpDir, name: []const u8) ![:0]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
    const cwd_str = std.mem.sliceTo(&cwd_buf, 0);
    return std.fmt.allocPrintSentinel(arena, "{s}/.zig-cache/tmp/{s}/{s}", .{ cwd_str, tmp_dir.sub_path, name }, 0);
}

test "concurrent open migrates atomically — no double-apply, no half-applied schema (ROD-287)" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const db_path = try tmpDbPath(arena, &tmp_dir, "concurrent.db");

    // Two independent connections open the same fresh (v0) file at once, both racing
    // the full 0→N ladder. The BEGIN IMMEDIATE txn + busy_timeout must serialize them:
    // exactly one applies the ALTERs, the other waits, re-reads the bumped version,
    // and skips every step. Neither errors, and the schema lands consistent. Under the
    // old two-exec migrate this raced to 'duplicate column name' or a half-applied brick.
    const Worker = struct {
        fn run(path: [:0]const u8, err_slot: *?anyerror) void {
            var s = Store.open(path) catch |e| {
                err_slot.* = e;
                return;
            };
            s.close();
        }
    };

    var err_a: ?anyerror = null;
    var err_b: ?anyerror = null;
    const t_a = try std.Thread.spawn(.{}, Worker.run, .{ db_path, &err_a });
    const t_b = try std.Thread.spawn(.{}, Worker.run, .{ db_path, &err_b });
    t_a.join();
    t_b.join();

    try testing.expectEqual(@as(?anyerror, null), err_a);
    try testing.expectEqual(@as(?anyerror, null), err_b);

    // A fresh open sees a fully-migrated, consistent schema after the race.
    var s = try Store.open(db_path);
    defer s.close();
    try testing.expectEqual(SCHEMA_VERSION, try s.userVersion());
}

test "open() wires the busy_timeout on the connection (ROD-287)" {
    // Directly assert `open()` configured a non-zero busy_timeout — the half of the fix
    // that lets a second writer wait out a briefly-held lock instead of erroring at
    // once (the markSynced-vs-checkpoint collision). The query form of
    // `PRAGMA busy_timeout` reads back exactly what `sqlite3_busy_timeout` set, so this
    // fails deterministically if the wiring in `open()` is ever dropped. A prior draft
    // drove a real contention timeout instead, but that passes on SQLite's own busy
    // mechanics even with our wiring removed (caught in review) — and it was timing-
    // dependent. Asserting against the const, not a literal, keeps it valid on a retune.
    var s = try Store.openMemory();
    defer s.close();
    const stmt = try s.prepare("PRAGMA busy_timeout;");
    defer _ = c.sqlite3_finalize(stmt);
    try testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try testing.expectEqual(BUSY_TIMEOUT_MS, c.sqlite3_column_int(stmt, 0));
}

test "bind error surfaces instead of writing a silent NULL" {
    var s = try Store.openMemory();
    defer s.close();

    // A single-parameter statement: valid bind indices are 1..1, so binding column
    // 2 is out of range and SQLite returns SQLITE_RANGE. Pre-ROD-217 that code was
    // discarded and the statement would have executed with a NULL where a value was
    // expected. We drive the real failing bind, then map its actual return code
    // through the side-effect-free `bindCode` (checkBind's core) to assert it
    // surfaces as error.Bind — without emitting the diagnostic .err log the test
    // runner counts as a failure.
    const stmt = try s.prepare("SELECT ?1");
    defer _ = c.sqlite3_finalize(stmt);

    const range_code = c.sqlite3_bind_text(stmt, 2, "x", 1, SQLITE_STATIC);
    try testing.expect(range_code != c.SQLITE_OK);
    try testing.expectError(error.Bind, bindCode(range_code));

    // The happy-path bind on the valid index maps to success.
    const ok_code = c.sqlite3_bind_text(stmt, 1, "ok", 2, SQLITE_STATIC);
    try testing.expectEqual(c.SQLITE_OK, ok_code);
    try bindCode(ok_code);
}

test "upsertAnime + loadHistory round-trips" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    const a = AnimeRecord.fromDomain(T_SOURCE, .{ .id = "abc", .name = "Frieren", .eps_sub = 28 }, .sub);
    try s.upsertAnime(a, 1000, arena);

    const rows = try s.loadHistory(arena);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("abc", rows[0].source_id);
    try testing.expectEqualStrings("Frieren", rows[0].title);
    try testing.expectEqual(@as(?i64, 28), rows[0].total_episodes);
    try testing.expectEqual(domain.ListStatus.planning, rows[0].list_status);
    try testing.expectEqual(@as(i64, 0), rows[0].play_count);
    try testing.expect(rows[0].history_visible);
}

test "loadDirtyForSync: only engaged, id-bearing rows; markSynced clears them (ROD-284)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    // Engaged + carries an AniList id → the one row the push should pick up.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "has-id", .title = "Frieren", .anilist_id = 100, .list_status = .watching, .progress = 3, .history_visible = true }, 1000, arena);
    // Engaged but no AniList id → nothing to push to; excluded.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "no-id", .title = "No Id", .list_status = .watching, .progress = 5, .history_visible = true }, 1001, arena);
    // Carries an id but is a merely-browsed search-cache row (not engaged) → excluded.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "hidden", .title = "Browsed", .anilist_id = 200, .history_visible = false }, 1002, arena);

    {
        const dirty = try s.loadDirtyForSync(arena);
        try testing.expectEqual(@as(usize, 1), dirty.len);
        try testing.expectEqualStrings("has-id", dirty[0].source_id);
        try testing.expectEqual(@as(i64, 100), dirty[0].anilist_id);
        try testing.expectEqual(domain.ListStatus.watching, dirty[0].list_status);
        try testing.expectEqual(@as(i64, 3), dirty[0].progress);
    }

    // Stamp the snapshot at exactly what we read → the row reads clean next time.
    try s.markSynced(T_SOURCE, "has-id", .watching, 3);
    try testing.expectEqual(@as(usize, 0), (try s.loadDirtyForSync(arena)).len);
}

test "loadDirtyForSync re-flags a row after a status or progress change (ROD-284)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "a", .title = "A", .anilist_id = 42, .total_episodes = 12, .list_status = .watching, .progress = 4, .history_visible = true }, 1000, arena);
    try s.markSynced(T_SOURCE, "a", .watching, 4);
    try testing.expectEqual(@as(usize, 0), (try s.loadDirtyForSync(arena)).len); // clean baseline

    // A manual status change with progress unchanged must re-flag the row — the
    // exact case a `last_watched_at` clock would miss, since no play occurred.
    try s.setListStatus(T_SOURCE, "a", .paused);
    {
        const dirty = try s.loadDirtyForSync(arena);
        try testing.expectEqual(@as(usize, 1), dirty.len);
        try testing.expectEqual(domain.ListStatus.paused, dirty[0].list_status);
    }
    try s.markSynced(T_SOURCE, "a", .paused, 4);
    try testing.expectEqual(@as(usize, 0), (try s.loadDirtyForSync(arena)).len);

    // A progress change (via a play) must re-flag it too.
    try s.recordPlay(T_SOURCE, "a", 5, 2000, true);
    {
        const dirty = try s.loadDirtyForSync(arena);
        try testing.expectEqual(@as(usize, 1), dirty.len);
        try testing.expectEqual(@as(i64, 5), dirty[0].progress);
    }
}

test "loadReconcileRows: engaged id-bearing rows only, snapshot NULL until synced (ROD-285)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    // Engaged + id → a reconcile candidate, even though it is (as yet) clean.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "has-id", .title = "Frieren", .anilist_id = 100, .list_status = .watching, .progress = 3, .history_visible = true }, 1000, arena);
    // Engaged, no id → nothing to join a remote entry to; excluded.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "no-id", .title = "No Id", .list_status = .watching, .progress = 5, .history_visible = true }, 1001, arena);
    // Has an id but merely browsed (not engaged) → excluded (v1 doesn't import onto browsed rows).
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "hidden", .title = "Browsed", .anilist_id = 200, .history_visible = false }, 1002, arena);

    const rows = try s.loadReconcileRows(arena);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("has-id", rows[0].source_id);
    try testing.expectEqual(@as(i64, 100), rows[0].anilist_id);
    try testing.expectEqual(domain.ListStatus.watching, rows[0].list_status);
    try testing.expectEqual(@as(i64, 3), rows[0].progress);
    // Never synced → NULL snapshot (a first-contact merge has no ancestor), NOT planning.
    try testing.expect(rows[0].synced_status == null);
    try testing.expect(rows[0].synced_progress == null);

    // Once synced, the snapshot reads back as the stamped pair.
    try s.markSynced(T_SOURCE, "has-id", .watching, 3);
    const synced = try s.loadReconcileRows(arena);
    try testing.expectEqual(domain.ListStatus.watching, synced[0].synced_status.?);
    try testing.expectEqual(@as(i64, 3), synced[0].synced_progress.?);
}

test "loadEngagedWithoutAniListId: names the engaged, unlinked shows, agreeing with the count (ROD-285)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    // Engaged + linked → excluded (it can sync). Engaged + no id → listed. Browsed-only
    // (hidden) + no id → excluded (not part of the push set).
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "linked", .title = "Linked", .anilist_id = 100, .list_status = .watching, .progress = 1, .history_visible = true }, 1000, arena);
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "unlinked", .title = "Unlinked Show", .list_status = .watching, .progress = 1, .history_visible = true }, 1001, arena);
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "browsed", .title = "Browsed", .history_visible = false }, 1002, arena);

    const names = try s.loadEngagedWithoutAniListId(arena);
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("Unlinked Show", names[0]);
    // The list and the count must agree (same predicate).
    try testing.expectEqual(@as(i64, 1), try s.countEngagedWithoutAniListId());
}

test "applyPulled: writes merged local pair + a server-truth snapshot; leaves a local-ahead row dirty (ROD-285)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "a", .title = "A", .anilist_id = 42, .list_status = .watching, .progress = 3, .history_visible = true }, 1000, arena);

    // Reconcile kept a locally-ahead value (completed@12) while AniList still holds
    // (watching, 8): local pair = merged, snapshot = remote (server truth). The row
    // still holds the (watching, 3) it was seeded with → the guard matches, so it lands.
    try testing.expect(try s.applyPulled(T_SOURCE, "a", .completed, 12, .watching, 8, .watching, 3));

    // The merged local pair landed.
    const rec = (try s.getAnime(arena, T_SOURCE, "a")).?;
    try testing.expectEqual(domain.ListStatus.completed, rec.list_status);
    try testing.expectEqual(@as(i64, 12), rec.progress);

    // The snapshot is the remote pair, not the merged one — so the row reads DIRTY
    // (local completed@12 ≠ snapshot watching@8) and the next push carries it up.
    const dirty = try s.loadDirtyForSync(arena);
    try testing.expectEqual(@as(usize, 1), dirty.len);
    try testing.expectEqual(domain.ListStatus.completed, dirty[0].list_status);
    try testing.expectEqual(@as(i64, 12), dirty[0].progress);

    // A clean pull-in (merged == remote) instead leaves the row clean. The row now
    // holds (completed, 12), so that's the expected guard pair.
    try testing.expect(try s.applyPulled(T_SOURCE, "a", .completed, 12, .completed, 12, .completed, 12));
    try testing.expectEqual(@as(usize, 0), (try s.loadDirtyForSync(arena)).len);
}

test "applyPulled: the optimistic guard skips a row that changed underneath (ROD-285)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "a", .title = "A", .anilist_id = 42, .list_status = .watching, .progress = 5, .history_visible = true }, 1000, arena);

    // Reconcile read the row as watching@5. Then a concurrent play (the TUI) advances
    // it to 7 before this write lands — the exact read-then-write race.
    try s.recordPlay(T_SOURCE, "a", 7, 2000, true);
    try testing.expectEqual(@as(i64, 7), (try s.getAnime(arena, T_SOURCE, "a")).?.progress);

    // applyPulled still carries the STALE expected pair (watching@5) from the bulk read.
    // The guard matches zero rows → false, and the concurrent value (7) is left intact
    // (no lost update); the row simply re-reconciles next run.
    const applied = try s.applyPulled(T_SOURCE, "a", .completed, 12, .watching, 5, .watching, 5);
    try testing.expect(!applied);
    try testing.expectEqual(@as(i64, 7), (try s.getAnime(arena, T_SOURCE, "a")).?.progress);
}

test "upsertAnime cover_url: an absolute cover survives a later relative re-search (ROD-267)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    // 1) First search seeds a bare, relative `mcovers/…` cover.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "Solo Leveling", .cover_url = "mcovers/a/b.webp" }, 1000, arena);
    // 2) Enrichment upserts the absolute AniList cover — an absolute url wins.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "Solo Leveling", .cover_url = "https://s4.anilist.co/x/bx1.jpg" }, 1001, arena);
    try testing.expectEqualStrings(
        "https://s4.anilist.co/x/bx1.jpg",
        (try s.getAnime(arena, T_SOURCE, "x")).?.cover_url.?,
    );
    // 3) A later re-search brings the relative cover again — it must NOT clobber the
    //    stored absolute one, so History (which never re-enriches) keeps the good cover.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "Solo Leveling", .cover_url = "mcovers/a/b.webp" }, 1002, arena);
    try testing.expectEqualStrings(
        "https://s4.anilist.co/x/bx1.jpg",
        (try s.getAnime(arena, T_SOURCE, "x")).?.cover_url.?,
    );
}

test "loadHistory excludes hidden metadata-cache rows" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "hidden", .title = "Hidden", .history_visible = false }, 1000, arena);
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "shown", .title = "Shown", .history_visible = true }, 1001, arena);

    const rows = try s.loadHistory(arena);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("shown", rows[0].source_id);
}

test "migration v4 hides polluted search-cache rows while preserving real history" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "search-only", .title = "Search Only", .history_visible = true }, 1000, arena);
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "played", .title = "Played", .history_visible = true, .play_count = 1, .progress = 3, .last_watched_at = 2000 }, 1001, arena);
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "rated", .title = "Rated", .history_visible = true, .user_rating = 8.5 }, 1002, arena);

    try s.exec(MIGRATION_V4);

    const rows = try s.loadHistory(arena);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expect(std.mem.eql(u8, rows[0].source_id, "played") or std.mem.eql(u8, rows[1].source_id, "played"));
    try testing.expect(std.mem.eql(u8, rows[0].source_id, "rated") or std.mem.eql(u8, rows[1].source_id, "rated"));
}

test "recordPlay promotes hidden row into history" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X", .history_visible = false }, 1000, arena);
    try s.recordPlay(T_SOURCE, "x", 2, 2000, true);

    const rows = try s.loadHistory(arena);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(i64, 1), rows[0].play_count);
    try testing.expectEqual(@as(i64, 2), rows[0].progress);
}

test "getAnime returns persisted enrichment" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    try s.upsertAnime(.{
        .source = T_SOURCE,
        .source_id = "frieren",
        .title = "Frieren",
        .title_english = "Frieren: Beyond Journey's End",
        .anilist_id = 154587,
        .mal_id = 52991,
        .cover_url = "https://img.anili.st/frieren.jpg",
        .year = 2023,
        .status = "FINISHED",
        .description = "Elf mage grief hour",
        .score = 91,
        .total_episodes = 28,
    }, 1000, arena);

    const rec = (try s.getAnime(arena, T_SOURCE, "frieren")) orelse return error.TestExpectationFailed;
    try testing.expectEqual(@as(?i64, 154587), rec.anilist_id);
    try testing.expectEqual(@as(?i64, 52991), rec.mal_id);
    try testing.expectEqual(@as(?i64, 2023), rec.year);
    try testing.expectEqual(@as(?i64, 91), rec.score);
    try testing.expectEqualStrings("FINISHED", rec.status orelse "");
    try testing.expectEqualStrings("Elf mage grief hour", rec.description orelse "");
}

test "enrichment fields (season/native/kind/start_date/genres/studios/duration/source/rank/airing/country) round-trip" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    // Persist via the real domain→record path so the @tagName / Date / genres /
    // studios mapping in fromDomain is exercised, not hand-rolled record literals.
    const genres = [_][]const u8{ "Action", "Adventure", "Fantasy" };
    const studios = [_][]const u8{"Madhouse"};
    const rec = AnimeRecord.fromDomain(T_SOURCE, .{
        .id = "frieren",
        .name = "Sousou no Frieren",
        .native_name = "葬送のフリーレン",
        .season = .fall,
        .start_date = .{ .year = 2023, .month = 9, .day = 29 },
        .kind = "TV",
        .genres = &genres,
        .studios = &studios,
        .duration = 24,
        .source_material = "MANGA",
        .rank = 3,
        .rank_type = "RATED",
        .rank_year = 2016,
        .next_airing_at = 1_700_000_000,
        .next_airing_episode = 15,
        .country = "JP",
    }, .sub);
    try s.upsertAnime(rec, 1000, arena);

    // getAnime path
    const got = (try s.getAnime(arena, T_SOURCE, "frieren")) orelse return error.TestExpectationFailed;
    try testing.expectEqualStrings("fall", got.season orelse "");
    try testing.expectEqualStrings("葬送のフリーレン", got.native_name orelse "");
    try testing.expectEqualStrings("TV", got.kind orelse "");
    try testing.expectEqual(@as(?i64, 2023), got.start_year);
    try testing.expectEqual(@as(?i64, 9), got.start_month);
    try testing.expectEqual(@as(?i64, 29), got.start_day);
    try testing.expectEqual(@as(usize, 3), got.genres.len);
    try testing.expectEqualStrings("Action", got.genres[0]);
    try testing.expectEqualStrings("Fantasy", got.genres[2]);
    try testing.expectEqual(@as(usize, 1), got.studios.len);
    try testing.expectEqualStrings("Madhouse", got.studios[0]);
    try testing.expectEqual(@as(?i64, 24), got.duration);
    try testing.expectEqualStrings("MANGA", got.source_material orelse "");
    try testing.expectEqual(@as(?i64, 3), got.rank);
    try testing.expectEqualStrings("RATED", got.rank_type orelse "");
    try testing.expectEqual(@as(?i64, 2016), got.rank_year);
    try testing.expectEqual(@as(?i64, 1_700_000_000), got.next_airing_at);
    try testing.expectEqual(@as(?i64, 15), got.next_airing_episode);
    try testing.expectEqualStrings("JP", got.country orelse "");

    // loadHistory path sees the same blob split back into a list.
    const rows = try s.loadHistory(arena);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("fall", rows[0].season orelse "");
    try testing.expectEqual(@as(usize, 3), rows[0].genres.len);
    try testing.expectEqualStrings("Adventure", rows[0].genres[1]);
    try testing.expectEqual(@as(usize, 1), rows[0].studios.len);
    try testing.expectEqualStrings("Madhouse", rows[0].studios[0]);
    try testing.expectEqual(@as(?i64, 24), rows[0].duration);
    try testing.expectEqualStrings("MANGA", rows[0].source_material orelse "");
    try testing.expectEqual(@as(?i64, 3), rows[0].rank);
    try testing.expectEqualStrings("RATED", rows[0].rank_type orelse "");
    try testing.expectEqual(@as(?i64, 2016), rows[0].rank_year);
    try testing.expectEqual(@as(?i64, 1_700_000_000), rows[0].next_airing_at);
    try testing.expectEqual(@as(?i64, 15), rows[0].next_airing_episode);
    try testing.expectEqualStrings("JP", rows[0].country orelse "");
}

test "a later search without genres/studios preserves the persisted lists" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    const genres = [_][]const u8{ "Action", "Fantasy" };
    const studios = [_][]const u8{ "Madhouse", "Bones" };
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X", .genres = &genres, .studios = &studios }, 1000, arena);
    // A plain re-search carries neither genres nor studios (empty list → NULL bind
    // → COALESCE keeps the stored blob, same rule the scalar enrichment fields lean
    // on). Studios must survive it exactly as genres does (ROD-261).
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X" }, 2000, arena);

    const got = (try s.getAnime(arena, T_SOURCE, "x")) orelse return error.TestExpectationFailed;
    try testing.expectEqual(@as(usize, 2), got.genres.len);
    try testing.expectEqualStrings("Action", got.genres[0]);
    try testing.expectEqual(@as(usize, 2), got.studios.len);
    try testing.expectEqualStrings("Madhouse", got.studios[0]);
    try testing.expectEqualStrings("Bones", got.studios[1]);
}

test "empty genres reads back as an empty list, never [\"\"]" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X" }, 1000, arena);
    const got = (try s.getAnime(arena, T_SOURCE, "x")) orelse return error.TestExpectationFailed;
    try testing.expectEqual(@as(usize, 0), got.genres.len);
}

test "upsertAnime preserves user state on re-search" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "Old Title" }, 1000, arena);
    try s.recordPlay(T_SOURCE, "x", 3, 2000, true); // play_count=1, progress=3

    // A later search refreshes the title but must NOT reset play_count/progress.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "New Title", .total_episodes = 12 }, 3000, arena);

    const rows = try s.loadHistory(arena);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("New Title", rows[0].title);
    try testing.expectEqual(@as(?i64, 12), rows[0].total_episodes);
    try testing.expectEqual(@as(i64, 1), rows[0].play_count); // preserved
    try testing.expectEqual(@as(i64, 3), rows[0].progress); // preserved
}

test "saveProgress + getResume; watched threshold" {
    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X" }, 1000, testing.allocator);

    // 94% → not watched.
    try s.saveProgress(T_SOURCE, "x", .sub, "1", 940, 1000, 1001);
    const r1 = (try s.getResume(T_SOURCE, "x", .sub, "1")).?;
    try testing.expectApproxEqAbs(@as(f64, 940), r1.position_secs, 0.001);
    try testing.expect(!r1.fully_watched);

    // 95% → watched; upsert overwrites the same row.
    try s.saveProgress(T_SOURCE, "x", .sub, "1", 950, 1000, 1002);
    const r2 = (try s.getResume(T_SOURCE, "x", .sub, "1")).?;
    try testing.expect(r2.fully_watched);

    // Never-started episode → null.
    try testing.expect((try s.getResume(T_SOURCE, "x", .sub, "2")) == null);
}

test "sub and dub resume independently" {
    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X" }, 1000, testing.allocator);

    try s.saveProgress(T_SOURCE, "x", .sub, "1", 100, 1400, 1001);
    try s.saveProgress(T_SOURCE, "x", .dub, "1", 700, 1400, 1002);

    try testing.expectApproxEqAbs(@as(f64, 100), (try s.getResume(T_SOURCE, "x", .sub, "1")).?.position_secs, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 700), (try s.getResume(T_SOURCE, "x", .dub, "1")).?.position_secs, 0.001);
}

test "Resume.startSeconds respects natural-end + watched" {
    const mid: Resume = .{ .position_secs = 300, .duration_secs = 1400, .fully_watched = false };
    try testing.expectEqual(@as(u64, 300), mid.startSeconds());

    const near_end: Resume = .{ .position_secs = 1200, .duration_secs = 1400, .fully_watched = false }; // ~86%
    try testing.expectEqual(@as(u64, 0), near_end.startSeconds());

    const done: Resume = .{ .position_secs = 500, .duration_secs = 1400, .fully_watched = true };
    try testing.expectEqual(@as(u64, 0), done.startSeconds());
}

test "Resume.startSecondsRewound rewinds for context, saturating at the top (ROD-84)" {
    const mid: Resume = .{ .position_secs = 300, .duration_secs = 1400, .fully_watched = false };
    try testing.expectEqual(@as(u64, 295), mid.startSecondsRewound(5)); // 300 - 5
    try testing.expectEqual(@as(u64, 270), mid.startSecondsRewound(30));
    try testing.expectEqual(@as(u64, 300), mid.startSecondsRewound(0)); // offset off → raw

    // Rewind past the start clamps to 0 (begin from the top), never underflows.
    const early: Resume = .{ .position_secs = 3, .duration_secs = 1400, .fully_watched = false };
    try testing.expectEqual(@as(u64, 0), early.startSecondsRewound(5));

    // Rewind exactly equal to position — the boundary, begins from top not underflow.
    const exact: Resume = .{ .position_secs = 5, .duration_secs = 1400, .fully_watched = false };
    try testing.expectEqual(@as(u64, 0), exact.startSecondsRewound(5));

    // Natural-end passthrough: startSeconds() suppresses to 0, so the rewind early-
    // outs and never resurrects a start inside the window the guard skips.
    const near_end: Resume = .{ .position_secs = 1200, .duration_secs = 1400, .fully_watched = false }; // ~86%
    try testing.expectEqual(@as(u64, 0), near_end.startSecondsRewound(5));

    // Fully-watched stays 0 — nothing to rewind into.
    const done: Resume = .{ .position_secs = 500, .duration_secs = 1400, .fully_watched = true };
    try testing.expectEqual(@as(u64, 0), done.startSecondsRewound(5));
}

test "recordPlay bumps count, progress, last_watched and reorders history" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "a", .title = "A" }, 1000, arena);
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "b", .title = "B" }, 1001, arena);

    // Play B → it should jump to the top of history.
    try s.recordPlay(T_SOURCE, "b", 5, 2000, true);
    try s.recordPlay(T_SOURCE, "b", 2, 2001, true); // progress is a high-water mark

    const rows = try s.loadHistory(arena);
    try testing.expectEqualStrings("b", rows[0].source_id);
    try testing.expectEqual(@as(i64, 2), rows[0].play_count);
    try testing.expectEqual(@as(i64, 5), rows[0].progress); // MAX, not last
    try testing.expectEqual(@as(?i64, 2001), rows[0].last_watched_at);
}

test "recordPlay with completed=false records the play but not the progress" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X" }, 1000, arena);

    // A short watch of episode 4: it's a real play (count/last_watched/visible)
    // but must NOT bump the progress high-water mark (ROD-168).
    try s.recordPlay(T_SOURCE, "x", 4, 2000, false);

    const rows = try s.loadHistory(arena);
    try testing.expectEqual(@as(usize, 1), rows.len); // promoted into history
    try testing.expectEqual(@as(i64, 1), rows[0].play_count); // play counted
    try testing.expectEqual(@as(?i64, 2000), rows[0].last_watched_at);
    try testing.expectEqual(@as(i64, 0), rows[0].progress); // NOT advanced
    // A play is a play: even a partial watch flips planning → watching (ROD-139).
    try testing.expectEqual(domain.ListStatus.watching, rows[0].list_status);

    // A subsequent completed watch of episode 4 does advance it.
    try s.recordPlay(T_SOURCE, "x", 4, 2100, true);
    const rows2 = try s.loadHistory(arena);
    try testing.expectEqual(@as(i64, 4), rows2[0].progress);
    try testing.expectEqual(@as(i64, 2), rows2[0].play_count);
}

test "recordPlay transitions planning → watching and commits to the store" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "a", .title = "A", .total_episodes = 12 }, 1000, arena);

    // Default state is planning; a play of ep 1 flips it to watching. The
    // getAnime below is a fresh SELECT against the (autocommitted) DB — it reads
    // committed state, not the in-memory record, so this is the persistence proof
    // (under SQLite autocommit a successful UPDATE is durable; a file reopen would
    // assert nothing more).
    try s.recordPlay(T_SOURCE, "a", 1, 2000, true);
    const rec = (try s.getAnime(arena, T_SOURCE, "a")).?;
    try testing.expectEqual(domain.ListStatus.watching, rec.list_status);
}

test "recordPlay auto-completes at the finale and stays completed on rewatch" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "a", .title = "A", .total_episodes = 3 }, 1000, arena);

    try s.recordPlay(T_SOURCE, "a", 2, 2000, true); // mid-run → watching
    try testing.expectEqual(domain.ListStatus.watching, (try s.getAnime(arena, T_SOURCE, "a")).?.list_status);

    try s.recordPlay(T_SOURCE, "a", 3, 2001, true); // hits finale → completed
    try testing.expectEqual(domain.ListStatus.completed, (try s.getAnime(arena, T_SOURCE, "a")).?.list_status);

    // A rewatch of ep 1 must NOT demote a finished show back to watching.
    try s.recordPlay(T_SOURCE, "a", 1, 2002, true);
    const rec = (try s.getAnime(arena, T_SOURCE, "a")).?;
    try testing.expectEqual(domain.ListStatus.completed, rec.list_status);
    try testing.expectEqual(@as(i64, 3), rec.progress); // high-water held
    try testing.expectEqual(@as(i64, 3), rec.play_count); // every play still counts
}

test "recordPlay with unknown total never auto-completes" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "a", .title = "A" }, 1000, arena); // total NULL

    try s.recordPlay(T_SOURCE, "a", 99, 2000, true);
    try testing.expectEqual(domain.ListStatus.watching, (try s.getAnime(arena, T_SOURCE, "a")).?.list_status);
}

test "setListStatus: manual pause/drop without bumping play stats" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "a", .title = "A", .total_episodes = 12 }, 1000, arena);
    try s.recordPlay(T_SOURCE, "a", 4, 2000, true); // watching, progress 4, play_count 1

    try s.setListStatus(T_SOURCE, "a", .paused);
    const paused = (try s.getAnime(arena, T_SOURCE, "a")).?;
    try testing.expectEqual(domain.ListStatus.paused, paused.list_status);
    try testing.expectEqual(@as(i64, 1), paused.play_count); // not a watch event
    try testing.expectEqual(@as(?i64, 2000), paused.last_watched_at); // untouched
    try testing.expectEqual(@as(i64, 4), paused.progress); // untouched

    try s.setListStatus(T_SOURCE, "a", .dropped);
    try testing.expectEqual(domain.ListStatus.dropped, (try s.getAnime(arena, T_SOURCE, "a")).?.list_status);
}

test "setListStatus: force-complete snaps progress to the known finale" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    // Known total: force-complete should fill progress to the finale.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "a", .title = "A", .total_episodes = 12 }, 1000, arena);
    try s.setListStatus(T_SOURCE, "a", .completed);
    const a = (try s.getAnime(arena, T_SOURCE, "a")).?;
    try testing.expectEqual(domain.ListStatus.completed, a.list_status);
    try testing.expectEqual(@as(i64, 12), a.progress);

    // Unknown total: complete is honored but progress can't be snapped — left as-is.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "b", .title = "B" }, 1001, arena);
    try s.recordPlay(T_SOURCE, "b", 3, 2000, true); // progress 3, total unknown
    try s.setListStatus(T_SOURCE, "b", .completed);
    const b = (try s.getAnime(arena, T_SOURCE, "b")).?;
    try testing.expectEqual(domain.ListStatus.completed, b.list_status);
    try testing.expectEqual(@as(i64, 3), b.progress); // unchanged, no total to snap to

    // total_episodes = 0 (AllAnime quirk) is NOT a real finale: force-complete
    // must NOT reset progress to zero (regression — the `t > 0` guard).
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "c", .title = "C", .total_episodes = 0 }, 1002, arena);
    try s.recordPlay(T_SOURCE, "c", 5, 2001, true); // progress 5, total 0
    try s.setListStatus(T_SOURCE, "c", .completed);
    const cc = (try s.getAnime(arena, T_SOURCE, "c")).?;
    try testing.expectEqual(domain.ListStatus.completed, cc.list_status);
    try testing.expectEqual(@as(i64, 5), cc.progress); // held, not zeroed
}

test "setListStatus on an unknown show is a silent no-op" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try s.setListStatus(T_SOURCE, "ghost", .completed); // must not error
    try testing.expect((try s.getAnime(arena, T_SOURCE, "ghost")) == null);
}

// ROD-189 reuses `upsertAnime` for the browse `P` (add-to-watchlist) path
// rather than a dedicated store method: its ON CONFLICT clause already preserves
// list_status/progress/play_count and MAX-merges history_visible, which is
// exactly the upsert-or-reveal-as-planning contract the ticket wants. These two
// tests lock the behaviors `P` depends on — if a future change to upsertAnime
// starts clobbering list_status on conflict, `P` breaks and these catch it.
test "ROD-189: P on an untracked show saves it as planning, not as watched" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    // The handler's exact call: fromDomain the highlighted result, upsert it.
    try s.upsertAnime(AnimeRecord.fromDomain(T_SOURCE, .{ .id = "abc", .name = "Frieren", .eps_sub = 28 }, .sub), 1000, arena);

    const rec = (try s.getAnime(arena, T_SOURCE, "abc")).?;
    try testing.expectEqual(domain.ListStatus.planning, rec.list_status);
    try testing.expect(rec.history_visible); // shows up in History
    // "save for later", not a watch: no progress, no play_count, no timestamp.
    try testing.expectEqual(@as(i64, 0), rec.progress);
    try testing.expectEqual(@as(i64, 0), rec.play_count);
    try testing.expectEqual(@as(?i64, null), rec.last_watched_at);
}

test "ROD-189: P reveals an existing row without clobbering its user state" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    // A hidden search-cache row (ROD-185) the user had already moved to paused
    // with real progress — the state `P` must not trample.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X", .list_status = .paused, .progress = 5, .history_visible = false }, 1000, arena);
    try testing.expectEqual(@as(usize, 0), (try s.loadHistory(arena)).len); // hidden

    // Pressing P re-upserts the browse result; fromDomain carries list_status
    // .planning + history_visible true, but the conflict path must keep the
    // user's paused/5 and only flip the row visible.
    try s.upsertAnime(AnimeRecord.fromDomain(T_SOURCE, .{ .id = "x", .name = "X" }, .sub), 2000, arena);

    const rec = (try s.getAnime(arena, T_SOURCE, "x")).?;
    try testing.expect(rec.history_visible); // revealed
    try testing.expectEqual(domain.ListStatus.paused, rec.list_status); // not demoted
    try testing.expectEqual(@as(i64, 5), rec.progress); // untouched
    try testing.expectEqual(@as(usize, 1), (try s.loadHistory(arena)).len); // now visible
}

test "ROD-189: P on an actively-watched show leaves all user state untouched" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    // A show the user is actively watching: visible, real progress + play_count.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X", .total_episodes = 12 }, 1000, arena);
    try s.recordPlay(T_SOURCE, "x", 7, 2000, true); // watching, progress 7, play_count 1

    // Re-adding it from browse (P) must be a pure no-op on user state — a silent
    // demote to planning here would be the single most destructive regression.
    try s.upsertAnime(AnimeRecord.fromDomain(T_SOURCE, .{ .id = "x", .name = "X" }, .sub), 3000, arena);

    const rec = (try s.getAnime(arena, T_SOURCE, "x")).?;
    try testing.expectEqual(domain.ListStatus.watching, rec.list_status); // not demoted
    try testing.expectEqual(@as(i64, 7), rec.progress); // not zeroed
    try testing.expectEqual(@as(i64, 1), rec.play_count); // not reset/bumped
    try testing.expectEqual(@as(?i64, 2000), rec.last_watched_at); // not touched
    try testing.expect(rec.history_visible);
}

test "recordPlay after a manual drop auto-resumes to watching (ROD-139)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "a", .title = "A", .total_episodes = 12 }, 1000, arena);
    try s.recordPlay(T_SOURCE, "a", 3, 2000, true); // watching
    try s.setListStatus(T_SOURCE, "a", .dropped);
    try testing.expectEqual(domain.ListStatus.dropped, (try s.getAnime(arena, T_SOURCE, "a")).?.list_status);

    // Pressing play on a dropped show means you're watching it again.
    try s.recordPlay(T_SOURCE, "a", 4, 2001, true);
    const rec = (try s.getAnime(arena, T_SOURCE, "a")).?;
    try testing.expectEqual(domain.ListStatus.watching, rec.list_status);
    try testing.expectEqual(@as(i64, 4), rec.progress); // high-water advanced
}

test "setListStatus resume (.watching) and re-plan (.planning) paths (ROD-139)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "a", .title = "A", .total_episodes = 12 }, 1000, arena);
    try s.recordPlay(T_SOURCE, "a", 6, 2000, true); // watching, progress 6
    try s.setListStatus(T_SOURCE, "a", .paused);

    // Resume: paused → watching, progress untouched (not a watch event).
    try s.setListStatus(T_SOURCE, "a", .watching);
    const resumed = (try s.getAnime(arena, T_SOURCE, "a")).?;
    try testing.expectEqual(domain.ListStatus.watching, resumed.list_status);
    try testing.expectEqual(@as(i64, 6), resumed.progress);
    try testing.expectEqual(@as(i64, 1), resumed.play_count); // manual move didn't bump

    // Re-plan: back to planning, progress still preserved (manual, not a reset).
    try s.setListStatus(T_SOURCE, "a", .planning);
    const replanned = (try s.getAnime(arena, T_SOURCE, "a")).?;
    try testing.expectEqual(domain.ListStatus.planning, replanned.list_status);
    try testing.expectEqual(@as(i64, 6), replanned.progress);
}

test "episode cache: hit, expiry, sub/dub separation" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X" }, 1000, arena); // FK parent

    const eps = [_]domain.EpisodeNumber{ .{ .raw = "1" }, .{ .raw = "1.5" }, .{ .raw = "2" } };
    // FINISHED → 7d TTL.
    try s.putCachedEpisodes(T_SOURCE, "x", .sub, &eps, "FINISHED", 1000, arena);

    // Hit well inside TTL.
    const got = (try s.getCachedEpisodes(arena, T_SOURCE, "x", .sub, 2000)).?;
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("1.5", got[1].raw);

    // Different track → miss.
    try testing.expect((try s.getCachedEpisodes(arena, T_SOURCE, "x", .dub, 2000)) == null);

    // Past expiry → miss.
    const past = 1000 + 7 * 24 * 60 * 60 + 1;
    try testing.expect((try s.getCachedEpisodes(arena, T_SOURCE, "x", .sub, past)) == null);
}

test "episode cache: TTL is status-keyed and expiry is boundary-exact" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "r", .title = "R" }, 1000, arena); // FK parent
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "u", .title = "U" }, 1000, arena); // FK parent

    const eps = [_]domain.EpisodeNumber{ .{ .raw = "1" }, .{ .raw = "2" } };
    const t0: i64 = 1000;
    const six_h = 6 * 60 * 60; // RELEASING TTL
    const day = 24 * 60 * 60; // unknown/null TTL

    // Same clock, two shows — the only difference is airing status, so any
    // divergence in expiry proves putCachedEpisodes keys the TTL off status
    // (line: now + cacheTtl(status)) rather than baking in a constant.
    try s.putCachedEpisodes(T_SOURCE, "r", .sub, &eps, "RELEASING", t0, arena);
    try s.putCachedEpisodes(T_SOURCE, "u", .sub, &eps, null, t0, arena);

    // Boundary-exact on getCachedEpisodes' `now >= expires_at`: a hit one second
    // before expiry, a miss at the exact expiry second (not expiry+1).
    try testing.expect((try s.getCachedEpisodes(arena, T_SOURCE, "r", .sub, t0 + six_h - 1)) != null);
    try testing.expect((try s.getCachedEpisodes(arena, T_SOURCE, "r", .sub, t0 + six_h)) == null);

    // At the RELEASING show's expiry, the null-status show cached at the SAME
    // instant is still fresh — it was stamped with 24h, not 6h. This is the
    // assertion the existing FINISHED-only test can't make.
    try testing.expect((try s.getCachedEpisodes(arena, T_SOURCE, "u", .sub, t0 + six_h)) != null);
    try testing.expect((try s.getCachedEpisodes(arena, T_SOURCE, "u", .sub, t0 + day - 1)) != null);
    try testing.expect((try s.getCachedEpisodes(arena, T_SOURCE, "u", .sub, t0 + day)) == null);
}

test "cacheTtl by airing status" {
    try testing.expectEqual(@as(i64, 7 * 24 * 60 * 60), Store.cacheTtl("FINISHED"));
    try testing.expectEqual(@as(i64, 6 * 60 * 60), Store.cacheTtl("RELEASING"));
    try testing.expectEqual(@as(i64, 24 * 60 * 60), Store.cacheTtl(null));
    try testing.expectEqual(@as(i64, 24 * 60 * 60), Store.cacheTtl("WEIRD"));
}

test "enrichmentTtl by airing status" {
    // Longer curve than cacheTtl: metadata drifts slower than the episode list.
    try testing.expectEqual(@as(i64, 30 * 24 * 60 * 60), Store.enrichmentTtl("FINISHED"));
    try testing.expectEqual(@as(i64, 24 * 60 * 60), Store.enrichmentTtl("RELEASING"));
    try testing.expectEqual(@as(i64, 24 * 60 * 60), Store.enrichmentTtl("ongoing"));
    // Unknown/unmodelled status still gets grace (7d), NOT always-stale — that
    // case belongs to a null fetched_at, not a null status.
    try testing.expectEqual(@as(i64, 7 * 24 * 60 * 60), Store.enrichmentTtl(null));
    try testing.expectEqual(@as(i64, 7 * 24 * 60 * 60), Store.enrichmentTtl("WEIRD"));
}

test "enrichmentStale: missing/old-fieldset always stale, else TTL-gated by status" {
    const V = Store.ENRICHMENT_FIELDSET_VERSION;

    // Never enriched (or a pre-v6 row) → always stale, regardless of status/now/version.
    try testing.expect(Store.enrichmentStale(null, V, "FINISHED", 0));
    try testing.expect(Store.enrichmentStale(null, null, null, 1_000_000));

    // Enriched under an OLDER field set → stale even with a fresh clock, so a ROD-261
    // widening heals old rows on view instead of waiting out the 30d TTL. A null
    // stored version reads as 0 — older than any real field set.
    try testing.expect(Store.enrichmentStale(1000, V - 1, "FINISHED", 1001));
    try testing.expect(Store.enrichmentStale(1000, null, "FINISHED", 1001));

    // Current field set + FINISHED, fetched at t=1000: fresh inside 30d, stale at the boundary.
    const finished_ttl = 30 * 24 * 60 * 60;
    try testing.expect(!Store.enrichmentStale(1000, V, "FINISHED", 1000 + finished_ttl - 1));
    try testing.expect(Store.enrichmentStale(1000, V, "FINISHED", 1000 + finished_ttl));

    // RELEASING refreshes on a 1d clock — stale a day after the fetch.
    const day = 24 * 60 * 60;
    try testing.expect(!Store.enrichmentStale(1000, V, "RELEASING", 1000 + day - 1));
    try testing.expect(Store.enrichmentStale(1000, V, "RELEASING", 1000 + day));
}

test "enrichment stamp (fetched_at + fieldset_version) round-trips and survives a non-enriching upsert" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const V = Store.ENRICHMENT_FIELDSET_VERSION;

    var s = try Store.openMemory();
    defer s.close();

    // First enrich stamps fetch time + field-set version together.
    try s.upsertAnime(.{
        .source = T_SOURCE,
        .source_id = "e",
        .title = "E",
        .status = "RELEASING",
        .enrichment_fetched_at = 5000,
        .enrichment_fieldset_version = V,
    }, 5000, arena);
    const first = (try s.getAnime(arena, T_SOURCE, "e")).?;
    try testing.expectEqual(@as(?i64, 5000), first.enrichment_fetched_at);
    try testing.expectEqual(@as(?i64, V), first.enrichment_fieldset_version);

    // A plain re-search (no stamp) must NOT wipe either field — COALESCE keeps them,
    // same "re-search never wipes enrichment" rule the content fields lean on.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "e", .title = "E" }, 6000, arena);
    const kept = (try s.getAnime(arena, T_SOURCE, "e")).?;
    try testing.expectEqual(@as(?i64, 5000), kept.enrichment_fetched_at);
    try testing.expectEqual(@as(?i64, V), kept.enrichment_fieldset_version);

    // A later refresh (fresh stamp) overwrites both.
    try s.upsertAnime(.{
        .source = T_SOURCE,
        .source_id = "e",
        .title = "E",
        .status = "FINISHED",
        .enrichment_fetched_at = 9000,
        .enrichment_fieldset_version = V,
    }, 9000, arena);
    const refreshed = (try s.getAnime(arena, T_SOURCE, "e")).?;
    try testing.expectEqual(@as(?i64, 9000), refreshed.enrichment_fetched_at);
    try testing.expectEqual(@as(?i64, V), refreshed.enrichment_fieldset_version);
}

test "upsertEnriched gates the freshness stamp on stamp_fresh, honors visible (ROD-280)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const V = Store.ENRICHMENT_FIELDSET_VERSION;
    var s = try Store.openMemory();
    defer s.close();

    const row: domain.Anime = .{ .id = "u", .name = "U", .status = "RELEASING" };

    // stamp_fresh=false (a failed/transport-miss enrich): caches the row but leaves the
    // freshness clock null — the single canonical gate ROD-278 needed at 3 call sites.
    try s.upsertEnriched(T_SOURCE, row, .sub, false, false, 5000, arena);
    const unstamped = (try s.getAnime(arena, T_SOURCE, "u")).?;
    try testing.expectEqualStrings("U", unstamped.title); // content cached
    try testing.expect(unstamped.enrichment_fetched_at == null); // NOT stamped
    try testing.expect(unstamped.enrichment_fieldset_version == null);
    try testing.expect(!unstamped.history_visible); // visible=false honored

    // stamp_fresh=true (a confirmed answer): advances the clock to `now` at the current
    // fieldset version; visible=true wins the MAX-merge over the stored false.
    try s.upsertEnriched(T_SOURCE, row, .sub, true, true, 9000, arena);
    const stamped = (try s.getAnime(arena, T_SOURCE, "u")).?;
    try testing.expectEqual(@as(?i64, 9000), stamped.enrichment_fetched_at);
    try testing.expectEqual(@as(?i64, V), stamped.enrichment_fieldset_version);
    try testing.expect(stamped.history_visible);

    // Independent variation (visible=false, stamp_fresh=true) on a fresh row pins the
    // argument order — a swap between `visible` and `stamp_fresh` would flip both.
    try s.upsertEnriched(T_SOURCE, .{ .id = "v", .name = "V" }, .sub, false, true, 7000, arena);
    const stamp_only = (try s.getAnime(arena, T_SOURCE, "v")).?;
    try testing.expectEqual(@as(?i64, 7000), stamp_only.enrichment_fetched_at); // stamped...
    try testing.expect(!stamp_only.history_visible); // ...but still hidden
}

test "getAnime surfaces history_visible (ROD-182 refresh-on-view gates on tracked)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    // A hidden search/discover cache row vs a tracked (visible) row — the refresh
    // gate skips the former (its own enrich path owns freshness) and fires the latter.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "hidden", .title = "H", .history_visible = false }, 1, arena);
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "shown", .title = "S", .history_visible = true }, 1, arena);

    try testing.expect(!(try s.getAnime(arena, T_SOURCE, "hidden")).?.history_visible);
    try testing.expect((try s.getAnime(arena, T_SOURCE, "shown")).?.history_visible);
}

test "foreign key cascade deletes progress and cache with its anime" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X" }, 1000, arena);
    try s.saveProgress(T_SOURCE, "x", .sub, "1", 100, 1400, 1001);
    const eps = [_]domain.EpisodeNumber{.{ .raw = "1" }};
    try s.putCachedEpisodes(T_SOURCE, "x", .sub, &eps, "FINISHED", 1000, arena);

    try s.exec("DELETE FROM anime WHERE source_id = 'x';");
    try testing.expect((try s.getResume(T_SOURCE, "x", .sub, "1")) == null);
    try testing.expect((try s.getCachedEpisodes(arena, T_SOURCE, "x", .sub, 1001)) == null);
}

test "recordPlay on an unknown show is a silent no-op" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    // No upsertAnime first: the UPDATE matches zero rows and must not error or
    // conjure a row.
    try s.recordPlay(T_SOURCE, "ghost", 1, 1000, true);
    try testing.expectEqual(@as(usize, 0), (try s.loadHistory(arena)).len);
}

test "recomputeProgress: contiguous high-water (ROD-193)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X", .total_episodes = 5 }, 1000, arena);
    // Seed eps 1..5 all fully_watched (position_secs / duration_secs >= 0.95).
    try s.saveProgress(T_SOURCE, "x", .sub, "1", 950, 1000, 1001);
    try s.saveProgress(T_SOURCE, "x", .sub, "2", 950, 1000, 1002);
    try s.saveProgress(T_SOURCE, "x", .sub, "3", 950, 1000, 1003);
    try s.saveProgress(T_SOURCE, "x", .sub, "4", 950, 1000, 1004);
    try s.saveProgress(T_SOURCE, "x", .sub, "5", 950, 1000, 1005);

    const hw = try s.recomputeProgress(arena, T_SOURCE, "x", .sub);
    try testing.expectEqual(@as(i64, 5), hw);

    // Confirm the store row was updated too.
    const rec = (try s.getAnime(arena, T_SOURCE, "x")).?;
    try testing.expectEqual(@as(i64, 5), rec.progress);
}

test "recomputeProgress: no episode_progress rows → 0 (ROD-193)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    // An anime row with a forced-complete progress (c key clobbers it to total).
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X", .total_episodes = 12 }, 1000, arena);
    try s.setListStatus(T_SOURCE, "x", .completed); // snaps progress to 12

    const before = (try s.getAnime(arena, T_SOURCE, "x")).?;
    try testing.expectEqual(@as(i64, 12), before.progress); // confirm clobber

    // No episode_progress rows exist → recompute → 0.
    const hw = try s.recomputeProgress(arena, T_SOURCE, "x", .sub);
    try testing.expectEqual(@as(i64, 0), hw);

    const after = (try s.getAnime(arena, T_SOURCE, "x")).?;
    try testing.expectEqual(@as(i64, 0), after.progress);
}

test "recomputeProgress: gap-watch documents strategy-A under-count (ROD-193)" {
    // Strategy A contract: progress = 1-based index of the last fully-watched row
    // among the rows PRESENT in episode_progress, sorted by sortKey. Rows for
    // episodes never started are absent from episode_progress — this is by design.
    // Gap-watching (only eps 3 and 5 in episode_progress, both fully_watched, no
    // rows for 1/2/4) yields high_water = 2: the 2-row sorted slice has its last
    // fully-watched entry at index 1 (0-based), i.e. 1-based index 2.
    // This LOCKS the intentional under-count: strategy A is correct for contiguous
    // watchers (the DoD case) and deliberately under-counts gaps. Do not change
    // this expectation without updating the recomputeProgress doc comment.
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X", .total_episodes = 5 }, 1000, arena);
    // Only rows for eps 3 and 5; eps 1, 2, 4 were never started (no rows).
    try s.saveProgress(T_SOURCE, "x", .sub, "3", 950, 1000, 1001);
    try s.saveProgress(T_SOURCE, "x", .sub, "5", 950, 1000, 1002);

    const hw = try s.recomputeProgress(arena, T_SOURCE, "x", .sub);
    // Sorted rows: ["3", "5"]. Last fully-watched is index 1 (0-based) → 1-based = 2.
    try testing.expectEqual(@as(i64, 2), hw);
}

test "upsertAnime cover_url: 'http'-prefixed non-URL garbage neither sticks nor clobbers (ROD-267 review)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    // Garbage the old loose `LIKE 'http%'` matched but which is NOT an absolute URL
    // (no `://`). It must not become sticky — a later real relative cover still lands.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "g", .title = "G", .cover_url = "httpzzz-not-a-url" }, 1000, arena);
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "g", .title = "G", .cover_url = "mcovers/real.webp" }, 1001, arena);
    try testing.expectEqualStrings("mcovers/real.webp", (try s.getAnime(arena, T_SOURCE, "g")).?.cover_url.?);

    // Case-variant garbage ("HTTPFOO…") must not clobber a stored absolute cover —
    // GLOB is case-sensitive, so an uppercase-scheme string is not "absolute".
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "h", .title = "H", .cover_url = "https://s4.anilist.co/real.jpg" }, 1002, arena);
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "h", .title = "H", .cover_url = "HTTPFOO-GARBAGE" }, 1003, arena);
    try testing.expectEqualStrings("https://s4.anilist.co/real.jpg", (try s.getAnime(arena, T_SOURCE, "h")).?.cover_url.?);
}
