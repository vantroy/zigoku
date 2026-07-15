//! Provider resolution, episode fetch, and fallback for the TUI.
//!
//! Free functions taking `self: *App`. State types (`Fallback`, `ResolveVerdict`,
//! `pending_bind`, …) stay on App; this file only drives them. Boundary: resolve /
//! fallback / prewarm / add-resolve only.

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

/// Pin-or-global preference for NEW canonical resolution only.
/// Unknown-owner paths (`owningProvider`, play spawn, `.direct` adds) stay on
/// `primary()`: re-routing those by preference would persist under the wrong provider.
/// `scratch` owns any pin string; callers must consume it before the arena dies.
fn effectivePreference(self: *const App, scratch: Allocator, aid: ?i64) []const u8 {
    if (aid) |id| {
        if (self.store) |st| {
            if (st.getProviderPin(scratch, id) catch null) |pin| return pin;
        }
    }
    return self.config.preferred_provider;
}

fn canonicalAid(sel: Anime) ?i64 {
    return std.math.cast(i64, sel.anilist_id orelse return null);
}

/// `count_hint`: expected episode count for listing-less providers (megaplay).
/// Null → derive from the seed record below when a binding already exists.
pub fn fireEpisodesForId(self: *App, loop: *Loop, io: std.Io, registry: Registry, source_id: []const u8, origin: ?[]const u8, count_hint: ?u32) void {
    // Do not join a prior episode fetch: that blocks the main loop. The old
    // worker is detached + drain-accounted; keep-check drops its result.
    self.episodes.freeResults(self.gpa);
    self.episodes.cursor = 0;
    // User-driven fetch must not demote History if it fails (only auto-resume re-arms).
    self.resume_landing_pending = false;
    // Clear stale bind / walk / play-search want. Walk hops stash the walk
    // across this call and reinstall after.
    self.pending_bind = null;
    clearFallback(self);
    self.play_resolve_aid = null;
    // Populated grid must never show the unbound sentinel.
    self.episodes.unbound = false;

    // `origin` is the resolved provider; unresolved opens derive source from nav.
    const source = origin orelse selection.currentDetailSourceName(self, registry);
    const status: ?[]const u8 = if (self.currentDetailAnime()) |a| a.status else null;
    // Arena outlives tryCacheHit → applyCached → seedHistoryCursor (browse-origin store read).
    var seed_arena = std.heap.ArenaAllocator.init(self.gpa);
    defer seed_arena.deinit();
    const seed_rec = selection.detailSeedRecord(self, seed_arena.allocator(), source, source_id);
    // Sole funnel for grid opens: keep pin + availability caches on the open show.
    self.refreshShowMeta(if (seed_rec) |r| r.anilist_id else null);
    // Refresh-on-view is independent of the episode cache hit.
    self.maybeRefreshEnrichment(loop, io, source, source_id, seed_rec);
    if (self.episodes.tryCacheHit(self.gpa, self.store, source, source_id, self.translation, status, seed_rec)) {
        self.async_start_ms = 0;
        // Sync hit posts no episodes_done; raise progress here.
        self.raiseLandingProgress(source, source_id);
        return;
    }

    // Two GPA-duped copies: for_id for App, one for the task event.
    // Set `loading` only once the spawn is committed: OOM mid-dupe must not strand the spinner.
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

    // begin before spawn so teardown never sees a drain gap; detach so supersede never joins.
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

/// Map a canonical-capable selection to a play-provider id.
///
/// Walk is TIER-major, not provider-major: any existing binding beats a fresh
/// key on an earlier provider (provider-major would shadow later bindings whenever
/// the first provider's `canonicalKey` hits). Within a tier, effective order
/// breaks ties. `scratch` owns store-read / `canonicalKey` strings.
pub fn browseResolveTarget(registry: Registry, preferred: []const u8, sel: Anime, store: ?*Store, scratch: Allocator) App.ResolveVerdict {
    const aid = sel.anilist_id orelse return .{ .direct = sel.id };
    const aid_i64 = std.math.cast(i64, aid) orelse return .{ .direct = sel.id };
    var idbuf: [24]u8 = undefined;
    const aid_str = std.fmt.bufPrint(&idbuf, "{d}", .{aid}) catch return .{ .direct = sel.id };
    // Already provider-keyed (id is not the stringified anilist_id).
    if (!std.mem.eql(u8, sel.id, aid_str)) return .{ .direct = sel.id };
    // Tier 0: existing binding, effective order on ties.
    if (store) |st| {
        var it = registry.ordered(preferred);
        while (it.next()) |p| {
            if (st.bindingSourceId(scratch, p.name(), aid_i64) catch null) |sid|
                return .{ .bound = .{ .provider = p, .id = sid, .anilist_id = aid_i64 } };
        }
    }
    // Tier A: first provider that derives a catalog key from the canonical.
    var it = registry.ordered(preferred);
    while (it.next()) |p| {
        if (p.canonicalKey(scratch, sel) catch null) |key|
            return .{ .tier_a = .{ .provider = p, .id = key, .anilist_id = aid_i64 } };
    }
    // Tier C: title search (worker walks an effective-order snapshot).
    return .{ .needs_search = aid_i64 };
}

/// Route a canonical selection through the resolver, then fetch episodes.
/// Shared by Browse and Discover zoom.
pub fn fireEpisodesCanonical(self: *App, loop: *Loop, io: std.Io, registry: Registry, sel: Anime) void {
    // `.needs_search` never enters fireEpisodesForId; kill stale walk / play-search want here.
    clearFallback(self);
    self.play_resolve_aid = null;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const hint = domain.expectedEpisodeCount(sel);
    switch (browseResolveTarget(registry, effectivePreference(self, arena.allocator(), canonicalAid(sel)), sel, self.store, arena.allocator())) {
        .direct => |id| fireEpisodesResolved(self, loop, io, registry, null, id, null, hint),
        .bound => |b| fireEpisodesResolved(self, loop, io, registry, b.provider.name(), b.id, null, hint),
        .tier_a => |t| fireEpisodesResolved(self, loop, io, registry, t.provider.name(), t.id, t.anilist_id, hint),
        .needs_search => |aid| fireResolvePlaySearch(self, loop, io, registry, sel, aid),
    }
}

pub fn fireEpisodesBrowse(self: *App, loop: *Loop, io: std.Io, registry: Registry) void {
    const sel = selection.selectedAnime(self) orelse return;
    fireEpisodesCanonical(self, loop, io, registry, sel);
}

/// Spawn (or skip-duplicate) an episode fetch after resolve.
/// `origin`: provider name for bound/tier_a, null for direct (nav-keyed).
/// `bind`: anilist_id to mint on episodes_done, or null when already bound.
fn fireEpisodesResolved(self: *App, loop: *Loop, io: std.Io, registry: Registry, origin: ?[]const u8, id: []const u8, bind: ?i64, count_hint: ?u32) void {
    const in_flight = self.episodes.loading and
        self.episodes.for_id != null and
        std.mem.eql(u8, self.episodes.for_id.?, id);
    if (in_flight) {
        // Same id already fetching: skip respawn, but refresh pending_bind
        // (two AniList entries can share a mal_id; bind THIS entry).
        self.pending_bind = bind;
        return;
    }
    fireEpisodesForId(self, loop, io, registry, id, origin, count_hint);
    // fireEpisodesForId nulled pending_bind; re-arm so only this fire's episodes_done consumes it.
    // Sync cache hit posts no episodes_done: unconsumed bind is fine (binding already exists).
    self.pending_bind = bind;
}

/// Tier-C Play resolve: title-search providers for a hit that could not tier-A.
/// One in-flight search (`play_resolving`); drain-accounted for teardown.
fn fireResolvePlaySearch(self: *App, loop: *Loop, io: std.Io, registry: Registry, canonical: Anime, anilist_id: i64) void {
    if (self.play_resolving) return;
    const gpa = self.gpa;
    const snap = workers.dupeOwnedAnime(gpa, canonical) catch return;
    // Snapshot order at fire time; preference can change mid-flight.
    // Filtered for known-absent providers.
    var pref_arena = std.heap.ArenaAllocator.init(gpa);
    defer pref_arena.deinit();
    const providers = orderedSearchProviders(self, gpa, registry, effectivePreference(self, pref_arena.allocator(), anilist_id), anilist_id) catch {
        workers.freeOwnedAnime(gpa, snap);
        return;
    };
    self.async_start_ms = self.now_ms;
    self.play_resolving = true;
    self.play_resolve_drain.begin();
    const t = std.Thread.spawn(.{}, workers.resolveSearchTask, .{
        loop, gpa, io, providers, snap, anilist_id, self.translation, true, &self.play_resolve_drain,
    }) catch {
        self.play_resolve_drain.finish();
        self.play_resolving = false;
        gpa.free(providers);
        workers.freeOwnedAnime(gpa, snap);
        return;
    };
    t.detach();
    self.play_resolve_aid = anilist_id; // staleness gate for the result
}

/// Map a failed episode onto a hop provider's grid: exact raw label, else 1-based ordinal.
pub fn mapEpisodeIndex(episodes: []const domain.EpisodeNumber, raw: []const u8, ordinal: u32) ?usize {
    for (episodes, 0..) |ep, i| {
        if (std.mem.eql(u8, ep.raw, raw)) return i;
    }
    if (ordinal >= 1 and @as(usize, ordinal) - 1 < episodes.len) return @as(usize, ordinal) - 1;
    return null;
}

/// Persist definitive per-provider misses. Best-effort: missing canonical FK-fails
/// silently (cache is optimization only).
pub fn persistProviderAbsences(self: *App, anilist_id: i64, names: []const []const u8) void {
    if (names.len == 0) return;
    const st = self.store orelse return;
    for (names) |n| {
        st.markProviderAbsent(anilist_id, n, Store.nowSecs()) catch |e|
            log.debug("markProviderAbsent failed: {s}", .{@errorName(e)});
    }
    self.noteAvailabilityWrite(anilist_id);
}

/// Effective-order provider list for tier-C search, minus fresh absence verdicts.
/// gpa-owned whole allocation (worker frees with `gpa.free`, not a shortened view).
/// Empty slice → caller takes its normal dead-end arm.
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
    // Exact-fit copy: worker frees a whole allocation, never a shortened view.
    defer gpa.free(full);
    return try gpa.dupe(SourceProvider, full[0..kept]);
}

/// Providers with no binding and no fresh absence. Registry construction order
/// (preference is a resolution concern; warm tries everyone). Result borrows `arena`.
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

/// Eager sibling-provider warm after add/play so later flips are tier-0.
/// Silent (no toast/spinner). Yields to fallback and user-facing resolve.
/// Once per canonical per session; empty candidates mark nothing, so a later-gained canonical id or aged-out absence still gets its warm. Spawn skipped under `is_test` (teardown race).
pub fn firePrewarm(self: *App, loop: *Loop, io: std.Io, registry: Registry, anilist_id: i64) void {
    if (self.prewarm.blocked(anilist_id, self.now_ms, self.add_resolving, self.play_resolving, self.fallback != null)) return;
    const st = self.store orelse return;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const candidates = prewarmCandidates(st, registry, anilist_id, arena.allocator()) catch return;
    if (candidates.len == 0) return;
    const canon_rec = (st.getCanonicalByAnilistId(arena.allocator(), anilist_id) catch null) orelse return;
    if (builtin.is_test) {
        self.prewarm.markAttempted(anilist_id, self.now_ms);
        return;
    }
    const gpa = self.gpa;
    const canonical = workers.dupeOwnedAnime(gpa, selection.animeFromHistoryRecord(canon_rec)) catch return;
    const providers = gpa.dupe(SourceProvider, candidates) catch {
        workers.freeOwnedAnime(gpa, canonical);
        return;
    };
    // Only a walk that actually ran gets marked attempted (ring stays honest on spawn failure).
    if (self.prewarm.fire(gpa, loop, io, providers, canonical, anilist_id, self.translation)) {
        self.prewarm.markAttempted(anilist_id, self.now_ms);
    }
}

pub fn clearFallback(self: *App) void {
    if (self.fallback) |*w| w.deinit(self.gpa);
    self.fallback = null;
}

/// Build a walk from the failed fetch. False when the show cannot fall back
/// (no store / no canonical): caller's dead-end handling stands.
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
    // tried bitmask is u16; refuse rather than overflow.
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

/// Advance (or begin) the fallback walk after a failed episode fetch / tier-C hop.
/// true = next hop in flight (suppress dead-end); false = exhausted / cannot walk.
/// Single-flight by construction: one hop per failure event, riding the existing episode-fetch/play_resolving guards.
pub fn advanceFallback(self: *App, loop: *Loop, io: std.Io, registry: Registry, pending_aid: ?i64, failed_name: ?[]const u8) bool {
    // Rescue owns the CDN budget: cancel any background warm.
    self.prewarm.cancelWalk();
    if (self.fallback == null and !beginFallback(self, registry, pending_aid)) return false;
    var walk = self.fallback.?;
    // Take the walk: hop re-enters fireEpisodesForId, which would clear the field.
    self.fallback = null;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    while (walk.next < walk.providers.len) {
        const idx = walk.next;
        const p = walk.providers[idx];
        walk.next += 1;
        if ((walk.tried >> @intCast(idx)) & 1 != 0) continue;
        const bound_id: ?[]const u8 = if (self.store) |st|
            (st.bindingSourceId(scratch, p.name(), walk.anilist_id) catch null)
        else
            null;
        if (bound_id) |sid| {
            fireFallbackFetch(self, loop, io, registry, walk, p, sid, null, failed_name);
            return true;
        }
        // Fresh "not stocked": skip probe/search. Bindings always win (checked above).
        // Manual walks probe anyway. Read errors fail open.
        if (!walk.manual) {
            if (self.store) |st| {
                if (st.providerAbsentFresh(walk.anilist_id, p.name(), Store.nowSecs()) catch false) continue;
            }
        }
        if (p.canonicalKey(scratch, walk.canonical) catch null) |key| {
            fireFallbackFetch(self, loop, io, registry, walk, p, key, walk.anilist_id, failed_name);
            return true;
        }
        // Tier C single-provider search; miss advances again via resolve_play_target.
        if (spawnFallbackSearch(self, loop, io, p, walk.canonical, walk.anilist_id, failed_name)) {
            self.fallback = walk;
            return true;
        }
    }
    walk.deinit(self.gpa);
    return false;
}

/// Walk hop episode fetch. Preserves resume_landing_pending across the fire
/// so auto-resume demotes only when the whole walk is exhausted.
fn fireFallbackFetch(self: *App, loop: *Loop, io: std.Io, registry: Registry, walk: App.Fallback, p: SourceProvider, id: []const u8, bind: ?i64, failed_name: ?[]const u8) void {
    toastFallbackHop(self, p, failed_name);
    const landing = self.resume_landing_pending;
    fireEpisodesResolved(self, loop, io, registry, p.name(), id, bind, domain.expectedEpisodeCount(walk.canonical));
    self.resume_landing_pending = landing and self.episodes.loading;
    self.fallback = walk;
    // Sync cache hit: no episodes_done will complete the walk.
    if (!self.episodes.loading) completeFallback(self, loop, io, registry);
}

/// Walk's grid landed. Plain episode walk retires. Play continuation remaps the
/// failed episode and relaunches with the walk STILL ARMED (one shot per provider
/// per walk: no ping-pong of fresh walks between two broken providers).
pub fn completeFallback(self: *App, loop: *Loop, io: std.Io, registry: Registry) void {
    var walk = self.fallback orelse return;
    // Progress already raised on every landing path; nothing to raise here.
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

/// Stream never opened: hop the walk. Takes ownership of `episode_raw` on every path.
/// true = hop in flight (suppress failure toast).
pub fn advancePlayFallback(self: *App, loop: *Loop, io: std.Io, registry: Registry, episode_raw: []const u8, ordinal: u32) bool {
    if (self.fallback) |*w| {
        if (w.play != null) {
            // Same episode, standing walk: free the fresh dupe.
            // firePlay's `playing` guard prevents a different episode mid-relaunch.
            std.debug.assert(std.mem.eql(u8, w.play.?.episode_raw, episode_raw));
            self.gpa.free(episode_raw);
            return advanceFallback(self, loop, io, registry, null, self.owningProvider(registry).displayName());
        }
        clearFallback(self);
    }
    if (!beginFallback(self, registry, null)) {
        self.gpa.free(episode_raw);
        return false;
    }
    self.fallback.?.play = .{ .episode_raw = episode_raw, .ordinal = ordinal };
    return advanceFallback(self, loop, io, registry, null, self.owningProvider(registry).displayName());
}

/// Walk hop tier-C search over ONE provider (initial resolve walks the whole order).
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
        self.play_resolve_drain.finish();
        self.play_resolving = false;
        gpa.free(one);
        workers.freeOwnedAnime(gpa, snap);
        return false;
    };
    t.detach();
    self.play_resolve_aid = anilist_id;
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

/// Manual 'v' flip exhausted: name the miss, pin kept.
/// `failed_name` must come from the walk BEFORE advanceFallback deinits it:
/// at tier-C search-miss, `for_source` still names the previous provider.
pub fn toastFlipExhaust(self: *App, failed_name: ?[]const u8) bool {
    const name = failed_name orelse return false;
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "no match on {s}, pin kept", .{name}) catch "no match, pin kept";
    self.pushToast(.warn, msg, false);
    return true;
}

/// History episode-grid open. One gate so unbound sentinels render "no source"
/// instead of fetching. Keys on `rec.source` (animeFromHistoryRecord drops it).
/// Unbound clears the grid: leftover results would let firePlay launch the
/// previous show while the pane shows this one.
pub fn fireEpisodesForHistoryRecord(self: *App, loop: *Loop, io: std.Io, registry: Registry, rec: AnimeRecord) void {
    if (std.mem.eql(u8, rec.source, store_mod.SOURCE_UNBOUND)) {
        self.episodes.freeResults(self.gpa);
        self.episodes.cursor = 0;
        self.pending_bind = null;
        clearFallback(self);
        self.resume_landing_pending = false;
        self.async_start_ms = 0;
        self.episodes.loading = false;
        self.episodes.unbound = true;
        // fireEpisodesForId funnel never runs: refresh pin/avail or the previous show lingers.
        self.refreshShowMeta(rec.anilist_id);
        return;
    }
    // Pinned show: open the pinned sibling when a binding exists. DB-only, since
    // History's visible row is still the pre-flip provider right after a flip.
    // byName gate: a retired pin must not fetch its foreign id on primary() (mis-key).
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
    fireEpisodesForId(self, loop, io, registry, rec.source_id, rec.source, null);
}

/// Full-screen history detail when the terminal is below the two-pane threshold.
pub fn openHistoryZoom(self: *App, loop: *Loop, io: std.Io, registry: Registry, rec: AnimeRecord) void {
    self.detail_origin = .history;
    self.active_view = .detail;
    self.active_pane = .detail;
    fireEpisodesForHistoryRecord(self, loop, io, registry, rec);
}

/// Full-screen browse detail below the two-pane threshold (otherwise Enter only
/// flips focus to a pane that is not drawn).
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
    // Fire-time source names the show; nav may have moved on.
    // byName → static vtable string for the session borrow (not gpa-owned for_source).
    // Retired source: fall back to nav name (history-arena backed) so persistence stays keyed.
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

    // Warm siblings while mpv runs so a mid-episode flip is tier-0.
    if (self.store) |st| {
        var warm_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer warm_arena.deinit();
        if (st.getAnime(warm_arena.allocator(), source_name, selected_id) catch null) |rec| {
            if (rec.anilist_id) |aid| firePrewarm(self, loop, io, registry, aid);
        }
    }
}

/// P-add for a canonical selection (Browse + Discover). Same resolver as episode fetch.
pub fn addSelectedCanonical(self: *App, loop: *Loop, io: std.Io, registry: Registry, anime: Anime) void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    switch (browseResolveTarget(registry, effectivePreference(self, arena.allocator(), canonicalAid(anime)), anime, self.store, arena.allocator())) {
        .direct => addToWatchlist(self, registry.primary(), anime),
        .bound => |b| revealBoundFromBrowse(self, loop, io, registry, b.provider, b.id, b.anilist_id),
        .tier_a => |t| fireResolveAdd(self, loop, io, t.provider, t.id, t.anilist_id),
        .needs_search => |aid| fireResolveAddSearch(self, loop, io, registry, anime, aid),
    }
}

/// Tier-0 Add: binding already exists, just reveal (bindCanonical MAX-merges history_visible).
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
    firePrewarm(self, loop, io, registry, anilist_id);
}

/// Tier-C Add resolve. Shares add_resolving / add_resolve_drain (`for_play = false`).
fn fireResolveAddSearch(self: *App, loop: *Loop, io: std.Io, registry: Registry, canonical: Anime, anilist_id: i64) void {
    if (self.add_resolving) return;
    const gpa = self.gpa;
    const snap = workers.dupeOwnedAnime(gpa, canonical) catch return;
    var pref_arena = std.heap.ArenaAllocator.init(gpa);
    defer pref_arena.deinit();
    const providers = orderedSearchProviders(self, gpa, registry, effectivePreference(self, pref_arena.allocator(), anilist_id), anilist_id) catch {
        workers.freeOwnedAnime(gpa, snap);
        return;
    };
    self.async_start_ms = self.now_ms;
    self.add_resolving = true;
    self.add_resolve_drain.begin();
    const t = std.Thread.spawn(.{}, workers.resolveSearchTask, .{
        loop, gpa, io, providers, snap, anilist_id, self.translation, false, &self.add_resolve_drain,
    }) catch {
        self.add_resolve_drain.finish();
        self.add_resolving = false;
        gpa.free(providers);
        workers.freeOwnedAnime(gpa, snap);
        return;
    };
    t.detach();
}

/// Add twin of fallback: tier-A probe missed, search remaining providers once.
/// Drops the failed source (same id would miss again). false → unbound arm stands.
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
        if (st.providerAbsentFresh(anilist_id, p.name(), now) catch false) continue;
        all[n] = p;
        n += 1;
    }
    if (n == 0) {
        gpa.free(all);
        return false;
    }
    // Exact-fit copy: worker frees a whole allocation.
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
        self.add_resolve_drain.finish();
        self.add_resolving = false;
        gpa.free(remaining);
        workers.freeOwnedAnime(gpa, snap);
        return false;
    };
    t.detach();
    return true;
}

/// Tier-A add probe. One at a time (`add_resolving`): mashed P must not fan CDN probes.
fn fireResolveAdd(self: *App, loop: *Loop, io: std.Io, provider: SourceProvider, candidate_id: []const u8, anilist_id: i64) void {
    if (self.add_resolving) return;
    const gpa = self.gpa;
    const id = gpa.dupe(u8, candidate_id) catch return;
    self.async_start_ms = self.now_ms;
    self.add_resolving = true;
    self.add_resolve_drain.begin();
    const t = std.Thread.spawn(.{}, workers.resolveAddTask, .{
        loop, gpa, io, provider, id, anilist_id, self.translation, &self.add_resolve_drain,
    }) catch {
        self.add_resolve_drain.finish();
        self.add_resolving = false;
        gpa.free(id);
        return;
    };
    t.detach();
}

fn addToWatchlist(self: *App, provider: SourceProvider, anime: Anime) void {
    const st = self.store orelse return;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    var rec = AnimeRecord.fromDomain(provider.name(), anime, self.translation);
    // Force reveal: fromDomain's default is for search-cache; if it ever flips
    // false, P must still MAX-merge history_visible true.
    rec.history_visible = true;
    st.upsertAnime(rec, Store.nowSecs(), arena.allocator()) catch |e| {
        log.debug("add-to-watchlist failed: {s}", .{@errorName(e)});
        self.pushToast(.@"error", "couldn't add to watchlist", false);
        return;
    };
    // Row is not yet in self.history: flag reload so it surfaces this session.
    self.history_dirty = true;
    self.pushToast(.success, "added to watchlist", false);
}
