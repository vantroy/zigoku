//! Zigoku — AniList watch-state push (ROD-284).
//!
//! One-way sync: local `list_status`/`progress` → AniList, via `SaveMediaListEntry`.
//! Delta-only. `Store.loadDirtyForSync` hands back just the rows whose (status,
//! progress) drifted from the last-synced snapshot; each landed push advances that
//! snapshot (`Store.markSynced`) so the row reads clean until it changes again.
//! Pull + reconcile is the other direction (ROD-285) — this file never reads the
//! remote list; it only writes local truth outward.
//!
//! Entry point today is `zigoku sync` (main.zig): the feature is config-file-only
//! and invisible in the TUI until ROD-286 wires a Settings trigger onto this same
//! engine. `pushAll` is written worker-friendly (it only touches the passed store,
//! io, and token, and its pacing is a plain `io.sleep`) so 286 can call it from a
//! `workers.zig` background task with no reshaping.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const anilist = @import("anilist.zig");
const auth = @import("auth.zig");
const domain = @import("domain.zig");
const store_mod = @import("store.zig");
const log = @import("log.zig");

const Store = store_mod.Store;

/// Serial pacing between pushes. AniList documents 90 req/min but has been running
/// degraded at ~30/min (ROD-284), so ~2 s/call keeps us under the *degraded*
/// ceiling with margin. This is a background side rail, never a user-blocking path,
/// so trading wall-clock for staying safely under the limit is the right call.
const MIN_INTERVAL: Io.Duration = .fromMilliseconds(2000);

/// After a 429, wait out a full fresh window before the one retry. A rate-limit
/// means we're already over the line — nibbling would just earn another 429, so we
/// back off generously rather than tune to a Retry-After we don't parse yet.
const RATE_LIMIT_BACKOFF: Io.Duration = .fromSeconds(60);

/// The outcome of one push run, rendered to human text by the CLI. Counts cover
/// the rows actually attempted; the booleans record an early stop (nothing after
/// the trigger was tried). `no_link` is informational — engaged shows with no
/// AniList id, which never entered the work-list.
pub const Summary = struct {
    /// Rows the delta query returned — the set we attempted this run.
    dirty: usize = 0,
    /// Rows AniList accepted (snapshot advanced).
    pushed: usize = 0,
    /// Rows whose push errored for a non-terminal reason; logged per row, run continues.
    failed: usize = 0,
    /// Engaged rows with no `anilist_id` — can't be pushed, reported so "skipped" is visible.
    no_link: usize = 0,
    /// No AniList token on file — nothing attempted; the user hasn't run `zigoku login`.
    signed_out: bool = false,
    /// Token past its expiry — nothing attempted; re-auth needed.
    expired: bool = false,
    /// Token rejected mid-run (401) — every further push would 401 too, so we stopped.
    unauthorized: bool = false,
    /// A retry still hit 429 — stopped early; the rest stay dirty for the next run.
    rate_limited: bool = false,
    /// Couldn't read the work-list from the store — nothing attempted.
    store_error: bool = false,
};

/// Push every dirty, engaged, id-bearing row to AniList. Total: it never returns an
/// error — every failure mode lands in the `Summary` so the caller (CLI now, a
/// worker later) renders one report instead of unwinding. `credentials` is a loaded
/// `auth.Auth` (the caller owns the load); `now_unix` dates the expiry check.
pub fn pushAll(gpa: Allocator, io: Io, st: *Store, credentials: auth.Auth, now_unix: i64) Summary {
    // Gate on a usable token before touching the store or the network.
    if (!credentials.hasAniList()) return .{ .signed_out = true };
    if (credentials.anilist.isExpired(now_unix)) return .{ .expired = true };

    var live = LiveEffects{ .io = io, .bearer = credentials.anilist.access_token };
    return pushDirty(gpa, st, live.effects());
}

/// The testable core of the push: load the delta work-list and drive each row
/// through `fx`, tallying into a `Summary`. Auth is already resolved by `pushAll`;
/// `fx` supplies the network push and the pacing sleep, so this whole loop — the
/// 429 retry, the early-stops, the per-row bookkeeping — runs under test with
/// scripted outcomes and no real network or minute-long backoffs.
fn pushDirty(gpa: Allocator, st: *Store, fx: Effects) Summary {
    var summary: Summary = .{};

    // The work-list slice lives for the whole run; per-row request/response memory
    // recycles through `scratch` (reset each iteration) so a long list doesn't
    // retain N × the 2 MB response buffer.
    var list_arena = std.heap.ArenaAllocator.init(gpa);
    defer list_arena.deinit();

    const rows = st.loadDirtyForSync(list_arena.allocator()) catch |e| {
        log.debug("sync: loadDirtyForSync failed: {s}", .{@errorName(e)});
        summary.store_error = true;
        return summary;
    };
    summary.dirty = rows.len;
    // Best-effort: a failed count only blanks the informational line, never the run.
    summary.no_link = std.math.cast(usize, st.countEngagedWithoutAniListId() catch 0) orelse 0;

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    for (rows, 0..) |row, i| {
        _ = scratch.reset(.retain_capacity);
        // Pace between calls, not before the first — a lone push shouldn't wait.
        if (i != 0) fx.sleep(MIN_INTERVAL);

        pushRow(scratch.allocator(), st, fx, row) catch |e| switch (e) {
            // Terminal for the run: every remaining push would hit the same wall.
            error.Unauthorized => {
                log.debug("sync: token rejected (401) pushing '{s}' — stopping", .{row.title});
                summary.unauthorized = true;
                return summary;
            },
            error.RateLimited => {
                log.debug("sync: still rate-limited after backoff on '{s}' — stopping", .{row.title});
                summary.rate_limited = true;
                return summary;
            },
            // Non-terminal (PushFailed / OutOfMemory): log this row, keep going.
            else => {
                summary.failed += 1;
                log.debug("sync: push failed for '{s}': {s}", .{ row.title, @errorName(e) });
                continue;
            },
        };
        summary.pushed += 1;
    }

    return summary;
}

/// Push one row, absorbing a single 429 through a backoff-and-retry. A second 429
/// (or any other error) propagates to the caller's summary arms. On success the
/// snapshot is advanced so the row stops being dirty.
fn pushRow(arena: Allocator, st: *Store, fx: Effects, row: Store.SyncRow) anilist.PushError!void {
    pushOnce(arena, st, fx, row) catch |e| {
        if (e != error.RateLimited) return e;
        log.debug("sync: rate-limited on '{s}', backing off before one retry", .{row.title});
        fx.sleep(RATE_LIMIT_BACKOFF);
        return pushOnce(arena, st, fx, row); // a second failure propagates
    };
}

/// A single `SaveMediaListEntry` upsert plus its snapshot stamp. AniList's returned
/// entry id is discarded — we key the local row by `anilist_id`, not the remote
/// entry id, so there's nothing to persist from it. A `markSynced` failure *after*
/// a landed push is non-fatal: the row simply stays dirty and re-pushes next run —
/// SaveMediaListEntry is idempotent, so that's harmless — so it's logged, never
/// propagated, and the push still counts.
fn pushOnce(arena: Allocator, st: *Store, fx: Effects, row: Store.SyncRow) anilist.PushError!void {
    _ = try fx.save(arena, row.anilist_id, row.list_status, row.progress);
    st.markSynced(row.source, row.source_id, row.list_status, row.progress) catch |e|
        log.debug("sync: markSynced failed for '{s}' after a landed push: {s}", .{ row.title, @errorName(e) });
}

/// The two outside-world effects `pushDirty`'s loop needs: pushing one entry to
/// AniList, and pacing between calls. Behind a vtable so the orchestration — retry,
/// early-stop, per-row bookkeeping — is unit-testable with scripted outcomes and no
/// real network or minute-long backoffs. `LiveEffects` wires the real ones. Internal
/// to this module: ROD-286's TUI trigger calls `pushAll`, never this seam directly.
const Effects = struct {
    ptr: *anyopaque,
    saveFn: *const fn (ptr: *anyopaque, arena: Allocator, media_id: i64, status: domain.ListStatus, progress: i64) anilist.PushError!i64,
    sleepFn: *const fn (ptr: *anyopaque, dur: Io.Duration) void,

    fn save(self: Effects, arena: Allocator, media_id: i64, status: domain.ListStatus, progress: i64) anilist.PushError!i64 {
        return self.saveFn(self.ptr, arena, media_id, status, progress);
    }
    fn sleep(self: Effects, dur: Io.Duration) void {
        self.sleepFn(self.ptr, dur);
    }
};

/// Production `Effects`: the real AniList push and a real `io.sleep`. Holds the `io`
/// and bearer the live push needs; a stack value in `pushAll` that outlives the
/// `pushDirty` call it's handed to.
const LiveEffects = struct {
    io: Io,
    bearer: []const u8,

    fn saveImpl(ptr: *anyopaque, arena: Allocator, media_id: i64, status: domain.ListStatus, progress: i64) anilist.PushError!i64 {
        const self: *LiveEffects = @ptrCast(@alignCast(ptr));
        return anilist.saveMediaListEntry(arena, self.io, self.bearer, media_id, status, progress);
    }
    fn sleepImpl(ptr: *anyopaque, dur: Io.Duration) void {
        const self: *LiveEffects = @ptrCast(@alignCast(ptr));
        self.io.sleep(dur, .awake) catch {};
    }
    fn effects(self: *LiveEffects) Effects {
        return .{ .ptr = self, .saveFn = saveImpl, .sleepFn = sleepImpl };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "pushAll: no token is a signed-out no-op, nothing attempted (ROD-284)" {
    var s = try Store.openMemory();
    defer s.close();

    // A dirty, id-bearing row exists — but with no credentials the engine must not
    // touch the network or the store; it reports signed_out and stops.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try s.upsertAnime(.{ .source = "allanime", .source_id = "a", .title = "A", .anilist_id = 1, .list_status = .watching, .progress = 1, .history_visible = true }, 1000, arena.allocator());

    const summary = pushAll(testing.allocator, undefined, &s, .{}, 2000);
    try testing.expect(summary.signed_out);
    try testing.expectEqual(@as(usize, 0), summary.dirty);
    try testing.expectEqual(@as(usize, 0), summary.pushed);
    // The row stays dirty — a signed-out run must not have advanced any snapshot.
    try testing.expectEqual(@as(usize, 1), (try s.loadDirtyForSync(arena.allocator())).len);
}

test "pushAll: an expired token is reported, nothing attempted (ROD-284)" {
    var s = try Store.openMemory();
    defer s.close();

    const creds: auth.Auth = .{ .anilist = .{ .access_token = "eyJ.stale.tok", .expires_at = 1000 } };
    // now_unix past expires_at → expired arm, before any store/network work.
    const summary = pushAll(testing.allocator, undefined, &s, creds, 2000);
    try testing.expect(summary.expired);
    try testing.expect(!summary.signed_out);
    try testing.expectEqual(@as(usize, 0), summary.pushed);
}

// A scripted `Effects` for driving `pushDirty` under test: `save` returns the next
// canned outcome in sequence; `sleep` is a no-op counter. Lets the retry and
// early-stop logic run with zero network and zero real backoff.
const ScriptedEffects = struct {
    outcomes: []const anilist.PushError!i64,
    idx: usize = 0,
    saves: usize = 0,
    sleeps: usize = 0,

    fn save(ptr: *anyopaque, arena: Allocator, media_id: i64, status: domain.ListStatus, progress: i64) anilist.PushError!i64 {
        _ = arena;
        _ = media_id;
        _ = status;
        _ = progress;
        const self: *ScriptedEffects = @ptrCast(@alignCast(ptr));
        self.saves += 1;
        const out = self.outcomes[self.idx];
        self.idx += 1;
        return out;
    }
    fn sleepImpl(ptr: *anyopaque, dur: Io.Duration) void {
        _ = dur;
        const self: *ScriptedEffects = @ptrCast(@alignCast(ptr));
        self.sleeps += 1;
    }
    fn effects(self: *ScriptedEffects) Effects {
        return .{ .ptr = self, .saveFn = save, .sleepFn = sleepImpl };
    }
};

fn seedDirty(s: *Store, arena: Allocator, source_id: []const u8, anilist_id: i64, added_at: i64) !void {
    try s.upsertAnime(.{ .source = "allanime", .source_id = source_id, .title = source_id, .anilist_id = anilist_id, .list_status = .watching, .progress = 1, .history_visible = true }, added_at, arena);
}

test "pushDirty: a 429 then success pushes the row and advances the snapshot (ROD-284)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try seedDirty(&s, arena, "a", 1, 1000);

    const outcomes = [_]anilist.PushError!i64{ error.RateLimited, 55 };
    var fx = ScriptedEffects{ .outcomes = &outcomes };
    const summary = pushDirty(testing.allocator, &s, fx.effects());

    try testing.expectEqual(@as(usize, 1), summary.pushed);
    try testing.expectEqual(@as(usize, 0), summary.failed);
    try testing.expect(!summary.rate_limited);
    try testing.expectEqual(@as(usize, 2), fx.saves); // original + one retry
    try testing.expectEqual(@as(usize, 1), fx.sleeps); // the backoff only — row 0 has no pacing sleep
    // Snapshot advanced → the row reads clean now.
    try testing.expectEqual(@as(usize, 0), (try s.loadDirtyForSync(arena)).len);
}

test "pushDirty: two 429s stop the run and leave the row dirty (ROD-284)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try seedDirty(&s, arena, "a", 1, 1000);

    const outcomes = [_]anilist.PushError!i64{ error.RateLimited, error.RateLimited };
    var fx = ScriptedEffects{ .outcomes = &outcomes };
    const summary = pushDirty(testing.allocator, &s, fx.effects());

    try testing.expect(summary.rate_limited);
    try testing.expectEqual(@as(usize, 0), summary.pushed);
    try testing.expectEqual(@as(usize, 2), fx.saves); // original + one retry, then stop
    // Row still dirty — the snapshot never advanced.
    try testing.expectEqual(@as(usize, 1), (try s.loadDirtyForSync(arena)).len);
}

test "pushDirty: a 401 mid-run stops, keeps the prior push, leaves the rest dirty (ROD-284)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    // Two dirty rows. The first save lands; the second is rejected (401) → stop.
    try seedDirty(&s, arena, "first", 1, 2000);
    try seedDirty(&s, arena, "second", 2, 1000);

    const outcomes = [_]anilist.PushError!i64{ 55, error.Unauthorized };
    var fx = ScriptedEffects{ .outcomes = &outcomes };
    const summary = pushDirty(testing.allocator, &s, fx.effects());

    try testing.expect(summary.unauthorized);
    try testing.expectEqual(@as(usize, 2), summary.dirty);
    try testing.expectEqual(@as(usize, 1), summary.pushed); // the first row landed and stuck
    // Exactly one row remains dirty: the landed push was stamped, the rejected one
    // wasn't. (Order-independent — the claim is one-of-two cleared, not which.)
    try testing.expectEqual(@as(usize, 1), (try s.loadDirtyForSync(arena)).len);
}
