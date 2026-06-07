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
    @cInclude("sys/stat.h");
    @cInclude("stdlib.h"); // getenv
});

pub const Error = error{ Open, Exec, Prepare, Step, OutOfMemory, NoHomeDir };

/// Schema version this build expects. Bump + add a `MIGRATION_Vn` + a branch in
/// `migrate` when the shape changes — never ALTER-and-ignore.
const SCHEMA_VERSION: c_int = 1;

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
    \\    PRIMARY KEY (source, source_id, translation)
    \\);
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
    total_episodes: ?i64 = null,
    list_status: []const u8 = "planning",
    user_rating: ?f64 = null,
    notes: ?[]const u8 = null,
    play_count: i64 = 0,
    progress: i64 = 0,
    added_at: i64 = 0,
    last_watched_at: ?i64 = null,

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
            .mal_id = if (a.mal_id) |m| @intCast(m) else null,
            .anilist_id = if (a.anilist_id) |x| @intCast(x) else null,
            .cover_url = a.thumb,
            .total_episodes = if (eps > 0) @intCast(eps) else null,
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
        return @intFromFloat(self.position_secs);
    }
};

// ── Store ───────────────────────────────────────────────────────────────────

pub const Store = struct {
    db: SqliteDb,

    /// Open (creating if needed) the DB at `path`, set WAL + foreign keys, and
    /// migrate to the current schema. `path` must be null-terminated.
    pub fn open(path: [:0]const u8) Error!Store {
        var db: SqliteDb = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
        if (c.sqlite3_open_v2(path.ptr, &db, flags, null) != c.SQLITE_OK) {
            std.debug.print("store: open failed: {s}\n", .{c.sqlite3_errmsg(db)});
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
    pub fn upsertAnime(self: *Store, a: AnimeRecord, now: i64) Error!void {
        const sql =
            \\INSERT INTO anime (source, source_id, title, title_english, mal_id, anilist_id,
            \\    cover_url, total_episodes, list_status, user_rating, notes,
            \\    play_count, progress, added_at, last_watched_at)
            \\VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            \\ON CONFLICT(source, source_id) DO UPDATE SET
            \\    title          = excluded.title,
            \\    title_english  = excluded.title_english,
            \\    mal_id         = COALESCE(excluded.mal_id, anime.mal_id),
            \\    anilist_id     = COALESCE(excluded.anilist_id, anime.anilist_id),
            \\    cover_url      = COALESCE(excluded.cover_url, anime.cover_url),
            \\    total_episodes = COALESCE(excluded.total_episodes, anime.total_episodes)
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt, 1, a.source);
        bindText(stmt, 2, a.source_id);
        bindText(stmt, 3, a.title);
        bindOptText(stmt, 4, a.title_english);
        bindOptI64(stmt, 5, a.mal_id);
        bindOptI64(stmt, 6, a.anilist_id);
        bindOptText(stmt, 7, a.cover_url);
        bindOptI64(stmt, 8, a.total_episodes);
        bindText(stmt, 9, a.list_status);
        bindOptF64(stmt, 10, a.user_rating);
        bindOptText(stmt, 11, a.notes);
        _ = c.sqlite3_bind_int64(stmt, 12, a.play_count);
        _ = c.sqlite3_bind_int64(stmt, 13, a.progress);
        _ = c.sqlite3_bind_int64(stmt, 14, if (a.added_at != 0) a.added_at else now);
        bindOptI64(stmt, 15, a.last_watched_at);

        try self.stepDone(stmt);
    }

    /// All shows, most-recently-watched first (then most-recently-added). Every
    /// text field is duped into `arena`.
    pub fn loadHistory(self: *Store, arena: Allocator) Error![]AnimeRecord {
        const sql =
            \\SELECT source, source_id, title, title_english, mal_id, anilist_id, cover_url,
            \\    total_episodes, list_status, user_rating, notes, play_count, progress,
            \\    added_at, last_watched_at
            \\FROM anime
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
                .total_episodes = colOptI64(stmt, 7),
                .list_status = try dupeText(arena, stmt, 8) orelse "planning",
                .user_rating = colOptF64(stmt, 9),
                .notes = try dupeText(arena, stmt, 10),
                .play_count = c.sqlite3_column_int64(stmt, 11),
                .progress = c.sqlite3_column_int64(stmt, 12),
                .added_at = c.sqlite3_column_int64(stmt, 13),
                .last_watched_at = colOptI64(stmt, 14),
            });
        }
        return rows.toOwnedSlice(arena);
    }

    /// Mark a play: bump play_count + last_watched_at, and advance `progress` to
    /// at least `episode_index` (1-based). Episode-level half of ROD-69; the
    /// sub-second position lands via `saveProgress` once M5's IPC feeds it.
    pub fn recordPlay(self: *Store, source: []const u8, source_id: []const u8, episode_index: i64, now: i64) Error!void {
        const sql =
            \\UPDATE anime
            \\SET play_count = play_count + 1,
            \\    last_watched_at = ?,
            \\    progress = MAX(progress, ?)
            \\WHERE source = ? AND source_id = ?
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, now);
        _ = c.sqlite3_bind_int64(stmt, 2, episode_index);
        bindText(stmt, 3, source);
        bindText(stmt, 4, source_id);
        try self.stepDone(stmt);
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
        bindText(stmt, 1, source);
        bindText(stmt, 2, source_id);
        bindText(stmt, 3, tt.str());
        bindText(stmt, 4, episode);
        _ = c.sqlite3_bind_double(stmt, 5, position_secs);
        _ = c.sqlite3_bind_double(stmt, 6, duration_secs);
        _ = c.sqlite3_bind_int64(stmt, 7, watched);
        _ = c.sqlite3_bind_int64(stmt, 8, now);
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
        bindText(stmt, 1, source);
        bindText(stmt, 2, source_id);
        bindText(stmt, 3, tt.str());
        bindText(stmt, 4, episode);
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
        const s = airing_status orelse return 24 * 60 * 60;
        if (eqIgnoreCase(s, "FINISHED") or eqIgnoreCase(s, "finished")) return 7 * 24 * 60 * 60;
        if (eqIgnoreCase(s, "RELEASING") or eqIgnoreCase(s, "ongoing") or eqIgnoreCase(s, "releasing")) return 6 * 60 * 60;
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
        bindText(stmt, 1, source);
        bindText(stmt, 2, source_id);
        bindText(stmt, 3, tt.str());
        bindText(stmt, 4, blob.items);
        _ = c.sqlite3_bind_int64(stmt, 5, now);
        _ = c.sqlite3_bind_int64(stmt, 6, now + cacheTtl(airing_status));
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
        bindText(stmt, 1, source);
        bindText(stmt, 2, source_id);
        bindText(stmt, 3, tt.str());
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
        if (v < 1) {
            try self.exec(MIGRATION_V1);
            try self.exec("PRAGMA user_version = 1;");
            v = 1;
        }
        // future: if (v < 2) { try self.exec(MIGRATION_V2); ... }
        std.debug.assert(v == SCHEMA_VERSION);
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
            std.debug.print("store: exec failed: {s}\n", .{errmsg});
            c.sqlite3_free(errmsg);
            return error.Exec;
        }
    }

    fn prepare(self: *Store, sql: [*c]const u8) Error!Stmt {
        var stmt: Stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            std.debug.print("store: prepare failed: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return error.Prepare;
        }
        return stmt;
    }

    fn stepDone(self: *Store, stmt: Stmt) Error!void {
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            std.debug.print("store: step failed: {s}\n", .{c.sqlite3_errmsg(self.db)});
            return error.Step;
        }
    }
};

// ── Default DB location (XDG) ─────────────────────────────────────────────────

/// `$XDG_DATA_HOME/zigoku/zigoku.db`, falling back to `~/.local/share/...`.
/// Creates the directory (best-effort) and returns a null-terminated path.
pub fn defaultDbPath(arena: Allocator) Error![:0]const u8 {
    const dir = try dataDir(arena);
    mkdirP(dir);
    return std.fmt.allocPrintSentinel(arena, "{s}/zigoku.db", .{dir}, 0);
}

fn dataDir(arena: Allocator) Error![]const u8 {
    if (c.getenv("XDG_DATA_HOME")) |x| {
        const base = std.mem.span(x);
        if (base.len > 0) return std.fmt.allocPrint(arena, "{s}/zigoku", .{base});
    }
    if (c.getenv("HOME")) |h| {
        const home = std.mem.span(h);
        if (home.len > 0) return std.fmt.allocPrint(arena, "{s}/.local/share/zigoku", .{home});
    }
    return error.NoHomeDir;
}

/// `mkdir -p`, best-effort: walks the path creating each component, ignoring
/// "already exists". A real failure surfaces later as an open error.
fn mkdirP(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            const save = buf[i];
            buf[i] = 0;
            _ = c.mkdir(&buf, 0o755); // ignore EEXIST and friends
            buf[i] = save;
        }
    }
}

// ── C-API binding/reading helpers ─────────────────────────────────────────────

fn bindText(stmt: Stmt, idx: c_int, s: []const u8) void {
    // SQLITE_STATIC: caller guarantees `s` outlives the step (always true here —
    // bind args live in the calling method's frame across its single step).
    _ = c.sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), null);
}
fn bindOptText(stmt: Stmt, idx: c_int, s: ?[]const u8) void {
    if (s) |x| bindText(stmt, idx, x) else _ = c.sqlite3_bind_null(stmt, idx);
}
fn bindOptI64(stmt: Stmt, idx: c_int, v: ?i64) void {
    if (v) |x| _ = c.sqlite3_bind_int64(stmt, idx, x) else _ = c.sqlite3_bind_null(stmt, idx);
}
fn bindOptF64(stmt: Stmt, idx: c_int, v: ?f64) void {
    if (v) |x| _ = c.sqlite3_bind_double(stmt, idx, x) else _ = c.sqlite3_bind_null(stmt, idx);
}

fn dupeText(arena: Allocator, stmt: Stmt, idx: c_int) Error!?[]const u8 {
    const ptr = c.sqlite3_column_text(stmt, idx);
    if (ptr == null) return null;
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, idx));
    return try arena.dupe(u8, ptr[0..n]);
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

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const T_SOURCE = "allanime";

test "open + migrate sets user_version" {
    var s = try Store.openMemory();
    defer s.close();
    try testing.expectEqual(SCHEMA_VERSION, try s.userVersion());
}

test "upsertAnime + loadHistory round-trips" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    const a = AnimeRecord.fromDomain(T_SOURCE, .{ .id = "abc", .name = "Frieren", .eps_sub = 28 }, .sub);
    try s.upsertAnime(a, 1000);

    const rows = try s.loadHistory(arena);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("abc", rows[0].source_id);
    try testing.expectEqualStrings("Frieren", rows[0].title);
    try testing.expectEqual(@as(?i64, 28), rows[0].total_episodes);
    try testing.expectEqualStrings("planning", rows[0].list_status);
    try testing.expectEqual(@as(i64, 0), rows[0].play_count);
}

test "upsertAnime preserves user state on re-search" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "Old Title" }, 1000);
    try s.recordPlay(T_SOURCE, "x", 3, 2000); // play_count=1, progress=3

    // A later search refreshes the title but must NOT reset play_count/progress.
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "New Title", .total_episodes = 12 }, 3000);

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
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X" }, 1000);

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
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X" }, 1000);

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

test "recordPlay bumps count, progress, last_watched and reorders history" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "a", .title = "A" }, 1000);
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "b", .title = "B" }, 1001);

    // Play B → it should jump to the top of history.
    try s.recordPlay(T_SOURCE, "b", 5, 2000);
    try s.recordPlay(T_SOURCE, "b", 2, 2001); // progress is a high-water mark

    const rows = try s.loadHistory(arena);
    try testing.expectEqualStrings("b", rows[0].source_id);
    try testing.expectEqual(@as(i64, 2), rows[0].play_count);
    try testing.expectEqual(@as(i64, 5), rows[0].progress); // MAX, not last
    try testing.expectEqual(@as(?i64, 2001), rows[0].last_watched_at);
}

test "episode cache: hit, expiry, sub/dub separation" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();

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

test "foreign key cascade deletes progress with its anime" {
    var s = try Store.openMemory();
    defer s.close();
    try s.upsertAnime(.{ .source = T_SOURCE, .source_id = "x", .title = "X" }, 1000);
    try s.saveProgress(T_SOURCE, "x", .sub, "1", 100, 1400, 1001);

    try s.exec("DELETE FROM anime WHERE source_id = 'x';");
    try testing.expect((try s.getResume(T_SOURCE, "x", .sub, "1")) == null);
}
