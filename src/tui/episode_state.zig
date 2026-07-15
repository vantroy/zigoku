//! Episode cache + detail-grid subsystem (ROD-180).
//!
//! Owns the detail pane's episode list, show id/source, grid cursor, watched high-water,
//! and two-tier cache (hot LRU + DB, ROD-130). Explicit deps only; never reaches into App.
//! Transport (`episode_drain`, `async_start_ms`) stays on App. Embed by value.

const std = @import("std");
const domain = @import("../domain.zig");
const store_mod = @import("../store.zig");
const workers = @import("workers.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const AnimeRecord = store_mod.AnimeRecord;
const Store = store_mod.Store;

pub const EpisodeState = struct {
    /// GPA-owned episode list (each .raw owned); null until fetched.
    results: ?[]domain.EpisodeNumber = null,
    /// GPA-duped id of the show in `results` (or in-flight).
    for_id: ?[]const u8 = null,
    /// GPA-duped source paired with `for_id` (ROD-193): exact (source, source_id) match
    /// so two providers sharing a source_id cannot cross-patch. Lockstep with for_id.
    for_source: ?[]const u8 = null,
    loading: bool = false,
    /// Unbound sentinel (ROD-329): no play provider stocks the show. Set by History-open
    /// gate; cleared at fireEpisodesForId. `results != null` implies false.
    unbound: bool = false,
    cursor: usize = 0,
    /// Hot LRU of DB episode cache (ROD-130). Owns canonical copies; view dups on hit.
    lru: workers.EpisodeLruCache = .{},
    /// Watched high-water (1-based); index < this is dimmed (ROD-131). 0 = nothing/unknown.
    progress: u32 = 0,
    /// Resume cell (ROD-192): checkpoint or next unwatched. Null when nothing in progress.
    /// Decoupled from cursor. Seeded in seedHistoryCursor; advanced by advanceAfterWatch.
    resume_idx: ?usize = null,

    /// Free results + for_id + for_source. Idempotent.
    pub fn freeResults(self: *EpisodeState, gpa: Allocator) void {
        if (self.results) |eps| {
            for (eps) |ep| gpa.free(ep.raw);
            gpa.free(eps);
            self.results = null;
        }
        if (self.for_id) |id| {
            gpa.free(id);
            self.for_id = null;
        }
        if (self.for_source) |src| {
            gpa.free(src);
            self.for_source = null;
        }
    }

    /// Release LRU (distinct from results). Call once on app teardown.
    pub fn deinit(self: *EpisodeState, gpa: Allocator) void {
        self.lru.deinit(gpa);
    }

    /// Cache key: source\0source_id\0translation. Null if it doesn't fit.
    fn cacheKey(buf: []u8, source: []const u8, source_id: []const u8, tt: domain.Translation) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}\x00{s}\x00{s}", .{ source, source_id, tt.str() }) catch null;
    }

    /// Seed cursor + progress from a history record (ROD-131).
    pub fn seedHistoryCursor(
        self: *EpisodeState,
        store: ?*Store,
        translation: domain.Translation,
        rec: AnimeRecord,
        episodes: []domain.EpisodeNumber,
    ) void {
        const progress: usize = if (rec.progress > 0) @intCast(rec.progress) else 0;
        self.progress = std.math.cast(u32, progress) orelse 0;
        self.cursor = 0;
        self.resume_idx = null;
        if (resumeSeed(store, translation, rec.source, rec.source_id, progress, episodes)) |idx| {
            self.cursor = idx;
            self.resume_idx = idx;
        }
    }

    /// Resume index for a progress high-water: mid-episode checkpoint if present, else
    /// next unwatched; null if unstarted or caught up. ROD-355: every progress writer
    /// must re-seed through this; `cursor = progress` skips the checkpoint branch.
    /// getResume unions sibling bindings, so the checkpoint is visible from any provider.
    pub fn resumeSeed(
        store: ?*Store,
        translation: domain.Translation,
        source: []const u8,
        source_id: []const u8,
        progress: usize,
        episodes: []const domain.EpisodeNumber,
    ) ?usize {
        if (progress == 0) return null;

        const current_idx = progress - 1;
        if (current_idx < episodes.len) {
            if (store) |st| {
                if (st.getResume(source, source_id, translation, episodes[current_idx].raw) catch null) |saved_resume| {
                    if (saved_resume.startSeconds() > 0) return current_idx;
                }
            }
        }

        if (progress < episodes.len) return progress;
        return null;
    }

    /// Install cache-sourced list as live detail state (ROD-130). Takes ownership of
    /// id/source/view; infallible, so results/for_id always land together.
    fn applyCached(
        self: *EpisodeState,
        store: ?*Store,
        translation: domain.Translation,
        id: []const u8,
        source_owned: []const u8,
        view: []domain.EpisodeNumber,
        history_rec: ?AnimeRecord,
    ) void {
        self.results = view;
        self.for_id = id;
        self.for_source = source_owned;
        self.cursor = 0;
        self.progress = 0;
        self.resume_idx = null;
        self.loading = false;
        if (history_rec) |rec| self.seedHistoryCursor(store, translation, rec, view);
    }

    /// Synchronous cache fast-path (ROD-130). True = skip async fetch. Caller must
    /// freeResults first. Never reads App.
    pub fn tryCacheHit(
        self: *EpisodeState,
        gpa: Allocator,
        store: ?*Store,
        source: []const u8,
        source_id: []const u8,
        translation: domain.Translation,
        status: ?[]const u8,
        history_rec: ?AnimeRecord,
    ) bool {
        var key_buf: [256]u8 = undefined;
        const key = cacheKey(&key_buf, source, source_id, translation) orelse return false;
        const now = Store.nowSecs();

        if (self.lru.get(key)) |entry| {
            if (now < entry.expires_at) {
                // Dupe order matters: each catch below frees only what's already duped.
                const id = gpa.dupe(u8, source_id) catch return false;
                const src = gpa.dupe(u8, source) catch {
                    gpa.free(id);
                    return false;
                };
                const view = workers.dupEpisodesOwned(gpa, entry.episodes) catch {
                    gpa.free(id);
                    gpa.free(src);
                    return false;
                };
                self.applyCached(store, translation, id, src, view, history_rec);
                return true;
            }
            // Stale: drop so it can't squat MRU after get() promotion.
            self.lru.remove(gpa, key);
        }

        // Empty lists never stored; zero-length is a miss.
        const st = store orelse return false;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const cached = (st.getCachedEpisodes(arena.allocator(), source, source_id, translation, now) catch null) orelse return false;
        if (cached.len == 0) return false;

        const id = gpa.dupe(u8, source_id) catch return false;
        const src = gpa.dupe(u8, source) catch {
            gpa.free(id);
            return false;
        };
        const view = workers.dupEpisodesOwned(gpa, cached) catch {
            gpa.free(id);
            gpa.free(src);
            return false;
        };
        if (workers.dupEpisodesOwned(gpa, cached)) |lru_copy| {
            self.lru.putOwned(gpa, key, .{ .episodes = lru_copy, .expires_at = now + Store.cacheTtl(status) }) catch {
                for (lru_copy) |ep| gpa.free(ep.raw);
                gpa.free(lru_copy);
            };
        } else |_| {}

        self.applyCached(store, translation, id, src, view, history_rec);
        return true;
    }

    /// Mirror fetch into DB + LRU. Best-effort; never disrupts navigation.
    pub fn cacheEpisodes(
        self: *EpisodeState,
        gpa: Allocator,
        store: ?*Store,
        source: []const u8,
        source_id: []const u8,
        translation: domain.Translation,
        status: ?[]const u8,
        eps: []const domain.EpisodeNumber,
    ) void {
        if (eps.len == 0) return;
        const now = Store.nowSecs();

        if (store) |st| {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            st.putCachedEpisodes(source, source_id, translation, eps, status, now, arena.allocator()) catch |e|
                log.debug("putCachedEpisodes failed: {s}", .{@errorName(e)});
        }

        var key_buf: [256]u8 = undefined;
        const key = cacheKey(&key_buf, source, source_id, translation) orelse return;
        const lru_copy = workers.dupEpisodesOwned(gpa, eps) catch return;
        self.lru.putOwned(gpa, key, .{ .episodes = lru_copy, .expires_at = now + Store.cacheTtl(status) }) catch {
            for (lru_copy) |ep| gpa.free(ep.raw);
            gpa.free(lru_copy);
        };
    }
};
