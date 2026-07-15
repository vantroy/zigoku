//! TUI background workers and shared ownership helpers.

const std = @import("std");
const builtin = @import("builtin");
const source_mod = @import("../source.zig");
const domain = @import("../domain.zig");
const store_mod = @import("../store.zig");
const anilist = @import("../anilist.zig");
const resolver = @import("../resolver.zig");
const cover_mod = @import("../cover.zig");
const player_mod = @import("../player.zig");
const aniskip = @import("../aniskip.zig");
const paths = @import("../paths.zig");
const lru_mod = @import("../util/lru.zig");
const deadline = @import("../util/deadline.zig");
const fetchguard = @import("../util/fetchguard.zig");
const event_mod = @import("event.zig");
const log = @import("../log.zig");
const sync = @import("../sync.zig");
const auth_mod = @import("../auth.zig");
const login_loopback = @import("../login_loopback.zig");
const updatecheck = @import("../updatecheck.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const SourceProvider = source_mod.SourceProvider;
const Anime = domain.Anime;
const Loop = event_mod.Loop;

/// Fire-and-forget worker accounting (ROD-179). Superseded workers detach and run out;
/// stale results are keep-checked and dropped. Teardown still waits so nothing touches
/// loop/gpa/io after free.
///
/// Contract:
///   - `begin()` on the spawning thread immediately BEFORE each spawn. On spawn failure,
///     pair with `finish()`.
///   - worker calls `finish()` last (defer), after final `postEvent` returns, so `drain()`
///     means no further touch of loop/gpa/io.
///   - `drain()` once on teardown: blocks until every begun worker finished.
///
/// Atomic counter + yield spin (this std's Thread is spawn/join/detach/yield only).
/// Teardown path only; bounded by in-flight fetch deadline (ROD-153).
///
/// Uncapped on purpose: backpressure is the caller's job (Discover soft-caps via
/// `inflight` at the spawn site, ROD-264). Episode-prefetch debounce (ROD-156) keeps
/// supersedes rare.
///
/// `drain()` needs the event queue still draining: final `postEvent` blocks if the queue
/// is full, and teardown has stopped popping, so a saturated queue can wedge. Shared
/// teardown hazard; pumping the queue while draining is a follow-up.
pub const ThreadDrain = struct {
    inflight: std.atomic.Value(usize) = .init(0),

    /// Raise the count on the spawning thread before spawn so `drain()` never sees a gap.
    pub fn begin(self: *ThreadDrain) void {
        _ = self.inflight.fetchAdd(1, .acq_rel);
    }

    /// Last action of the worker (defer). Release publishes prior effects (final
    /// `postEvent`) to the observer of count-zero in `drain()`.
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

/// Shared mutex-guarded cover caches (ROD-243). Single-cover and Discover grid share the
/// same URL-keyed LRUs so Browse fetches reuse in Discover. `mu` is what makes them safe
/// under N concurrent cover workers.
///
/// Lock discipline (`loadCoverPixels`): dupe of cache-resident/inserted slices under `mu`;
/// `decodeCoverBody` and network fetch UNLOCKED. `LruCache.get` promotes (writer), so pure
/// lookups hold the lock too.
pub const CoverCaches = struct {
    mu: std.Io.Mutex = .init,
    raw: RawCoverCache = .{},
    decoded: DecodedCoverCache = .{},

    /// Teardown only: call after every cover worker has joined.
    pub fn deinit(self: *CoverCaches, gpa: Allocator) void {
        self.decoded.deinit(gpa);
        self.decoded = .{};
        self.raw.deinit(gpa);
        self.raw = .{};
    }
};

/// Episode hot-cache slot: canonical GPA-owned list + Unix-seconds expiry mirroring the
/// DB episode_cache TTL, so the mirror never serves data the DB would refuse (ROD-130).
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
/// In-memory mirror of the DB episode cache (ROD-130), key
/// "source\x00source_id\x00translation". Entries own canonical episode copies (each
/// `.raw` owned); hits dupe into the view so LRU eviction cannot invalidate displayed
/// memory.
pub const EpisodeLruCache = lru_mod.LruCache([]const u8, EpisodeLruEntry, episode_lru_cap, EpisodeListOps);

/// Canonical episode-list clone: outer slice + individually-owned `.raw`, matching
/// `episodesTask` / freeable by `EpisodeState.freeResults` / `EpisodeListOps`.
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

/// Dupe `sources` into `alloc` as one commit (ROD-401): any failure frees everything
/// already duped instead of stranding it, so callers don't hand-roll an N-deep
/// catch/free ladder per spawn site. Caller arms `loading` only after this succeeds.
pub fn dupeAll(alloc: Allocator, comptime n: usize, sources: [n][]const u8) ![n][]u8 {
    var out: [n][]u8 = undefined;
    var filled: usize = 0;
    errdefer for (out[0..filled]) |s| alloc.free(s);
    for (sources, 0..) |s, i| {
        out[i] = try alloc.dupe(u8, s);
        filled = i + 1;
    }
    return out;
}

/// Deep-copy string list (genres, studios): owned slice + owned elements, freeable by
/// `freeOwnedAnime`. Empty input returns `&.{}` (no alloc).
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
        .rank = a.rank,
        .rank_year = a.rank_year,
        .next_airing_at = a.next_airing_at,
        .next_airing_episode = a.next_airing_episode,
    };
    errdefer freeOwnedAnime(alloc, out);

    out.name = try alloc.dupe(u8, a.name);
    out.english_name = try dupeOptText(alloc, a.english_name);
    out.title_romaji = try dupeOptText(alloc, a.title_romaji);
    out.native_name = try dupeOptText(alloc, a.native_name);
    out.thumb = try dupeOptText(alloc, a.thumb);
    out.banner = try dupeOptText(alloc, a.banner);
    out.status = try dupeOptText(alloc, a.status);
    out.description = try dupeOptText(alloc, a.description);
    out.kind = try dupeOptText(alloc, a.kind);
    out.source_material = try dupeOptText(alloc, a.source_material);
    out.rank_type = try dupeOptText(alloc, a.rank_type);
    out.country = try dupeOptText(alloc, a.country);
    out.genres = try dupeOwnedStrList(alloc, a.genres);
    out.studios = try dupeOwnedStrList(alloc, a.studios);
    return out;
}

pub fn freeOwnedAnime(alloc: Allocator, a: Anime) void {
    alloc.free(a.id);
    if (a.name.len > 0) alloc.free(a.name);
    if (a.english_name) |x| alloc.free(x);
    if (a.title_romaji) |x| alloc.free(x);
    if (a.native_name) |x| alloc.free(x);
    if (a.thumb) |x| alloc.free(x);
    if (a.banner) |x| alloc.free(x);
    if (a.status) |x| alloc.free(x);
    if (a.description) |x| alloc.free(x);
    if (a.kind) |x| alloc.free(x);
    if (a.source_material) |x| alloc.free(x);
    if (a.rank_type) |x| alloc.free(x);
    if (a.country) |x| alloc.free(x);
    if (a.genres.len > 0) {
        for (a.genres) |g| alloc.free(g);
        alloc.free(a.genres);
    }
    if (a.studios.len > 0) {
        for (a.studios) |s| alloc.free(s);
        alloc.free(a.studios);
    }
}

/// Prefer enriched cover `inc` over `cur` (ROD-267): adopt when blank, or relative→absolute.
/// Never absolute→relative, never absolute→absolute (no equal-quality churn).
fn preferCover(cur: ?[]const u8, inc: ?[]const u8) bool {
    const incoming = inc orelse return false;
    const current = cur orelse return true;
    return !domain.isAbsoluteUrl(current) and domain.isAbsoluteUrl(incoming);
}

/// AniList discovery search (ROD-327). Off the `SourceProvider` vtable (ROD-324): hits are
/// anilist_id-keyed canonical rows, not provider bindings. Binding is the resolver's job.
pub fn searchTask(loop: *Loop, gpa: Allocator, io: std.Io, query: []const u8, page: u32) void {
    // `query` transfers to `search_done.for_query` on success (UI frees). Error paths free
    // it here. Do NOT defer free: that UAF's the UI thread reading `ev.for_query`.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const raw = anilist.search(arena.allocator(), io, query, page) catch |e| {
        log.debug("search failed: {s}", .{@errorName(e)});
        gpa.free(query);
        // @errorName is static/immortal: safe to put in the toast.
        loop.postEvent(.{ .task_error = @errorName(e) }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };

    // GPA-owned dupes so the event outlives the arena.
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

    // `toOwnedSlice` exact-fits (len == capacity). Freeing `owned.items` raw would
    // mismatch the over-allocated buffer and panic under gpa.
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
        // Post failed: still own everything.
        for (exact) |r| freeOwnedAnime(gpa, r);
        gpa.free(exact); // exact-fit: len == capacity
        gpa.free(query);
    };
}

/// Tier-A resolve for add-to-watchlist (ROD-327). Probes `provider.episodes(candidate_id)`
/// (play provider keys by stringified mal_id). Non-empty = stocked (UI mints binding).
/// Transport fail and empty both post `ok = false` (UI → unbound marker, ROD-329), but
/// only authoritative empty rides `absent_sources` into the ROD-347 negative cache.
/// This worker writes no state.
///
/// `candidate_id` transfers to `resolve_add_result` on successful post (UI frees); free
/// here only if post fails. `drain.finish()` last so a drained barrier means no loop/gpa touch.
pub fn resolveAddTask(loop: *Loop, gpa: Allocator, io: std.Io, provider: SourceProvider, candidate_id: []const u8, anilist_id: i64, translation: domain.Translation, drain: *ThreadDrain) void {
    defer drain.finish();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Three-state (ROD-347): 200-with-empty is authoritative "not stocked" (ROD-346) and
    // earns an absence row; transport error proves nothing (ROD-278).
    const Probe = enum { hit, absent, unknown };
    const probe: Probe = if (provider.episodes(arena.allocator(), io, candidate_id, translation, null)) |eps|
        (if (eps.len > 0) Probe.hit else Probe.absent)
    else |e| blk: {
        log.debug("resolve-add probe failed: {s}", .{@errorName(e)});
        break :blk Probe.unknown;
    };
    const absent: []const []const u8 = if (probe == .absent) blk: {
        const one = gpa.alloc([]const u8, 1) catch break :blk &.{};
        one[0] = provider.name();
        break :blk one;
    } else &.{};

    loop.postEvent(.{ .resolve_add_result = .{
        .ok = probe == .hit,
        .anilist_id = anilist_id,
        .source_id = candidate_id,
        .source = provider.name(),
        .absent_sources = absent,
    } }) catch |pe| {
        log.debug("postEvent failed: {s}", .{@errorName(pe)});
        gpa.free(candidate_id);
        if (absent.len > 0) gpa.free(absent);
    };
}

/// Search-then-match binding resolve (ROD-328/342). Walks `providers` in effective order
/// (ROD-343/344: caller's `Registry.orderedAlloc` snapshot; first confident match wins).
/// `providers` is gpa-owned here so a mid-flight preference change cannot retarget the walk.
///
/// Per provider (via `resolveViaSearch`): tier A `canonicalKey` first (ROD-366; needed so
/// tier-A-only providers like megaplay and widen retries past browseResolveTarget's first
/// provider are reachable), then own-catalog search: tier B `bestIdMatch`, tier C
/// `bestProviderMatch`. Two title passes (romaji then English). Misses post `ok = false`
/// (add → unbound ROD-329; Play toasts); definitive absences ride `absent_sources` (ROD-347).
/// Add probes `episodes` after a match; Play skips (downstream fetch confirms).
///
/// `canonical` is a gpa deep copy freed here. Hit id dups into gpa and transfers on post.
/// `for_play` selects `.resolve_play_target` vs `.resolve_add_result`. `drain.finish()` last.
pub fn resolveSearchTask(loop: *Loop, gpa: Allocator, io: std.Io, providers: []const SourceProvider, canonical: Anime, anilist_id: i64, translation: domain.Translation, for_play: bool, drain: *ThreadDrain) void {
    defer drain.finish();
    defer gpa.free(providers);
    defer freeOwnedAnime(gpa, canonical);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var absent_names: std.ArrayListUnmanaged([]const u8) = .empty;
    const match = resolveAcrossProviders(arena.allocator(), io, providers, canonical, translation, for_play, &absent_names);
    const resolved: ?[]const u8 = if (match) |m| gpa.dupe(u8, m.id) catch null else null;
    // Slice only: names are static vtable strings.
    const absent: []const []const u8 = if (absent_names.items.len > 0)
        gpa.dupe([]const u8, absent_names.items) catch &.{}
    else
        &.{};

    const ok = resolved != null;
    const source_id: []const u8 = resolved orelse &.{};
    const source: []const u8 = if (ok) match.?.source else &.{};
    const posted = if (for_play)
        loop.postEvent(.{ .resolve_play_target = .{ .ok = ok, .anilist_id = anilist_id, .source_id = source_id, .source = source, .absent_sources = absent } })
    else
        loop.postEvent(.{ .resolve_add_result = .{ .ok = ok, .anilist_id = anilist_id, .source_id = source_id, .source = source, .absent_sources = absent } });
    posted catch |pe| {
        log.debug("postEvent failed: {s}", .{@errorName(pe)});
        if (resolved) |r| gpa.free(r);
        if (absent.len > 0) gpa.free(absent);
    };
}

/// Cross-provider match: catalog id + provider name (static vtable string).
const SearchMatch = struct { id: []const u8, source: []const u8 };

/// One provider's search-resolve verdict (ROD-347). `.match` borrows catalog id from the
/// search arena. `.absent` is definitive (UI may cache). `.unknown` means transport tainted
/// the walk or nothing ran: learn nothing, cache nothing (ROD-278).
const SearchVerdict = union(enum) { match: []const u8, absent, unknown };

/// Walk providers through `resolveViaSearch`; first confident match wins (ROD-343/344).
/// Full two-pass search per provider before the next; sequential (ROD-309). Definitive
/// `.absent` appends to `absent_out` (arena; static vtable names) for ROD-347.
fn resolveAcrossProviders(arena: Allocator, io: std.Io, providers: []const SourceProvider, canonical: Anime, translation: domain.Translation, for_play: bool, absent_out: *std.ArrayListUnmanaged([]const u8)) ?SearchMatch {
    for (providers) |p| {
        switch (resolveViaSearch(arena, io, p, canonical, translation, for_play, null)) {
            .match => |id| return .{ .id = id, .source = p.name() },
            .absent => absent_out.append(arena, p.name()) catch {},
            .unknown => {},
        }
    }
    return null;
}

/// Search→match→probe core of `resolveSearchTask`. Split for unit tests with a stub provider.
fn resolveViaSearch(arena: Allocator, io: std.Io, provider: SourceProvider, canonical: Anime, translation: domain.Translation, for_play: bool, pre_search_gap_ms: ?u64) SearchVerdict {
    var transport_failed = false;
    // Gates `.absent`: without at least one clean tier-A probe or title search, a miss
    // is `.unknown` (learned nothing).
    var probed = false;
    // True if tier-A hit the network this call: gates `pre_search_gap_ms` so no-tier-A
    // providers (search is first request) skip a needless gap (ROD-367).
    var tier_a_probed = false;

    // Tier A (ROD-366) before title search so tier-A-only providers (megaplay: search is
    // `error.Unsupported`) are reachable. Also covers widen retries past the first
    // provider (browseResolveTarget stops there).
    if (provider.canonicalKey(arena, canonical) catch null) |key| {
        // Play skips probe (downstream fetch confirms).
        if (for_play) return .{ .match = key };
        tier_a_probed = true;
        if (provider.episodes(arena, io, key, translation, null)) |eps| {
            if (eps.len > 0) return .{ .match = key };
            // 200-with-empty is authoritative "not stocked" (ROD-347). Still fall through
            // to title search when the provider has one: mal_id may not match the catalog id.
            probed = true;
        } else |e| {
            log.debug("resolve tier-A episode probe failed: {s}", .{@errorName(e)});
            transport_failed = true;
        }
    }

    // ROD-367: background pre-warm spaces tier-A → search so pure-background work
    // does not burst a rate-scoring CDN (ROD-309). Foreground widen passes null.
    // is_test-gated so the suite does not sleep.
    if (pre_search_gap_ms) |g| {
        if (tier_a_probed and !builtin.is_test) nanosleepMs(g);
    }

    const opts: source_mod.SearchOptions = .{
        .translation = translation,
        .limit = source_mod.search_page_size,
        .page = 1,
    };
    const passes = [_]?[]const u8{ canonical.name, canonical.english_name };
    for (passes, 0..) |pass, pi| {
        const query = pass orelse continue;
        if (query.len == 0) continue;
        // Skip redundant second search when English title IS the name.
        if (pi == 1 and std.mem.eql(u8, query, canonical.name)) continue;
        const results = provider.search(arena, io, query, opts) catch |e| {
            // Unsupported = no catalog search (megaplay), not transport: must not taint
            // an absence a clean tier-A probe already established (ROD-366/347).
            if (e != error.Unsupported) {
                log.debug("resolve-search failed: {s}", .{@errorName(e)});
                transport_failed = true;
            }
            continue;
        };
        probed = true;
        const idx = resolver.bestIdMatch(canonical, results) orelse
            resolver.bestProviderMatch(canonical, results) orelse continue;
        const matched_id = results[idx].id;
        // Add probes episodes (parity with resolveAddTask; listing can be empty). Play
        // skips. Sequential after search (ROD-309). Fail/empty falls through to next title
        // pass: one dead listing must not deny the other title's match.
        if (!for_play) {
            const eps = provider.episodes(arena, io, matched_id, translation, null) catch |e| {
                log.debug("resolve-search episode probe failed: {s}", .{@errorName(e)});
                transport_failed = true;
                continue;
            };
            if (eps.len == 0) continue;
        }
        return .{ .match = matched_id };
    }
    // Clean miss is definitive only if an authoritative pass ran and transport did not
    // hide a hit (must not poison the negative cache).
    if (transport_failed or !probed) return .unknown;
    return .absent;
}

/// Gap between pre-warm per-provider passes (ROD-351). Pure background, so it can
/// avoid looking like a CDN burst (ROD-309); foreground resolve does not use this.
const prewarm_gap_ms: u64 = 1500;

/// Eager sibling pre-warm (ROD-351). Walks `providers` (UI-filtered: no binding, no
/// fresh absence) via shared `resolveViaSearch` (ROD-367) so dual-capability providers
/// whose tier-A lists empty still fall through to search: a warm-only false absence
/// would strand flips (ROD-366/368). One `.prewarm_result` per settled provider (UI
/// mints/caches incrementally); `.unknown` posts nothing. Sequential with gaps (ROD-309).
/// `.prewarm_done` always closes the single-flight guard.
///
/// `providers`/`canonical` gpa-owned here. Match id dups into gpa and transfers on post.
/// `cancel` (App.prewarm.cancel) polled between hops so an advancing fallback can yield
/// CDN budget; `.prewarm_done` still posts.
pub fn prewarmTask(loop: *Loop, gpa: Allocator, io: std.Io, providers: []const SourceProvider, canonical: Anime, anilist_id: i64, translation: domain.Translation, cancel: *const std.atomic.Value(bool), drain: *ThreadDrain) void {
    defer drain.finish();
    defer gpa.free(providers);
    defer freeOwnedAnime(gpa, canonical);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    for (providers, 0..) |p, i| {
        if (cancel.load(.acquire)) break;
        if (i > 0) nanosleepMs(prewarm_gap_ms);
        if (cancel.load(.acquire)) break;
        const verdict = resolveViaSearch(arena.allocator(), io, p, canonical, translation, false, prewarm_gap_ms);
        switch (verdict) {
            .match => |id| {
                const owned = gpa.dupe(u8, id) catch continue;
                loop.postEvent(.{ .prewarm_result = .{ .anilist_id = anilist_id, .source = p.name(), .source_id = owned, .absent = false } }) catch |pe| {
                    log.debug("postEvent failed: {s}", .{@errorName(pe)});
                    gpa.free(owned);
                };
            },
            .absent => loop.postEvent(.{ .prewarm_result = .{ .anilist_id = anilist_id, .source = p.name(), .source_id = &.{}, .absent = true } }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)}),
            .unknown => {},
        }
    }
    loop.postEvent(.prewarm_done) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
}

/// One Discover feed page for `axis` from AniList (ROD-336). Off the vtable (ROD-324):
/// anilist_id-keyed, fully enriched (no follow-up enrich). GPA-owned results outlive the
/// arena; UI frees via `.discover_feed`. `now_ms` anchors This Season. Three-state (ROD-278):
/// transport miss posts `.discover_feed_error`; empty page is a confirmed answer.
pub fn discoverFeedTask(loop: *Loop, gpa: Allocator, io: std.Io, axis: anilist.DiscoverAxis, page: u32, now_ms: i64, drain: *ThreadDrain) void {
    defer drain.finish(); // ROD-251: detached; account so teardown can drain us
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const feed = anilist.discover(arena.allocator(), io, axis, page, now_ms) catch |e| {
        log.debug("discover feed failed: {s}", .{@errorName(e)});
        loop.postEvent(.{ .discover_feed_error = .{ .axis = axis, .cause = e } }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };

    // GPA-owned dupes so the event outlives the arena (mirrors searchTask).
    var owned = std.ArrayListUnmanaged(Anime).empty;
    owned.ensureTotalCapacity(gpa, feed.rows.len) catch |e| {
        log.debug("discover feed alloc failed: {s}", .{@errorName(e)});
        loop.postEvent(.{ .discover_feed_error = .{ .axis = axis, .cause = e } }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };
    for (feed.rows) |a| {
        const duped = dupeOwnedAnime(gpa, a) catch continue;
        owned.appendAssumeCapacity(duped);
    }

    // Exact-fit so gpa.free is valid (see searchTask).
    const exact = owned.toOwnedSlice(gpa) catch {
        for (owned.items) |r| freeOwnedAnime(gpa, r);
        owned.deinit(gpa);
        return;
    };

    loop.postEvent(.{ .discover_feed = .{
        .results = exact,
        .axis = axis,
        .page = page,
        .has_next = feed.has_next_page,
    } }) catch {
        for (exact) |r| freeOwnedAnime(gpa, r);
        gpa.free(exact); // exact-fit: len == capacity
    };
}

/// Fill blank Anime fields from AniList metadata (nulls only). Strings deep-copy into
/// `gpa` before the arena `meta` dies; failed copy keeps prior blank (no arena alias).
/// Used by ROD-182 refresh-on-view.
pub fn applyMetadata(gpa: Allocator, a: *Anime, meta: anilist.Metadata) void {
    if (a.english_name == null) a.english_name = dupeOptText(gpa, meta.title_english) catch a.english_name;
    // ROD-312: stash true romaji alongside provider `name` (never overwrite here; see
    // title_romaji's doc) so the canonical write can heal canonical.title.
    if (a.title_romaji == null) a.title_romaji = dupeOptText(gpa, meta.title_romaji) catch a.title_romaji;
    if (a.native_name == null) a.native_name = dupeOptText(gpa, meta.title_native) catch a.native_name;
    // Prefer absolute cover over relative provider ref (ROD-267). Free old before adopt;
    // failed dup keeps it.
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
    if (a.source_material == null) a.source_material = dupeOptText(gpa, meta.source_material) catch a.source_material;
    if (a.rank == null) a.rank = meta.rank;
    if (a.rank_type == null) a.rank_type = dupeOptText(gpa, meta.rank_type) catch a.rank_type;
    if (a.rank_year == null) a.rank_year = meta.rank_year;
    if (a.next_airing_at == null) a.next_airing_at = meta.next_airing_at;
    if (a.next_airing_episode == null) a.next_airing_episode = meta.next_airing_episode;
    if (a.country == null) a.country = dupeOptText(gpa, meta.country) catch a.country;
}

/// Fill null Anime fields from a stored `AnimeRecord` (gpa-owned, freeOwnedAnime).
/// Sibling of `applyMetadata`: nulls only, never clobber fresher in-memory values.
/// Shared by search/Discover hydrates (ROD-268) so cards without a mineable AniList id
/// still enrich from a past match's stored id.
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
    // genres/studios deep-copied into gpa so they outlive caller's scratch arena.
    if (a.season == null) a.season = if (rec.season) |tag| domain.Season.fromString(tag) else null;
    if (a.start_date == null) a.start_date = rec.startDate();
    if (a.genres.len == 0) a.genres = dupeOwnedStrList(gpa, rec.genres) catch a.genres;
    if (a.studios.len == 0) a.studios = dupeOwnedStrList(gpa, rec.studios) catch a.studios;
    if (a.source_material == null) a.source_material = dupeOptText(gpa, rec.source_material) catch a.source_material;
    if (a.rank == null) a.rank = if (rec.rank) |x| std.math.cast(u32, x) else null;
    if (a.rank_type == null) a.rank_type = dupeOptText(gpa, rec.rank_type) catch a.rank_type;
    if (a.rank_year == null) a.rank_year = if (rec.rank_year) |x| std.math.cast(u32, x) else null;
    if (a.next_airing_at == null) a.next_airing_at = rec.next_airing_at;
    if (a.next_airing_episode == null) a.next_airing_episode = if (rec.next_airing_episode) |x| std.math.cast(u32, x) else null;
    if (a.country == null) a.country = dupeOptText(gpa, rec.country) catch a.country;
}

/// ROD-182 refresh-on-view: re-pull AniList when persisted enrichment is stale. `stub` is
/// gpa identity-only (id/name/english_name/anilist_id) so fill-if-null + upsert COALESCE
/// rewrites stored content with no in-memory merge. `stub`/`source` transfer to
/// `enrichment_refreshed`, or free here on post failure.
///
/// Miss contract (ROD-278): confirmed no-match posts `stub` with `answered = true` (handler
/// stamps negative cache until TTL). Transport failure posts `answered = false` (no stamp;
/// next view retries without burning the freshness clock).
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
    // ROD-278: Ok(match|null) → AniList answered, stamp. Err → leave un-stamped for retry.
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

/// Pull history and post to the UI thread.
pub fn loadHistoryTask(loop: *Loop, arena: Allocator, store: *Store) void {
    const recs = store.loadHistory(arena) catch |err| {
        log.debug("loadHistory failed: {s}", .{@errorName(err)});
        // ROD-234: dedicated failure, not generic task_error (banner is history-only).
        loop.postEvent(.{ .history_load_failed = @errorName(err) }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };
    loop.postEvent(.{ .history_loaded = recs }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
}

/// Reconcile with AniList then flush local changes (ROD-291). Debounced off render via
/// `.tick`. PULL-THEN-PUSH like CLI `zigoku sync` (ROD-285): pull reconciles first so a
/// farther-ahead remote value is not blind-lowered by push. Both engines are total
/// (summary, never error). Skip push when pull already hit 401/429/store error.
///
/// `pull_only` (ROD-293): launch pull-refresh only; same `.sync_flushed` with `pushed = 0`
/// so the handler shows ↓ reconcile whisper, not ↑.
///
/// `credentials` by value (slices in run()'s auth arena). `inflight` cleared in defer so a
/// failed post cannot latch the one-flush gate. Dropped flush self-heals: rows stay dirty.
pub fn syncFlushTask(
    loop: *Loop,
    gpa: Allocator,
    io: std.Io,
    store: *Store,
    credentials: auth_mod.Auth,
    now_unix: i64,
    inflight: *std.atomic.Value(bool),
    pull_only: bool,
) void {
    defer inflight.store(false, .release);

    const pull = sync.pullAll(gpa, io, store, credentials, now_unix);
    // CLI-only `unmatched_ids`; free so the TUI path does not leak.
    if (pull.unmatched_ids.len > 0) gpa.free(pull.unmatched_ids);

    // pull_only (ROD-293), or pull already hit a wall push would too (401/429/store).
    const skip_push = pull_only or pull.unauthorized or pull.rate_limited or pull.store_error;
    const push: ?sync.Summary = if (skip_push) null else sync.pushAll(gpa, io, store, credentials, now_unix);

    const outcome: event_mod.SyncFlushOutcome = .{
        .pushed = if (push) |p| p.pushed else 0,
        .reconciled = pull.updated,
        .expired = pull.expired or if (push) |p| p.expired else false,
    };
    loop.postEvent(.{ .sync_flushed = outcome }) catch |pe|
        log.debug("sync flush postEvent failed: {s}", .{@errorName(pe)});
}

/// Poll interval (ms) for `pushOnQuit`'s pool-independent wait (ROD-294).
const quit_poll_ms: u64 = 5;

/// Bounded best-effort push on quit (ROD-294). From run()'s fast-exit AFTER terminal
/// restore and BEFORE `_exit`. Posts no event (store+network only) so it sidesteps the
/// ROD-179/232 event-queue wedge. Must not run alongside a pull (ROD-285); caller checks
/// connected + no sync inflight.
///
/// Push on its own thread; bound the WAIT with libc `nanosleep`, not `withDeadline`
/// (same Io pool as the push: under starvation that arms no real deadline, and an
/// unbounded op one line before `_exit` is the quit-hang ROD-232 kills). Stalled push
/// abandoned to `_exit`. Partial land is fine: `pushAll` stamps rows as it goes; rest
/// re-flush next launch.
pub fn pushOnQuit(
    gpa: Allocator,
    io: std.Io,
    store: *Store,
    credentials: auth_mod.Auth,
    now_unix: i64,
    deadline_ms: i64,
) void {
    // Heap `done`, intentionally leaked on success: quitPushBody may set it after we
    // return (abandoned push). Stack would dangle. `_exit` reclaims (ROD-232). Free only
    // on spawn failure (we are sole owner).
    const done = gpa.create(std.atomic.Value(bool)) catch return;
    done.* = .init(false);
    const t = std.Thread.spawn(.{}, quitPushBody, .{ gpa, io, store, credentials, now_unix, done }) catch {
        gpa.destroy(done);
        return;
    };
    // Monotonic wall clock, not iteration count: nanosleep returns early on signals, and
    // SIGWINCH stays live through quit (vaxis, process-wide), so a fixed poll count would
    // let a resize storm collapse the budget. Cut-short sleep just loops.
    //
    // Validate `deadline_ms` (assert was stripped in Release). Saturating multiply so an
    // oversized deadline cannot wrap the budget.
    const ms = std.math.cast(u64, deadline_ms) orelse return;
    const budget_ns: u64 = ms *| std.time.ns_per_ms;
    // Clock failure returns 0. First-read 0: skip wait (cannot bound; never hang). Later 0:
    // `0 -% start` wraps huge and ends the loop.
    const start = monotonicNs();
    if (start != 0) {
        while (!done.load(.acquire) and monotonicNs() -% start < budget_ns) nanosleepMs(quit_poll_ms);
    }
    // Never join: stalled push must not block quit. detach; `_exit` reaps thread + leaked done.
    t.detach();
}

/// Quit push body (ROD-294). Sets `done` on every exit so the poll can wake early. Dirty
/// pre-check is inside the bounded region (wedged storage cannot stall past deadline) and
/// reuses `pushAll`'s work-list query so the predicate cannot drift.
fn quitPushBody(
    gpa: Allocator,
    io: std.Io,
    store: *Store,
    credentials: auth_mod.Auth,
    now_unix: i64,
    done: *std.atomic.Value(bool),
) void {
    defer done.store(true, .release);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const dirty = store.loadDirtyForSync(arena.allocator()) catch return;
    if (dirty.len == 0) return;
    // Total (Summary, never error). Inner per-POST deadline may unbounded under pool
    // starvation; caller's poll still bounds quit. Outcome discarded (surface gone);
    // unlanded rows stay dirty.
    _ = sync.pushAll(gpa, io, store, credentials, now_unix);
}

/// Pool-independent sleep via libc `nanosleep` so quit bound is not on the Io pool the
/// push competes for. EINTR may cut short: wait loop is clock-bounded, not sleep-complete
/// (ROD-294).
fn nanosleepMs(ms: u64) void {
    var req = msToTimespec(ms);
    _ = std.c.nanosleep(&req, null);
}

/// ms → timespec. Pure, factored for unit tests (ROD-294).
fn msToTimespec(ms: u64) std.c.timespec {
    return .{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
}

/// Monotonic ns via libc `clock_gettime` for `pushOnQuit`'s bound (ROD-294).
/// CLOCK_MONOTONIC ignores NTP jumps. 0 = failure: first-read → skip wait, later → end
/// wait (never hang). Saturating arithmetic so absurd uptime cannot wrap the bound.
fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec *| std.time.ns_per_s +| nsec;
}

/// In-TUI connect worker (ROD-286): loopback accept off the render thread; post
/// `ConnectOutcome`. `listener`/`cancel`/`arena` borrowed from `App.ConnectState` (freed
/// only after this joins). On `.canceled` skip the post: UI is joining us, and posting
/// into a queue no one drains can wedge that join. Other outcomes post best-effort.
pub fn connectTask(
    loop: *Loop,
    io: std.Io,
    listener: *login_loopback.Listener,
    arena: Allocator,
    cancel: *std.atomic.Value(bool),
) void {
    const outcome = login_loopback.awaitConnect(listener, arena, io, cancel);
    switch (outcome) {
        // UI tore the modal down and is joining; post would risk wedging teardown.
        .canceled => {},
        else => loop.postEvent(.{ .connect_result = outcome }) catch |pe|
            log.debug("connect postEvent failed: {s}", .{@errorName(pe)}),
    }
}

/// Post-playback history refresh (ROD-191). Dedicated settle events
/// (`.history_reloaded` / `.history_reload_failed`) so the double-buffer reaper always
/// settles. Generic `.task_error` would never bump the reload settle signal and would
/// latch the reloader off after one transient failure.
pub fn reloadHistoryTask(loop: *Loop, arena: Allocator, store: *Store) void {
    const recs = store.loadHistory(arena) catch |err| {
        log.debug("history reload failed: {s}", .{@errorName(err)});
        loop.postEvent(.{ .history_reload_failed = {} }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };
    loop.postEvent(.{ .history_reloaded = recs }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
}

/// Fetch episode list and post to UI. `id` transfers to the event (`episodes_done` /
/// `episodes_error` for_id) for keep-check; free here only if post fails.
/// `drain.finish()` last so a drained barrier means no loop/gpa touch (ROD-179).
pub fn episodesTask(loop: *Loop, gpa: Allocator, io: std.Io, provider: SourceProvider, id: []const u8, translation: domain.Translation, count_hint: ?u32, drain: *ThreadDrain) void {
    defer drain.finish();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const raw = provider.episodes(arena.allocator(), io, id, translation, count_hint) catch |e| {
        log.debug("episodes fetch failed: {s}", .{@errorName(e)});
        // id on event for keep-check (ROD-179); free only if post fails.
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
        // Still post so UI clears loading (no stranded spinner); same id ownership.
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
    // Heartbeat: failed post = queue closing; skip log spam on teardown.
    cb.loop.postEvent(.{ .position_update = .{
        .time_pos = update.time_pos,
        .duration = update.duration,
    } }) catch {};
}

/// Total mpv launch attempts per play, including the first (ROD-309). Covers short
/// Cloudflare penalty windows (e.g. restart soon after quit) without hanging a dead stream.
const MAX_PLAY_ATTEMPTS: usize = 3;

/// Backoff before each retry, by just-failed attempt index (0 → before 2nd, 1 → before 3rd).
const RETRY_BACKOFFS_MS = [_]u64{ 2000, 4000 };

/// Retry only on open failure (`MpvOpenFailed` / CDN 403-class) with no meaningful playback
/// yet and budget remaining. Mid-episode drop or quit must not restart-storm. Pure for tests.
fn playAttemptRetryable(cause: anyerror, attempt: usize, played: bool) bool {
    return cause == error.MpvOpenFailed and !played and attempt + 1 < MAX_PLAY_ATTEMPTS;
}

/// Resolve stream and launch mpv. String params (except below) are GPA-owned and freed
/// here. `mpv_path` and `skip_mode` borrow `App.config` (ROD-85); do not free them.
pub fn playTask(loop: *Loop, gpa: Allocator, io: std.Io, provider: SourceProvider, id: []const u8, ep_raw: []const u8, translation: domain.Translation, title: []const u8, start_seconds: u64, mal_id: ?u32, episode_ordinal: u32, mpv_path: []const u8, skip_mode: []const u8, quality: domain.Quality) void {
    defer gpa.free(id);
    defer gpa.free(ep_raw);
    defer gpa.free(title);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const ep: domain.EpisodeNumber = .{ .raw = ep_raw };

    // ROD-83: OP/ED skip once on this worker (never UI); stable across re-resolve retries.
    const skip = aniskip.prepare(arena.allocator(), io, mal_id, title, aniskip.episodeNumber(ep_raw, episode_ordinal), aniskip.SkipMode.fromString(skip_mode));

    var progress: PlaybackProgress = .{};
    var callback_ctx: PlayTaskCallbackCtx = .{ .loop = loop, .progress = &progress };

    // ROD-309: re-resolve a fresh signed URL each attempt (penalty window / expiry), backoff
    // on pre-playback open failure.
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const link = provider.resolve(arena.allocator(), io, id, ep, translation, quality) catch |e| {
            // ROD-300: always-on top-level receipt per failed play.
            log.err("resolve failed for id={s} ep={s} tt={s}: {s}", .{ id, ep_raw, translation.str(), @errorName(e) });
            loop.postEvent(.{ .play_error = .{ .final = null, .cause = e } }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
            return;
        };

        // Fresh per attempt; play() joins its watcher before return so nothing races progress.
        progress = .{};
        player_mod.play(arena.allocator(), io, mpv_path, link, title, start_seconds, .{
            .ctx = @ptrCast(&callback_ctx),
            .func = postPositionUpdate,
        }, skip) catch |e| {
            const played = progress.snapshot() != null;
            if (playAttemptRetryable(e, attempt, played)) {
                const backoff_ms = RETRY_BACKOFFS_MS[attempt];
                log.warn("mpv open failed for id={s} ep={s} (attempt {d}/{d}) — re-resolving in {d}ms", .{ id, ep_raw, attempt + 1, MAX_PLAY_ATTEMPTS, backoff_ms });
                // attempt is 0-based; event surfaces 1-based retry count vs max retries.
                loop.postEvent(.{ .play_retry = .{ .attempt = @intCast(attempt + 1), .max = @intCast(MAX_PLAY_ATTEMPTS - 1) } }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
                nanosleepMs(backoff_ms);
                continue;
            }
            log.err("mpv playback failed for id={s} ep={s}: {s}", .{ id, ep_raw, @errorName(e) });
            loop.postEvent(.{ .play_error = .{ .final = progress.snapshot(), .cause = e } }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
            return;
        };

        break; // played, or exited cleanly
    }

    loop.postEvent(.{ .play_done = progress.snapshot() }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
}

const max_cover_encoded_bytes = 8 * 1024 * 1024;
// Decode footprint cap (ROD-270). Full RGBA goes to Kitty with no pre-downscale: must
// admit real source covers (not thumbnail size) or art falls back. 2560 holds margin over
// largest seen (~1635x2247) and caps concurrent Discover decode RAM.
const max_cover_dimension = 2560;
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

// On-disk raw cover cache (ROD-171): cold-start under RawCoverCache. Best-effort only.

/// Cover cache subdir under `paths.cacheDir`. Shared by `coverCachePath` and Settings
/// display (`coverCacheDir`) so they cannot drift (ROD-225).
const cover_subdir = "covers";

/// Absolute cover-cache dir for Settings (honours `$XDG_CACHE_HOME`, ROD-225).
pub fn coverCacheDir(alloc: Allocator) ![]u8 {
    const dir = try paths.cacheDir(alloc);
    defer alloc.free(dir);
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, cover_subdir });
}

/// hex-16 of first 8 SHA-256 bytes of `url`: on-disk filename stem. Collision → one re-fetch.
fn coverCacheStem(url: []const u8) [16]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    return std.fmt.bytesToHex(digest[0..8].*, .lower);
}

/// `<cacheDir>/covers/<hex-16>.jpg` for `url`, allocated in `arena`.
fn coverCachePath(arena: Allocator, url: []const u8) ![]u8 {
    const dir = try paths.cacheDir(arena);
    const stem = coverCacheStem(url);
    return std.fmt.allocPrint(arena, "{s}/{s}/{s}.jpg", .{ dir, cover_subdir, &stem });
}

/// GPA-owned raw cover bytes for `url`, or null on any miss.
fn readCoverDisk(gpa: Allocator, io: std.Io, url: []const u8) ?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const path = coverCachePath(arena_state.allocator(), url) catch return null;

    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);

    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, std.Io.Limit.limited(max_cover_encoded_bytes)) catch null;
}

/// Per-write temp-file nonce (ROD-243). Concurrent writers of the same url must not share
/// a fixed `.tmp` (torn `.jpg` after rename). Thread id + nonce; orphan tmp only on hard crash.
var disk_tmp_nonce: std.atomic.Value(u64) = .init(0);

/// Persist raw cover to disk, best-effort. Failure still leaves in-memory bytes for this run.
fn writeCoverDisk(gpa: Allocator, io: std.Io, url: []const u8, body: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = coverCachePath(arena, url) catch {
        log.debug("cover disk-cache: no cache dir", .{});
        return;
    };
    if (std.fs.path.dirname(path)) |dir| paths.ensureDir(dir);

    // Per-writer temp then atomic rename: never promote a torn `.jpg` (ROD-171/243).
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

/// Decode gate (ROD-270): probe before decodeRgba so over-cap/degenerate never alloc.
fn coverDimsWithinCap(dims: cover_mod.Dimensions) bool {
    if (dims.w == 0 or dims.h == 0 or dims.w > max_cover_dimension or dims.h > max_cover_dimension) return false;
    const pixel_count = std.math.mul(u64, dims.w, dims.h) catch return false;
    return pixel_count <= max_cover_pixels;
}

fn decodeCoverBody(gpa: Allocator, body: []const u8) !cover_mod.Pixels {
    const dims = cover_mod.probeDimensions(body) orelse return error.DecodeFailed;
    if (!coverDimsWithinCap(dims)) return error.DecodeFailed;
    return cover_mod.decodeRgba(gpa, body);
}

/// Insert raw into LRU under lock; takes ownership of `bytes` (ROD-243).
fn insertRaw(gpa: Allocator, io: std.Io, caches: *CoverCaches, url: []const u8, bytes: []u8) void {
    caches.mu.lockUncancelable(io);
    defer caches.mu.unlock(io);
    const cached = caches.raw.putOwnedBounded(gpa, url, bytes, max_cover_raw_cache_bytes) catch false;
    if (!cached) gpa.free(bytes);
}

/// Store decoded in LRU; return independent owned copy. Clone under same lock as insert:
/// after put accepts, `decoded.rgba` is cache-owned; unlocked dupe races evict (ROD-243).
/// Decline hands `decoded` back; OOM after insert leaves cache owning pixels (no double-free).
fn storeDecodedAndClone(gpa: Allocator, io: std.Io, caches: *CoverCaches, url: []const u8, decoded: cover_mod.Pixels) !cover_mod.Pixels {
    caches.mu.lockUncancelable(io);
    defer caches.mu.unlock(io);
    const cached = caches.decoded.putOwnedBounded(gpa, url, decoded, max_cover_decoded_cache_bytes) catch false;
    if (!cached) return decoded; // declined: caller keeps owned pixels
    const rgba = try gpa.dupe(u8, decoded.rgba); // under lock: decoded now cache-owned
    return .{ .rgba = rgba, .w = decoded.w, .h = decoded.h };
}

/// Cover fetch deadline (s): connect+headers+body (ROD-265). Same class as long-tail GET
/// (ROD-153). Silent host would hang the worker and pin `discover_cover_drain` forever.
const cover_fetch_deadline_s = 20;

/// Cover GET under `withDeadline` (ROD-265). `CoverRequest` carries absolute URL + optional
/// CDN headers (ROD-267). Owns Client so cancel frees the socket. GPA-owned body; miss →
/// `CoverFetchFailed` (loadCoverPixels also folds Timeout/OOM to miss).
fn fetchCoverBody(gpa: Allocator, io: std.Io, req: source_mod.CoverRequest) ![]u8 {
    // SSRF (ROD-266): untrusted cover refs. No private/loopback/link-local.
    // redirect_behavior=.not_allowed so 3xx cannot bypass.
    fetchguard.guardFetchUrl(req.url) catch |e| {
        log.debug("cover fetch blocked by SSRF guard: {s}", .{@errorName(e)});
        return error.CoverFetchFailed;
    };

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const resp_buf = try gpa.alloc(u8, max_cover_encoded_bytes);
    defer gpa.free(resp_buf);
    var resp_writer: std.Io.Writer = .fixed(resp_buf);
    // Accept always; Referer/UA only when provider set them (CDN needs them).
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
        .redirect_behavior = .not_allowed,
        .response_writer = &resp_writer,
        .headers = if (req.user_agent) |ua| .{ .user_agent = .{ .override = ua } } else .{},
        .extra_headers = extra[0..extra_len],
    }) catch |e| {
        // Deadline cancel, oversize body, network.
        log.debug("cover fetch failed: {s}", .{@errorName(e)});
        return error.CoverFetchFailed;
    };
    if (res.status != .ok) {
        log.debug("cover fetch HTTP {d}", .{@intFromEnum(res.status)});
        return error.CoverFetchFailed;
    }
    return gpa.dupe(u8, resp_writer.buffered());
}

/// Shared cover load (ROD-243): `url` → gpa-owned independent pixels via cache → disk →
/// network. Returned rgba is never cache-owned (safe past eviction). Concurrent-safe under
/// CoverCaches lock discipline.
///
/// `url` is the cache key at every layer. Only the network branch resolves via
/// `provider.coverRequest` so CDN host rotation does not bust cache (ROD-267).
pub fn loadCoverPixels(gpa: Allocator, io: std.Io, provider: SourceProvider, url: []const u8, caches: *CoverCaches) !cover_mod.Pixels {
    // 1) Decoded hit: dupe under lock (get promotes = writer).
    {
        caches.mu.lockUncancelable(io);
        defer caches.mu.unlock(io);
        if (caches.decoded.get(url)) |d| {
            const rgba = try gpa.dupe(u8, d.rgba);
            return .{ .rgba = rgba, .w = d.w, .h = d.h };
        }
    }

    // 2) Raw hit: copy under lock, decode unlocked.
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

    // 3) Disk before network (ROD-171). Hit warms both in-memory caches.
    if (readCoverDisk(gpa, io, url)) |disk_body| {
        if (decodeCoverBody(gpa, disk_body)) |decoded| {
            insertRaw(gpa, io, caches, url, disk_body); // takes ownership of disk_body
            return storeDecodedAndClone(gpa, io, caches, url, decoded);
        } else |e| {
            // Corrupt/truncated: drop and refetch.
            log.debug("cover disk-cache decode failed: {s}", .{@errorName(e)});
            gpa.free(disk_body);
        }
    }

    // 4) Network (unlocked, deadline-bounded ROD-265), warm caches, persist (ROD-171).
    // Provider resolves relative url + CDN headers (ROD-267).
    const req = provider.coverRequest(gpa, url) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CoverFetchFailed, // bad/blocked ref → miss
    };
    defer gpa.free(req.url);
    const body = deadline.withDeadline(io, .fromSeconds(cover_fetch_deadline_s), fetchCoverBody, .{ gpa, io, req }) catch |e| {
        if (e == error.Timeout)
            log.debug("cover fetch {s}: aborted past {d}s deadline", .{ url, cover_fetch_deadline_s });
        return error.CoverFetchFailed;
    };
    defer gpa.free(body);
    const decoded = try decodeCoverBody(gpa, body);
    writeCoverDisk(gpa, io, url, body); // ROD-171: next cold start
    if (gpa.dupe(u8, body)) |raw_copy| {
        insertRaw(gpa, io, caches, url, raw_copy);
    } else |_| {}
    return storeDecodedAndClone(gpa, io, caches, url, decoded);
}

/// Load one cover for UI. `url` freed here; `for_id` transfers on post. Pixels independent
/// of cache (ROD-243).
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

/// One Discover-grid cover (ROD-240). `url` transfers on post; free only if post fails.
/// `drain.finish()` last so teardown cannot unblock while we touch loop/gpa (ROD-179).
/// Fan-out capped via `drain.inflight` at spawn; per-frame pump avoids scrolled-off cards.
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

/// Heartbeat: `.tick` every 100ms until `quit`.
pub fn tickTask(loop: *Loop, io: std.Io, quit: *std.atomic.Value(bool)) void {
    while (!quit.load(.acquire)) {
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
        // Failed post = queue closing.
        loop.postEvent(.tick) catch {};
    }
}

/// Wall-clock ms since Unix epoch.
pub fn nowMs(io: std.Io) i64 {
    const ts = std.Io.Clock.real.now(io);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_ms));
}

/// Boot update check (ROD-370): if behind latest release, post `.update_available`.
/// Best-effort; arena-local so nothing crosses the worker→UI seam.
pub fn updateCheckTask(loop: *Loop, gpa: Allocator, io: std.Io, current_version: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    if (updatecheck.check(arena.allocator(), io, current_version, Store.nowSecs()) == null) return;
    loop.postEvent(.update_available) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
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

test "coverDimsWithinCap admits real covers, refuses over-cap on either axis (ROD-270)" {
    // Full decoded res to Kitty: undershoot → real art becomes fallback. Largest seen 1635x2247.
    try std.testing.expect(coverDimsWithinCap(.{ .w = 1635, .h = 2247 }));
    try std.testing.expect(coverDimsWithinCap(.{ .w = 1080, .h = 1490 }));
    try std.testing.expect(coverDimsWithinCap(.{ .w = max_cover_dimension, .h = max_cover_dimension }));
    try std.testing.expect(!coverDimsWithinCap(.{ .w = max_cover_dimension + 1, .h = 1 }));
    try std.testing.expect(!coverDimsWithinCap(.{ .w = 1, .h = max_cover_dimension + 1 }));
    try std.testing.expect(!coverDimsWithinCap(.{ .w = 0, .h = 100 }));
    try std.testing.expect(!coverDimsWithinCap(.{ .w = 100, .h = 0 }));
}

test "msToTimespec splits milliseconds into whole seconds and remainder nanos (ROD-294)" {
    // Units slip here mis-scales quit_poll_ms.
    const a = msToTimespec(5);
    try std.testing.expectEqual(@as(@TypeOf(a.sec), 0), a.sec);
    try std.testing.expectEqual(@as(@TypeOf(a.nsec), 5_000_000), a.nsec);
    const b = msToTimespec(2000);
    try std.testing.expectEqual(@as(@TypeOf(b.sec), 2), b.sec);
    try std.testing.expectEqual(@as(@TypeOf(b.nsec), 0), b.nsec);
    const c = msToTimespec(2345);
    try std.testing.expectEqual(@as(@TypeOf(c.sec), 2), c.sec);
    try std.testing.expectEqual(@as(@TypeOf(c.nsec), 345_000_000), c.nsec);
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
    // Gate workers in flight so drain is not a no-op race.
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
            drain.finish(); // spawn failed: rebalance like the real call site
            continue;
        };
        t.detach(); // drain() is the only sync
        spawned += 1;
    }

    // begin before spawn: inflight == spawned, workers still on the gate.
    try std.testing.expectEqual(spawned, drain.inflight.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), completed.load(.acquire));

    release.store(true, .release);
    drain.drain();

    // drain returned ⇒ all finish() happened (release/acquire with completed).
    try std.testing.expectEqual(spawned, completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), drain.inflight.load(.acquire));
}

test "preferCover: absolute beats relative, never downgrades or churns (ROD-267)" {
    try std.testing.expect(preferCover(null, "mcovers/x.webp"));
    try std.testing.expect(preferCover(null, "https://s4.anilist.co/x.jpg"));
    try std.testing.expect(preferCover("mcovers/x.webp", "https://s4.anilist.co/x.jpg"));
    try std.testing.expect(!preferCover("https://s4.anilist.co/x.jpg", "mcovers/x.webp"));
    try std.testing.expect(!preferCover("https://a/x.jpg", "https://b/y.jpg"));
    try std.testing.expect(!preferCover("mcovers/x.webp", "mcovers/y.png"));
    try std.testing.expect(!preferCover("mcovers/x.webp", null));
    try std.testing.expect(!preferCover(null, null));
}

test "playAttemptRetryable: only an unplayed open-failure with budget left retries (ROD-309)" {
    try std.testing.expect(playAttemptRetryable(error.MpvOpenFailed, 0, false));
    try std.testing.expect(playAttemptRetryable(error.MpvOpenFailed, 1, false));
    try std.testing.expect(!playAttemptRetryable(error.MpvOpenFailed, MAX_PLAY_ATTEMPTS - 1, false));
    try std.testing.expect(!playAttemptRetryable(error.MpvOpenFailed, 0, true));
    try std.testing.expect(!playAttemptRetryable(error.MpvFailed, 0, false));
    try std.testing.expect(!playAttemptRetryable(error.MpvNotFound, 0, false));
    try std.testing.expectEqual(MAX_PLAY_ATTEMPTS - 1, RETRY_BACKOFFS_MS.len);
}

// ROD-342: resolveViaSearch control flow with stub provider.

/// In-process SourceProvider for resolveViaSearch tests (no network).
const StubCatalog = struct {
    romaji: []const Anime = &.{},
    english: []const Anime = &.{},
    /// Episode probe succeeds only for this id; others empty.
    alive_id: []const u8 = "",
    /// Search-call count (redundant-pass skip).
    searches: u32 = 0,
    catalog_name: []const u8 = "stub",
    /// Transport knobs (ROD-347).
    search_fails: bool = false,
    episodes_fail: bool = false,
    /// Tier-A knobs (ROD-366): canon key; search_unsupported = megaplay shape.
    canon_key: ?[]const u8 = null,
    search_unsupported: bool = false,

    fn provider(self: *StubCatalog) SourceProvider {
        return .{ .ptr = self, .vtable = &stub_vtable };
    }
    const stub_vtable: source_mod.SourceProvider.VTable = .{
        .name = stubName,
        .displayName = stubName,
        .search = stubSearch,
        .canonicalKey = stubCanonicalKey,
        .episodes = stubEpisodes,
        .resolve = stubResolve,
        .coverRequest = stubCover,
    };
    fn stubName(ptr: *anyopaque) []const u8 {
        const self: *StubCatalog = @ptrCast(@alignCast(ptr));
        return self.catalog_name;
    }
    fn stubSearch(ptr: *anyopaque, arena: Allocator, _: std.Io, query: []const u8, _: source_mod.SearchOptions) anyerror![]Anime {
        const self: *StubCatalog = @ptrCast(@alignCast(ptr));
        if (self.search_unsupported) return error.Unsupported;
        self.searches += 1;
        if (self.search_fails) return error.NoAnswer;
        const rows: []const Anime = if (std.mem.eql(u8, query, "Romaji Title"))
            self.romaji
        else if (std.mem.eql(u8, query, "English Title"))
            self.english
        else
            &.{};
        return arena.dupe(Anime, rows);
    }
    fn stubCanonicalKey(ptr: *anyopaque, _: Allocator, _: Anime) anyerror!?[]const u8 {
        const self: *StubCatalog = @ptrCast(@alignCast(ptr));
        return self.canon_key;
    }
    fn stubEpisodes(ptr: *anyopaque, arena: Allocator, _: std.Io, show_id: []const u8, _: domain.Translation, _: ?u32) anyerror![]domain.EpisodeNumber {
        const self: *StubCatalog = @ptrCast(@alignCast(ptr));
        if (self.episodes_fail) return error.NoAnswer;
        if (!std.mem.eql(u8, show_id, self.alive_id)) return arena.alloc(domain.EpisodeNumber, 0);
        const eps = try arena.alloc(domain.EpisodeNumber, 1);
        eps[0] = .{ .raw = "1" };
        return eps;
    }
    fn stubResolve(_: *anyopaque, _: Allocator, _: std.Io, _: []const u8, _: domain.EpisodeNumber, _: domain.Translation, _: domain.Quality) anyerror!domain.StreamLink {
        return error.NotImplemented;
    }
    fn stubCover(_: *anyopaque, _: Allocator, _: []const u8) anyerror!source_mod.CoverRequest {
        return error.NotImplemented;
    }
};

test "resolveViaSearch: English retry pass binds when the romaji pass misses (ROD-342)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const canonical: Anime = .{ .id = "154587", .name = "Romaji Title", .english_name = "English Title", .anilist_id = 154587, .mal_id = 52991 };
    var stub = StubCatalog{
        .english = &.{.{ .id = "2454", .name = "English Title", .mal_id = 52991 }},
    };
    const got = resolveViaSearch(arena_state.allocator(), std.testing.io, stub.provider(), canonical, .sub, true, null);
    try std.testing.expectEqualStrings("2454", got.match);
}

test "resolveViaSearch: a dead pass-1 listing falls through to pass 2 on the Add probe" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // Pass 1 matches empty-probe listing; pass 2 must still run.
    const canonical: Anime = .{ .id = "1", .name = "Romaji Title", .english_name = "English Title", .anilist_id = 1, .mal_id = 52991 };
    var stub = StubCatalog{
        .romaji = &.{.{ .id = "dead", .name = "Romaji Title", .mal_id = 52991 }},
        .english = &.{.{ .id = "alive", .name = "English Title", .mal_id = 52991 }},
        .alive_id = "alive",
    };
    const got = resolveViaSearch(arena_state.allocator(), std.testing.io, stub.provider(), canonical, .sub, false, null);
    try std.testing.expectEqualStrings("alive", got.match);

    // Both dead → clean .absent (catalog fact, not transport).
    stub.alive_id = "";
    try std.testing.expect(resolveViaSearch(arena_state.allocator(), std.testing.io, stub.provider(), canonical, .sub, false, null) == .absent);
}

test "resolveViaSearch: Play skips the probe; identical English title skips pass 2" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // for_play: probe-dead listing still resolves; confirmation is downstream fetch.
    const canonical: Anime = .{ .id = "1", .name = "Romaji Title", .english_name = "English Title", .anilist_id = 1, .mal_id = 52991 };
    var stub = StubCatalog{
        .romaji = &.{.{ .id = "dead", .name = "Romaji Title", .mal_id = 52991 }},
    };
    const got = resolveViaSearch(arena_state.allocator(), std.testing.io, stub.provider(), canonical, .sub, true, null);
    try std.testing.expectEqualStrings("dead", got.match);
    try std.testing.expectEqual(@as(u32, 1), stub.searches); // pass-1 hit → no pass 2

    // english_name == name: no redundant second search.
    const same_title: Anime = .{ .id = "2", .name = "No Such Show", .english_name = "No Such Show", .anilist_id = 2 };
    var stub2 = StubCatalog{};
    try std.testing.expect(resolveViaSearch(arena_state.allocator(), std.testing.io, stub2.provider(), same_title, .sub, true, null) == .absent);
    try std.testing.expectEqual(@as(u32, 1), stub2.searches);
}

test "resolveViaSearch three-state: transport failures read unknown, never absent (ROD-347)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const canonical: Anime = .{ .id = "1", .name = "Romaji Title", .english_name = "English Title", .anilist_id = 1, .mal_id = 52991 };

    // Failed search proves nothing (ROD-278): must not cache absent for a whole TTL.
    var down = StubCatalog{ .search_fails = true };
    try std.testing.expect(resolveViaSearch(arena_state.allocator(), std.testing.io, down.provider(), canonical, .sub, true, null) == .unknown);

    // Matched listing, Add probe transport-fails: taints walk even if later pass clean-misses.
    var flaky = StubCatalog{
        .romaji = &.{.{ .id = "2454", .name = "Romaji Title", .mal_id = 52991 }},
        .episodes_fail = true,
    };
    try std.testing.expect(resolveViaSearch(arena_state.allocator(), std.testing.io, flaky.provider(), canonical, .sub, false, null) == .unknown);

    // No usable titles → learned nothing: unknown.
    const untitled: Anime = .{ .id = "3", .name = "", .anilist_id = 3 };
    var idle = StubCatalog{};
    try std.testing.expect(resolveViaSearch(arena_state.allocator(), std.testing.io, idle.provider(), untitled, .sub, true, null) == .unknown);
    try std.testing.expectEqual(@as(u32, 0), idle.searches);
}

test "resolveViaSearch tier-A: a tier-A-only provider (no search) is reachable off the canonical key (ROD-366)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const canonical: Anime = .{ .id = "1", .name = "Romaji Title", .english_name = "English Title", .anilist_id = 1, .mal_id = 52991 };

    // megaplay shape: canon key + Unsupported search → bind via tier-A.
    var mega = StubCatalog{ .canon_key = "66624", .alive_id = "66624", .search_unsupported = true };
    const hit = resolveViaSearch(arena_state.allocator(), std.testing.io, mega.provider(), canonical, .sub, false, null);
    try std.testing.expectEqualStrings("66624", hit.match);
    try std.testing.expectEqual(@as(u32, 0), mega.searches);

    // Empty tier-A + Unsupported search must stay .absent (ROD-347), not .unknown.
    var mega_miss = StubCatalog{ .canon_key = "404", .alive_id = "", .search_unsupported = true };
    try std.testing.expect(resolveViaSearch(arena_state.allocator(), std.testing.io, mega_miss.provider(), canonical, .sub, false, null) == .absent);

    // No key + Unsupported search: .unknown so a later mal_id is not blocked by cached absent.
    const no_mal: Anime = .{ .id = "2", .name = "Romaji Title", .anilist_id = 2 };
    var mega_nokey = StubCatalog{ .search_unsupported = true };
    try std.testing.expect(resolveViaSearch(arena_state.allocator(), std.testing.io, mega_nokey.provider(), no_mal, .sub, false, null) == .unknown);

    // Play: tier-A key resolves without episode probe.
    var mega_play = StubCatalog{ .canon_key = "66624", .alive_id = "", .search_unsupported = true };
    const played = resolveViaSearch(arena_state.allocator(), std.testing.io, mega_play.provider(), canonical, .sub, true, null);
    try std.testing.expectEqualStrings("66624", played.match);

    // Tier-A transport fail + clean empty search → still .unknown (ROD-278/347).
    var mega_flaky = StubCatalog{ .canon_key = "66624", .episodes_fail = true };
    try std.testing.expect(resolveViaSearch(arena_state.allocator(), std.testing.io, mega_flaky.provider(), canonical, .sub, false, null) == .unknown);
    try std.testing.expect(mega_flaky.searches > 0);
}

test "resolveViaSearch tier-A: an empty tier-A probe still falls through to a title search (ROD-366)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // Dual-capability: empty tier-A must not skip title search that finds a different id.
    const canonical: Anime = .{ .id = "1", .name = "Romaji Title", .english_name = "English Title", .anilist_id = 1, .mal_id = 52991 };
    var senshi = StubCatalog{
        .canon_key = "52991",
        .romaji = &.{.{ .id = "found", .name = "Romaji Title", .mal_id = 52991 }},
        .alive_id = "found",
    };
    const got = resolveViaSearch(arena_state.allocator(), std.testing.io, senshi.provider(), canonical, .sub, false, null);
    try std.testing.expectEqualStrings("found", got.match);
    try std.testing.expect(senshi.searches > 0);
}

test "prewarmTask: a dual-capability empty tier-A falls through to search, no false absence (ROD-367)" {
    const gpa = std.testing.allocator;
    // Empty tier-A alone must not post false .absent (strands flip); resolveViaSearch fallthrough.
    var senshi = StubCatalog{
        .canon_key = "52991",
        .romaji = &.{.{ .id = "found", .name = "Romaji Title", .mal_id = 52991 }},
        .alive_id = "found",
    };
    // prewarmTask frees providers + canonical.
    const providers = try gpa.dupe(SourceProvider, &.{senshi.provider()});
    const canonical = try dupeOwnedAnime(gpa, .{ .id = "1", .name = "Romaji Title", .english_name = "English Title", .anilist_id = 1, .mal_id = 52991 });

    var loop = Loop{ .io = std.testing.io, .tty = undefined, .vaxis = undefined, .queue = .{ .io = std.testing.io } };
    var cancel = std.atomic.Value(bool).init(false);
    var drain = ThreadDrain{};
    drain.begin();

    // One provider: no inter-provider sleep (i > 0); posts synchronously.
    prewarmTask(&loop, gpa, std.testing.io, providers, canonical, 154587, .sub, &cancel, &drain);

    var saw_match = false;
    while (loop.queue.tryPop() catch null) |ev| {
        switch (ev) {
            .prewarm_result => |r| {
                try std.testing.expect(!r.absent);
                try std.testing.expectEqualStrings("found", r.source_id);
                saw_match = true;
                if (r.source_id.len > 0) gpa.free(r.source_id);
            },
            else => {},
        }
    }
    try std.testing.expect(saw_match);
}

test "resolveAcrossProviders: walks registry order, first confident match wins (ROD-343)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const canonical: Anime = .{ .id = "154587", .name = "Romaji Title", .anilist_id = 154587, .mal_id = 52991 };

    // Miss then hit: bind under second provider; first clean miss → absent_out.
    var miss = StubCatalog{ .catalog_name = "alpha" };
    var hit = StubCatalog{ .catalog_name = "beta", .romaji = &.{.{ .id = "2454", .name = "Romaji Title", .mal_id = 52991 }} };
    var absent: std.ArrayListUnmanaged([]const u8) = .empty;
    const walked = resolveAcrossProviders(arena, std.testing.io, &.{ miss.provider(), hit.provider() }, canonical, .sub, true, &absent) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("2454", walked.id);
    try std.testing.expectEqualStrings("beta", walked.source);
    try std.testing.expectEqual(@as(usize, 1), absent.items.len);
    try std.testing.expectEqualStrings("alpha", absent.items[0]);

    // Tie: first in order wins; runner-up never searched.
    var hit_first = StubCatalog{ .catalog_name = "alpha", .romaji = &.{.{ .id = "1111", .name = "Romaji Title", .mal_id = 52991 }} };
    var hit_second = StubCatalog{ .catalog_name = "beta", .romaji = &.{.{ .id = "2222", .name = "Romaji Title", .mal_id = 52991 }} };
    var absent_tie: std.ArrayListUnmanaged([]const u8) = .empty;
    const tie = resolveAcrossProviders(arena, std.testing.io, &.{ hit_first.provider(), hit_second.provider() }, canonical, .sub, true, &absent_tie) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("1111", tie.id);
    try std.testing.expectEqualStrings("alpha", tie.source);
    try std.testing.expectEqual(@as(usize, 0), absent_tie.items.len);

    // All miss: only clean absences collected; transport-dead stays unknown (ROD-347).
    var m1 = StubCatalog{ .catalog_name = "alpha" };
    var m2 = StubCatalog{ .catalog_name = "beta", .search_fails = true };
    var absent_miss: std.ArrayListUnmanaged([]const u8) = .empty;
    try std.testing.expect(resolveAcrossProviders(arena, std.testing.io, &.{ m1.provider(), m2.provider() }, canonical, .sub, true, &absent_miss) == null);
    try std.testing.expect(m1.searches > 0 and m2.searches > 0);
    try std.testing.expectEqual(@as(usize, 1), absent_miss.items.len);
    try std.testing.expectEqualStrings("alpha", absent_miss.items[0]);
}
