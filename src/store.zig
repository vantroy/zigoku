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
const SCHEMA_VERSION: c_int = 5;

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
            // Store the canonical tag ("winter"…) so it round-trips through
            // domain.Season.fromString on the way back out.
            .season = if (a.season) |s| @tagName(s) else null,
            .native_name = a.native_name,
            .kind = a.kind,
            .start_year = if (a.start_date) |d| @intCast(d.year) else null,
            .start_month = if (a.start_date) |d| if (d.month) |m| @intCast(m) else null else null,
            .start_day = if (a.start_date) |d| if (d.day) |dd| @intCast(dd) else null else null,
            .genres = a.genres,
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
        try self.exec("PRAGMA journal_mode = WAL;");
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
    /// list_status, user_rating, notes, added_at, last_watched_at) — re-running a
    /// search must never wipe the viewer's history.
    ///
    /// `cover_url` breaks the plain COALESCE "new-if-present" rule to prefer a
    /// fetchable absolute url over a relative ref (ROD-267): a stored AniList/MAL
    /// cover is never clobbered by a later `mcovers/…` re-search, so an enriched
    /// cover stays put on surfaces that never re-enrich (History).
    /// `scratch` joins the genres list into a '\n' blob for binding (only touched
    /// when `a.genres` is non-empty); pass an arena — like `putCachedEpisodes`,
    /// the join isn't freed here, it rides the caller's arena to teardown. It is
    /// safe to pass a non-arena (e.g. `testing.allocator`) ONLY when `a.genres` is
    /// empty — then nothing is allocated and the lifetime contract is moot.
    pub fn upsertAnime(self: *Store, a: AnimeRecord, now: i64, scratch: Allocator) Error!void {
        const sql =
            \\INSERT INTO anime (source, source_id, title, title_english, mal_id, anilist_id,
            \\    cover_url, year, status, description, score, total_episodes,
            \\    list_status, user_rating, notes, play_count, progress, added_at, last_watched_at, history_visible,
            \\    season, native_name, kind, start_year, start_month, start_day, genres)
            \\VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            \\ON CONFLICT(source, source_id) DO UPDATE SET
            \\    title          = excluded.title,
            \\    title_english  = COALESCE(excluded.title_english, anime.title_english),
            \\    mal_id         = COALESCE(excluded.mal_id, anime.mal_id),
            \\    anilist_id     = COALESCE(excluded.anilist_id, anime.anilist_id),
            \\    cover_url      = CASE
            \\        WHEN excluded.cover_url LIKE 'http%' THEN excluded.cover_url
            \\        WHEN anime.cover_url LIKE 'http%' THEN anime.cover_url
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
            \\    history_visible = MAX(excluded.history_visible, anime.history_visible)
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
            try bindText(stmt, 27, try joinGenres(scratch, a.genres));
        }

        try self.stepDone(stmt);
    }

    /// All shows, most-recently-watched first (then most-recently-added). Every
    /// text field is duped into `arena`.
    pub fn loadHistory(self: *Store, arena: Allocator) Error![]AnimeRecord {
        const sql =
            \\SELECT source, source_id, title, title_english, mal_id, anilist_id, cover_url,
            \\    year, status, description, score, total_episodes, list_status,
            \\    user_rating, notes, play_count, progress, added_at, last_watched_at,
            \\    season, native_name, kind, start_year, start_month, start_day, genres
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
                .genres = try dupeGenres(arena, stmt, 25),
                .history_visible = true,
            });
        }
        return rows.toOwnedSlice(arena);
    }

    /// Full stored metadata for one show, or null if it was never persisted.
    pub fn getAnime(self: *Store, arena: Allocator, source: []const u8, source_id: []const u8) Error!?AnimeRecord {
        const sql =
            \\SELECT source, source_id, title, title_english, mal_id, anilist_id, cover_url,
            \\    year, status, description, score, total_episodes, list_status,
            \\    user_rating, notes, play_count, progress, added_at, last_watched_at,
            \\    season, native_name, kind, start_year, start_month, start_day, genres
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
            .genres = try dupeGenres(arena, stmt, 25),
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

    fn migrate(self: *Store) Error!void {
        var v = try self.userVersion();
        // A DB written by a newer Zigoku knows a schema we don't. Refuse it as a
        // real error (the best-effort caller falls back to no persistence)
        // rather than asserting our way into a panic.
        if (v > SCHEMA_VERSION) return error.SchemaTooNew;
        if (v < 1) {
            try self.exec(MIGRATION_V1);
            try self.exec("PRAGMA user_version = 1;");
            v = 1;
        }
        if (v < 2) {
            try self.exec(MIGRATION_V2);
            try self.exec("PRAGMA user_version = 2;");
            v = 2;
        }
        if (v < 3) {
            try self.exec(MIGRATION_V3);
            try self.exec("PRAGMA user_version = 3;");
            v = 3;
        }
        if (v < 4) {
            try self.exec(MIGRATION_V4);
            try self.exec("PRAGMA user_version = 4;");
            v = 4;
        }
        if (v < 5) {
            try self.exec(MIGRATION_V5);
            try self.exec("PRAGMA user_version = 5;");
            v = 5;
        }
        std.debug.assert(v == SCHEMA_VERSION); // invariant: migrations reached target
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
fn colOptF64(stmt: Stmt, idx: c_int) ?f64 {
    if (c.sqlite3_column_type(stmt, idx) == c.SQLITE_NULL) return null;
    return c.sqlite3_column_double(stmt, idx);
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// Genres persist as a single '\n'-joined blob (display-only — never queried by
// genre, so a column beats a side table). Genre names never contain newlines,
// the same guarantee episode labels lean on in episode_cache.
fn joinGenres(scratch: Allocator, genres: []const []const u8) Error![]const u8 {
    var blob: std.ArrayList(u8) = .empty;
    for (genres, 0..) |g, i| {
        if (i != 0) try blob.append(scratch, '\n');
        try blob.appendSlice(scratch, g);
    }
    return blob.items;
}

/// Split the stored genres blob back into an arena-owned list. A NULL/empty
/// column is an empty list, never a one-element list of "".
fn dupeGenres(arena: Allocator, stmt: Stmt, idx: c_int) Error![]const []const u8 {
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

test "enrichment fields (season/native/kind/start_date/genres) round-trip" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    // Persist via the real domain→record path so the @tagName / Date / genres
    // mapping in fromDomain is exercised, not hand-rolled record literals.
    const genres = [_][]const u8{ "Action", "Adventure", "Fantasy" };
    const rec = AnimeRecord.fromDomain(T_SOURCE, .{
        .id = "frieren",
        .name = "Sousou no Frieren",
        .native_name = "葬送のフリーレン",
        .season = .fall,
        .start_date = .{ .year = 2023, .month = 9, .day = 29 },
        .kind = "TV",
        .genres = &genres,
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

    // loadHistory path sees the same blob split back into a list.
    const rows = try s.loadHistory(arena);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("fall", rows[0].season orelse "");
    try testing.expectEqual(@as(usize, 3), rows[0].genres.len);
    try testing.expectEqualStrings("Adventure", rows[0].genres[1]);
}

test "a later search without genres preserves the persisted genres list" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    const genres = [_][]const u8{ "Action", "Fantasy" };
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X", .genres = &genres }, 1000, arena);
    // A plain re-search carries no genres (empty list → NULL bind → COALESCE keeps
    // the stored blob, same rule the scalar enrichment fields lean on).
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X" }, 2000, arena);

    const got = (try s.getAnime(arena, T_SOURCE, "x")) orelse return error.TestExpectationFailed;
    try testing.expectEqual(@as(usize, 2), got.genres.len);
    try testing.expectEqualStrings("Action", got.genres[0]);
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

test "cacheTtl by airing status" {
    try testing.expectEqual(@as(i64, 7 * 24 * 60 * 60), Store.cacheTtl("FINISHED"));
    try testing.expectEqual(@as(i64, 6 * 60 * 60), Store.cacheTtl("RELEASING"));
    try testing.expectEqual(@as(i64, 24 * 60 * 60), Store.cacheTtl(null));
    try testing.expectEqual(@as(i64, 24 * 60 * 60), Store.cacheTtl("WEIRD"));
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
