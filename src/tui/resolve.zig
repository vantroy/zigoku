//! Provider resolution + episode-fetch + fallback layer for the TUI (ROD-363).
//! Carved out of app.zig (cut #2, following ROD-361's input.zig): app.zig had
//! grown past 4.5k lines and every resolve touch blew review context. These are
//! the free functions that turn a selection into a playable provider id, fetch
//! its episodes, walk the fallback ladder when a provider comes up empty, and
//! pre-warm the next candidate. They take `self: *App` and call App's pub methods
//! as `self.foo()`, matching the view/*.zig + input.zig convention.
//!
//! Boundary: only the resolve/fallback/prewarm/add-resolve cluster lives here.
//! The state it drives (App.fallback, App.pending_bind, App.episodes) and its
//! return/state types (App.ResolveVerdict, App.Fallback) stay on App; this file
//! references them as `App.*`. Resume-landing, the discover-feed pump, and the
//! shared show-meta helpers (owningProvider, refreshShowMeta, ...) stay on App too.

const std = @import("std");
const builtin = @import("builtin");

const app_mod = @import("app.zig");
const App = app_mod.App;

const workers = @import("workers.zig");
const selection = @import("selection.zig");
const event_mod = @import("event.zig");

const domain = @import("../domain.zig");
const store_mod = @import("../store.zig");
const source_mod = @import("../source.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const AnimeRecord = store_mod.AnimeRecord;
const SourceProvider = source_mod.SourceProvider;
const Registry = source_mod.Registry;
const Anime = domain.Anime;
const Loop = event_mod.Loop;
const episodesTask = workers.episodesTask;
const playTask = workers.playTask;

/// Cool-down between speculative pre-warm spawns (ROD-351): a burst of grid
/// opens must not fan out a resolve worker per open.
const prewarm_spacing_ms: i64 = 30_000;

/// The provider preference in force for NEW canonical resolution (ROD-344):
/// tier walk order and the tier-C worker's snapshot. The per-show pin
/// (ROD-345) layers over the global setting here (show orelse global),
/// never at the walk sites. `scratch` owns the pin string; every caller
/// consumes it before the arena dies (Registry.ordered reads the name only
/// during the call). Deliberately NOT consulted by the unknown-owner
/// fallbacks (`owningProvider`, the play spawn, `.direct` adds): those ids
/// historically belong to `primary()`, and re-routing them by preference
/// would persist them under the wrong provider.
fn effectivePreference(self: *const App, scratch: Allocator, aid: ?i64) []const u8 {
    if (aid) |id| {
        if (self.store) |st| {
            if (st.getProviderPin(scratch, id) catch null) |pin| return pin;
        }
    }
    return self.config.preferred_provider;
}

/// The canonical id of a selection as the store's i64 key, or null for a
/// non-canonical row (no AniList identity → no pin, no binding spine).
fn canonicalAid(sel: Anime) ?i64 {
    return std.math.cast(i64, sel.anilist_id orelse return null);
}

/// `count_hint` (ROD-359): the canonical's expected episode count for a
/// provider with no listing endpoint (megaplay), from a caller that holds
/// the canonical (a resolve verdict's `sel`, a walk's `canonical`). Null
/// derives it from the seed record below, which covers every open of an
/// already-persisted binding; only a virgin resolve has no row to read.
pub fn fireEpisodesForId(self: *App, loop: *Loop, io: std.Io, registry: Registry, source_id: []const u8, origin: ?[]const u8, count_hint: ?u32) void {
    // ROD-179: do NOT join a prior in-flight episode fetch here: that would
    // block the main loop on a slow network when a settled-then-resumed scroll
    // supersedes it (ROD-156). The old worker is already detached + accounted
    // in `episode_drain`; its stale result/failure is keep-checked away on
    // arrival (see the episodes_done / episodes_error handlers).
    self.episodes.freeResults(self.gpa);
    self.episodes.cursor = 0;
    // ROD-229: any new fetch supersedes a pending resume-landing, so a later
    // failure of *this* (user-driven) fetch must not demote to History. Only
    // the auto-open re-arms the flag, immediately after this returns.
    self.resume_landing_pending = false;
    // ROD-327: a new fetch also clears any pending tier-A bind so a non-resolving
    // open (History/Discover) never inherits a stale one. A resolving Browse fire
    // re-sets it immediately after this returns (fireEpisodesBrowse).
    self.pending_bind = null;
    // ROD-346: same for the fallback walk. A user-driven fire kills a stale walk;
    // walk hops hold theirs in a local across this call and re-install after.
    // A late Play-search result is likewise no longer wanted once the user
    // fired something else (the resolve_play_target staleness gate).
    clearFallback(self);
    self.play_resolve_aid = null;
    // ROD-329: clears the sentinel flag; a populated grid must never render "no source
    // available" (the History gate re-sets it, this fetch never runs for a sentinel row).
    self.episodes.unbound = false;

    // ROD-130: a synchronous LRU/DB hit opens the pane instantly, no thread.
    // Resolve the source/status/history-record and hand them to the subsystem,
    // which never reads App (ROD-180). A resolved Browse fire passes the
    // provider it actually resolved on as `origin` (ROD-343); only an
    // unresolved open derives the source from nav state. On a hit the
    // subsystem installs the results; clear the shared slow-path timer since
    // no async op is now running.
    const source = origin orelse selection.currentDetailSourceName(self, registry);
    const status: ?[]const u8 = if (self.currentDetailAnime()) |a| a.status else null;
    // ROD-163: resolve the seed record for either origin (history in-memory /
    // browse from the store). The arena backs a browse-origin store read and
    // outlives the synchronous tryCacheHit → applyCached → seedHistoryCursor
    // call below.
    var seed_arena = std.heap.ArenaAllocator.init(self.gpa);
    defer seed_arena.deinit();
    const seed_rec = selection.detailSeedRecord(self, seed_arena.allocator(), source, source_id);
    // ROD-345/348: every grid open funnels through here, so this is the one
    // spot that keeps the rail's cached per-show state (pin + provider
    // availability) in step with the show on screen.
    self.refreshShowMeta(if (seed_rec) |r| r.anilist_id else null);
    // ROD-182: opening a show is the refresh-on-view trigger: re-enrich it when
    // its persisted metadata is stale. Independent of the episode cache hit
    // below, so it runs whether or not the grid is already cached.
    self.maybeRefreshEnrichment(loop, io, source, source_id, seed_rec);
    if (self.episodes.tryCacheHit(self.gpa, self.store, source, source_id, self.translation, status, seed_rec)) {
        self.async_start_ms = 0;
        // ROD-352: a synchronous hit posts no episodes_done, so the landing
        // raise fires here (covers plain cached opens AND a walk hop's
        // cache-hit landing, which used to rely on completeFallback).
        self.raiseLandingProgress(source, source_id);
        return;
    }

    // Two GPA-duped copies: one for episodes.for_id, one for the task (→ event).
    // `loading` is set only once the spawn is committed below: an OOM in this
    // dupe chain returns with loading cleared, so a fire that never starts a
    // worker can't strand the spinner (ROD-179 review). freeResults above
    // already nulled for_id, so "not loading" is the coherent state on bail.
    const id_for_app = self.gpa.dupe(u8, source_id) catch {
        self.episodes.loading = false;
        return;
    };
    const src_for_app = self.gpa.dupe(u8, source) catch {
        self.gpa.free(id_for_app);
        self.episodes.loading = false;
        return;
    };
    const id_for_task = self.gpa.dupe(u8, source_id) catch {
        self.gpa.free(id_for_app);
        self.gpa.free(src_for_app);
        self.episodes.loading = false;
        return;
    };
    self.episodes.for_id = id_for_app;
    self.episodes.for_source = src_for_app;

    self.episodes.loading = true;
    self.async_start_ms = self.now_ms;

    const hint = count_hint orelse if (seed_rec) |r|
        domain.expectedEpisodeCount(selection.animeFromHistoryRecord(r))
    else
        null;

    // Account before the spawn so teardown's drain can never observe a gap;
    // detach so a later supersede never has to join this one (ROD-179).
    self.episode_drain.begin();
    const t = std.Thread.spawn(.{}, episodesTask, .{
        loop, self.gpa, io, registry.byName(source) orelse registry.primary(), id_for_task, self.translation, hint, &self.episode_drain,
    }) catch {
        self.episode_drain.finish(); // no worker will run, rebalance the count
        self.gpa.free(id_for_task);
        self.episodes.loading = false;
        return;
    };
    t.detach();
}

/// Classify a canonical-capable selection into how it resolves to a play provider
/// (ROD-328; Browse search and the Discover feed both key rows this way). Anything
/// already provider-keyed (History rows, or an anilist_id-less row) is `.direct`.
/// For an unresolved AniList hit the walk is TIER-major across the registry
/// (ROD-343), not provider-major: an existing binding on ANY provider beats
/// deriving a fresh key on an earlier one, because it respects where the user's
/// history for the show already lives (provider-major would shadow a later
/// provider's bindings forever, since the first provider's canonicalKey hits
/// whenever a mal_id exists). Within a tier, the EFFECTIVE order breaks ties
/// (ROD-344): `preferred` leads, construction order for the rest.
/// `scratch` owns any store-read or `canonicalKey` id string; the caller uses it before
/// `scratch` dies (the fetch spawn dupes it).
pub fn browseResolveTarget(registry: Registry, preferred: []const u8, sel: Anime, store: ?*Store, scratch: Allocator) App.ResolveVerdict {
    const aid = sel.anilist_id orelse return .{ .direct = sel.id };
    const aid_i64 = std.math.cast(i64, aid) orelse return .{ .direct = sel.id };
    var idbuf: [24]u8 = undefined;
    const aid_str = std.fmt.bufPrint(&idbuf, "{d}", .{aid}) catch return .{ .direct = sel.id };
    // A provider-keyed row (id != stringified anilist_id) fetches as-is.
    if (!std.mem.eql(u8, sel.id, aid_str)) return .{ .direct = sel.id };
    // Tier 0: an existing binding on any provider wins, effective order on ties.
    if (store) |st| {
        var it = registry.ordered(preferred);
        while (it.next()) |p| {
            if (st.bindingSourceId(scratch, p.name(), aid_i64) catch null) |sid|
                return .{ .bound = .{ .provider = p, .id = sid, .anilist_id = aid_i64 } };
        }
    }
    // Tier A: the first provider (effective order) that keys its own catalog
    // by canonical id.
    var it = registry.ordered(preferred);
    while (it.next()) |p| {
        if (p.canonicalKey(scratch, sel) catch null) |key|
            return .{ .tier_a = .{ .provider = p, .id = key, .anilist_id = aid_i64 } };
    }
    // Tier C: a title search (the worker walks an effective-order snapshot).
    return .{ .needs_search = aid_i64 };
}

/// Fire an episode fetch for a canonical-capable selection, routing through the
/// resolver (ROD-328). `.direct`/`.tier_a` fetch immediately (the fetch doubles as
/// the tier-A existence probe); `.needs_search` fires the tier-C search worker
/// first. Shared by Browse (two-pane focus + zoom) and the Discover zoom (ROD-336)
/// so the routing lives once.
pub fn fireEpisodesCanonical(self: *App, loop: *Loop, io: std.Io, registry: Registry, sel: Anime) void {
    // ROD-346: a `.needs_search` verdict never reaches fireEpisodesForId, so a
    // stale walk (and a stale Play-search want) from a previous show must die
    // here, not there.
    clearFallback(self);
    self.play_resolve_aid = null;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    // The selection is the canonical entity (fully enriched on the AniList
    // paths), so it carries the count hint for listing-less providers.
    const hint = domain.expectedEpisodeCount(sel);
    switch (browseResolveTarget(registry, effectivePreference(self, arena.allocator(), canonicalAid(sel)), sel, self.store, arena.allocator())) {
        .direct => |id| fireEpisodesResolved(self, loop, io, registry, null, id, null, hint),
        // Tier 0: the binding already exists, so fetch by the stored id with no re-bind.
        .bound => |b| fireEpisodesResolved(self, loop, io, registry, b.provider.name(), b.id, null, hint),
        .tier_a => |t| fireEpisodesResolved(self, loop, io, registry, t.provider.name(), t.id, t.anilist_id, hint),
        .needs_search => |aid| fireResolvePlaySearch(self, loop, io, registry, sel, aid),
    }
}

/// Browse's Enter/l entry into `fireEpisodesCanonical`: resolve the list selection.
pub fn fireEpisodesBrowse(self: *App, loop: *Loop, io: std.Io, registry: Registry) void {
    const sel = selection.selectedAnime(self) orelse return;
    fireEpisodesCanonical(self, loop, io, registry, sel);
}

/// Shared tail of a resolved Browse fire (ROD-328): the in-flight guard, the episode
/// spawn, and arming `pending_bind`. `origin` is the resolved provider's name (a
/// static vtable string) for a `.bound`/`.tier_a` verdict, or null for a `.direct`
/// open (no resolve happened, the fetch keys on nav state). `bind` is the canonical
/// anilist_id for a tier-A or tier-C resolve (minted on `.episodes_done`), or null
/// when the binding needs no minting (an already-keyed `.direct` open, or a tier-0
/// `.bound` hit whose row already exists).
/// Skips a respawn when the same provider id is already fetching: re-firing would
/// just abandon the in-flight fetch and start an identical one.
fn fireEpisodesResolved(self: *App, loop: *Loop, io: std.Io, registry: Registry, origin: ?[]const u8, id: []const u8, bind: ?i64, count_hint: ?u32) void {
    const in_flight = self.episodes.loading and
        self.episodes.for_id != null and
        std.mem.eql(u8, self.episodes.for_id.?, id);
    if (in_flight) {
        // Same provider id already fetching, so skip the respawn. Still refresh
        // pending_bind: two AniList entries can share a mal_id (duplicate/unmerged
        // records), so the in-flight episodes_done must bind THIS entry, not a stale one.
        self.pending_bind = bind;
        return;
    }
    fireEpisodesForId(self, loop, io, registry, id, origin, count_hint);
    // fireEpisodesForId nulled pending_bind at entry; set the fresh one so only this
    // fire's episodes_done can consume it. A synchronous cache hit posts no
    // episodes_done, so this bind goes unconsumed; that's benign (a warm cache means
    // the binding already exists) and the next fire nulls it anyway.
    self.pending_bind = bind;
}

/// Fire the tier-C Play resolve worker (ROD-328): title-search the providers (effective order, ROD-344) for a
/// Browse hit that could not tier-A (`canonicalKey` returned null). On a confident match
/// `.resolve_play_target` arms `pending_bind` and fires the episode fetch; a miss toasts.
/// gpa owns a deep copy of the canonical (the worker frees it). Bounded to one in-flight
/// search via `play_resolving` (the ROD-309 rate-scoring discipline); accounted via
/// `play_resolve_drain` so teardown waits it out. Best-effort: a failed dupe/spawn drops it.
fn fireResolvePlaySearch(self: *App, loop: *Loop, io: std.Io, registry: Registry, canonical: Anime, anilist_id: i64) void {
    if (self.play_resolving) return;
    const gpa = self.gpa;
    const snap = workers.dupeOwnedAnime(gpa, canonical) catch return;
    // Effective-order snapshot for the walk (ROD-344), owned by the worker:
    // the preference can change mid-flight, the snapshot can't. Filtered
    // through the ROD-347 cache: known-absent providers aren't re-searched.
    var pref_arena = std.heap.ArenaAllocator.init(gpa);
    defer pref_arena.deinit();
    const providers = orderedSearchProviders(self, gpa, registry, effectivePreference(self, pref_arena.allocator(), anilist_id), anilist_id) catch {
        workers.freeOwnedAnime(gpa, snap);
        return;
    };
    self.async_start_ms = self.now_ms; // slow-path spinner while the search runs
    self.play_resolving = true;
    self.play_resolve_drain.begin();
    const t = std.Thread.spawn(.{}, workers.resolveSearchTask, .{
        loop, gpa, io, providers, snap, anilist_id, self.translation, true, &self.play_resolve_drain,
    }) catch {
        self.play_resolve_drain.finish(); // no worker will run, rebalance the count
        self.play_resolving = false;
        gpa.free(providers);
        workers.freeOwnedAnime(gpa, snap);
        return;
    };
    t.detach();
    self.play_resolve_aid = anilist_id; // the show this search is FOR (staleness gate)
}

/// Map the failed episode onto a hop provider's grid (ROD-346): exact raw-label
/// match first, same 1-based ordinal as fallback (providers label positionally,
/// senshi and megaplay both), null when the grid is too short for either.
pub fn mapEpisodeIndex(episodes: []const domain.EpisodeNumber, raw: []const u8, ordinal: u32) ?usize {
    for (episodes, 0..) |ep, i| {
        if (std.mem.eql(u8, ep.raw, raw)) return i;
    }
    if (ordinal >= 1 and @as(usize, ordinal) - 1 < episodes.len) return @as(usize, ordinal) - 1;
    return null;
}

/// Persist a resolve walk's definitive per-provider misses into the ROD-347
/// negative cache. Best-effort: a missing canonical row FK-fails the insert
/// (nothing to key the verdict on) and is logged, never surfaced. The cache
/// is an optimization; no user path may fail on it.
pub fn persistProviderAbsences(self: *App, anilist_id: i64, names: []const []const u8) void {
    if (names.len == 0) return;
    const st = self.store orelse return;
    for (names) |n| {
        st.markProviderAbsent(anilist_id, n, Store.nowSecs()) catch |e|
            log.debug("markProviderAbsent failed: {s}", .{@errorName(e)});
    }
    self.noteAvailabilityWrite(anilist_id);
}

/// Effective-order provider snapshot for a tier-C search walk, minus the
/// providers holding a fresh ROD-347 absence verdict for this show: sparing
/// exactly these searches is what the cache is for. gpa-owned; the worker
/// frees it. An all-absent show yields an EMPTY slice; the worker then posts
/// the plain miss, which routes the caller's normal dead-end arm (unbound
/// marker on add, toast on play) with no bespoke handling.
fn orderedSearchProviders(self: *App, gpa: Allocator, registry: Registry, preferred: []const u8, anilist_id: i64) ![]SourceProvider {
    const full = try registry.orderedAlloc(gpa, preferred);
    const st = self.store orelse return full;
    const now = Store.nowSecs();
    var kept: usize = 0;
    for (full) |p| {
        if (st.providerAbsentFresh(anilist_id, p.name(), now) catch false) continue;
        full[kept] = p;
        kept += 1;
    }
    if (kept == full.len) return full;
    // Exact-fit copy: the worker frees with gpa.free, so it must own a whole
    // allocation, never a shortened view of one.
    defer gpa.free(full);
    return try gpa.dupe(SourceProvider, full[0..kept]);
}

/// The providers a pre-warm walk should try for one canonical entity (ROD-351):
/// every registered provider with no existing binding (tier 0 already covers
/// those) and no fresh absence verdict (ROD-347). Registry construction order:
/// the warm tries everyone it can learn about, so preference (a resolution
/// concern) plays no part. Result borrows `arena`. pub for the app_test pins.
pub fn prewarmCandidates(st: *Store, registry: Registry, anilist_id: i64, arena: Allocator) ![]SourceProvider {
    var out: std.ArrayListUnmanaged(SourceProvider) = .empty;
    const now = Store.nowSecs();
    for (registry.providers) |p| {
        if ((st.bindingSourceId(arena, p.name(), anilist_id) catch null) != null) continue;
        if (st.providerAbsentFresh(anilist_id, p.name(), now) catch false) continue;
        try out.append(arena, p);
    }
    return out.toOwnedSlice(arena);
}

/// Fire the eager pre-warm walk (ROD-351) for a show the user just added or
/// started playing: mint sibling bindings in the background so a later
/// provider flip (auto fallback or the 'v' pin) is instant tier-0 routing
/// instead of a slow first-time resolve. Silent by design: no toast, no
/// spinner; the walk's only user-visible trace is faster flips later.
///
/// Yields to the foreground: never fires while a fallback walk is armed or a
/// user-facing resolve is in flight (those flags clear quickly and the next
/// add/play re-triggers). Once per canonical per session (`prewarm_attempted`);
/// an empty candidate set marks nothing, so a show that gains a canonical id
/// or ages out an absence verdict later still gets its warm.
///
/// Tested-debt, same shape as `fireSyncFlush`: the spawn is gated under
/// `builtin.is_test` (a detached thread posting into the loop mid-test is a
/// teardown race), so tests pin the candidate filter (`prewarmCandidates`),
/// the attempted-mark, and the event arms; the thread glue mirrors
/// `fireResolveAddSearch` and is exercised live.
pub fn firePrewarm(self: *App, loop: *Loop, io: std.Io, registry: Registry, anilist_id: i64) void {
    if (self.prewarm_active or self.add_resolving or self.play_resolving) return;
    if (self.fallback != null) return; // mid-rescue is exactly the wrong time
    const st = self.store orelse return;
    for (self.prewarm_attempted) |a| if (a != null and a.? == anilist_id) return;
    if (self.prewarm_last_start_ms) |t| if (self.now_ms - t < prewarm_spacing_ms) return;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const candidates = prewarmCandidates(st, registry, anilist_id, arena.allocator()) catch return;
    if (candidates.len == 0) return;
    const canon_rec = (st.getCanonicalByAnilistId(arena.allocator(), anilist_id) catch null) orelse return;
    if (builtin.is_test) {
        markPrewarmAttempted(self, anilist_id);
        return;
    }
    const gpa = self.gpa;
    const canonical = workers.dupeOwnedAnime(gpa, selection.animeFromHistoryRecord(canon_rec)) catch return;
    const providers = gpa.dupe(SourceProvider, candidates) catch {
        workers.freeOwnedAnime(gpa, canonical);
        return;
    };
    self.prewarm_cancel.store(false, .release);
    self.prewarm_active = true;
    self.prewarm_drain.begin();
    const t = std.Thread.spawn(.{}, workers.prewarmTask, .{
        loop, gpa, io, providers, canonical, anilist_id, self.translation, &self.prewarm_cancel, &self.prewarm_drain,
    }) catch {
        self.prewarm_drain.finish(); // no worker will run, rebalance the count
        self.prewarm_active = false;
        gpa.free(providers);
        workers.freeOwnedAnime(gpa, canonical);
        return;
    };
    t.detach();
    markPrewarmAttempted(self, anilist_id); // only a walk that actually ran counts
}

fn markPrewarmAttempted(self: *App, anilist_id: i64) void {
    self.prewarm_attempted[self.prewarm_attempted_next] = anilist_id;
    self.prewarm_attempted_next = (self.prewarm_attempted_next + 1) % self.prewarm_attempted.len;
    self.prewarm_last_start_ms = self.now_ms;
}

/// pub for the app_test teardowns (a test that arms a walk must free it).
pub fn clearFallback(self: *App) void {
    if (self.fallback) |*w| w.deinit(self.gpa);
    self.fallback = null;
}

/// Build the walk from the failed fetch's identity (ROD-346). The canonical
/// entity is looked up by anilist_id: `pending_aid` (a virgin tier-A probe whose
/// binding was never minted) or the failed binding's own row. Returns false when
/// the show can't fall back (no store, no canonical identity): the caller's
/// dead-end handling stands.
fn beginFallback(self: *App, registry: Registry, pending_aid: ?i64) bool {
    const st = self.store orelse return false;
    const src = self.episodes.for_source orelse return false;
    const fid = self.episodes.for_id orelse return false;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const looked_up: ?i64 = pending_aid orelse blk: {
        const rec = (st.getAnime(arena.allocator(), src, fid) catch null) orelse break :blk null;
        break :blk rec.anilist_id;
    };
    const aid = looked_up orelse return false;
    const canon_rec = (st.getCanonicalByAnilistId(arena.allocator(), aid) catch null) orelse return false;
    const canonical = workers.dupeOwnedAnime(self.gpa, selection.animeFromHistoryRecord(canon_rec)) catch return false;
    const providers = registry.orderedAlloc(self.gpa, effectivePreference(self, arena.allocator(), aid)) catch {
        workers.freeOwnedAnime(self.gpa, canonical);
        return false;
    };
    // `tried` bitmask capacity; degrade to no-walk rather than overflow if the
    // registry ever outgrows it (asserts compile out of release builds).
    if (providers.len > 16) {
        workers.freeOwnedAnime(self.gpa, canonical);
        self.gpa.free(providers);
        return false;
    }
    var tried: u16 = 0;
    for (providers, 0..) |p, i| {
        if (std.mem.eql(u8, p.name(), src)) tried |= @as(u16, 1) << @intCast(i);
    }
    self.fallback = .{ .canonical = canonical, .anilist_id = aid, .providers = providers, .tried = tried };
    return true;
}

/// Advance (or begin) the fallback walk after a failed episode fetch or a failed
/// tier-C hop (ROD-346). Returns true when a next-provider attempt is in flight
/// (the caller suppresses its dead-end handling); false when there is nothing to
/// walk or the order is exhausted (walk freed, the caller's dead-end copy stands).
/// Sequential single-flight by construction: one hop fires per failure event, and
/// each hop rides the existing episode-fetch / `play_resolving` guards.
pub fn advanceFallback(self: *App, loop: *Loop, io: std.Io, registry: Registry, pending_aid: ?i64, failed_name: ?[]const u8) bool {
    // ROD-351: a rescue in motion owns the CDN budget; wind down any
    // in-flight background warm rather than compete with it (checked by
    // prewarmTask between hops).
    self.prewarm_cancel.store(true, .release);
    if (self.fallback == null and !beginFallback(self, registry, pending_aid)) return false;
    var walk = self.fallback.?;
    self.fallback = null; // taken: hop fires re-enter fireEpisodesForId, which clears the field
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    while (walk.next < walk.providers.len) {
        const idx = walk.next;
        const p = walk.providers[idx];
        walk.next += 1;
        if ((walk.tried >> @intCast(idx)) & 1 != 0) continue;
        // Tier 0: an existing binding on this provider.
        const bound_id: ?[]const u8 = if (self.store) |st|
            (st.bindingSourceId(scratch, p.name(), walk.anilist_id) catch null)
        else
            null;
        if (bound_id) |sid| {
            fireFallbackFetch(self, loop, io, registry, walk, p, sid, null, failed_name);
            return true;
        }
        // ROD-347: no binding and a fresh "not stocked" verdict: don't burn a
        // probe or a tier-C search on a provider known to miss. A binding always
        // wins over a stale negative (checked above), and a manual walk probes
        // anyway. Read errors fail open: the cache is an optimization.
        if (!walk.manual) {
            if (self.store) |st| {
                if (st.providerAbsentFresh(walk.anilist_id, p.name(), Store.nowSecs()) catch false) continue;
            }
        }
        // Tier A: the provider derives its own catalog key from the canonical.
        if (p.canonicalKey(scratch, walk.canonical) catch null) |key| {
            fireFallbackFetch(self, loop, io, registry, walk, p, key, walk.anilist_id, failed_name);
            return true;
        }
        // Tier C: single-provider title search; its miss advances the walk again
        // via `.resolve_play_target`. A failed spawn counts as tried, keep walking.
        if (spawnFallbackSearch(self, loop, io, p, walk.canonical, walk.anilist_id, failed_name)) {
            self.fallback = walk;
            return true;
        }
    }
    walk.deinit(self.gpa);
    return false;
}

/// A walk hop's episode fetch (tier 0 / tier A). The fetch doubles as the
/// existence probe exactly like the initial resolve; `bind` mints on
/// `.episodes_done`. `resume_landing_pending` survives the hop (the fire clears
/// it) so an auto-resume landing demotes only when the whole walk is exhausted.
fn fireFallbackFetch(self: *App, loop: *Loop, io: std.Io, registry: Registry, walk: App.Fallback, p: SourceProvider, id: []const u8, bind: ?i64, failed_name: ?[]const u8) void {
    toastFallbackHop(self, p, failed_name);
    const landing = self.resume_landing_pending;
    fireEpisodesResolved(self, loop, io, registry, p.name(), id, bind, domain.expectedEpisodeCount(walk.canonical));
    self.resume_landing_pending = landing and self.episodes.loading;
    self.fallback = walk;
    // A synchronous cache hit already landed the grid: no episodes_done will
    // come, so the walk completes (or retires) here.
    if (!self.episodes.loading) completeFallback(self, loop, io, registry);
}

/// The walk's grid landed (ROD-346). A plain episode walk just retires. A play
/// continuation re-lands the failed episode on the hop provider and relaunches;
/// the walk STAYS ARMED across that relaunch, so a stream that fails on this
/// provider too advances the SAME walk. That is the relaunch chain's bound:
/// each provider gets at most one shot per walk, never a ping-pong of fresh
/// walks between two broken providers.
pub fn completeFallback(self: *App, loop: *Loop, io: std.Io, registry: Registry) void {
    var walk = self.fallback orelse return;
    // The landing already raised progress through the canonical union:
    // raiseLandingProgress fires on every grid landing, async (episodes_done)
    // and synchronous (cache hit) alike, so no raise belongs here (ROD-352).
    const cont = walk.play orelse {
        self.fallback = null;
        walk.deinit(self.gpa);
        return;
    };
    const eps = self.episodes.results orelse {
        self.fallback = null;
        walk.deinit(self.gpa);
        return;
    };
    const idx = mapEpisodeIndex(eps, cont.episode_raw, cont.ordinal) orelse {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "episode {s} not found on {s}", .{ cont.episode_raw, self.owningProvider(registry).displayName() }) catch "episode not found on this provider";
        self.pushToast(.warn, msg, false);
        self.fallback = null;
        walk.deinit(self.gpa);
        return;
    };
    self.episodes.cursor = idx;
    firePlay(self, loop, io, registry);
}

/// ROD-346 play surface: a stream that never opened (`isMeaningful` false on the
/// final position) hops the walk. A relaunch failure advances the walk the last
/// hop left armed; a first failure builds a fresh one from the played binding.
/// Takes ownership of `episode_raw` on every path. Returns true when a hop is in
/// flight (the caller suppresses the failure toast).
pub fn advancePlayFallback(self: *App, loop: *Loop, io: std.Io, registry: Registry, episode_raw: []const u8, ordinal: u32) bool {
    if (self.fallback) |*w| {
        if (w.play != null) {
            // Same episode, standing walk: the fresh dupe is redundant. firePlay's
            // `playing` guard structurally prevents a different episode starting
            // while the relaunch is in flight; assert that non-local proof here.
            std.debug.assert(std.mem.eql(u8, w.play.?.episode_raw, episode_raw));
            self.gpa.free(episode_raw);
            return advanceFallback(self, loop, io, registry, null, self.owningProvider(registry).displayName());
        }
        // An episode walk without a play continuation can't own a play failure.
        clearFallback(self);
    }
    if (!beginFallback(self, registry, null)) {
        self.gpa.free(episode_raw);
        return false;
    }
    self.fallback.?.play = .{ .episode_raw = episode_raw, .ordinal = ordinal };
    return advanceFallback(self, loop, io, registry, null, self.owningProvider(registry).displayName());
}

/// A walk hop's tier-C search: `resolveSearchTask` over ONE provider (mirrors
/// `fireResolvePlaySearch`, which walks the whole order for the initial resolve).
fn spawnFallbackSearch(self: *App, loop: *Loop, io: std.Io, p: SourceProvider, canonical: Anime, anilist_id: i64, failed_name: ?[]const u8) bool {
    if (self.play_resolving) return false;
    const gpa = self.gpa;
    const snap = workers.dupeOwnedAnime(gpa, canonical) catch return false;
    const one = gpa.alloc(SourceProvider, 1) catch {
        workers.freeOwnedAnime(gpa, snap);
        return false;
    };
    one[0] = p;
    self.async_start_ms = self.now_ms;
    self.play_resolving = true;
    self.play_resolve_drain.begin();
    const t = std.Thread.spawn(.{}, workers.resolveSearchTask, .{
        loop, gpa, io, one, snap, anilist_id, self.translation, true, &self.play_resolve_drain,
    }) catch {
        self.play_resolve_drain.finish(); // no worker will run, rebalance the count
        self.play_resolving = false;
        gpa.free(one);
        workers.freeOwnedAnime(gpa, snap);
        return false;
    };
    t.detach();
    self.play_resolve_aid = anilist_id; // the show this search is FOR (staleness gate)
    toastFallbackHop(self, p, failed_name);
    return true;
}

fn toastFallbackHop(self: *App, next_p: SourceProvider, failed_name: ?[]const u8) void {
    var buf: [96]u8 = undefined;
    const msg = if (failed_name) |f|
        std.fmt.bufPrint(&buf, "{s} failed, trying {s}…", .{ f, next_p.displayName() }) catch "trying next provider…"
    else
        std.fmt.bufPrint(&buf, "trying {s}…", .{next_p.displayName()}) catch "trying next provider…";
    self.pushToast(.warn, msg, false);
}

/// Every History-origin episode-grid open routes through here (ONE gate) so the
/// ROD-329 unbound sentinel renders "no source available" instead of firing a provider
/// fetch. Must key on `rec.source`: `fireEpisodesForId` only gets a bare `source_id`,
/// and `selection.animeFromHistoryRecord` drops `source` before that point. The unbound
/// branch clears the grid rather than skipping the fetch: a leftover `results`/`for_id`
/// from a previously-viewed show would let `firePlay` launch THAT show while the pane
/// displays this one.
pub fn fireEpisodesForHistoryRecord(self: *App, loop: *Loop, io: std.Io, registry: Registry, rec: AnimeRecord) void {
    if (std.mem.eql(u8, rec.source, store_mod.SOURCE_UNBOUND)) {
        self.episodes.freeResults(self.gpa);
        self.episodes.cursor = 0;
        self.pending_bind = null;
        clearFallback(self);
        self.resume_landing_pending = false;
        self.async_start_ms = 0; // no async op runs; retire any slow-path spinner
        self.episodes.loading = false;
        self.episodes.unbound = true;
        // No fetch fires, so the funnel in fireEpisodesForId never runs: keep
        // the rail's per-show state in step here or the previous show's
        // pin/availability lingers.
        self.refreshShowMeta(rec.anilist_id);
        return;
    }
    // ROD-345: a pinned show opens on the pinned provider's sibling binding when
    // one exists. DB-only, no fresh resolve on an open; the flip affordance is
    // where resolve-and-mint happens. Needed because History's visible row is the
    // most-recently-watched sibling, which right after a flip (or before the first
    // post-flip play) is still the old provider's row. The byName gate keeps a
    // retired provider's pin from fetching its foreign id on primary() (mis-key).
    if (rec.anilist_id) |aid| pin: {
        const st = self.store orelse break :pin;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const pin = (st.getProviderPin(arena.allocator(), aid) catch null) orelse break :pin;
        if (std.mem.eql(u8, pin, rec.source) or registry.byName(pin) == null) break :pin;
        const sid = (st.bindingSourceId(arena.allocator(), pin, aid) catch null) orelse break :pin;
        fireEpisodesForId(self, loop, io, registry, sid, pin, null);
        return;
    }
    // A real binding: the normal fetch, which clears `unbound` at entry.
    fireEpisodesForId(self, loop, io, registry, rec.source_id, rec.source, null);
}

/// ROD-170: open the full-screen zoom directly on a history record + fetch its
/// episodes. Used below pane_split_min, where there is no two-pane to focus
/// into, so the zoom is the only detail surface (the grid lives there).
pub fn openHistoryZoom(self: *App, loop: *Loop, io: std.Io, registry: Registry, rec: AnimeRecord) void {
    self.detail_origin = .history;
    self.active_view = .detail;
    self.active_pane = .detail;
    fireEpisodesForHistoryRecord(self, loop, io, registry, rec);
}

/// ROD-194: open the full-screen zoom directly from the Browse list, the
/// Browse twin of openHistoryZoom. Below pane_split_min there is no detail pane
/// to focus into, so Enter/Space must reach the grid via the zoom (otherwise
/// they only flip active_pane to a pane that isn't drawn: the regression).
pub fn openBrowseZoom(self: *App, loop: *Loop, io: std.Io, registry: Registry) void {
    if (self.search.results.items.len == 0) return;
    self.detail_origin = .browse;
    self.active_view = .detail;
    self.active_pane = .detail;
    fireEpisodesBrowse(self, loop, io, registry);
}

pub fn firePlay(self: *App, loop: *Loop, io: std.Io, registry: Registry) void {
    const eps = self.episodes.results orelse return;
    if (eps.len == 0 or self.episodes.cursor >= eps.len) return;
    if (self.playing) return;

    if (self.play_thread) |t| {
        t.join();
        self.play_thread = null;
    }

    const selected_id = self.episodes.for_id orelse return;
    const ep = eps[self.episodes.cursor];
    // The grid's fire-time source names the show being played (nav state can
    // have moved on). Round-trip through byName so the session borrows the
    // vtable's STATIC name string, never gpa-owned for_source (the session
    // borrow contract, see App.PlaybackSession.source). An unregistered (retired)
    // source keeps its true name via nav state, whose borrow the history
    // arena backs: persistence stays keyed to the row even though the fetch
    // fell back to the default provider.
    const source_name = blk: {
        if (self.episodes.for_source) |src| {
            if (registry.byName(src)) |p| break :blk p.name();
        }
        break :blk selection.currentDetailSourceName(self, registry);
    };
    const episode_index: u32 = @intCast(self.episodes.cursor + 1);

    var start_seconds: u64 = 0;
    if (self.store) |st| {
        if (st.getResume(source_name, selected_id, self.translation, ep.raw) catch null) |saved_resume| {
            start_seconds = saved_resume.startSecondsRewound(self.config.resume_offset_sec);
        }
    }

    const detail_anime = self.currentDetailAnime();
    const title_src: []const u8 = if (detail_anime) |anime|
        anime.name
    else
        "zigoku";
    // ROD-83: MAL id for AniSkip, when enrichment has supplied one. `playTask`
    // falls back to a Jikan lookup when this is null.
    const mal_id: ?u32 = if (detail_anime) |anime|
        (if (anime.mal_id) |m| std.math.cast(u32, m) else null)
    else
        null;

    const id_copy = self.gpa.dupe(u8, selected_id) catch return;
    const ep_copy = self.gpa.dupe(u8, ep.raw) catch {
        self.gpa.free(id_copy);
        return;
    };
    const title_copy = self.gpa.dupe(u8, title_src) catch {
        self.gpa.free(id_copy);
        self.gpa.free(ep_copy);
        return;
    };

    self.current_position = 0;
    self.current_duration = 0;
    if (!self.session.begin(self.gpa, source_name, selected_id, ep.raw, episode_index, self.translation, start_seconds)) {
        self.gpa.free(id_copy);
        self.gpa.free(ep_copy);
        self.gpa.free(title_copy);
        return;
    }

    self.play_thread = std.Thread.spawn(.{}, playTask, .{
        loop,
        self.gpa,
        io,
        registry.byName(source_name) orelse registry.primary(),
        id_copy,
        ep_copy,
        self.translation,
        title_copy,
        start_seconds,
        mal_id,
        episode_index,
        self.config.mpv_path,
        self.config.skip_mode,
        domain.Quality.fromString(self.config.default_quality),
    }) catch {
        self.session.clear(self.gpa);
        self.gpa.free(id_copy);
        self.gpa.free(ep_copy);
        self.gpa.free(title_copy);
        return;
    };
    self.playing = true;
    self.async_start_ms = self.now_ms;

    // ROD-351: while mpv runs, warm the sibling providers in the background so
    // a flip away from a mid-episode failure (or a 'v' pin) routes tier-0.
    if (self.store) |st| {
        var warm_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer warm_arena.deinit();
        if (st.getAnime(warm_arena.allocator(), source_name, selected_id) catch null) |rec| {
            if (rec.anilist_id) |aid| firePrewarm(self, loop, io, registry, aid);
        }
    }
}

/// P-add for a canonical-capable selection (ROD-327/328), shared by Browse and
/// Discover (ROD-336): dispatches Add through the same resolver as the episode
/// fetch (`browseResolveTarget`). `.tier_a` fires the async probe; `.needs_search`
/// fires the tier-C title search; both mint the binding on success. `.direct` (an
/// already provider-keyed row) adds synchronously.
pub fn addSelectedCanonical(self: *App, loop: *Loop, io: std.Io, registry: Registry, anime: Anime) void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    switch (browseResolveTarget(registry, effectivePreference(self, arena.allocator(), canonicalAid(anime)), anime, self.store, arena.allocator())) {
        // No resolve happened (already provider-keyed): the default provider owns it.
        .direct => addToWatchlist(self, registry.primary(), anime),
        // Tier 0: the binding already exists, so reveal it in place (no probe/search).
        .bound => |b| revealBoundFromBrowse(self, loop, io, registry, b.provider, b.id, b.anilist_id),
        .tier_a => |t| fireResolveAdd(self, loop, io, t.provider, t.id, t.anilist_id),
        .needs_search => |aid| fireResolveAddSearch(self, loop, io, registry, anime, aid),
    }
}

/// Reveal an already-bound tier-0 hit synchronously (ROD-328): the binding exists from a
/// prior resolve, so Add just flips it visible via `bindCanonical` (idempotent, MAX-merges
/// `history_visible`), no probe or search. Mirrors the `.resolve_add_result` success arm.
fn revealBoundFromBrowse(self: *App, loop: *Loop, io: std.Io, registry: Registry, provider: SourceProvider, id: []const u8, anilist_id: i64) void {
    const st = self.store orelse return;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const bound = st.bindCanonical(provider.name(), id, anilist_id, true, Store.nowSecs(), arena.allocator()) catch |e| {
        log.debug("reveal bound (add) failed: {s}", .{@errorName(e)});
        self.pushToast(.@"error", "couldn't add to watchlist", false);
        return;
    };
    if (!bound) {
        self.pushToast(.@"error", "couldn't add to watchlist", false);
        return;
    }
    self.history_dirty = true;
    self.noteAvailabilityWrite(anilist_id);
    self.pushToast(.success, "added to watchlist", false);
    firePrewarm(self, loop, io, registry, anilist_id); // ROD-351: warm the siblings
}

/// Fire the tier-C Add resolve worker (ROD-328): title-search the providers (effective order, ROD-344) for a
/// Browse-P hit that could not tier-A. On a confident match `.resolve_add_result` mints
/// the binding revealed; a miss toasts. Mirrors `fireResolvePlaySearch` but binds
/// visible (Add) rather than firing an episode fetch, and shares the Add path's
/// `add_resolving` guard + `add_resolve_drain` (`for_play = false`).
fn fireResolveAddSearch(self: *App, loop: *Loop, io: std.Io, registry: Registry, canonical: Anime, anilist_id: i64) void {
    if (self.add_resolving) return;
    const gpa = self.gpa;
    const snap = workers.dupeOwnedAnime(gpa, canonical) catch return;
    // Effective-order snapshot, worker-owned; mirrors fireResolvePlaySearch,
    // including the ROD-347 known-absent filter.
    var pref_arena = std.heap.ArenaAllocator.init(gpa);
    defer pref_arena.deinit();
    const providers = orderedSearchProviders(self, gpa, registry, effectivePreference(self, pref_arena.allocator(), anilist_id), anilist_id) catch {
        workers.freeOwnedAnime(gpa, snap);
        return;
    };
    self.async_start_ms = self.now_ms; // slow-path spinner while the search runs
    self.add_resolving = true;
    self.add_resolve_drain.begin();
    const t = std.Thread.spawn(.{}, workers.resolveSearchTask, .{
        loop, gpa, io, providers, snap, anilist_id, self.translation, false, &self.add_resolve_drain,
    }) catch {
        self.add_resolve_drain.finish(); // no worker will run, rebalance the count
        self.add_resolving = false;
        gpa.free(providers);
        workers.freeOwnedAnime(gpa, snap);
        return;
    };
    t.detach();
}

/// ROD-346: the Add twin of the fallback walk, collapsed to one shot: a tier-A
/// add probe missed on one provider, so search the rest of the effective order
/// (`resolveSearchTask` walks them first-confident-match). The probed provider is
/// dropped: its tier-C search would recover the same id that just failed the
/// probe, one more request against a catalog we just watched miss (ROD-309
/// discipline). Returns false when there is nothing to widen to (the caller's
/// unbound verdict stands).
pub fn fireResolveAddWiden(self: *App, loop: *Loop, io: std.Io, registry: Registry, anilist_id: i64, failed_source: []const u8) bool {
    if (self.add_resolving) return false;
    const st = self.store orelse return false;
    const gpa = self.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rec = (st.getCanonicalByAnilistId(arena.allocator(), anilist_id) catch null) orelse return false;
    const all = registry.orderedAlloc(gpa, effectivePreference(self, arena.allocator(), anilist_id)) catch return false;
    const now = Store.nowSecs();
    var n: usize = 0;
    for (all) |p| {
        if (std.mem.eql(u8, p.name(), failed_source)) continue;
        // ROD-347: a fresh cached absence spares the whole two-pass search;
        // the n == 0 return below then routes the caller's unbound arm.
        if (st.providerAbsentFresh(anilist_id, p.name(), now) catch false) continue;
        all[n] = p;
        n += 1;
    }
    if (n == 0) {
        gpa.free(all);
        return false;
    }
    // Exact-fit copy: the worker frees its slice with gpa.free, so it must own
    // a whole allocation, never a shortened view of one.
    const remaining = gpa.alloc(SourceProvider, n) catch {
        gpa.free(all);
        return false;
    };
    @memcpy(remaining, all[0..n]);
    gpa.free(all);
    const snap = workers.dupeOwnedAnime(gpa, selection.animeFromHistoryRecord(rec)) catch {
        gpa.free(remaining);
        return false;
    };
    self.async_start_ms = self.now_ms;
    self.add_resolving = true;
    self.add_resolve_drain.begin();
    const t = std.Thread.spawn(.{}, workers.resolveSearchTask, .{
        loop, gpa, io, remaining, snap, anilist_id, self.translation, false, &self.add_resolve_drain,
    }) catch {
        self.add_resolve_drain.finish(); // no worker will run, rebalance the count
        self.add_resolving = false;
        gpa.free(remaining);
        workers.freeOwnedAnime(gpa, snap);
        return false;
    };
    t.detach();
    return true;
}

/// Spawn the detached tier-A add-resolve worker (ROD-327): probes `provider.episodes`
/// for `candidate_id`; `.resolve_add_result` mints the binding and reveals on a hit, or
/// toasts the miss. gpa owns a copy of `candidate_id` (the event frees it). Accounted
/// via `add_resolve_drain` so teardown waits it out; best-effort, a failed dupe/spawn
/// drops the add.
///
/// Bounded to one in-flight probe via `add_resolving` (see its field doc for why: the
/// ROD-309 CDN rate-scoring trap). A second P while one resolves is dropped; the user
/// re-presses after the toast.
fn fireResolveAdd(self: *App, loop: *Loop, io: std.Io, provider: SourceProvider, candidate_id: []const u8, anilist_id: i64) void {
    if (self.add_resolving) return;
    const gpa = self.gpa;
    const id = gpa.dupe(u8, candidate_id) catch return;
    self.async_start_ms = self.now_ms; // slow-path spinner while the probe runs
    self.add_resolving = true;
    self.add_resolve_drain.begin();
    const t = std.Thread.spawn(.{}, workers.resolveAddTask, .{
        loop, gpa, io, provider, id, anilist_id, self.translation, &self.add_resolve_drain,
    }) catch {
        self.add_resolve_drain.finish(); // no worker will run, rebalance the count
        self.add_resolving = false;
        gpa.free(id);
        return;
    };
    t.detach();
}

/// Upsert `anime` into the watchlist as a revealed planning row, and toast the
/// outcome. Shared by Browse's P and Discover's P (ROD-189 / ROD-239).
fn addToWatchlist(self: *App, provider: SourceProvider, anime: Anime) void {
    const st = self.store orelse return;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    var rec = AnimeRecord.fromDomain(provider.name(), anime, self.translation);
    // Explicit, not via the fromDomain struct default: an add is always a
    // reveal. If AnimeRecord.history_visible's default ever flips to false
    // (defensible for its search-cache role), this keeps P revealing rows
    // (ON CONFLICT does MAX(excluded, anime)) instead of silently hiding them.
    rec.history_visible = true;
    st.upsertAnime(rec, Store.nowSecs(), arena.allocator()) catch |e| {
        log.debug("add-to-watchlist failed: {s}", .{@errorName(e)});
        self.pushToast(.@"error", "couldn't add to watchlist", false);
        return;
    };
    // Unlike the p/x/c/w transitions (which mutate a row already in
    // self.history in place), P adds a row that isn't in the in-memory list
    // yet, so flag a background reload so it surfaces in History this session,
    // not just after a restart.
    self.history_dirty = true;
    self.pushToast(.success, "added to watchlist", false);
}
