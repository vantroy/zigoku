//! Zigoku — TUI background workers and shared ownership helpers.

const std = @import("std");
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
const event_mod = @import("event.zig");
const log = @import("../log.zig");
const sync = @import("../sync.zig");
const auth_mod = @import("../auth.zig");
const login_loopback = @import("../login_loopback.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const SourceProvider = source_mod.SourceProvider;
const Anime = domain.Anime;
const Loop = event_mod.Loop;

/// Fire-and-forget worker accounting (ROD-179): spawn a background worker without
/// synchronously joining a prior one. The superseded worker is detached and runs to
/// completion on its own (its stale result is keep-checked and dropped on arrival),
/// while a teardown barrier still guarantees every outstanding worker finished before
/// the shared state it borrows (the event loop, the gpa, the io) is torn down.
///
/// Contract:
///   - `begin()` on the spawning thread immediately BEFORE each spawn, so the count is
///     raised before the new thread can start. On spawn failure, pair with `finish()`.
///   - the worker calls `finish()` as its last action (via `defer`), after its final
///     `postEvent` returns, so once `drain()` unblocks no worker can still touch the
///     loop/gpa/io.
///   - `drain()` once, on teardown: blocks until every begun worker finished.
///
/// Just an atomic counter: this std's `Thread` is spawn/join/detach/yield only (the
/// blocking primitives moved to `std.Io`), so `begin`/`finish` are lock-free fetch
/// add/sub and `drain()` spins with `yield()`. It runs once on teardown, never the hot
/// path, and is bounded by the in-flight fetch's deadline (ROD-153).
///
/// Intentionally uncapped: the episode-prefetch debounce (ROD-156) keeps superseding
/// fires rare and each fetch is deadline-bounded, so the outstanding set stays small. A
/// cap would be backpressure policy, not safety, so a caller that wants one (the Discover
/// fan-out) reads `inflight` against its own soft cap at the spawn site (ROD-264) instead
/// of this primitive imposing a global limit.
///
/// `drain()` assumes the event queue keeps draining: a worker's final `postEvent` blocks
/// if the bounded queue is full, and during teardown the main loop has stopped popping,
/// so a saturated queue could wedge the drain. A pre-existing low-probability teardown
/// hazard shared by every worker join in run(); pumping the queue while draining is a
/// separate follow-up.
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
/// single-cover path and the Discover grid fetch against the SAME URL-keyed LRUs, so a
/// cover fetched in Browse is reused by Discover for free.
///
/// The mutex is what makes these caches safe under N concurrent cover workers; before
/// ROD-243 safety came only from `cover_state.zig` joining the prior thread before
/// spawning the next, and the grid breaks that.
///
/// Lock discipline (in `loadCoverPixels`): every dupe of a slice that lives in or was
/// just inserted into a cache happens while `mu` is held; `decodeCoverBody` and the
/// network fetch run UNLOCKED so a slow decode never stalls another worker. `LruCache.get`
/// is itself a writer (it promotes the hit), so even a pure lookup must hold the lock.
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

/// Whether to replace a card's current cover `cur` with an enriched `inc`: adopt
/// when there's no cover yet, or when `cur` is only a relative ref and `inc` is a
/// fetchable absolute url (ROD-267). Never downgrades an absolute url to a relative
/// one, and never swaps one absolute for another (no churn for equal quality).
fn preferCover(cur: ?[]const u8, inc: ?[]const u8) bool {
    const incoming = inc orelse return false;
    const current = cur orelse return true;
    return !domain.isAbsoluteUrl(current) and domain.isAbsoluteUrl(incoming);
}

/// Background task: run a discovery search on AniList (ROD-327) and post the results to
/// the UI thread. Discovery search is OFF the `SourceProvider` vtable (ROD-324): it
/// queries AniList directly, so hits are anilist_id-keyed canonical rows, not provider
/// bindings. Binding a hit to a play provider is the resolver's job (the Play/Add
/// tier-A path), never this fetch.
pub fn searchTask(loop: *Loop, gpa: Allocator, io: std.Io, query: []const u8, page: u32) void {
    // NOTE: `query` ownership is transferred to the `search_done` event's `for_query`
    // on the success path; the UI thread frees it there. On all error paths we free it
    // here explicitly before returning. Do NOT add a defer — it would free the string
    // before the UI thread reads `ev.for_query`, causing a use-after-free.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const raw = anilist.search(arena.allocator(), io, query, page) catch |e| {
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

/// Background task: tier-A resolve for add-to-watchlist (ROD-327). A Browse search hit
/// is anilist_id-keyed; the play provider keys by the stringified mal_id (`candidate_id`).
/// Probes `provider.episodes(candidate_id)`: a non-empty list means the provider stocks
/// the show, so the UI thread can mint the binding. A transport failure and an empty list
/// both collapse to `ok = false`; the UI thread turns that miss into the explicit unbound
/// marker (ROD-329, add path), so this worker writes no state itself.
///
/// `candidate_id` ownership transfers to the `resolve_add_result` event on a successful
/// post (the UI thread frees it on either arm); freed here only if the post fails.
/// `drain.finish()` runs last (mirrors `episodesTask`) so a drained barrier means this
/// worker can no longer touch loop/gpa.
pub fn resolveAddTask(loop: *Loop, gpa: Allocator, io: std.Io, provider: SourceProvider, candidate_id: []const u8, anilist_id: i64, translation: domain.Translation, drain: *ThreadDrain) void {
    defer drain.finish();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const ok = if (provider.episodes(arena.allocator(), io, candidate_id, translation)) |eps|
        eps.len > 0
    else |e| blk: {
        log.debug("resolve-add probe failed: {s}", .{@errorName(e)});
        break :blk false;
    };

    loop.postEvent(.{ .resolve_add_result = .{
        .ok = ok,
        .anilist_id = anilist_id,
        .source_id = candidate_id,
        .source = provider.name(),
    } }) catch |pe| {
        log.debug("postEvent failed: {s}", .{@errorName(pe)});
        gpa.free(candidate_id);
    };
}

/// Background task: search-then-match binding resolve (ROD-328/342). A Browse search hit
/// that could not tier-A anywhere is resolved by walking `providers` in effective order
/// (ROD-343/344: the caller's `Registry.orderedAlloc` snapshot, preference first; first
/// confident match wins and the posted event carries the winner's name). `providers` is
/// gpa-owned by this task and freed here, so a preference change mid-flight can't touch
/// a walk already underway.
/// Per provider: search its OWN catalog and match: tier B first
/// (`resolver.bestIdMatch`: exact canonical-id agreement off ids the provider embedded
/// in its results, e.g. anipub's MALID backfill), then tier C
/// (`resolver.bestProviderMatch`, the STRONG canonical→provider fuzzy direction). Two
/// query passes: the canonical (romaji) title, then the English title, since an
/// English-titled catalog (anipub) misses a romaji query entirely, and a confident
/// match on the first pass skips the second. A confident match yields the provider's
/// opaque id; no match or a failed search both collapse to `ok = false` (the add path
/// then persists the unbound marker, ROD-329; Play just toasts). Add (`for_play` false)
/// then probes `episodes` to confirm the match has playable episodes, the same bar
/// tier-A Add holds; Play skips that probe because its own downstream episode fetch is
/// the confirmation.
///
/// `canonical` is a gpa-owned deep copy (freed here) so it outlives the caller's return
/// (`fireResolvePlaySearch`/`fireResolveAddSearch`). On a hit the matched id is duped into gpa
/// and transferred to the posted event (the UI thread frees it); `for_play` selects
/// `.resolve_play_target` vs `.resolve_add_result`.
/// `drain.finish()` runs last (mirrors `episodesTask`) so a drained barrier means this
/// worker can no longer touch loop/gpa.
pub fn resolveSearchTask(loop: *Loop, gpa: Allocator, io: std.Io, providers: []const SourceProvider, canonical: Anime, anilist_id: i64, translation: domain.Translation, for_play: bool, drain: *ThreadDrain) void {
    defer drain.finish();
    defer gpa.free(providers);
    defer freeOwnedAnime(gpa, canonical);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const match = resolveAcrossProviders(arena.allocator(), io, providers, canonical, translation, for_play);
    const resolved: ?[]const u8 = if (match) |m| gpa.dupe(u8, m.id) catch null else null;

    const ok = resolved != null;
    const source_id: []const u8 = resolved orelse &.{};
    const source: []const u8 = if (ok) match.?.source else &.{};
    const posted = if (for_play)
        loop.postEvent(.{ .resolve_play_target = .{ .ok = ok, .anilist_id = anilist_id, .source_id = source_id, .source = source } })
    else
        loop.postEvent(.{ .resolve_add_result = .{ .ok = ok, .anilist_id = anilist_id, .source_id = source_id, .source = source } });
    posted catch |pe| {
        log.debug("postEvent failed: {s}", .{@errorName(pe)});
        if (resolved) |r| gpa.free(r);
    };
}

/// A settled cross-provider search resolve: the matched catalog id and the name of
/// the provider that produced it (a static vtable string).
const SearchMatch = struct { id: []const u8, source: []const u8 };

/// Walk the registry order through `resolveViaSearch`, first confident match wins
/// (ROD-343): each provider gets its full two-pass search before the next is tried,
/// so a strong first-provider match is never preempted by a weaker later one, and
/// requests stay sequential (one provider at a time, the ROD-309 discipline).
fn resolveAcrossProviders(arena: Allocator, io: std.Io, providers: []const SourceProvider, canonical: Anime, translation: domain.Translation, for_play: bool) ?SearchMatch {
    for (providers) |p| {
        if (resolveViaSearch(arena, io, p, canonical, translation, for_play)) |id|
            return .{ .id = id, .source = p.name() };
    }
    return null;
}

/// The search→match→probe core of `resolveSearchTask`, split from the thread/event
/// glue so the pass control flow is unit-testable with a stub provider. Returns the
/// matched provider id (borrowing from `arena` via the provider's results) or null.
fn resolveViaSearch(arena: Allocator, io: std.Io, provider: SourceProvider, canonical: Anime, translation: domain.Translation, for_play: bool) ?[]const u8 {
    const opts: source_mod.SearchOptions = .{
        .translation = translation,
        .limit = source_mod.search_page_size,
        .page = 1,
    };
    const passes = [_]?[]const u8{ canonical.name, canonical.english_name };
    for (passes, 0..) |pass, pi| {
        const query = pass orelse continue;
        if (query.len == 0) continue;
        // Skip a redundant second search when the English title IS the name.
        if (pi == 1 and std.mem.eql(u8, query, canonical.name)) continue;
        const results = provider.search(arena, io, query, opts) catch |e| {
            log.debug("resolve-search failed: {s}", .{@errorName(e)});
            continue;
        };
        const idx = resolver.bestIdMatch(canonical, results) orelse
            resolver.bestProviderMatch(canonical, results) orelse continue;
        const matched_id = results[idx].id;
        // Add confirms the match actually has playable episodes (parity with tier-A's
        // resolveAddTask): a catalog listing can be announced-but-empty. Play skips this, since
        // its own downstream episode fetch is the confirmation. Sequential after the search, so
        // still one provider request at a time (ROD-309). A failed or empty probe falls
        // through to the next pass (bounded at 2): a dead listing on one title must not
        // also deny the other title's legitimate match.
        if (!for_play) {
            const eps = provider.episodes(arena, io, matched_id, translation) catch |e| {
                log.debug("resolve-search episode probe failed: {s}", .{@errorName(e)});
                continue;
            };
            if (eps.len == 0) continue;
        }
        return matched_id;
    }
    return null;
}

/// Background task: fetch one Discover feed page for `axis` from AniList (ROD-336).
/// Off the vtable like `searchTask` (ROD-324): rows are anilist_id-keyed canonical
/// entities, fully enriched (full GQL_FIELDS), so no follow-up enrich pass exists.
/// Mirrors searchTask's ownership shape — dupes every owned string into gpa so the
/// event payload outlives the worker's arena; the UI thread frees `results` via the
/// `.discover_feed` arm. `now_ms` anchors the This Season cour. Three-state (ROD-278):
/// a transport miss (error.NoAnswer) posts `.discover_feed_error`; an empty page is a
/// confirmed answer and posts normally.
pub fn discoverFeedTask(loop: *Loop, gpa: Allocator, io: std.Io, axis: anilist.DiscoverAxis, page: u32, now_ms: i64, drain: *ThreadDrain) void {
    defer drain.finish(); // ROD-251: detached; account so teardown can drain us
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const feed = anilist.discover(arena.allocator(), io, axis, page, now_ms) catch |e| {
        log.debug("discover feed failed: {s}", .{@errorName(e)});
        loop.postEvent(.{ .discover_feed_error = .{ .axis = axis, .cause = e } }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };

    // Dupe every owned string we thread into the UI so arena teardown cannot leave
    // dangling references in the event payload (mirrors searchTask).
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

    // toOwnedSlice resizes to exact fit (len == capacity) so gpa.free is valid on
    // either path below (see searchTask for the over-allocation rationale).
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
        gpa.free(exact); // exact-fit: len == capacity, free is valid
    };
}

/// Fill an Anime's blank fields from AniList metadata — AllAnime is the source of
/// truth, so only nulls are filled. Each string/slice deep-copies into `gpa`
/// before the arena `meta` came from is torn down; a failed copy keeps the prior
/// (blank) value rather than aliasing the soon-dead arena. Shared by the
/// search-page enrich and the ROD-182 refresh-on-view.
pub fn applyMetadata(gpa: Allocator, a: *Anime, meta: anilist.Metadata) void {
    if (a.english_name == null) a.english_name = dupeOptText(gpa, meta.title_english) catch a.english_name;
    // ROD-312: stash true romaji alongside the provider `name` (never overwritten
    // here — see title_romaji's doc), so the canonical write can heal canonical.title.
    if (a.title_romaji == null) a.title_romaji = dupeOptText(gpa, meta.title_romaji) catch a.title_romaji;
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
    if (a.source_material == null) a.source_material = dupeOptText(gpa, meta.source_material) catch a.source_material;
    if (a.rank == null) a.rank = meta.rank;
    if (a.rank_type == null) a.rank_type = dupeOptText(gpa, meta.rank_type) catch a.rank_type;
    if (a.rank_year == null) a.rank_year = meta.rank_year;
    if (a.next_airing_at == null) a.next_airing_at = meta.next_airing_at;
    if (a.next_airing_episode == null) a.next_airing_episode = meta.next_airing_episode;
    if (a.country == null) a.country = dupeOptText(gpa, meta.country) catch a.country;
}

/// Fill the null fields of an in-memory `Anime` from a stored `AnimeRecord`, taking
/// gpa-owned copies so they ride `freeOwnedAnime`. The record->Anime sibling of
/// `applyMetadata`: both back-fill only nulls, so a stored value never clobbers a fresher
/// one already on the row. Pure. Shared by the search-page and Discover-feed hydrates
/// (ROD-268), so a card whose provider thumb carries no mineable AniList id still
/// enriches by the id a past match stored.
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
    if (a.source_material == null) a.source_material = dupeOptText(gpa, rec.source_material) catch a.source_material;
    if (a.rank == null) a.rank = if (rec.rank) |x| std.math.cast(u32, x) else null;
    if (a.rank_type == null) a.rank_type = dupeOptText(gpa, rec.rank_type) catch a.rank_type;
    if (a.rank_year == null) a.rank_year = if (rec.rank_year) |x| std.math.cast(u32, x) else null;
    if (a.next_airing_at == null) a.next_airing_at = rec.next_airing_at;
    if (a.next_airing_episode == null) a.next_airing_episode = if (rec.next_airing_episode) |x| std.math.cast(u32, x) else null;
    if (a.country == null) a.country = dupeOptText(gpa, rec.country) catch a.country;
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

/// ROD-182 refresh-on-view: a show was opened and its persisted enrichment read stale, so
/// re-pull AniList metadata and post it for the UI thread to persist + reload. `stub` is a
/// gpa-owned identity record (id/name/english_name/anilist_id) blank beyond identity, so
/// `applyMetadata`'s fill-if-null fills every field from `meta` and the upsert COALESCE
/// overwrites stored content with the fresh values: a content refresh with no in-memory
/// merge. `stub`/`source` are gpa-owned; ownership transfers to the `enrichment_refreshed`
/// event, or both are freed here on a post failure.
///
/// Miss contract (ROD-278): a CONFIRMED no-match posts `stub` unchanged with
/// `answered = true`, and the handler stamps it fresh (a negative cache that stops
/// re-hammering AniList until the TTL lapses). A transport failure (no answer reached)
/// posts `answered = false`, and the handler skips the stamp so the next view retries
/// instead of burning the freshness clock.
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

/// Background task: reconcile with AniList then flush local changes up (ROD-291). Armed by
/// a debounce on a local mutation; .tick spawns it off the render thread when the debounce
/// elapses. Runs PULL-THEN-PUSH, the same order as the CLI `zigoku sync`: `pullAll`
/// reconciles first (3-way merge, progress = max) so a value that moved further ahead on
/// another surface is adopted locally before the push, instead of the push blind-lowering
/// it (the ROD-285 pull-before-push discipline, now on the action path too). Both engines
/// are total (every outcome lands in a summary, never an error). The push is skipped only
/// when the pull already hit a wall the push would too (401 / 429 / store error).
///
/// `pull_only` (ROD-293) suppresses the push: the launch pull-refresh runs one
/// `MediaListCollection` round trip to adopt other-device edits but leaves the paced push
/// to the action and quit flushes. It rides the same `.sync_flushed` event with
/// `pushed = 0`, so the handler emits no ↑ line, just the ambient `↓ N from AniList`
/// whisper (and a history reload) when the reconcile changed local rows.
///
/// `credentials` is by value (slices live in run()'s session auth arena). `inflight` is
/// cleared in a defer so a failed `postEvent` at quit can't latch the one-flush gate on. A
/// dropped flush self-heals: unpushed rows stay dirty for the next.
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
    // `unmatched_ids` is a CLI-only affordance (print ids for manual lookup); the action
    // path ignores it, so free the gpa-owned slice rather than leak it.
    if (pull.unmatched_ids.len > 0) gpa.free(pull.unmatched_ids);

    // Skip the push when it's a pull-only launch refresh (ROD-293), or when the pull
    // already hit a wall the push would hit too — a rejected token or rate limit apply to
    // both, and an unreadable store fails the same way.
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

/// Poll interval (ms) for `pushOnQuit`'s pool-independent wait — how often it wakes to
/// check whether the push landed (an early exit). Small enough that a fast push exits
/// quit near-instantly; the syscall cost of the (≤ deadline/interval) short sleeps is
/// nothing against a one-time quit. ROD-294.
const quit_poll_ms: u64 = 5;

/// ROD-294: bounded best-effort push on quit, the mirror of the launch pull at the far end
/// of the session. Called synchronously from run()'s fast-exit path, AFTER the terminal is
/// restored and BEFORE `_exit`: if rows are still dirty, land as many as `deadline_ms`
/// allows so a push that failed mid-session (offline, a dropped 429) doesn't wait for the
/// next launch. Posts NO event, a pure store+network call that never touches the loop or
/// tty, so it sidesteps the ROD-179/232 event-queue wedge that retired the graceful drain.
///
/// Runs the push on its OWN thread and bounds the WAIT with a libc-`nanosleep` poll,
/// deliberately NOT `withDeadline`: withDeadline arms its timer on the same `Io` pool the
/// push competes for, so under pool starvation it runs the op inline with NO deadline
/// (deadline.zig), and this sits one line before `_exit`, where an unbounded op on a silent
/// socket is exactly the quit-hang ROD-232 kills. `nanosleep` is a direct libc syscall,
/// independent of the pool, so the quit thread ALWAYS returns by the deadline no matter what
/// the push thread does; a stalled push is abandoned to `_exit` like any ROD-232 worker.
/// Best-effort: whatever doesn't land stays dirty and re-flushes next launch (`sync.pushAll`
/// stamps each row as it lands, so a cut-short run leaves a consistent partial). The caller
/// has already checked we're connected and no sync worker is inflight: the quit push must
/// never run alongside a pull (ROD-285 ordering).
pub fn pushOnQuit(
    gpa: Allocator,
    io: std.Io,
    store: *Store,
    credentials: auth_mod.Auth,
    now_unix: i64,
    deadline_ms: i64,
) void {
    // `done` is heap-allocated and intentionally leaked: `quitPushBody` sets it in a
    // defer that can run AFTER we return (we abandon a slow push), so it must outlive
    // this stack frame — a stack `done` would dangle under the abandoned thread. `_exit`
    // reclaims it moments later, like every other ROD-232 abandoned-worker resource. On
    // spawn failure we're its only owner and free it; on success the (possibly still
    // running) thread is its last writer, so we must not.
    const done = gpa.create(std.atomic.Value(bool)) catch return;
    done.* = .init(false);
    const t = std.Thread.spawn(.{}, quitPushBody, .{ gpa, io, store, credentials, now_unix, done }) catch {
        gpa.destroy(done);
        return;
    };
    // Wait for the push to land, up to the deadline, waking every `quit_poll_ms` for an
    // early exit. Bound on a MONOTONIC WALL CLOCK, not an iteration count: `nanosleep`
    // returns early on any delivered signal, and this process keeps a live SIGWINCH handler
    // through quit (vaxis installs it process-wide, never reset), so a fixed poll count
    // would let a resize storm mid-quit collapse the budget to milliseconds. Re-reading the
    // clock each pass makes a cut-short sleep harmless (just loop and sleep again), so the
    // push gets its full window while quit stays capped.
    //
    // `deadline_ms` is validated, not asserted: a non-positive/oversized value skips the
    // wait rather than trap or wrap (the assert form was compiled out in Release). The
    // multiply saturates so an oversized deadline can't overflow to a garbage budget.
    const ms = std.math.cast(u64, deadline_ms) orelse return;
    const budget_ns: u64 = ms *| std.time.ns_per_ms;
    // A failed clock read returns 0. If the FIRST read failed we cannot wall-clock-bound,
    // so skip the wait outright rather than risk an unbounded loop (`0 -% 0 = 0 < budget`
    // forever) — best-effort degrades to "don't wait," never to "hang." A LATER failure
    // also returns 0, but `0 -% start` wraps huge and ends the loop on the next compare.
    const start = monotonicNs();
    if (start != 0) {
        while (!done.load(.acquire) and monotonicNs() -% start < budget_ns) nanosleepMs(quit_poll_ms);
    }
    // Done or timed out: never join — a starved/stalled push must not block quit. `detach`
    // hands the thread to the runtime; `_exit` reaps it (and the leaked `done`) on our heels.
    t.detach();
}

/// The quit push body (ROD-294), run on its own thread so `pushOnQuit` can bound the WAIT
/// with a pool-independent timer. Sets `done` on every exit path so the caller's poll
/// loop wakes early on the happy path. The dirty pre-check lives here, INSIDE the bounded
/// region, so even a wedged storage layer can't stall it past the deadline; it reuses
/// `pushAll`'s own work-list query so the dirty predicate has one source and can't drift.
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
    // Total (returns `Summary`, never errors). Its own inner per-POST deadline may go
    // unbounded under pool starvation, but the caller's poll loop bounds QUIT regardless,
    // so a stalled push here is just abandoned. Outcome discarded — the render surface is
    // gone; unlanded rows stay dirty and re-flush next launch.
    _ = sync.pushAll(gpa, io, store, credentials, now_unix);
}

/// Pool-independent ~`ms`-millisecond sleep via libc `nanosleep` (the app links libc),
/// used by `pushOnQuit`'s wait loop so the quit bound can't depend on the `Io` thread
/// pool the push is competing for. A signal (EINTR) may cut it short — harmless: the
/// wait loop is bounded by a monotonic clock, not by this sleep completing. ROD-294.
fn nanosleepMs(ms: u64) void {
    var req = msToTimespec(ms);
    _ = std.c.nanosleep(&req, null);
}

/// Split a millisecond count into a `timespec` (whole seconds + remainder nanoseconds).
/// Pure — factored out of `nanosleepMs` so the arithmetic is unit-testable without a real
/// sleep. ROD-294.
fn msToTimespec(ms: u64) std.c.timespec {
    return .{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
}

/// Monotonic clock in nanoseconds via libc `clock_gettime` — the wall-clock reference for
/// `pushOnQuit`'s pool-independent wait bound. CLOCK_MONOTONIC is immune to wall-clock/NTP
/// jumps. Returns 0 as a failure sentinel (near-impossible on a real OS — a vDSO read):
/// `pushOnQuit` treats a first-read 0 as "skip the wait" and a later 0 as "end the wait,"
/// so a clock failure can never hang, only shorten. Saturating arithmetic so an absurd
/// uptime can't overflow to a small value that would truncate the bound. ROD-294.
fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec *| std.time.ns_per_s +| nsec;
}

/// The in-TUI connect worker (ROD-286): run the loopback accept loop off the render
/// thread and post the settled `ConnectOutcome` back for the UI to adopt. `listener`
/// and `cancel` are borrowed (owned by `App.ConnectState`'s boxed arena, freed only
/// after this joins); `arena` is that same connect arena, used for the callback's
/// verify/persist. On `.canceled` — the UI tore the modal down and is joining us — we
/// skip the post entirely: there's nothing to report, and posting into a queue no one
/// is draining (teardown) could wedge the join. Any other outcome is posted best-effort.
pub fn connectTask(
    loop: *Loop,
    io: std.Io,
    listener: *login_loopback.Listener,
    arena: Allocator,
    cancel: *std.atomic.Value(bool),
) void {
    const outcome = login_loopback.awaitConnect(listener, arena, io, cancel);
    switch (outcome) {
        // Torn down by the UI (esc / teardown) — it's joining us; nothing to report,
        // and posting into a queue no one is draining could wedge that join.
        .canceled => {},
        else => loop.postEvent(.{ .connect_result = outcome }) catch |pe|
            log.debug("connect postEvent failed: {s}", .{@errorName(pe)}),
    }
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

/// Total mpv launch attempts per play, including the first (ROD-309). The senshi CDN
/// intermittently 403s the stream open when this IP is in a short Cloudflare penalty
/// window (classically: restarting an episode seconds after a quit). Two retries after
/// the initial try give the window time to clear.
const MAX_PLAY_ATTEMPTS: usize = 3;

/// Backoff before each retry, indexed by the just-failed attempt (0 → before the 2nd
/// try, 1 → before the 3rd). The windows observed were seconds-long, so ~2s then ~4s
/// spans them without stalling a genuinely dead stream too long.
const RETRY_BACKOFFS_MS = [_]u64{ 2000, 4000 };

/// Whether a failed play attempt is worth a re-resolve + relaunch. Retry only when mpv
/// failed to OPEN the stream (its code-2 signal — the CDN's transient 403/expiry) AND
/// nothing ever played (so a mid-episode drop or a normal quit never triggers a restart
/// storm) AND an attempt budget remains. Pure so the gate is testable without spawning mpv.
fn playAttemptRetryable(cause: anyerror, attempt: usize, played: bool) bool {
    return cause == error.MpvOpenFailed and !played and attempt + 1 < MAX_PLAY_ATTEMPTS;
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

    // ROD-83: fetch OP/ED skip data once on this worker thread (never the UI thread);
    // it doesn't change across the re-resolve retries below, so it's hoisted out.
    const skip = aniskip.prepare(arena.allocator(), io, mal_id, title, aniskip.episodeNumber(ep_raw, episode_ordinal), aniskip.SkipMode.fromString(skip_mode));

    var progress: PlaybackProgress = .{};
    var callback_ctx: PlayTaskCallbackCtx = .{ .loop = loop, .progress = &progress };

    // ROD-309 retry loop: re-resolve a FRESH signed URL each attempt (the old one's CDN
    // token is irrelevant once we're in a penalty window; a re-resolve also dodges an
    // expiry) and relaunch after a short backoff on a pre-playback open failure.
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const link = provider.resolve(arena.allocator(), io, id, ep, translation, quality) catch |e| {
            // Always-on top-level receipt (ROD-300): one line per failed play, with
            // the id/ep to correlate against the provider-level lines below it.
            log.err("resolve failed for id={s} ep={s} tt={s}: {s}", .{ id, ep_raw, translation.str(), @errorName(e) });
            loop.postEvent(.{ .play_error = .{ .final = null, .cause = e } }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
            return;
        };

        // Fresh counters per attempt; safe to reset — play() joins its watcher thread
        // before returning, so nothing else touches `progress` here.
        progress = .{};
        player_mod.play(arena.allocator(), io, mpv_path, link, title, start_seconds, .{
            .ctx = @ptrCast(&callback_ctx),
            .func = postPositionUpdate,
        }, skip) catch |e| {
            const played = progress.snapshot() != null;
            if (playAttemptRetryable(e, attempt, played)) {
                const backoff_ms = RETRY_BACKOFFS_MS[attempt];
                log.warn("mpv open failed for id={s} ep={s} (attempt {d}/{d}) — re-resolving in {d}ms", .{ id, ep_raw, attempt + 1, MAX_PLAY_ATTEMPTS, backoff_ms });
                // Surface the wait so the backoff reads as "retrying", not a frozen
                // launch. `attempt` is 0-based, so attempt+1 is this retry's 1-based
                // number and MAX_PLAY_ATTEMPTS-1 the total retries (ROD-309).
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

/// Per-write nonce for the disk-cache temp file (ROD-243). With concurrent cover workers,
/// two threads (or a second app instance) can persist the SAME url at once; a fixed
/// `<path>.tmp` would let them interleave into one temp file and then rename a torn `.jpg`
/// into place. A unique suffix per write gives each writer its own temp sibling, so the
/// atomic rename always promotes a whole file. The thread id keeps it unique across
/// processes too (Linux tids are system-wide). Worst case is a uniquely-named orphan tmp on
/// a hard crash; best-effort cleanup deletes it on every non-crash failure path.
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

/// The actual cover GET, run as a cancelable unit by `withDeadline` (ROD-265). Takes a
/// provider-resolved `CoverRequest` (absolute URL + any CDN headers, ROD-267): some cover
/// CDNs 403 a refererless GET, so Referer/UA ride along when the provider set them. Owns
/// its `std.http.Client` so a deadline cancel unwinds this frame and frees the connection
/// instead of leaving a socket blocked in `recv`. Returns the encoded body as an exact
/// gpa-owned slice (caller frees). Fetch and non-200 failures return `error.CoverFetchFailed`;
/// `loadCoverPixels` collapses that, OOM, and the deadline's `error.Timeout` to a cover miss.
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

/// Shared cover load (ROD-243): resolve `url` to gpa-owned, INDEPENDENT decoded pixels via
/// cache -> disk -> network, or an error. The returned `rgba` is never a cache-owned
/// pointer, so it stays valid past any concurrent eviction (the caller owns it). Safe for
/// concurrent callers: the single-cover worker and the Discover grid share one
/// `CoverCaches`, under its lock discipline (see `CoverCaches`).
///
/// `url` is the raw stored cover ref and the cache key at every layer (memory, disk). Only
/// the network branch resolves it (via `provider.coverRequest`) into the absolute URL
/// actually fetched, so a CDN-host rotation never invalidates the cache and the host stays
/// behind the provider seam (ROD-267).
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

/// Background task: load ONE Discover-grid cover and post it (ROD-240). `url` is gpa-owned
/// by this task; it transfers to the result event (UI thread frees it) on both done and
/// error paths, and is freed here only if the post fails. `drain` bounds the fan-out: the
/// pump caps how many run at once (`config.discoverCoverConcurrency`) by gating spawns on
/// `drain.inflight`, and `finish()` runs as the worker's LAST action so teardown `drain()`
/// can never unblock while a worker might still touch `loop`/`gpa` (ROD-179). N of these
/// plus the single-cover worker may touch `caches` concurrently, safe under its lock. The
/// per-frame pump replaces the old batch worker: each frame tops the in-flight set back to
/// the cap against live slot state, so a fetch is never spent on an already-scrolled-past
/// card.
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

test "msToTimespec splits milliseconds into whole seconds and remainder nanos (ROD-294)" {
    // The quit-push wait sleeps in `quit_poll_ms` increments and uses this to build the
    // libc timespec; a sign/units slip here would mis-scale the poll interval.
    const a = msToTimespec(5); // the poll interval: sub-second
    try std.testing.expectEqual(@as(@TypeOf(a.sec), 0), a.sec);
    try std.testing.expectEqual(@as(@TypeOf(a.nsec), 5_000_000), a.nsec);
    const b = msToTimespec(2000); // exact seconds, zero remainder
    try std.testing.expectEqual(@as(@TypeOf(b.sec), 2), b.sec);
    try std.testing.expectEqual(@as(@TypeOf(b.nsec), 0), b.nsec);
    const c = msToTimespec(2345); // seconds + a nanosecond remainder
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

test "playAttemptRetryable: only an unplayed open-failure with budget left retries (ROD-309)" {
    // The retry case: mpv couldn't open the stream, nothing played, tries remain.
    try std.testing.expect(playAttemptRetryable(error.MpvOpenFailed, 0, false));
    try std.testing.expect(playAttemptRetryable(error.MpvOpenFailed, 1, false));

    // Budget exhausted — the last allowed attempt does not schedule another.
    try std.testing.expect(!playAttemptRetryable(error.MpvOpenFailed, MAX_PLAY_ATTEMPTS - 1, false));

    // Playback started before it died → not our transient open 403; never hammer-restart.
    try std.testing.expect(!playAttemptRetryable(error.MpvOpenFailed, 0, true));

    // A different failure class (mpv missing, signal, generic exit) is not retryable.
    try std.testing.expect(!playAttemptRetryable(error.MpvFailed, 0, false));
    try std.testing.expect(!playAttemptRetryable(error.MpvNotFound, 0, false));

    // Guard the backoff table covers every retry the gate permits.
    try std.testing.expectEqual(MAX_PLAY_ATTEMPTS - 1, RETRY_BACKOFFS_MS.len);
}

// ── ROD-342: resolveViaSearch pass control flow, driven by a stub provider ──────

/// In-process `SourceProvider` for exercising `resolveViaSearch` without network:
/// two canned query→results rows and a single show id whose episode probe lists
/// anything. Everything else errors or lists empty, mirroring a miss.
const StubCatalog = struct {
    romaji: []const Anime = &.{},
    english: []const Anime = &.{},
    /// The one show id whose episode probe succeeds; all others list empty.
    alive_id: []const u8 = "",
    /// Search-call count, for pinning the redundant-pass skip.
    searches: u32 = 0,
    catalog_name: []const u8 = "stub",

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
        self.searches += 1;
        const rows: []const Anime = if (std.mem.eql(u8, query, "Romaji Title"))
            self.romaji
        else if (std.mem.eql(u8, query, "English Title"))
            self.english
        else
            &.{};
        return arena.dupe(Anime, rows);
    }
    fn stubCanonicalKey(_: *anyopaque, _: Allocator, _: Anime) anyerror!?[]const u8 {
        return null;
    }
    fn stubEpisodes(ptr: *anyopaque, arena: Allocator, _: std.Io, show_id: []const u8, _: domain.Translation) anyerror![]domain.EpisodeNumber {
        const self: *StubCatalog = @ptrCast(@alignCast(ptr));
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
    // The anipub shape: an English-only-searchable catalog embedding mal ids.
    const canonical: Anime = .{ .id = "154587", .name = "Romaji Title", .english_name = "English Title", .anilist_id = 154587, .mal_id = 52991 };
    var stub = StubCatalog{
        .english = &.{.{ .id = "2454", .name = "English Title", .mal_id = 52991 }},
    };
    const got = resolveViaSearch(arena_state.allocator(), std.testing.io, stub.provider(), canonical, .sub, true) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("2454", got);
}

test "resolveViaSearch: a dead pass-1 listing falls through to pass 2 on the Add probe" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // Pass 1 id-matches a listing whose episode probe comes up empty; pass 2 must
    // still get its shot instead of the whole resolve dying with it.
    const canonical: Anime = .{ .id = "1", .name = "Romaji Title", .english_name = "English Title", .anilist_id = 1, .mal_id = 52991 };
    var stub = StubCatalog{
        .romaji = &.{.{ .id = "dead", .name = "Romaji Title", .mal_id = 52991 }},
        .english = &.{.{ .id = "alive", .name = "English Title", .mal_id = 52991 }},
        .alive_id = "alive",
    };
    const got = resolveViaSearch(arena_state.allocator(), std.testing.io, stub.provider(), canonical, .sub, false) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("alive", got);

    // Both passes dead → null, never a bind on an unplayable listing.
    stub.alive_id = "";
    try std.testing.expect(resolveViaSearch(arena_state.allocator(), std.testing.io, stub.provider(), canonical, .sub, false) == null);
}

test "resolveViaSearch: Play skips the probe; identical English title skips pass 2" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // for_play: the downstream episode fetch is the confirmation, so a probe-dead
    // listing still resolves (and its failure surfaces on that fetch instead).
    const canonical: Anime = .{ .id = "1", .name = "Romaji Title", .english_name = "English Title", .anilist_id = 1, .mal_id = 52991 };
    var stub = StubCatalog{
        .romaji = &.{.{ .id = "dead", .name = "Romaji Title", .mal_id = 52991 }},
    };
    const got = resolveViaSearch(arena_state.allocator(), std.testing.io, stub.provider(), canonical, .sub, true) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("dead", got);
    try std.testing.expectEqual(@as(u32, 1), stub.searches); // pass-1 hit → pass 2 never fired

    // english_name == name: the second pass is a redundant query and must not fire
    // even when pass 1 misses (one search total, resolve collapses to null).
    const same_title: Anime = .{ .id = "2", .name = "No Such Show", .english_name = "No Such Show", .anilist_id = 2 };
    var stub2 = StubCatalog{};
    try std.testing.expect(resolveViaSearch(arena_state.allocator(), std.testing.io, stub2.provider(), same_title, .sub, true) == null);
    try std.testing.expectEqual(@as(u32, 1), stub2.searches);
}

test "resolveAcrossProviders: walks registry order, first confident match wins (ROD-343)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const canonical: Anime = .{ .id = "154587", .name = "Romaji Title", .anilist_id = 154587, .mal_id = 52991 };

    // First provider's catalog misses, second's id-matches: the match must carry
    // the SECOND provider's name (the bind is keyed under it, never the default).
    var miss = StubCatalog{ .catalog_name = "alpha" };
    var hit = StubCatalog{ .catalog_name = "beta", .romaji = &.{.{ .id = "2454", .name = "Romaji Title", .mal_id = 52991 }} };
    const walked = resolveAcrossProviders(arena_state.allocator(), std.testing.io, &.{ miss.provider(), hit.provider() }, canonical, .sub, true) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("2454", walked.id);
    try std.testing.expectEqualStrings("beta", walked.source);

    // Both match: first in registry order wins the tie.
    var hit_first = StubCatalog{ .catalog_name = "alpha", .romaji = &.{.{ .id = "1111", .name = "Romaji Title", .mal_id = 52991 }} };
    var hit_second = StubCatalog{ .catalog_name = "beta", .romaji = &.{.{ .id = "2222", .name = "Romaji Title", .mal_id = 52991 }} };
    const tie = resolveAcrossProviders(arena_state.allocator(), std.testing.io, &.{ hit_first.provider(), hit_second.provider() }, canonical, .sub, true) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("1111", tie.id);
    try std.testing.expectEqualStrings("alpha", tie.source);

    // Nobody matches → null, and every provider got its shot.
    var m1 = StubCatalog{ .catalog_name = "alpha" };
    var m2 = StubCatalog{ .catalog_name = "beta" };
    try std.testing.expect(resolveAcrossProviders(arena_state.allocator(), std.testing.io, &.{ m1.provider(), m2.provider() }, canonical, .sub, true) == null);
    try std.testing.expect(m1.searches > 0 and m2.searches > 0);
}
