//! `SourceProvider` interface: the app talks only to this vtable, never a concrete site.
//! Fat pointer (`*anyopaque` + `*const VTable`); each provider's `provider()` packs itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const domain = @import("domain.zig");

/// Results per page / load-more stride. Browse footer and load-more key off
/// `results.len % search_page_size == 0`; must match what a full page returns (ROD-201).
pub const search_page_size: usize = 26;

pub const SearchOptions = struct {
    translation: domain.Translation = .sub,
    /// Cap on results after ranking.
    limit: usize = 20,
    /// 1-indexed page.
    page: u32 = 1,
};

/// Fetchable cover request (ROD-267). Provider turns a stored ref (maybe relative) into
/// absolute URL + optional headers. `url` owned by `coverRequest`'s allocator; headers
/// static/null, not freed. Keeps the cover CDN host behind the seam.
pub const CoverRequest = struct {
    url: []const u8,
    referer: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
};

pub const SourceProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Stable persistence key, e.g. "allanime".
        name: *const fn (ptr: *anyopaque) []const u8,
        /// User-visible name (toasts, CLI). Free to change; `name` is not.
        displayName: *const fn (ptr: *anyopaque) []const u8,
        /// Provider catalog search for tier-C binding (ROD-328). NOT user-facing discovery
        /// (that is AniList). Only the resolver calls this when `canonicalKey` is null.
        search: *const fn (ptr: *anyopaque, arena: Allocator, io: Io, query: []const u8, opts: SearchOptions) anyerror![]domain.Anime,
        /// Tier-A key (ROD-328): pure derivation of provider-opaque id from a canonical
        /// (e.g. stringified mal_id). Null = "I do not id-key on a canonical" (fall to
        /// tier-C), NOT "not stocked". Caller confirms stock via `episodes`. Arena-owned.
        canonicalKey: *const fn (ptr: *anyopaque, arena: Allocator, canonical: domain.Anime) anyerror!?[]const u8,
        /// Episode list for track, sorted. Empty = authoritative not stocked (ROD-347);
        /// cannot-answer must error. `count_hint` for providers without listing endpoints
        /// (megaplay mint); real listings ignore it.
        episodes: *const fn (ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation, count_hint: ?u32) anyerror![]domain.EpisodeNumber,
        /// Playable stream at `quality` (ROD-152; free to ignore if no variants).
        resolve: *const fn (ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, episode: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) anyerror!domain.StreamLink,
        /// Cover ref → fetchable request. Absolute pass-through; relative gets CDN host.
        /// `url` owned by `gpa` (ROD-267).
        coverRequest: *const fn (ptr: *anyopaque, gpa: Allocator, ref: []const u8) anyerror!CoverRequest,
    };

    pub fn name(self: SourceProvider) []const u8 {
        return self.vtable.name(self.ptr);
    }
    pub fn displayName(self: SourceProvider) []const u8 {
        return self.vtable.displayName(self.ptr);
    }
    pub fn search(self: SourceProvider, arena: Allocator, io: Io, query: []const u8, opts: SearchOptions) anyerror![]domain.Anime {
        return self.vtable.search(self.ptr, arena, io, query, opts);
    }
    pub fn canonicalKey(self: SourceProvider, arena: Allocator, canonical: domain.Anime) anyerror!?[]const u8 {
        return self.vtable.canonicalKey(self.ptr, arena, canonical);
    }
    pub fn episodes(self: SourceProvider, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation, count_hint: ?u32) anyerror![]domain.EpisodeNumber {
        return self.vtable.episodes(self.ptr, arena, io, show_id, tt, count_hint);
    }
    pub fn resolve(self: SourceProvider, arena: Allocator, io: Io, show_id: []const u8, episode: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) anyerror!domain.StreamLink {
        return self.vtable.resolve(self.ptr, arena, io, show_id, episode, tt, quality);
    }
    pub fn coverRequest(self: SourceProvider, gpa: Allocator, ref: []const u8) anyerror!CoverRequest {
        return self.vtable.coverRequest(self.ptr, gpa, ref);
    }
};

/// Live providers in construction order = default resolve precedence (ROD-343).
/// Slice is process-immutable; user order (ROD-344) is a per-walk VIEW via
/// `ordered`/`preferred`, never in-place reorder.
///
/// Preference applies only to NEW canonical resolution. Provider-keyed ids of
/// unknown owner (legacy `.direct`, missing `for_source`) keep falling back to
/// `primary()`: re-routing would persist under the wrong provider.
///
/// Catalog-binding + play only. Discovery lives on AniList; no "search all" here.
pub const Registry = struct {
    /// Non-empty, fixed at construction.
    providers: []const SourceProvider,

    /// Default for flows with no persisted binding.
    pub fn primary(self: Registry) SourceProvider {
        return self.providers[0];
    }

    /// Owner of a persisted `source` key. Rows keyed `(source, source_id)` MUST use this,
    /// never `primary()` (wrong provider silently corrupts the binding). Null = retired.
    pub fn byName(self: Registry, source_name: []const u8) ?SourceProvider {
        for (self.providers) |p| {
            if (std.mem.eql(u8, p.name(), source_name)) return p;
        }
        return null;
    }

    /// Named preference or `primary()` (ROD-344). Empty/unregistered → construction order.
    pub fn preferred(self: Registry, preferred_name: []const u8) SourceProvider {
        return self.byName(preferred_name) orelse self.primary();
    }

    /// Preferred first, then construction order (ROD-344). Empty/unknown → plain order.
    pub fn ordered(self: Registry, preferred_name: []const u8) OrderedIter {
        return .{ .providers = self.providers, .pref = self.indexOf(preferred_name) };
    }

    /// Materialized order snapshot for a worker spawn. Caller frees.
    pub fn orderedAlloc(self: Registry, gpa: Allocator, preferred_name: []const u8) ![]SourceProvider {
        const out = try gpa.alloc(SourceProvider, self.providers.len);
        var it = self.ordered(preferred_name);
        var i: usize = 0;
        while (it.next()) |p| : (i += 1) out[i] = p;
        return out;
    }

    fn indexOf(self: Registry, source_name: []const u8) ?usize {
        for (self.providers, 0..) |p, i| {
            if (std.mem.eql(u8, p.name(), source_name)) return i;
        }
        return null;
    }
};

pub const OrderedIter = struct {
    providers: []const SourceProvider,
    pref: ?usize,
    i: usize = 0,
    yielded_pref: bool = false,

    pub fn next(it: *OrderedIter) ?SourceProvider {
        if (it.pref) |p| {
            if (!it.yielded_pref) {
                it.yielded_pref = true;
                return it.providers[p];
            }
        }
        while (it.i < it.providers.len) {
            const idx = it.i;
            it.i += 1;
            if (it.pref) |p| {
                if (idx == p) continue;
            }
            return it.providers[idx];
        }
        return null;
    }
};

/// Minimal vtable for registry tests: only `name` is live.
const TestProvider = struct {
    id: []const u8,

    const vtable: SourceProvider.VTable = .{
        .name = nameFn,
        .displayName = displayNameFn,
        .search = searchFn,
        .canonicalKey = canonicalKeyFn,
        .episodes = episodesFn,
        .resolve = resolveFn,
        .coverRequest = coverRequestFn,
    };

    fn provider(self: *TestProvider) SourceProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn nameFn(ptr: *anyopaque) []const u8 {
        const self: *TestProvider = @ptrCast(@alignCast(ptr));
        return self.id;
    }
    fn displayNameFn(_: *anyopaque) []const u8 {
        return "Test";
    }
    fn searchFn(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: SearchOptions) anyerror![]domain.Anime {
        return error.Unsupported;
    }
    fn canonicalKeyFn(_: *anyopaque, _: Allocator, _: domain.Anime) anyerror!?[]const u8 {
        return null;
    }
    fn episodesFn(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: domain.Translation, _: ?u32) anyerror![]domain.EpisodeNumber {
        return error.Unsupported;
    }
    fn resolveFn(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: domain.EpisodeNumber, _: domain.Translation, _: domain.Quality) anyerror!domain.StreamLink {
        return error.Unsupported;
    }
    fn coverRequestFn(_: *anyopaque, _: Allocator, _: []const u8) anyerror!CoverRequest {
        return error.Unsupported;
    }
};

test "Registry.primary returns the first provider" {
    var a = TestProvider{ .id = "senshi" };
    var b = TestProvider{ .id = "anipub" };
    const reg = Registry{ .providers = &.{ a.provider(), b.provider() } };
    try std.testing.expectEqualStrings("senshi", reg.primary().name());
}

test "Registry.byName finds each registered provider" {
    var a = TestProvider{ .id = "senshi" };
    var b = TestProvider{ .id = "anipub" };
    const reg = Registry{ .providers = &.{ a.provider(), b.provider() } };
    try std.testing.expectEqualStrings("senshi", reg.byName("senshi").?.name());
    try std.testing.expectEqualStrings("anipub", reg.byName("anipub").?.name());
}

test "Registry.byName returns null for an unregistered source" {
    var a = TestProvider{ .id = "senshi" };
    const reg = Registry{ .providers = &.{a.provider()} };
    try std.testing.expect(reg.byName("allanime") == null);
}

fn expectOrder(reg: Registry, preferred_name: []const u8, want: []const []const u8) !void {
    var it = reg.ordered(preferred_name);
    for (want) |name| {
        const p = it.next() orelse return error.TestExpectedMore;
        try std.testing.expectEqualStrings(name, p.name());
    }
    try std.testing.expect(it.next() == null);
}

test "Registry.ordered promotes the preferred provider, keeps the rest in construction order (ROD-344)" {
    var a = TestProvider{ .id = "senshi" };
    var b = TestProvider{ .id = "anipub" };
    var c = TestProvider{ .id = "third" };
    const reg = Registry{ .providers = &.{ a.provider(), b.provider(), c.provider() } };
    try expectOrder(reg, "anipub", &.{ "anipub", "senshi", "third" });
    try expectOrder(reg, "third", &.{ "third", "senshi", "anipub" });
    try expectOrder(reg, "senshi", &.{ "senshi", "anipub", "third" });
}

test "Registry.ordered with an empty or unknown preference is construction order (ROD-344)" {
    var a = TestProvider{ .id = "senshi" };
    var b = TestProvider{ .id = "anipub" };
    const reg = Registry{ .providers = &.{ a.provider(), b.provider() } };
    try expectOrder(reg, "", &.{ "senshi", "anipub" });
    try expectOrder(reg, "allanime", &.{ "senshi", "anipub" });
}

test "Registry.preferred picks the named provider, degrades to primary (ROD-344)" {
    var a = TestProvider{ .id = "senshi" };
    var b = TestProvider{ .id = "anipub" };
    const reg = Registry{ .providers = &.{ a.provider(), b.provider() } };
    try std.testing.expectEqualStrings("anipub", reg.preferred("anipub").name());
    try std.testing.expectEqualStrings("senshi", reg.preferred("").name());
    try std.testing.expectEqualStrings("senshi", reg.preferred("allanime").name());
}

test "Registry.orderedAlloc materializes the effective order into an owned slice (ROD-344)" {
    var a = TestProvider{ .id = "senshi" };
    var b = TestProvider{ .id = "anipub" };
    const reg = Registry{ .providers = &.{ a.provider(), b.provider() } };
    const snap = try reg.orderedAlloc(std.testing.allocator, "anipub");
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqual(@as(usize, 2), snap.len);
    try std.testing.expectEqualStrings("anipub", snap[0].name());
    try std.testing.expectEqualStrings("senshi", snap[1].name());
}
