//! Zigoku — TUI background workers and shared ownership helpers.

const std = @import("std");
const source_mod = @import("../source.zig");
const domain = @import("../domain.zig");
const store_mod = @import("../store.zig");
const anilist = @import("../anilist.zig");
const cover_mod = @import("../cover.zig");
const player_mod = @import("../player.zig");
const aniskip = @import("../aniskip.zig");
const paths = @import("../paths.zig");
const lru_mod = @import("../util/lru.zig");
const deadline = @import("../util/deadline.zig");
const event_mod = @import("event.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const SourceProvider = source_mod.SourceProvider;
const Anime = domain.Anime;
const Loop = event_mod.Loop;

/// Fire-and-forget worker accounting (ROD-179). Lets the main loop spawn a
/// background worker without synchronously joining a prior one: the superseded
/// worker is *detached* and runs to completion on its own (its stale result is
/// keep-checked and dropped on arrival), while a teardown barrier still
/// guarantees every outstanding worker has finished before the shared state it
/// borrows — the event loop, the gpa, the io — is torn down.
///
/// Contract:
///   - `begin()` on the spawning thread, immediately *before* each spawn, so the
///     count is already raised when the new thread may start. On a spawn
///     failure, pair it with `finish()` to rebalance.
///   - the worker calls `finish()` as its last action (via `defer`), after its
///     final `postEvent` returns — so once `drain()` unblocks, no worker can
///     still touch the loop/gpa/io.
///   - `drain()` once, on teardown: blocks until every begun worker finished.
///
/// Just an atomic counter: this std's `Thread` is `spawn/join/detach/yield`
/// only — the blocking sync primitives (Mutex/Condition/Futex) moved to
/// `std.Io`, and these are raw OS threads, not io tasks. `begin`/`finish` are
/// lock-free fetch-add/sub. `drain()` spins, but `yield()` hands the core to a
/// worker so it can finish, it runs once on teardown only (never the hot path),
/// and it's bounded by the in-flight fetch's wall-clock deadline (ROD-153).
///
/// Intentionally does NOT cap the worker count: the episode-prefetch debounce
/// (ROD-156) keeps superseding fires rare and each fetch is deadline-bounded
/// (ROD-153), so the outstanding set stays small in practice. A hard cap would
/// be backpressure policy, not a safety requirement — so where a caller *does*
/// want one (the Discover fan-out, which can storm), it reads `inflight` against
/// its own soft cap at the spawn site and drops past it (`discoverPoolSaturated`,
/// ROD-264 #3), rather than this shared primitive imposing a single global limit.
///
/// `drain()` assumes the event queue keeps draining: a worker's final
/// `postEvent` blocks if the bounded queue is full, and during teardown the main
/// loop has stopped popping — so a saturated queue could wedge the drain. This is
/// a pre-existing, low-probability teardown hazard shared by every worker join in
/// run(); hardening it (pump the queue while draining) is a separate follow-up.
pub const ThreadDrain = struct {
    inflight: std.atomic.Value(usize) = .init(0),

    /// Account for a worker about to be spawned. Call on the spawning thread,
    /// before the spawn, so `drain()` can never observe a gap.
    pub fn begin(self: *ThreadDrain) void {
        _ = self.inflight.fetchAdd(1, .acq_rel);
    }

    /// Account for a finished worker. Call as the worker's last action (defer).
    /// The release here publishes the worker's prior effects (its final
    /// `postEvent`) to whoever observes the count hit zero in `drain()`.
    pub fn finish(self: *ThreadDrain) void {
        const prev = self.inflight.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
    }

    /// Block until every begun worker has finished. Teardown only.
    pub fn drain(self: *ThreadDrain) void {
        while (self.inflight.load(.acquire) != 0) std.Thread.yield() catch {};
    }
};

const DecodedCoverCacheOps = struct {
    pub fn freeValue(alloc: Allocator, value: cover_mod.Pixels) void {
        alloc.free(value.rgba);
    }

    pub fn valueBytes(value: cover_mod.Pixels) usize {
        return value.rgba.len;
    }
};
pub const RawCoverCache = lru_mod.LruCache([]const u8, []u8, 20, lru_mod.SliceValueOps([]u8));
pub const DecodedCoverCache = lru_mod.LruCache([]const u8, cover_mod.Pixels, 5, DecodedCoverCacheOps);
pub const max_cover_raw_cache_bytes = 32 * 1024 * 1024;
pub const max_cover_decoded_cache_bytes = 48 * 1024 * 1024;

/// Shared, mutex-guarded cover caches (ROD-243). Hoisted out of `CoverState` so the
/// single-cover path and the Discover grid both fetch against the *same* URL-keyed
/// LRUs — a cover fetched in Browse is reused by Discover (and vice-versa) for free.
///
/// The mutex is what makes these previously one-at-a-time caches safe under N
/// concurrent cover workers. Before ROD-243 the only safety came from
/// `cover_state.zig` joining the prior thread before spawning the next, so exactly
/// one worker ever touched the caches; the grid breaks that invariant.
///
/// Lock discipline (implemented in `loadCoverPixels`): every dupe of a slice that
/// lives in — or was just inserted into — a cache happens while `mu` is held;
/// `decodeCoverBody` and the network fetch run *unlocked* so a slow decode/fetch
/// never stalls another worker. Note `LruCache.get` is itself a writer (it promotes
/// the hit to most-recent), so even a pure lookup must hold the lock.
pub const CoverCaches = struct {
    mu: std.Io.Mutex = .init,
    raw: RawCoverCache = .{},
    decoded: DecodedCoverCache = .{},

    /// Teardown only — call after every cover worker has joined, so nothing a
    /// worker still references is freed out from under it.
    pub fn deinit(self: *CoverCaches, gpa: Allocator) void {
        self.decoded.deinit(gpa);
        self.decoded = .{};
        self.raw.deinit(gpa);
        self.raw = .{};
    }
};

/// One slot of the episode hot-cache: a canonical GPA-owned episode list plus
/// the Unix-seconds expiry mirroring the DB episode_cache TTL, so the in-memory
/// mirror never serves data the DB itself would refuse as stale (ROD-130).
pub const EpisodeLruEntry = struct {
    episodes: []domain.EpisodeNumber,
    expires_at: i64,
};
const EpisodeListOps = struct {
    pub fn freeValue(alloc: Allocator, value: EpisodeLruEntry) void {
        for (value.episodes) |ep| alloc.free(ep.raw);
        alloc.free(value.episodes);
    }
    pub fn valueBytes(value: EpisodeLruEntry) usize {
        var total = value.episodes.len * @sizeOf(domain.EpisodeNumber);
        for (value.episodes) |ep| total += ep.raw.len; // each .raw is its own alloc
        return total;
    }
};
pub const episode_lru_cap = 8;
/// Hot in-memory mirror of the DB episode cache (ROD-130), keyed by
/// "source\x00source_id\x00translation". A synchronous hit bypasses the async
/// fetch so the detail pane opens instantly on repeat visits. Entries hold
/// canonical episode copies (each .raw individually owned); a hit dups into the
/// view, so LRU eviction can never invalidate displayed memory.
pub const EpisodeLruCache = lru_mod.LruCache([]const u8, EpisodeLruEntry, episode_lru_cap, EpisodeListOps);

/// Duplicate an episode list into a fresh canonical GPA allocation: a new outer
/// slice plus an individually-owned copy of every `.raw`. Mirrors the exact
/// ownership shape `episodesTask` produces, so the result is freeable by
/// `EpisodeState.freeResults` / `EpisodeListOps`. On OOM the partial allocation is
/// unwound and the error propagates (callers fall back to a network fetch).
pub fn dupEpisodesOwned(alloc: Allocator, eps: []const domain.EpisodeNumber) ![]domain.EpisodeNumber {
    const out = try alloc.alloc(domain.EpisodeNumber, eps.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |ep| alloc.free(ep.raw);
        alloc.free(out);
    }
    for (eps, 0..) |ep, i| {
        out[i] = .{ .raw = try alloc.dupe(u8, ep.raw) };
        filled = i + 1;
    }
    return out;
}

pub fn dupeOptText(alloc: Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |x| try alloc.dupe(u8, x) else null;
}

/// Deep-copy a slice of strings (genres, studios) into a fresh owned slice plus
/// an individually-owned copy of every element — the shape `freeOwnedAnime`
/// frees. On OOM the partial allocation is unwound and the error propagates.
/// Returns `&.{}` for an empty input (no allocation, nothing to free).
pub fn dupeOwnedStrList(alloc: Allocator, items: []const []const u8) ![]const []const u8 {
    if (items.len == 0) return &.{};
    const out = try alloc.alloc([]const u8, items.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| alloc.free(s);
        alloc.free(out);
    }
    for (items, 0..) |s, i| {
        out[i] = try alloc.dupe(u8, s);
        filled = i + 1;
    }
    return out;
}

pub fn dupeOwnedAnime(alloc: Allocator, a: Anime) !Anime {
    var out: Anime = .{
        .id = try alloc.dupe(u8, a.id),
        .name = &.{},
        .mal_id = a.mal_id,
        .anilist_id = a.anilist_id,
        .eps_sub = a.eps_sub,
        .eps_dub = a.eps_dub,
        .total_episodes = a.total_episodes,
        .duration = a.duration,
        .year = a.year,
        .season = a.season,
        .start_date = a.start_date,
        .score = a.score,
        .view_count = a.view_count, // scalar, no heap — must survive the dupe (ROD-239)
    };
    errdefer freeOwnedAnime(alloc, out);

    out.name = try alloc.dupe(u8, a.name);
    out.english_name = try dupeOptText(alloc, a.english_name);
    out.native_name = try dupeOptText(alloc, a.native_name);
    out.thumb = try dupeOptText(alloc, a.thumb);
    out.banner = try dupeOptText(alloc, a.banner);
    out.status = try dupeOptText(alloc, a.status);
    out.description = try dupeOptText(alloc, a.description);
    out.kind = try dupeOptText(alloc, a.kind);
    out.genres = try dupeOwnedStrList(alloc, a.genres);
    out.studios = try dupeOwnedStrList(alloc, a.studios);
    return out;
}

pub fn freeOwnedAnime(alloc: Allocator, a: Anime) void {
    alloc.free(a.id);
    if (a.name.len > 0) alloc.free(a.name);
    if (a.english_name) |x| alloc.free(x);
    if (a.native_name) |x| alloc.free(x);
    if (a.thumb) |x| alloc.free(x);
    if (a.banner) |x| alloc.free(x);
    if (a.status) |x| alloc.free(x);
    if (a.description) |x| alloc.free(x);
    if (a.kind) |x| alloc.free(x);
    if (a.genres.len > 0) {
        for (a.genres) |g| alloc.free(g);
        alloc.free(a.genres);
    }
    if (a.studios.len > 0) {
        for (a.studios) |s| alloc.free(s);
        alloc.free(a.studios);
    }
}

/// Merge an enriched copy into the live card, filling ONLY the fields the live card
/// still lacks (live wins) — the concurrency-safe replacement for `live.* = incoming`
/// (ROD-247). The Discover slot now has two concurrent enrichers (the page batch and
/// the per-card zoom); a full overwrite from either's fire-time snapshot would clobber
/// fields the other already filled (zoom lands → batch's score reverts to `[--]`, or
/// batch lands → zoom's synopsis blanks). Fill-if-null mirrors `applyMetadata`'s
/// "existing wins" rule, so arrival order no longer matters and no enrichment is lost.
/// Ownership: adopted fields transfer out of `incoming` (nulled so they aren't freed);
/// everything `incoming` still holds — including its id/name (live keeps its own) — is
/// freed here. `live`'s id/name/view_count/eps always win (never touched).
pub fn mergeEnrichedFillNull(gpa: Allocator, live: *Anime, incoming: *Anime) void {
    mergeOptText(&live.english_name, &incoming.english_name);
    mergeOptText(&live.native_name, &incoming.native_name);
    mergeCoverPreferAbsolute(gpa, &live.thumb, &incoming.thumb);
    mergeOptText(&live.banner, &incoming.banner);
    mergeOptText(&live.status, &incoming.status);
    mergeOptText(&live.description, &incoming.description);
    mergeOptText(&live.kind, &incoming.kind);
    mergeStrList(&live.genres, &incoming.genres);
    mergeStrList(&live.studios, &incoming.studios);
    if (live.mal_id == null) live.mal_id = incoming.mal_id;
    if (live.anilist_id == null) live.anilist_id = incoming.anilist_id;
    if (live.total_episodes == null) live.total_episodes = incoming.total_episodes;
    if (live.year == null) live.year = incoming.year;
    if (live.season == null) live.season = incoming.season;
    if (live.start_date == null) live.start_date = incoming.start_date;
    if (live.score == null) live.score = incoming.score;
    freeOwnedAnime(gpa, incoming.*); // frees id/name + every field not transferred above
}

/// Adopt `incoming`'s string only if `live` lacks one, transferring ownership (the
/// source is nulled so the subsequent freeOwnedAnime won't double-free it).
fn mergeOptText(live: *?[]const u8, incoming: *?[]const u8) void {
    if (live.* == null) {
        live.* = incoming.*;
        incoming.* = null;
    }
}

/// Whether to replace a card's current cover `cur` with an enriched `inc`: adopt
/// when there's no cover yet, or when `cur` is only a relative ref and `inc` is a
/// fetchable absolute url (ROD-267). Never downgrades an absolute url to a relative
/// one, and never swaps one absolute for another (no churn for equal quality).
fn preferCover(cur: ?[]const u8, inc: ?[]const u8) bool {
    const incoming = inc orelse return false;
    const current = cur orelse return true;
    return !domain.isAbsoluteUrl(current) and domain.isAbsoluteUrl(incoming);
}

/// Cover-thumb variant of `mergeOptText` that prefers an absolute url over a
/// relative ref (ROD-267): when `preferCover` says so, adopt `incoming` (transfer
/// ownership, null the source) and free `live`'s old relative thumb. Otherwise
/// `live` keeps its thumb and the caller's `freeOwnedAnime` reclaims `incoming`'s.
fn mergeCoverPreferAbsolute(gpa: Allocator, live: *?[]const u8, incoming: *?[]const u8) void {
    if (!preferCover(live.*, incoming.*)) return;
    if (live.*) |old| gpa.free(old);
    live.* = incoming.*;
    incoming.* = null;
}

/// List variant of mergeOptText: adopt only when live's list is empty; `&.{}` (len 0)
/// is skipped by freeOwnedAnime, so the transferred slice isn't freed twice.
fn mergeStrList(live: *[]const []const u8, incoming: *[]const []const u8) void {
    if (live.*.len == 0) {
        live.* = incoming.*;
        incoming.* = &.{};
    }
}

/// Background task: search and post results back to the UI thread.
pub fn searchTask(loop: *Loop, gpa: Allocator, io: std.Io, provider: SourceProvider, query: []const u8, page: u32, translation: domain.Translation) void {
    // NOTE: `query` ownership is transferred to the `search_done` event's `for_query`
    // on the success path; the UI thread frees it there. On all error paths we free it
    // here explicitly before returning. Do NOT add a defer — it would free the string
    // before the UI thread reads `ev.for_query`, causing a use-after-free.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const raw = provider.search(arena.allocator(), io, query, .{
        .translation = translation,
        .limit = source_mod.search_page_size,
        .page = page,
    }) catch |e| {
        log.debug("search failed: {s}", .{@errorName(e)});
        gpa.free(query);
        // @errorName is a static string (immortal) — safe to thread into the toast.
        loop.postEvent(.{ .task_error = @errorName(e) }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };

    // Dupe every owned string we might thread into the UI so arena teardown
    // cannot leave dangling references in the event payload.
    var owned = std.ArrayListUnmanaged(Anime).empty;
    owned.ensureTotalCapacity(gpa, raw.len) catch |e| {
        log.debug("search result alloc failed: {s}", .{@errorName(e)});
        gpa.free(query);
        loop.postEvent(.{ .task_error = @errorName(e) }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };
    for (raw) |a| {
        const duped = dupeOwnedAnime(gpa, a) catch continue;
        owned.appendAssumeCapacity(duped);
    }

    // `owned.items` is a sub-slice of an over-allocated backing buffer —
    // `ensureTotalCapacity` grows by more than requested so len < capacity.
    // `gpa.free(owned.items)` would mismatch the allocation length and panic.
    // `toOwnedSlice` resizes to exact fit (len == capacity), giving a slice
    // safe to pass to gpa.free on either path below.
    const exact = owned.toOwnedSlice(gpa) catch {
        for (owned.items) |r| freeOwnedAnime(gpa, r);
        owned.deinit(gpa);
        gpa.free(query);
        return;
    };

    loop.postEvent(.{ .search_done = .{
        .results = exact,
        .for_query = query,
        .page = page,
    } }) catch {
        // Post failed — we still own everything; free it all.
        for (exact) |r| freeOwnedAnime(gpa, r);
        gpa.free(exact); // exact-fit: len == capacity, free is valid
        gpa.free(query);
    };
    // On success: `exact` and `query` are now owned by the event.
    // The UI thread frees them via gpa.free(ev.results) and gpa.free(ev.for_query).
}

/// Background task: fetch one page of the Popular feed for `window` (ROD-239).
/// Mirrors searchTask's ownership shape — dupes every owned string into gpa so the
/// event payload outlives the worker's arena, and the UI thread frees `results`
/// via the `.popular_done` arm. No query string to thread (the feed has none); a
/// failure posts `.popular_error` (whose handler clears the slot's loading flag
/// and marks it failed).
pub fn popularTask(loop: *Loop, gpa: Allocator, io: std.Io, provider: SourceProvider, window: source_mod.PopularWindow, page: u32, drain: *ThreadDrain) void {
    defer drain.finish(); // ROD-251: detached; account so teardown can drain us
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const raw = provider.popular(arena.allocator(), io, .{
        .window = window,
        .page = page,
    }) catch |e| {
        log.debug("popular failed: {s}", .{@errorName(e)});
        loop.postEvent(.{ .popular_error = .{ .window = window, .cause = e } }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };

    // Dupe every owned string we thread into the UI so arena teardown cannot leave
    // dangling references in the event payload (mirrors searchTask).
    var owned = std.ArrayListUnmanaged(Anime).empty;
    owned.ensureTotalCapacity(gpa, raw.len) catch |e| {
        log.debug("popular result alloc failed: {s}", .{@errorName(e)});
        loop.postEvent(.{ .popular_error = .{ .window = window, .cause = e } }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };
    for (raw) |a| {
        const duped = dupeOwnedAnime(gpa, a) catch continue;
        owned.appendAssumeCapacity(duped);
    }

    // toOwnedSlice resizes to exact fit (len == capacity) so gpa.free is valid on
    // either path below (see searchTask for the over-allocation rationale).
    const exact = owned.toOwnedSlice(gpa) catch {
        for (owned.items) |r| freeOwnedAnime(gpa, r);
        owned.deinit(gpa);
        return;
    };

    loop.postEvent(.{ .popular_done = .{
        .results = exact,
        .window = window,
        .page = page,
    } }) catch {
        for (exact) |r| freeOwnedAnime(gpa, r);
        gpa.free(exact); // exact-fit: len == capacity, free is valid
    };
}

/// Fill an Anime's blank fields from AniList metadata — AllAnime is the source of
/// truth, so only nulls are filled. Each string/slice deep-copies into `gpa`
/// before the arena `meta` came from is torn down; a failed copy keeps the prior
/// (blank) value rather than aliasing the soon-dead arena. Shared by the
/// search-page enrich and the Discover lazy zoom enrich (ROD-239).
pub fn applyMetadata(gpa: Allocator, a: *Anime, meta: anilist.Metadata) void {
    if (a.english_name == null) a.english_name = dupeOptText(gpa, meta.title_english) catch a.english_name;
    if (a.native_name == null) a.native_name = dupeOptText(gpa, meta.title_native) catch a.native_name;
    // Prefer a fetchable absolute cover over a relative source ref (ROD-267): an
    // AniList/MAL url beats a bare `mcovers/…` that only resolves behind the
    // provider. Free the old relative ref before adopting; a failed dup keeps it.
    if (preferCover(a.thumb, meta.thumb)) {
        if (dupeOptText(gpa, meta.thumb) catch null) |t| {
            if (a.thumb) |old| gpa.free(old);
            a.thumb = t;
        }
    }
    if (a.status == null) a.status = dupeOptText(gpa, meta.status) catch a.status;
    if (a.kind == null) a.kind = dupeOptText(gpa, meta.kind) catch a.kind;
    if (a.description == null) a.description = dupeOptText(gpa, meta.description) catch a.description;
    if (a.genres.len == 0) {
        if (dupeOwnedStrList(gpa, meta.genres) catch null) |g| a.genres = g;
    }
    if (a.studios.len == 0) {
        if (dupeOwnedStrList(gpa, meta.studios) catch null) |s| a.studios = s;
    }
    if (a.anilist_id == null) a.anilist_id = meta.anilist_id;
    if (a.mal_id == null) a.mal_id = meta.mal_id;
    if (a.total_episodes == null) a.total_episodes = meta.total_episodes;
    if (a.duration == null) a.duration = meta.duration;
    if (a.year == null) a.year = meta.year;
    if (a.season == null) a.season = meta.season;
    if (a.start_date == null) a.start_date = meta.start_date;
    if (a.score == null) a.score = meta.score;
}

/// Fill the null fields of an in-memory `Anime` from a stored `AnimeRecord`,
/// taking gpa-owned copies so they ride `freeOwnedAnime`. The record→Anime
/// sibling of `applyMetadata` (meta→Anime): both back-fill only nulls, so a
/// stored value never clobbers a fresher one already on the row. Pure — operates
/// on the passed row + record and touches no controller state. Shared by the
/// search-page hydrate (`SearchController.hydrateResultsFromStore`) and the
/// Discover-feed hydrate (`DiscoverState.hydrateSlotFromStore`, ROD-268), so a
/// card whose provider thumb carries no mineable AniList id still enriches
/// deterministically by the id a past match already stored.
pub fn hydrateAnimeFromRecord(gpa: Allocator, a: *Anime, rec: store_mod.AnimeRecord) void {
    if (a.english_name == null) a.english_name = dupeOptText(gpa, rec.title_english) catch a.english_name;
    if (a.native_name == null) a.native_name = dupeOptText(gpa, rec.native_name) catch a.native_name;
    if (a.thumb == null) a.thumb = dupeOptText(gpa, rec.cover_url) catch a.thumb;
    if (a.status == null) a.status = dupeOptText(gpa, rec.status) catch a.status;
    if (a.description == null) a.description = dupeOptText(gpa, rec.description) catch a.description;
    if (a.kind == null) a.kind = dupeOptText(gpa, rec.kind) catch a.kind;
    if (a.anilist_id == null) a.anilist_id = if (rec.anilist_id) |x| std.math.cast(u64, x) else null;
    if (a.mal_id == null) a.mal_id = if (rec.mal_id) |x| std.math.cast(u64, x) else null;
    if (a.total_episodes == null) a.total_episodes = if (rec.total_episodes) |x| std.math.cast(u32, x) else null;
    if (a.duration == null) a.duration = if (rec.duration) |x| std.math.cast(u32, x) else null;
    if (a.year == null) a.year = if (rec.year) |x| std.math.cast(u32, x) else null;
    if (a.score == null) a.score = if (rec.score) |x| std.math.cast(u32, x) else null;
    // Season/start_date are pure values (no heap); genres/studios are deep-copied
    // into gpa so they outlive the caller's scratch arena and ride freeOwnedAnime.
    if (a.season == null) a.season = if (rec.season) |tag| domain.Season.fromString(tag) else null;
    if (a.start_date == null) a.start_date = rec.startDate();
    if (a.genres.len == 0) a.genres = dupeOwnedStrList(gpa, rec.genres) catch a.genres;
    if (a.studios.len == 0) a.studios = dupeOwnedStrList(gpa, rec.studios) catch a.studios;
}

/// Background task: enrich one page of search results from AniList. `results` and
/// `query` are GPA-owned by this task and transferred to the `.search_enriched`
/// event on success (freed here on failure). Fills each row via `applyMetadata`.
pub fn enrichTask(
    loop: *Loop,
    gpa: Allocator,
    io: std.Io,
    results: []Anime,
    query: []const u8,
    offset: usize,
) void {
    var posted = false;
    defer if (!posted) {
        for (results) |a| freeOwnedAnime(gpa, a);
        gpa.free(results);
        gpa.free(query);
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // ROD-278: page-level answered signal — the handler stamps the freshness clock
    // only if EVERY row got an answer (a match or a confirmed no-match). If any row's
    // enrich hit a transport failure (error.NoAnswer / OOM), leave the whole page
    // un-stamped so those rows retry on next view instead of burning the clock on a
    // failed fetch. Conservative: a partial-failure page also re-enriches its answered
    // rows next view (harmless waste), but never stamps a row AniList never reached.
    var all_answered = true;
    for (results) |*a| {
        if (anilist.enrich(arena.allocator(), io, a.*)) |maybe_meta| {
            if (maybe_meta) |meta| applyMetadata(gpa, a, meta);
        } else |err| {
            all_answered = false;
            log.debug("search enrich got no answer: {s}", .{@errorName(err)});
        }
    }

    loop.postEvent(.{ .search_enriched = .{ .results = results, .for_query = query, .offset = offset, .answered = all_answered } }) catch |pe| {
        log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return; // `posted` stays false → the defer frees results/query
    };
    posted = true;
}

/// ROD-182 refresh-on-view: a show was opened and its persisted enrichment read
/// stale (`Store.enrichmentStale`), so re-pull AniList metadata and post it for the
/// UI thread to persist + reload. `stub` is a gpa-owned identity record
/// (id/name/english_name/anilist_id) the caller built from the stored row — blank
/// beyond identity, so `applyMetadata`'s fill-if-null fills every field from `meta`
/// and the store's upsert COALESCE then overwrites stored content with the fresh
/// values (keeping stored values where AniList returned null): a content refresh
/// with no in-memory overwrite-merge. `stub` and `source` are gpa-owned; ownership
/// transfers to the `enrichment_refreshed` event, or both are freed here on a post
/// failure. Miss contract, split by ROD-278: a *confirmed* no-match posts `stub`
/// UNCHANGED with `answered = true` — the handler stamps it fresh, a negative cache
/// that stops re-hammering AniList until the TTL lapses. A transport failure (no
/// answer reached) posts `stub` UNCHANGED with `answered = false` — the handler
/// skips the stamp so the next view retries instead of burning the freshness clock.
pub fn refreshEnrichTask(
    loop: *Loop,
    gpa: Allocator,
    io: std.Io,
    stub: Anime,
    source: []const u8,
    drain: *ThreadDrain,
) void {
    defer drain.finish(); // detached; account so teardown can drain us
    var a = stub;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // ROD-278: value (a match, or a confirmed no-match `null`) means AniList
    // answered → stamp. The error arm (transport failure / OOM) means it didn't →
    // leave the row un-stamped so the next view retries.
    var answered = true;
    if (anilist.enrich(arena.allocator(), io, a)) |maybe_meta| {
        if (maybe_meta) |meta| applyMetadata(gpa, &a, meta);
    } else |err| {
        answered = false;
        log.debug("refresh enrich got no answer: {s}", .{@errorName(err)});
    }
    loop.postEvent(.{ .enrichment_refreshed = .{ .result = a, .source = source, .answered = answered } }) catch |pe| {
        log.debug("postEvent failed: {s}", .{@errorName(pe)});
        freeOwnedAnime(gpa, a);
        gpa.free(source);
    };
}

/// Lazy single-show enrich for the Discover zoom (ROD-239): the feed payload has
/// no synopsis (anyCard has no description), so opening a card enriches just that
/// show from AniList — far cheaper than enriching all ~30 grid cards proactively.
/// `anime` is gpa-owned (the caller duped it); ownership transfers to the
/// discover_enriched event on success, or is freed here on a post failure.
/// `window` routes the merge to the right per-window slot.
pub fn discoverEnrichTask(loop: *Loop, gpa: Allocator, io: std.Io, anime: Anime, window: source_mod.PopularWindow, drain: *ThreadDrain) void {
    defer drain.finish(); // ROD-251: detached; account so teardown can drain us
    var a = anime;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // A confirmed no-match still posts `a` unchanged — the merge is then a harmless
    // self-replace and the zoom shows no synopsis (none exists). ROD-278: stamp
    // freshness only when AniList answered; a transport failure leaves this card
    // un-stamped so it retries on next view.
    var answered = true;
    if (anilist.enrich(arena.allocator(), io, a)) |maybe_meta| {
        if (maybe_meta) |meta| applyMetadata(gpa, &a, meta);
    } else |err| {
        answered = false;
        log.debug("discover enrich got no answer: {s}", .{@errorName(err)});
    }
    loop.postEvent(.{ .discover_enriched = .{ .result = a, .window = window, .answered = answered } }) catch {
        freeOwnedAnime(gpa, a);
    };
}

/// Batch-enrich a whole Discover feed page from AniList in ONE fetch (ROD-247):
/// score + genres + season, the card signals the popular feed nulls. `stubs` are
/// gpa-owned copies of the page's cards (the caller filtered to those with a
/// mineable anilist_id); ownership transfers to the discover_batch_enriched event
/// on success, or is freed here on a post failure — the same contract as
/// `enrichTask`. `window` routes the merge to the right per-window slot.
///
/// One arena feeds N shows: every enriched field is deep-copied into GPA by
/// `applyMetadata` while the arena is still live, so nothing aliases the parse
/// arena after teardown. The genres/description slices are arena-borrowed — this
/// is the UAF trap, and the ordering (copy in the loop, `defer arena.deinit()`)
/// is what defuses it.
pub fn discoverBatchEnrichTask(
    loop: *Loop,
    gpa: Allocator,
    io: std.Io,
    stubs: []Anime,
    window: source_mod.PopularWindow,
    drain: *ThreadDrain,
) void {
    defer drain.finish(); // ROD-251: detached; account so teardown can drain us
    var posted = false;
    defer if (!posted) {
        for (stubs) |a| freeOwnedAnime(gpa, a);
        gpa.free(stubs);
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // The caller already filtered to cards with an anilist_id; collect them for the
    // batch query, guarding a stray null so it can't poison the join.
    var ids: std.ArrayList(u64) = .empty;
    for (stubs) |a| {
        if (a.anilist_id) |id| ids.append(arena.allocator(), id) catch {};
    }

    // One round trip for the whole page. ROD-278: enrichBatch errors on a transport
    // miss (vs an empty slice for a reached-but-no-matches page), so a failed page
    // fetch sets answered=false and the handler leaves the slot un-stamped instead of
    // burning the freshness clock on ~30 un-enriched cards. A reached-but-empty page
    // still stamps (answered stays true) — the stubs stay at [--], the same as before.
    var answered = true;
    const metas = anilist.enrichBatch(arena.allocator(), io, ids.items) catch |err| blk: {
        answered = false;
        log.debug("discover batch enrich got no answer: {s}", .{@errorName(err)});
        break :blk &.{};
    };
    for (stubs) |*a| {
        const id = a.anilist_id orelse continue;
        for (metas) |meta| {
            if (meta.anilist_id == id) {
                applyMetadata(gpa, a, meta); // deep-copies out of the arena
                break;
            }
        }
    }

    loop.postEvent(.{ .discover_batch_enriched = .{ .results = stubs, .window = window, .answered = answered } }) catch |pe| {
        log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return; // `posted` stays false → the defer frees stubs
    };
    posted = true;
}

/// Background task: pull history and post it back to the UI thread. Errors are
/// reported as a toast-able message rather than crashing the worker.
pub fn loadHistoryTask(loop: *Loop, arena: Allocator, store: *Store) void {
    const recs = store.loadHistory(arena) catch |err| {
        log.debug("loadHistory failed: {s}", .{@errorName(err)});
        // ROD-234: post a dedicated history-load failure (not the generic task_error)
        // so only a real history-load error raises the "history unavailable" banner.
        loop.postEvent(.{ .history_load_failed = @errorName(err) }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };
    loop.postEvent(.{ .history_loaded = recs }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
}

/// Like loadHistoryTask but for the post-playback refresh (ROD-191): posts
/// dedicated terminal events so run()'s double-buffer reaper always settles —
/// .history_reloaded on success, .history_reload_failed on error. The generic
/// .task_error path would never bump the reload's settle signal, latching the
/// reloader off after one transient failure.
pub fn reloadHistoryTask(loop: *Loop, arena: Allocator, store: *Store) void {
    const recs = store.loadHistory(arena) catch |err| {
        log.debug("history reload failed: {s}", .{@errorName(err)});
        loop.postEvent(.{ .history_reload_failed = {} }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };
    loop.postEvent(.{ .history_reloaded = recs }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
}

/// Background task: fetch episode list and post to UI.
/// `id` ownership: transferred to the posted event (`episodes_done.for_id` on
/// success, `episodes_error.for_id` on failure) so the UI thread can keep-check
/// it; freed here only if the event can't be posted. `drain.finish()` runs last
/// (after the final postEvent), so once the barrier drains this worker can no
/// longer touch loop/gpa (ROD-179).
pub fn episodesTask(loop: *Loop, gpa: Allocator, io: std.Io, provider: SourceProvider, id: []const u8, translation: domain.Translation, drain: *ThreadDrain) void {
    defer drain.finish();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const raw = provider.episodes(arena.allocator(), io, id, translation) catch |e| {
        log.debug("episodes fetch failed: {s}", .{@errorName(e)});
        // Hand `id` to the event so the UI can keep-check a superseded failure
        // (ROD-179); the handler frees it. Free here only if the post fails.
        loop.postEvent(.{ .episodes_error = .{ .cause = e, .for_id = id } }) catch |pe| {
            log.debug("postEvent failed: {s}", .{@errorName(pe)});
            gpa.free(id);
        };
        return;
    };

    var owned: std.ArrayListUnmanaged(domain.EpisodeNumber) = .empty;
    owned.ensureTotalCapacity(gpa, raw.len) catch |e| {
        log.debug("episodes alloc failed: {s}", .{@errorName(e)});
        loop.postEvent(.{ .episodes_error = .{ .cause = e, .for_id = id } }) catch |pe| {
            log.debug("postEvent failed: {s}", .{@errorName(pe)});
            gpa.free(id);
        };
        return;
    };
    for (raw) |ep| {
        const raw_owned = gpa.dupe(u8, ep.raw) catch continue;
        owned.appendAssumeCapacity(.{ .raw = raw_owned });
    }
    const exact = owned.toOwnedSlice(gpa) catch |e| {
        for (owned.items) |ep| gpa.free(ep.raw);
        owned.deinit(gpa);
        // Mirror the error paths above: post so the UI clears `loading` instead of
        // stranding the spinner forever; hand `id` to the event and free it here
        // only if the post fails (ROD-179 review).
        loop.postEvent(.{ .episodes_error = .{ .cause = e, .for_id = id } }) catch |pe| {
            log.debug("postEvent failed: {s}", .{@errorName(pe)});
            gpa.free(id);
        };
        return;
    };

    loop.postEvent(.{ .episodes_done = .{ .episodes = exact, .for_id = id } }) catch {
        for (exact) |ep| gpa.free(ep.raw);
        gpa.free(exact);
        gpa.free(id);
    };
}

const PlaybackProgress = struct {
    time_pos_bits: std.atomic.Value(u64) = .init(0),
    duration_bits: std.atomic.Value(u64) = .init(0),
    seen_update: std.atomic.Value(bool) = .init(false),

    fn record(self: *PlaybackProgress, update: player_mod.PositionUpdate) void {
        self.time_pos_bits.store(@bitCast(update.time_pos), .release);
        self.duration_bits.store(@bitCast(update.duration), .release);
        self.seen_update.store(true, .release);
    }

    fn snapshot(self: *PlaybackProgress) ?player_mod.PositionUpdate {
        if (!self.seen_update.load(.acquire)) return null;
        return .{
            .time_pos = @bitCast(self.time_pos_bits.load(.acquire)),
            .duration = @bitCast(self.duration_bits.load(.acquire)),
        };
    }
};

const PlayTaskCallbackCtx = struct {
    loop: *Loop,
    progress: *PlaybackProgress,
};

fn observedPlaybackWasMeaningful(latest: ?player_mod.PositionUpdate) bool {
    const update = latest orelse return false;
    return update.isMeaningful();
}

fn persistFinalProgress(
    st: *Store,
    source_name: []const u8,
    source_id: []const u8,
    ep_raw: []const u8,
    translation: domain.Translation,
    latest: ?player_mod.PositionUpdate,
) void {
    const update = latest orelse return;
    st.saveProgress(source_name, source_id, translation, ep_raw, update.time_pos, update.duration, Store.nowSecs()) catch |e|
        log.debug("saveProgress failed: {s}", .{@errorName(e)});
}

fn postPositionUpdate(ctx: *anyopaque, update: player_mod.PositionUpdate) void {
    const cb: *PlayTaskCallbackCtx = @ptrCast(@alignCast(ctx));
    cb.progress.record(update);
    // Heartbeat-frequency event: a failed post means the queue is closing
    // (shutdown). Not worth a log line on every tick of a teardown.
    cb.loop.postEvent(.{ .position_update = .{
        .time_pos = update.time_pos,
        .duration = update.duration,
    } }) catch {};
}

/// Background task: resolve stream and launch mpv.
/// All string params are GPA-owned by this task and freed before return.
/// `mpv_path` and `skip_mode` are borrowed from `App.config` (ROD-85), which
/// outlives this thread — they must not be freed here.
pub fn playTask(loop: *Loop, gpa: Allocator, io: std.Io, provider: SourceProvider, id: []const u8, ep_raw: []const u8, translation: domain.Translation, title: []const u8, start_seconds: u64, mal_id: ?u32, episode_ordinal: u32, mpv_path: []const u8, skip_mode: []const u8, quality: domain.Quality) void {
    defer gpa.free(id);
    defer gpa.free(ep_raw);
    defer gpa.free(title);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const ep: domain.EpisodeNumber = .{ .raw = ep_raw };
    const link = provider.resolve(arena.allocator(), io, id, ep, translation, quality) catch |e| {
        log.debug("resolve failed: {s}", .{@errorName(e)});
        loop.postEvent(.{ .play_error = .{ .final = null, .cause = e } }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };

    // ROD-83: fetch OP/ED skip data on this worker thread (never the UI thread).
    const skip = aniskip.prepare(arena.allocator(), io, mal_id, title, aniskip.episodeNumber(ep_raw, episode_ordinal), aniskip.SkipMode.fromString(skip_mode));

    var progress: PlaybackProgress = .{};
    var callback_ctx: PlayTaskCallbackCtx = .{ .loop = loop, .progress = &progress };
    player_mod.play(arena.allocator(), io, mpv_path, link, title, start_seconds, .{
        .ctx = @ptrCast(&callback_ctx),
        .func = postPositionUpdate,
    }, skip) catch |e| {
        log.debug("mpv playback failed: {s}", .{@errorName(e)});
        loop.postEvent(.{ .play_error = .{ .final = progress.snapshot(), .cause = e } }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };

    loop.postEvent(.{ .play_done = progress.snapshot() }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
}

const max_cover_encoded_bytes = 8 * 1024 * 1024;
const max_cover_dimension = 4096;
const max_cover_pixels = max_cover_dimension * max_cover_dimension;

fn postCoverError(loop: *Loop, gpa: Allocator, for_id: []const u8) void {
    loop.postEvent(.{ .cover_error = for_id }) catch gpa.free(for_id);
}

fn postCoverDoneOwned(loop: *Loop, gpa: Allocator, decoded: cover_mod.Pixels, for_id: []const u8) void {
    loop.postEvent(.{ .cover_done = .{
        .rgba = decoded.rgba,
        .width = decoded.w,
        .height = decoded.h,
        .for_id = for_id,
    } }) catch {
        gpa.free(decoded.rgba);
        gpa.free(for_id);
    };
}

// ── On-disk raw cover cache (ROD-171) ────────────────────────────────────────
// A persistence layer one level below `RawCoverCache`: covers fetched in a prior
// run are served from `<cacheDir>/covers/<hash>.jpg` on a cold start, sparing the
// network. Every operation is best-effort — any failure degrades to "not
// persisted" / "cache miss", never to a crash or a stalled cover pipeline.

/// The on-disk cover-cache subdirectory under `paths.cacheDir`. Single source of
/// truth: both `coverCachePath` (where covers are read/written) and the Settings
/// "cover art cache" display row (via `coverCacheDir`) derive from this one name,
/// so the two can never drift (ROD-225).
const cover_subdir = "covers";

/// Absolute path to the cover-cache directory — `<cacheDir>/covers` — allocated
/// in `alloc`. The Settings view renders this so the displayed path honours
/// `$XDG_CACHE_HOME` instead of a hardcoded literal (ROD-225). Propagates the
/// cache-dir resolution error when no cache home can be located.
pub fn coverCacheDir(alloc: Allocator) ![]u8 {
    const dir = try paths.cacheDir(alloc);
    defer alloc.free(dir);
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, cover_subdir });
}

/// hex-16 SHA-256 of `url`: the on-disk cover filename stem. Truncating the
/// 32-byte digest to 8 bytes is ample for a content-addressed personal cache —
/// a (vanishingly unlikely) collision costs a single spurious re-fetch, nothing
/// worse.
fn coverCacheStem(url: []const u8) [16]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    return std.fmt.bytesToHex(digest[0..8].*, .lower);
}

/// Absolute on-disk path for `url`'s cover, allocated in `arena`:
/// `<cacheDir>/covers/<hex-16>.jpg`. Propagates the cache-dir resolution error
/// when no cache home can be located (no `$XDG_CACHE_HOME`/`$HOME`).
fn coverCachePath(arena: Allocator, url: []const u8) ![]u8 {
    const dir = try paths.cacheDir(arena);
    const stem = coverCacheStem(url);
    return std.fmt.allocPrint(arena, "{s}/{s}/{s}.jpg", .{ dir, cover_subdir, &stem });
}

/// Read previously-persisted raw cover bytes for `url`, owned by `gpa`, or null
/// on any miss (no cache dir, file absent, oversized, read error).
fn readCoverDisk(gpa: Allocator, io: std.Io, url: []const u8) ?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const path = coverCachePath(arena_state.allocator(), url) catch return null;

    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);

    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, std.Io.Limit.limited(max_cover_encoded_bytes)) catch null;
}

/// Per-write nonce for the disk-cache temp file (ROD-243). With concurrent cover
/// workers, two threads — or a second app instance — can persist the SAME url at
/// once; a fixed `<path>.tmp` would let them interleave writes into one temp file
/// and then rename a torn `.jpg` into place. A unique suffix per write gives each
/// writer its own temp sibling, so the final atomic rename always promotes a whole
/// file. The thread id keeps it unique across processes too (Linux tids are
/// system-wide). Worst case is a uniquely-named orphan tmp on a hard crash — best-
/// effort cleanup already deletes it on every non-crash failure path.
var disk_tmp_nonce: std.atomic.Value(u64) = .init(0);

/// Persist raw cover `body` for `url` to disk, best-effort. A failure (read-only
/// dir, full disk, no cache home) is logged at debug and otherwise ignored — the
/// cover still renders from the in-memory bytes this run.
fn writeCoverDisk(gpa: Allocator, io: std.Io, url: []const u8, body: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = coverCachePath(arena, url) catch {
        log.debug("cover disk-cache: no cache dir", .{});
        return;
    };
    if (std.fs.path.dirname(path)) |dir| paths.ensureDir(dir);

    // Write to a per-writer temp sibling then atomically rename into place: a
    // crash, full disk, or concurrent writer racing mid-write can never leave a
    // torn `.jpg` that a later cold start would read back as a corrupt cover
    // (ROD-171; per-write nonce added in ROD-243 for the concurrent cover workers).
    const nonce = disk_tmp_nonce.fetchAdd(1, .monotonic);
    const tmp_path = std.fmt.allocPrint(arena, "{s}.{d}.{d}.tmp", .{ path, std.Thread.getCurrentId(), nonce }) catch return;
    var file = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch |e| {
        log.debug("cover disk-cache create failed: {s}", .{@errorName(e)});
        return;
    };
    const wrote = blk: {
        defer file.close(io);
        file.writeStreamingAll(io, body) catch |e| {
            log.debug("cover disk-cache write failed: {s}", .{@errorName(e)});
            break :blk false;
        };
        break :blk true;
    };
    if (!wrote) {
        std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
        return;
    }
    std.Io.Dir.renameAbsolute(tmp_path, path, io) catch |e| {
        log.debug("cover disk-cache rename failed: {s}", .{@errorName(e)});
        std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
    };
}

fn decodeCoverBody(gpa: Allocator, body: []const u8) !cover_mod.Pixels {
    const dims = cover_mod.probeDimensions(body) orelse return error.DecodeFailed;
    if (dims.w == 0 or dims.h == 0 or dims.w > max_cover_dimension or dims.h > max_cover_dimension) {
        return error.DecodeFailed;
    }
    const pixel_count = std.math.mul(u64, dims.w, dims.h) catch return error.DecodeFailed;
    if (pixel_count > max_cover_pixels) return error.DecodeFailed;
    return cover_mod.decodeRgba(gpa, body);
}

/// Insert raw encoded `bytes` into the raw LRU under the lock, taking ownership:
/// the cache keeps them if accepted, otherwise we free them here. Caller must not
/// touch `bytes` afterwards (ROD-243).
fn insertRaw(gpa: Allocator, io: std.Io, caches: *CoverCaches, url: []const u8, bytes: []u8) void {
    caches.mu.lockUncancelable(io);
    defer caches.mu.unlock(io);
    const cached = caches.raw.putOwnedBounded(gpa, url, bytes, max_cover_raw_cache_bytes) catch false;
    if (!cached) gpa.free(bytes);
}

/// Store `decoded` in the decoded LRU and return an INDEPENDENT owned copy for the
/// caller. The clone is taken under the same lock as the insert: once
/// `putOwnedBounded` accepts the value, `decoded.rgba` *is* the cache's pointer, so
/// an unlocked dupe could race a concurrent evict-and-free (ROD-243). If the cache
/// declines the entry the caller still owns `decoded` and we hand it back directly;
/// if the clone OOMs after a successful insert the cache owns the pixels (no
/// double-free) and we surface the error.
fn storeDecodedAndClone(gpa: Allocator, io: std.Io, caches: *CoverCaches, url: []const u8, decoded: cover_mod.Pixels) !cover_mod.Pixels {
    caches.mu.lockUncancelable(io);
    defer caches.mu.unlock(io);
    const cached = caches.decoded.putOwnedBounded(gpa, url, decoded, max_cover_decoded_cache_bytes) catch false;
    if (!cached) return decoded; // cache declined — caller keeps the owned pixels
    const rgba = try gpa.dupe(u8, decoded.rgba); // under lock: `decoded` is now cache-owned
    return .{ .rgba = rgba, .w = decoded.w, .h = decoded.h };
}

/// Wall-clock ceiling for one cover fetch — connect, headers, and body, end to
/// end. Covers are the last app fetch that lacked a deadline (ROD-265): a
/// reachable-but-silent image host would otherwise hang the cover worker forever,
/// leaking its `discover_cover_drain` slot so teardown's `drain()` spin-waits on a
/// counter that never falls (workers.zig `ThreadDrain`). A cover is a GET body of
/// the same class as the AllAnime long-tail (ROD-153), so it shares that 20 s
/// ceiling — far above any healthy image fetch, only tripping on a stalled host.
const cover_fetch_deadline_s = 20;

/// The actual cover GET, run as a cancelable unit of concurrency by `withDeadline`
/// (ROD-265). Takes a provider-resolved `CoverRequest` — an absolute URL plus any
/// CDN headers (ROD-267): some cover CDNs (AllAnime's is Cloudflare-fronted) 403 a
/// refererless GET, so Referer/UA ride along when the provider set them. Owns its
/// `std.http.Client` so a deadline cancel unwinds this frame — freeing the
/// connection — instead of leaving a socket blocked in `recv`. Returns the encoded
/// body as an exact, gpa-owned slice (the caller frees it). Fetch and non-200
/// failures return `error.CoverFetchFailed`; allocation failures propagate as
/// `error.OutOfMemory`. `loadCoverPixels` collapses both — plus the deadline's
/// `error.Timeout` — to a cover miss at the `withDeadline` call site.
fn fetchCoverBody(gpa: Allocator, io: std.Io, req: source_mod.CoverRequest) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const resp_buf = try gpa.alloc(u8, max_cover_encoded_bytes);
    defer gpa.free(resp_buf);
    var resp_writer: std.Io.Writer = .fixed(resp_buf);
    // Accept is ours; Referer/UA come from the provider only when its CDN needs
    // them (AniList/MAL covers need none — the fields stay null).
    var extra: [2]std.http.Header = .{
        .{ .name = "Accept", .value = "image/png,image/jpeg,*/*;q=0.1" },
        undefined,
    };
    var extra_len: usize = 1;
    if (req.referer) |r| {
        extra[1] = .{ .name = "Referer", .value = r };
        extra_len = 2;
    }
    const res = client.fetch(.{
        .location = .{ .url = req.url },
        .method = .GET,
        .response_writer = &resp_writer,
        .headers = if (req.user_agent) |ua| .{ .user_agent = .{ .override = ua } } else .{},
        .extra_headers = extra[0..extra_len],
    }) catch |e| {
        // Covers the deadline cancel (ReadFailed ← Canceled), oversize body (writer
        // full), and ordinary network errors.
        log.debug("cover fetch failed: {s}", .{@errorName(e)});
        return error.CoverFetchFailed;
    };
    if (res.status != .ok) {
        log.debug("cover fetch HTTP {d}", .{@intFromEnum(res.status)});
        return error.CoverFetchFailed;
    }
    return gpa.dupe(u8, resp_writer.buffered());
}

/// Shared cover load (ROD-243): resolve `url` to gpa-owned, INDEPENDENT decoded
/// pixels via cache → disk → network, or return an error. The returned `rgba` is
/// never a cache-owned pointer, so it stays valid past any concurrent eviction —
/// the caller owns it. Safe for concurrent callers: the single-cover worker and the
/// Discover grid worker share one `CoverCaches`.
///
/// Lock rule: every dupe of a slice that lives in (or was just inserted into) a
/// cache happens while `caches.mu` is held; `decodeCoverBody` and `client.fetch`
/// run *unlocked* so a slow decode/fetch never stalls another worker.
///
/// `url` is the raw stored cover ref and is the cache key at every layer (memory,
/// disk). Only the network branch resolves it — via `provider.coverRequest` — into
/// the absolute URL actually fetched, so a CDN-host rotation never invalidates the
/// cache and the CDN host stays behind the provider seam (ROD-267).
pub fn loadCoverPixels(gpa: Allocator, io: std.Io, provider: SourceProvider, url: []const u8, caches: *CoverCaches) !cover_mod.Pixels {
    // 1) Decoded-cache hit: dupe the pixels out under the lock (get() promotes, so
    //    it mutates — even this read holds the lock).
    {
        caches.mu.lockUncancelable(io);
        defer caches.mu.unlock(io);
        if (caches.decoded.get(url)) |d| {
            const rgba = try gpa.dupe(u8, d.rgba);
            return .{ .rgba = rgba, .w = d.w, .h = d.h };
        }
    }

    // 2) Raw-cache hit: copy the encoded bytes out under the lock, decode unlocked.
    {
        const raw_copy: ?[]u8 = blk: {
            caches.mu.lockUncancelable(io);
            defer caches.mu.unlock(io);
            break :blk if (caches.raw.get(url)) |b| try gpa.dupe(u8, b) else null;
        };
        if (raw_copy) |rc| {
            defer gpa.free(rc);
            const decoded = try decodeCoverBody(gpa, rc);
            return storeDecodedAndClone(gpa, io, caches, url, decoded);
        }
    }

    // 3) ROD-171: a raw-LRU miss falls through to disk before the network. A hit
    //    warms both in-memory caches so the rest of this session is a raw hit.
    if (readCoverDisk(gpa, io, url)) |disk_body| {
        if (decodeCoverBody(gpa, disk_body)) |decoded| {
            insertRaw(gpa, io, caches, url, disk_body); // takes ownership of disk_body
            return storeDecodedAndClone(gpa, io, caches, url, decoded);
        } else |e| {
            // A corrupt/truncated cache file: drop it and refetch from network.
            log.debug("cover disk-cache decode failed: {s}", .{@errorName(e)});
            gpa.free(disk_body);
        }
    }

    // 4) Network fetch (unlocked, deadline-bounded), then warm both caches and
    //    persist to disk. The provider resolves the (possibly relative) `url` into
    //    an absolute URL + CDN headers behind the vtable (ROD-267). `withDeadline`
    //    races the fetch against a timer and cancels a stalled host so a silent CDN
    //    can't hang this worker forever (ROD-265); the returned body is a gpa-owned
    //    exact slice we free after decode.
    const req = provider.coverRequest(gpa, url) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CoverFetchFailed, // bad/blocked ref → cover miss
    };
    defer gpa.free(req.url);
    const body = deadline.withDeadline(io, .fromSeconds(cover_fetch_deadline_s), fetchCoverBody, .{ gpa, io, req }) catch |e| {
        if (e == error.Timeout)
            log.debug("cover fetch {s}: aborted past {d}s deadline", .{ url, cover_fetch_deadline_s });
        return error.CoverFetchFailed;
    };
    defer gpa.free(body);
    const decoded = try decodeCoverBody(gpa, body);
    writeCoverDisk(gpa, io, url, body); // ROD-171: persist for the next cold start
    if (gpa.dupe(u8, body)) |raw_copy| {
        insertRaw(gpa, io, caches, url, raw_copy);
    } else |_| {}
    return storeDecodedAndClone(gpa, io, caches, url, decoded);
}

/// Background task: load one cover and post it to the UI thread. `url` is task-owned
/// and freed here; `for_id` transfers to the event on success/error (the UI thread
/// frees it). The decoded pixels handed to the event are an independent copy (see
/// `loadCoverPixels`), so a concurrent cache eviction can't invalidate them. One of
/// N concurrent cover workers sharing `caches` (ROD-243).
pub fn coverTask(
    loop: *Loop,
    gpa: Allocator,
    io: std.Io,
    provider: SourceProvider,
    url: []const u8,
    for_id: []const u8,
    caches: *CoverCaches,
) void {
    defer gpa.free(url);
    const decoded = loadCoverPixels(gpa, io, provider, url, caches) catch |e| {
        log.debug("cover load failed: {s}", .{@errorName(e)});
        postCoverError(loop, gpa, for_id);
        return;
    };
    postCoverDoneOwned(loop, gpa, decoded, for_id);
}

/// Background task: load ONE Discover-grid cover and post it (ROD-240). `url` is a
/// gpa-owned string owned by this task; it transfers to the result event (the UI
/// thread frees it) on both the done and error paths, and is freed here only if the
/// post itself fails. `drain` bounds the worker fan-out: the pump caps how many of
/// these run at once (`config.discoverCoverConcurrency`) by gating spawns on
/// `drain.inflight`, and `finish()` runs as the worker's LAST action (after the
/// final `postEvent`) so the teardown `drain()` can never unblock while a worker
/// might still touch `loop`/`gpa` (ROD-179). N of these plus the single-cover
/// worker may touch `caches` concurrently — safe under its lock (see
/// `loadCoverPixels`). The per-frame pump replaces the old batch worker: instead of
/// one thread draining a snapshot, each frame tops the in-flight set back up to the
/// cap against live slot state, so a fetch is never spent on a card already scrolled
/// past.
pub fn discoverCoverTask(
    loop: *Loop,
    gpa: Allocator,
    io: std.Io,
    provider: SourceProvider,
    url: []const u8,
    caches: *CoverCaches,
    drain: *ThreadDrain,
) void {
    defer drain.finish();
    if (loadCoverPixels(gpa, io, provider, url, caches)) |px| {
        loop.postEvent(.{ .discover_cover_done = .{
            .url = url,
            .rgba = px.rgba,
            .width = px.w,
            .height = px.h,
        } }) catch {
            gpa.free(px.rgba);
            gpa.free(url);
        };
    } else |e| {
        log.debug("discover cover load failed: {s}", .{@errorName(e)});
        loop.postEvent(.{ .discover_cover_error = url }) catch gpa.free(url);
    }
}

/// Heartbeat thread: posts .tick every 100ms until `quit` is set.
pub fn tickTask(loop: *Loop, io: std.Io, quit: *std.atomic.Value(bool)) void {
    while (!quit.load(.acquire)) {
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
        // Like position_update: a failed post here is just the queue closing.
        loop.postEvent(.tick) catch {};
    }
}

/// Current wall-clock time in milliseconds (ms since Unix epoch).
pub fn nowMs(io: std.Io) i64 {
    const ts = std.Io.Clock.real.now(io);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_ms));
}

test "coverCacheStem is a stable hex-16 SHA-256 truncation (ROD-171)" {
    const stem = coverCacheStem("https://example.com/cover.jpg");
    // Pin the truncation: first 8 bytes of SHA-256, lowercase hex.
    try std.testing.expectEqual(@as(usize, 16), stem.len);
    try std.testing.expectEqualStrings("f8ebf6e202ed59a9", &stem);
    for (stem) |c| try std.testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));
    // Distinct URLs map to distinct stems.
    const other = coverCacheStem("https://example.com/cover.png");
    try std.testing.expect(!std.mem.eql(u8, &stem, &other));
}

test "coverCachePath nests the stem under covers/ with a .jpg suffix (ROD-171)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const path = try coverCachePath(arena.allocator(), "https://example.com/cover.jpg");
    try std.testing.expect(std.mem.endsWith(u8, path, "/covers/f8ebf6e202ed59a9.jpg"));
}

test "dupeOwnedAnime round-trips the widened metadata fields leak-clean (ROD-140)" {
    const alloc = std.testing.allocator; // fails the test on any leak or double-free
    const src: Anime = .{
        .id = "show1",
        .name = "Sousou no Frieren",
        .english_name = "Frieren",
        .native_name = "葬送のフリーレン",
        .kind = "TV",
        .season = .fall,
        .start_date = .{ .year = 2023, .month = 9, .day = 29 },
        .genres = &.{ "Adventure", "Drama", "Fantasy" },
        .studios = &.{"Madhouse"},
    };

    const owned = try dupeOwnedAnime(alloc, src);
    defer freeOwnedAnime(alloc, owned);

    // Value types copy through; slices are deep, independent copies.
    try std.testing.expectEqual(domain.Season.fall, owned.season.?);
    try std.testing.expectEqual(@as(?u32, 29), owned.start_date.?.day);
    try std.testing.expectEqual(@as(usize, 3), owned.genres.len);
    try std.testing.expectEqualStrings("Fantasy", owned.genres[2]);
    try std.testing.expect(owned.genres.ptr != src.genres.ptr); // not aliasing the source
    try std.testing.expectEqual(@as(usize, 1), owned.studios.len);
    try std.testing.expectEqualStrings("Madhouse", owned.studios[0]);
}

test "dupeOwnedStrList returns the empty sentinel without allocating" {
    // &.{} in → &.{} out, freeable as a no-op (len 0). No allocator touch.
    const out = try dupeOwnedStrList(std.testing.allocator, &.{});
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "observedPlaybackWasMeaningful requires positive observed position" {
    try std.testing.expect(!observedPlaybackWasMeaningful(null));
    try std.testing.expect(!observedPlaybackWasMeaningful(.{ .time_pos = 0, .duration = 1440 }));
    try std.testing.expect(!observedPlaybackWasMeaningful(.{ .time_pos = -1, .duration = 1440 }));
    try std.testing.expect(observedPlaybackWasMeaningful(.{ .time_pos = 0.5, .duration = 1440 }));
}

test "persistFinalProgress writes the latest observed position" {
    var store = try Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "show1", .title = "Test Show" }, 1000, std.testing.allocator);

    persistFinalProgress(&store, "allanime", "show1", "7", .sub, .{
        .time_pos = 91.5,
        .duration = 1440,
    });

    const saved_resume = (try store.getResume("allanime", "show1", .sub, "7")).?;
    try std.testing.expectApproxEqAbs(@as(f64, 91.5), saved_resume.position_secs, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1440), saved_resume.duration_secs, 0.001);
}

test "persistFinalProgress is a no-op without an observed update" {
    var store = try Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "show1", .title = "Test Show" }, 1000, std.testing.allocator);

    persistFinalProgress(&store, "allanime", "show1", "7", .sub, null);
    try std.testing.expect((try store.getResume("allanime", "show1", .sub, "7")) == null);
}

test "ThreadDrain.drain blocks until every begun worker has finished (ROD-179)" {
    var drain: ThreadDrain = .{};
    // Gate the workers so they're provably still in flight when we assert the
    // accounting and then call drain() — a no-op barrier would let the count
    // race ahead and the test would catch it.
    var release: std.atomic.Value(bool) = .init(false);
    var completed: std.atomic.Value(usize) = .init(0);

    const Worker = struct {
        fn run(d: *ThreadDrain, gate: *std.atomic.Value(bool), c: *std.atomic.Value(usize)) void {
            defer d.finish();
            while (!gate.load(.acquire)) std.Thread.yield() catch {};
            _ = c.fetchAdd(1, .acq_rel);
        }
    };

    var spawned: usize = 0;
    for (0..8) |_| {
        drain.begin();
        const t = std.Thread.spawn(.{}, Worker.run, .{ &drain, &release, &completed }) catch {
            drain.finish(); // spawn failed — rebalance, mirroring the real call site
            continue;
        };
        t.detach(); // never joined; drain() is the only synchronization
        spawned += 1;
    }

    // begin() ran on this thread before each spawn, so the count is exactly the
    // spawn total and nothing has finished yet — the workers are parked on the gate.
    try std.testing.expectEqual(spawned, drain.inflight.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), completed.load(.acquire));

    release.store(true, .release);
    drain.drain();

    // drain() returned ⇒ every worker passed finish() ⇒ every fetchAdd (which
    // precedes the deferred finish) is visible via finish's release / drain's acquire.
    try std.testing.expectEqual(spawned, completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), drain.inflight.load(.acquire));
}

test "preferCover: absolute beats relative, never downgrades or churns (ROD-267)" {
    // Nothing held yet → adopt whatever's present.
    try std.testing.expect(preferCover(null, "mcovers/x.webp"));
    try std.testing.expect(preferCover(null, "https://s4.anilist.co/x.jpg"));
    // Relative held + absolute incoming → upgrade.
    try std.testing.expect(preferCover("mcovers/x.webp", "https://s4.anilist.co/x.jpg"));
    // Absolute held → never downgrade to relative, never swap absolute for absolute.
    try std.testing.expect(!preferCover("https://s4.anilist.co/x.jpg", "mcovers/x.webp"));
    try std.testing.expect(!preferCover("https://a/x.jpg", "https://b/y.jpg"));
    // Relative held + relative incoming → no change (neither is fetchable as-is).
    try std.testing.expect(!preferCover("mcovers/x.webp", "mcovers/y.png"));
    // Nothing incoming → nothing to adopt.
    try std.testing.expect(!preferCover("mcovers/x.webp", null));
    try std.testing.expect(!preferCover(null, null));
}

test "mergeCoverPreferAbsolute: upgrade frees the old relative thumb, keeps absolute otherwise (ROD-267)" {
    const gpa = std.testing.allocator; // flags a leak or double-free

    // Upgrade: relative → absolute. The old relative thumb must be freed (else the
    // testing allocator reports a leak); the absolute's ownership transfers to live.
    {
        var live: ?[]const u8 = try gpa.dupe(u8, "mcovers/x.webp");
        var incoming: ?[]const u8 = try gpa.dupe(u8, "https://s4.anilist.co/x.jpg");
        mergeCoverPreferAbsolute(gpa, &live, &incoming);
        try std.testing.expectEqualStrings("https://s4.anilist.co/x.jpg", live.?);
        try std.testing.expect(incoming == null); // transferred out
        gpa.free(live.?);
    }
    // No swap: absolute held, relative incoming. live is untouched; incoming stays
    // owned by us (the real caller's freeOwnedAnime would reclaim it).
    {
        var live: ?[]const u8 = try gpa.dupe(u8, "https://s4.anilist.co/x.jpg");
        var incoming: ?[]const u8 = try gpa.dupe(u8, "mcovers/x.webp");
        mergeCoverPreferAbsolute(gpa, &live, &incoming);
        try std.testing.expectEqualStrings("https://s4.anilist.co/x.jpg", live.?);
        try std.testing.expect(incoming != null); // not transferred
        gpa.free(live.?);
        gpa.free(incoming.?);
    }
}
