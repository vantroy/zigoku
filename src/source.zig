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
        episodes: *const fn (ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation) anyerror![]domain.EpisodeNumber,
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
    pub fn episodes(self: SourceProvider, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation) anyerror![]domain.EpisodeNumber {
        return self.vtable.episodes(self.ptr, arena, io, show_id, tt);
    }
    pub fn resolve(self: SourceProvider, arena: Allocator, io: Io, show_id: []const u8, episode: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) anyerror!domain.StreamLink {
        return self.vtable.resolve(self.ptr, arena, io, show_id, episode, tt, quality);
    }
    pub fn coverRequest(self: SourceProvider, gpa: Allocator, ref: []const u8) anyerror!CoverRequest {
        return self.vtable.coverRequest(self.ptr, gpa, ref);
    }
};

/// The ordered set of live providers (ROD-343). Order IS resolve precedence:
/// index 0 is the default, and binding walks the slice first-hit-wins.
/// Construction keeps senshi at index 0: that ordering is the guarantee that
/// single-provider behavior stays byte-identical; don't reorder it outside the
/// (future, ROD-340 slice D/F) user-facing override path.
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
    fn episodesFn(_: *anyopaque, _: Allocator, _: Io, _: []const u8, _: domain.Translation) anyerror![]domain.EpisodeNumber {
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
