//! AniList watch-state sync (ROD-284 push, ROD-285 pull).
//!
//! One snapshot (`synced_status`/`synced_progress`) serves both directions:
//!
//!   * Push (`pushAll`): dirty local pair → SaveMediaListEntry. markSynced advances
//!     the snapshot so the row reads clean.
//!   * Pull (`pullAll`): MediaListCollection → 3-way merge (progress=max; status
//!     local-authoritative on conflict). Snapshot re-baselines to remote so
//!     local-ahead values stay dirty for the next push.
//!
//! Worker-friendly: store + io + token only (ROD-286 Settings rail via workers.zig).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const anilist = @import("anilist.zig");
const auth = @import("auth.zig");
const domain = @import("domain.zig");
const store_mod = @import("store.zig");
const log = @import("log.zig");

const Store = store_mod.Store;

/// Inter-push spacing (ROD-284). ~2s stays under degraded ~30/min AniList ceiling.
const MIN_INTERVAL: Io.Duration = .fromMilliseconds(2000);

/// Full-window backoff after a 429 before one retry (no Retry-After parse yet).
const RATE_LIMIT_BACKOFF: Io.Duration = .fromSeconds(60);

/// One push run for the CLI. Counts = attempted rows; booleans = early stop.
pub const Summary = struct {
    /// Delta work-list size this run.
    dirty: usize = 0,
    /// Accepted by AniList (snapshot advanced).
    pushed: usize = 0,
    /// Non-terminal per-row errors; run continues.
    failed: usize = 0,
    /// Engaged rows with no anilist_id (never in work-list).
    no_link: usize = 0,
    /// No token on file.
    signed_out: bool = false,
    /// Token expired.
    expired: bool = false,
    /// 401 mid-run: stop (rest would 401 too).
    unauthorized: bool = false,
    /// Still 429 after retry: stop; rest stay dirty.
    rate_limited: bool = false,
    /// loadDirtyForSync failed.
    store_error: bool = false,
};

/// Push dirty engaged id-bearing rows. Total: failures land in Summary, never error.
pub fn pushAll(gpa: Allocator, io: Io, st: *Store, credentials: auth.Auth, now_unix: i64) Summary {
    if (!credentials.hasAniList()) return .{ .signed_out = true };
    if (credentials.anilist.isExpired(now_unix)) return .{ .expired = true };

    var live = LiveEffects{ .io = io, .bearer = credentials.anilist.access_token };
    return pushDirty(gpa, st, live.effects());
}

/// Testable push core: work-list + fx (network/sleep). Auth resolved by pushAll.
fn pushDirty(gpa: Allocator, st: *Store, fx: Effects) Summary {
    var summary: Summary = .{};

    // Work-list lives whole run; scratch resets per row (avoids N × 2 MB buffers).
    var list_arena = std.heap.ArenaAllocator.init(gpa);
    defer list_arena.deinit();

    const rows = st.loadDirtyForSync(list_arena.allocator()) catch |e| {
        log.debug("sync: loadDirtyForSync failed: {s}", .{@errorName(e)});
        summary.store_error = true;
        return summary;
    };
    summary.dirty = rows.len;
    // Best-effort info line only.
    summary.no_link = std.math.cast(usize, st.countEngagedWithoutAniListId() catch 0) orelse 0;

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    for (rows, 0..) |row, i| {
        _ = scratch.reset(.retain_capacity);
        // Pace between calls, not before the first.
        if (i != 0) fx.sleep(MIN_INTERVAL);

        pushRow(scratch.allocator(), st, fx, row) catch |e| switch (e) {
            // Terminal: rest of run would hit the same wall.
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
            // Non-terminal: log row, continue.
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

/// One row: absorb a single 429 (backoff + retry); second failure propagates.
fn pushRow(arena: Allocator, st: *Store, fx: Effects, row: Store.SyncRow) anilist.PushError!void {
    pushOnce(arena, st, fx, row) catch |e| {
        if (e != error.RateLimited) return e;
        log.debug("sync: rate-limited on '{s}', backing off before one retry", .{row.title});
        fx.sleep(RATE_LIMIT_BACKOFF);
        return pushOnce(arena, st, fx, row);
    };
}

/// SaveMediaListEntry + markSynced. Entry id discarded (we key by anilist_id).
/// markSynced failure after a landed push is non-fatal (idempotent re-push next run).
fn pushOnce(arena: Allocator, st: *Store, fx: Effects, row: Store.SyncRow) anilist.PushError!void {
    _ = try fx.save(arena, row.anilist_id, row.list_status, row.progress);
    st.markSynced(row.source, row.source_id, row.list_status, row.progress) catch |e|
        log.debug("sync: markSynced failed for '{s}' after a landed push: {s}", .{ row.title, @errorName(e) });
}

/// Injected save + sleep so pushDirty is unit-testable. TUI uses pushAll, not this.
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

/// Live AniList push + io.sleep.
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

// ── Pull + reconcile: AniList → local (ROD-285) ──────────────────────────────

/// One pull run for the CLI. Counts = merge tally; set booleans mean never reached merge.
pub const PullSummary = struct {
    /// Distinct remote entries (deduped custom lists).
    remote_entries: usize = 0,
    /// Local rows that joined a remote by anilist_id.
    reconciled: usize = 0,
    /// Local (status, progress) actually changed.
    updated: usize = 0,
    /// Status conflict: kept local, row dirty for push.
    conflicts: usize = 0,
    /// Remote with no engaged local row (v1: not imported).
    unmatched: usize = 0,
    /// Media ids for unmatched (gpa-owned, outlives reconcileAll). Empty if none.
    unmatched_ids: []const i64 = &.{},
    /// applyPulled store errors; run continues.
    failed: usize = 0,
    /// Concurrent local edit: CAS guard skipped write; retry next run.
    contended: usize = 0,
    signed_out: bool = false,
    expired: bool = false,
    /// Token present but no user_id (MediaListCollection needs it).
    no_user_id: bool = false,
    unauthorized: bool = false,
    rate_limited: bool = false,
    fetch_failed: bool = false,
    store_error: bool = false,
};

const Pair = struct { status: domain.ListStatus, progress: i64 };

const Merged = struct { status: domain.ListStatus, progress: i64, status_conflict: bool = false };

/// Pure 3-way merge (ROD-285). base = last-synced ancestor (null = first contact).
/// progress = max. status: adopt remote only if local unmoved from base; both moved
/// differently → keep local + conflict. Caller re-baselines snapshot to remote.
fn reconcile(base: ?Pair, local: Pair, remote: Pair) Merged {
    const merged_progress = @max(local.progress, remote.progress);

    const eff_base = if (base) |b| b.status else domain.ListStatus.planning;
    const local_moved = local.status != eff_base;
    const remote_moved = remote.status != eff_base;

    var merged_status = local.status; // default: local-authoritative
    var conflict = false;
    if (remote_moved and !local_moved) {
        merged_status = remote.status;
    } else if (remote_moved and local_moved and remote.status != local.status) {
        conflict = true;
    }

    return .{ .status = merged_status, .progress = merged_progress, .status_conflict = conflict };
}

/// Pull list + reconcile into local (ROD-285). Total: failures land in PullSummary.
pub fn pullAll(gpa: Allocator, io: Io, st: *Store, credentials: auth.Auth, now_unix: i64) PullSummary {
    // user_id <= 0 unusable (corrupt auth.zon); do not send on the wire.
    if (!credentials.hasAniList()) return .{ .signed_out = true };
    if (credentials.anilist.isExpired(now_unix)) return .{ .expired = true };
    if (credentials.anilist.user_id <= 0) return .{ .no_user_id = true };

    // PulledEntry is all scalars; arena covers the fetch for the reconcile.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const entries = anilist.mediaListCollection(
        arena.allocator(),
        io,
        credentials.anilist.access_token,
        credentials.anilist.user_id,
    ) catch |e| return classifyPullOutcome(e);
    return reconcileAll(gpa, st, entries);
}

/// PullError → summary bucket. Exhaustive so new arms cannot be dropped silently.
fn classifyPullOutcome(e: anilist.PullError) PullSummary {
    return switch (e) {
        error.RateLimited => .{ .rate_limited = true },
        error.Unauthorized => .{ .unauthorized = true },
        error.PullFailed, error.OutOfMemory => .{ .fetch_failed = true },
    };
}

/// Network-free reconcile core: join local candidates to remote, merge, write, tally.
fn reconcileAll(gpa: Allocator, st: *Store, entries: []const anilist.PulledEntry) PullSummary {
    var summary: PullSummary = .{ .remote_entries = entries.len };

    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var remote: std.AutoHashMapUnmanaged(i64, anilist.PulledEntry) = .empty;
    for (entries) |e| remote.put(arena, e.media_id, e) catch {
        log.debug("pull: building the remote index failed (OOM) — aborting reconcile", .{});
        summary.store_error = true;
        return summary;
    };

    const rows = st.loadReconcileRows(arena) catch |e| {
        log.debug("pull: loadReconcileRows failed: {s}", .{@errorName(e)});
        summary.store_error = true;
        return summary;
    };

    var matched: std.AutoHashMapUnmanaged(i64, void) = .empty;

    for (rows) |row| {
        const entry = remote.get(row.anilist_id) orelse continue;
        matched.put(arena, row.anilist_id, {}) catch {};
        summary.reconciled += 1;

        // NULL snapshot either column → no ancestor.
        const base: ?Pair = if (row.synced_status) |ss|
            if (row.synced_progress) |sp| Pair{ .status = ss, .progress = sp } else null
        else
            null;

        const merged = reconcile(
            base,
            .{ .status = row.list_status, .progress = row.progress },
            .{ .status = entry.status, .progress = entry.progress },
        );
        if (merged.status_conflict) summary.conflicts += 1;

        const local_changed = merged.status != row.list_status or merged.progress != row.progress;
        // Always re-baseline snapshot to server truth when remote moved (kept-local stays dirty).
        const snap_changed = base == null or base.?.status != entry.status or base.?.progress != entry.progress;
        if (!local_changed and !snap_changed) continue;

        // CAS on pre-merge pair: TUI edit mid-flight skips rather than clobber.
        const applied = st.applyPulled(row.source, row.source_id, merged.status, merged.progress, entry.status, entry.progress, row.list_status, row.progress) catch |e| {
            summary.failed += 1;
            log.debug("pull: applyPulled failed for {s}/{s}: {s}", .{ row.source, row.source_id, @errorName(e) });
            continue;
        };
        if (!applied) {
            summary.contended += 1;
            log.debug("pull: {s}/{s} changed under reconcile — skipped, retries next run", .{ row.source, row.source_id });
            continue;
        }
        if (local_changed) summary.updated += 1;
    }

    summary.unmatched = summary.remote_entries - matched.count();
    // gpa-owned ids for CLI (outlive arena). OOM drops list; count still stands.
    var unmatched_ids: std.ArrayList(i64) = .empty;
    for (entries) |e| {
        if (!matched.contains(e.media_id)) unmatched_ids.append(gpa, e.media_id) catch break;
    }
    // toOwnedSlice exact-fit: free(items) on over-alloc buffer panics real gpa (ROD-291).
    summary.unmatched_ids = unmatched_ids.toOwnedSlice(gpa) catch blk: {
        unmatched_ids.deinit(gpa);
        break :blk &.{};
    };
    return summary;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "pushAll: no token is a signed-out no-op, nothing attempted (ROD-284)" {
    var s = try Store.openMemory();
    defer s.close();

    // Dirty row present; no creds → signed_out, no network/store writes.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try s.upsertAnime(.{ .source = "allanime", .source_id = "a", .title = "A", .anilist_id = 1, .list_status = .watching, .progress = 1, .history_visible = true }, 1000, arena.allocator());

    const summary = pushAll(testing.allocator, undefined, &s, .{}, 2000);
    try testing.expect(summary.signed_out);
    try testing.expectEqual(@as(usize, 0), summary.dirty);
    try testing.expectEqual(@as(usize, 0), summary.pushed);
    try testing.expectEqual(@as(usize, 1), (try s.loadDirtyForSync(arena.allocator())).len);
}

test "pushAll: an expired token is reported, nothing attempted (ROD-284)" {
    var s = try Store.openMemory();
    defer s.close();

    const creds: auth.Auth = .{ .anilist = .{ .access_token = "eyJ.stale.tok", .expires_at = 1000 } };
    // now past expires_at → expired before store/network.
    const summary = pushAll(testing.allocator, undefined, &s, creds, 2000);
    try testing.expect(summary.expired);
    try testing.expect(!summary.signed_out);
    try testing.expectEqual(@as(usize, 0), summary.pushed);
}

// Scripted Effects for pushDirty tests: canned save outcomes, sleep counter.
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
    try testing.expectEqual(@as(usize, 1), fx.sleeps); // backoff only (no inter-row pace)
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
    try testing.expectEqual(@as(usize, 1), (try s.loadDirtyForSync(arena)).len);
}

test "pushDirty: a 401 mid-run stops, keeps the prior push, leaves the rest dirty (ROD-284)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    // First lands; second 401 → stop.
    try seedDirty(&s, arena, "first", 1, 2000);
    try seedDirty(&s, arena, "second", 2, 1000);

    const outcomes = [_]anilist.PushError!i64{ 55, error.Unauthorized };
    var fx = ScriptedEffects{ .outcomes = &outcomes };
    const summary = pushDirty(testing.allocator, &s, fx.effects());

    try testing.expect(summary.unauthorized);
    try testing.expectEqual(@as(usize, 2), summary.dirty);
    try testing.expectEqual(@as(usize, 1), summary.pushed);
    // One of two still dirty (landed stamped; rejected not).
    try testing.expectEqual(@as(usize, 1), (try s.loadDirtyForSync(arena)).len);
}

// ── Pull + reconcile tests (ROD-285) ─────────────────────────────────────────

test "reconcile: 3-way merge: progress=max, status adopts remote only where local held (ROD-285)" {
    const S = domain.ListStatus;
    const base: Pair = .{ .status = .watching, .progress = 3 };

    // Only remote moved (local == base): adopt the remote status; progress is max.
    {
        const m = reconcile(base, .{ .status = .watching, .progress = 3 }, .{ .status = .completed, .progress = 12 });
        try testing.expectEqual(S.completed, m.status);
        try testing.expectEqual(@as(i64, 12), m.progress);
        try testing.expect(!m.status_conflict);
    }
    // Only local moved (remote == base): keep local; progress is max (local ahead).
    {
        const m = reconcile(base, .{ .status = .completed, .progress = 12 }, .{ .status = .watching, .progress = 3 });
        try testing.expectEqual(S.completed, m.status);
        try testing.expectEqual(@as(i64, 12), m.progress);
        try testing.expect(!m.status_conflict);
    }
    // Both moved, differently → true conflict: keep local, flag it. (Rod's preview.)
    {
        const m = reconcile(base, .{ .status = .completed, .progress = 12 }, .{ .status = .paused, .progress = 5 });
        try testing.expectEqual(S.completed, m.status); // local-authoritative
        try testing.expectEqual(@as(i64, 12), m.progress); // max
        try testing.expect(m.status_conflict);
    }
    // Both converged to the same status independently → no conflict, keep (== either).
    {
        const m = reconcile(base, .{ .status = .completed, .progress = 12 }, .{ .status = .completed, .progress = 8 });
        try testing.expectEqual(S.completed, m.status);
        try testing.expectEqual(@as(i64, 12), m.progress);
        try testing.expect(!m.status_conflict);
    }
    // Remote moved DOWN in progress while local held: max keeps local, never un-watch.
    {
        const m = reconcile(base, .{ .status = .watching, .progress = 3 }, .{ .status = .watching, .progress = 1 });
        try testing.expectEqual(@as(i64, 3), m.progress);
    }
}

test "reconcile: first contact (no ancestor) adopts remote onto planning, keeps a set local (ROD-285)" {
    const S = domain.ListStatus;
    // Untouched local (default planning) + a real remote status → adopt remote.
    {
        const m = reconcile(null, .{ .status = .planning, .progress = 0 }, .{ .status = .completed, .progress = 12 });
        try testing.expectEqual(S.completed, m.status);
        try testing.expectEqual(@as(i64, 12), m.progress);
        try testing.expect(!m.status_conflict);
    }
    // A deliberately-set local status + a differing remote → conflict, keep local.
    {
        const m = reconcile(null, .{ .status = .watching, .progress = 4 }, .{ .status = .dropped, .progress = 4 });
        try testing.expectEqual(S.watching, m.status);
        try testing.expect(m.status_conflict);
    }
    // A local status + remote still at planning → keep local, no conflict (remote didn't move).
    {
        const m = reconcile(null, .{ .status = .watching, .progress = 4 }, .{ .status = .planning, .progress = 0 });
        try testing.expectEqual(S.watching, m.status);
        try testing.expectEqual(@as(i64, 4), m.progress);
        try testing.expect(!m.status_conflict);
    }
    // Both sides already agree on a non-default status with no ancestor → keep it, no
    // conflict (converged independently, the fourth branch, by name).
    {
        const m = reconcile(null, .{ .status = .completed, .progress = 12 }, .{ .status = .completed, .progress = 12 });
        try testing.expectEqual(S.completed, m.status);
        try testing.expectEqual(@as(i64, 12), m.progress);
        try testing.expect(!m.status_conflict);
    }
}

test "pullAll: signed-out / expired / no-user-id are no-ops before any fetch (ROD-285)" {
    var s = try Store.openMemory();
    defer s.close();

    // No token → signed_out, before touching io or the store.
    try testing.expect(pullAll(testing.allocator, undefined, &s, .{}, 2000).signed_out);

    // Token past expiry → expired.
    const stale: auth.Auth = .{ .anilist = .{ .access_token = "eyJ.tok", .expires_at = 1000, .user_id = 7 } };
    try testing.expect(pullAll(testing.allocator, undefined, &s, stale, 2000).expired);

    // Live token but no cached user id → no_user_id (MediaListCollection needs one).
    const no_uid: auth.Auth = .{ .anilist = .{ .access_token = "eyJ.tok", .expires_at = 0, .user_id = 0 } };
    const sum = pullAll(testing.allocator, undefined, &s, no_uid, 2000);
    try testing.expect(sum.no_user_id);
    try testing.expect(!sum.signed_out);
}

fn seedReconcilable(s: *Store, arena: Allocator, source_id: []const u8, anilist_id: i64, status: domain.ListStatus, progress: i64) !void {
    try s.upsertAnime(.{ .source = "allanime", .source_id = source_id, .title = source_id, .anilist_id = anilist_id, .list_status = status, .progress = progress, .history_visible = true }, 1000, arena);
}

test "reconcileAll: a remote-ahead entry updates local and lands clean (ROD-285)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    // A synced row (base = watching@3); AniList has since advanced to watching@8.
    try seedReconcilable(&s, arena, "a", 42, .watching, 3);
    try s.markSynced("allanime", "a", .watching, 3);

    const entries = [_]anilist.PulledEntry{.{ .media_id = 42, .status = .watching, .progress = 8 }};
    const sum = reconcileAll(testing.allocator, &s, &entries);

    try testing.expectEqual(@as(usize, 1), sum.remote_entries);
    try testing.expectEqual(@as(usize, 1), sum.reconciled);
    try testing.expectEqual(@as(usize, 1), sum.updated);
    try testing.expectEqual(@as(usize, 0), sum.conflicts);
    try testing.expectEqual(@as(usize, 0), sum.unmatched);

    // Local advanced to 8, and the snapshot re-baselined to remote → row reads clean.
    const rec = (try s.getAnime(arena, "allanime", "a")).?;
    try testing.expectEqual(@as(i64, 8), rec.progress);
    try testing.expectEqual(@as(usize, 0), (try s.loadDirtyForSync(arena)).len);
}

test "reconcileAll: a status conflict keeps local and leaves the row dirty for push (ROD-285)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    // base = watching@3. Local moved to completed@12; AniList moved to paused@5.
    try seedReconcilable(&s, arena, "a", 42, .watching, 3);
    try s.markSynced("allanime", "a", .watching, 3);
    try s.setListStatus("allanime", "a", .completed);
    try s.recordPlay("allanime", "a", 12, 2000, true);

    const entries = [_]anilist.PulledEntry{.{ .media_id = 42, .status = .paused, .progress = 5 }};
    const sum = reconcileAll(testing.allocator, &s, &entries);

    try testing.expectEqual(@as(usize, 1), sum.reconciled);
    try testing.expectEqual(@as(usize, 1), sum.conflicts);
    try testing.expectEqual(@as(usize, 0), sum.updated); // merged == local, no local change

    // Local kept completed@12; snapshot re-baselined to remote (paused@5) → dirty.
    const rec = (try s.getAnime(arena, "allanime", "a")).?;
    try testing.expectEqual(domain.ListStatus.completed, rec.list_status);
    try testing.expectEqual(@as(i64, 12), rec.progress);
    const dirty = try s.loadDirtyForSync(arena);
    try testing.expectEqual(@as(usize, 1), dirty.len);
    try testing.expectEqual(domain.ListStatus.completed, dirty[0].list_status);
}

test "reconcileAll: unmatched remote counted, local-only row untouched (ROD-285)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    // Local row for media 42; AniList returns 42 (matches) AND 99 (no local row).
    try seedReconcilable(&s, arena, "a", 42, .watching, 5);
    try s.markSynced("allanime", "a", .watching, 5);

    const entries = [_]anilist.PulledEntry{
        .{ .media_id = 42, .status = .watching, .progress = 5 }, // in sync, no write
        .{ .media_id = 99, .status = .completed, .progress = 24 }, // no local row → unmatched
    };
    // Pass the test arena as gpa so the unmatched-id list is freed with it (no leak).
    const sum = reconcileAll(arena, &s, &entries);

    try testing.expectEqual(@as(usize, 2), sum.remote_entries);
    try testing.expectEqual(@as(usize, 1), sum.reconciled); // only media 42 joined
    try testing.expectEqual(@as(usize, 0), sum.updated); // 42 already in sync
    try testing.expectEqual(@as(usize, 1), sum.unmatched); // media 99 not imported
    // The unmatched id is surfaced for the CLI's manual-lookup list.
    try testing.expectEqual(@as(usize, 1), sum.unmatched_ids.len);
    try testing.expectEqual(@as(i64, 99), sum.unmatched_ids[0]);
    // No phantom row was created for the unmatched remote entry.
    try testing.expectEqual(@as(usize, 1), (try s.loadReconcileRows(arena)).len);
}

test "reconcileAll: unmatched_ids is exact-fit, safe to free on a real gpa (ROD-291)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try seedReconcilable(&s, arena, "a", 42, .watching, 5);
    try s.markSynced("allanime", "a", .watching, 5);

    // unmatched_ids must be exact-fit (toOwnedSlice): free(items) panics real gpa
    // on over-alloc buffer (ROD-291). testing.allocator free proves the contract.
    const entries = [_]anilist.PulledEntry{
        .{ .media_id = 42, .status = .watching, .progress = 5 },
        .{ .media_id = 99, .status = .completed, .progress = 24 },
    };
    const sum = reconcileAll(testing.allocator, &s, &entries);
    try testing.expectEqual(@as(usize, 1), sum.unmatched_ids.len);
    testing.allocator.free(sum.unmatched_ids);
}

test "reconcileAll: first contact adopts an AniList status onto an unsynced planning row (ROD-285)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    // Never synced (NULL snapshot), local at the planning default. AniList: completed@12.
    try seedReconcilable(&s, arena, "a", 42, .planning, 0);

    const entries = [_]anilist.PulledEntry{.{ .media_id = 42, .status = .completed, .progress = 12 }};
    const sum = reconcileAll(testing.allocator, &s, &entries);

    try testing.expectEqual(@as(usize, 1), sum.updated);
    try testing.expectEqual(@as(usize, 0), sum.conflicts);
    const rec = (try s.getAnime(arena, "allanime", "a")).?;
    try testing.expectEqual(domain.ListStatus.completed, rec.list_status);
    try testing.expectEqual(@as(i64, 12), rec.progress);
    // Snapshot baselined to remote → clean (local == remote here).
    try testing.expectEqual(@as(usize, 0), (try s.loadDirtyForSync(arena)).len);
}

test "classifyPullOutcome: each fetch error maps to its own summary bucket (ROD-285)" {
    try testing.expect(classifyPullOutcome(error.RateLimited).rate_limited);
    try testing.expect(classifyPullOutcome(error.Unauthorized).unauthorized);
    try testing.expect(classifyPullOutcome(error.PullFailed).fetch_failed);
    try testing.expect(classifyPullOutcome(error.OutOfMemory).fetch_failed);
}

test "reconcileAll: a rewatch (REPEATING→watching) adopts watching but keeps progress via max (ROD-285)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var s = try Store.openMemory();
    defer s.close();
    try seedReconcilable(&s, arena, "a", 42, .completed, 12);
    try s.markSynced("allanime", "a", .completed, 12);

    // REPEATING already folded to watching; remote progress 2. Adopt watching; max keeps 12.
    const entries = [_]anilist.PulledEntry{.{ .media_id = 42, .status = .watching, .progress = 2 }};
    const sum = reconcileAll(testing.allocator, &s, &entries);

    try testing.expectEqual(@as(usize, 1), sum.updated);
    const rec = (try s.getAnime(arena, "allanime", "a")).?;
    try testing.expectEqual(domain.ListStatus.watching, rec.list_status);
    try testing.expectEqual(@as(i64, 12), rec.progress);
}

// Fake remote for push+pull order tests: save mutates map; toEntries feeds pull.
const FakeAniList = struct {
    entries: std.AutoHashMapUnmanaged(i64, anilist.PulledEntry) = .empty,
    backing: Allocator,

    fn save(ptr: *anyopaque, arena: Allocator, media_id: i64, status: domain.ListStatus, progress: i64) anilist.PushError!i64 {
        _ = arena;
        const self: *FakeAniList = @ptrCast(@alignCast(ptr));
        self.entries.put(self.backing, media_id, .{ .media_id = media_id, .status = status, .progress = progress }) catch return error.OutOfMemory;
        return media_id;
    }
    fn sleepImpl(ptr: *anyopaque, dur: Io.Duration) void {
        _ = ptr;
        _ = dur;
    }
    fn effects(self: *FakeAniList) Effects {
        return .{ .ptr = self, .saveFn = save, .sleepFn = sleepImpl };
    }
    fn toEntries(self: *FakeAniList, a: Allocator) ![]anilist.PulledEntry {
        var list: std.ArrayList(anilist.PulledEntry) = .empty;
        var it = self.entries.iterator();
        while (it.next()) |kv| try list.append(a, kv.value_ptr.*);
        return list.toOwnedSlice(a);
    }
};

test "pull-before-push preserves AniList history a blind push-first would wipe (ROD-285 regression)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Local watching@3 never synced; remote watching@10 (other device).

    // Bug (push-first): blind upsert 3 over 10, then pull locks in the wipe.
    {
        var s = try Store.openMemory();
        defer s.close();
        try seedReconcilable(&s, arena, "a", 42, .watching, 3);
        var fake = FakeAniList{ .backing = arena };
        try fake.entries.put(arena, 42, .{ .media_id = 42, .status = .watching, .progress = 10 });

        _ = pushDirty(testing.allocator, &s, fake.effects());
        try testing.expectEqual(@as(i64, 3), fake.entries.get(42).?.progress);
        _ = reconcileAll(testing.allocator, &s, try fake.toEntries(arena));
        try testing.expectEqual(@as(i64, 3), (try s.getAnime(arena, "allanime", "a")).?.progress);
    }

    // Fix (pull-first): max lifts local to 10, push keeps remote at 10.
    {
        var s = try Store.openMemory();
        defer s.close();
        try seedReconcilable(&s, arena, "a", 42, .watching, 3);
        var fake = FakeAniList{ .backing = arena };
        try fake.entries.put(arena, 42, .{ .media_id = 42, .status = .watching, .progress = 10 });

        _ = reconcileAll(testing.allocator, &s, try fake.toEntries(arena));
        try testing.expectEqual(@as(i64, 10), (try s.getAnime(arena, "allanime", "a")).?.progress);
        _ = pushDirty(testing.allocator, &s, fake.effects());
        try testing.expectEqual(@as(i64, 10), fake.entries.get(42).?.progress);
    }
}
