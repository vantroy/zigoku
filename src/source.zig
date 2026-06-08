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

pub const SearchOptions = struct {
    translation: domain.Translation = .sub,
    /// Cap on results returned after ranking.
    limit: usize = 20,
    /// Page number for pagination (1-indexed).
    page: u32 = 1,
};

pub const SourceProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Search the catalog; return shows ranked best-match-first.
        search: *const fn (ptr: *anyopaque, arena: Allocator, io: Io, query: []const u8, opts: SearchOptions) anyerror![]domain.Anime,
        /// List a show's episode numbers in the given track, numerically sorted.
        episodes: *const fn (ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation) anyerror![]domain.EpisodeNumber,
        /// Resolve a playable stream for one episode.
        resolve: *const fn (ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, episode: domain.EpisodeNumber, tt: domain.Translation) anyerror!domain.StreamLink,
    };

    pub fn search(self: SourceProvider, arena: Allocator, io: Io, query: []const u8, opts: SearchOptions) anyerror![]domain.Anime {
        return self.vtable.search(self.ptr, arena, io, query, opts);
    }
    pub fn episodes(self: SourceProvider, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation) anyerror![]domain.EpisodeNumber {
        return self.vtable.episodes(self.ptr, arena, io, show_id, tt);
    }
    pub fn resolve(self: SourceProvider, arena: Allocator, io: Io, show_id: []const u8, episode: domain.EpisodeNumber, tt: domain.Translation) anyerror!domain.StreamLink {
        return self.vtable.resolve(self.ptr, arena, io, show_id, episode, tt);
    }
};
