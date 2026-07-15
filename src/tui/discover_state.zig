//! Discover feed controller (ROD-239; AniList-backed since ROD-336).
//!
//! Owns axis, cursor/scroll, per-axis result cache. Transport stays on App. Embed by value.

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

/// One cached feed axis: pages, TTL stamp, in-flight / failed / exhausted.
pub const Slot = struct {
    results: std.ArrayListUnmanaged(Anime) = .empty,
    page: u32 = 0,
    /// Last successful fetch (Store.nowSecs); 0 = never. TTL from here on axis-switch.
    fetched_at: i64 = 0,
    loading: bool = false,
    /// Last fetch failed (ROD-239). View shows "can't reach" only while empty; cleared on success.
    failed: bool = false,
    /// AniList hasNextPage false (ROD-336, §9.6). Stops load-more; footer "all loaded".
    exhausted: bool = false,
};

/// CORRECTNESS: one independent owned list per axis. Never a shared list re-sorted:
/// ranks differ per axis; card `#N` is positional. Same show on four axes = four copies.
pub const DiscoverState = struct {
    /// Cap rows per axis (ROD-339). Load-more has no natural bound; crossing flips exhausted.
    pub const max_feed_rows: usize = 300;

    axis: anilist.DiscoverAxis = .trending,
    cursor: usize = 0,
    scroll: usize = 0,
    /// Indexed by `@intFromEnum(axis)`.
    slots: [4]Slot = .{ .{}, .{}, .{}, .{} },

    pub fn activeSlot(self: *const DiscoverState) *const Slot {
        return &self.slots[@intFromEnum(self.axis)];
    }

    pub fn clearSlot(self: *DiscoverState, gpa: Allocator, idx: usize) void {
        const slot = &self.slots[idx];
        for (slot.results.items) |r| freeOwnedAnime(gpa, r);
        slot.results.clearRetainingCapacity();
        slot.page = 0;
        slot.fetched_at = 0;
        slot.exhausted = false;
    }

    /// Mirror rows into the canonical spine (ROD-336), never as provider bindings
    /// (resolver, ROD-328). Fully enriched → stamp fresh. Best-effort.
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

    /// After worker join: free every axis.
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

    // Feed id is stringified anilist_id, not a provider id (ROD-336 landmine).
    try ds.slots[0].results.append(alloc, .{
        .id = try alloc.dupe(u8, "182255"),
        .name = try alloc.dupe(u8, "Sousou no Frieren"),
        .anilist_id = 182255,
        .mal_id = 52991,
    });

    ds.persistSlot(alloc, &st, 0, 0, 1);

    const rec = (try st.getCanonicalByAnilistId(arena, 182255)).?;
    try testing.expectEqualStrings("Sousou no Frieren", rec.title);
    try testing.expectEqual(@as(?i64, 52991), rec.mal_id);
    try testing.expectEqualStrings("", rec.source);
    try testing.expect((try st.getAnime(arena, "senshi", "182255")) == null);
}
