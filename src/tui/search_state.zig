//! Zigoku — search + enrich controller subsystem (ROD-219).
//!
//! The fifth cut of the controller/subsystem split (after ROD-160's CoverState,
//! ROD-161's SettingsState, ROD-162's PlaybackSession, and ROD-180's
//! EpisodeState). Owns the *record* of the catalogue-search lifecycle: the query
//! buffer, the accumulated results, the loaded-page count, the in-flight flag,
//! and the queued follow-up enrichment request. The pure helpers (clear / hydrate
//! / persist) and the query-edit key handler take explicit dependencies
//! (`gpa`/`store`/`source`/`translation`) and report a `KeyResult` verdict — this
//! struct never reaches back into App or navigation state.
//!
//! Where the boundary sits (mirroring EpisodeState / PlaybackSession): this
//! struct owns the search *record*, not the *transport*. The worker threads (`search_thread`,
//! `enrich_thread` — the handles run() joins on teardown), the shared slow-path
//! timer (`async_start_ms`), and the search debounce timer stay on App. App
//! owns the thread spawns — via `fireSearch` / `fireEnrich` and tick's
//! `.search_done` / `.search_enriched` arms — and resolves the source name +
//! translation from navigation state, passing those primitives in here. Mode/nav
//! transitions (`input_mode`, the list cursor, the history filter) are
//! *projections* App applies from the `onKey` verdict — the SettingsState
//! keystone. Embed by value (`search: SearchController = .{}`); no back-reference,
//! no `@fieldParentPtr`.
//!
//! The views (`view/browse.zig`, `view/chrome.zig`) render this state through
//! `self.search.*`; `SearchController` is re-exported from app.zig so existing
//! `app_mod.*` references keep resolving.

const std = @import("std");
const vaxis = @import("vaxis");
const domain = @import("../domain.zig");
const store_mod = @import("../store.zig");
const workers = @import("workers.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const Anime = domain.Anime;
const AnimeRecord = store_mod.AnimeRecord;
const Store = store_mod.Store;

const dupeOptText = workers.dupeOptText;
const dupeOwnedStrList = workers.dupeOwnedStrList;
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

    /// Fill the null fields of a result row from a stored `AnimeRecord`, taking
    /// gpa-owned copies so they ride `freeOwnedAnime`. Pure: operates on the
    /// passed row + record and touches no controller state, so it stays a free
    /// helper rather than a method.
    fn hydrateAnimeFromRecord(gpa: Allocator, a: *Anime, rec: AnimeRecord) void {
        if (a.english_name == null) a.english_name = dupeOptText(gpa, rec.title_english) catch a.english_name;
        if (a.native_name == null) a.native_name = dupeOptText(gpa, rec.native_name) catch a.native_name;
        if (a.thumb == null) a.thumb = dupeOptText(gpa, rec.cover_url) catch a.thumb;
        if (a.status == null) a.status = dupeOptText(gpa, rec.status) catch a.status;
        if (a.description == null) a.description = dupeOptText(gpa, rec.description) catch a.description;
        if (a.kind == null) a.kind = dupeOptText(gpa, rec.kind) catch a.kind;
        if (a.anilist_id == null) a.anilist_id = if (rec.anilist_id) |x| std.math.cast(u64, x) else null;
        if (a.mal_id == null) a.mal_id = if (rec.mal_id) |x| std.math.cast(u64, x) else null;
        if (a.total_episodes == null) a.total_episodes = if (rec.total_episodes) |x| std.math.cast(u32, x) else null;
        if (a.year == null) a.year = if (rec.year) |x| std.math.cast(u32, x) else null;
        if (a.score == null) a.score = if (rec.score) |x| std.math.cast(u32, x) else null;
        // Season/start_date are pure values (no heap); genres is deep-copied into
        // gpa so it outlives the caller's scratch arena and rides freeOwnedAnime.
        if (a.season == null) a.season = if (rec.season) |tag| domain.Season.fromString(tag) else null;
        if (a.start_date == null) a.start_date = rec.startDate();
        if (a.genres.len == 0) a.genres = dupeOwnedStrList(gpa, rec.genres) catch a.genres;
    }

    /// Backfill the [offset, offset+count) result rows from the local store, so a
    /// fresh page renders rich (cover / synopsis / ids cached from a prior visit)
    /// instead of waiting on enrichment. `store` / `source_name` are resolved by
    /// the controller (App) from nav state and passed in — this never reads App.
    pub fn hydrateResultsFromStore(
        self: *SearchController,
        gpa: Allocator,
        store: ?*Store,
        source_name: []const u8,
        offset: usize,
        count: usize,
    ) void {
        const st = store orelse return;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        const end = @min(self.results.items.len, offset + count);
        var i = offset;
        while (i < end) : (i += 1) {
            const source_id = self.results.items[i].id;
            const rec = st.getAnime(arena.allocator(), source_name, source_id) catch null orelse continue;
            hydrateAnimeFromRecord(gpa, &self.results.items[i], rec);
        }
    }

    /// Mirror the [offset, offset+count) result rows into the store as cached
    /// catalogue records. Best-effort: a write failure never disrupts search.
    /// `store` / `source_name` / `translation` are resolved by the controller and
    /// passed in — this never reads App.
    pub fn persistResults(
        self: *SearchController,
        gpa: Allocator,
        store: ?*Store,
        source_name: []const u8,
        translation: domain.Translation,
        offset: usize,
        count: usize,
        visible: bool,
        stamp_fresh: bool,
    ) void {
        const st = store orelse return;
        // Scratch arena for the per-row genres-blob join (reset each iteration so
        // it can't grow across a whole search page). Reset-retaining keeps the
        // backing capacity, so it's one alloc amortized over the page.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const now = Store.nowSecs();
        const end = @min(self.results.items.len, offset + count);
        var i = offset;
        while (i < end) : (i += 1) {
            // ROD-280: history_visible + the freshness-stamp gate live in
            // Store.upsertEnriched (see its doc for the gate contract). `stamp_fresh`
            // is false on the raw .search_done persist and on a failed enrich.
            st.upsertEnriched(source_name, self.results.items[i], translation, visible, stamp_fresh, now, arena.allocator()) catch |e| log.debug("upsertAnime failed: {s}", .{@errorName(e)});
            _ = arena.reset(.retain_capacity);
        }
    }
};
