//! Zigoku — episode cache + detail-grid subsystem (ROD-180).
//!
//! Owns the RECORD of the detail pane's episode list (the fetched episodes, the show they
//! belong to, the grid cursor, the watched high-water) plus the two-tier episode cache (hot
//! LRU mirror + DB, ROD-130). Driven purely through explicit dependencies
//! (`gpa`/`store`/`source`/`translation`/`status`); it never reaches back into App.
//!
//! Boundary (mirroring PlaybackSession): this struct owns the episode record + cache, not
//! the transport. `episode_drain` (the teardown barrier) and `async_start_ms` (the shared
//! slow-path timer) stay on App. The controller resolves source/status/history from nav
//! state and passes them in, and owns the thread spawn and async-timer reset. Embed by
//! value; no `@fieldParentPtr`.

const std = @import("std");
const domain = @import("../domain.zig");
const store_mod = @import("../store.zig");
const workers = @import("workers.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const AnimeRecord = store_mod.AnimeRecord;
const Store = store_mod.Store;

/// The detail pane's episode subsystem (ROD-180). Holds the fetched episode
/// list, the show it belongs to, the grid cursor + watched high-water mark, and
/// the two-tier episode cache (ROD-130). Transport (`episode_drain`,
/// `async_start_ms`) lives on App, not here.
pub const EpisodeState = struct {
    /// Current episode list for the detail pane. GPA-owned (each .raw owned);
    /// null until fetched. Use `freeResults()` to release.
    results: ?[]domain.EpisodeNumber = null,
    /// GPA-duped id of the show whose episodes are in `results` (or in-flight).
    /// null = nothing requested yet.
    for_id: ?[]const u8 = null,
    /// GPA-duped source name paired with `for_id` (ROD-193 review): lets a
    /// (source, source_id) match be exact, so two providers sharing a source_id
    /// can never cross-patch episode state. Set/freed in lockstep with `for_id`;
    /// null whenever `for_id` is null.
    for_source: ?[]const u8 = null,
    /// Whether an episode fetch is in flight.
    loading: bool = false,
    /// ROD-329: true when the open show is the unbound sentinel (no play provider stocks
    /// it), so the grid renders "no source available" with no fetch. Set only by the
    /// History-open gate and cleared at `fireEpisodesForId` entry, so `results != null`
    /// always implies this is false.
    unbound: bool = false,
    /// Cursor position within the episode grid (0-based index into `results`).
    cursor: usize = 0,
    /// Hot in-memory LRU mirror of the DB episode cache (ROD-130): a synchronous
    /// hit here (or in the DB) opens the detail pane instantly on a repeat visit,
    /// bypassing the async fetch. Owns canonical episode copies; the view dups on
    /// hit, so eviction never touches displayed memory.
    lru: workers.EpisodeLruCache = .{},
    /// Watched high-water mark (1-based) for the detail show: episodes with a
    /// 0-based index < this render dimmed as "done" (ROD-131). Seeded from the
    /// store's `progress` on a history-origin load and bumped by `finishPlayback`
    /// after a counted watch. 0 = nothing watched / unknown.
    progress: u32 = 0,
    /// 0-based index of the resume cell (ROD-192): the episode the user will
    /// continue from — the mid-episode checkpoint if one exists, else the next
    /// unwatched. `null` when nothing is in progress (unstarted, or caught up).
    /// Decoupled from `cursor` (which the user moves freely): the grid paints the
    /// `▸` resume glyph here regardless of where the cursor sits. Seeded alongside
    /// `cursor` in `seedHistoryCursor` and advanced by `advanceAfterWatch`.
    resume_idx: ?usize = null,

    /// Free the GPA-owned episode list and the show id, resetting both to null.
    /// Idempotent.
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

    /// Release the LRU cache. Call once on app teardown (the canonical episode
    /// copies the LRU owns are distinct from `results`, which `freeResults`
    /// handles).
    pub fn deinit(self: *EpisodeState, gpa: Allocator) void {
        self.lru.deinit(gpa);
    }

    /// Build the "source\x00source_id\x00translation" episode cache key into
    /// `buf`. Null bytes never appear in any component, so the separator is
    /// collision-safe. Returns null if it doesn't fit (caller skips the cache).
    fn cacheKey(buf: []u8, source: []const u8, source_id: []const u8, tt: domain.Translation) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}\x00{s}\x00{s}", .{ source, source_id, tt.str() }) catch null;
    }

    /// Seed the grid cursor + watched mark from a history record's progress
    /// (ROD-131). Dims already-watched cells on open and parks the cursor on the
    /// in-progress episode (if a resume checkpoint exists) or the next unwatched
    /// one. The controller passes the record + store; this never reads nav state.
    pub fn seedHistoryCursor(
        self: *EpisodeState,
        store: ?*Store,
        translation: domain.Translation,
        rec: AnimeRecord,
        episodes: []domain.EpisodeNumber,
    ) void {
        const progress: usize = if (rec.progress > 0) @intCast(rec.progress) else 0;
        // Dim already-watched cells on open, consistent with the post-playback
        // treatment (ROD-131). Browse-origin detail does not seed progress today
        // — same scope line as the resume-cursor seed below.
        self.progress = std.math.cast(u32, progress) orelse 0;
        self.resume_idx = null;
        if (progress == 0) return;

        const current_idx = progress - 1;
        if (current_idx < episodes.len) {
            if (store) |st| {
                if (st.getResume(rec.source, rec.source_id, translation, episodes[current_idx].raw) catch null) |saved_resume| {
                    if (saved_resume.startSeconds() > 0) {
                        self.cursor = current_idx;
                        self.resume_idx = current_idx;
                        return;
                    }
                }
            }
        }

        if (progress < episodes.len) {
            self.cursor = progress;
            self.resume_idx = progress;
        }
    }

    /// Install a cache-sourced episode list as the live detail state (ROD-130): no thread,
    /// no spinner. `id`/`view` are GPA-owned; ownership transfers to `for_id`/`results`.
    /// Infallible by contract (the caller pre-allocates both), so a hit can never leave
    /// `results` set with a null `for_id`, which would silently block playback. Mirrors the
    /// state the `episodes_done` handler leaves so the two write sites stay consistent;
    /// `history_rec` (resolved by the controller) seeds the history cursor.
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

    /// Synchronous episode cache fast-path (ROD-130): on an LRU hit (fresh) or a
    /// fresh DB hit, populate `results` directly and return true; the caller then
    /// skips the async fetch. A miss returns false. Reads stay on the main thread
    /// (no sqlite-from-worker concern). Caller must have already cleared prior
    /// `results` via `freeResults`. `source`/`status`/`history_rec` are resolved
    /// from navigation state by the controller and passed in — this never reads
    /// App.
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

        // 1) Hot LRU mirror.
        if (self.lru.get(key)) |entry| {
            if (now < entry.expires_at) {
                // for_id first (small): on OOM bail before touching results, so a
                // hit never half-installs.
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
            // Stale: drop it so a repeatedly-visited stale entry can't squat in
            // the MRU slot (get() just promoted it) and evict fresher entries
            // during the refetch window. The refetch re-populates it.
            self.lru.remove(gpa, key);
        }

        // 2) DB cache — getCachedEpisodes returns null for stale/missing rows. An
        // empty list is never stored (cacheEpisodes guards eps.len==0), so a
        // zero-length result here is treated as a miss.
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
        // Promote into the hot LRU (best-effort; on failure the next visit just
        // re-reads the DB). The status drives a fresh TTL, matching putCachedEpisodes.
        if (workers.dupEpisodesOwned(gpa, cached)) |lru_copy| {
            self.lru.putOwned(gpa, key, .{ .episodes = lru_copy, .expires_at = now + Store.cacheTtl(status) }) catch {
                for (lru_copy) |ep| gpa.free(ep.raw);
                gpa.free(lru_copy);
            };
        } else |_| {}

        self.applyCached(store, translation, id, src, view, history_rec);
        return true;
    }

    /// Mirror a freshly-fetched episode list into the DB + hot LRU (ROD-130).
    /// Best-effort: a cache write failure never disrupts navigation/playback.
    /// `source`/`status` are resolved by the controller (see the ROD-170 note in
    /// app.zig about re-derived source names) and passed in.
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
