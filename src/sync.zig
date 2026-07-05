//! Zigoku — AniList watch-state sync (ROD-284 push, ROD-285 pull).
//!
//! Two directions over one snapshot:
//!
//!   * **Push** (ROD-284, `pushAll`): local `list_status`/`progress` → AniList via
//!     `SaveMediaListEntry`. Delta-only — `Store.loadDirtyForSync` hands back just
//!     the rows whose pair drifted from the last-synced snapshot; each landed push
//!     advances that snapshot (`Store.markSynced`) so the row reads clean again.
//!
//!   * **Pull** (ROD-285, `pullAll`): AniList `MediaListCollection` → local, via a
//!     3-way merge. The snapshot (`synced_status`/`synced_progress`) is the common
//!     ancestor; `reconcile` merges it against local and remote per row (progress =
//!     max, status local-authoritative on a true conflict) and re-baselines the
//!     snapshot to what AniList now holds — so any locally-ahead value stays put and
//!     the next push carries it back up. The two directions compose to convergence.
//!
//! Entry point today is `zigoku sync` (main.zig), which runs push then pull: the
//! feature is config-file-only and invisible in the TUI until ROD-286 wires a
//! Settings trigger onto these same engines. Both `pushAll` and `pullAll` are
//! written worker-friendly (they touch only the passed store, io, and token) so 286
//! can call them from a `workers.zig` background task with no reshaping.

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

// ── Pull + reconcile: AniList → local (ROD-285) ──────────────────────────────

/// The outcome of one pull run, rendered to human text by the CLI. Counts cover
/// the reconcile; the booleans record an early stop where nothing was reconciled
/// (the gate/transport arms). Mutually exclusive with a normal tally: a set boolean
/// means the run never reached the merge loop.
pub const PullSummary = struct {
    /// Distinct entries AniList's list returned (deduped across custom lists).
    remote_entries: usize = 0,
    /// Local rows that joined a remote entry by `anilist_id` — the merge set.
    reconciled: usize = 0,
    /// Reconciled rows whose local (status, progress) actually changed.
    updated: usize = 0,
    /// Status conflicts (local and remote both moved, differently) kept local — the
    /// row is now dirty and the next push sends the local status up. Reported so a
    /// surprising "why didn't AniList's status take?" is visible.
    conflicts: usize = 0,
    /// Distinct remote entries with no engaged, id-bearing local row — not imported
    /// in v1 (that's a follow-up); reported so the skip is visible, not silent.
    unmatched: usize = 0,
    /// The AniList media ids behind `unmatched` (== `unmatched` in length, barring an
    /// OOM building the list), so the CLI can print them for a manual lookup instead of
    /// a bare count. Allocated from the caller's `gpa` so it outlives `reconcileAll`'s
    /// internal arena; empty when nothing is unmatched.
    unmatched_ids: []const i64 = &.{},
    /// Rows whose `applyPulled` write errored; logged per row, the run continues.
    failed: usize = 0,
    /// Rows a concurrent local edit (the TUI) moved between our read and our write —
    /// the optimistic guard skipped them to avoid clobbering the edit; they reconcile
    /// next run. Reported so the skip isn't silent.
    contended: usize = 0,
    /// No AniList token on file — nothing attempted; run `zigoku login`.
    signed_out: bool = false,
    /// Token past its expiry — nothing attempted; re-auth needed.
    expired: bool = false,
    /// Token present but no cached AniList user id — `MediaListCollection` needs one
    /// (login caches it; a hand-written auth.zon may not). Reconnect to resolve it.
    no_user_id: bool = false,
    /// Token rejected (401) — nothing to reconcile; re-auth needed.
    unauthorized: bool = false,
    /// Hit AniList's rate limit (429) — nothing reconciled; try again shortly.
    rate_limited: bool = false,
    /// Transport/HTTP/parse miss fetching the list — nothing reconciled.
    fetch_failed: bool = false,
    /// Couldn't read the local candidate set — nothing reconciled.
    store_error: bool = false,
};

/// One (status, progress) point — the merge operates on these triples.
const Pair = struct { status: domain.ListStatus, progress: i64 };

/// The merged outcome for one row, plus whether a true status conflict was resolved
/// local-authoritative (for the report).
const Merged = struct { status: domain.ListStatus, progress: i64, status_conflict: bool = false };

/// The pure 3-way merge (ROD-285). `base` is the last-synced snapshot (the common
/// ancestor; null = never synced, a first-contact bootstrap), `local` the current
/// local pair, `remote` what AniList holds now. Field-wise:
///   * progress — `max`. A watched-count never decreases, so whoever is ahead has
///     seen more; this is non-lossy and sidesteps a progress conflict entirely.
///   * status — 3-way: adopt the remote status only where local hasn't diverged from
///     the ancestor; on a true conflict (both moved, differently) keep local and
///     flag it. With no ancestor, an untouched local reads as `planning`, so a real
///     remote status is adopted while a deliberately-set local status still wins.
/// The caller re-baselines the snapshot to `remote` after applying, so a kept-local
/// value (conflict, or a higher local progress) leaves the row dirty for the push.
fn reconcile(base: ?Pair, local: Pair, remote: Pair) Merged {
    const merged_progress = @max(local.progress, remote.progress);

    const eff_base = if (base) |b| b.status else domain.ListStatus.planning;
    const local_moved = local.status != eff_base;
    const remote_moved = remote.status != eff_base;

    var merged_status = local.status; // default: local-authoritative
    var conflict = false;
    if (remote_moved and !local_moved) {
        merged_status = remote.status; // only remote moved → adopt it
    } else if (remote_moved and local_moved and remote.status != local.status) {
        conflict = true; // both moved and differ → keep local, flag for the report
    }
    // Otherwise (remote unchanged, or both converged to the same status) keep local.

    return .{ .status = merged_status, .progress = merged_progress, .status_conflict = conflict };
}

/// Pull the connected AniList list and reconcile it into local (ROD-285). Total —
/// like `pushAll` it never errors; every failure mode lands in the `PullSummary` so
/// the caller renders one report. `credentials` is a loaded `auth.Auth`; `now_unix`
/// dates the expiry check. Fetches the whole collection in one round trip, then
/// hands the entries to the network-free `reconcileAll` core.
pub fn pullAll(gpa: Allocator, io: Io, st: *Store, credentials: auth.Auth, now_unix: i64) PullSummary {
    // Same gate as the push, plus the user-id the pull query needs. `<= 0`, not `== 0`:
    // a negative id is as unusable as a zero one (a corrupt/hand-edited auth.zon) and
    // must not ride onto the wire as a GraphQL Int.
    if (!credentials.hasAniList()) return .{ .signed_out = true };
    if (credentials.anilist.isExpired(now_unix)) return .{ .expired = true };
    if (credentials.anilist.user_id <= 0) return .{ .no_user_id = true };

    // The fetched entry slice lives in this arena for the whole reconcile —
    // `PulledEntry` is all scalars (no borrowed slices), so nothing outlives it.
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

/// Map a fetch-side `PullError` to the summary bucket that reports it — split out of
/// `pullAll` so the mapping has runtime coverage without an injectable transport
/// (pull has no per-row `Effects` seam like the push loop). A failed fetch and an
/// OOM'd fetch both mean "no list to reconcile", one report line; the exhaustive
/// switch means a future `PullError` arm can't be silently dropped.
fn classifyPullOutcome(e: anilist.PullError) PullSummary {
    return switch (e) {
        error.RateLimited => .{ .rate_limited = true },
        error.Unauthorized => .{ .unauthorized = true },
        error.PullFailed, error.OutOfMemory => .{ .fetch_failed = true },
    };
}

/// The testable core of the pull: given the already-fetched remote `entries` and the
/// store, load the local candidate set, 3-way-merge each matched row, and tally.
/// Auth and the network are resolved by `pullAll`, so this whole reconcile — the
/// join, the merge, the write, the unmatched bookkeeping — runs under test with
/// canned entries and no live query.
fn reconcileAll(gpa: Allocator, st: *Store, entries: []const anilist.PulledEntry) PullSummary {
    var summary: PullSummary = .{ .remote_entries = entries.len };

    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Remote index: media_id → entry, for an O(1) join from each local row.
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

    // Distinct remote media that joined a local row → `unmatched` is the remainder.
    var matched: std.AutoHashMapUnmanaged(i64, void) = .empty;

    for (rows) |row| {
        const entry = remote.get(row.anilist_id) orelse continue; // local row AniList doesn't list
        matched.put(arena, row.anilist_id, {}) catch {}; // best-effort: only feeds a count
        summary.reconciled += 1;

        // A NULL snapshot (either column) means never-synced → no ancestor.
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
        // Re-baseline the snapshot to server truth even when local didn't change —
        // AniList may have moved to a value we didn't adopt (kept local), and the
        // snapshot must reflect what the server actually holds.
        const snap_changed = base == null or base.?.status != entry.status or base.?.progress != entry.progress;
        if (!local_changed and !snap_changed) continue; // already in sync — nothing to write

        // Guarded on the pre-merge local pair — if the TUI moved this row between the
        // bulk read above and now, the write is skipped rather than clobbering it.
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

    // Distinct remote entries that never joined an engaged local row (not imported).
    summary.unmatched = summary.remote_entries - matched.count();
    // Collect their media ids for the CLI to print (manual lookup on anilist.co). From
    // `gpa`, not the internal arena, so the slice outlives this call; best-effort — an
    // OOM here just drops the list, the count above still stands. `entries` are already
    // deduped, so this is exactly the unmatched set in insertion order.
    var unmatched_ids: std.ArrayList(i64) = .empty;
    for (entries) |e| {
        if (!matched.contains(e.media_id)) unmatched_ids.append(gpa, e.media_id) catch break;
    }
    summary.unmatched_ids = unmatched_ids.items;
    return summary;
}

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

// ── Pull + reconcile tests (ROD-285) ─────────────────────────────────────────

test "reconcile: 3-way merge — progress=max, status adopts remote only where local held (ROD-285)" {
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
    // Remote moved DOWN in progress while local held: max keeps local — never un-watch.
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
    // conflict (converged independently — the fourth branch, by name).
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
        .{ .media_id = 42, .status = .watching, .progress = 5 }, // in sync — no write
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
    // Runtime coverage for the pull's error→summary mapping (pull has no injectable
    // transport seam like the push loop, so the switch is proven here in isolation).
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
    // Local completed@12, synced there.
    try seedReconcilable(&s, arena, "a", 42, .completed, 12);
    try s.markSynced("allanime", "a", .completed, 12);

    // classifyMediaList has already folded AniList's REPEATING → .watching; the rewatch
    // reset remote progress to 2. Only remote moved (completed→watching) → adopt the
    // watching status, but max keeps the completed episode count — the design-mandated
    // outcome (you don't lose 12 episodes because a rewatch restarted the counter).
    const entries = [_]anilist.PulledEntry{.{ .media_id = 42, .status = .watching, .progress = 2 }};
    const sum = reconcileAll(testing.allocator, &s, &entries);

    try testing.expectEqual(@as(usize, 1), sum.updated);
    const rec = (try s.getAnime(arena, "allanime", "a")).?;
    try testing.expectEqual(domain.ListStatus.watching, rec.list_status);
    try testing.expectEqual(@as(i64, 12), rec.progress);
}

// A fake AniList list backing a `pushDirty` run: `save` writes the pushed value into
// an in-memory map (AniList's server state), and `toEntries` reads it back as the
// pull's input — so a test can drive push and pull against the SAME remote and prove
// the *order* between them matters.
const FakeAniList = struct {
    entries: std.AutoHashMapUnmanaged(i64, anilist.PulledEntry) = .empty,
    backing: Allocator,

    fn save(ptr: *anyopaque, arena: Allocator, media_id: i64, status: domain.ListStatus, progress: i64) anilist.PushError!i64 {
        _ = arena;
        const self: *FakeAniList = @ptrCast(@alignCast(ptr));
        // A push is a blind upsert — it overwrites whatever AniList held for this media.
        self.entries.put(self.backing, media_id, .{ .media_id = media_id, .status = status, .progress = progress }) catch return error.OutOfMemory;
        return media_id; // any non-null entry id counts as a landed push
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

    // The reachable first-sync scenario: locally we've watched eps 1-3 (engaged, never
    // synced); AniList already holds this show at watching@10 (watched on another
    // device). AniList is the fake remote, pre-loaded with the richer history.

    // ── The BUG (push-first): push blind-upserts local watching@3 over AniList's
    //    watching@10, then pull reads back watching@3 — 7 episodes of real remote
    //    history destroyed, and reported clean.
    {
        var s = try Store.openMemory();
        defer s.close();
        try seedReconcilable(&s, arena, "a", 42, .watching, 3);
        var fake = FakeAniList{ .backing = arena };
        try fake.entries.put(arena, 42, .{ .media_id = 42, .status = .watching, .progress = 10 });

        _ = pushDirty(testing.allocator, &s, fake.effects());
        try testing.expectEqual(@as(i64, 3), fake.entries.get(42).?.progress); // remote wiped 10 → 3
        _ = reconcileAll(testing.allocator, &s, try fake.toEntries(arena));
        try testing.expectEqual(@as(i64, 3), (try s.getAnime(arena, "allanime", "a")).?.progress); // unrecoverable
    }

    // ── The FIX (pull-first, the shipped order): pull sees watching@10 first, max
    //    lifts local to 10, then push carries 10 back up. Nothing lost; both converge.
    {
        var s = try Store.openMemory();
        defer s.close();
        try seedReconcilable(&s, arena, "a", 42, .watching, 3);
        var fake = FakeAniList{ .backing = arena };
        try fake.entries.put(arena, 42, .{ .media_id = 42, .status = .watching, .progress = 10 });

        _ = reconcileAll(testing.allocator, &s, try fake.toEntries(arena));
        try testing.expectEqual(@as(i64, 10), (try s.getAnime(arena, "allanime", "a")).?.progress); // preserved
        _ = pushDirty(testing.allocator, &s, fake.effects());
        try testing.expectEqual(@as(i64, 10), fake.entries.get(42).?.progress); // remote stays at 10
    }
}
