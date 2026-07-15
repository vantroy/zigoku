//! Search + enrich controller (ROD-219).
//!
//! Owns query buffer, results, page, loading. Pure helpers take explicit deps;
//! transport (thread / debounce / async_start_ms) stays on App. Embed by value.

const std = @import("std");
const vaxis = @import("vaxis");
const domain = @import("../domain.zig");
const store_mod = @import("../store.zig");
const workers = @import("workers.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const Anime = domain.Anime;
const Store = store_mod.Store;

const hydrateAnimeFromRecord = workers.hydrateAnimeFromRecord;
const freeOwnedAnime = workers.freeOwnedAnime;

pub const SearchController = struct {
    /// Fixed 127 usable bytes; not null-terminated. Slice via querySlice.
    query: [128]u8 = undefined,
    len: usize = 0,
    loading: bool = false,
    page: u32 = 0,
    /// gpa-owned results; free on query reset.
    results: std.ArrayListUnmanaged(Anime) = .empty,

    pub fn querySlice(self: *const SearchController) []const u8 {
        return self.query[0..self.len];
    }

    /// Verdict for App: mode/debounce/fire are projections of this.
    pub const KeyResult = union(enum) {
        ignored,
        edited,
        cleared: struct { exit: bool },
        submit: struct { fire: bool },
    };

    /// Browse search prompt keys. Mutates query/results only; reports KeyResult.
    pub fn onKey(self: *SearchController, gpa: Allocator, key: vaxis.Key, debounce_pending: bool) KeyResult {
        if (key.matches(vaxis.Key.escape, .{})) {
            self.len = 0;
            self.clearResults(gpa);
            self.loading = false;
            return .{ .cleared = .{ .exit = true } };
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            if (debounce_pending and self.len > 0) {
                self.clearResults(gpa);
                return .{ .submit = .{ .fire = true } };
            }
            return .{ .submit = .{ .fire = false } };
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.len == 0) return .ignored;
            self.len -= 1;
            if (self.len == 0) {
                self.clearResults(gpa);
                self.loading = false;
                return .{ .cleared = .{ .exit = false } };
            }
            return .edited;
        }
        if (key.text) |text| {
            if (text.len > 0 and self.len + text.len <= 127) {
                @memcpy(self.query[self.len..][0..text.len], text);
                self.len += text.len;
                return .edited;
            }
        }
        return .ignored;
    }

    pub fn clearResults(self: *SearchController, gpa: Allocator) void {
        for (self.results.items) |r| freeOwnedAnime(gpa, r);
        self.results.clearRetainingCapacity();
        self.page = 0;
    }

    /// After workers join.
    pub fn deinit(self: *SearchController, gpa: Allocator) void {
        self.clearResults(gpa);
        self.results.deinit(gpa);
        self.results = .empty;
    }

    /// Backfill [offset, count) from canonical spine by anilist_id (ROD-327).
    /// Nulls only: never clobbers fields the fresh hit already carries.
    pub fn hydrateResultsFromStore(
        self: *SearchController,
        gpa: Allocator,
        store: ?*Store,
        offset: usize,
        count: usize,
    ) void {
        const st = store orelse return;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        const end = @min(self.results.items.len, offset + count);
        var i = offset;
        while (i < end) : (i += 1) {
            const aid = self.results.items[i].anilist_id orelse continue;
            const key = std.math.cast(i64, aid) orelse continue;
            const rec = st.getCanonicalByAnilistId(arena.allocator(), key) catch null orelse continue;
            hydrateAnimeFromRecord(gpa, &self.results.items[i], rec);
            _ = arena.reset(.retain_capacity);
        }
    }

    /// Mirror rows into canonical spine only (ROD-327); provider binding is the resolver.
    /// Fully enriched hits → stamp fresh. Best-effort.
    pub fn persistResults(
        self: *SearchController,
        gpa: Allocator,
        store: ?*Store,
        offset: usize,
        count: usize,
    ) void {
        const st = store orelse return;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const now = Store.nowSecs();
        const end = @min(self.results.items.len, offset + count);
        var i = offset;
        while (i < end) : (i += 1) {
            st.upsertCanonicalOnly(self.results.items[i], true, now, arena.allocator()) catch |e| log.debug("upsertCanonicalOnly failed: {s}", .{@errorName(e)});
            _ = arena.reset(.retain_capacity);
        }
    }
};
