//! Zigoku — TUI shell (ROD-71).
//!
//! The libvaxis application skeleton the rest of M3 builds into. It owns:
//!   - vaxis init / alt-screen / teardown,
//!   - the event loop with a clean render/tick split (tick mutates state,
//!     draw is a pure function of state),
//!   - resize handling,
//!   - the worker→UI seam: background work posts into vaxis's event queue via
//!     Loop.postEvent, and the main loop drains it through nextEvent. Here that
//!     seam loads watch History off a background thread; ROD-73's async search
//!     rides the same rail.
//!
//! Landing view is History (locked decision — AllAnime is search-first with no
//! popular feed, so there's nothing to populate a Browse-idle screen with).
//! The polished views land in their own issues: tabs (ROD-72), search (ROD-73),
//! detail pane (ROD-74), history filter/progress bars (ROD-75), toasts (ROD-76).

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const colors = @import("colors.zig");
const store_mod = @import("../store.zig");
const source_mod = @import("../source.zig");
const domain = @import("../domain.zig");
const anilist = @import("../anilist.zig");
const player_mod = @import("../player.zig");

const Allocator = std.mem.Allocator;
const AnimeRecord = store_mod.AnimeRecord;
const Store = store_mod.Store;
const SourceProvider = source_mod.SourceProvider;
const Anime = domain.Anime;

/// Unified event type. vaxis fills key_press / winsize / focus; the rest are our
/// worker→UI messages, posted from background threads and drained in tick().
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    /// History finished loading (owned, gpa-allocated — App takes ownership).
    history_loaded: []AnimeRecord,
    /// A background task failed; payload is a human-readable reason.
    task_error: []const u8,
    /// Search results from background thread. `results` is gpa-allocated; app takes ownership.
    /// `for_query` is a gpa-duped copy of the query string at search time (for stale check).
    /// `page` is the page number this result set belongs to.
    search_done: struct {
        results: []Anime,
        for_query: []const u8,
        page: u32,
    },
    /// AniList-enriched metadata for a page slice. `results` is gpa-allocated;
    /// app takes ownership and merges fields into the live search results.
    search_enriched: struct {
        results: []Anime,
        for_query: []const u8,
        offset: usize,
    },
    /// Episode list from background fetch. `episodes` is gpa-allocated (each .raw owned);
    /// `for_id` is a gpa-duped copy of the show id (for stale check). App takes ownership.
    episodes_done: struct {
        episodes: []domain.EpisodeNumber,
        for_id: []const u8,
    },
    /// Episode fetch failed.
    episodes_error,
    /// mpv exited (success or failure — we don't distinguish in M3).
    play_done,
    /// resolve or mpv spawn failed.
    play_error,
    /// Periodic 100ms heartbeat: advances spinner, fires debounced search.
    tick,
};

const Loop = vaxis.Loop(Event);

/// Run the TUI to completion. `store` is optional and best-effort, exactly like
/// the CLI path: a DB hiccup means "no history," never a refusal to run.
pub fn run(
    gpa: Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    store: ?*Store,
    provider: SourceProvider,
) !void {
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, gpa, environ_map, .{});
    defer vx.deinit(gpa, writer);

    var loop = Loop.init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    try loop.installResizeHandler();

    try vx.enterAltScreen(writer);
    // Learn terminal caps (kitty graphics/keyboard) before the first paint.
    try vx.queryTerminal(writer, .fromMilliseconds(500));

    // Drain events that accumulated during queryTerminal before the first paint.
    // The tty reader thread may have posted an initial .winsize event (Loop.zig
    // ttyRun lines 164–167) and/or CPR-derived key_press events: vaxis's
    // explicit_width/scaled_text queries produce \e[1;1R which Parser.zig decodes
    // as F3-no-mods ('R' => Key.f3); Loop.zig's guard only consumes F3+shift/alt,
    // so F3-no-mods leaks through and would trigger our Settings keybind. The
    // tty.getWinsize() call below compensates for any swallowed .winsize event.
    while (loop.tryEvent() catch null) |_| {}

    // Size the screen to the terminal NOW — vx.window() reads vx.screen, which
    // only resize() populates. Without this the first frame paints at 0×0.
    // Subsequent size changes ride the .winsize event in the loop below.
    if (tty.getWinsize()) |ws| try vx.resize(gpa, writer, ws) else |_| {}

    var app: App = .{};

    // History memory lives in an arena owned here and freed on exit — matching
    // store.loadHistory's arena-in contract. App only reads the slice; in M3
    // history loads once (no re-search churn), so wholesale free is exactly right.
    var hist_arena = std.heap.ArenaAllocator.init(gpa);
    defer hist_arena.deinit();

    // The worker→UI seam: load history off a background thread. It posts the
    // result into the same queue the tty reader feeds; tick() drains it. The
    // thread is short-lived and joined before teardown.
    var hist_thread: ?std.Thread = null;
    // TODO(ROD-75): no cancellation — quitting while loadHistory is mid-query
    // blocks here until it returns. Fine for local SQLite; revisit if a real
    // async fetch lands behind this seam.
    defer if (hist_thread) |t| t.join();
    if (store) |st| {
        hist_thread = std.Thread.spawn(.{}, loadHistoryTask, .{ &loop, hist_arena.allocator(), st }) catch blk: {
            // Couldn't spawn — fall back to a synchronous load so the user still
            // sees their history.
            app.setHistory(st.loadHistory(hist_arena.allocator()) catch &.{});
            break :blk null;
        };
    } else {
        app.history_loading = false;
    }

    app.gpa = gpa;
    app.store = store;
    // Join the last search thread before loop teardown so in-flight threads
    // can't dereference a torn-down loop or gpa. Declared after loop.stop()'s
    // defer so it executes first (Zig defers are LIFO).
    defer if (app.search_thread) |t| t.join();
    defer if (app.enrich_thread) |t| t.join();
    defer if (app.episode_thread) |t| t.join();
    defer if (app.play_thread) |t| t.join();

    // Tick thread: 100ms heartbeat for spinner + search debounce. Joins before
    // loop.stop() (LIFO — this defer is declared after the loop.stop() defer).
    var tick_quit: std.atomic.Value(bool) = .init(false);
    const tick_thread = std.Thread.spawn(.{}, tickTask, .{ &loop, io, &tick_quit }) catch null;
    defer {
        tick_quit.store(true, .release);
        if (tick_thread) |t| t.join();
    }

    // First paint, then the event loop.
    try app.draw(&vx, writer);
    while (!app.should_quit) {
        const event = try loop.nextEvent();
        // Resize is a vaxis-lifecycle concern (it reallocates the screen), so
        // run() owns it — that keeps tick() a pure state fold, testable without
        // a tty. tick() still sees the event; it just doesn't touch the screen.
        if (event == .winsize) try vx.resize(gpa, writer, event.winsize);
        try app.tick(event, &loop, io, provider);
        try app.draw(&vx, writer);
    }

    // Teardown: free results strings and the backing allocation.
    // clearResults only calls clearRetainingCapacity (keeps the buffer for
    // mid-session reuse); here we want the full deinit.
    for (app.results.items) |r| freeOwnedAnime(gpa, r);
    app.results.deinit(gpa);
    app.freeEpisodeResults();
}

fn dupeOptText(alloc: Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |x| try alloc.dupe(u8, x) else null;
}

fn dupeOwnedAnime(alloc: Allocator, a: Anime) !Anime {
    var out: Anime = .{
        .id = try alloc.dupe(u8, a.id),
        .name = &.{},
        .mal_id = a.mal_id,
        .anilist_id = a.anilist_id,
        .eps_sub = a.eps_sub,
        .eps_dub = a.eps_dub,
        .total_episodes = a.total_episodes,
        .year = a.year,
        .score = a.score,
    };
    errdefer freeOwnedAnime(alloc, out);

    out.name = try alloc.dupe(u8, a.name);
    out.english_name = try dupeOptText(alloc, a.english_name);
    out.thumb = try dupeOptText(alloc, a.thumb);
    out.banner = try dupeOptText(alloc, a.banner);
    out.status = try dupeOptText(alloc, a.status);
    out.description = try dupeOptText(alloc, a.description);
    out.kind = try dupeOptText(alloc, a.kind);
    return out;
}

fn freeOwnedAnime(alloc: Allocator, a: Anime) void {
    alloc.free(a.id);
    if (a.name.len > 0) alloc.free(a.name);
    if (a.english_name) |x| alloc.free(x);
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

/// Background task: search and post results back to the UI thread.
fn searchTask(loop: *Loop, gpa: Allocator, io: std.Io, provider: SourceProvider, query: []const u8, page: u32, translation: domain.Translation) void {
    // NOTE: `query` ownership is transferred to the `search_done` event's `for_query`
    // on the success path; the UI thread frees it there. On all error paths we free it
    // here explicitly before returning. Do NOT add a defer — it would free the string
    // before the UI thread reads `ev.for_query`, causing a use-after-free.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const raw = provider.search(arena.allocator(), io, query, .{
        .translation = translation,
        .limit = 26,
        .page = page,
    }) catch {
        gpa.free(query);
        loop.postEvent(.{ .task_error = "search failed" }) catch {};
        return;
    };

    // Dupe every owned string we might thread into the UI so arena teardown
    // cannot leave dangling references in the event payload.
    var owned = std.ArrayListUnmanaged(Anime).empty;
    owned.ensureTotalCapacity(gpa, raw.len) catch {
        gpa.free(query);
        loop.postEvent(.{ .task_error = "search OOM" }) catch {};
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
    }}) catch {
        // Post failed — we still own everything; free it all.
        for (exact) |r| freeOwnedAnime(gpa, r);
        gpa.free(exact); // exact-fit: len == capacity, free is valid
        gpa.free(query);
    };
    // On success: `exact` and `query` are now owned by the event.
    // The UI thread frees them via gpa.free(ev.results) and gpa.free(ev.for_query).
}

/// Background task: enrich one page of search results from AniList.
/// `results` and `query` are GPA-owned by this task and transferred to the event on success.
fn enrichTask(
    loop: *Loop,
    gpa: Allocator,
    io: std.Io,
    results: []Anime,
    query: []const u8,
    offset: usize,
    cancel: *std.atomic.Value(bool),
) void {
    defer if (cancel.load(.acquire)) {
        for (results) |a| freeOwnedAnime(gpa, a);
        gpa.free(results);
        gpa.free(query);
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    for (results) |*a| {
        if (cancel.load(.acquire)) return;
        const meta = anilist.enrich(arena.allocator(), io, a.*) catch null orelse continue;
        if (a.english_name == null) a.english_name = dupeOptText(gpa, meta.title_english) catch a.english_name;
        if (a.thumb == null) a.thumb = dupeOptText(gpa, meta.thumb) catch a.thumb;
        if (a.status == null) a.status = dupeOptText(gpa, meta.status) catch a.status;
        if (a.description == null) a.description = dupeOptText(gpa, meta.description) catch a.description;
        if (a.anilist_id == null) a.anilist_id = meta.anilist_id;
        if (a.mal_id == null) a.mal_id = meta.mal_id;
        if (a.total_episodes == null) a.total_episodes = meta.total_episodes;
        if (a.year == null) a.year = meta.year;
        if (a.score == null) a.score = meta.score;
    }

    loop.postEvent(.{ .search_enriched = .{ .results = results, .for_query = query, .offset = offset } }) catch {
        for (results) |a| freeOwnedAnime(gpa, a);
        gpa.free(results);
        gpa.free(query);
    };
}

/// Background task: pull history and post it back to the UI thread. Errors are
/// reported as a toast-able message rather than crashing the worker.
fn loadHistoryTask(loop: *Loop, arena: Allocator, store: *Store) void {
    const recs = store.loadHistory(arena) catch |err| {
        loop.postEvent(.{ .task_error = @errorName(err) }) catch {};
        return;
    };
    loop.postEvent(.{ .history_loaded = recs }) catch {};
}

/// Background task: fetch episode list and post to UI.
/// `id` ownership: transferred to episodes_done.for_id on success; freed here on error.
fn episodesTask(loop: *Loop, gpa: Allocator, io: std.Io, provider: SourceProvider, id: []const u8, translation: domain.Translation) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const raw = provider.episodes(arena.allocator(), io, id, translation) catch {
        gpa.free(id);
        loop.postEvent(.episodes_error) catch {};
        return;
    };

    var owned: std.ArrayListUnmanaged(domain.EpisodeNumber) = .empty;
    owned.ensureTotalCapacity(gpa, raw.len) catch {
        gpa.free(id);
        loop.postEvent(.episodes_error) catch {};
        return;
    };
    for (raw) |ep| {
        const raw_owned = gpa.dupe(u8, ep.raw) catch continue;
        owned.appendAssumeCapacity(.{ .raw = raw_owned });
    }
    const exact = owned.toOwnedSlice(gpa) catch {
        for (owned.items) |ep| gpa.free(ep.raw);
        owned.deinit(gpa);
        gpa.free(id);
        return;
    };

    loop.postEvent(.{ .episodes_done = .{ .episodes = exact, .for_id = id } }) catch {
        for (exact) |ep| gpa.free(ep.raw);
        gpa.free(exact);
        gpa.free(id);
    };
}

/// Background task: resolve stream and launch mpv.
/// All string params are GPA-owned by this task and freed before return.
fn playTask(loop: *Loop, gpa: Allocator, io: std.Io, provider: SourceProvider, store: ?*Store, id: []const u8, ep_raw: []const u8, translation: domain.Translation, title: []const u8) void {
    _ = store; // resume lookup deferred to M5 (needs source_name in vtable)
    defer gpa.free(id);
    defer gpa.free(ep_raw);
    defer gpa.free(title);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const ep: domain.EpisodeNumber = .{ .raw = ep_raw };
    const link = provider.resolve(arena.allocator(), io, id, ep, translation) catch {
        loop.postEvent(.play_error) catch {};
        return;
    };
    player_mod.play(arena.allocator(), io, link, title, 0) catch {};
    loop.postEvent(.play_done) catch {};
}

/// Heartbeat thread: posts .tick every 100ms until `quit` is set.
fn tickTask(loop: *Loop, io: std.Io, quit: *std.atomic.Value(bool)) void {
    while (!quit.load(.acquire)) {
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
        loop.postEvent(.tick) catch {};
    }
}

/// Current wall-clock time in milliseconds (ms since Unix epoch).
fn nowMs(io: std.Io) i64 {
    const ts = std.Io.Clock.real.now(io);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_ms));
}

const Toast = struct {
    const Kind = enum { info, @"error", warn };
    kind: Kind,
    text: [80]u8 = undefined,
    text_len: usize = 0,
    /// Remaining TTL in ms. Ignored when persistent = true.
    ttl_ms: i32 = 4000,
    /// Persistent toasts survive TTL and are only cleared by a recovery path.
    persistent: bool = false,
};

const App = struct {
    should_quit: bool = false,

    /// Landing data. Backed by run()'s history arena — App only reads it.
    history: []AnimeRecord = &.{},
    history_loading: bool = true,
    /// Set if the background history load failed.
    load_error: ?[]const u8 = null,

    history_filter: [128]u8 = undefined,
    history_filter_len: usize = 0,

    list_cursor: usize = 0,
    /// Topmost visible row index — the viewport offset for scrolling.
    list_top: usize = 0,

    /// Per-row scratch for formatted meta strings. vaxis stores printed text by
    /// *reference*, not by copy, so anything we print must outlive the matching
    /// vx.render() call. A loop-local stack buffer dangles by render time; this
    /// App-owned buffer persists across the draw→render cycle. Soft cap of 256
    /// slots: a terminal with more than 256 visible history rows renders titles
    /// for the overflow rows without the meta column (no crash, just no meta).
    meta_scratch: [256][48]u8 = undefined,
    /// Per-row scratch for progress bar fraction strings ("N / M eps"). Same
    /// lifetime contract as meta_scratch — must outlive vx.render().
    bar_scratch: [256][32]u8 = undefined,

    /// Which top-level view is currently displayed.
    /// Defaults to .history — the M3 landing (§9.2).
    active_view: enum { browse, history, settings } = .history,

    /// Which pane has keyboard focus within the current view.
    /// Only meaningful in Browse (two panes). History and Settings are single-pane
    /// and treat this field as always .list — it still exists so the top-bar `·`
    /// rendering function can read it without a view branch.
    active_pane: enum { list, detail } = .list,

    /// Current input mode. `.search` = typing a query; `.normal` = list navigation.
    input_mode: enum { normal, search } = .normal,

    /// Fixed-width query buffer. 127 usable bytes + null sentinel = 128 total.
    search_query: [128]u8 = undefined,
    search_len: usize = 0,

    /// Whether a search HTTP request is in flight.
    search_loading: bool = false,

    /// Page count of loaded results (0 = no search run yet, 1 = first page, etc.).
    search_page: u32 = 0,

    /// Accumulated search results. Backed by gpa — strings owned, must be freed on query reset.
    /// Access via `self.results.items`.
    results: std.ArrayListUnmanaged(Anime) = .empty,

    /// GPA reference for freeing search results. Set in run() before the event loop.
    /// Intentionally not zero-initialised — only valid after run() sets it.
    gpa: Allocator = undefined,

    /// Handle for the most recent search thread. Joined in fireSearch before a new
    /// spawn, and in run() teardown. This bounds concurrent search threads to 1,
    /// preventing use-after-free of `loop` and `gpa` on fast quit.
    search_thread: ?std.Thread = null,
    /// Handle for the most recent AniList enrichment thread.
    enrich_thread: ?std.Thread = null,
    /// Cooperative cancellation flag for the current enrichment thread.
    enrich_cancel: std.atomic.Value(bool) = .init(false),

    /// Sub/dub translation for searches.
    translation: domain.Translation = .sub,

    /// Handle for the most recent episode-fetch thread. Joined in fireEpisodes before a new spawn.
    episode_thread: ?std.Thread = null,
    /// Current episode list for the detail pane. GPA-owned (each .raw owned); null until fetched.
    /// Use freeEpisodeResults() to release.
    episode_results: ?[]domain.EpisodeNumber = null,
    /// GPA-duped id of the show whose episodes are in episode_results (or in-flight).
    /// null = nothing requested yet.
    detail_for_id: ?[]const u8 = null,
    /// Whether an episode fetch is in flight.
    episode_loading: bool = false,
    /// Cursor position within the episode grid (0-based index into episode_results).
    episode_cursor: usize = 0,
    /// Handle for the most recent play thread. Joined before a new spawn.
    play_thread: ?std.Thread = null,
    /// Whether mpv is running (play thread in-flight).
    playing: bool = false,
    /// Store reference — set in run() for getResume in the play thread.
    store: ?*Store = null,
    /// Scratch for episode grid cell text (avoids dangling stack buffers in draw).
    /// vaxis stores text by reference, so we need stable storage that survives vx.render().
    /// 8 bytes per slot: "[" + up to 5-char label + "]" + spare = 8. 6 was too tight
    /// for labels like "1000a" — silently fell back to "[?]".
    ep_scratch: [512][8]u8 = undefined,
    /// Stable storage for the "no results for…" message in drawBrowseList.
    no_results_buf: [160]u8 = undefined,
    /// Stable storage for the "N eps" metadata line in drawDetailPane.
    detail_meta_buf: [32]u8 = undefined,
    /// Stable storage for the "[N]" result count in drawBottomBar search mode.
    cnt_scratch: [16]u8 = undefined,
    /// Scratch for the animated browse chip text ("⠋ search") in drawTopBar.
    chip_buf: [16]u8 = undefined,

    // ── async feedback (ROD-76) ───────────────────────────────────────────────
    /// Current Braille spinner frame index (0–9, wraps on .tick).
    spinner_frame: u8 = 0,
    /// Timestamp (ms) when the current async op started. 0 = nothing running.
    async_start_ms: i64 = 0,
    /// Deadline for search debounce (ms). 0 = no pending debounce.
    debounce_deadline_ms: i64 = 0,
    /// Last tick timestamp (ms). Updated on every .tick event; used by draw functions.
    now_ms: i64 = 0,
    /// Toast queue (oldest first). null = empty slot.
    toast_queue: [3]?Toast = .{ null, null, null },

    /// Current query as a slice (may be empty).
    fn querySlice(self: *const App) []const u8 {
        return self.search_query[0..self.search_len];
    }

    const spinner_frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"; // 10 × 3 UTF-8 bytes
    fn spinnerChar(self: *const App) []const u8 {
        const b = @as(usize, self.spinner_frame) * 3;
        return spinner_frames[b .. b + 3];
    }

    fn pushToast(self: *App, kind: Toast.Kind, text: []const u8, persistent: bool) void {
        var idx: usize = 3;
        for (self.toast_queue, 0..) |slot, i| {
            if (slot == null) { idx = i; break; }
        }
        if (idx == 3) {
            self.toast_queue[0] = self.toast_queue[1];
            self.toast_queue[1] = self.toast_queue[2];
            idx = 2;
        }
        var t: Toast = .{ .kind = kind, .persistent = persistent,
            .ttl_ms = if (persistent) 0 else 2500 };
        const n = @min(text.len, 79);
        @memcpy(t.text[0..n], text[0..n]);
        t.text_len = n;
        self.toast_queue[idx] = t;
    }

    /// Free all accumulated search results and reset search state.
    /// Call before a new page-1 search and when Esc clears the query.
    fn clearResults(self: *App) void {
        self.cancelEnrich();
        for (self.results.items) |r| freeOwnedAnime(self.gpa, r);
        self.results.clearRetainingCapacity();
        self.search_page = 0;
    }

    fn cancelEnrich(self: *App) void {
        self.enrich_cancel.store(true, .release);
        if (self.enrich_thread) |t| {
            t.join();
            self.enrich_thread = null;
        }
        self.enrich_cancel.store(false, .release);
    }

    fn fireEnrich(self: *App, loop: *Loop, io: std.Io, offset: usize, count: usize) void {
        if (builtin.is_test) return;
        if (count == 0 or offset >= self.results.items.len) return;
        self.cancelEnrich();

        const slice = self.results.items[offset..@min(self.results.items.len, offset + count)];
        var unresolved: usize = 0;
        for (slice) |a| {
            if (a.anilist_id == null or a.thumb == null or a.description == null or a.score == null) unresolved += 1;
        }
        if (unresolved == 0) return;

        const q_copy = self.gpa.dupe(u8, self.querySlice()) catch return;
        var copied = std.ArrayListUnmanaged(Anime).empty;
        copied.ensureTotalCapacity(self.gpa, slice.len) catch {
            self.gpa.free(q_copy);
            return;
        };
        for (slice) |a| {
            const duped = dupeOwnedAnime(self.gpa, a) catch continue;
            copied.appendAssumeCapacity(duped);
        }
        const exact = copied.toOwnedSlice(self.gpa) catch {
            for (copied.items) |a| freeOwnedAnime(self.gpa, a);
            copied.deinit(self.gpa);
            self.gpa.free(q_copy);
            return;
        };

        self.enrich_thread = std.Thread.spawn(.{}, enrichTask, .{
            loop, self.gpa, io, exact, q_copy, offset, &self.enrich_cancel,
        }) catch {
            for (exact) |a| freeOwnedAnime(self.gpa, a);
            self.gpa.free(exact);
            self.gpa.free(q_copy);
            return;
        };
    }

    fn freeEpisodeResults(self: *App) void {
        if (self.episode_results) |eps| {
            for (eps) |ep| self.gpa.free(ep.raw);
            self.gpa.free(eps);
            self.episode_results = null;
        }
        if (self.detail_for_id) |id| {
            self.gpa.free(id);
            self.detail_for_id = null;
        }
    }

    fn setHistory(self: *App, recs: []AnimeRecord) void {
        self.history = recs;
        self.history_loading = false;
        // Clamp against filtered len so an active filter can't leave the cursor
        // pointing past the visible range when history reloads.
        const cap = self.filteredHistoryLen();
        if (self.list_cursor >= cap) self.list_cursor = if (cap == 0) 0 else cap - 1;
    }

    fn hydrateAnimeFromRecord(self: *App, a: *Anime, rec: AnimeRecord) void {
        if (a.english_name == null) a.english_name = dupeOptText(self.gpa, rec.title_english) catch a.english_name;
        if (a.thumb == null) a.thumb = dupeOptText(self.gpa, rec.cover_url) catch a.thumb;
        if (a.status == null) a.status = dupeOptText(self.gpa, rec.status) catch a.status;
        if (a.description == null) a.description = dupeOptText(self.gpa, rec.description) catch a.description;
        if (a.anilist_id == null) a.anilist_id = if (rec.anilist_id) |x| std.math.cast(u64, x) else null;
        if (a.mal_id == null) a.mal_id = if (rec.mal_id) |x| std.math.cast(u64, x) else null;
        if (a.total_episodes == null) a.total_episodes = if (rec.total_episodes) |x| std.math.cast(u32, x) else null;
        if (a.year == null) a.year = if (rec.year) |x| std.math.cast(u32, x) else null;
        if (a.score == null) a.score = if (rec.score) |x| std.math.cast(u32, x) else null;
    }

    fn hydrateResultsFromStore(self: *App, source_name: []const u8, offset: usize, count: usize) void {
        const st = self.store orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();

        const end = @min(self.results.items.len, offset + count);
        var i = offset;
        while (i < end) : (i += 1) {
            const source_id = self.results.items[i].id;
            const rec = st.getAnime(arena.allocator(), source_name, source_id) catch null orelse continue;
            self.hydrateAnimeFromRecord(&self.results.items[i], rec);
        }
    }

    fn persistResults(self: *App, source_name: []const u8, offset: usize, count: usize) void {
        const st = self.store orelse return;
        const end = @min(self.results.items.len, offset + count);
        var i = offset;
        while (i < end) : (i += 1) {
            st.upsertAnime(AnimeRecord.fromDomain(source_name, self.results.items[i], self.translation), Store.nowSecs()) catch {};
        }
    }

    // ── tick: fold one event into state ──────────────────────────────────────
    fn tick(self: *App, event: Event, loop: *Loop, io: std.Io, provider: SourceProvider) !void {
        switch (event) {
            .key_press => |key| self.onKey(key, loop, io, provider),
            .winsize => {}, // screen resize is handled in run()'s loop (it owns vx).
            .focus_in, .focus_out => {},
            .history_loaded => |recs| self.setHistory(recs),
            .task_error => |msg| {
                self.load_error = msg;
                self.history_loading = false;
                self.search_loading = false;
                self.debounce_deadline_ms = 0;
                self.async_start_ms = 0;
                self.pushToast(.@"error", msg, true);
            },
            .search_done => |ev| {
                // Stale check: ignore if query has changed since this search was fired.
                if (!std.mem.eql(u8, ev.for_query, self.querySlice())) {
                    for (ev.results) |r| freeOwnedAnime(self.gpa, r);
                    self.gpa.free(ev.for_query);
                    self.gpa.free(ev.results);
                    return;
                }
                self.search_loading = false;
                self.async_start_ms = 0;
                // Clear persistent search-error toasts on a good result.
                for (&self.toast_queue) |*slot| {
                    if (slot.*) |t| {
                        if (t.persistent and t.kind == .@"error") slot.* = null;
                    }
                }
                if (ev.page == 1) {
                    self.clearResults(); // free old data
                }
                const offset = self.results.items.len;
                self.search_page = ev.page;
                // Take ownership: append results into self.results, which already holds
                // old page(s) for page > 1. The strings are already gpa-owned.
                self.results.appendSlice(self.gpa, ev.results) catch {};
                self.gpa.free(ev.results);
                self.gpa.free(ev.for_query);
                // Reset cursor to top on fresh search.
                if (ev.page == 1) {
                    self.list_cursor = 0;
                    self.list_top = 0;
                }
                const added = self.results.items.len - offset;
                const source_name = provider.name();
                self.hydrateResultsFromStore(source_name, offset, added);
                self.persistResults(source_name, offset, added);
                self.fireEnrich(loop, io, offset, added);
            },
            .search_enriched => |ev| {
                if (!std.mem.eql(u8, ev.for_query, self.querySlice())) {
                    for (ev.results) |r| freeOwnedAnime(self.gpa, r);
                    self.gpa.free(ev.results);
                    self.gpa.free(ev.for_query);
                    return;
                }
                const source_name = provider.name();
                for (ev.results) |enriched| {
                    var replaced = false;
                    for (self.results.items[ev.offset..@min(self.results.items.len, ev.offset + ev.results.len)]) |*live| {
                        if (std.mem.eql(u8, live.id, enriched.id)) {
                            freeOwnedAnime(self.gpa, live.*);
                            live.* = enriched;
                            replaced = true;
                            break;
                        }
                    }
                    if (!replaced) freeOwnedAnime(self.gpa, enriched);
                }
                self.gpa.free(ev.results);
                self.gpa.free(ev.for_query);
                self.persistResults(source_name, ev.offset, ev.results.len);
            },
            .episodes_done => |ev| {
                defer self.gpa.free(ev.for_id);
                // Stale: discard if not for the current detail show.
                if (self.detail_for_id == null or !std.mem.eql(u8, ev.for_id, self.detail_for_id.?)) {
                    for (ev.episodes) |ep| self.gpa.free(ep.raw);
                    self.gpa.free(ev.episodes);
                    return;
                }
                self.episode_loading = false;
                self.async_start_ms = 0;
                // Free any old results (fireEpisodes clears them, but be defensive).
                if (self.episode_results) |old| {
                    for (old) |ep| self.gpa.free(ep.raw);
                    self.gpa.free(old);
                }
                self.episode_results = ev.episodes;
                self.episode_cursor = 0;
            },
            .episodes_error => {
                self.episode_loading = false;
                self.async_start_ms = 0;
            },
            .play_done, .play_error => {
                self.playing = false;
                self.async_start_ms = 0;
            },
            .tick => {
                const now = nowMs(io);
                self.now_ms = now;
                self.spinner_frame = (self.spinner_frame + 1) % 10;
                if (self.debounce_deadline_ms > 0 and now >= self.debounce_deadline_ms) {
                    self.debounce_deadline_ms = 0;
                    self.clearResults();
                    self.fireSearch(loop, io, provider, 1);
                }
                for (&self.toast_queue) |*slot| {
                    if (slot.*) |*t| {
                        if (!t.persistent) {
                            t.ttl_ms -= 100;
                            if (t.ttl_ms <= 0) slot.* = null;
                        }
                    }
                }
            },
        }
    }

    fn fireSearch(self: *App, loop: *Loop, io: std.Io, provider: SourceProvider, page: u32) void {
        const q = self.querySlice();
        if (q.len == 0) return;
        // Join any previous search thread before spawning a new one. This bounds
        // concurrent threads to 1 and prevents `loop`/`gpa` use-after-free on quit.
        // At ~1s per request, rapid typing may block briefly here — a cancellation
        // token is future scope (ROD-76+).
        if (self.search_thread) |t| {
            t.join();
            self.search_thread = null;
        }
        const q_copy = self.gpa.dupe(u8, q) catch return;
        self.search_loading = true;
        self.async_start_ms = self.now_ms;
        self.search_thread = std.Thread.spawn(.{}, searchTask, .{
            loop, self.gpa, io, provider, q_copy, page, self.translation,
        }) catch {
            self.gpa.free(q_copy);
            self.search_loading = false;
            return;
        };
    }

    fn fireEpisodes(self: *App, loop: *Loop, io: std.Io, provider: SourceProvider) void {
        if (self.results.items.len == 0 or self.list_cursor >= self.results.items.len) return;
        const selected = self.results.items[self.list_cursor];

        if (self.episode_thread) |t| { t.join(); self.episode_thread = null; }

        self.freeEpisodeResults();
        self.episode_loading = true;
        self.episode_cursor = 0;
        self.async_start_ms = self.now_ms;

        // Two GPA-duped copies: one for App.detail_for_id, one for the task (→ event).
        const id_for_app = self.gpa.dupe(u8, selected.id) catch return;
        const id_for_task = self.gpa.dupe(u8, selected.id) catch {
            self.gpa.free(id_for_app);
            return;
        };
        self.detail_for_id = id_for_app;

        self.episode_thread = std.Thread.spawn(.{}, episodesTask, .{
            loop, self.gpa, io, provider, id_for_task, self.translation,
        }) catch {
            self.gpa.free(id_for_task);
            self.episode_loading = false;
            return;
        };
    }

    fn firePlay(self: *App, loop: *Loop, io: std.Io, provider: SourceProvider) void {
        const eps = self.episode_results orelse return;
        if (eps.len == 0 or self.episode_cursor >= eps.len) return;
        if (self.playing) return;

        if (self.play_thread) |t| { t.join(); self.play_thread = null; }

        const selected_id = self.detail_for_id orelse return;
        const ep = eps[self.episode_cursor];

        const title_src: []const u8 = if (self.results.items.len > 0 and self.list_cursor < self.results.items.len)
            self.results.items[self.list_cursor].name
        else
            "zigoku";

        const id_copy = self.gpa.dupe(u8, selected_id) catch return;
        const ep_copy = self.gpa.dupe(u8, ep.raw) catch { self.gpa.free(id_copy); return; };
        const title_copy = self.gpa.dupe(u8, title_src) catch { self.gpa.free(id_copy); self.gpa.free(ep_copy); return; };

        self.play_thread = std.Thread.spawn(.{}, playTask, .{
            loop, self.gpa, io, provider, self.store, id_copy, ep_copy, self.translation, title_copy,
        }) catch {
            self.gpa.free(id_copy);
            self.gpa.free(ep_copy);
            self.gpa.free(title_copy);
            return;
        };
        self.playing = true;
        self.async_start_ms = self.now_ms;
    }

    fn onSearchKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io, provider: SourceProvider) void {
        // History view: local in-memory filter — no network calls.
        if (self.active_view == .history) {
            if (key.matches(vaxis.Key.escape, .{})) {
                self.history_filter_len = 0;
                self.list_cursor = 0;
                self.list_top = 0;
                self.input_mode = .normal;
            } else if (key.matches(vaxis.Key.enter, .{})) {
                self.input_mode = .normal;
            } else if (key.matches(vaxis.Key.backspace, .{})) {
                if (self.history_filter_len > 0) {
                    self.history_filter_len -= 1;
                    self.list_cursor = 0;
                    self.list_top = 0;
                }
            } else if (key.text) |text| {
                if (text.len > 0 and self.history_filter_len + text.len <= 127) {
                    @memcpy(self.history_filter[self.history_filter_len..][0..text.len], text);
                    self.history_filter_len += text.len;
                    self.list_cursor = 0;
                    self.list_top = 0;
                }
            }
            return;
        }

        // Esc: clear query + any pending debounce, return to normal mode.
        if (key.matches(vaxis.Key.escape, .{})) {
            self.search_len = 0;
            self.clearResults();
            self.search_loading = false;
            self.debounce_deadline_ms = 0;
            self.input_mode = .normal;
            return;
        }
        // Enter: bypass debounce — fire immediately if pending, then lock results.
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.debounce_deadline_ms > 0 and self.search_len > 0) {
                self.debounce_deadline_ms = 0;
                self.clearResults();
                self.fireSearch(loop, io, provider, 1);
            }
            self.input_mode = .normal;
            return;
        }
        // Backspace: pop last char, schedule re-search via debounce.
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.search_len > 0) {
                self.search_len -= 1;
                if (self.search_len == 0) {
                    self.clearResults();
                    self.search_loading = false;
                    self.debounce_deadline_ms = 0;
                } else {
                    self.debounce_deadline_ms = nowMs(io) + 300;
                }
            }
            return;
        }
        // Printable: append and arm debounce — don't fire immediately.
        if (key.text) |text| {
            if (text.len > 0 and self.search_len + text.len <= 127) {
                @memcpy(self.search_query[self.search_len..][0..text.len], text);
                self.search_len += text.len;
                self.debounce_deadline_ms = nowMs(io) + 300;
            }
        }
    }

    fn onKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io, provider: SourceProvider) void {
        // q key behavior by view (§10.6).
        if (key.matches('q', .{})) {
            switch (self.active_view) {
                .browse => self.should_quit = true,
                .history, .settings => {
                    self.active_view = .browse;
                    self.active_pane = .list;
                },
            }
            return;
        }

        // Ctrl-C quit (unchanged from before).
        if (key.matches('c', .{ .ctrl = true })) {
            self.should_quit = true;
            return;
        }

        // View switching — F-keys (discoverable, §10.2) and H/S (vim-native, §6.1).
        // F2 = "go to History" — no-op if already there (spec §10.2 F2 from History).
        // H = toggle Browse ↔ History (distinct from F2, per Elara H1/M2 fixes).
        if (key.matches(vaxis.Key.f2, .{})) {
            if (self.active_view != .history) {
                self.active_view = .history;
                self.active_pane = .list;
                self.list_cursor = 0;
                self.list_top = 0;
            }
            return;
        }
        if (key.matches('H', .{ .shift = true }) or key.matches('H', .{})) {
            self.active_view = if (self.active_view == .history) .browse else .history;
            self.active_pane = .list;
            self.list_cursor = 0;
            self.list_top = 0;
            return;
        }
        if (key.matches(vaxis.Key.f3, .{}) or
            key.matches('S', .{ .shift = true }) or key.matches('S', .{}))
        {
            if (self.active_view != .settings) {
                self.active_view = .settings;
                self.active_pane = .list;
                self.list_cursor = 0;
                self.list_top = 0;
            }
            return;
        }
        // F1 = "go to Browse" — no-op if already there (spec §10.2 F1 from Browse).
        if (key.matches(vaxis.Key.f1, .{})) {
            if (self.active_view != .browse) {
                self.active_view = .browse;
                self.active_pane = .list;
                self.list_cursor = 0;
                self.list_top = 0;
            }
            return;
        }

        // h / l pane switching (Browse only) (§10.3c).
        if (key.matches('h', .{})) {
            if (self.active_view == .browse and self.active_pane == .detail) {
                self.active_pane = .list;
            }
            return;
        }
        // Enter is only handled here in normal mode. In search mode it must fall
        // through to the search mode check below so onSearchKey can lock the results.
        if (self.input_mode == .normal and (key.matches('l', .{}) or key.matches(vaxis.Key.enter, .{}))) {
            if (self.active_view == .browse) {
                if (self.active_pane == .list and self.results.items.len > 0) {
                    self.active_pane = .detail;
                    self.fireEpisodes(loop, io, provider);
                } else if (self.active_pane == .detail) {
                    // Enter on episode in detail pane: play
                    if (key.matches(vaxis.Key.enter, .{})) {
                        self.firePlay(loop, io, provider);
                    }
                    // l in detail: no-op (already rightmost)
                }
            }
            return;
        }

        // Search mode intercepts all keys (including Esc) before the view chain.
        // Esc in search mode clears the query; Esc in normal mode runs the view chain.
        if (self.input_mode == .search) {
            self.onSearchKey(key, loop, io, provider);
            return;
        }

        // Esc chain (§10.4): only reached in normal mode.
        if (key.matches(vaxis.Key.escape, .{})) {
            if (self.active_view == .browse and self.active_pane == .detail) {
                self.active_pane = .list;
            } else if (self.active_view == .history or self.active_view == .settings) {
                self.active_view = .browse;
                self.active_pane = .list;
            }
            // Browse + list + normal: no-op. q handles quit.
            return;
        }

        // Normal mode — view-gated navigation.
        // '/' enters search/filter mode in Browse and History.
        if (key.matches('/', .{})) {
            if (self.active_view == .browse or self.active_view == .history) {
                self.input_mode = .search;
            }
            return;
        }

        // In detail pane: j/k/g/G navigate the episode grid.
        if (self.active_view == .browse and self.active_pane == .detail) {
            const ep_len: usize = if (self.episode_results) |eps| eps.len else 0;
            if (ep_len == 0) return;
            if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                if (self.episode_cursor + 1 < ep_len) self.episode_cursor += 1;
            } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                if (self.episode_cursor > 0) self.episode_cursor -= 1;
            } else if (key.matches('g', .{})) {
                self.episode_cursor = 0;
            } else if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) {
                self.episode_cursor = ep_len - 1;
            }
            return;
        }

        // List navigation (history + browse list pane).
        const nav_len: usize = switch (self.active_view) {
            .history => self.filteredHistoryLen(),
            .browse => self.results.items.len,
            .settings => return,
        };
        if (nav_len == 0) return;

        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (self.list_cursor + 1 < nav_len) self.list_cursor += 1;
        } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.list_cursor > 0) self.list_cursor -= 1;
        } else if (key.matches('g', .{})) {
            self.list_cursor = 0;
        } else if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) {
            self.list_cursor = nav_len - 1;
        }
        // Load-more: at last result + j, trigger page+1 if possible.
        if (key.matches('j', .{}) and
            self.active_view == .browse and
            self.list_cursor == nav_len - 1 and
            self.search_page > 0 and
            nav_len % 26 == 0 and
            !self.search_loading)
        {
            self.fireSearch(loop, io, provider, self.search_page + 1);
        }
    }

    // ── draw: pure render from state ─────────────────────────────────────────
    fn draw(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer) !void {
        const win = vx.window();
        win.clear();
        win.fill(.{ .style = .{ .bg = colors.bg_base } });

        const w = win.width;
        const h = win.height;
        if (h < 4 or w < 16) {
            // Too small to lay out — just say so.
            put(win, 0, 0, "terminal too small", style(colors.warn, .{}));
            try vx.render(writer);
            return;
        }

        self.drawTopBar(win, w);
        self.drawContent(win, h);
        self.drawToasts(win, h);
        self.drawBottomBar(win, h);

        try vx.render(writer);
    }

    /// §3.4: the top bar is read-only context, not navigation — `地獄 zigoku`
    /// as one primary H1 unit, then a hairline separator. No tabs here: the tab
    /// system + focus model is ROD-72 and needs a designed home (the active-tab
    /// cyan would collide with the focus color if it lived in this bar).
    fn drawTopBar(self: *App, win: vaxis.Window, w: u16) void {
        put(win, 0, 2, "地獄 zigoku", style(colors.fg, .{ .bold = true }));
        if (w > 16) put(win, 0, 14, "░", style(colors.chrome, .{}));

        // Render the chip after the separator (§10.3b).
        const chip_col: u16 = 16;
        const chip: []const u8 = switch (self.active_view) {
            .history => "Watchlist",
            .settings => "Settings",
            .browse => std.fmt.bufPrint(&self.chip_buf, "{s} search", .{self.spinnerChar()}) catch "⠋ search",
        };
        put(win, 0, chip_col, chip, style(colors.focus, .{}));

        // Render the · indicator right-aligned (§10.3b).
        const dot_color = switch (self.active_view) {
            .browse => if (self.active_pane == .detail) colors.focus else colors.fg3,
            .history, .settings => colors.focus,
        };
        if (w > 2) put(win, 0, w - 2, "·", style(dot_color, .{}));
    }

    fn drawContent(self: *App, win: vaxis.Window, h: u16) void {
        // Row 0 is the top bar; row 1 is intentional breathing room; content
        // starts at row 2 and runs to h-2; the bottom bar owns h-1.
        const top: u16 = 2;
        const visible: u16 = h - 3;
        const body_w: u16 = if (win.width > 2) win.width - 2 else 0;

        const w = win.width;

        switch (self.active_view) {
            .history => {
                // History view — existing list rendering.
                if (self.history_loading) {
                    const hist_spin = std.fmt.bufPrint(&self.no_results_buf, "{s} loading history", .{self.spinnerChar()}) catch "⠋ loading history";
                    putClipped(win, top, 2, body_w, hist_spin, style(colors.focus, .{}));
                    return;
                }
                if (self.load_error) |msg| {
                    // Hard failure → magenta (state.error = state.now, §1.1).
                    put(win, top, 2, "history unavailable", style(colors.hot, .{ .bold = true }));
                    putClipped(win, top + 1, 2, body_w, msg, style(colors.fg3, .{}));
                    return;
                }
                if (self.history.len == 0) {
                    // First-run empty state (§9.2): the void, one quiet line, one
                    // invitation — both centered. `/` wires up in ROD-73.
                    const mid = top + visible / 2;
                    centerText(win, mid -| 1, w, "nothing here yet", style(colors.fg3, .{ .italic = true }));
                    const action = " to search for a show";
                    const total: u16 = 1 + @as(u16, @intCast(action.len));
                    const start: u16 = if (w > total) (w - total) / 2 else 0;
                    put(win, mid + 1, start, "/", style(colors.focus, .{ .bold = true }));
                    putClipped(win, mid + 1, start + 1, w -| (start + 1), action, style(colors.fg2, .{}));
                    return;
                }

                // Each history entry occupies 2 rows (title + progress bar).
                // @max(1, ...) guards against visible=1 producing a zero slot count
                // which would corrupt list_top via scrollIntoView's arithmetic.
                self.scrollIntoView(@max(1, visible / 2));

                // Meta only earns its column when the terminal is wide enough to hold it
                // without colliding the title — otherwise the title takes the full width.
                const show_meta = w >= meta_col + 12;
                const title_right: u16 = if (show_meta) meta_col - title_meta_gap else w;
                const title_w: u16 = if (title_right > title_col) title_right - title_col else 0;
                // Bar width: clamp to [16, 24] columns — saturating sub avoids underflow.
                const bar_w: u16 = @min(24, @max(16, w -| 20));

                var row: u16 = top;
                var slot: usize = 0;
                var visible_i: usize = 0;
                var i: usize = 0;
                while (i < self.history.len) : (i += 1) {
                    const rec = self.history[i];
                    if (!self.historyEntryVisible(rec.title)) continue;
                    if (visible_i < self.list_top) { visible_i += 1; continue; }
                    if (row + 1 >= top + visible) break;

                    const selected = visible_i == self.list_cursor;

                    // §4.1 focus affordance: the focused row's background shifts to
                    // bg.surface (a full-width band), its marker is the ▸ play glyph in
                    // focus cyan, and its title goes cyan+bold. Magenta is reserved for
                    // the one cursor in the status bar — never a list marker (§8).
                    const row_bg = if (selected) colors.bg_surface else colors.bg_base;
                    if (selected) {
                        fillRow(win, row, w, colors.bg_surface);
                        fillRow(win, row + 1, w, colors.bg_surface);
                    }

                    const marker = if (selected) "▸ " else "  ";
                    put(win, row, 2, marker, style(colors.focus, .{ .bg = row_bg }));

                    const title_style = if (selected)
                        style(colors.focus, .{ .bg = row_bg, .bold = true })
                    else
                        style(colors.fg, .{ .bg = row_bg });
                    putClipped(win, row, title_col, title_w, rec.title, title_style);

                    if (show_meta and slot < self.meta_scratch.len) {
                        const meta = formatMeta(&self.meta_scratch[slot], rec);
                        putClipped(win, row, meta_col, w - meta_col, meta, style(colors.fg3, .{ .bg = row_bg }));
                    }

                    // Row 2: §4.5 progress bar (inherits row_bg for the focus band).
                    if (slot < self.bar_scratch.len) {
                        drawProgressBar(win, row + 1, title_col, bar_w, rec, row_bg, &self.bar_scratch[slot]);
                    }

                    slot += 1;
                    row += 2;
                    visible_i += 1;
                }
            },

            .browse => {
                const list_w: u16 = @max(30, (w * 38) / 100);
                const detail_x: u16 = 2 + list_w + 2;
                const detail_w: u16 = if (w > detail_x + 1) w - detail_x - 1 else 0;
                const pane_h: u16 = visible;

                const list_win = win.child(.{ .x_off = 2, .y_off = top, .width = list_w, .height = pane_h });
                const detail_win = win.child(.{ .x_off = @intCast(detail_x), .y_off = top, .width = detail_w, .height = pane_h });

                self.drawBrowseList(list_win, pane_h, list_w);
                self.drawDetailPane(detail_win, detail_w, pane_h);
            },

            .settings => {
                // Settings stub (ROD-75/76 territory).
                const mid = top + visible / 2;
                centerText(win, mid, w, "settings — coming soon", style(colors.fg3, .{ .italic = true }));
            },
        }
    }

    fn drawBrowseList(self: *App, win: vaxis.Window, pane_h: u16, pane_w: u16) void {
        const w = pane_w;
        if (self.search_len == 0) {
            const mid = pane_h / 2;
            centerText(win, mid -| 1, w, "no feed yet", style(colors.fg3, .{ .italic = true }));
            const action = " to start a search";
            const total: u16 = 1 + @as(u16, @intCast(action.len));
            const start: u16 = if (w > total) (w - total) / 2 else 0;
            put(win, mid + 1, start, "/", style(colors.focus, .{ .bold = true }));
            putClipped(win, mid + 1, start + 1, w -| (start + 1), action, style(colors.fg2, .{}));
            return;
        }
        const search_pending = self.search_loading or self.debounce_deadline_ms > 0;
        if (search_pending and self.results.items.len == 0) {
            const spin_msg = std.fmt.bufPrint(&self.no_results_buf, "{s} searching\u{2026}", .{self.spinnerChar()}) catch "⠋ searching\u{2026}";
            centerText(win, pane_h / 2, w, spin_msg, style(colors.focus, .{}));
            return;
        }
        if (!search_pending and self.results.items.len == 0) {
            const q = self.querySlice();
            const msg = std.fmt.bufPrint(&self.no_results_buf, "no results for \"{s}\"", .{q}) catch "no results";
            putClipped(win, 0, 0, w, msg, style(colors.fg3, .{ .italic = true }));
            return;
        }

        // Results list — col offsets relative to list_win (no x=2 leading margin).
        const list_title_col: u16 = 2; // marker is col 0–1, title starts at 2
        self.scrollIntoView(pane_h);

        var row: u16 = 0;
        var slot: usize = 0;
        var i: usize = self.list_top;
        while (i < self.results.items.len and row < pane_h) : (i += 1) {
            const a = self.results.items[i];
            const selected = i == self.list_cursor;

            const row_bg = if (selected) colors.bg_surface else colors.bg_base;
            if (selected) fillRow(win, row, w, colors.bg_surface);

            const marker = if (selected) "▸ " else "  ";
            put(win, row, 0, marker, style(colors.focus, .{ .bg = row_bg }));

            const title_style = if (selected)
                style(colors.focus, .{ .bg = row_bg, .bold = true })
            else
                style(colors.fg, .{ .bg = row_bg });
            // Meta (eps) if pane is wide enough — rarely true in split view.
            const list_meta_col: u16 = 46;
            const show_list_meta = w >= list_meta_col + 8;
            // Title clips short enough to leave room for the meta column. The 2-char
            // gap (title_meta_gap) prevents the last title char from touching the first
            // meta char. Without this guard the title fills the full pane width and
            // its tail bleeds through the meta text (vaxis writes cells; later write wins).
            const title_w: u16 = if (show_list_meta)
                list_meta_col -| list_title_col -| 2
            else if (w > list_title_col) w - list_title_col else 0;
            putClipped(win, row, list_title_col, title_w, a.name, title_style);

            if (show_list_meta and slot < self.meta_scratch.len) {
                const tt = self.translation;
                const eps = if (tt == .dub) a.eps_dub else a.eps_sub;
                const meta = std.fmt.bufPrint(&self.meta_scratch[slot], "{d} {s}", .{ eps, tt.str() }) catch "";
                putClipped(win, row, list_meta_col, w - list_meta_col, meta, style(colors.fg3, .{ .bg = row_bg }));
                slot += 1;
            }
            row += 1;
        }

        // Load-more footer.
        if (row < pane_h and
            self.search_page > 0 and
            self.results.items.len % 26 == 0 and
            self.results.items.len > 0)
        {
            const footer = if (self.search_loading) "⠋ loading…" else "╌ more ╌";
            const footer_color = if (self.search_loading) colors.focus else colors.fg3;
            centerText(win, row, w, footer, style(footer_color, .{}));
        }
    }

    fn drawDetailPane(self: *App, win: vaxis.Window, w: u16, h: u16) void {
        if (w < 10) return;

        var row: u16 = 0;

        // Cover art block (§3.3 + §9.1): always "no art yet" in M3.
        // 20×28 at ≥100 total terminal cols, 14×20 at 80–99, hidden below 80.
        const cover_w: u16 = if (w >= 60) 20 else if (w >= 40) 14 else 0;
        const cover_h: u16 = if (w >= 60) 7 else if (w >= 40) 5 else 0;
        if (cover_w > 0 and cover_h > 0) {
            const cover_win = win.child(.{ .x_off = 0, .y_off = row, .width = cover_w, .height = cover_h });
            cover_win.fill(.{ .style = .{ .bg = colors.bg_surface } });
            if (cover_h > 1) {
                centerText(cover_win, cover_h / 2, cover_w, "no art yet", style(colors.fg3, .{ .italic = true }));
            }
            row += cover_h + 1;
        }

        const anime: ?Anime = if (self.results.items.len > 0 and self.list_cursor < self.results.items.len)
            self.results.items[self.list_cursor]
        else
            null;

        // Title — the selected result's name, or placeholder.
        const title: []const u8 = if (anime) |a| a.name else "";
        if (title.len > 0) {
            putClipped(win, row, 0, w, title, style(colors.fg, .{ .bold = true }));
        } else {
            putClipped(win, row, 0, w, "—", style(colors.fg3, .{}));
        }
        row += 1;

        // Score — placeholder until enrichment lands, then the real AniList score.
        const score_text: []const u8 = if (anime) |a| blk: {
            if (a.score) |score| {
                break :blk std.fmt.bufPrint(&self.detail_meta_buf, "[{d}/100]", .{score}) catch "[--/100]";
            }
            break :blk "[--/100]";
        } else "[--/100]";
        putClipped(win, row, 0, w, score_text, style(colors.fg3, .{}));
        row += 1;

        // Hairline.
        if (row < h) {
            _ = win.printSegment(.{ .text = "─" ** 160, .style = .{ .fg = colors.chrome, .bg = colors.bg_base } }, .{ .row_offset = row });
        }
        row += 1;

        // Metadata: episode count, falling back to AniList total when needed.
        if (row < h) {
            const meta: []const u8 = if (anime) |a| blk: {
                const eps = a.episodeCount(self.translation);
                if (eps > 0) break :blk std.fmt.bufPrint(&self.detail_meta_buf, "{d} eps", .{eps}) catch "? eps";
                if (a.total_episodes) |total| break :blk std.fmt.bufPrint(&self.detail_meta_buf, "{d} eps", .{total}) catch "? eps";
                break :blk "? eps";
            } else "? eps";
            const meta_style = if (anime) |a|
                if (a.episodeCount(self.translation) > 0 or a.total_episodes != null) style(colors.fg2, .{}) else style(colors.fg3, .{})
            else
                style(colors.fg3, .{});
            putClipped(win, row, 0, w, meta, meta_style);
            row += 1;
        }

        // Synopsis: real metadata when present, otherwise the existing stub.
        if (row < h) {
            if (anime) |a| {
                if (a.description) |desc| {
                    row += drawWrappedText(win, row, 0, w, h - row, desc, style(colors.fg2, .{}));
                } else {
                    putClipped(win, row, 0, w, "no synopsis yet", style(colors.fg2, .{ .italic = true }));
                    row += 1;
                }
            } else {
                putClipped(win, row, 0, w, "no synopsis yet", style(colors.fg2, .{ .italic = true }));
                row += 1;
            }
        }

        if (row < h) row += 1; // blank line before grid

        // Episode grid.
        if (row >= h) return;
        const grid_h: u16 = h - row;
        const grid_win = win.child(.{ .x_off = 0, .y_off = row, .width = w, .height = grid_h });
        self.drawEpisodeGrid(grid_win, w, grid_h);
    }

    fn drawEpisodeGrid(self: *App, win: vaxis.Window, w: u16, h: u16) void {
        if (self.episode_loading) {
            centerText(win, 0, w, "⠋ loading episodes…", style(colors.focus, .{}));
            return;
        }
        const eps = self.episode_results orelse {
            // No fetch fired yet (detail pane opened but no item selected).
            return;
        };
        if (eps.len == 0) {
            putClipped(win, 0, 0, w, "no episodes", style(colors.fg3, .{ .italic = true }));
            return;
        }

        // Each cell is 5 chars wide: "[NN] " or "[NNN]" — allocate 5 per cell.
        const cell_w: u16 = 5;
        const cols: u16 = @max(1, w / cell_w);

        // Scroll so that episode_cursor is in view.
        const cursor_row: usize = self.episode_cursor / cols;
        const viewport_rows: usize = h;
        const view_top: usize = if (cursor_row >= viewport_rows)
            cursor_row + 1 - viewport_rows
        else
            0;

        var grid_row: u16 = 0;
        var ep_idx: usize = view_top * cols;
        while (grid_row < h and ep_idx < eps.len) : (grid_row += 1) {
            var col_off: u16 = 0;
            var c: u16 = 0;
            while (c < cols and ep_idx < eps.len) : (c += 1) {
                const ep = eps[ep_idx];
                const focused = ep_idx == self.episode_cursor and self.active_pane == .detail;

                // Use ep_scratch to avoid dangling stack buffers. Index relative
                // to the viewport start so we never alias two live cells.
                const slot = (ep_idx - view_top * cols) % 512;
                const cell_buf = &self.ep_scratch[slot];
                const cell_text = std.fmt.bufPrint(cell_buf, "[{s}]", .{ep.raw}) catch "[?]";

                const cell_style = if (focused)
                    style(colors.focus, .{ .bg = colors.bg_surface, .bold = true })
                else
                    style(colors.fg2, .{});

                if (focused) {
                    const cell_win = win.child(.{
                        .x_off = @intCast(col_off),
                        .y_off = @intCast(grid_row),
                        .width = cell_w,
                        .height = 1,
                    });
                    cell_win.fill(.{ .style = .{ .bg = colors.bg_surface } });
                    _ = cell_win.printSegment(.{ .text = cell_text, .style = cell_style }, .{});
                } else {
                    putClipped(win, grid_row, col_off, cell_w, cell_text, cell_style);
                }

                col_off += cell_w;
                ep_idx += 1;
            }
        }
    }

    fn drawBottomBar(self: *App, win: vaxis.Window, h: u16) void {
        const w = win.width;
        const row = h - 1;

        // Search mode in Browse: suppress ▌, show /query_ + count.
        if (self.active_view == .browse and self.input_mode == .search) {
            const q = self.querySlice();
            put(win, row, 2, "/", style(colors.focus, .{ .bold = true }));
            const cursor_col: u16 = 3 + @as(u16, @intCast(q.len));
            if (q.len > 0) {
                putClipped(win, row, 3, cursor_col -| 3, q, style(colors.fg, .{ .bold = true }));
            }
            if (cursor_col < w) put(win, row, cursor_col, "_", style(colors.focus, .{ .bold = true }));
            // Right-aligned count (text.muted = fg2 per §3.5).
            const cnt: []const u8 = if ((self.search_loading or self.debounce_deadline_ms > 0) and self.results.items.len == 0)
                "…"
            else if (self.results.items.len > 0)
                std.fmt.bufPrint(&self.cnt_scratch, "[{d}]", .{self.results.items.len}) catch ""
            else if (self.search_len > 0)
                "[0 results]"
            else
                "";
            if (cnt.len > 0) {
                const cnt_col: u16 = if (w > @as(u16, @intCast(cnt.len)) + 1) w - @as(u16, @intCast(cnt.len)) - 1 else 0;
                // Overlap guard: suppress count if it would collide with the cursor.
                if (cnt_col > cursor_col + 1) {
                    putClipped(win, row, cnt_col, @as(u16, @intCast(cnt.len)), cnt, style(colors.fg2, .{}));
                }
            }
            return;
        }

        // Search mode in History: suppress ▌, show /filter_ + filtered count.
        if (self.active_view == .history and self.input_mode == .search) {
            const q = self.history_filter[0..self.history_filter_len];
            put(win, row, 2, "/", style(colors.focus, .{ .bold = true }));
            const cursor_col: u16 = 3 + @as(u16, @intCast(q.len));
            if (q.len > 0) {
                putClipped(win, row, 3, cursor_col -| 3, q, style(colors.fg, .{ .bold = true }));
            }
            if (cursor_col < w) put(win, row, cursor_col, "_", style(colors.focus, .{ .bold = true }));
            const n = self.filteredHistoryLen();
            const cnt: []const u8 = if (q.len == 0)
                ""
            else if (n > 0)
                std.fmt.bufPrint(&self.cnt_scratch, "[{d}]", .{n}) catch ""
            else
                "[0]";
            if (cnt.len > 0) {
                const cnt_col: u16 = if (w > @as(u16, @intCast(cnt.len)) + 1) w - @as(u16, @intCast(cnt.len)) - 1 else 0;
                if (cnt_col > cursor_col + 1) {
                    putClipped(win, row, cnt_col, @as(u16, @intCast(cnt.len)), cnt, style(colors.fg2, .{}));
                }
            }
            return;
        }

        // When anything is loading, replace the ▌ with an animated spinner.
        const any_loading = self.search_loading or self.history_loading or
            self.episode_loading or self.debounce_deadline_ms > 0;
        if (any_loading) {
            const spin_color: vaxis.Color = if (self.async_start_ms > 0 and
                self.now_ms - self.async_start_ms > 3000)
                colors.hot
            else
                colors.focus;
            put(win, row, 2, self.spinnerChar(), style(spin_color, .{}));
        } else {
            put(win, row, 2, "▌", style(colors.hot, .{ .blink = true }));
        }

        const help: []const u8 = switch (self.active_view) {
            .browse => switch (self.active_pane) {
                .list => "hjkl · / search · F1/F2/F3 views · q quit",
                .detail => "hjkl scroll · h back · enter play · q back",
            },
            .history => if (self.history.len == 0)
                "/ search · F1 browse · q quit"
            else
                "jk move · enter open · F1 browse · F3 settings · q quit",
            .settings => "jk navigate · space toggle · enter edit · esc cancel · q back",
        };
        putClipped(win, row, 4, if (w > 4) w - 4 else 0, help, style(colors.fg3, .{}));
    }

    fn drawToasts(self: *App, win: vaxis.Window, h: u16) void {
        if (h < 4) return;
        var row: u16 = h -| 2;
        // Iterate newest-first (index 2→0) so the most recent toast anchors at h-2.
        var qi: usize = self.toast_queue.len;
        while (qi > 0) {
            qi -= 1;
            const t = self.toast_queue[qi] orelse continue;
            if (row < 1) break;
            const fg_color: vaxis.Color = switch (t.kind) {
                .@"error" => colors.hot,
                .warn => colors.warn,
                .info => colors.focus,
            };
            const prefix: []const u8 = switch (t.kind) {
                .@"error" => "[!] ",
                .warn => "[~] ",
                .info => "[·] ",
            };
            const w = win.width;
            // §4.7: right-aligned, max 40 display columns.
            const pre_len: u16 = @intCast(prefix.len);
            const txt_len: u16 = @intCast(t.text_len);
            const toast_w: u16 = @min(pre_len + txt_len, @min(40, w -| 2));
            const pre_col: u16 = if (w > toast_w + 1) w - toast_w - 1 else 0;
            fillRow(win, row, w, colors.bg_elevated);
            put(win, row, pre_col, prefix, style(fg_color, .{ .bold = true, .bg = colors.bg_elevated }));
            const txt_col: u16 = pre_col + pre_len;
            const txt_w: u16 = if (toast_w > pre_len) toast_w - pre_len else 0;
            putClipped(win, row, txt_col, txt_w, t.text[0..t.text_len],
                style(fg_color, .{ .bg = colors.bg_elevated }));
            row -|= 1;
        }
    }

    fn scrollIntoView(self: *App, visible: u16) void {
        const v: usize = visible;
        if (self.list_cursor < self.list_top) {
            self.list_top = self.list_cursor;
        } else if (self.list_cursor >= self.list_top + v) {
            self.list_top = self.list_cursor + 1 - v;
        }
    }

    fn historyEntryVisible(self: *const App, title: []const u8) bool {
        if (self.history_filter_len == 0) return true;
        return std.ascii.indexOfIgnoreCase(title, self.history_filter[0..self.history_filter_len]) != null;
    }

    fn filteredHistoryLen(self: *const App) usize {
        if (self.history_filter_len == 0) return self.history.len;
        var n: usize = 0;
        for (self.history) |rec| {
            if (self.historyEntryVisible(rec.title)) n += 1;
        }
        return n;
    }
};

/// "ep 3/12 · watching" — whatever we actually know. total_episodes can be null
/// (source didn't say), in which case we drop the denominator.
fn formatMeta(buf: []u8, rec: AnimeRecord) []const u8 {
    if (rec.total_episodes) |total| {
        return std.fmt.bufPrint(buf, "ep {d}/{d} · {s}", .{ rec.progress, total, rec.list_status }) catch rec.list_status;
    }
    return std.fmt.bufPrint(buf, "ep {d} · {s}", .{ rec.progress, rec.list_status }) catch rec.list_status;
}

// ── tiny render helpers ─────────────────────────────────────────────────────

/// §4.5 progress bar for a history row. `row_bg` is the row's background color
/// (bg.surface for the focused entry, bg.base otherwise). `frac_buf` must be
/// App-owned — vaxis holds a reference until the next render call.
fn drawProgressBar(win: vaxis.Window, row: u16, col: u16, bar_w: u16, rec: AnimeRecord, row_bg: vaxis.Color, frac_buf: []u8) void {
    const is_planning = std.mem.eql(u8, rec.list_status, "planning");
    const is_watching = std.mem.eql(u8, rec.list_status, "watching");
    const is_paused = std.mem.eql(u8, rec.list_status, "paused");

    const filled: u16 = if (is_planning) 0 else blk: {
        if (rec.total_episodes) |total| {
            if (total <= 0) break :blk if (rec.progress > 0) bar_w / 3 else 0;
            const bw: i64 = @intCast(bar_w);
            const f = @divTrunc(@max(0, rec.progress) * bw, total);
            break :blk @intCast(@min(bw, f));
        }
        break :blk if (rec.progress > 0) bar_w / 3 else 0;
    };

    const fill_color = if (is_watching or is_paused) colors.focus else colors.fg3;
    const frac_color = if (is_watching or is_paused) colors.fg2 else colors.fg3;

    put(win, row, col, "[", style(colors.fg3, .{ .bg = row_bg }));
    var c: u16 = 0;
    while (c < bar_w) : (c += 1) {
        if (c < filled) {
            put(win, row, col + 1 + c, "█", style(fill_color, .{ .bg = row_bg, .dim = is_paused }));
        } else {
            put(win, row, col + 1 + c, "░", style(colors.chrome, .{ .bg = row_bg }));
        }
    }
    put(win, row, col + 1 + bar_w, "]", style(colors.fg3, .{ .bg = row_bg }));

    const frac: []const u8 = if (rec.total_episodes) |total|
        std.fmt.bufPrint(frac_buf, "  {d} / {d} eps", .{ rec.progress, total }) catch ""
    else
        std.fmt.bufPrint(frac_buf, "  {d} / ? eps", .{ rec.progress }) catch "";
    put(win, row, col + 1 + bar_w + 1, frac, style(frac_color, .{ .bg = row_bg }));
}

fn put(win: vaxis.Window, row: u16, col: u16, text: []const u8, sty: vaxis.Style) void {
    _ = win.printSegment(.{ .text = text, .style = sty }, .{ .row_offset = row, .col_offset = col });
}

/// Like `put`, but clipped to `max_w` columns via a 1-row child window. The
/// child bounds stop a long string from bleeding past its column budget into a
/// neighbour (and the clip lands on a grapheme boundary, so multibyte titles
/// stay valid). max_w == 0 draws nothing.
fn putClipped(win: vaxis.Window, row: u16, col: u16, max_w: u16, text: []const u8, sty: vaxis.Style) void {
    if (max_w == 0) return;
    const child = win.child(.{ .x_off = @intCast(col), .y_off = @intCast(row), .width = max_w, .height = 1 });
    _ = child.printSegment(.{ .text = text, .style = sty }, .{});
}

/// Paint a full-width 1-row band in `bg` — the focused-row background shift.
fn fillRow(win: vaxis.Window, row: u16, w: u16, bg: vaxis.Color) void {
    const child = win.child(.{ .x_off = 0, .y_off = @intCast(row), .width = w, .height = 1 });
    child.fill(.{ .style = .{ .bg = bg } });
}

/// Horizontally centre an ASCII string on `row` (byte length == display width
/// for the ASCII copy this is used with).
fn centerText(win: vaxis.Window, row: u16, w: u16, text: []const u8, sty: vaxis.Style) void {
    const tw: u16 = @intCast(text.len);
    const col: u16 = if (w > tw) (w - tw) / 2 else 0;
    putClipped(win, row, col, w, text, sty);
}

fn drawWrappedText(win: vaxis.Window, start_row: u16, start_col: u16, max_w: u16, max_rows: u16, text: []const u8, sty: vaxis.Style) u16 {
    if (max_w == 0 or max_rows == 0 or text.len == 0) return 0;

    var row: u16 = 0;
    var i: usize = 0;
    while (i < text.len and row < max_rows) {
        const remaining = text[i..];
        if (remaining.len <= max_w) {
            putClipped(win, start_row + row, start_col, max_w, std.mem.trim(u8, remaining, " "), sty);
            return row + 1;
        }

        var cut: usize = max_w;
        while (cut > 0 and remaining[cut - 1] != ' ') : (cut -= 1) {}
        if (cut == 0) cut = max_w;

        const line = std.mem.trim(u8, remaining[0..cut], " ");
        putClipped(win, start_row + row, start_col, max_w, line, sty);
        row += 1;
        i += cut;
        while (i < text.len and text[i] == ' ') : (i += 1) {}
    }
    return row;
}

// History-row layout columns. The detail/responsive layout is ROD-72+; this is
// the fixed two-column (title | meta) skeleton.
const title_col: u16 = 4;
const meta_col: u16 = 48;
const title_meta_gap: u16 = 2;

// One style constructor for foreground-on-(void|surface) cells. bg defaults to
// the void so most call sites stay terse; the focused list row passes bg.surface
// to get §4.1's background shift.
fn style(fg: vaxis.Color, opts: struct {
    bg: vaxis.Color = colors.bg_base,
    bold: bool = false,
    italic: bool = false,
    blink: bool = false,
    dim: bool = false,
}) vaxis.Style {
    return .{ .fg = fg, .bg = opts.bg, .bold = opts.bold, .italic = opts.italic, .blink = opts.blink, .dim = opts.dim };
}

// ── tests: the App state machine (no tty needed) ────────────────────────────

const testing = std.testing;

fn keyEv(cp: u21, mods: vaxis.Key.Modifiers) Event {
    return .{ .key_press = .{ .codepoint = cp, .mods = mods } };
}

fn sampleHistory() [3]AnimeRecord {
    return .{
        .{ .source = "allanime", .source_id = "a", .title = "Frieren", .total_episodes = 28, .progress = 4 },
        .{ .source = "allanime", .source_id = "b", .title = "K-On!", .total_episodes = 13, .progress = 1 },
        .{ .source = "allanime", .source_id = "c", .title = "Bebop", .progress = 0 },
    };
}

fn dummySearchFn(_: *anyopaque, _: Allocator, _: std.Io, _: []const u8, _: source_mod.SearchOptions) anyerror![]Anime {
    return &.{};
}
fn dummyEpisodesFn(_: *anyopaque, _: Allocator, _: std.Io, _: []const u8, _: domain.Translation) anyerror![]domain.EpisodeNumber {
    return &.{};
}
fn dummyResolveFn(_: *anyopaque, _: Allocator, _: std.Io, _: []const u8, _: domain.EpisodeNumber, _: domain.Translation) anyerror!domain.StreamLink {
    return .{ .url = "" };
}

fn dummyNameFn(_: *anyopaque) []const u8 {
    return "allanime";
}

const dummy_vtable: SourceProvider.VTable = .{
    .name = dummyNameFn,
    .search = dummySearchFn,
    .episodes = dummyEpisodesFn,
    .resolve = dummyResolveFn,
};

fn dummyProvider() SourceProvider {
    return .{ .ptr = undefined, .vtable = &dummy_vtable };
}

fn testTick(app: *App, event: Event) !void {
    // Use a properly initialized loop so that background threads spawned during
    // tick() can safely call loop.postEvent() (which locks a mutex via io).
    // tty and vaxis are never accessed by postEvent, so undefined is safe there.
    const io = std.testing.io;
    var loop: Loop = .{
        .io = io,
        .tty = undefined,
        .vaxis = undefined,
        .queue = .{ .io = io },
    };
    try app.tick(event, &loop, io, dummyProvider());
    // Join any threads spawned during tick so they finish using &loop before the
    // stack frame tears down. Without this the thread dereferences a dangling
    // loop pointer in the next test and triggers an ABRT.
    if (app.episode_thread) |t| { t.join(); app.episode_thread = null; }
    if (app.search_thread) |t| { t.join(); app.search_thread = null; }
    if (app.enrich_thread) |t| { t.join(); app.enrich_thread = null; }
    if (app.play_thread) |t| { t.join(); app.play_thread = null; }
    // Drain events the threads may have posted; free their owned payloads so the
    // test allocator doesn't report leaks.
    while (loop.queue.tryPop() catch null) |ev| {
        switch (ev) {
            .episodes_done => |d| {
                for (d.episodes) |ep| app.gpa.free(ep.raw);
                app.gpa.free(d.episodes);
                app.gpa.free(d.for_id);
            },
            .search_done => |d| {
                for (d.results) |r| freeOwnedAnime(app.gpa, r);
                app.gpa.free(d.results);
                app.gpa.free(d.for_query);
            },
            .search_enriched => |d| {
                for (d.results) |r| freeOwnedAnime(app.gpa, r);
                app.gpa.free(d.results);
                app.gpa.free(d.for_query);
            },
            // task_error and most other events carry no owned heap payloads.
            else => {},
        }
    }
}

test "history_loaded drains into state and clears loading" {
    var app: App = .{};
    try testing.expect(app.history_loading);
    var recs = sampleHistory();
    try testTick(&app, .{ .history_loaded = &recs });
    try testing.expect(!app.history_loading);
    try testing.expectEqual(@as(usize, 3), app.history.len);
}

test "j/k navigation stays in bounds" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    try testing.expectEqual(@as(usize, 0), app.list_cursor);

    try testTick(&app, keyEv('k', .{})); // up at top — pinned
    try testing.expectEqual(@as(usize, 0), app.list_cursor);

    try testTick(&app, keyEv('j', .{}));
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 2), app.list_cursor);

    try testTick(&app, keyEv('j', .{})); // down at bottom — pinned
    try testing.expectEqual(@as(usize, 2), app.list_cursor);

    try testTick(&app, keyEv('k', .{}));
    try testing.expectEqual(@as(usize, 1), app.list_cursor);
}

test "g/G jump to ends" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    try testTick(&app, keyEv('G', .{}));
    try testing.expectEqual(@as(usize, 2), app.list_cursor);
    try testTick(&app, keyEv('g', .{}));
    try testing.expectEqual(@as(usize, 0), app.list_cursor);
}

test "quit keys: q from browse and Ctrl-C" {
    // q from browse quits.
    var app: App = .{};
    app.active_view = .browse;
    try testing.expect(!app.should_quit);
    try testTick(&app, keyEv('q', .{}));
    try testing.expect(app.should_quit);

    // Ctrl-C always quits.
    app = .{};
    try testing.expect(!app.should_quit);
    try testTick(&app, keyEv('c', .{ .ctrl = true }));
    try testing.expect(app.should_quit);
}

test "navigation is a no-op with empty history" {
    var app: App = .{};
    app.setHistory(&.{});
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 0), app.list_cursor);
    try testing.expect(!app.should_quit);
}

test "setHistory clamps an out-of-range cursor" {
    var app: App = .{};
    app.list_cursor = 99;
    var recs = sampleHistory();
    app.setHistory(&recs);
    try testing.expectEqual(@as(usize, 2), app.list_cursor);
    app.setHistory(&.{});
    try testing.expectEqual(@as(usize, 0), app.list_cursor);
}

test "scrollIntoView keeps the cursor within the viewport" {
    var app: App = .{};
    // 10 rows, viewport of 4.
    app.list_cursor = 7;
    app.list_top = 0;
    app.scrollIntoView(4);
    try testing.expect(app.list_cursor >= app.list_top);
    try testing.expect(app.list_cursor < app.list_top + 4);
    // Cursor moves back above the window → window follows up.
    app.list_cursor = 2;
    app.scrollIntoView(4);
    try testing.expectEqual(@as(usize, 2), app.list_top);
}

test "formatMeta degrades when total episodes is unknown" {
    var buf: [48]u8 = undefined;
    const known = formatMeta(&buf, .{ .source = "s", .source_id = "i", .title = "T", .total_episodes = 12, .progress = 3, .list_status = "watching" });
    try testing.expectEqualStrings("ep 3/12 · watching", known);
    var buf2: [48]u8 = undefined;
    const unknown = formatMeta(&buf2, .{ .source = "s", .source_id = "i", .title = "T", .progress = 0, .list_status = "planning" });
    try testing.expectEqualStrings("ep 0 · planning", unknown);
}

test "F2 from browse goes to history" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .browse;
    try testTick(&app, keyEv(vaxis.Key.f2, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .history), app.active_view);
}

test "F2 from history is a no-op" {
    var app: App = .{};
    app.active_view = .history;
    app.active_pane = .list;
    try testTick(&app, keyEv(vaxis.Key.f2, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .history), app.active_view);
}

test "F1 from history switches to browse" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    try testTick(&app, keyEv(vaxis.Key.f1, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
}

test "F1 from browse is a no-op and preserves active_pane" {
    var app: App = .{};
    app.active_view = .browse;
    app.active_pane = .detail;
    try testTick(&app, keyEv(vaxis.Key.f1, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
    // active_pane must not be reset — F1 from Browse is a no-op per §10.2
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .detail), app.active_pane);
}

test "H from history toggles to browse" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    try testTick(&app, keyEv('H', .{ .shift = true }));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
}

test "H from browse toggles to history" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .browse;
    try testTick(&app, keyEv('H', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .history), app.active_view);
}

test "F3 / S from any view switches to settings" {
    for ([_]@TypeOf(@as(App, undefined).active_view){ .browse, .history }) |from_view| {
        var app: App = .{};
        app.active_view = from_view;
        try testTick(&app, keyEv(vaxis.Key.f3, .{}));
        try testing.expectEqual(@as(@TypeOf(app.active_view), .settings), app.active_view);
    }
}

test "S from settings is a no-op" {
    var app: App = .{};
    app.active_view = .settings;
    try testTick(&app, keyEv('S', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .settings), app.active_view);
}

test "q from history returns to browse without quitting" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    try testing.expect(!app.should_quit);
    try testTick(&app, keyEv('q', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
    try testing.expect(!app.should_quit);
}

test "q from settings returns to browse without quitting" {
    var app: App = .{};
    app.active_view = .settings;
    try testing.expect(!app.should_quit);
    try testTick(&app, keyEv('q', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
    try testing.expect(!app.should_quit);
}

test "q from browse quits the app" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .browse;
    try testing.expect(!app.should_quit);
    try testTick(&app, keyEv('q', .{}));
    try testing.expect(app.should_quit);
}

test "Esc from browse detail pane returns to list pane" {
    var app: App = .{};
    app.active_view = .browse;
    app.active_pane = .detail;
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
}

test "Esc from history returns to browse" {
    var app: App = .{};
    app.active_view = .history;
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
}

test "Esc from browse list pane is a no-op" {
    var app: App = .{};
    app.active_view = .browse;
    app.active_pane = .list;
    try testing.expect(!app.should_quit);
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_view), .browse), app.active_view);
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
    try testing.expect(!app.should_quit);
}

test "h in browse list pane is a no-op (already leftmost)" {
    var app: App = .{};
    app.active_view = .browse;
    app.active_pane = .list;
    try testTick(&app, keyEv('h', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
}

test "l in browse list pane switches to detail pane" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .list;
    // l requires a selected result.
    try app.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "x"),
        .name = try std.testing.allocator.dupe(u8, "X"),
    });
    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .detail), app.active_pane);
    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
    app.freeEpisodeResults();
}

test "h in browse detail pane switches to list pane" {
    var app: App = .{};
    app.active_view = .browse;
    app.active_pane = .detail;
    try testTick(&app, keyEv('h', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
}

test "l in browse detail pane is a no-op (already rightmost)" {
    var app: App = .{};
    app.active_view = .browse;
    app.active_pane = .detail;
    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .detail), app.active_pane);
}

test "h / l in history view are no-ops (single pane)" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    try testTick(&app, keyEv('h', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
}

test "h / l in settings view are no-ops (single pane)" {
    var app: App = .{};
    app.active_view = .settings;
    try testTick(&app, keyEv('h', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .list), app.active_pane);
}

test "navigation j/k — history with data, browse empty (no-op), settings no-op" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);

    // Browse with no results: j is a no-op (nav_len == 0).
    app.active_view = .browse;
    app.list_cursor = 0;
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 0), app.list_cursor);

    // History: j moves cursor.
    app.active_view = .history;
    app.list_cursor = 0;
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 1), app.list_cursor);

    // Settings: j is always a no-op.
    app.active_view = .settings;
    app.list_cursor = 1;
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 1), app.list_cursor);
}

test "/ in Browse enters search mode" {
    var app: App = .{};
    app.active_view = .browse;
    try testing.expectEqual(.normal, app.input_mode);
    try testTick(&app, keyEv('/', .{}));
    try testing.expectEqual(.search, app.input_mode);
}

test "/ in History enters search mode" {
    var app: App = .{};
    app.active_view = .history;
    try testTick(&app, keyEv('/', .{}));
    try testing.expectEqual(.search, app.input_mode);
}

test "search mode: Esc clears query and returns to normal" {
    var app: App = .{};
    app.active_view = .browse;
    app.input_mode = .search;
    app.search_len = 5;
    @memcpy(app.search_query[0..5], "hello");
    try testTick(&app, keyEv(vaxis.Key.escape, .{}));
    try testing.expectEqual(.normal, app.input_mode);
    try testing.expectEqual(@as(usize, 0), app.search_len);
}

test "search mode: Enter locks results and returns to normal" {
    var app: App = .{};
    app.active_view = .browse;
    app.input_mode = .search;
    app.search_len = 5;
    @memcpy(app.search_query[0..5], "hello");
    try testTick(&app, keyEv(vaxis.Key.enter, .{}));
    try testing.expectEqual(.normal, app.input_mode);
    try testing.expectEqual(@as(usize, 5), app.search_len); // query preserved
}

test "search_done page 1 populates results" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.search_len = 7;
    @memcpy(app.search_query[0..7], "frieren");

    const query_copy = try std.testing.allocator.dupe(u8, "frieren");
    const results_backing = try std.testing.allocator.alloc(Anime, 1);
    results_backing[0] = .{
        .id = try std.testing.allocator.dupe(u8, "abc123"),
        .name = try std.testing.allocator.dupe(u8, "Frieren"),
        .eps_sub = 28,
    };

    try testTick(&app, .{ .search_done = .{ .results = results_backing, .for_query = query_copy, .page = 1 } });
    try testing.expectEqual(@as(usize, 1), app.results.items.len);
    try testing.expectEqualStrings("Frieren", app.results.items[0].name);
    try testing.expectEqual(@as(u32, 1), app.search_page);
    try testing.expect(!app.search_loading);

    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
}

test "search_done stale result is discarded" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    // Current query is "frieren"; incoming result is for "bebop" — stale.
    app.search_len = 7;
    @memcpy(app.search_query[0..7], "frieren");

    const query_copy = try std.testing.allocator.dupe(u8, "bebop");
    const results_backing = try std.testing.allocator.alloc(Anime, 1);
    results_backing[0] = .{
        .id = try std.testing.allocator.dupe(u8, "xyz789"),
        .name = try std.testing.allocator.dupe(u8, "Bebop"),
        .eps_sub = 26,
    };

    try testTick(&app, .{ .search_done = .{ .results = results_backing, .for_query = query_copy, .page = 1 } });
    // All stale data freed by tick — results untouched.
    try testing.expectEqual(@as(usize, 0), app.results.items.len);
    try testing.expectEqual(@as(u32, 0), app.search_page);

    app.results.deinit(std.testing.allocator); // capacity is 0; safe no-op
}

test "search_done page 2 appends to existing results" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.search_len = 4;
    @memcpy(app.search_query[0..4], "test");
    app.search_page = 1;

    // Seed a page-1 result directly.
    try app.results.ensureTotalCapacity(std.testing.allocator, 2);
    app.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "id1"),
        .name = try std.testing.allocator.dupe(u8, "Show One"),
        .eps_sub = 12,
    });

    const query_copy = try std.testing.allocator.dupe(u8, "test");
    const results_backing = try std.testing.allocator.alloc(Anime, 1);
    results_backing[0] = .{
        .id = try std.testing.allocator.dupe(u8, "id2"),
        .name = try std.testing.allocator.dupe(u8, "Show Two"),
        .eps_sub = 24,
    };

    try testTick(&app, .{ .search_done = .{ .results = results_backing, .for_query = query_copy, .page = 2 } });
    try testing.expectEqual(@as(usize, 2), app.results.items.len);
    try testing.expectEqual(@as(u32, 2), app.search_page);
    try testing.expectEqualStrings("Show One", app.results.items[0].name);
    try testing.expectEqualStrings("Show Two", app.results.items[1].name);

    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
}

test "search_enriched merges metadata into matching live result" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.search_len = 7;
    @memcpy(app.search_query[0..7], "frieren");

    try app.results.ensureTotalCapacity(std.testing.allocator, 1);
    app.results.appendAssumeCapacity(.{
        .id = try std.testing.allocator.dupe(u8, "id1"),
        .name = try std.testing.allocator.dupe(u8, "Frieren"),
        .eps_sub = 28,
    });

    const query_copy = try std.testing.allocator.dupe(u8, "frieren");
    const enriched = try std.testing.allocator.alloc(Anime, 1);
    enriched[0] = .{
        .id = try std.testing.allocator.dupe(u8, "id1"),
        .name = try std.testing.allocator.dupe(u8, "Frieren"),
        .eps_sub = 28,
        .anilist_id = 154587,
        .thumb = try std.testing.allocator.dupe(u8, "https://img.anili.st/frieren.jpg"),
        .description = try std.testing.allocator.dupe(u8, "Elf mage grief hour"),
        .score = 91,
        .total_episodes = 28,
        .year = 2023,
        .status = try std.testing.allocator.dupe(u8, "FINISHED"),
    };

    try testTick(&app, .{ .search_enriched = .{ .results = enriched, .for_query = query_copy, .offset = 0 } });
    try testing.expectEqual(@as(?u64, 154587), app.results.items[0].anilist_id);
    try testing.expectEqual(@as(?u32, 91), app.results.items[0].score);
    try testing.expectEqualStrings("Elf mage grief hour", app.results.items[0].description orelse "");

    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
}

test "browse j/k navigates results list" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.search_page = 1;

    try app.results.ensureTotalCapacity(std.testing.allocator, 3);
    for (0..3) |_| {
        app.results.appendAssumeCapacity(.{
            .id = try std.testing.allocator.dupe(u8, "id"),
            .name = try std.testing.allocator.dupe(u8, "X"),
            .eps_sub = 12,
        });
    }

    try testing.expectEqual(@as(usize, 0), app.list_cursor);
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 1), app.list_cursor);
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 2), app.list_cursor);
    try testTick(&app, keyEv('j', .{})); // pinned (3 % 26 != 0 → no load-more)
    try testing.expectEqual(@as(usize, 2), app.list_cursor);
    try testTick(&app, keyEv('k', .{}));
    try testing.expectEqual(@as(usize, 1), app.list_cursor);

    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
}

test "view switch resets cursor to 0" {
    var app: App = .{};
    var recs = sampleHistory();
    app.setHistory(&recs);
    app.active_view = .history;
    app.list_cursor = 2;

    // F1 → Browse: cursor resets.
    try testTick(&app, keyEv(vaxis.Key.f1, .{}));
    try testing.expectEqual(.browse, app.active_view);
    try testing.expectEqual(@as(usize, 0), app.list_cursor);

    app.list_cursor = 5;
    // F2 → History: cursor resets.
    try testTick(&app, keyEv(vaxis.Key.f2, .{}));
    try testing.expectEqual(.history, app.active_view);
    try testing.expectEqual(@as(usize, 0), app.list_cursor);
}

test "episode_cursor j/k navigation in detail pane" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .detail;

    // Seed 3 episodes.
    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 3);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    eps[1] = .{ .raw = try std.testing.allocator.dupe(u8, "2") };
    eps[2] = .{ .raw = try std.testing.allocator.dupe(u8, "3") };
    app.episode_results = eps;
    app.episode_cursor = 0;

    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 1), app.episode_cursor);
    try testTick(&app, keyEv('j', .{}));
    try testing.expectEqual(@as(usize, 2), app.episode_cursor);
    try testTick(&app, keyEv('j', .{})); // pinned at last
    try testing.expectEqual(@as(usize, 2), app.episode_cursor);
    try testTick(&app, keyEv('k', .{}));
    try testing.expectEqual(@as(usize, 1), app.episode_cursor);
    try testTick(&app, keyEv('g', .{}));
    try testing.expectEqual(@as(usize, 0), app.episode_cursor);
    try testTick(&app, keyEv('G', .{}));
    try testing.expectEqual(@as(usize, 2), app.episode_cursor);

    app.freeEpisodeResults();
}

test "episodes_done populates episode_results" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    const for_id = try std.testing.allocator.dupe(u8, "anime1");
    app.detail_for_id = try std.testing.allocator.dupe(u8, "anime1");
    app.episode_loading = true;

    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 2);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    eps[1] = .{ .raw = try std.testing.allocator.dupe(u8, "2") };

    try testTick(&app, .{ .episodes_done = .{ .episodes = eps, .for_id = for_id } });
    try testing.expect(!app.episode_loading);
    try testing.expectEqual(@as(usize, 2), app.episode_results.?.len);

    app.freeEpisodeResults();
}

test "episodes_done stale result is discarded" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    // Current show: "anime2"; incoming event is for "anime1" — stale.
    app.detail_for_id = try std.testing.allocator.dupe(u8, "anime2");
    app.episode_loading = true;

    const stale_id = try std.testing.allocator.dupe(u8, "anime1");
    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 1);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };

    try testTick(&app, .{ .episodes_done = .{ .episodes = eps, .for_id = stale_id } });
    // Still loading (wasn't cleared by stale event), episode_results still null.
    try testing.expect(app.episode_loading);
    try testing.expect(app.episode_results == null);

    // Cleanup detail_for_id manually.
    if (app.detail_for_id) |id| { std.testing.allocator.free(id); app.detail_for_id = null; }
}

test "search mode: char appends and arms debounce, does not fire immediately" {
    var app: App = .{};
    app.active_view = .browse;
    app.input_mode = .search;
    const k = vaxis.Key{ .codepoint = 'a', .text = "a" };
    try testTick(&app, .{ .key_press = k });
    try testing.expectEqual(@as(usize, 1), app.search_len);
    try testing.expect(!app.search_loading);
    try testing.expect(app.debounce_deadline_ms > 0);
}

test "tick advances spinner frame and wraps at 10" {
    var app: App = .{};
    try testing.expectEqual(@as(u8, 0), app.spinner_frame);
    for (0..10) |_| try testTick(&app, .tick);
    try testing.expectEqual(@as(u8, 0), app.spinner_frame);
}

test "tick fires debounced search when deadline has passed" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.search_len = 3;
    @memcpy(app.search_query[0..3], "abc");
    app.debounce_deadline_ms = 1; // well in the past — always expired
    try testTick(&app, .tick);
    try testing.expectEqual(@as(i64, 0), app.debounce_deadline_ms);
    try testing.expect(app.search_loading);
    for (app.results.items) |r| freeOwnedAnime(std.testing.allocator, r);
    app.results.deinit(std.testing.allocator);
}

test "task_error pushes a persistent error toast" {
    var app: App = .{};
    try testTick(&app, .{ .task_error = "network down" });
    const t = app.toast_queue[0] orelse return error.TestExpectationFailed;
    try testing.expectEqual(Toast.Kind.@"error", t.kind);
    try testing.expect(t.persistent);
    try testing.expectEqualStrings("network down", t.text[0..t.text_len]);
}

test "firePlay: double-play guard is a no-op when playing is true" {
    var app: App = .{};
    app.gpa = std.testing.allocator;
    app.active_view = .browse;
    app.active_pane = .detail;
    app.playing = true;

    const eps = try std.testing.allocator.alloc(domain.EpisodeNumber, 1);
    eps[0] = .{ .raw = try std.testing.allocator.dupe(u8, "1") };
    app.episode_results = eps;
    app.detail_for_id = try std.testing.allocator.dupe(u8, "anime1");

    try testTick(&app, keyEv(vaxis.Key.enter, .{}));

    // Guard held — no thread spawned, playing still true.
    try testing.expect(app.play_thread == null);
    try testing.expect(app.playing);

    std.testing.allocator.free(app.detail_for_id.?);
    std.testing.allocator.free(eps[0].raw);
    std.testing.allocator.free(eps);
}

test "history filter: reduces nav_len to matching entries only" {
    var hist = sampleHistory(); // Frieren, K-On!, Bebop
    var app: App = .{};
    app.history = &hist;
    app.active_view = .history;

    // No filter: all 3 entries visible.
    try testing.expectEqual(@as(usize, 3), app.filteredHistoryLen());

    // Filter "on" matches K-On! only.
    @memcpy(app.history_filter[0..2], "on");
    app.history_filter_len = 2;
    try testing.expectEqual(@as(usize, 1), app.filteredHistoryLen());

    // Filter "bop" matches Bebop only.
    @memcpy(app.history_filter[0..3], "bop");
    app.history_filter_len = 3;
    try testing.expectEqual(@as(usize, 1), app.filteredHistoryLen());

    // Filter "zzz" matches nothing.
    @memcpy(app.history_filter[0..3], "zzz");
    app.history_filter_len = 3;
    try testing.expectEqual(@as(usize, 0), app.filteredHistoryLen());
}

test "history filter: esc clears filter and resets cursor" {
    var hist = sampleHistory();
    var app: App = .{};
    app.history = &hist;
    app.active_view = .history;
    app.input_mode = .search;
    @memcpy(app.history_filter[0..5], "Frien");
    app.history_filter_len = 5;
    app.list_cursor = 2;
    app.list_top = 1;

    try testTick(&app, keyEv(vaxis.Key.escape, .{}));

    try testing.expectEqual(@as(usize, 0), app.history_filter_len);
    try testing.expectEqual(@as(usize, 0), app.list_cursor);
    try testing.expectEqual(@as(usize, 0), app.list_top);
    try testing.expectEqual(.normal, app.input_mode);
}

test "history 2-row scroll: scrollIntoView with visible/2 keeps cursor in view" {
    var hist = sampleHistory();
    var app: App = .{};
    app.history = &hist;
    app.active_view = .history;
    app.list_cursor = 2;
    app.list_top = 0;

    // visible = 4 terminal rows → 2 entry slots. Cursor at entry 2 must push list_top.
    app.scrollIntoView(4 / 2);
    try testing.expect(app.list_cursor >= app.list_top);
    try testing.expect(app.list_cursor < app.list_top + 2);
}

test "history 2-row scroll: scrollIntoView(0) does not corrupt list_top" {
    var hist = sampleHistory();
    var app: App = .{};
    app.history = &hist;
    app.active_view = .history;
    app.list_cursor = 1;
    app.list_top = 0;

    // Degenerate edge: visible=1 terminal row → visible/2=0 without the @max(1,…) guard.
    // scrollIntoView(0) would set list_top = cursor+1, skipping all entries. Confirm
    // that @max(1, visible/2) keeps list_top sane.
    app.scrollIntoView(@max(1, 1 / 2));
    try testing.expect(app.list_top <= app.list_cursor);
}
