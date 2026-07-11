//! Zigoku — persistence (M2: ROD-65..69).
//!
//! One `Store` over raw SQLite C-interop (`@cImport` libsqlite3, no wrapper —
//! the raw API is the point, this is a learning project). Holds the watch
//! history, per-episode resume positions, and a status-aware episode-list cache.
//!
//! ## Why `anime` is keyed on `(source, source_id)`, not `anilist_id`
//!
//! The playable identity is the provider's opaque show handle; `anilist_id`/`mal_id`
//! arrive only later with enrichment, so keying `anime` on them would make every
//! fresh row a NULL primary key. The pair also keeps a dead provider's id namespace
//! from colliding with its replacement's when the `SourceProvider` seam is swapped.
//! `anilist_id`/`mal_id` ride along as nullable enrichment columns; the canonical
//! identity spine keyed on `anilist_id` lives in `canonical_anime` (see MIGRATION_V14).
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
const SCHEMA_VERSION: c_int = 16;

/// Milliseconds SQLite waits on a held write lock before giving up with SQLITE_BUSY,
/// set once per connection in `open` (ROD-287). Two processes share one DB (the TUI
/// plus a standalone/cron'd `zigoku sync`), so a writer can find the lock held. WAL
/// lets readers through, so this only gates writer-vs-writer. Kept short because the
/// TUI runs its checkpoint/recordPlay writes on the render/input thread, so a long
/// wait freezes the UI: real collisions resolve far below this (migration <20ms, a
/// lone checkpoint UPDATE sub-ms), so 250ms is ~10x the realistic worst case yet caps
/// a foreground stall at a quarter-second, and failing fast is right for a render loop
/// (a dropped checkpoint is recoverable). Does NOT cover the WAL-mode flip in `open`;
/// SQLite skips its busy handler for that lock upgrade, so `enableWal` retries by hand.
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

/// Reserved pseudo-`source`: a canonical resolved (real AniList id) but no play provider
/// stocks it (ROD-329). Distinct from the enrichment "confirmed-unmatched" state
/// (canonical_id NULL, see MIGRATION_V14 comment), which is an id-miss; this is a
/// provider-miss. Never a real provider name: the History gate keys on this exact string.
pub const SOURCE_UNBOUND = "unbound";

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

// enrichment_fetched_at stamps the last successful AniList pull so a status-aware
// TTL (`enrichmentTtl`) can drive refresh-on-view (ROD-182). NULL = never enriched
// or pre-v6, both read as stale (`enrichmentStale`). It rides `anime` rather than a
// side table because the freshness key is the row's own live `status`, computed at
// read.
//
// enrichment_fieldset_version records which set of enriched columns a row was last
// filled under (see `ENRICHMENT_FIELDSET_VERSION`). Widening the persisted set
// (ROD-261 added studios/source/duration) leaves old rows fresh-by-clock but missing
// the new columns; bumping the constant marks every older-fieldset row stale so they
// heal on next view instead of waiting out the TTL.
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

// synced_status/synced_progress snapshot the (list_status, progress) pair AniList
// last accepted (ROD-284). A row is dirty (needs push) when it has an anilist_id and
// its live pair differs from this snapshot, or the snapshot is NULL (never synced).
// Snapshot-vs-live, NOT a synced_at clock: last_watched_at only moves on playback, so
// a wall-clock watermark would miss a manual drop/pause. Both NULL pre-v11, so the
// first push treats the engaged library as dirty and backfills. Also the
// last-known-synced baseline for the ROD-285 pull/reconcile merge, not push-only.
const MIGRATION_V11 =
    \\ALTER TABLE anime ADD COLUMN synced_status   TEXT;
    \\ALTER TABLE anime ADD COLUMN synced_progress INTEGER;
;

// ROD-304: re-key rows off the captcha-dead AllAnime provider onto senshi so a
// watchlist survives the default-provider swap. senshi's handle IS the stringified
// MAL id already stored in `anime.mal_id`, so every enriched row re-keys offline:
// `(allanime, opaque_id) -> (senshi, CAST(mal_id AS TEXT))`. NULL-mal_id rows can't
// map to a MAL-keyed provider and stay in place for ROD-307 to backfill.
//
// In-place UPDATE, not a copy: `loadHistory` reads every row regardless of `source`,
// so additive senshi rows would double each show. FKs are ON DELETE CASCADE only, so
// moving a parent key transiently orphans its children; `defer_foreign_keys` pushes
// the checks to COMMIT, consistent again by then (resets per transaction, and this
// ladder runs inside migrate()'s one BEGIN IMMEDIATE).
const MIGRATION_V12 =
    \\PRAGMA defer_foreign_keys = ON;
    \\
    \\-- Freeze the allanime -> senshi mapping before mutating `anime`, so every step
    \\-- keys off a stable snapshot (old opaque id -> stringified MAL id). old_id is a
    \\-- per-source PK, so it's unique here; new_id may repeat if two allanime rows
    \\-- enriched to one MAL id (a dup is resolved by OR IGNORE + the cleanup below).
    \\CREATE TEMP TABLE _rekey_304 AS
    \\  SELECT source_id AS old_id, CAST(mal_id AS TEXT) AS new_id
    \\    FROM anime WHERE source = 'allanime' AND mal_id IS NOT NULL AND mal_id > 0;
    \\
    \\-- The episode-list cache is provider-specific (senshi may label/segment episodes
    \\-- differently), so drop it for every migrated show rather than carry stale labels;
    \\-- senshi refetches lazily on next view.
    \\DELETE FROM episode_cache
    \\ WHERE source = 'allanime' AND source_id IN (SELECT old_id FROM _rekey_304);
    \\
    \\-- Resume + fully-watched state follows the show onto its senshi key — this is the
    \\-- watchlist "not going dark". OR IGNORE tolerates a pre-existing senshi twin's
    \\-- progress row (user re-added the show under senshi) or an intra-allanime dup;
    \\-- the superseded straggler is swept below.
    \\UPDATE OR IGNORE episode_progress
    \\   SET source = 'senshi',
    \\       source_id = (SELECT new_id FROM _rekey_304 WHERE old_id = episode_progress.source_id)
    \\ WHERE source = 'allanime' AND source_id IN (SELECT old_id FROM _rekey_304);
    \\
    \\-- The show rows themselves. OR IGNORE preserves any pre-existing senshi row with
    \\-- the same MAL id (no clobber, no history loss); the losing allanime row is swept.
    \\UPDATE OR IGNORE anime
    \\   SET source = 'senshi',
    \\       source_id = (SELECT new_id FROM _rekey_304 WHERE old_id = anime.source_id)
    \\ WHERE source = 'allanime' AND source_id IN (SELECT old_id FROM _rekey_304);
    \\
    \\-- Sweep: any row still bearing a migrated old_id was skipped by OR IGNORE (twin
    \\-- or dup) and is now a superseded duplicate. Dropping it leaves exactly one row
    \\-- per show and no orphaned child. Moved rows are already source='senshi', so this
    \\-- source='allanime' filter can't touch them.
    \\DELETE FROM episode_progress
    \\ WHERE source = 'allanime' AND source_id IN (SELECT old_id FROM _rekey_304);
    \\DELETE FROM anime
    \\ WHERE source = 'allanime' AND source_id IN (SELECT old_id FROM _rekey_304);
    \\
    \\DROP TABLE _rekey_304;
;

// ROD-308: a tiny key/value table for app-level one-time flags that are DB-scoped
// rather than schema-versioned — the first user is the provider-cutover backfill
// marker (`app_meta['provider_backfill_v1'] = 'done'`), stamped once the network
// idMal backfill has fully widened the senshi re-key so it never re-runs. Distinct
// from `SCHEMA_VERSION` (which gates DDL) and from enrichment metadata.
const MIGRATION_V13 =
    \\CREATE TABLE app_meta (
    \\    key   TEXT NOT NULL PRIMARY KEY,
    \\    value TEXT NOT NULL
    \\);
;

// canonical_anime: one row per distinct AniList id. Provider rows (senshi, a
// future anipub) bind UP to it via `anime.canonical_id`, so identity + enrichment
// live once here and survive a provider swap instead of being duplicated per row.
//
// PK is anilist_id because AniList is the identity superset: every enriched entity
// has one, not every has a mal_id. mal_id is a nullable, non-unique secondary so
// MAL-native providers resolve free; it never keys the spine.
//
// INVARIANT: canonical holds identity + enrichment only. User-state (list_status,
// progress, ratings, notes, sync snapshots, clocks) and the binding key (source,
// source_id) stay on anime; they are per-binding, never move them here.
//
// Backfill picks one source row per anilist_id (freshest enrichment, then senshi,
// then lowest rowid) and recovers a mal_id from any sibling the winner lacked. Both
// are dormant while every anilist_id is unique; the suite drives BACKFILL alone
// against seeded rows to pin them before two providers ever co-bind one id.
//
// DDL + BACKFILL split run back to back inside migrate()'s one BEGIN IMMEDIATE, so
// V14 commits atomically with the version bump. defer_foreign_keys is V12 parity
// only: canonical is fully populated before the link UPDATE, so nothing defers.
const MIGRATION_V14_DDL =
    \\PRAGMA defer_foreign_keys = ON;
    \\
    \\CREATE TABLE canonical_anime (
    \\    anilist_id                  INTEGER PRIMARY KEY,  -- AniList id: the canonical spine key
    \\    mal_id                      INTEGER,              -- secondary (MAL-native); non-unique, may be NULL
    \\    title                       TEXT,                 -- seeded from provider display; heals to romaji (ROD-312)
    \\    title_english               TEXT,
    \\    cover_url                   TEXT,
    \\    total_episodes              INTEGER,
    \\    year                        INTEGER,
    \\    status                      TEXT,
    \\    description                 TEXT,
    \\    score                       INTEGER,
    \\    season                      TEXT,
    \\    native_name                 TEXT,
    \\    kind                        TEXT,
    \\    start_year                  INTEGER,
    \\    start_month                 INTEGER,
    \\    start_day                   INTEGER,
    \\    genres                      TEXT,
    \\    enrichment_fetched_at       INTEGER,
    \\    enrichment_fieldset_version INTEGER,
    \\    studios                     TEXT,
    \\    duration                    INTEGER,
    \\    source_material             TEXT,
    \\    rank                        INTEGER,
    \\    rank_type                   TEXT,
    \\    rank_year                   INTEGER,
    \\    next_airing_at              INTEGER,
    \\    next_airing_episode         INTEGER,
    \\    country                     TEXT
    \\);
    \\CREATE INDEX idx_canonical_mal ON canonical_anime(mal_id);
    \\
    \\-- Binding -> canonical link column (nullable FK; NULL default satisfies SQLite's
    \\-- ALTER-ADD-COLUMN-with-REFERENCES rule), then its indexes. idx_anime_anilist has
    \\-- no reader in V14 — it is groundwork for ROD-312's canonical-resolution join.
    \\ALTER TABLE anime ADD COLUMN canonical_id INTEGER REFERENCES canonical_anime(anilist_id);
    \\CREATE INDEX idx_anime_canonical ON anime(canonical_id);
    \\CREATE INDEX idx_anime_anilist   ON anime(anilist_id);
;

// The data lift, held apart from the DDL above so the migrate test can run it in
// isolation against a seeded anime table. Idempotent-safe to run once against an
// empty canonical_anime (the ladder's case, and the test's after openMemory seeds a
// fresh v14). All the dormant multi-provider logic lives here.
const MIGRATION_V14_BACKFILL =
    \\-- One canonical row per distinct anilist_id; the ROW_NUMBER window picks the
    \\-- best source row when two bindings ever co-bind an id (dormant today: every
    \\-- group is size 1). DESC on enrichment_fetched_at sorts NULLs last in SQLite.
    \\INSERT INTO canonical_anime (
    \\    anilist_id, mal_id, title, title_english, cover_url, total_episodes,
    \\    year, status, description, score, season, native_name, kind,
    \\    start_year, start_month, start_day, genres,
    \\    enrichment_fetched_at, enrichment_fieldset_version, studios, duration,
    \\    source_material, rank, rank_type, rank_year,
    \\    next_airing_at, next_airing_episode, country
    \\)
    \\SELECT
    \\    anilist_id, mal_id, title, title_english, cover_url, total_episodes,
    \\    year, status, description, score, season, native_name, kind,
    \\    start_year, start_month, start_day, genres,
    \\    enrichment_fetched_at, enrichment_fieldset_version, studios, duration,
    \\    source_material, rank, rank_type, rank_year,
    \\    next_airing_at, next_airing_episode, country
    \\FROM (
    \\    SELECT *, ROW_NUMBER() OVER (
    \\        PARTITION BY anilist_id
    \\        ORDER BY enrichment_fetched_at DESC,
    \\                 CASE source WHEN 'senshi' THEN 0 ELSE 1 END,
    \\                 rowid
    \\    ) AS _rn
    \\    FROM anime
    \\    WHERE anilist_id IS NOT NULL
    \\)
    \\WHERE _rn = 1;
    \\
    \\-- Recover mal_id from any sibling binding the winner lacked (dormant today).
    \\UPDATE canonical_anime
    \\   SET mal_id = (
    \\       SELECT a.mal_id FROM anime a
    \\        WHERE a.anilist_id = canonical_anime.anilist_id
    \\          AND a.mal_id IS NOT NULL
    \\        ORDER BY a.mal_id
    \\        LIMIT 1
    \\   )
    \\ WHERE mal_id IS NULL
    \\   AND EXISTS (
    \\       SELECT 1 FROM anime a
    \\        WHERE a.anilist_id = canonical_anime.anilist_id
    \\          AND a.mal_id IS NOT NULL
    \\   );
    \\
    \\-- Link every id-bearing binding. Rows with NULL anilist_id keep canonical_id
    \\-- NULL — the three-state contract (canonical_id + enrichment_fetched_at) reads
    \\-- them as pending / confirmed-unmatched.
    \\UPDATE anime SET canonical_id = anilist_id WHERE anilist_id IS NOT NULL;
;

// ROD-345: per-show preferred-provider pin, keyed on the canonical spine. User
// state, so it gets its own table rather than a column on canonical_anime: the
// enrichment upsert must never be able to touch it (the V14 INVARIANT).
const MIGRATION_V15 =
    \\CREATE TABLE provider_pins (
    \\    canonical_id INTEGER PRIMARY KEY REFERENCES canonical_anime(anilist_id),
    \\    provider     TEXT NOT NULL
    \\);
;

// ROD-347: the negative arm of the per-(canonical, provider) availability
// tri-state. Only definitive "searched, not stocked" verdicts are persisted;
// "bound" is derived from the anime table and "unchecked" is the absence of a
// row, so this table never mirrors either. Own table for the same reason as
// provider_pins: the enrichment upsert must never be able to touch it.
const MIGRATION_V16 =
    \\CREATE TABLE provider_absences (
    \\    canonical_id INTEGER NOT NULL REFERENCES canonical_anime(anilist_id),
    \\    provider     TEXT NOT NULL,
    \\    checked_at   INTEGER NOT NULL,
    \\    PRIMARY KEY (canonical_id, provider)
    \\);
;

// ── Records ─────────────────────────────────────────────────────────────────

/// A library/history row. Text fields returned from `loadHistory` are owned by
/// the arena passed to it.
pub const AnimeRecord = struct {
    source: []const u8,
    source_id: []const u8,
    title: []const u8,
    /// ROD-312: true AniList romaji, write-only carrier for the canonical heal.
    /// `upsertCanonical` heals `canonical.title` to this when present (non-empty),
    /// preserving a prior heal on a seed-only re-persist rather than downgrading — see
    /// its anti-downgrade CASE. The anime-local `title` always keeps the provider seed.
    /// Never read back onto a record; the healed title returns via the COALESCE read as
    /// `title`. Left null by `loadHistory`/`getAnime`.
    title_romaji: ?[]const u8 = null,
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
    /// ROD-312: the binding's link to its canonical entity (== anilist_id today).
    /// NULL until enrichment resolves an id; set by `upsertEnriched` only after the
    /// canonical row exists (the FK target). `fromDomain` leaves it null — a plain
    /// search persist never mints the link.
    canonical_id: ?i64 = null,

    /// Build a row from a freshly-searched show. Only carries what the source
    /// gives us; user state (status/rating/notes/counts) takes table defaults
    /// and is preserved across re-searches by `upsertAnime`.
    pub fn fromDomain(source: []const u8, a: domain.Anime, tt: domain.Translation) AnimeRecord {
        const eps = a.episodeCount(tt);
        return .{
            .source = source,
            .source_id = a.id,
            .title = a.name,
            .title_romaji = a.title_romaji,
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
    /// Threading: this one connection handle is shared across threads (the main loop,
    /// the history worker at startup, and interrupt() at quit), which is safe ONLY under
    /// SQLite's serialized mode. We rely on NOT passing SQLITE_OPEN_NOMUTEX (which
    /// downgrades to multi-thread mode, where one connection is not thread-safe). Do not
    /// add NOMUTEX/FULLMUTEX without auditing every cross-thread call site; the assert
    /// below trips loud if a build links a non-serialized SQLite.
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
        // Bound lock-contention waits before the first statement so migrate()'s
        // BEGIN IMMEDIATE and every later writer sit out a concurrent holder instead
        // of erroring (ROD-287, see BUSY_TIMEOUT_MS). enableWal handles the WAL flip
        // it can't rescue.
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
    /// INVARIANT: never touches user state on conflict (play_count, progress,
    /// list_status, user_rating, notes, added_at, last_watched_at, and the ROD-284
    /// sync snapshot synced_status/synced_progress). A re-run search must not wipe
    /// history or reset the sync snapshot (which would make every re-viewed show
    /// permanently dirty). Concretely: none of those columns appear in the
    /// `ON CONFLICT DO UPDATE SET` clause below; keep it that way when adding columns.
    ///
    /// `cover_url` breaks plain COALESCE to prefer a fetchable absolute url over a
    /// relative ref (ROD-267), so an enriched AniList/MAL cover is never clobbered by a
    /// later `mcovers/…` re-search on surfaces that don't re-enrich (History). The
    /// "absolute" test is a case-sensitive `http(s)://` GLOB mirroring
    /// `domain.isAbsoluteUrl` so the two layers can't drift.
    ///
    /// `scratch` joins genres/studios into '\n' blobs and, like `putCachedEpisodes`,
    /// does not free them: they ride the caller's arena to teardown. Passing a
    /// non-arena is safe ONLY when both lists are empty (nothing is allocated).
    pub fn upsertAnime(self: *Store, a: AnimeRecord, now: i64, scratch: Allocator) Error!void {
        const sql =
            \\INSERT INTO anime (source, source_id, title, title_english, mal_id, anilist_id,
            \\    cover_url, year, status, description, score, total_episodes,
            \\    list_status, user_rating, notes, play_count, progress, added_at, last_watched_at, history_visible,
            \\    season, native_name, kind, start_year, start_month, start_day, genres,
            \\    enrichment_fetched_at, enrichment_fieldset_version, studios, duration,
            \\    source_material, rank, rank_type, rank_year,
            \\    next_airing_at, next_airing_episode, country, canonical_id)
            \\VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
            \\    country        = COALESCE(excluded.country, anime.country),
            \\    canonical_id   = COALESCE(excluded.canonical_id, anime.canonical_id)
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
        // ROD-312: the canonical link. NULL on a plain search persist (COALESCE
        // preserves any existing link); set to anilist_id by upsertEnriched once the
        // canonical row exists, so the FK to canonical_anime(anilist_id) is satisfied.
        try bindOptI64(stmt, 39, a.canonical_id);

        try self.stepDone(stmt);
    }

    /// Persist enrichment onto the canonical spine (ROD-312), one entity per AniList
    /// id, called ONLY for id-bearing rows (see `upsertEnriched`'s M1 guard). The
    /// ON CONFLICT set mirrors `upsertAnime`: COALESCE(excluded, canonical) keeps
    /// anything the incoming row lacks, plus the same absolute-cover preference
    /// (ROD-267). `title` is the exception (anti-downgrade): it refreshes only when
    /// this row carries real romaji (the `?29` flag), never back to a provider seed;
    /// see the bind block. A fresh INSERT bootstraps `title` via `romaji orelse a.title`.
    ///
    /// M1 (ROD-311): `anilist_id` is asserted non-null. It is INTEGER PRIMARY KEY, so a
    /// NULL insert auto-assigns a rowid and would mint a bogus canonical entity for an
    /// unresolved title; the assert makes that a loud invariant.
    fn upsertCanonical(self: *Store, a: AnimeRecord, scratch: Allocator) Error!void {
        std.debug.assert(a.anilist_id != null);
        const sql =
            \\INSERT INTO canonical_anime (anilist_id, mal_id, title, title_english, cover_url,
            \\    total_episodes, year, status, description, score, season, native_name, kind,
            \\    start_year, start_month, start_day, genres,
            \\    enrichment_fetched_at, enrichment_fieldset_version, studios, duration,
            \\    source_material, rank, rank_type, rank_year,
            \\    next_airing_at, next_airing_episode, country)
            \\VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            \\ON CONFLICT(anilist_id) DO UPDATE SET
            \\    mal_id         = COALESCE(excluded.mal_id, canonical_anime.mal_id),
            \\    title          = CASE WHEN ?29 THEN excluded.title ELSE canonical_anime.title END,
            \\    title_english  = COALESCE(excluded.title_english, canonical_anime.title_english),
            \\    cover_url      = CASE
            \\        WHEN excluded.cover_url GLOB 'http://*' OR excluded.cover_url GLOB 'https://*' THEN excluded.cover_url
            \\        WHEN canonical_anime.cover_url GLOB 'http://*' OR canonical_anime.cover_url GLOB 'https://*' THEN canonical_anime.cover_url
            \\        ELSE COALESCE(excluded.cover_url, canonical_anime.cover_url)
            \\    END,
            \\    total_episodes = COALESCE(excluded.total_episodes, canonical_anime.total_episodes),
            \\    year           = COALESCE(excluded.year, canonical_anime.year),
            \\    status         = COALESCE(excluded.status, canonical_anime.status),
            \\    description    = COALESCE(excluded.description, canonical_anime.description),
            \\    score          = COALESCE(excluded.score, canonical_anime.score),
            \\    season         = COALESCE(excluded.season, canonical_anime.season),
            \\    native_name    = COALESCE(excluded.native_name, canonical_anime.native_name),
            \\    kind           = COALESCE(excluded.kind, canonical_anime.kind),
            \\    start_year     = COALESCE(excluded.start_year, canonical_anime.start_year),
            \\    start_month    = COALESCE(excluded.start_month, canonical_anime.start_month),
            \\    start_day      = COALESCE(excluded.start_day, canonical_anime.start_day),
            \\    genres         = COALESCE(excluded.genres, canonical_anime.genres),
            \\    enrichment_fetched_at = COALESCE(excluded.enrichment_fetched_at, canonical_anime.enrichment_fetched_at),
            \\    enrichment_fieldset_version = COALESCE(excluded.enrichment_fieldset_version, canonical_anime.enrichment_fieldset_version),
            \\    studios        = COALESCE(excluded.studios, canonical_anime.studios),
            \\    duration       = COALESCE(excluded.duration, canonical_anime.duration),
            \\    source_material = COALESCE(excluded.source_material, canonical_anime.source_material),
            \\    rank           = COALESCE(excluded.rank, canonical_anime.rank),
            \\    rank_type      = COALESCE(excluded.rank_type, canonical_anime.rank_type),
            \\    rank_year      = COALESCE(excluded.rank_year, canonical_anime.rank_year),
            \\    next_airing_at = COALESCE(excluded.next_airing_at, canonical_anime.next_airing_at),
            \\    next_airing_episode = COALESCE(excluded.next_airing_episode, canonical_anime.next_airing_episode),
            \\    country        = COALESCE(excluded.country, canonical_anime.country)
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        // ROD-312 heal: romaji only when non-empty (an empty string is "no romaji").
        // Anti-downgrade: once canonical.title holds real romaji, a later seed-only
        // re-persist (a Discover/search hydrate that backfilled anilist_id but carries
        // no romaji) must NOT clobber it back to the seed, so the ON CONFLICT overwrites
        // `title` only when this row carries romaji (the ?29 flag). A fresh INSERT still
        // bootstraps with romaji-or-seed; anime-local `title` stays the provider seed.
        const romaji: ?[]const u8 = if (a.title_romaji) |r| (if (r.len > 0) r else null) else null;

        try bindOptI64(stmt, 1, a.anilist_id);
        try bindOptI64(stmt, 2, a.mal_id);
        try bindText(stmt, 3, romaji orelse a.title);
        try bindOptText(stmt, 4, a.title_english);
        try bindOptText(stmt, 5, a.cover_url);
        try bindOptI64(stmt, 6, a.total_episodes);
        try bindOptI64(stmt, 7, a.year);
        try bindOptText(stmt, 8, a.status);
        try bindOptText(stmt, 9, a.description);
        try bindOptI64(stmt, 10, a.score);
        try bindOptText(stmt, 11, a.season);
        try bindOptText(stmt, 12, a.native_name);
        try bindOptText(stmt, 13, a.kind);
        try bindOptI64(stmt, 14, a.start_year);
        try bindOptI64(stmt, 15, a.start_month);
        try bindOptI64(stmt, 16, a.start_day);
        // Same empty→NULL rule as upsertAnime: a re-enrich that carries no genres
        // never wipes a list an earlier one persisted (the COALESCE preserves it).
        if (a.genres.len == 0) {
            try checkBind(stmt, c.sqlite3_bind_null(stmt, 17));
        } else {
            try bindText(stmt, 17, try joinStrBlob(scratch, a.genres));
        }
        try bindOptI64(stmt, 18, a.enrichment_fetched_at);
        try bindOptI64(stmt, 19, a.enrichment_fieldset_version);
        if (a.studios.len == 0) {
            try checkBind(stmt, c.sqlite3_bind_null(stmt, 20));
        } else {
            try bindText(stmt, 20, try joinStrBlob(scratch, a.studios));
        }
        try bindOptI64(stmt, 21, a.duration);
        try bindOptText(stmt, 22, a.source_material);
        try bindOptI64(stmt, 23, a.rank);
        try bindOptText(stmt, 24, a.rank_type);
        try bindOptI64(stmt, 25, a.rank_year);
        try bindOptI64(stmt, 26, a.next_airing_at);
        try bindOptI64(stmt, 27, a.next_airing_episode);
        try bindOptText(stmt, 28, a.country);
        // ?29: "this row carries real romaji" — gates the anti-downgrade title CASE.
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 29, if (romaji != null) 1 else 0));

        try self.stepDone(stmt);
    }

    /// Persist a search hit as a canonical entity only, no binding row (ROD-326): writes
    /// `canonical_anime`, never `anime` (the provider binding is the resolver's job,
    /// ROD-328). `source` is unused by the canonical write; `.sub` only feeds `fromDomain`'s
    /// `episodeCount`, which is 0 for a search hit, so neither placeholder reaches a column.
    /// A caller passing a row with real per-track counts would break that: scope this to
    /// search hits.
    ///
    /// `stamp_fresh` gates the freshness stamp (same contract as `upsertEnriched`, ROD-182):
    /// pass true only when `anime` carries the full enrichment field set from a confirmed
    /// answer. Both current callers qualify: AniList discovery search (ROD-326) and the
    /// AniList Discover feed (ROD-336) return the full `GQL_FIELDS`. A caller with a
    /// partial row MUST pass false, or its gaps never draw a refresh.
    pub fn upsertCanonicalOnly(self: *Store, anime: domain.Anime, stamp_fresh: bool, now: i64, scratch: Allocator) Error!void {
        var rec = AnimeRecord.fromDomain("", anime, .sub);
        if (stamp_fresh) {
            rec.enrichment_fetched_at = now;
            rec.enrichment_fieldset_version = ENRICHMENT_FIELDSET_VERSION;
        }
        return self.upsertCanonical(rec, scratch);
    }

    /// Mint (or link) the provider binding row for a canonical entity (ROD-327): the
    /// tier-A resolver's write, once `provider.episodes()` confirms the provider stocks
    /// the show. `anilist_id` must already own a canonical row (search persisted it via
    /// `upsertCanonicalOnly`). Creates the `(source, source_id)` binding, links
    /// `canonical_id`, reveals it when `visible`. Display columns resolve through canonical
    /// (loadHistory/getAnime COALESCE), so the binding carries only identity plus the NOT
    /// NULL `title`. `upsertAnime`'s ON CONFLICT preserves user state and MAX-merges
    /// `history_visible`, so a re-resolve of an already-tracked show never clobbers it.
    ///
    /// Returns false if no canonical row exists for `anilist_id` (persist ran out of order
    /// or silently failed): the caller must not report success, since persist is
    /// best-effort and a false "success" here means an Add toasts a lie or a later
    /// `recordPlay` FK-fails.
    pub fn bindCanonical(self: *Store, source: []const u8, source_id: []const u8, anilist_id: i64, visible: bool, now: i64, scratch: Allocator) Error!bool {
        const canon = try self.getCanonicalByAnilistId(scratch, anilist_id) orelse {
            std.log.debug("store: bindCanonical found no canonical row for anilist_id {d}", .{anilist_id});
            return false;
        };
        // ROD-329: a real bind supersedes any prior `unbound` sentinel for this canonical
        // (shared `canonical_id`). A lingering sentinel (NULL last_watched, lower rowid)
        // wins loadHistory's ROD-313 collapse and would mask the now-playable row, so
        // delete it. Inherit its visibility: the sentinel always mints visible, so a hidden
        // Play-path bind must reveal here or the show drops out of History.
        var effective_visible = visible;
        if (!std.mem.eql(u8, source, SOURCE_UNBOUND) and try self.supersedeUnbound(anilist_id)) {
            effective_visible = true;
        }
        const rec: AnimeRecord = .{
            .source = source,
            .source_id = source_id,
            .title = canon.title,
            .mal_id = canon.mal_id,
            .anilist_id = anilist_id,
            .canonical_id = anilist_id,
            .history_visible = effective_visible,
        };
        try self.upsertAnime(rec, now, scratch);
        // ROD-347 invariant: bound and absent never coexist. A real mint proves the
        // provider stocks the show, so it supersedes any cached negative. The unbound
        // sentinel is not a provider verdict and clears nothing.
        if (!std.mem.eql(u8, source, SOURCE_UNBOUND)) {
            try self.clearProviderAbsence(anilist_id, source);
        }
        return true;
    }

    /// Delete the `unbound` sentinel for `anilist_id`, if present (ROD-329). A plain row
    /// delete is safe: the sentinel owns no episode_progress rows (Play is gated off it),
    /// so nothing cascades.
    fn supersedeUnbound(self: *Store, anilist_id: i64) Error!bool {
        var buf: [24]u8 = undefined;
        const source_id = unboundSourceId(&buf, anilist_id) orelse return false;
        const stmt = try self.prepare("DELETE FROM anime WHERE source = ? AND source_id = ?");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, SOURCE_UNBOUND);
        try bindText(stmt, 2, source_id);
        try self.stepDone(stmt);
        return c.sqlite3_changes(self.db) > 0;
    }

    /// Persist the ROD-329 unbound terminal state: the add-time resolver found no play
    /// provider, so mint a visible `SOURCE_UNBOUND` binding. A thin wrapper over
    /// `bindCanonical` (reuses its conflict/merge semantics) rather than a bespoke insert,
    /// to keep `bindCanonical`'s "provider stocks the show" contract honest. Returns false
    /// when no canonical row exists yet: the caller must not toast success on that.
    pub fn markUnbound(self: *Store, anilist_id: i64, now: i64, scratch: Allocator) Error!bool {
        var buf: [24]u8 = undefined;
        const source_id = unboundSourceId(&buf, anilist_id) orelse return false;
        return self.bindCanonical(SOURCE_UNBOUND, source_id, anilist_id, true, now, scratch);
    }

    /// The sentinel's `source_id`, in one place so `markUnbound` and `supersedeUnbound`
    /// can't key the row differently (ROD-329).
    fn unboundSourceId(buf: []u8, anilist_id: i64) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{d}", .{anilist_id}) catch null;
    }

    /// Map a freshly-fetched domain row into the store, set `history_visible`, and
    /// (ONLY when `stamp_fresh`) advance the enrichment freshness clock, then upsert
    /// (ROD-280).
    ///
    /// `stamp_fresh` must be true only when AniList returned a *confirmed* answer (a
    /// match or a confirmed no-match), never on a transport/parse failure (the ROD-278
    /// `EnrichError` contract). Folding the gate here keeps it in ONE place: search,
    /// Discover, and refresh-on-view all route through this, so no caller can
    /// reintroduce an un-gated stamp (the bug ROD-278 fixed across 3 sites).
    ///
    /// `now` timestamps the stamp and `upsertAnime`'s `added_at`; pass one value per
    /// page so a batch shares it. `scratch` is the genres-blob arena (see `upsertAnime`).
    /// Id-bearing rows write canonical FIRST then link `canonical_id` (the FK target
    /// must exist first); rows with no anilist_id skip canonical (the M1 guard).
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
        if (rec.anilist_id != null) {
            try self.upsertCanonical(rec, scratch);
            rec.canonical_id = rec.anilist_id;
        }
        return self.upsertAnime(rec, now, scratch);
    }

    /// All shows, most-recently-watched first (then most-recently-added). Every
    /// text field is duped into `arena`.
    pub fn loadHistory(self: *Store, arena: Allocator) Error![]AnimeRecord {
        // ROD-312: resolve enrichment through the canonical spine. Every identity/
        // enrichment column reads COALESCE(canonical, anime-local): canonical wins where
        // a binding resolved to one, anime-local is the fallback for the unmatched tail
        // (canonical_id NULL, the LEFT JOIN yields NULLs). User-state and the binding key
        // stay anime-only; column ORDER is unchanged (the row builder reads by index).
        //
        // ROD-313: collapse multi-binding shows (senshi sub+dub, or senshi + a future
        // anipub) to one History card via a ROW_NUMBER representative per group. Two
        // invariants:
        //   1. PARTITION BY COALESCE(canonical_id, -rowid), never bare canonical_id: the
        //      unmatched tail is all NULL, which SQLite groups as one, so bare
        //      partitioning would fuse the whole tail into a single card. -rowid is unique
        //      and never collides with a real (positive) anilist_id.
        //   2. The representative is an explicit TOTAL order (most-recently-watched, then
        //      furthest progress, then rowid), so a never-played co-bound pair still
        //      resolves deterministically. Its user-state is what the card shows and what
        //      Play resumes; enrichment columns are group-invariant.
        // Display-only: no row deleted, no user-state merged.
        const sql =
            \\SELECT anime.source, anime.source_id,
            \\    COALESCE(c.title, anime.title), COALESCE(c.title_english, anime.title_english),
            \\    COALESCE(c.mal_id, anime.mal_id), anime.anilist_id, COALESCE(c.cover_url, anime.cover_url),
            \\    COALESCE(c.year, anime.year), COALESCE(c.status, anime.status), COALESCE(c.description, anime.description),
            \\    COALESCE(c.score, anime.score), COALESCE(c.total_episodes, anime.total_episodes), anime.list_status,
            \\    anime.user_rating, anime.notes, anime.play_count, anime.progress, anime.added_at, anime.last_watched_at,
            \\    COALESCE(c.season, anime.season), COALESCE(c.native_name, anime.native_name), COALESCE(c.kind, anime.kind),
            \\    COALESCE(c.start_year, anime.start_year), COALESCE(c.start_month, anime.start_month), COALESCE(c.start_day, anime.start_day), COALESCE(c.genres, anime.genres),
            \\    COALESCE(c.enrichment_fetched_at, anime.enrichment_fetched_at), COALESCE(c.enrichment_fieldset_version, anime.enrichment_fieldset_version), COALESCE(c.studios, anime.studios), COALESCE(c.duration, anime.duration),
            \\    COALESCE(c.source_material, anime.source_material), COALESCE(c.rank, anime.rank), COALESCE(c.rank_type, anime.rank_type), COALESCE(c.rank_year, anime.rank_year),
            \\    COALESCE(c.next_airing_at, anime.next_airing_at), COALESCE(c.next_airing_episode, anime.next_airing_episode), COALESCE(c.country, anime.country)
            \\FROM (
            \\    SELECT *, ROW_NUMBER() OVER (
            \\        PARTITION BY COALESCE(canonical_id, -rowid)
            \\        ORDER BY last_watched_at DESC NULLS LAST, progress DESC, rowid
            \\    ) AS _rn
            \\    FROM anime
            \\    WHERE history_visible != 0
            \\) anime
            \\LEFT JOIN canonical_anime c ON anime.canonical_id = c.anilist_id
            \\WHERE anime._rn = 1
            \\ORDER BY anime.last_watched_at DESC NULLS LAST, anime.added_at DESC
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

    /// The pull/reconcile candidate set (ROD-285): every engaged, id-bearing row with
    /// its last-synced snapshot for the 3-way merge. Same gate as `loadDirtyForSync`
    /// (engaged + `anilist_id`) but NOT dirty-filtered: reconcile must see clean rows
    /// too, since a remote change lands on a locally-unchanged row. `history_visible`
    /// keeps a merely-browsed search-cache row from being reshaped by a remote list.
    /// Text fields are duped into `arena`.
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

    /// Apply a reconciled pull to one row (ROD-285), but only if the row still holds
    /// the `(expected_status, expected_progress)` pair the merge was computed from.
    /// Sets the merged local (list_status, progress) and advances the sync snapshot to
    /// what AniList now holds, in one guarded UPDATE. Returns `true` when the write
    /// landed, `false` when the guard matched zero rows: a concurrent writer (the TUI's
    /// `recordPlay`/`setListStatus`) moved the row between the bulk `loadReconcileRows`
    /// read and this write. `reconcileAll` merges from a point-in-time snapshot with no
    /// spanning transaction, so without this guard a mid-flight local edit would be
    /// silently clobbered (a lost update); the guard turns that into a skip that
    /// re-reconciles next run.
    ///
    /// The snapshot becomes the *remote* pair (server truth), not the merged pair: if
    /// the merge kept a locally-ahead value, the row then reads dirty against the
    /// snapshot and the next push carries that delta up. Pull sets the baseline to the
    /// server; push closes any remaining local gap.
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
        // ROD-312: same canonical-resolution join as loadHistory — enrichment
        // reads COALESCE(canonical, anime-local), user-state/binding stay local.
        // `history_visible` (index 28) is anime-only and keeps its mid-list slot;
        // column ORDER is unchanged so the fixed-index row builder stays valid.
        const sql =
            \\SELECT anime.source, anime.source_id,
            \\    COALESCE(c.title, anime.title), COALESCE(c.title_english, anime.title_english),
            \\    COALESCE(c.mal_id, anime.mal_id), anime.anilist_id, COALESCE(c.cover_url, anime.cover_url),
            \\    COALESCE(c.year, anime.year), COALESCE(c.status, anime.status), COALESCE(c.description, anime.description),
            \\    COALESCE(c.score, anime.score), COALESCE(c.total_episodes, anime.total_episodes), anime.list_status,
            \\    anime.user_rating, anime.notes, anime.play_count, anime.progress, anime.added_at, anime.last_watched_at,
            \\    COALESCE(c.season, anime.season), COALESCE(c.native_name, anime.native_name), COALESCE(c.kind, anime.kind),
            \\    COALESCE(c.start_year, anime.start_year), COALESCE(c.start_month, anime.start_month), COALESCE(c.start_day, anime.start_day), COALESCE(c.genres, anime.genres),
            \\    COALESCE(c.enrichment_fetched_at, anime.enrichment_fetched_at), COALESCE(c.enrichment_fieldset_version, anime.enrichment_fieldset_version), anime.history_visible, COALESCE(c.studios, anime.studios), COALESCE(c.duration, anime.duration),
            \\    COALESCE(c.source_material, anime.source_material), COALESCE(c.rank, anime.rank), COALESCE(c.rank_type, anime.rank_type), COALESCE(c.rank_year, anime.rank_year),
            \\    COALESCE(c.next_airing_at, anime.next_airing_at), COALESCE(c.next_airing_episode, anime.next_airing_episode), COALESCE(c.country, anime.country)
            \\FROM anime
            \\LEFT JOIN canonical_anime c ON anime.canonical_id = c.anilist_id
            \\WHERE anime.source = ? AND anime.source_id = ?
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

    /// Read the canonical entity for `anilist_id` as an `AnimeRecord` (ROD-327): the
    /// hydrate reader for AniList search hits, which are anilist_id-keyed with no
    /// binding row (`upsertCanonicalOnly`). `source` is empty and `source_id` is the
    /// stringified anilist_id: this is a canonical entity, not a provider binding, so
    /// user-state columns take their record defaults (canonical carries none).
    pub fn getCanonicalByAnilistId(self: *Store, arena: Allocator, anilist_id: i64) Error!?AnimeRecord {
        const sql =
            \\SELECT title, title_english, mal_id, cover_url, year, status, description,
            \\    score, total_episodes, season, native_name, kind, start_year, start_month,
            \\    start_day, genres, enrichment_fetched_at, enrichment_fieldset_version,
            \\    studios, duration, source_material, rank, rank_type, rank_year,
            \\    next_airing_at, next_airing_episode, country
            \\FROM canonical_anime WHERE anilist_id = ?
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindOptI64(stmt, 1, anilist_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return .{
            .source = "",
            .source_id = try std.fmt.allocPrint(arena, "{d}", .{anilist_id}),
            .title = try dupeText(arena, stmt, 0) orelse "",
            .title_english = try dupeText(arena, stmt, 1),
            .mal_id = colOptI64(stmt, 2),
            .anilist_id = anilist_id,
            .cover_url = try dupeText(arena, stmt, 3),
            .year = colOptI64(stmt, 4),
            .status = try dupeText(arena, stmt, 5),
            .description = try dupeText(arena, stmt, 6),
            .score = colOptI64(stmt, 7),
            .total_episodes = colOptI64(stmt, 8),
            .season = try dupeText(arena, stmt, 9),
            .native_name = try dupeText(arena, stmt, 10),
            .kind = try dupeText(arena, stmt, 11),
            .start_year = colOptI64(stmt, 12),
            .start_month = colOptI64(stmt, 13),
            .start_day = colOptI64(stmt, 14),
            .genres = try dupeStrBlob(arena, stmt, 15),
            .enrichment_fetched_at = colOptI64(stmt, 16),
            .enrichment_fieldset_version = colOptI64(stmt, 17),
            .studios = try dupeStrBlob(arena, stmt, 18),
            .duration = colOptI64(stmt, 19),
            .source_material = try dupeText(arena, stmt, 20),
            .rank = colOptI64(stmt, 21),
            .rank_type = try dupeText(arena, stmt, 22),
            .rank_year = colOptI64(stmt, 23),
            .next_airing_at = colOptI64(stmt, 24),
            .next_airing_episode = colOptI64(stmt, 25),
            .country = try dupeText(arena, stmt, 26),
        };
    }

    /// The persisted provider id for `anilist_id` on `source`, or null when this provider
    /// has no binding for that canonical yet (ROD-328, tier 0). The resolver's short-circuit:
    /// a Browse re-search of a show already bound on this provider reuses the stored id
    /// instead of re-deriving (tier A) or re-searching the catalog (tier C, a wasted round
    /// trip and the ROD-309 rate-scoring surface).
    ///
    /// A canonical can carry MORE than one binding on one provider (a MAL multi-cour split
    /// that AniList merges: N mal-keyed senshi rows, one anilist_id; the ROD-313 collapse
    /// case), so this is NOT a unique lookup. It picks the SAME representative loadHistory
    /// surfaces: `history_visible` rows first (loadHistory ranks only visible rows), then
    /// most-recently-watched, then furthest progress, then rowid. So tier 0 replays the cour
    /// the user is actually watching, and never a hidden binding when a visible one exists.
    /// Uses `idx_anime_canonical`. Arena owns the returned string.
    pub fn bindingSourceId(self: *Store, arena: Allocator, source: []const u8, anilist_id: i64) Error!?[]const u8 {
        const stmt = try self.prepare(
            \\SELECT source_id FROM anime
            \\WHERE canonical_id = ? AND source = ?
            \\ORDER BY history_visible DESC, last_watched_at DESC NULLS LAST, progress DESC, rowid
            \\LIMIT 1
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindOptI64(stmt, 1, anilist_id);
        try bindText(stmt, 2, source);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return try dupeText(arena, stmt, 0);
    }

    /// ROD-345: the per-show provider pin, or null when unpinned. Callers layer
    /// this over the global preference (App.effectivePreference); a pin naming a
    /// provider that is no longer registered degrades there via Registry.ordered's
    /// unknown-name contract, so it is returned verbatim here.
    pub fn getProviderPin(self: *Store, arena: Allocator, canonical_id: i64) Error!?[]const u8 {
        const stmt = try self.prepare("SELECT provider FROM provider_pins WHERE canonical_id = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        try bindOptI64(stmt, 1, canonical_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return try dupeText(arena, stmt, 0);
    }

    /// Set (upsert) or clear (null) the per-show provider pin (ROD-345).
    pub fn setProviderPin(self: *Store, canonical_id: i64, provider: ?[]const u8) Error!void {
        const stmt = if (provider == null)
            try self.prepare("DELETE FROM provider_pins WHERE canonical_id = ?;")
        else
            try self.prepare(
                \\INSERT INTO provider_pins (canonical_id, provider) VALUES (?, ?)
                \\ON CONFLICT(canonical_id) DO UPDATE SET provider = excluded.provider
            );
        defer _ = c.sqlite3_finalize(stmt);
        try bindOptI64(stmt, 1, canonical_id);
        if (provider) |p| try bindText(stmt, 2, p);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.Step;
    }

    // ── ROD-347: provider-absence negative cache ─────────────────────────────

    /// How long a persisted "not stocked" verdict stays authoritative. Catalogs
    /// move (a currently-airing show can appear on a provider days after
    /// premiere), so an absence past this window reads as unchecked and the next
    /// resolve or pre-warm re-probes.
    pub const ABSENCE_TTL_SECONDS: i64 = 7 * 24 * 60 * 60;

    /// Persist (or refresh) a definitive "this provider doesn't stock this show"
    /// verdict (ROD-347). Callers must hold the ROD-278 line: only a completed
    /// search/probe with no confident match earns a row here. A transport
    /// failure proves nothing and must not poison the cache.
    pub fn markProviderAbsent(self: *Store, canonical_id: i64, provider: []const u8, now: i64) Error!void {
        const stmt = try self.prepare(
            \\INSERT INTO provider_absences (canonical_id, provider, checked_at) VALUES (?, ?, ?)
            \\ON CONFLICT(canonical_id, provider) DO UPDATE SET checked_at = excluded.checked_at
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindOptI64(stmt, 1, canonical_id);
        try bindText(stmt, 2, provider);
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 3, now));
        try self.stepDone(stmt);
    }

    /// Whether a fresh (within-TTL) absence verdict exists for this
    /// (canonical, provider) pair. A stale row reads false, indistinguishable
    /// from unchecked by design, so consumers re-probe naturally.
    pub fn providerAbsentFresh(self: *Store, canonical_id: i64, provider: []const u8, now: i64) Error!bool {
        const stmt = try self.prepare("SELECT checked_at FROM provider_absences WHERE canonical_id = ? AND provider = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        try bindOptI64(stmt, 1, canonical_id);
        try bindText(stmt, 2, provider);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return false;
        const checked_at = c.sqlite3_column_int64(stmt, 0);
        return now < checked_at + ABSENCE_TTL_SECONDS;
    }

    /// One provider's read-side availability for a canonical (ROD-348): what the
    /// detail rail renders per registry provider.
    pub const ProviderAvailability = enum { unchecked, bound, absent };

    /// Fold the provider picture for one (canonical, provider) pair: `bound` when
    /// any binding row joins the canonical on that source, else `absent` under a
    /// fresh negative, else `unchecked`. Bound is checked first, the same
    /// binding-outranks-negative rule the fallback walk applies; `bindCanonical`
    /// deletes the negative on mint, so a coexisting pair only appears through
    /// external DB edits and must still read as bound.
    pub fn providerAvailability(self: *Store, canonical_id: i64, provider: []const u8, now: i64) Error!ProviderAvailability {
        const stmt = try self.prepare("SELECT 1 FROM anime WHERE canonical_id = ? AND source = ? LIMIT 1;");
        defer _ = c.sqlite3_finalize(stmt);
        try bindOptI64(stmt, 1, canonical_id);
        try bindText(stmt, 2, provider);
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) return .bound;
        if (try self.providerAbsentFresh(canonical_id, provider, now)) return .absent;
        return .unchecked;
    }

    /// Drop the absence row for one (canonical, provider) pair. `bindCanonical`
    /// calls this on every real-source mint so bound and absent can never
    /// coexist; the ROD-345 'v' flip's re-probe lands here too via its mint.
    fn clearProviderAbsence(self: *Store, canonical_id: i64, provider: []const u8) Error!void {
        const stmt = try self.prepare("DELETE FROM provider_absences WHERE canonical_id = ? AND provider = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        try bindOptI64(stmt, 1, canonical_id);
        try bindText(stmt, 2, provider);
        try self.stepDone(stmt);
    }

    /// (list_status, progress high-water, total episodes, still-airing) for one
    /// show, or null if it isn't tracked. `airing` folds the airing-status column
    /// via `domain.isStillAiring` (ROD-296). The minimal read the watch-state
    /// machine needs — no arena, no full AnimeRecord — and a uniform unknown-show
    /// guard for the transition paths.
    const StatusRow = struct { status: domain.ListStatus, progress: i64, total: ?i64, airing: bool };
    fn statusRow(self: *Store, source: []const u8, source_id: []const u8) Error!?StatusRow {
        // `status` is the airing-status text (RELEASING/FINISHED), the "still releasing"
        // signal `afterPlay` gates on (ROD-296); read transiently and folded to a bool.
        // ROD-312: the gate reads its enrichment inputs (total_episodes, status) through
        // the canonical join like loadHistory, so a co-bound entity uses the freshest
        // canonical truth. list_status/progress stay anime-local (user state).
        const stmt = try self.prepare(
            \\SELECT anime.list_status, anime.progress,
            \\    COALESCE(c.total_episodes, anime.total_episodes), COALESCE(c.status, anime.status)
            \\FROM anime
            \\LEFT JOIN canonical_anime c ON anime.canonical_id = c.anilist_id
            \\WHERE anime.source = ? AND anime.source_id = ?
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, source);
        try bindText(stmt, 2, source_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        // Fold the status text to a bool before it escapes — the sqlite pointer is
        // only valid until the next step/finalize, so `isStillAiring` consumes the
        // transient slice here and nothing stores it. NULL status → still airing
        // (isStillAiring's "don't trust an unclassified total" default).
        const status_ptr = c.sqlite3_column_text(stmt, 3);
        const status_opt: ?[]const u8 = if (status_ptr == null) null else blk: {
            const n: usize = @intCast(c.sqlite3_column_bytes(stmt, 3));
            break :blk status_ptr[0..n];
        };
        return .{
            .status = colStatus(stmt, 0),
            .progress = c.sqlite3_column_int64(stmt, 1),
            .total = colOptI64(stmt, 2),
            .airing = domain.isStillAiring(status_opt),
        };
    }

    /// Record a play of `episode_index` (1-based) and advance the watch-state machine
    /// (ROD-139). Always bumps play_count, last_watched_at and history visibility (a
    /// play is a play). The `progress` high-water only advances when `completed`
    /// (ROD-168): a partial watch belongs in history but must not mark the episode
    /// watched-through.
    ///
    /// The new `list_status` comes from `ListStatus.afterPlay`, a pure function of
    /// (current status, post-play progress, total, still-airing); the last input keeps a
    /// mid-broadcast show from auto-completing at the latest aired episode (ROD-296). We
    /// read the row first so the transition is testable Zig, not a SQL CASE. Unknown
    /// show is a silent no-op.
    pub fn recordPlay(self: *Store, source: []const u8, source_id: []const u8, episode_index: i64, now: i64, completed: bool) Error!void {
        const cur = try self.statusRow(source, source_id) orelse return;
        const new_progress = if (completed) @max(cur.progress, episode_index) else cur.progress;
        const new_status = domain.ListStatus.afterPlay(cur.status, new_progress, cur.total, cur.airing);

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
    /// CONTRACT: progress is the 1-based ordinal of the last fully-watched episode
    /// among the rows present (sorted by `EpisodeNumber.sortKey`, matching the detail
    /// grid), NOT a count of watched episodes and NOT an absolute episode number. Only
    /// started episodes have `episode_progress` rows, so gap-watching under-counts on
    /// purpose: eps 3 and 5 fully watched with nothing else stored gives 2. No
    /// fully-watched row gives 0.
    ///
    /// Translation-scoped: `anime.progress` tracks the tracked translation's high-water;
    /// mixing sub and dub rows would give a meaningless combined count. Accepted
    /// limitation (ROD-193): if the session's translation has no rows but another does,
    /// this returns 0. Recompute-only: no `episode_progress` rows are deleted.
    ///
    /// ROD-346: rows are the UNION across sibling bindings through `canonical_id`
    /// (per-episode watched = MAX across siblings), so a freshly-minted fallback
    /// binding recomputes to the show's true high-water instead of 0, which would
    /// otherwise push an AniList progress downgrade (the ROD-323 shape). The
    /// UPDATE still targets only the queried binding. NULL `canonical_id` never
    /// cross-joins (see getResume). Siblings correlate per episode by RAW LABEL:
    /// providers that label the same episode differently ("9" vs "09") count it
    /// twice; the codebase-wide raw-label identity scheme, not a new assumption.
    pub fn recomputeProgress(self: *Store, scratch: Allocator, source: []const u8, source_id: []const u8, tt: domain.Translation) Error!i64 {
        const high_water = try self.unionHighWater(scratch, source, source_id, tt);
        const sql_upd = "UPDATE anime SET progress = ? WHERE source = ? AND source_id = ?";
        const upd = try self.prepare(sql_upd);
        defer _ = c.sqlite3_finalize(upd);
        try checkBind(upd, c.sqlite3_bind_int64(upd, 1, high_water));
        try bindText(upd, 2, source);
        try bindText(upd, 3, source_id);
        try self.stepDone(upd);
        return high_water;
    }

    /// Raise-only twin of `recomputeProgress` for a fallback-walk landing (ROD-346):
    /// never LOWERS the binding's progress, so landing on a force-completed sibling
    /// (the ROD-131 c-key snap, which has no episode_progress rows behind it) can't
    /// silently un-complete it. The exact recompute stays the afterPlay/r-key
    /// contract; this one only closes the "fresh or stale binding under-reads the
    /// union" gap. Returns the binding's resulting progress.
    pub fn raiseProgressToUnion(self: *Store, scratch: Allocator, source: []const u8, source_id: []const u8, tt: domain.Translation) Error!i64 {
        const high_water = try self.unionHighWater(scratch, source, source_id, tt);
        const sql_upd = "UPDATE anime SET progress = MAX(progress, ?) WHERE source = ? AND source_id = ?";
        const upd = try self.prepare(sql_upd);
        defer _ = c.sqlite3_finalize(upd);
        try checkBind(upd, c.sqlite3_bind_int64(upd, 1, high_water));
        try bindText(upd, 2, source);
        try bindText(upd, 3, source_id);
        try self.stepDone(upd);

        const sql_sel = "SELECT progress FROM anime WHERE source = ? AND source_id = ?";
        const sel = try self.prepare(sql_sel);
        defer _ = c.sqlite3_finalize(sel);
        try bindText(sel, 1, source);
        try bindText(sel, 2, source_id);
        return switch (c.sqlite3_step(sel)) {
            c.SQLITE_ROW => c.sqlite3_column_int64(sel, 0),
            c.SQLITE_DONE => high_water, // no binding row: nothing raised, report the union
            else => error.Step,
        };
    }

    /// The cross-sibling watched high-water (see recomputeProgress for the contract);
    /// pure read, shared by the exact and raise-only writers.
    fn unionHighWater(self: *Store, scratch: Allocator, source: []const u8, source_id: []const u8, tt: domain.Translation) Error!i64 {
        // 1. Fetch the union of episode_progress rows across sibling bindings.
        const sql_sel =
            \\SELECT ep.episode, MAX(ep.fully_watched)
            \\FROM episode_progress ep
            \\WHERE ep.translation = ?3
            \\  AND ((ep.source = ?1 AND ep.source_id = ?2)
            \\    OR EXISTS (
            \\      SELECT 1 FROM anime self_row JOIN anime sib
            \\        ON sib.canonical_id = self_row.canonical_id
            \\      WHERE self_row.source = ?1 AND self_row.source_id = ?2
            \\        AND self_row.canonical_id IS NOT NULL
            \\        AND sib.source = ep.source AND sib.source_id = ep.source_id))
            \\GROUP BY ep.episode
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
    ///
    /// ROD-346: reads aggregate across sibling bindings through `canonical_id`
    /// (writes stay per-binding) so watch state follows a show across a provider
    /// fallback/flip. Freshest sibling row wins; the queried binding wins ties.
    /// A NULL `canonical_id` must never cross-join (the ROD-313 lesson: SQLite
    /// would fuse the whole unmatched tail), so the EXISTS arm requires it non-null.
    pub fn getResume(
        self: *Store,
        source: []const u8,
        source_id: []const u8,
        tt: domain.Translation,
        episode: []const u8,
    ) Error!?Resume {
        const sql =
            \\SELECT ep.position_secs, ep.duration_secs, ep.fully_watched
            \\FROM episode_progress ep
            \\WHERE ep.translation = ?3 AND ep.episode = ?4
            \\  AND ((ep.source = ?1 AND ep.source_id = ?2)
            \\    OR EXISTS (
            \\      SELECT 1 FROM anime self_row JOIN anime sib
            \\        ON sib.canonical_id = self_row.canonical_id
            \\      WHERE self_row.source = ?1 AND self_row.source_id = ?2
            \\        AND self_row.canonical_id IS NOT NULL
            \\        AND sib.source = ep.source AND sib.source_id = ep.source_id))
            \\ORDER BY ep.updated_at DESC,
            \\         (ep.source = ?1 AND ep.source_id = ?2) DESC
            \\LIMIT 1
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

    /// TTL in seconds for cached *enrichment metadata* on the `anime` row, keyed off
    /// airing status. A deliberately longer curve than `cacheTtl` (which governs the
    /// episode LIST): a score/synopsis/status flips far slower than a weekly episode
    /// drop, so refresh is conservative. A finished show is all but frozen (30d), an
    /// airing one can flip RELEASING→FINISHED and gain votes (1d), an unknown status
    /// splits the difference (7d). "Never enriched" is not modelled here (that is
    /// `fetched_at == null` in `enrichmentStale`), so a fetched-but-status-null row
    /// still gets 7d of grace instead of re-fetching on every view.
    pub fn enrichmentTtl(airing_status: ?[]const u8) i64 {
        const s = airing_status orelse return 7 * 24 * 60 * 60;
        if (eqIgnoreCase(s, "FINISHED")) return 30 * 24 * 60 * 60;
        if (eqIgnoreCase(s, "RELEASING") or eqIgnoreCase(s, "ongoing")) return 24 * 60 * 60;
        return 7 * 24 * 60 * 60;
    }

    /// Whether a row's persisted enrichment is stale enough to refresh on view.
    /// Stale when ANY of:
    ///   * `fetched_at` is null: never enriched, or a row predating the v6 column
    ///     (also the backfill predicate for pre-ROD-181 rows with no `anilist_id`).
    ///   * `fieldset_version` predates `ENRICHMENT_FIELDSET_VERSION`: the row was filled
    ///     under a narrower column set, so widened columns are missing (null reads as 0).
    ///   * the clock has passed `fetched_at + enrichmentTtl(status)`.
    /// Pure: unit-tested without a DB.
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
    /// `busy_timeout` (ROD-287): when two fresh connections race to promote the journal
    /// to WAL, the loser needs a brief exclusive lock the winner holds, and SQLite does
    /// NOT run the busy handler for that lock upgrade (it could deadlock two mutually
    /// waiting upgraders), so the pragma returns SQLITE_BUSY at once regardless of the
    /// timeout. We retry by hand: the winner finishes in microseconds, then the loser's
    /// retry sees WAL already set and returns without the lock, converging in a round or
    /// two. Bounded so a wedged peer surfaces as error.Exec (best-effort no-store) rather
    /// than hanging open() forever. Uses sqlite3_sleep so the store needn't thread an Io
    /// handle through just for this.
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

    // ── ROD-304 / ROD-308: legacy-provider cutover ───────────────────────────

    /// Re-key `(allanime, opaque)` rows that carry a `mal_id` onto `(senshi, <mal>)`
    /// — the exact transform the v12 schema migration runs, factored out so the
    /// ROD-308 backfill can invoke it again after it populates fresh `mal_id`s over
    /// the network. Runs in its own write transaction; the schema-migration path
    /// instead folds the identical `MIGRATION_V12` SQL into `migrate()`'s ladder txn.
    /// Idempotent: with no eligible allanime rows the temp table is empty and every
    /// statement is a no-op.
    pub fn rekeyLegacyProvider(self: *Store) Error!void {
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        try self.exec(MIGRATION_V12);
        try self.exec("COMMIT;");
    }

    /// AniList ids of the allanime rows that COULD re-key but for a missing `mal_id`
    /// (enriched before `idMal` joined the enrichment fieldset). These are the
    /// ROD-308 backfill's work-list: one deterministic AniList `id -> idMal` lookup
    /// turns each into a migratable row. Returned slice is arena-owned.
    pub fn listBackfillAnilistIds(self: *Store, arena: Allocator) Error![]i64 {
        var ids: std.ArrayList(i64) = .empty;
        const stmt = try self.prepare(
            \\SELECT anilist_id FROM anime
            \\WHERE source = 'allanime' AND anilist_id IS NOT NULL AND mal_id IS NULL
        );
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try ids.append(arena, c.sqlite3_column_int64(stmt, 0));
        }
        return ids.toOwnedSlice(arena);
    }

    /// Stamp a resolved `mal_id` onto the allanime row(s) with this `anilist_id`,
    /// but only where it's still missing — never overwrite an id already present.
    /// Scoped to `source = 'allanime'` so the backfill can't touch already-migrated
    /// senshi rows. A no-op if nothing matches.
    pub fn setMalIdByAnilistId(self: *Store, anilist_id: i64, mal_id: i64) Error!void {
        const stmt = try self.prepare(
            \\UPDATE anime SET mal_id = ?
            \\WHERE source = 'allanime' AND anilist_id = ? AND mal_id IS NULL
        );
        defer _ = c.sqlite3_finalize(stmt);
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 1, mal_id));
        try checkBind(stmt, c.sqlite3_bind_int64(stmt, 2, anilist_id));
        try self.stepDone(stmt);
    }

    /// Count allanime rows still carrying a `mal_id` — rows pending an offline re-key.
    /// The ROD-308 backfill reads this just before `rekeyLegacyProvider` to report how
    /// many rows its network pass made eligible to move onto senshi.
    pub fn countMigratableAllanime(self: *Store) Error!usize {
        const stmt = try self.prepare(
            \\SELECT COUNT(*) FROM anime WHERE source = 'allanime' AND mal_id IS NOT NULL
        );
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.Step;
        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }

    /// Read an `app_meta` value (ROD-308 one-time flags). Arena-owned, null if unset.
    pub fn metaGet(self: *Store, arena: Allocator, key: []const u8) Error!?[]const u8 {
        const stmt = try self.prepare("SELECT value FROM app_meta WHERE key = ?");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, key);
        return switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => try dupeText(arena, stmt, 0),
            c.SQLITE_DONE => null,
            else => error.Step,
        };
    }

    /// Upsert an `app_meta` value (ROD-308 one-time flags).
    pub fn metaSet(self: *Store, key: []const u8, value: []const u8) Error!void {
        const stmt = try self.prepare(
            \\INSERT INTO app_meta (key, value) VALUES (?, ?)
            \\ON CONFLICT(key) DO UPDATE SET value = excluded.value
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, key);
        try bindText(stmt, 2, value);
        try self.stepDone(stmt);
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
        // transaction (ROD-287): BEGIN IMMEDIATE takes the write lock up front, and
        // busy_timeout makes a second opener racing the same schema window wait rather
        // than error with 'duplicate column name'. Atomicity is the prize: the ALTERs
        // and the version bump commit or roll back together, so an interrupted migrate
        // never leaves the half-applied state (columns added, user_version un-bumped)
        // that used to brick every future open. (Prevents new half-applied states; does
        // not heal one an older build already wrote, which needs idempotent ALTERs.)
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
        if (v < 12) {
            try self.exec(MIGRATION_V12);
            v = 12;
        }
        if (v < 13) {
            try self.exec(MIGRATION_V13);
            v = 13;
        }
        if (v < 14) {
            try self.exec(MIGRATION_V14_DDL);
            try self.exec(MIGRATION_V14_BACKFILL);
            v = 14;
        }
        if (v < 15) {
            try self.exec(MIGRATION_V15);
            v = 15;
        }
        if (v < 16) {
            try self.exec(MIGRATION_V16);
            v = 16;
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

// Check a `sqlite3_bind_*` return code, mirroring `prepare`/`stepDone`: a non-OK code
// is logged and surfaced as `error.Bind`, not discarded. A swallowed failure would let
// the statement run with a NULL where a value was expected: silent data corruption.
// Reachable via SQLITE_RANGE (a column index drifting past a schema change) and
// SQLITE_NOMEM/SQLITE_TOOBIG on pathological inputs. The bind helpers hold only a
// `Stmt`, so we recover the owning connection with `sqlite3_db_handle(stmt)`.
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
    // Directly assert `open()` configured a non-zero busy_timeout, the half of the fix that
    // lets a second writer wait out a briefly-held lock instead of erroring at once (the
    // markSynced-vs-checkpoint collision). The query form of `PRAGMA busy_timeout` reads back
    // exactly what `sqlite3_busy_timeout` set, so this fails deterministically if the wiring
    // in `open()` is ever dropped. A prior draft drove a real contention timeout, but that
    // passes on SQLite's own busy mechanics even with our wiring removed (caught in review)
    // and was timing-dependent. Asserting against the const, not a literal, survives a retune.
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
    // FINISHED: total_episodes = 3 is the real finale, so reaching it completes.
    // (A show with no/unsettled status won't auto-complete — that's the ROD-296
    // gate; see the still-airing test below.)
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "a", .title = "A", .total_episodes = 3, .status = "FINISHED" }, 1000, arena);

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

test "recordPlay does not auto-complete a still-airing show at the latest aired episode (ROD-296)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    // A weekly show mid-broadcast: 3 episodes aired so far (total tracks the aired
    // count), AniList status RELEASING → still airing.
    try s.upsertAnime(.{
        .source = T_SOURCE,
        .source_id = "a",
        .title = "A",
        .total_episodes = 3,
        .status = "RELEASING",
    }, 1000, arena);

    // Watching the latest aired episode (progress == aired count) must stay
    // watching, not flip to completed.
    try s.recordPlay(T_SOURCE, "a", 3, 2000, true);
    const airing = (try s.getAnime(arena, T_SOURCE, "a")).?;
    try testing.expectEqual(domain.ListStatus.watching, airing.list_status);
    try testing.expectEqual(@as(i64, 3), airing.progress); // progress still tracked

    // Once the season finishes airing (status → FINISHED, which overwrites
    // RELEASING via the non-null COALESCE, and total is the real finale), the next
    // play that reaches it completes as before.
    try s.upsertAnime(.{
        .source = T_SOURCE,
        .source_id = "a",
        .title = "A",
        .total_episodes = 4,
        .status = "FINISHED",
    }, 1001, arena);
    try s.recordPlay(T_SOURCE, "a", 4, 2001, true);
    try testing.expectEqual(domain.ListStatus.completed, (try s.getAnime(arena, T_SOURCE, "a")).?.list_status);
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

test "upsertEnriched routes id-bearing enrichment onto canonical (mint + link + read-back), M1 skips id-less rows, re-enrich never wipes (ROD-312)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    // Read the UNREAD spine directly — getCanonical() is a later slice.
    const Q = struct {
        fn int(st: *Store, sql: [*c]const u8) !?i64 {
            const stmt = try st.prepare(sql);
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
            if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) return null;
            return c.sqlite3_column_int64(stmt, 0);
        }
        fn text(a: Allocator, st: *Store, sql: [*c]const u8) !?[]const u8 {
            const stmt = try st.prepare(sql);
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
            return dupeText(a, stmt, 0);
        }
    };

    // 1) An id-bearing enrich (anilist_id resolved) mints a canonical entity, stamps it
    //    fresh, and links the binding — then getAnime reads it all back THROUGH canonical
    //    (slice-1 join), closing the write→read loop on the spine.
    const resolved: domain.Anime = .{
        .id = "s1",
        .name = "Resolved",
        .anilist_id = 500,
        .mal_id = 700,
        .score = 88,
        .native_name = "ネイティブ",
        .status = "RELEASING",
        .next_airing_at = 4242,
    };
    try s.upsertEnriched(T_SOURCE, resolved, .sub, true, true, 9000, arena);

    try testing.expectEqual(@as(?i64, 1), try Q.int(&s, "SELECT COUNT(*) FROM canonical_anime;"));
    try testing.expectEqual(@as(?i64, 88), try Q.int(&s, "SELECT score FROM canonical_anime WHERE anilist_id = 500;"));
    try testing.expectEqual(@as(?i64, 700), try Q.int(&s, "SELECT mal_id FROM canonical_anime WHERE anilist_id = 500;"));
    try testing.expectEqual(@as(?i64, 9000), try Q.int(&s, "SELECT enrichment_fetched_at FROM canonical_anime WHERE anilist_id = 500;"));
    try testing.expectEqual(@as(?i64, 500), try Q.int(&s, "SELECT canonical_id FROM anime WHERE source_id = 's1';"));

    const got = (try s.getAnime(arena, T_SOURCE, "s1")).?;
    try testing.expectEqual(@as(?i64, 88), got.score);
    try testing.expectEqualStrings("ネイティブ", got.native_name.?);
    try testing.expectEqual(@as(?i64, 4242), got.next_airing_at);
    try testing.expectEqual(@as(?i64, 9000), got.enrichment_fetched_at);

    // 2) M1 guard: an id-less enrich (an unmatched provider row / a Discover idMal=null)
    //    mints NO canonical row — a NULL PRIMARY KEY insert would fabricate a rowid and a
    //    bogus entity. Its enrichment persists to anime-local and reads back via fallback.
    const unresolved: domain.Anime = .{ .id = "s2", .name = "Unmatched", .score = 55 };
    try s.upsertEnriched(T_SOURCE, unresolved, .sub, true, true, 9000, arena);
    try testing.expectEqual(@as(?i64, 1), try Q.int(&s, "SELECT COUNT(*) FROM canonical_anime;")); // still just the one
    try testing.expectEqual(@as(?i64, null), try Q.int(&s, "SELECT canonical_id FROM anime WHERE source_id = 's2';"));
    try testing.expectEqual(@as(?i64, 55), (try s.getAnime(arena, T_SOURCE, "s2")).?.score);

    // 3) Re-enrich never wipes canonical: a partial refresh (no score, fresh romaji +
    //    status + stamp) preserves the prior score via COALESCE, refreshes the title
    //    (real romaji wins — see the dedicated no-downgrade test for the seed-only
    //    case), lets the fresh non-null status win, and advances the clock.
    const partial: domain.Anime = .{ .id = "s1", .name = "Resolved v2", .title_romaji = "Resolved v2", .anilist_id = 500, .status = "FINISHED" };
    try s.upsertEnriched(T_SOURCE, partial, .sub, true, true, 12000, arena);
    try testing.expectEqual(@as(?i64, 88), try Q.int(&s, "SELECT score FROM canonical_anime WHERE anilist_id = 500;"));
    try testing.expectEqualStrings("Resolved v2", (try Q.text(arena, &s, "SELECT title FROM canonical_anime WHERE anilist_id = 500;")).?);
    try testing.expectEqualStrings("FINISHED", (try Q.text(arena, &s, "SELECT status FROM canonical_anime WHERE anilist_id = 500;")).?);
    try testing.expectEqual(@as(?i64, 12000), try Q.int(&s, "SELECT enrichment_fetched_at FROM canonical_anime WHERE anilist_id = 500;"));
}

test "upsertCanonicalOnly persists a search hit as a canonical entity with no binding row (ROD-326)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    const Q = struct {
        fn int(st: *Store, sql: [*c]const u8) !?i64 {
            const stmt = try st.prepare(sql);
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
            if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) return null;
            return c.sqlite3_column_int64(stmt, 0);
        }
        fn text(al: Allocator, st: *Store, sql: [*c]const u8) !?[]const u8 {
            const stmt = try st.prepare(sql);
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
            return dupeText(al, stmt, 0);
        }
    };

    // A raw discovery-search hit: full AniList metadata, `id` = the stringified anilist_id.
    // name != title_romaji on purpose, so the canonical title-heal below is observable.
    const hit: domain.Anime = .{
        .id = "182255",
        .name = "Frieren Beyond Journeys End",
        .title_romaji = "Sousou no Frieren",
        .english_name = "Frieren",
        .anilist_id = 182255,
        .mal_id = 52991,
        .score = 89,
        .season = .fall,
        .genres = &.{ "Adventure", "Fantasy" },
    };
    try s.upsertCanonicalOnly(hit, false, 0, arena);

    // Canonical entity minted (title healed to romaji), carrying the hit's enrichment.
    try testing.expectEqual(@as(?i64, 1), try Q.int(&s, "SELECT COUNT(*) FROM canonical_anime;"));
    try testing.expectEqual(@as(?i64, 52991), try Q.int(&s, "SELECT mal_id FROM canonical_anime WHERE anilist_id = 182255;"));
    try testing.expectEqual(@as(?i64, 89), try Q.int(&s, "SELECT score FROM canonical_anime WHERE anilist_id = 182255;"));
    try testing.expectEqualStrings("Sousou no Frieren", (try Q.text(arena, &s, "SELECT title FROM canonical_anime WHERE anilist_id = 182255;")).?);

    // No binding row: canonical-only is the point. loadHistory needs a binding, stays empty.
    try testing.expectEqual(@as(?i64, 0), try Q.int(&s, "SELECT COUNT(*) FROM anime;"));
    try testing.expectEqual(@as(usize, 0), (try s.loadHistory(arena)).len);
}

test "getCanonicalByAnilistId reads a hit back; bindCanonical mints a linked binding (ROD-327)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    const Q = struct {
        fn int(st: *Store, sql: [*c]const u8) !?i64 {
            const stmt = try st.prepare(sql);
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
            if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) return null;
            return c.sqlite3_column_int64(stmt, 0);
        }
    };

    // Persist a search hit as canonical-only (the ROD-326 search-persist path).
    const hit: domain.Anime = .{
        .id = "182255",
        .name = "Frieren",
        .title_romaji = "Sousou no Frieren",
        .anilist_id = 182255,
        .mal_id = 52991,
        .score = 89,
        .total_episodes = 28,
    };
    // Full field set → stamp fresh (see upsertCanonicalOnly's doc for the gate contract).
    try s.upsertCanonicalOnly(hit, true, 7000, arena);
    try testing.expectEqual(@as(?i64, 7000), try Q.int(&s, "SELECT enrichment_fetched_at FROM canonical_anime WHERE anilist_id = 182255;"));

    // The hydrate reader returns the entity keyed by anilist_id, no binding needed.
    const canon = (try s.getCanonicalByAnilistId(arena, 182255)).?;
    try testing.expectEqualStrings("Sousou no Frieren", canon.title);
    try testing.expectEqual(@as(?i64, 52991), canon.mal_id);
    try testing.expectEqual(@as(?i64, 182255), canon.anilist_id);
    try testing.expectEqual(@as(?i64, 89), canon.score);
    try testing.expectEqual(@as(?i64, 28), canon.total_episodes);
    try testing.expectEqual(@as(?i64, 7000), canon.enrichment_fetched_at);
    // An unknown id reads null (the miss the resolver treats as "not canonical yet").
    try testing.expect((try s.getCanonicalByAnilistId(arena, 999999)) == null);

    // Binding an id with no canonical row writes nothing and returns false (the honest
    // no-op the resolver callers must not report as success).
    try testing.expect(!(try s.bindCanonical("senshi", "404", 999999, true, 500, arena)));
    try testing.expectEqual(@as(?i64, 0), try Q.int(&s, "SELECT COUNT(*) FROM anime;"));

    // Tier-A resolve: senshi keys by the stringified mal_id. A first bind mints the
    // binding hidden (a Play resolve; recordPlay reveals it later) and returns true.
    try testing.expect(try s.bindCanonical("senshi", "52991", 182255, false, 1000, arena));
    try testing.expectEqual(@as(?i64, 1), try Q.int(&s, "SELECT COUNT(*) FROM anime;"));
    try testing.expectEqual(@as(?i64, 182255), try Q.int(&s, "SELECT canonical_id FROM anime WHERE source='senshi' AND source_id='52991';"));
    try testing.expectEqual(@as(?i64, 0), try Q.int(&s, "SELECT history_visible FROM anime WHERE source='senshi' AND source_id='52991';"));
    // Hidden binding stays out of History; the join still resolves title via canonical.
    try testing.expectEqual(@as(usize, 0), (try s.loadHistory(arena)).len);

    // A second bind that reveals (the Add path) surfaces one History row, enriched
    // through canonical (MAX-merged visibility), still a single binding row.
    try testing.expect(try s.bindCanonical("senshi", "52991", 182255, true, 2000, arena));
    try testing.expectEqual(@as(?i64, 1), try Q.int(&s, "SELECT COUNT(*) FROM anime;"));
    const hist = try s.loadHistory(arena);
    try testing.expectEqual(@as(usize, 1), hist.len);
    try testing.expectEqualStrings("Sousou no Frieren", hist[0].title);
    try testing.expectEqual(@as(?i64, 52991), hist[0].mal_id);
    try testing.expectEqual(@as(?i64, 89), hist[0].score);
}

test "markUnbound persists a visible sentinel keyed on the anilist_id, idempotent (ROD-329)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    const Q = struct {
        fn int(st: *Store, sql: [*c]const u8) !?i64 {
            const stmt = try st.prepare(sql);
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
            if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) return null;
            return c.sqlite3_column_int64(stmt, 0);
        }
    };

    // No canonical row yet: markUnbound is an honest no-op (false) that writes nothing
    // (the same guard as bindCanonical, since it routes through it).
    try testing.expect(!(try s.markUnbound(182255, 500, arena)));
    try testing.expectEqual(@as(?i64, 0), try Q.int(&s, "SELECT COUNT(*) FROM anime;"));

    try s.upsertCanonicalOnly(.{
        .id = "182255",
        .name = "Frieren",
        .title_romaji = "Sousou no Frieren",
        .anilist_id = 182255,
        .mal_id = 52991,
    }, true, 7000, arena);

    // Sentinel mints and surfaces as one History card (title resolved through the
    // canonical join).
    try testing.expect(try s.markUnbound(182255, 1000, arena));
    try testing.expectEqual(@as(?i64, 1), try Q.int(&s, "SELECT COUNT(*) FROM anime WHERE source='unbound';"));
    try testing.expectEqual(@as(?i64, 182255), try Q.int(&s, "SELECT canonical_id FROM anime WHERE source='unbound' AND source_id='182255';"));
    try testing.expectEqual(@as(?i64, 1), try Q.int(&s, "SELECT history_visible FROM anime WHERE source='unbound' AND source_id='182255';"));
    const hist = try s.loadHistory(arena);
    try testing.expectEqual(@as(usize, 1), hist.len);
    try testing.expectEqualStrings("Sousou no Frieren", hist[0].title);
    try testing.expectEqualStrings("unbound", hist[0].source);

    // Re-run is idempotent (ON CONFLICT preserves the row): still exactly one binding.
    try testing.expect(try s.markUnbound(182255, 2000, arena));
    try testing.expectEqual(@as(?i64, 1), try Q.int(&s, "SELECT COUNT(*) FROM anime;"));
}

test "a real provider bind supersedes the unbound sentinel and inherits its visibility (ROD-329)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    const Q = struct {
        fn int(st: *Store, sql: [*c]const u8) !?i64 {
            const stmt = try st.prepare(sql);
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
            if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) return null;
            return c.sqlite3_column_int64(stmt, 0);
        }
    };

    try s.upsertCanonicalOnly(.{
        .id = "182255",
        .name = "Frieren",
        .title_romaji = "Sousou no Frieren",
        .anilist_id = 182255,
        .mal_id = 52991,
    }, true, 7000, arena);

    // Add-time miss: the show enters History as an unbound sentinel.
    try testing.expect(try s.markUnbound(182255, 1000, arena));
    try testing.expectEqual(@as(usize, 1), (try s.loadHistory(arena)).len);

    // The provider later stocks it; a re-resolve mints the real binding. Bind HIDDEN
    // (the Play path mints hidden, revealed by recordPlay) to prove the sentinel's
    // visibility is inherited; otherwise the show would vanish from History.
    try testing.expect(try s.bindCanonical("senshi", "52991", 182255, false, 2000, arena));

    try testing.expectEqual(@as(?i64, 0), try Q.int(&s, "SELECT COUNT(*) FROM anime WHERE source='unbound';"));
    try testing.expectEqual(@as(?i64, 1), try Q.int(&s, "SELECT COUNT(*) FROM anime;"));
    try testing.expectEqual(@as(?i64, 1), try Q.int(&s, "SELECT history_visible FROM anime WHERE source='senshi';"));

    const hist = try s.loadHistory(arena);
    try testing.expectEqual(@as(usize, 1), hist.len);
    try testing.expectEqualStrings("senshi", hist[0].source);
    try testing.expectEqualStrings("52991", hist[0].source_id);
    try testing.expectEqualStrings("Sousou no Frieren", hist[0].title);
}

test "bindCanonical does not force-reveal a hidden bind when no sentinel was superseded (ROD-329)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    const Q = struct {
        fn int(st: *Store, sql: [*c]const u8) !?i64 {
            const stmt = try st.prepare(sql);
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
            if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) return null;
            return c.sqlite3_column_int64(stmt, 0);
        }
    };

    try s.upsertCanonicalOnly(.{
        .id = "182255",
        .name = "Frieren",
        .title_romaji = "Sousou no Frieren",
        .anilist_id = 182255,
        .mal_id = 52991,
    }, true, 7000, arena);

    // No sentinel exists, so a hidden Play-path bind must stay hidden; the supersede
    // path must not become a blanket "always reveal".
    try testing.expect(try s.bindCanonical("senshi", "52991", 182255, false, 1000, arena));
    try testing.expectEqual(@as(?i64, 0), try Q.int(&s, "SELECT history_visible FROM anime WHERE source='senshi';"));
    try testing.expectEqual(@as(usize, 0), (try s.loadHistory(arena)).len);
}

test "bindingSourceId returns an existing provider binding by canonical id, null otherwise (ROD-328 tier 0)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    try s.upsertCanonicalOnly(.{
        .id = "182255",
        .name = "Frieren",
        .title_romaji = "Sousou no Frieren",
        .anilist_id = 182255,
        .mal_id = 52991,
    }, true, 7000, arena);

    // No binding yet → null (the resolver falls through to tier A / tier C).
    try testing.expect((try s.bindingSourceId(arena, "senshi", 182255)) == null);

    // After a resolve persists the binding, the stored provider id comes back.
    try testing.expect(try s.bindCanonical("senshi", "52991", 182255, false, 1000, arena));
    const sid = (try s.bindingSourceId(arena, "senshi", 182255)).?;
    try testing.expectEqualStrings("52991", sid);

    // Scoped to the provider: a different play source has its own binding space.
    try testing.expect((try s.bindingSourceId(arena, "anipub", 182255)) == null);
    // And to the canonical: an unbound anilist_id is still null.
    try testing.expect((try s.bindingSourceId(arena, "senshi", 999999)) == null);
}

test "bindingSourceId picks loadHistory's representative when a canonical has several bindings on one provider (ROD-328)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    // A MAL multi-cour split AniList merges: two senshi bindings, one canonical (the ROD-313
    // case). tier-0 must NOT pick arbitrarily; it reuses the same representative loadHistory
    // surfaces: most-recently-watched first, so the cour the user is actively on wins even
    // when the other has more raw progress.
    try s.exec("INSERT INTO canonical_anime (anilist_id, title) VALUES (901, 'Spice and Wolf');");
    try s.upsertAnime(.{
        .source = "senshi",
        .source_id = "cour1",
        .title = "Spice and Wolf",
        .anilist_id = 901,
        .canonical_id = 901,
        .progress = 8,
        .last_watched_at = 1000,
        .history_visible = true,
    }, 1000, arena);
    try s.upsertAnime(.{
        .source = "senshi",
        .source_id = "cour2",
        .title = "Spice and Wolf",
        .anilist_id = 901,
        .canonical_id = 901,
        .progress = 2,
        .last_watched_at = 5000,
        .history_visible = true,
    }, 1001, arena);

    // cour2 was watched more recently (5000 > 1000), so it is the representative despite
    // cour1's higher progress: last_watched_at is the primary sort, progress only a tiebreak.
    try testing.expectEqualStrings("cour2", (try s.bindingSourceId(arena, "senshi", 901)).?);

    // A hidden binding, even watched more recently than every visible one, must NOT be
    // picked: loadHistory ranks only visible rows, so tier 0 matches by preferring visible
    // first. cour3 (hidden, lwa 9000) outranks cour2 on recency but stays unpicked.
    try s.upsertAnime(.{
        .source = "senshi",
        .source_id = "cour3",
        .title = "Spice and Wolf",
        .anilist_id = 901,
        .canonical_id = 901,
        .progress = 1,
        .last_watched_at = 9000,
        .history_visible = false,
    }, 1002, arena);
    try testing.expectEqualStrings("cour2", (try s.bindingSourceId(arena, "senshi", 901)).?);
}

test "provider pin: set, overwrite, clear, and per-canonical isolation (ROD-345)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    try s.exec("INSERT INTO canonical_anime (anilist_id, title) VALUES (901, 'Frieren');");
    try s.exec("INSERT INTO canonical_anime (anilist_id, title) VALUES (902, 'Apothecary');");

    // Unpinned reads null; the caller falls through to the global preference.
    try testing.expect((try s.getProviderPin(arena, 901)) == null);

    try s.setProviderPin(901, "anipub");
    try testing.expectEqualStrings("anipub", (try s.getProviderPin(arena, 901)).?);
    // Keyed per canonical: the sibling show stays unpinned.
    try testing.expect((try s.getProviderPin(arena, 902)) == null);

    // Re-pin overwrites (the cycle affordance flips through providers).
    try s.setProviderPin(901, "senshi");
    try testing.expectEqualStrings("senshi", (try s.getProviderPin(arena, 901)).?);

    // Clear returns the show to the global order; clearing twice is a no-op.
    try s.setProviderPin(901, null);
    try testing.expect((try s.getProviderPin(arena, 901)) == null);
    try s.setProviderPin(901, null);
    try testing.expect((try s.getProviderPin(arena, 901)) == null);
}

test "provider absence: mark, TTL, refresh, isolation; bindCanonical clears it (ROD-347)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    try s.exec("INSERT INTO canonical_anime (anilist_id, mal_id, title) VALUES (901, 111, 'Frieren');");
    try s.exec("INSERT INTO canonical_anime (anilist_id, mal_id, title) VALUES (902, 222, 'Apothecary');");

    // No row reads unchecked.
    try testing.expect(!(try s.providerAbsentFresh(901, "anipub", 1000)));

    // A verdict is fresh strictly inside the TTL window and stale at the edge;
    // stale is indistinguishable from unchecked, so consumers re-probe.
    try s.markProviderAbsent(901, "anipub", 1000);
    try testing.expect(try s.providerAbsentFresh(901, "anipub", 1000));
    try testing.expect(try s.providerAbsentFresh(901, "anipub", 1000 + Store.ABSENCE_TTL_SECONDS - 1));
    try testing.expect(!(try s.providerAbsentFresh(901, "anipub", 1000 + Store.ABSENCE_TTL_SECONDS)));

    // Re-marking refreshes the clock (a re-probe that misses again re-arms the TTL).
    try s.markProviderAbsent(901, "anipub", 5000);
    try testing.expect(try s.providerAbsentFresh(901, "anipub", 5000 + Store.ABSENCE_TTL_SECONDS - 1));

    // Keyed per (canonical, provider): neither the sibling show nor a sibling
    // provider inherits the verdict.
    try testing.expect(!(try s.providerAbsentFresh(902, "anipub", 5000)));
    try testing.expect(!(try s.providerAbsentFresh(901, "senshi", 5000)));

    // A real mint proves stock: bindCanonical deletes the negative (the
    // bound-and-absent-never-coexist invariant), including the 'v' flip's
    // successful re-probe.
    try testing.expect(try s.bindCanonical("anipub", "2454", 901, false, 6000, arena));
    try testing.expect(!(try s.providerAbsentFresh(901, "anipub", 6000)));
    const stmt = try s.prepare("SELECT COUNT(*) FROM provider_absences WHERE canonical_id = 901;");
    defer _ = c.sqlite3_finalize(stmt);
    try testing.expect(c.sqlite3_step(stmt) == c.SQLITE_ROW);
    try testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(stmt, 0));

    // The unbound sentinel is not a provider verdict: marking a show unbound
    // leaves every provider's negative standing.
    try s.markProviderAbsent(902, "senshi", 7000);
    try testing.expect(try s.markUnbound(902, 7000, arena));
    try testing.expect(try s.providerAbsentFresh(902, "senshi", 7000));
}

test "providerAvailability folds bound/absent/unchecked, bound first (ROD-348)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    try s.exec("INSERT INTO canonical_anime (anilist_id, mal_id, title) VALUES (901, 111, 'Frieren');");

    // Virgin identity: nothing known about any provider.
    try testing.expectEqual(Store.ProviderAvailability.unchecked, try s.providerAvailability(901, "senshi", 1000));

    // A fresh negative reads absent; past the TTL it degrades to unchecked
    // (stale = indistinguishable from unchecked, the re-probe contract).
    try s.markProviderAbsent(901, "anipub", 1000);
    try testing.expectEqual(Store.ProviderAvailability.absent, try s.providerAvailability(901, "anipub", 1000));
    try testing.expectEqual(Store.ProviderAvailability.unchecked, try s.providerAvailability(901, "anipub", 1000 + Store.ABSENCE_TTL_SECONDS));

    // A binding reads bound, and only for its own source.
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    try testing.expect(try s.bindCanonical("senshi", "111", 901, false, 2000, scratch.allocator()));
    try testing.expectEqual(Store.ProviderAvailability.bound, try s.providerAvailability(901, "senshi", 2000));
    try testing.expectEqual(Store.ProviderAvailability.absent, try s.providerAvailability(901, "anipub", 2000));

    // Bound outranks a lingering negative (externally-edited DB shape; the
    // mint path deletes the negative, so force the row back in by hand).
    try s.exec("INSERT INTO provider_absences (canonical_id, provider, checked_at) VALUES (901, 'senshi', 2000);");
    try testing.expectEqual(Store.ProviderAvailability.bound, try s.providerAvailability(901, "senshi", 2000));

    // The unbound sentinel is not a registry provider: a show carrying ONLY the
    // sentinel still reads unchecked for every real provider.
    try s.exec("INSERT INTO canonical_anime (anilist_id, mal_id, title) VALUES (902, 222, 'Apothecary');");
    try testing.expect(try s.markUnbound(902, 3000, arena));
    try testing.expectEqual(Store.ProviderAvailability.unchecked, try s.providerAvailability(902, "senshi", 3000));
}

test "a hidden bindCanonical mint never enters the sync push set (ROD-351)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    try s.exec("INSERT INTO canonical_anime (anilist_id, mal_id, title) VALUES (901, 111, 'Frieren');");

    // The pre-warm's sibling mint is hidden; loadDirtyForSync gates on
    // history_visible, so a background mint can never push a default status
    // over the user's real AniList entry (the ROD-323 shape stays dormant
    // until a play reveals the row).
    try testing.expect(try s.bindCanonical("anipub", "2454", 901, false, 1000, arena));
    try testing.expectEqual(@as(usize, 0), (try s.loadDirtyForSync(arena)).len);

    // Contrast pin: the same binding revealed IS push-eligible. Visibility is
    // the gate, not anything about how the row was minted.
    try testing.expect(try s.bindCanonical("anipub", "2454", 901, true, 2000, arena));
    try testing.expectEqual(@as(usize, 1), (try s.loadDirtyForSync(arena)).len);
}

test "romaji heals canonical.title; anime-local title stays the provider seed; no-romaji falls back to seed (ROD-312)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    const Q = struct {
        fn text(a: Allocator, st: *Store, sql: [*c]const u8) !?[]const u8 {
            const stmt = try st.prepare(sql);
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
            return dupeText(a, stmt, 0);
        }
    };

    // An id-bearing enrich carries BOTH the provider display name and true romaji.
    const show: domain.Anime = .{
        .id = "f1",
        .name = "Frieren Beyond Journeys End", // provider display seed
        .title_romaji = "Sousou no Frieren", // AniList romaji
        .anilist_id = 182255,
    };
    try s.upsertEnriched(T_SOURCE, show, .sub, true, true, 9000, arena);

    // canonical.title heals to romaji; the anime-local column keeps the seed as fallback.
    try testing.expectEqualStrings("Sousou no Frieren", (try Q.text(arena, &s, "SELECT title FROM canonical_anime WHERE anilist_id = 182255;")).?);
    try testing.expectEqualStrings("Frieren Beyond Journeys End", (try Q.text(arena, &s, "SELECT title FROM anime WHERE source_id = 'f1';")).?);
    // The read path surfaces the healed romaji (COALESCE picks canonical.title).
    try testing.expectEqualStrings("Sousou no Frieren", (try s.getAnime(arena, T_SOURCE, "f1")).?.title);

    // A resolved show with NO romaji falls back to the provider seed on canonical too
    // (the `orelse` guard) — never a NULL title.
    const no_romaji: domain.Anime = .{ .id = "f2", .name = "Only Seed", .anilist_id = 999 };
    try s.upsertEnriched(T_SOURCE, no_romaji, .sub, true, true, 9000, arena);
    try testing.expectEqualStrings("Only Seed", (try Q.text(arena, &s, "SELECT title FROM canonical_anime WHERE anilist_id = 999;")).?);
}

test "canonical title never downgrades: a seed-only re-persist after a heal keeps romaji; a later real romaji still refreshes; empty romaji is ignored (ROD-312)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    const Q = struct {
        fn text(a: Allocator, st: *Store, sql: [*c]const u8) !?[]const u8 {
            const stmt = try st.prepare(sql);
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
            return dupeText(a, stmt, 0);
        }
    };
    const canon = "SELECT title FROM canonical_anime WHERE anilist_id = 700;";

    // Heal: a full enrich carries romaji.
    try s.upsertEnriched(T_SOURCE, .{ .id = "d1", .name = "Provider Seed", .title_romaji = "Romaji Title", .anilist_id = 700 }, .sub, true, true, 1000, arena);
    try testing.expectEqualStrings("Romaji Title", (try Q.text(arena, &s, canon)).?);

    // The regression review caught: a seed-only re-persist (a Discover/search
    // hydrate-then-persist — anilist_id backfilled, NO romaji) must NOT clobber the
    // healed title back to the provider seed. Ordinary, frequent path.
    try s.upsertEnriched(T_SOURCE, .{ .id = "d1", .name = "Provider Seed", .anilist_id = 700 }, .sub, true, true, 2000, arena);
    try testing.expectEqualStrings("Romaji Title", (try Q.text(arena, &s, canon)).?);

    // An empty-string romaji counts as no-romaji — never blanks the surfaced title.
    try s.upsertEnriched(T_SOURCE, .{ .id = "d1", .name = "Provider Seed", .title_romaji = "", .anilist_id = 700 }, .sub, true, true, 2500, arena);
    try testing.expectEqualStrings("Romaji Title", (try Q.text(arena, &s, canon)).?);

    // A later REAL romaji still refreshes — romaji always wins; only seeds are ignored.
    try s.upsertEnriched(T_SOURCE, .{ .id = "d1", .name = "Provider Seed", .title_romaji = "Romaji Fixed", .anilist_id = 700 }, .sub, true, true, 3000, arena);
    try testing.expectEqualStrings("Romaji Fixed", (try Q.text(arena, &s, canon)).?);

    // Bootstrap: a brand-new canonical row with NO romaji still gets a title (the seed),
    // never NULL — and a romaji then upgrades it.
    try s.upsertEnriched(T_SOURCE, .{ .id = "d2", .name = "Only Seed", .anilist_id = 800 }, .sub, true, true, 1000, arena);
    try testing.expectEqualStrings("Only Seed", (try Q.text(arena, &s, "SELECT title FROM canonical_anime WHERE anilist_id = 800;")).?);
    try s.upsertEnriched(T_SOURCE, .{ .id = "d2", .name = "Only Seed", .title_romaji = "Seed Romaji", .anilist_id = 800 }, .sub, true, true, 2000, arena);
    try testing.expectEqualStrings("Seed Romaji", (try Q.text(arena, &s, "SELECT title FROM canonical_anime WHERE anilist_id = 800;")).?);
}

test "afterPlay completion gate reads airing status through canonical, not the local shadow (ROD-312/ROD-296)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    // Canonical holds the fresher truth: the show FINISHED airing. The binding's own
    // shadow still says RELEASING — the stale per-binding value a provider swap strands.
    // (Constructed by hand; single-provider dual-write can't diverge them today.)
    try s.exec("INSERT INTO canonical_anime (anilist_id, title, status, total_episodes) VALUES (700, 'X', 'FINISHED', 12);");
    try s.upsertAnime(.{
        .source = T_SOURCE,
        .source_id = "g",
        .title = "X",
        .anilist_id = 700,
        .canonical_id = 700,
        .status = "RELEASING",
        .total_episodes = 12,
        .list_status = .watching,
        .progress = 11,
        .history_visible = true,
    }, 1, arena);

    // Play the final episode. The gate must read canonical's FINISHED (not airing) and
    // auto-complete; reading the anime-local RELEASING would keep it .watching (ROD-296).
    try s.recordPlay(T_SOURCE, "g", 12, 2, true);
    try testing.expectEqual(domain.ListStatus.completed, (try s.getAnime(arena, T_SOURCE, "g")).?.list_status);
}

test "loadHistory collapses two bindings of one canonical entity to a single card (ROD-313)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    // One show, two provider bindings resolving UP to the same canonical entity — a
    // senshi sub/dub split, or senshi + a future anipub. Both tracked (visible). The
    // user watched the sub most recently (last_watched 5000, ep 12); the dub is the
    // older touch (4000, ep 3).
    try s.exec("INSERT INTO canonical_anime (anilist_id, title) VALUES (900, 'Frieren');");
    try s.upsertAnime(.{
        .source = "senshi",
        .source_id = "sub",
        .title = "Frieren",
        .anilist_id = 900,
        .canonical_id = 900,
        .list_status = .watching,
        .progress = 12,
        .last_watched_at = 5000,
        .history_visible = true,
    }, 1000, arena);
    try s.upsertAnime(.{
        .source = "senshi",
        .source_id = "dub",
        .title = "Frieren",
        .anilist_id = 900,
        .canonical_id = 900,
        .list_status = .watching,
        .progress = 3,
        .last_watched_at = 4000,
        .history_visible = true,
    }, 1001, arena);
    try s.saveProgress("senshi", "sub", .sub, "12", 300, 1400, 5000);
    try s.saveProgress("senshi", "dub", .dub, "3", 120, 1400, 4000);

    // One card, not two.
    const rows = try s.loadHistory(arena);
    try testing.expectEqual(@as(usize, 1), rows.len);

    // The representative is the most-recently-watched binding (the sub), so the card's
    // resume key and progress come from it — not the dub.
    try testing.expectEqualStrings("sub", rows[0].source_id);
    try testing.expectEqual(@as(i64, 12), rows[0].progress);

    // Display-only: both bindings' rows and their resume state are untouched.
    try testing.expect((try s.getAnime(arena, "senshi", "sub")) != null);
    try testing.expect((try s.getAnime(arena, "senshi", "dub")) != null);
    try testing.expect((try s.getResume("senshi", "sub", .sub, "12")) != null);
    try testing.expect((try s.getResume("senshi", "dub", .dub, "3")) != null);
}

test "loadHistory does not collapse the unmatched (NULL canonical_id) tail into one card (ROD-313)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    // Two distinct unmatched shows — no anilist_id, no canonical binding. SQLite groups
    // all NULLs together, so a bare `GROUP BY canonical_id` would fuse these (and the
    // whole real-library tail) into a single card. The -rowid fallback keeps them apart.
    try s.upsertAnime(.{ .source = "senshi", .source_id = "u1", .title = "Unmatched One", .history_visible = true }, 1000, arena);
    try s.upsertAnime(.{ .source = "senshi", .source_id = "u2", .title = "Unmatched Two", .history_visible = true }, 1001, arena);

    try testing.expectEqual(@as(usize, 2), (try s.loadHistory(arena)).len);
}

test "loadHistory representative pick is deterministic on a never-played tie (ROD-313)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    // Two bindings of one canonical entity, both freshly added and never played — the
    // natural planning state, and the case where last_watched_at ties at NULL across the
    // whole group. The representative must still resolve deterministically: progress is
    // the tiebreak below last_watched, so the furthest-progress binding wins, never an
    // arbitrary row.
    try s.exec("INSERT INTO canonical_anime (anilist_id, title) VALUES (901, 'Spice and Wolf');");
    try s.upsertAnime(.{
        .source = "senshi",
        .source_id = "low",
        .title = "Spice and Wolf",
        .anilist_id = 901,
        .canonical_id = 901,
        .list_status = .planning,
        .progress = 2,
        .history_visible = true,
    }, 1000, arena);
    try s.upsertAnime(.{
        .source = "senshi",
        .source_id = "high",
        .title = "Spice and Wolf",
        .anilist_id = 901,
        .canonical_id = 901,
        .list_status = .planning,
        .progress = 7,
        .history_visible = true,
    }, 1001, arena);

    const rows = try s.loadHistory(arena);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("high", rows[0].source_id);
    try testing.expectEqual(@as(i64, 7), rows[0].progress);
}

test "loadHistory collapses a co-bound group and keeps the unmatched tail in one call (ROD-313)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    // One loadHistory call exercising both paths at once: a three-binding co-bound group
    // (collapses to one card) alongside two independent unmatched rows (stay separate).
    // Expect 1 + 2 = 3 cards — proving the collapse and the -rowid tail-guard coexist in
    // a single query, not just in isolation.
    try s.exec("INSERT INTO canonical_anime (anilist_id, title) VALUES (902, 'Vinland Saga');");
    try s.upsertAnime(.{ .source = "senshi", .source_id = "b1", .title = "Vinland Saga", .anilist_id = 902, .canonical_id = 902, .progress = 1, .last_watched_at = 3000, .history_visible = true }, 1000, arena);
    try s.upsertAnime(.{ .source = "senshi", .source_id = "b2", .title = "Vinland Saga", .anilist_id = 902, .canonical_id = 902, .progress = 9, .last_watched_at = 9000, .history_visible = true }, 1001, arena);
    try s.upsertAnime(.{ .source = "senshi", .source_id = "b3", .title = "Vinland Saga", .anilist_id = 902, .canonical_id = 902, .progress = 4, .last_watched_at = 5000, .history_visible = true }, 1002, arena);
    try s.upsertAnime(.{ .source = "senshi", .source_id = "u1", .title = "Unmatched One", .history_visible = true }, 1003, arena);
    try s.upsertAnime(.{ .source = "senshi", .source_id = "u2", .title = "Unmatched Two", .history_visible = true }, 1004, arena);

    const rows = try s.loadHistory(arena);
    try testing.expectEqual(@as(usize, 3), rows.len);

    // The group's representative is its most-recently-watched binding (b2); neither of
    // the other two bindings of that group surfaces as its own card.
    var found_rep = false;
    for (rows) |r| {
        if (std.mem.eql(u8, r.source_id, "b2")) {
            found_rep = true;
            try testing.expectEqual(@as(i64, 9), r.progress);
        }
        try testing.expect(!std.mem.eql(u8, r.source_id, "b1"));
        try testing.expect(!std.mem.eql(u8, r.source_id, "b3"));
    }
    try testing.expect(found_rep);
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
    // recomputeProgress contract: progress = 1-based index of the last fully-watched row
    // among the rows PRESENT in episode_progress, sorted by sortKey. Episodes never started
    // are absent from episode_progress, by design. Gap-watching (only eps 3 and 5 present,
    // both fully_watched, no rows for 1/2/4) yields high_water = 2: the 2-row sorted slice has
    // its last fully-watched entry at 0-based index 1, i.e. 1-based index 2. This LOCKS the
    // intentional under-count (correct for contiguous watchers, deliberately under-counting
    // gaps). Do not change this expectation without updating the recomputeProgress doc comment.
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

test "getResume reads through canonical_id: a sibling binding's resume follows the show (ROD-346)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    // One show, bound on two providers. All watch state lives on the senshi
    // binding; the anipub binding is a fresh fallback mint (ROD-346).
    try s.exec("INSERT INTO canonical_anime (anilist_id, title) VALUES (900, 'Frieren');");
    try s.upsertAnime(.{ .source = "senshi", .source_id = "52991", .title = "Frieren", .anilist_id = 900, .canonical_id = 900 }, 1000, arena);
    try s.upsertAnime(.{ .source = "anipub", .source_id = "2454", .title = "Frieren", .anilist_id = 900, .canonical_id = 900 }, 1001, arena);
    try s.saveProgress("senshi", "52991", .sub, "9", 300, 1400, 5000);

    // The fresh binding resumes from the sibling's row.
    const r = (try s.getResume("anipub", "2454", .sub, "9")).?;
    try testing.expectEqual(@as(f64, 300), r.position_secs);

    // Freshest sibling wins: a later anipub checkpoint supersedes the senshi row.
    try s.saveProgress("anipub", "2454", .sub, "9", 700, 1400, 6000);
    const r2 = (try s.getResume("senshi", "52991", .sub, "9")).?;
    try testing.expectEqual(@as(f64, 700), r2.position_secs);

    // Translation stays scoped across siblings: no dub row exists anywhere.
    try testing.expect((try s.getResume("anipub", "2454", .dub, "9")) == null);
}

test "getResume: NULL canonical_id never cross-joins two unmatched rows (ROD-346)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    // Two unrelated unmatched-tail rows (canonical_id NULL on both).
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "a", .title = "A" }, 1000, arena);
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "b", .title = "B" }, 1001, arena);
    try s.saveProgress(T_SOURCE, "a", .sub, "1", 300, 1400, 5000);

    try testing.expect((try s.getResume(T_SOURCE, "b", .sub, "1")) == null);
}

test "recomputeProgress unions episode rows across sibling bindings (ROD-346)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    try s.exec("INSERT INTO canonical_anime (anilist_id, title) VALUES (900, 'Frieren');");
    try s.upsertAnime(.{ .source = "senshi", .source_id = "52991", .title = "Frieren", .anilist_id = 900, .canonical_id = 900 }, 1000, arena);
    try s.upsertAnime(.{ .source = "anipub", .source_id = "2454", .title = "Frieren", .anilist_id = 900, .canonical_id = 900 }, 1001, arena);

    // Eps 1..3 fully watched on senshi; ep 3 also STARTED (not watched) on anipub:
    // the per-episode MAX must keep it watched, not let the weaker row demote it.
    try s.saveProgress("senshi", "52991", .sub, "1", 950, 1000, 5001);
    try s.saveProgress("senshi", "52991", .sub, "2", 950, 1000, 5002);
    try s.saveProgress("senshi", "52991", .sub, "3", 950, 1000, 5003);
    try s.saveProgress("anipub", "2454", .sub, "3", 120, 1400, 6000);

    // The fresh anipub binding recomputes to the show's true high-water, not 0
    // (a 0 here is the ROD-323 AniList-downgrade shape).
    const hw = try s.recomputeProgress(arena, "anipub", "2454", .sub);
    try testing.expectEqual(@as(i64, 3), hw);
    try testing.expectEqual(@as(i64, 3), (try s.getAnime(arena, "anipub", "2454")).?.progress);

    // The UPDATE targets only the queried binding; the sibling row is untouched.
    try testing.expectEqual(@as(i64, 0), (try s.getAnime(arena, "senshi", "52991")).?.progress);

    // Dub rows on a sibling never leak into a sub recompute.
    try s.saveProgress("anipub", "2454", .dub, "4", 950, 1000, 7000);
    try testing.expectEqual(@as(i64, 3), try s.recomputeProgress(arena, "senshi", "52991", .sub));
}

test "raiseProgressToUnion raises a lagging binding but never lowers a force-completed one (ROD-346 review)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    try s.exec("INSERT INTO canonical_anime (anilist_id, title) VALUES (900, 'Frieren');");
    // The union's real high-water lives on the first binding: eps 1..3 watched.
    try s.upsertAnime(.{ .source = "senshi", .source_id = "a", .title = "F", .anilist_id = 900, .canonical_id = 900 }, 1000, arena);
    try s.saveProgress("senshi", "a", .sub, "1", 950, 1000, 5001);
    try s.saveProgress("senshi", "a", .sub, "2", 950, 1000, 5002);
    try s.saveProgress("senshi", "a", .sub, "3", 950, 1000, 5003);

    // A lagging sibling (progress 1) raises to the union.
    try s.upsertAnime(.{ .source = "anipub", .source_id = "b", .title = "F", .anilist_id = 900, .canonical_id = 900, .progress = 1 }, 1001, arena);
    try testing.expectEqual(@as(i64, 3), try s.raiseProgressToUnion(arena, "anipub", "b", .sub));
    try testing.expectEqual(@as(i64, 3), (try s.getAnime(arena, "anipub", "b")).?.progress);

    // A force-completed sibling (c-key snap: progress 12, no rows behind it) is
    // NEVER lowered; the exact recompute stays the afterPlay/r-key contract.
    try s.upsertAnime(.{ .source = "other", .source_id = "c", .title = "F", .anilist_id = 900, .canonical_id = 900, .progress = 12 }, 1002, arena);
    try testing.expectEqual(@as(i64, 12), try s.raiseProgressToUnion(arena, "other", "c", .sub));
    try testing.expectEqual(@as(i64, 12), (try s.getAnime(arena, "other", "c")).?.progress);
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

test "MIGRATION_V12 re-keys an enriched allanime row onto senshi, leaves dark rows (ROD-304)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    // `rekeyLegacyProvider` runs the exact SQL the v12 ladder rung runs (MIGRATION_V12),
    // just in its own transaction — so it exercises the migration transform directly.

    // Enriched allanime row: carries the mal_id AniList enrichment stored, plus resume
    // state and a cached episode list — the migratable case.
    try s.upsertAnime(.{ .source = "allanime", .source_id = "opaqueA", .title = "Frieren", .anilist_id = 182255, .mal_id = 52991 }, 1000, arena);
    try s.saveProgress("allanime", "opaqueA", .sub, "1", 300, 1400, 1001);
    const eps = [_]domain.EpisodeNumber{ .{ .raw = "1" }, .{ .raw = "2" } };
    try s.putCachedEpisodes("allanime", "opaqueA", .sub, &eps, "FINISHED", 1000, arena);

    // Dark allanime row: never enriched (no mal_id) → cannot map to a MAL-keyed
    // provider. Must be left exactly as-is for the epic's network backfill (ROD-307).
    try s.upsertAnime(.{ .source = "allanime", .source_id = "opaqueDark", .title = "NoMal" }, 1000, arena);

    try s.rekeyLegacyProvider();

    // The enriched row re-keyed onto senshi at the stringified mal_id, content intact.
    const moved = (try s.getAnime(arena, "senshi", "52991")).?;
    try testing.expectEqualStrings("Frieren", moved.title);
    try testing.expectEqual(@as(?i64, 182255), moved.anilist_id);
    try testing.expectEqual(@as(?i64, 52991), moved.mal_id);
    try testing.expect((try s.getAnime(arena, "allanime", "opaqueA")) == null); // old key gone

    // Resume state followed the show; the old key holds nothing.
    try testing.expect((try s.getResume("senshi", "52991", .sub, "1")) != null);
    try testing.expect((try s.getResume("allanime", "opaqueA", .sub, "1")) == null);

    // Provider-specific episode cache was dropped (senshi refetches lazily), not moved.
    try testing.expect((try s.getCachedEpisodes(arena, "senshi", "52991", .sub, 1001)) == null);

    // Dark row untouched, and no duplicate: History holds the moved show + the dark row.
    try testing.expect((try s.getAnime(arena, "allanime", "opaqueDark")) != null);
    try testing.expectEqual(@as(usize, 2), (try s.loadHistory(arena)).len);

    // Idempotent: a second pass finds no allanime row with a mal_id left to move.
    try s.rekeyLegacyProvider();
    try testing.expectEqual(@as(usize, 2), (try s.loadHistory(arena)).len);
    try testing.expect((try s.getAnime(arena, "senshi", "52991")) != null);
}

test "MIGRATION_V12 keeps a pre-existing senshi twin and sweeps the allanime duplicate (ROD-304)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    // The user watched the show under allanime AND, while testing senshi, re-added it
    // there — both keys exist for MAL 52991, with a live senshi resume position. The
    // re-key must not clobber the senshi row (UPDATE OR IGNORE) and must not leave the
    // losing allanime row behind (the sweep) or orphan its child (deferred FK check).
    try s.upsertAnime(.{ .source = "allanime", .source_id = "opaqueA", .title = "Frieren (allanime)", .mal_id = 52991 }, 1000, arena);
    try s.saveProgress("allanime", "opaqueA", .sub, "1", 100, 1400, 1001);
    try s.upsertAnime(.{ .source = "senshi", .source_id = "52991", .title = "Frieren (senshi)", .mal_id = 52991 }, 2000, arena);
    try s.saveProgress("senshi", "52991", .sub, "1", 500, 1400, 2001);

    try s.rekeyLegacyProvider();

    // The senshi twin wins: its title and its resume position survive untouched.
    const twin = (try s.getAnime(arena, "senshi", "52991")).?;
    try testing.expectEqualStrings("Frieren (senshi)", twin.title);
    try testing.expectEqual(@as(f64, 500), (try s.getResume("senshi", "52991", .sub, "1")).?.position_secs);

    // The losing allanime duplicate — row and progress — is swept: no orphan, no double.
    try testing.expect((try s.getAnime(arena, "allanime", "opaqueA")) == null);
    try testing.expect((try s.getResume("allanime", "opaqueA", .sub, "1")) == null);
    try testing.expectEqual(@as(usize, 1), (try s.loadHistory(arena)).len);
}

test "MIGRATION_V12 collapses two allanime rows sharing a mal_id, no orphaned progress (ROD-304)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    // Two distinct allanime opaque ids that both enriched to the same MAL id (a
    // re-upload, or a sub/dub split allanime listed separately). Each carries its own
    // resume state — one episode overlaps ("1"), the rest are disjoint ("2" vs "3").
    try s.upsertAnime(.{ .source = "allanime", .source_id = "dupA", .title = "Dup A", .mal_id = 5956 }, 1000, arena);
    try s.upsertAnime(.{ .source = "allanime", .source_id = "dupB", .title = "Dup B", .mal_id = 5956 }, 1001, arena);
    try s.saveProgress("allanime", "dupA", .sub, "1", 100, 1400, 1002);
    try s.saveProgress("allanime", "dupA", .sub, "2", 100, 1400, 1002);
    try s.saveProgress("allanime", "dupB", .sub, "1", 200, 1400, 1003); // collides with dupA ep 1
    try s.saveProgress("allanime", "dupB", .sub, "3", 200, 1400, 1003);

    try s.rekeyLegacyProvider();

    // Collapses to exactly one row at the shared senshi key, no allanime leftover, and
    // crucially no orphaned child — an orphan would have failed the COMMIT's deferred
    // FK check inside rekeyLegacyProvider, so reaching these asserts already proves it.
    try testing.expect((try s.getAnime(arena, "senshi", "5956")) != null);
    try testing.expect((try s.getAnime(arena, "allanime", "dupA")) == null);
    try testing.expect((try s.getAnime(arena, "allanime", "dupB")) == null);
    try testing.expectEqual(@as(usize, 1), (try s.loadHistory(arena)).len);

    // The union of episodes survives on the senshi key (OR IGNORE keeps one row on the
    // ep-1 collision); nothing is stranded on the dead allanime keys.
    try testing.expect((try s.getResume("senshi", "5956", .sub, "1")) != null);
    try testing.expect((try s.getResume("senshi", "5956", .sub, "2")) != null);
    try testing.expect((try s.getResume("senshi", "5956", .sub, "3")) != null);
    try testing.expect((try s.getResume("allanime", "dupA", .sub, "2")) == null);
    try testing.expect((try s.getResume("allanime", "dupB", .sub, "3")) == null);
}

test "MIGRATION_V14 backfill: singletons lift 1:1; shared anilist_id collapses via freshest+senshi tiebreak and recovers a sibling mal_id (ROD-311)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    // Scalar readers for the UNREAD shadow — no getCanonical() exists yet (ROD-312),
    // so the test reads canonical_anime / the link column directly.
    const Q = struct {
        fn int(st: *Store, sql: [*c]const u8) !?i64 {
            const stmt = try st.prepare(sql);
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
            if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) return null;
            return c.sqlite3_column_int64(stmt, 0);
        }
        fn text(a: Allocator, st: *Store, sql: [*c]const u8) !?[]const u8 {
            const stmt = try st.prepare(sql);
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
            return dupeText(a, stmt, 0);
        }
    };

    // openMemory already ran MIGRATION_V14 (DDL + BACKFILL) on empty tables, so
    // canonical_anime exists and is empty. Seed bindings by hand (a raw INSERT, not
    // upsertAnime, because the tiebreak keys on enrichment_fetched_at, which the upsert API
    // doesn't take). Six distinct anilist_ids exercise every tier of the pick:
    //   100  singleton (senshi)                           → 1:1 lift, mal_id carries
    //   NULL the unmatched tail                           → no canonical row, stays unlinked
    //   999  senshi(fresher, NO mal) vs allanime(mal=555) → fresher wins; NULL mal recovers 555
    //   777  allanime(FRESHER, mal=333) vs senshi(stale)  → freshness is PRIMARY, beats senshi
    //   888  allanime vs senshi, TIED on enrichment       → senshi wins the tie (secondary key)
    //   666  two allanime tied on enrichment+source       → lowest rowid wins (final key)
    //   321  allanime(enriched) vs senshi(NULL enrich)    → NULL sorts LAST, enriched wins
    try s.exec(
        \\INSERT INTO anime (source, source_id, title, anilist_id, mal_id, enrichment_fetched_at, added_at) VALUES
        \\  ('senshi',   'solo', 'Solo Show',    100,  700,  3000, 1000),
        \\  ('senshi',   'tail', 'No Id',        NULL, NULL, NULL, 1000),
        \\  ('senshi',   'win',  'Winner',       999,  NULL, 2000, 1000),
        \\  ('allanime', 'lose', 'Loser',        999,  555,  1000, 1000),
        \\  ('allanime', 'fa',   'Fresh AL',     777,  333,  5000, 1000),
        \\  ('senshi',   'ss',   'Stale Senshi', 777,  444,  1000, 1000),
        \\  ('allanime', 'pa',   'P allanime',   888,  111,  1500, 1000),
        \\  ('senshi',   'qs',   'Q senshi',     888,  222,  1500, 1000),
        \\  ('allanime', 'r1',   'Rowid First',  666,  661,  2500, 1000),
        \\  ('allanime', 'r2',   'Rowid Later',  666,  662,  2500, 1000),
        \\  ('senshi',   'ne',   'Null Enrich',  321,  811,  NULL, 1000),
        \\  ('allanime', 'ee',   'Has Enrich',   321,  812,  100,  1000);
    );

    // Run the exact data lift the ladder runs — the DDL is already applied, so this is
    // the isolated backfill the const split exists to make testable.
    try s.exec(MIGRATION_V14_BACKFILL);

    // One canonical row per distinct non-null anilist_id (100, 999, 777, 888, 666, 321).
    try testing.expectEqual(@as(?i64, 6), try Q.int(&s, "SELECT COUNT(*) FROM canonical_anime;"));
    // Eleven of twelve bindings link; the NULL-anilist tail stays unlinked.
    try testing.expectEqual(@as(?i64, 11), try Q.int(&s, "SELECT COUNT(*) FROM anime WHERE canonical_id IS NOT NULL;"));
    try testing.expectEqual(@as(?i64, null), try Q.int(&s, "SELECT canonical_id FROM anime WHERE source_id = 'tail';"));

    // Singleton: 1:1 lift, mal_id and link intact.
    try testing.expectEqual(@as(?i64, 100), try Q.int(&s, "SELECT canonical_id FROM anime WHERE source_id = 'solo';"));
    try testing.expectEqual(@as(?i64, 700), try Q.int(&s, "SELECT mal_id FROM canonical_anime WHERE anilist_id = 100;"));

    // Shared 999: freshest binding (senshi 'win') wins the seed; its NULL mal_id
    // recovers 555 from the older 'lose' sibling; BOTH bindings point at canonical 999.
    try testing.expectEqualStrings("Winner", (try Q.text(arena, &s, "SELECT title FROM canonical_anime WHERE anilist_id = 999;")).?);
    try testing.expectEqual(@as(?i64, 555), try Q.int(&s, "SELECT mal_id FROM canonical_anime WHERE anilist_id = 999;"));
    try testing.expectEqual(@as(?i64, 999), try Q.int(&s, "SELECT canonical_id FROM anime WHERE source_id = 'win';"));
    try testing.expectEqual(@as(?i64, 999), try Q.int(&s, "SELECT canonical_id FROM anime WHERE source_id = 'lose';"));

    // Shared 888: tie on enrichment_fetched_at → senshi ('qs') wins the CASE tiebreak,
    // so title is 'Q senshi' and its own mal_id 222 stands (no sibling recovery needed).
    try testing.expectEqualStrings("Q senshi", (try Q.text(arena, &s, "SELECT title FROM canonical_anime WHERE anilist_id = 888;")).?);
    try testing.expectEqual(@as(?i64, 222), try Q.int(&s, "SELECT mal_id FROM canonical_anime WHERE anilist_id = 888;"));
    try testing.expectEqual(@as(?i64, 888), try Q.int(&s, "SELECT canonical_id FROM anime WHERE source_id = 'pa';"));
    try testing.expectEqual(@as(?i64, 888), try Q.int(&s, "SELECT canonical_id FROM anime WHERE source_id = 'qs';"));

    // Shared 777: freshness is the PRIMARY sort key — the fresher allanime binding
    // ('fa', enrichment 5000) beats the staler senshi one ('ss', 1000), proving the
    // enrichment DESC sort outranks the senshi CASE. Guards against a key reorder.
    try testing.expectEqualStrings("Fresh AL", (try Q.text(arena, &s, "SELECT title FROM canonical_anime WHERE anilist_id = 777;")).?);
    try testing.expectEqual(@as(?i64, 333), try Q.int(&s, "SELECT mal_id FROM canonical_anime WHERE anilist_id = 777;"));

    // Shared 666: two same-source bindings tied on enrichment resolve by lowest rowid
    // (insertion order) — the first-seeded 'r1' wins deterministically, pinning the
    // final tiebreak so a group can never collapse to two rows or a nondeterministic one.
    try testing.expectEqualStrings("Rowid First", (try Q.text(arena, &s, "SELECT title FROM canonical_anime WHERE anilist_id = 666;")).?);
    try testing.expectEqual(@as(?i64, 661), try Q.int(&s, "SELECT mal_id FROM canonical_anime WHERE anilist_id = 666;"));

    // Shared 321: a never-enriched binding (NULL enrichment_fetched_at) sorts LAST under
    // the DESC primary key, so the enriched allanime 'ee' beats senshi 'ne' — the tie the
    // two-provider future is most likely to hit (a freshly-added, un-enriched binding).
    try testing.expectEqualStrings("Has Enrich", (try Q.text(arena, &s, "SELECT title FROM canonical_anime WHERE anilist_id = 321;")).?);
    try testing.expectEqual(@as(?i64, 812), try Q.int(&s, "SELECT mal_id FROM canonical_anime WHERE anilist_id = 321;"));
}

test "loadHistory/getAnime resolve enrichment through canonical: linked row reads canonical (per-column COALESCE), unmatched row falls back to anime-local (ROD-312)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    // Seed the spine by hand (no getCanonical/upsertCanonical yet — that's slice 2)
    // with values that DIFFER from the anime shadow, so a wrong join is visible: a
    // read that returned the local column would report the stale seed, not these.
    // `description` is left NULL on canonical to prove the resolution is per-column
    // COALESCE, not a whole-row swap — it must fall back to the local description.
    // The FK (anime.canonical_id -> canonical_anime.anilist_id) forces canonical first.
    try s.exec(
        \\INSERT INTO canonical_anime
        \\  (anilist_id, title, score, native_name, total_episodes, next_airing_at, description)
        \\VALUES
        \\  (500, 'Canonical Romaji', 99, 'カノニカル', 24, 1234567, NULL);
    );
    try s.exec(
        \\INSERT INTO anime
        \\  (source, source_id, title, anilist_id, canonical_id, score, native_name,
        \\   total_episodes, next_airing_at, description, list_status, progress,
        \\   history_visible, added_at)
        \\VALUES
        \\  ('senshi', 'linked', 'Stale Provider Seed', 500, 500, 10, NULL,
        \\   1, NULL, 'Local Desc', 'watching', 7, 1, 1000),
        \\  ('senshi', 'orphan', 'Only Local', NULL, NULL, 42, 'ローカル',
        \\   13, 555, 'Orphan Desc', 'planning', 3, 1, 900);
    );

    // getAnime on the linked row: every enrichment column resolves to canonical...
    const linked = (try s.getAnime(arena, "senshi", "linked")).?;
    try testing.expectEqualStrings("Canonical Romaji", linked.title);
    try testing.expectEqual(@as(?i64, 99), linked.score);
    try testing.expectEqualStrings("カノニカル", linked.native_name.?);
    try testing.expectEqual(@as(?i64, 24), linked.total_episodes);
    try testing.expectEqual(@as(?i64, 1234567), linked.next_airing_at);
    // ...except where canonical is NULL, which falls back to the local column...
    try testing.expectEqualStrings("Local Desc", linked.description.?);
    // ...while user-state and the binding key stay anime-local, never canonical.
    try testing.expectEqualStrings("linked", linked.source_id);
    try testing.expectEqual(@as(?i64, 500), linked.anilist_id);
    try testing.expectEqual(domain.ListStatus.watching, linked.list_status);
    try testing.expectEqual(@as(i64, 7), linked.progress);

    // getAnime on the unmatched row: canonical_id NULL → the LEFT JOIN yields NULLs
    // → every enrichment column falls back to the anime-local value.
    const orphan = (try s.getAnime(arena, "senshi", "orphan")).?;
    try testing.expectEqualStrings("Only Local", orphan.title);
    try testing.expectEqual(@as(?i64, 42), orphan.score);
    try testing.expectEqualStrings("ローカル", orphan.native_name.?);

    // loadHistory drives the same join: most-recently-added first (linked 1000 >
    // orphan 900), and each row shows its resolved title.
    const hist = try s.loadHistory(arena);
    try testing.expectEqual(@as(usize, 2), hist.len);
    try testing.expectEqualStrings("Canonical Romaji", hist[0].title);
    try testing.expectEqualStrings("Only Local", hist[1].title);
}

test "app_meta round-trips one-time flags (ROD-308)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    try testing.expect((try s.metaGet(arena, "provider_backfill_v1")) == null); // unset → null
    try s.metaSet("provider_backfill_v1", "done");
    try testing.expectEqualStrings("done", (try s.metaGet(arena, "provider_backfill_v1")).?);
    try s.metaSet("provider_backfill_v1", "redone"); // upsert overwrites
    try testing.expectEqualStrings("redone", (try s.metaGet(arena, "provider_backfill_v1")).?);
}

test "ROD-308 backfill: list anilist-only rows, stamp mal_id, re-key onto senshi" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var s = try Store.openMemory();
    defer s.close();

    // A: allanime with an anilist_id but no mal_id → the backfill's target.
    try s.upsertAnime(.{ .source = "allanime", .source_id = "opaqueA", .title = "Frieren", .anilist_id = 182255 }, 1000, arena);
    // B: allanime already carrying mal_id → not a backfill target (re-keys offline).
    try s.upsertAnime(.{ .source = "allanime", .source_id = "opaqueB", .title = "Dungeon Meshi", .anilist_id = 153518, .mal_id = 52701 }, 1000, arena);
    // C: allanime with no ids at all → the hard tail, never a backfill target.
    try s.upsertAnime(.{ .source = "allanime", .source_id = "opaqueC", .title = "NoIds" }, 1000, arena);

    // Work-list is exactly A: anilist_id present, mal_id absent.
    const ids = try s.listBackfillAnilistIds(arena);
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqual(@as(i64, 182255), ids[0]);

    // The network step resolves 182255 → idMal 52991; stamp it. The stamp is scoped
    // to still-missing mal_ids, so a second (wrong) stamp for the same id is a no-op.
    try s.setMalIdByAnilistId(182255, 52991);
    try s.setMalIdByAnilistId(182255, 99999);
    try testing.expectEqual(@as(?i64, 52991), (try s.getAnime(arena, "allanime", "opaqueA")).?.mal_id);

    // The reusable re-key now sweeps A (freshly eligible) and B onto senshi; C stays.
    try s.rekeyLegacyProvider();
    try testing.expect((try s.getAnime(arena, "senshi", "52991")) != null); // A moved
    try testing.expect((try s.getAnime(arena, "senshi", "52701")) != null); // B moved
    try testing.expect((try s.getAnime(arena, "allanime", "opaqueA")) == null);
    try testing.expect((try s.getAnime(arena, "allanime", "opaqueC")) != null); // dark, kept

    // Nothing left to back-fill: A moved, C has no anilist_id to resolve.
    try testing.expectEqual(@as(usize, 0), (try s.listBackfillAnilistIds(arena)).len);
}
