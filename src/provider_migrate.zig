//! Zigoku — one-time provider-cutover backfill (ROD-308).
//!
//! The v12 schema migration (store.zig) re-keys allanime rows that already carry a
//! `mal_id` onto senshi offline. This closes the gap for rows enriched BEFORE `idMal`
//! joined the enrichment fieldset: they hold an `anilist_id` but no `mal_id`, so the
//! offline re-key skips them. Here we resolve `anilist_id -> idMal` over the network
//! (public, unauthed `enrichBatch` — works for every user, not just linked accounts),
//! stamp the `mal_id`, then run the SAME re-key to move them onto senshi — widening
//! the cutover from ~37% to ~83% of a real watchlist.
//!
//! Best-effort and one-shot: gated by an `app_meta` marker so it runs once. A network
//! miss mid-run banks what landed and retries next launch (the `mal_id`-present
//! predicate self-excludes what already resolved), never stamping the marker until a
//! clean pass. Only a store/allocation fault propagates to the (best-effort) caller.

const std = @import("std");
const anilist = @import("anilist.zig");
const store_mod = @import("store.zig");

const Store = store_mod.Store;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// `app_meta` key: set to "done" after a full clean pass so the backfill never re-runs.
const MARKER_KEY = "provider_backfill_v1";

/// AniList caps `Page(perPage:…)` at 50, so the id work-list is resolved in chunks of
/// this size — a larger page 400s (→ enrichBatch `error.NoAnswer`).
const CHUNK: usize = 50;

pub const Summary = struct {
    /// Marker already set → the backfill did nothing this launch.
    skipped: bool = false,
    /// allanime rows carrying an `anilist_id` but no `mal_id` — the work-list size.
    candidates: usize = 0,
    /// of those, how many AniList returned an `idMal` for.
    resolved: usize = 0,
    /// rows the post-backfill re-key then moved off the allanime key.
    rekeyed: usize = 0,
    /// every chunk answered → marker stamped, won't run again.
    completed: bool = false,
};

/// Run the one-time backfill against `store`. Owns a scratch arena so its working
/// memory (the id list + the parsed AniList pages) is freed before the caller
/// proceeds into the TUI. Network failures are handled internally; only a store or
/// allocation fault propagates.
pub fn run(gpa: Allocator, io: Io, store: *Store) !Summary {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var sum: Summary = .{};

    // Gate: one clean pass, then never again.
    if (try store.metaGet(arena, MARKER_KEY)) |_| {
        sum.skipped = true;
        return sum;
    }

    const ids = try store.listBackfillAnilistIds(arena);
    sum.candidates = ids.len;
    if (ids.len == 0) {
        // Nothing resolvable (fresh DB, or all rows already have mal_id) — stamp so we
        // never revisit.
        try store.metaSet(MARKER_KEY, "done");
        sum.completed = true;
        return sum;
    }

    var all_chunks_ok = true;
    var i: usize = 0;
    while (i < ids.len) : (i += CHUNK) {
        const end = @min(i + CHUNK, ids.len);
        const chunk = ids[i..end];

        // enrichBatch wants `[]const u64`; AniList ids are positive, so the cast is safe.
        const batch = try arena.alloc(u64, chunk.len);
        for (chunk, 0..) |id, j| batch[j] = @intCast(id);

        const metas = anilist.enrichBatch(arena, io, batch) catch |err| switch (err) {
            // NoAnswer: network down / rate-limited / malformed. Stop rather than hammer
            // a possibly-throttled endpoint; next launch resumes incrementally.
            error.NoAnswer => {
                all_chunks_ok = false;
                break;
            },
            // OutOfMemory is real — propagate (the caller runs it best-effort anyway).
            else => |e| return e,
        };
        for (metas) |m| {
            const aid = m.anilist_id orelse continue; // the id AniList echoed back
            const mal = m.mal_id orelse continue; // AniList entry with no MAL id → dark tail.
            try store.setMalIdByAnilistId(@intCast(aid), @intCast(mal));
            sum.resolved += 1;
        }
    }

    // Move everything freshly eligible (and any stragglers) onto senshi. Count first —
    // the re-key empties the bucket, so this is the "how many more re-keyed" number.
    sum.rekeyed = try store.countMigratableAllanime();
    try store.rekeyLegacyProvider();

    // Only claim done — and skip every future launch — after a full clean pass. A run
    // cut short by the network leaves the marker unset so the rest resumes next time.
    if (all_chunks_ok) {
        try store.metaSet(MARKER_KEY, "done");
        sum.completed = true;
    }
    return sum;
}

/// Print the one-time progress lines above the TUI before it opens. Silent when there
/// was nothing to do (marker already set, or zero candidates on a clean pass), so a
/// normal launch prints nothing.
pub fn report(out: *Io.Writer, sum: Summary) !void {
    if (sum.skipped or sum.candidates == 0) return;

    try out.print("  migrating watchlist to senshi…\n", .{});
    try out.print("    · resolved {d}/{d} shows via AniList\n", .{ sum.resolved, sum.candidates });
    if (sum.rekeyed > 0)
        try out.print("    · re-keyed {d} onto senshi\n", .{sum.rekeyed});
    if (!sum.completed)
        try out.print("    · network incomplete — will finish next launch\n", .{});
    try out.flush();
}
