//! Zigoku — search + enrich controller subsystem (ROD-219).
//!
//! Owns the RECORD of the catalogue-search lifecycle: the query buffer, the accumulated
//! results, the loaded-page count, the in-flight flag, and the queued follow-up enrichment.
//! The pure helpers (clear / hydrate / persist) and the query-edit key handler take explicit
//! dependencies (`gpa`/`store`/`source`/`translation`) and report a `KeyResult` verdict; this
//! struct never reaches back into App.
//!
//! Boundary (mirroring EpisodeState): this struct owns the search record, not the transport.
//! The worker threads (`search_thread`/`enrich_thread`, joined on teardown), the shared
//! slow-path timer (`async_start_ms`), and the search debounce stay on App. App owns the
//! thread spawns and resolves source/translation from nav state. Mode/nav transitions
//! (`input_mode`, the list cursor, the history filter) are PROJECTIONS App applies from the
//! `onKey` verdict. Embed by value; no `@fieldParentPtr`.
//!
//! The views (`view/browse.zig`, `view/chrome.zig`) render this; `SearchController` is
//! re-exported from app.zig.

const std = @import("std");
const vaxis = @import("vaxis");
const domain = @import("../domain.zig");
const store_mod = @import("../store.zig");
const workers = @import("workers.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const Anime = domain.Anime;
const Store = store_mod.Store;

// ROD-268: the record→Anime back-fill moved to workers.zig so the Discover feed
// hydrate can share it verbatim (both back-fill a stored anilist_id so an
// id-less thumb still enriches deterministically). Same call, one home.
const hydrateAnimeFromRecord = workers.hydrateAnimeFromRecord;
const freeOwnedAnime = workers.freeOwnedAnime;

/// The catalogue-search controller (ROD-219). Holds the query buffer, the
/// accumulated (and owned) results, the loaded-page count, the in-flight flag,
/// and the queued follow-up enrich request. Transport (`search_thread` /
/// `enrich_thread` / `async_start_ms` / debounce) lives on App, not here.
pub const SearchController = struct {
    /// Fixed-width query buffer: 127 usable bytes (the append guard caps `len` at
    /// 127). Not null-terminated — the 128th byte is never written; readers always
    /// slice `query[0..len]` via `querySlice`.
    query: [128]u8 = undefined,
    len: usize = 0,

    /// Whether a search HTTP request is in flight.
    loading: bool = false,

    /// Page count of loaded results (0 = no search run yet, 1 = first page, etc.).
    page: u32 = 0,

    /// Accumulated search results. Backed by gpa — strings owned, must be freed on
    /// query reset. Access via `self.search.results.items`.
    results: std.ArrayListUnmanaged(Anime) = .empty,

    /// Queued follow-up AniList enrichment request: set when an enrich worker is
    /// already in flight so a later page can chain one without blocking the UI.
    /// Drained by the `.search_enriched` tick arm after the active worker joins.
    pending_enrich: ?struct { offset: usize, count: usize } = null,

    /// Current query as a slice (may be empty).
    pub fn querySlice(self: *const SearchController) []const u8 {
        return self.query[0..self.len];
    }

    /// What a search-prompt keypress means to the controller (the SettingsState
    /// keystone). The controller mutates only its own query/results; nav mode, the
    /// debounce timer, and the fire transport are App-live projections the
    /// controller (`App.onSearchKey`) applies from this verdict.
    pub const KeyResult = union(enum) {
        /// Not an actionable search-edit key — App does nothing.
        ignored,
        /// Query buffer grew or shrank; App (re)arms the search debounce.
        edited,
        /// Query + results were cleared. `exit` also leaves search mode (Esc);
        /// false stays in it (backspace emptied the buffer). App cancels the
        /// debounce either way.
        cleared: struct { exit: bool },
        /// Enter — leave search mode. `fire` means a debounce was still pending, so
        /// App fires the search now instead of waiting it out.
        submit: struct { fire: bool },
    };

    /// Handle a key while the Browse search prompt is active. Owns the query
    /// buffer + the owned results; never touches nav mode, the debounce timer, or
    /// the fire transport — it reports a `KeyResult` App projects. `debounce_pending`
    /// (App's timer state) lets Enter bypass an armed-but-unfired debounce.
    pub fn onKey(self: *SearchController, gpa: Allocator, key: vaxis.Key, debounce_pending: bool) KeyResult {
        // Esc: drop the query + results and leave search mode.
        if (key.matches(vaxis.Key.escape, .{})) {
            self.len = 0;
            self.clearResults(gpa);
            self.loading = false;
            return .{ .cleared = .{ .exit = true } };
        }
        // Enter: bypass the debounce — fire now if one was armed — then lock results.
        if (key.matches(vaxis.Key.enter, .{})) {
            if (debounce_pending and self.len > 0) {
                self.clearResults(gpa);
                return .{ .submit = .{ .fire = true } };
            }
            return .{ .submit = .{ .fire = false } };
        }
        // Backspace: pop a char; emptying the buffer clears the results too.
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.len == 0) return .ignored;
            self.len -= 1;
            if (self.len == 0) {
                self.clearResults(gpa);
                self.loading = false;
                return .{ .cleared = .{ .exit = false } };
            }
            return .edited;
        }
        // Printable: append and let App (re)arm the debounce.
        if (key.text) |text| {
            if (text.len > 0 and self.len + text.len <= 127) {
                @memcpy(self.query[self.len..][0..text.len], text);
                self.len += text.len;
                return .edited;
            }
        }
        return .ignored;
    }

    /// Free all accumulated search results and reset search state. Call before a
    /// new page-1 search and when Esc clears the query. `gpa` is the same
    /// allocator the results were appended with (App's `gpa`).
    pub fn clearResults(self: *SearchController, gpa: Allocator) void {
        self.pending_enrich = null;
        for (self.results.items) |r| freeOwnedAnime(gpa, r);
        self.results.clearRetainingCapacity();
        self.page = 0;
    }

    /// Release the results list on teardown. Call once from App's
    /// `deinitOwnedState`, after run() has joined the worker threads — so nothing
    /// a worker still references is freed out from under it.
    pub fn deinit(self: *SearchController, gpa: Allocator) void {
        self.clearResults(gpa);
        self.results.deinit(gpa);
        self.results = .empty;
    }

    /// Backfill the [offset, offset+count) result rows from the canonical spine, so a
    /// re-search of the same query renders rich (cover / synopsis cached from a prior
    /// visit) instead of looking cold (ROD-327). Reads `canonical_anime` by anilist_id:
    /// AniList discovery hits are canonical-keyed with no provider binding, so the old
    /// `getAnime(source, source_id)` read is wrong here. Back-fills nulls only, so it
    /// never clobbers a field the fresh AniList hit already carried. `store` is resolved
    /// by the controller (App) and passed in; this never reads App.
    pub fn hydrateResultsFromStore(
        self: *SearchController,
        gpa: Allocator,
        store: ?*Store,
        offset: usize,
        count: usize,
    ) void {
        const st = store orelse return;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        const end = @min(self.results.items.len, offset + count);
        var i = offset;
        while (i < end) : (i += 1) {
            const aid = self.results.items[i].anilist_id orelse continue;
            const key = std.math.cast(i64, aid) orelse continue;
            const rec = st.getCanonicalByAnilistId(arena.allocator(), key) catch null orelse continue;
            hydrateAnimeFromRecord(gpa, &self.results.items[i], rec);
            _ = arena.reset(.retain_capacity);
        }
    }

    /// Mirror the [offset, offset+count) result rows into the canonical spine (ROD-327):
    /// AniList discovery hits persist as canonical entities, never as provider bindings
    /// (binding a hit to a play provider is the resolver's job). Best-effort: a write
    /// failure never disrupts search. `store` is resolved by the controller and passed
    /// in; this never reads App.
    pub fn persistResults(
        self: *SearchController,
        gpa: Allocator,
        store: ?*Store,
        offset: usize,
        count: usize,
    ) void {
        const st = store orelse return;
        // Scratch arena for the per-row genres/studios-blob join (reset each iteration so
        // it can't grow across a whole search page). Reset-retaining keeps the backing
        // capacity, so it's one alloc amortized over the page.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        // AniList discovery search returns the full enrichment field set (GQL_SEARCH is
        // GQL_FIELDS), so each hit is a confirmed, fully-enriched answer: stamp it fresh
        // (ROD-327) so the collapse to one pass is real and refresh-on-view doesn't
        // re-fetch an already-current show on first open. Share one `now` across the page.
        const now = Store.nowSecs();
        const end = @min(self.results.items.len, offset + count);
        var i = offset;
        while (i < end) : (i += 1) {
            st.upsertCanonicalOnly(self.results.items[i], true, now, arena.allocator()) catch |e| log.debug("upsertCanonicalOnly failed: {s}", .{@errorName(e)});
            _ = arena.reset(.retain_capacity);
        }
    }
};
