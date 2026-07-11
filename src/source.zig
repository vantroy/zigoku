//! Zigoku — the `SourceProvider` interface.
//!
//! THE seam. The entire defensive architecture is one idea: the app talks only to this
//! vtable, never to a concrete site. When a provider dies, you write a new struct satisfying
//! this interface and change one line of wiring; the app upstream never learns the source
//! changed.
//!
//! Implemented as Zig's idiomatic "fat pointer" interface: a type-erased `*anyopaque` self
//! paired with a `*const VTable` of function pointers, and each provider exposes a
//! `provider()` that packs itself into one. (A vtable, not a comptime/generic interface, so
//! one runtime value can hold ANY provider, necessary the moment we have more than one.)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const domain = @import("domain.zig");

/// Canonical search page size — how many results a single page fetches and the UI
/// appends per load-more. The browse footer (`╌ more ╌`) and the load-more trigger
/// both key off `results.len % search_page_size == 0`, so this MUST equal the count
/// a full page actually returns. Workers pass it as `SearchOptions.limit`; the
/// provider's query asks for exactly this many so the server's page stride matches
/// the UI's. Change the page size here and nowhere else (ROD-201).
pub const search_page_size: usize = 26;

pub const SearchOptions = struct {
    translation: domain.Translation = .sub,
    /// Cap on results returned after ranking.
    limit: usize = 20,
    /// Page number for pagination (1-indexed).
    page: u32 = 1,
};

/// A resolved, fetchable cover request (ROD-267). A provider turns a stored cover ref (which
/// may be a provider-relative `mcovers/…` path with no host) into an absolute URL plus
/// whatever headers its cover CDN gates on. `url` is owned by the allocator passed to
/// `coverRequest` (caller frees); `referer`/`user_agent` are static or null and must NOT be
/// freed (a null header means "don't send it"). This is the seam that keeps the cover-CDN
/// host behind the provider: the app fetches an opaque URL and never learns which host served it.
pub const CoverRequest = struct {
    url: []const u8,
    referer: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
};

pub const SourceProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Stable source identity used by persistence keys, e.g. "allanime".
        name: *const fn (ptr: *anyopaque) []const u8,
        /// Human-facing source name for user-visible copy (toasts, CLI, banners),
        /// e.g. "AllAnime". Distinct from `name`: that one is the stable
        /// persistence key DB rows depend on; this one is free to read however it
        /// looks best to a user. THE seam for the site name above the vtable — no
        /// copy upstream of here hardcodes it, since the source is swappable.
        displayName: *const fn (ptr: *anyopaque) []const u8,
        /// Search this provider's OWN catalog; return shows ranked best-match-first.
        /// ROD-328: this is the resolver's per-provider CATALOG primitive: the tier-C
        /// binding path (fuzzy-match a known canonical title against the provider's own
        /// library to recover its opaque id). It is NOT user-facing discovery search:
        /// that moved to AniList, off this vtable (see `anilist.search`), so do not
        /// re-wire the browse/search UI back onto this. Its only caller is the resolver,
        /// used when a provider can't tier-A (`canonicalKey` returned null).
        search: *const fn (ptr: *anyopaque, arena: Allocator, io: Io, query: []const u8, opts: SearchOptions) anyerror![]domain.Anime,
        /// Tier-A binding key (ROD-328): if this provider keys its own catalog by a
        /// canonical id (senshi's show id IS the stringified MAL id), return that
        /// provider-opaque id for `canonical`, else null. PURE key derivation, no
        /// network; the caller confirms the provider actually stocks the id via
        /// `episodes`. A null return means "I do not id-key on a canonical" (the
        /// resolver falls to tier-C `search`), NOT "not stocked". The returned string is
        /// owned by `arena`.
        canonicalKey: *const fn (ptr: *anyopaque, arena: Allocator, canonical: domain.Anime) anyerror!?[]const u8,
        /// List a show's episode numbers in the given track, numerically sorted.
        /// An EMPTY list is authoritative "not stocked" (probe callers cache it,
        /// ROD-347); a provider that can't answer must error instead.
        /// `count_hint` is the canonical's expected episode count
        /// (`domain.expectedEpisodeCount`, ROD-359), for a provider whose catalog
        /// has no listing endpoint (megaplay: per-episode MAL-keyed routes only)
        /// to mint positional labels from; providers with real listings ignore
        /// it, and probe callers that only need existence pass null.
        episodes: *const fn (ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation, count_hint: ?u32) anyerror![]domain.EpisodeNumber,
        /// Resolve a playable stream for one episode at the requested quality.
        /// `quality` is the user's preference (ROD-152); a source with no variants
        /// is free to ignore it.
        resolve: *const fn (ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, episode: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) anyerror!domain.StreamLink,
        /// Resolve a stored cover ref into a fetchable request (absolute URL + any
        /// headers this source's cover CDN requires). Absolute refs pass through
        /// unchanged (e.g. AniList/MAL covers); a provider-relative ref gets the
        /// site's cover CDN prepended. `CoverRequest.url` is owned by `gpa`. Keeps
        /// the cover-CDN host behind the seam — no copy upstream names it (ROD-267).
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

/// The ordered set of live providers (ROD-343). Construction order is the
/// DEFAULT resolve precedence: index 0 (senshi) leads, and that slice is
/// immutable for the process. Worker threads walk it concurrently, so the
/// user's order preference (ROD-344) is a VIEW computed per walk via
/// `ordered`/`preferred`, never an in-place reorder.
///
/// The preference applies only to NEW canonical resolution (which provider
/// gets first shot). A provider-keyed id of unknown owner (legacy `.direct`
/// rows, a missing `for_source`) must keep falling back to `primary()`:
/// the historical owner is index 0, and re-routing those by preference
/// would persist the id under the wrong provider.
///
/// This registry covers the catalog-binding + play axis ONLY. User-facing
/// discovery/search lives on AniList, off the vtable (see `VTable.search`);
/// never add a "search all providers" convenience here.
pub const Registry = struct {
    /// Non-empty, fixed at construction.
    providers: []const SourceProvider,

    /// The default provider for flows with no persisted binding to honor.
    pub fn primary(self: Registry) SourceProvider {
        return self.providers[0];
    }

    /// The provider owning a persisted `source` key (`name()` output). Rows
    /// keyed `(source, source_id)` MUST route through this, never `primary()`:
    /// playing/persisting a row on the wrong provider silently corrupts the
    /// binding. Null = the row's provider isn't registered (retired source).
    pub fn byName(self: Registry, source_name: []const u8) ?SourceProvider {
        for (self.providers) |p| {
            if (std.mem.eql(u8, p.name(), source_name)) return p;
        }
        return null;
    }

    /// The provider a preference names, else `primary()`. The default-provider
    /// accessor for preference-aware flows (ROD-344): an empty or unregistered
    /// name degrades to construction order, same contract as `ordered`.
    pub fn preferred(self: Registry, preferred_name: []const u8) SourceProvider {
        return self.byName(preferred_name) orelse self.primary();
    }

    /// Effective-order iteration (ROD-344): the preferred provider first, then
    /// the rest in construction order. `preferred_name` empty or unregistered
    /// yields plain construction order. The name is read only during `ordered`
    /// itself, so any lifetime works; per-show overrides (ROD-345) are just a
    /// different name resolved by the caller before this point.
    pub fn ordered(self: Registry, preferred_name: []const u8) OrderedIter {
        return .{ .providers = self.providers, .pref = self.indexOf(preferred_name) };
    }

    /// `ordered` materialized into a gpa-owned slice, for handing a worker a
    /// stable snapshot at spawn time (the registry's own slice never mutates,
    /// but the *order* is per-spawn). Caller (in practice the worker) frees.
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
    /// Construction index of the preferred provider; null = no reordering.
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

/// Minimal vtable satisfier for registry tests: only `name` is live.
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
    // Preferring the leader is a no-op, not a duplicate yield.
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
