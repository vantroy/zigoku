//! Zigoku: Discover feed controller subsystem (ROD-239, AniList-backed since ROD-336).
//!
//! Owns the RECORD of the Discover feed: the active ranking axis, the grid
//! cursor/scroll, and a short-lived per-axis result cache. Transport (the worker thread,
//! the slow-path timer) stays on App, mirroring SearchController: App resolves nav state and
//! hands primitives in; this struct never reaches back into App. Embed by value.
//!
//! The view (`view/discover.zig`) renders this; DiscoverState is re-exported from app.zig.

const std = @import("std");
const domain = @import("../domain.zig");
const anilist = @import("../anilist.zig");
const store_mod = @import("../store.zig");
const workers = @import("workers.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const Anime = domain.Anime;
const Store = store_mod.Store;
const freeOwnedAnime = workers.freeOwnedAnime;

/// One cached feed axis. Holds *that axis's* fetched page(s), the
/// loaded-page count, the fetch timestamp (for the TTL), and the in-flight flag.
pub const Slot = struct {
    /// Accumulated, gpa-owned results for this axis; freed on TTL-expiry
    /// refetch and on teardown. Access via `self.discover.activeSlot().results`.
    results: std.ArrayListUnmanaged(Anime) = .empty,
    /// Loaded-page count (0 = never fetched, 1 = first page, …).
    page: u32 = 0,
    /// `Store.nowSecs()` stamp of the last successful fetch (0 = never). The TTL
    /// (`feed_ttl_secs`) is measured from here on axis-switch / re-open.
    fetched_at: i64 = 0,
    /// Whether a fetch for this axis is in flight.
    loading: bool = false,
    /// Whether the last fetch for this axis failed (ROD-239). Surfaces the
    /// in-view "can't reach the feed" state only while the slot is also empty;
    /// cleared on the next successful page. A retry sets `loading`, which the view
    /// shows ahead of this.
    failed: bool = false,
    /// Whether the feed has no more pages: AniList's `pageInfo.hasNextPage` came
    /// back false (ROD-336, §9.6). Stops the load-more prefetch and flips the
    /// footer to "all entries loaded".
    exhausted: bool = false,
};

/// The Discover-feed controller (ROD-239).
///
/// ── CORRECTNESS INVARIANT: one independent slot per axis ────────────────────
/// `slots` is FOUR separate owned lists, one per `DiscoverAxis`, NEVER a single shared
/// list that gets re-sorted. Each axis is an independent AniList ranking, so the same
/// show sits at a different rank (and page position) per axis, and the card's `#N`
/// label is positional, so a shared list would lie about rank the moment the axis
/// changes. Never intern or share an `Anime` across slots: a show on all four axes is
/// four independent owned copies (ownership is per-slot; `clearSlot` frees per-slot).
pub const DiscoverState = struct {
    /// The active ranking axis; drives both the axis bar and the fetch (§3.8/§9.6).
    axis: anilist.DiscoverAxis = .trending,

    /// Grid cursor: a flat index into the active axis's results (the episode-grid
    /// flat-index→2D positioning is resolved render-side from the column count).
    cursor: usize = 0,
    /// Top card-row offset for the scrolled grid viewport (settled in App.layout).
    scroll: usize = 0,

    /// Per-axis result cache; see the struct-level invariant. Indexed by
    /// `@intFromEnum(axis)` (trending=0, popular=1, top_rated=2, this_season=3).
    slots: [4]Slot = .{ .{}, .{}, .{}, .{} },

    /// The slot for the active axis (const, the render path). The fetch/cache path
    /// indexes `slots[@intFromEnum(axis)]` directly with a mutable App.
    pub fn activeSlot(self: *const DiscoverState) *const Slot {
        return &self.slots[@intFromEnum(self.axis)];
    }

    /// Free one axis's accumulated results and reset it to "never fetched".
    /// `gpa` is the same allocator the results were appended with (App's `gpa`).
    pub fn clearSlot(self: *DiscoverState, gpa: Allocator, idx: usize) void {
        const slot = &self.slots[idx];
        for (slot.results.items) |r| freeOwnedAnime(gpa, r);
        slot.results.clearRetainingCapacity();
        slot.page = 0;
        slot.fetched_at = 0;
        slot.exhausted = false;
    }

    /// Mirror an axis slot's [offset, offset+count) rows into the canonical spine
    /// (ROD-336), exactly as Browse search does (`SearchController.persistResults`):
    /// feed rows are anilist_id-keyed canonical entities, never provider bindings;
    /// binding to a play provider is the resolver's job (ROD-328). Rows arrive fully
    /// enriched (full GQL_FIELDS), so every row is a confirmed answer: stamp fresh
    /// (see `upsertCanonicalOnly`'s doc for the gate contract). Best effort: a write
    /// failure never disrupts the feed. `store` is resolved by App and passed in;
    /// this never reads App.
    pub fn persistSlot(self: *DiscoverState, gpa: Allocator, store: ?*Store, idx: usize, offset: usize, count: usize) void {
        const st = store orelse return;
        const items = self.slots[idx].results.items;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const now = Store.nowSecs();
        const end = @min(items.len, offset + count);
        var i = offset;
        while (i < end) : (i += 1) {
            st.upsertCanonicalOnly(items[i], true, now, arena.allocator()) catch |e| log.debug("discover canonical upsert failed: {s}", .{@errorName(e)});
            _ = arena.reset(.retain_capacity);
        }
    }

    /// Release every axis's results on teardown. Call once from App's
    /// `deinitOwnedState`, after the worker thread has joined — so nothing a
    /// worker still references is freed out from under it.
    pub fn deinit(self: *DiscoverState, gpa: Allocator) void {
        for (&self.slots) |*slot| {
            for (slot.results.items) |r| freeOwnedAnime(gpa, r);
            slot.results.deinit(gpa);
            slot.results = .empty;
        }
    }
};

test "persistSlot mirrors feed rows into the canonical spine, no provider binding (ROD-336)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var arena_inst = std.heap.ArenaAllocator.init(alloc);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var st = try Store.openMemory();
    defer st.close();

    var ds: DiscoverState = .{};
    defer ds.deinit(alloc);

    // An AniList feed row: id is the STRINGIFIED anilist_id, not a provider id.
    // Persisting it under (provider, "182255") was the ROD-336 landmine.
    try ds.slots[0].results.append(alloc, .{
        .id = try alloc.dupe(u8, "182255"),
        .name = try alloc.dupe(u8, "Sousou no Frieren"),
        .anilist_id = 182255,
        .mal_id = 52991,
    });

    ds.persistSlot(alloc, &st, 0, 0, 1);

    // The row landed in the canonical spine, keyed by anilist_id…
    const rec = (try st.getCanonicalByAnilistId(arena, 182255)).?;
    try testing.expectEqualStrings("Sousou no Frieren", rec.title);
    try testing.expectEqual(@as(?i64, 52991), rec.mal_id);
    // …with NO provider binding minted (that is the resolver's job, ROD-328): the
    // canonical read reports an empty source, and no (source, source_id) row exists.
    try testing.expectEqualStrings("", rec.source);
    try testing.expect((try st.getAnime(arena, "senshi", "182255")) == null);
}
