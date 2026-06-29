//! Zigoku — the `SourceProvider` interface.
//!
//! THE seam. The entire defensive architecture is one idea: the app talks only
//! to this vtable, never to a concrete site. When AllAnime dies, you write a new
//! struct satisfying this interface and change one line of wiring — the app
//! upstream of here never learns the source changed.
//!
//! Implemented as Zig's idiomatic "fat pointer" interface: a type-erased
//! `*anyopaque` self paired with a `*const VTable` of function pointers. A
//! concrete provider exposes a `provider()` that packs itself into one of these.
//! (Contrast with `comptime`/generic interfaces: a vtable lets us hold *any*
//! provider behind one runtime value — necessary the moment we have more than one.)

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

/// How many entries one Popular-feed page fetches (and the Discover grid appends
/// per load-more). The grid's load-more trigger keys off
/// `results.len % popular_page_size == 0`, so this MUST equal the count a full
/// page returns. Distinct from `search_page_size` (ROD-239): the feed paginates
/// the site's ranked popular list, not a relevance search.
pub const popular_page_size: usize = 30;

/// Which popularity window the Popular feed ranks over. Provider-agnostic — a
/// source maps each to whatever its own API speaks (AllAnime → a `dateRange` in
/// days, all-time = 0); the encoding stays quarantined in the provider.
pub const PopularWindow = enum { daily, weekly, monthly, all_time };

pub const PopularOptions = struct {
    window: PopularWindow = .daily,
    /// Page number for pagination (1-indexed).
    page: u32 = 1,
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
        /// Search the catalog; return shows ranked best-match-first.
        search: *const fn (ptr: *anyopaque, arena: Allocator, io: Io, query: []const u8, opts: SearchOptions) anyerror![]domain.Anime,
        /// Fetch one page of the source's popularity-ranked feed for `opts.window`,
        /// in the server's rank order (NOT re-sorted — rank == array position).
        /// A distinct persisted query from `search` (ROD-239).
        popular: *const fn (ptr: *anyopaque, arena: Allocator, io: Io, opts: PopularOptions) anyerror![]domain.Anime,
        /// List a show's episode numbers in the given track, numerically sorted.
        episodes: *const fn (ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation) anyerror![]domain.EpisodeNumber,
        /// Resolve a playable stream for one episode at the requested quality.
        /// `quality` is the user's preference (ROD-152); a source with no variants
        /// is free to ignore it.
        resolve: *const fn (ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, episode: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) anyerror!domain.StreamLink,
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
    pub fn popular(self: SourceProvider, arena: Allocator, io: Io, opts: PopularOptions) anyerror![]domain.Anime {
        return self.vtable.popular(self.ptr, arena, io, opts);
    }
    pub fn episodes(self: SourceProvider, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation) anyerror![]domain.EpisodeNumber {
        return self.vtable.episodes(self.ptr, arena, io, show_id, tt);
    }
    pub fn resolve(self: SourceProvider, arena: Allocator, io: Io, show_id: []const u8, episode: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) anyerror!domain.StreamLink {
        return self.vtable.resolve(self.ptr, arena, io, show_id, episode, tt, quality);
    }
};
