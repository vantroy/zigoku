//! ROD-56 spike — prove SQLite via raw C interop on Zig 0.16.0.
//!
//! Exercises the full surface we'll need: @cImport + linkSystemLibrary, open,
//! exec (pragmas/migrations), prepared statements, bind (int/text/double/null),
//! step, typed column reads, upsert via ON CONFLICT, and error handling that
//! surfaces sqlite3_errmsg.
//!
//! The schema is OURS — AniList-keyed with watchlist semantics and real
//! PRAGMA user_version migrations (not ani-nexus's AllAnime-string-id tables
//! with episode-cache columns and ALTER-and-ignore-errors).
//!
//! Run: `zig build spike-sqlite`

const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("time.h");
});

const DB_PATH = "/tmp/zigoku-spike.db";
const SCHEMA_VERSION: c_int = 1;

const Error = error{ Open, Exec, Prepare, Step };

// ── Schema (v1) ───────────────────────────────────────────────────────────────
// `anime`: a personal library/history keyed by AniList Media.id (a stable
// integer natural key). `episode_progress`: per-episode resume + watched state.
const MIGRATION_V1 =
    \\CREATE TABLE anime (
    \\    anilist_id      INTEGER PRIMARY KEY,                 -- AniList Media.id
    \\    mal_id          INTEGER,                             -- Media.idMal, for AniSkip
    \\    title_romaji    TEXT    NOT NULL,
    \\    title_english   TEXT,
    \\    cover_url       TEXT,
    \\    format          TEXT,                                -- TV / MOVIE / OVA / ONA ...
    \\    episodes        INTEGER,                             -- total, NULL if unknown/ongoing
    \\    season_year     INTEGER,
    \\    average_score   INTEGER,                             -- AniList 0-100
    \\    airing_status   TEXT,                                -- FINISHED / RELEASING / ...
    \\    list_status     TEXT    NOT NULL DEFAULT 'planning', -- watching|completed|planning|paused|dropped
    \\    user_score      REAL,                                -- our own 0-10 rating
    \\    notes           TEXT,
    \\    added_at        INTEGER NOT NULL,                    -- unix seconds
    \\    last_watched_at INTEGER                              -- unix seconds, NULL until first play
    \\);
    \\CREATE TABLE episode_progress (
    \\    anilist_id    INTEGER NOT NULL REFERENCES anime(anilist_id) ON DELETE CASCADE,
    \\    episode       INTEGER NOT NULL,
    \\    position_secs REAL    NOT NULL DEFAULT 0,            -- resume point
    \\    duration_secs REAL    NOT NULL DEFAULT 0,            -- 0 = unknown
    \\    watched       INTEGER NOT NULL DEFAULT 0,            -- bool: >= ~90% watched
    \\    updated_at    INTEGER NOT NULL,
    \\    PRIMARY KEY (anilist_id, episode)
    \\);
    \\CREATE INDEX idx_anime_last_watched ON anime(last_watched_at DESC);
    \\CREATE INDEX idx_anime_list_status  ON anime(list_status);
;

// ── Tiny helpers over the C API ───────────────────────────────────────────────

const Db = ?*c.sqlite3;
const Stmt = ?*c.sqlite3_stmt;

/// Run one or more statements with no result rows (pragmas, DDL).
fn exec(db: Db, sql: [*c]const u8) Error!void {
    var errmsg: [*c]u8 = null;
    if (c.sqlite3_exec(db, sql, null, null, &errmsg) != c.SQLITE_OK) {
        std.debug.print("  ✗ exec: {s}\n", .{errmsg});
        c.sqlite3_free(errmsg);
        return error.Exec;
    }
}

fn prepare(db: Db, sql: [*c]const u8) Error!Stmt {
    var stmt: Stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("  ✗ prepare: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.Prepare;
    }
    return stmt;
}

fn bindText(stmt: Stmt, idx: c_int, s: []const u8) void {
    // null destructor == SQLITE_STATIC: caller guarantees `s` outlives the step.
    _ = c.sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), null);
}
fn bindOptText(stmt: Stmt, idx: c_int, s: ?[]const u8) void {
    if (s) |x| bindText(stmt, idx, x) else _ = c.sqlite3_bind_null(stmt, idx);
}
fn bindOptI64(stmt: Stmt, idx: c_int, v: ?i64) void {
    if (v) |x| _ = c.sqlite3_bind_int64(stmt, idx, x) else _ = c.sqlite3_bind_null(stmt, idx);
}

/// Read a text column as a slice, or null. Uses column_bytes for an exact length.
fn colText(stmt: Stmt, idx: c_int) ?[]const u8 {
    const ptr = c.sqlite3_column_text(stmt, idx);
    if (ptr == null) return null;
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, idx));
    return ptr[0..n];
}
fn colOptI64(stmt: Stmt, idx: c_int) ?i64 {
    if (c.sqlite3_column_type(stmt, idx) == c.SQLITE_NULL) return null;
    return c.sqlite3_column_int64(stmt, idx);
}

// ── Migrations via PRAGMA user_version ────────────────────────────────────────

fn userVersion(db: Db) Error!c_int {
    const stmt = try prepare(db, "PRAGMA user_version;");
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.Step;
    return c.sqlite3_column_int(stmt, 0);
}

fn migrate(db: Db) Error!void {
    var v = try userVersion(db);
    std.debug.print("  schema at v{d}, target v{d}\n", .{ v, SCHEMA_VERSION });
    if (v < 1) {
        try exec(db, MIGRATION_V1);
        try exec(db, "PRAGMA user_version = 1;");
        v = 1;
        std.debug.print("  → applied migration v1\n", .{});
    }
    // future: if (v < 2) { ... }
}

// ── Domain writes ─────────────────────────────────────────────────────────────

const Anime = struct {
    anilist_id: i64,
    mal_id: ?i64 = null,
    title_romaji: []const u8,
    title_english: ?[]const u8 = null,
    cover_url: ?[]const u8 = null,
    format: ?[]const u8 = null,
    episodes: ?i64 = null,
    season_year: ?i64 = null,
    average_score: ?i64 = null,
    airing_status: ?[]const u8 = null,
    list_status: []const u8 = "planning",
};

fn upsertAnime(db: Db, a: Anime, now: i64) Error!void {
    const sql =
        \\INSERT INTO anime (anilist_id, mal_id, title_romaji, title_english, cover_url,
        \\    format, episodes, season_year, average_score, airing_status, list_status, added_at)
        \\VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        \\ON CONFLICT(anilist_id) DO UPDATE SET
        \\    title_english = excluded.title_english,
        \\    cover_url     = excluded.cover_url,
        \\    episodes      = excluded.episodes,
        \\    average_score = excluded.average_score,
        \\    airing_status = excluded.airing_status
    ;
    const stmt = try prepare(db, sql);
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, a.anilist_id);
    bindOptI64(stmt, 2, a.mal_id);
    bindText(stmt, 3, a.title_romaji);
    bindOptText(stmt, 4, a.title_english);
    bindOptText(stmt, 5, a.cover_url);
    bindOptText(stmt, 6, a.format);
    bindOptI64(stmt, 7, a.episodes);
    bindOptI64(stmt, 8, a.season_year);
    bindOptI64(stmt, 9, a.average_score);
    bindOptText(stmt, 10, a.airing_status);
    bindText(stmt, 11, a.list_status);
    _ = c.sqlite3_bind_int64(stmt, 12, now);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.debug.print("  ✗ upsertAnime: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.Step;
    }
}

/// Upsert resume position for one episode and bump the anime's last_watched_at.
fn saveProgress(db: Db, anilist_id: i64, episode: i64, pos: f64, dur: f64, now: i64) Error!void {
    const watched: i64 = if (dur > 0 and pos / dur >= 0.90) 1 else 0;
    const sql =
        \\INSERT INTO episode_progress (anilist_id, episode, position_secs, duration_secs, watched, updated_at)
        \\VALUES (?,?,?,?,?,?)
        \\ON CONFLICT(anilist_id, episode) DO UPDATE SET
        \\    position_secs = excluded.position_secs,
        \\    duration_secs = excluded.duration_secs,
        \\    watched       = excluded.watched,
        \\    updated_at    = excluded.updated_at
    ;
    const stmt = try prepare(db, sql);
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, anilist_id);
    _ = c.sqlite3_bind_int64(stmt, 2, episode);
    _ = c.sqlite3_bind_double(stmt, 3, pos);
    _ = c.sqlite3_bind_double(stmt, 4, dur);
    _ = c.sqlite3_bind_int64(stmt, 5, watched);
    _ = c.sqlite3_bind_int64(stmt, 6, now);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        std.debug.print("  ✗ saveProgress: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.Step;
    }

    const bump = try prepare(db, "UPDATE anime SET last_watched_at = ? WHERE anilist_id = ?");
    defer _ = c.sqlite3_finalize(bump);
    _ = c.sqlite3_bind_int64(bump, 1, now);
    _ = c.sqlite3_bind_int64(bump, 2, anilist_id);
    _ = c.sqlite3_step(bump);
}

// ── Read-back: the library view with resume info ──────────────────────────────

fn printLibrary(db: Db) Error!void {
    const sql =
        \\SELECT a.title_english, a.title_romaji, a.list_status, a.episodes,
        \\    (SELECT COUNT(*) FROM episode_progress p
        \\       WHERE p.anilist_id = a.anilist_id AND p.watched = 1)              AS watched_count,
        \\    (SELECT p.episode FROM episode_progress p
        \\       WHERE p.anilist_id = a.anilist_id ORDER BY p.updated_at DESC LIMIT 1) AS last_ep,
        \\    (SELECT p.position_secs FROM episode_progress p
        \\       WHERE p.anilist_id = a.anilist_id ORDER BY p.updated_at DESC LIMIT 1) AS last_pos
        \\FROM anime a
        \\ORDER BY a.last_watched_at DESC NULLS LAST, a.added_at DESC
    ;
    const stmt = try prepare(db, sql);
    defer _ = c.sqlite3_finalize(stmt);

    std.debug.print("\n  library:\n", .{});
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const title = colText(stmt, 0) orelse colText(stmt, 1) orelse "(untitled)";
        const status = colText(stmt, 2) orelse "?";
        const eps = colOptI64(stmt, 3);
        const watched = c.sqlite3_column_int64(stmt, 4);
        const last_ep = colOptI64(stmt, 5);
        const last_pos = c.sqlite3_column_double(stmt, 6);

        std.debug.print("   • {s}  [{s}]\n", .{ title, status });
        if (eps) |e| {
            std.debug.print("       {d}/{d} watched", .{ watched, e });
        } else {
            std.debug.print("       {d} watched", .{watched});
        }
        if (last_ep) |le| {
            std.debug.print("  ·  resume ep {d} @ {d:.0}s", .{ le, last_pos });
        }
        std.debug.print("\n", .{});
    }
}

// ── main ──────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    _ = init;

    // Fresh DB each run for reproducibility (libc is linked anyway).
    _ = std.c.unlink(DB_PATH);
    _ = std.c.unlink(DB_PATH ++ "-wal");
    _ = std.c.unlink(DB_PATH ++ "-shm");

    std.debug.print("→ opening {s}  (sqlite {s})\n", .{ DB_PATH, c.sqlite3_libversion() });

    var db: Db = null;
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
    if (c.sqlite3_open_v2(DB_PATH, &db, flags, null) != c.SQLITE_OK) {
        std.debug.print("  ✗ open: {s}\n", .{c.sqlite3_errmsg(db)});
        return error.Open;
    }
    defer _ = c.sqlite3_close(db);

    try exec(db, "PRAGMA journal_mode = WAL;");
    try exec(db, "PRAGMA foreign_keys = ON;");
    try migrate(db);

    const now: i64 = @intCast(c.time(null));

    // Seed a couple of AniList rows (data shape matches the spike-http output).
    try upsertAnime(db, .{
        .anilist_id = 154587,
        .mal_id = 52991,
        .title_romaji = "Sousou no Frieren",
        .title_english = "Frieren: Beyond Journey's End",
        .cover_url = "https://img.anili.st/154587.jpg",
        .format = "TV",
        .episodes = 28,
        .season_year = 2023,
        .average_score = 91,
        .airing_status = "FINISHED",
        .list_status = "watching",
    }, now);
    try upsertAnime(db, .{
        .anilist_id = 21,
        .title_romaji = "One Piece",
        .title_english = "One Piece",
        .format = "TV",
        .episodes = null, // ongoing
        .season_year = 1999,
        .average_score = 88,
        .airing_status = "RELEASING",
        .list_status = "planning",
    }, now);

    // Progress: watch ep1 fully, pause mid ep2. The double-write on ep2 proves
    // the ON CONFLICT upsert (120s then 540s → final 540s).
    try saveProgress(db, 154587, 1, 1410, 1440, now); // ~98% → watched
    try saveProgress(db, 154587, 2, 120, 1440, now + 1);
    try saveProgress(db, 154587, 2, 540, 1440, now + 2); // resume point wins

    try printLibrary(db);

    std.debug.print("\n✓ SQLite C-interop works.\n", .{});
}
