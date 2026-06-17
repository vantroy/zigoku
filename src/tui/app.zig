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
const event_mod = @import("event.zig");
const render = @import("render.zig");
const workers = @import("workers.zig");
const config_mod = @import("../config.zig");
const log = @import("../log.zig");

// Per-view render passes, extracted along the tick/draw seam (ROD-144).
const chrome = @import("view/chrome.zig");
const history = @import("view/history.zig");
const browse = @import("view/browse.zig");
const detail = @import("view/detail.zig");
const settings = @import("view/settings.zig");

const Allocator = std.mem.Allocator;
const AnimeRecord = store_mod.AnimeRecord;
const Store = store_mod.Store;
const Config = config_mod.Config;
const SourceProvider = source_mod.SourceProvider;
const Anime = domain.Anime;
const Event = event_mod.Event;
const Loop = event_mod.Loop;
// Only `put` survives in app.zig (the "terminal too small" guard in `draw()`);
// the rest of the render helpers now live with the per-view passes (ROD-144).
const put = render.put;
const dupeOptText = workers.dupeOptText;
const dupeOwnedAnime = workers.dupeOwnedAnime;
const freeOwnedAnime = workers.freeOwnedAnime;
const searchTask = workers.searchTask;
const enrichTask = workers.enrichTask;
const loadHistoryTask = workers.loadHistoryTask;
const episodesTask = workers.episodesTask;
const playTask = workers.playTask;
const tickTask = workers.tickTask;
const nowMs = workers.nowMs;

/// §3.6 async feedback: once an in-flight op outlives this many ms, spinners
/// shift from the focus/cyan colour to the slow-path `hot` emphasis so the user
/// knows we're waiting on the network, not stuck.
const slow_path_threshold_ms: i64 = 3000;

/// Cover/image subsystem (ROD-160). Lives in its own module now that it's a
/// self-contained unit with no dependency on App; re-exported here so existing
/// `app_mod.CoverState` references (views, tests) keep resolving.
pub const CoverState = @import("cover_state.zig").CoverState;

/// Settings controller subsystem (ROD-161). Owns the Settings tab data model +
/// edit state in its own module; re-exported here (along with the row table the
/// view renders) so existing `app_mod.*` references keep resolving.
const settings_state = @import("settings_state.zig");
pub const SettingsState = settings_state.SettingsState;
pub const SettingId = settings_state.SettingId;
pub const SettingKind = settings_state.SettingKind;
pub const SettingRow = settings_state.SettingRow;
pub const settings_rows = settings_state.settings_rows;
pub const settings_row_count = settings_state.settings_row_count;

/// Run the TUI to completion. `store` is optional and best-effort, exactly like
/// the CLI path: a DB hiccup means "no history," never a refusal to run.
pub fn run(
    gpa: Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    store: ?*Store,
    provider: SourceProvider,
    config: Config,
    config_path: ?[]const u8,
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
    app.gpa = gpa;
    app.store = store;
    app.config = config;
    app.config_path = config_path;
    app.palette = paletteFromConfig(config.palette);
    // The configured sub/dub default seeds the search translation; the user can
    // still toggle it live in-session (ROD-85).
    app.translation = config.translationEnum();
    defer app.deinitOwnedState(&vx, writer);

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

    // Join the last search thread before loop teardown so in-flight threads
    // can't dereference a torn-down loop or gpa. Declared after loop.stop()'s
    // defer so it executes first (Zig defers are LIFO).
    defer if (app.search_thread) |t| t.join();
    defer if (app.enrich_thread) |t| t.join();
    defer if (app.episode_thread) |t| t.join();
    // Cover worker must be joined on both the normal shutdown path and any
    // error unwind path before `loop`, `gpa`, or the caches are torn down.
    defer app.cover.joinThread();
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
    {
        const win = vx.window();
        app.layout(win.height, win.width);
    }
    try app.draw(&vx, writer);
    while (!app.should_quit) {
        const event = try loop.nextEvent();
        // Resize is a vaxis-lifecycle concern (it reallocates the screen), so
        // run() owns it — that keeps tick() a pure state fold, testable without
        // a tty. tick() still sees the event; it just doesn't touch the screen.
        if (event == .winsize) try vx.resize(gpa, writer, event.winsize);
        try app.tick(event, &loop, io, provider);
        // Settle the list viewport before drawing: layout() is the state half
        // of the scroll seam, so draw() reads list_top without writing it
        // (ROD-155). run() owns geometry, so it feeds the terminal size in.
        const win = vx.window();
        app.layout(win.height, win.width);
        try app.draw(&vx, writer);
    }
}

pub const Toast = struct {
    pub const Kind = enum { info, success, @"error", warn };
    kind: Kind,
    text: [80]u8 = undefined,
    text_len: usize = 0,
    /// Remaining TTL in ms. Ignored when persistent = true.
    ttl_ms: i32 = 4000,
    /// Persistent toasts survive TTL and are only cleared by a recovery path.
    persistent: bool = false,
};

/// Resolve a config palette name to its static `colors.Palette`, falling back
/// to the default for anything unrecognized. Stays on App (not in
/// `SettingsState`): it's an App-live projection the controller re-derives after
/// a settings change, and `run()` also calls it at startup.
fn paletteFromConfig(name: []const u8) *const colors.Palette {
    if (std.mem.eql(u8, name, "phosphor")) return &colors.phosphor;
    if (std.mem.eql(u8, name, "nord")) return &colors.nord;
    return &colors.terminal_ghost;
}

/// Per-frame render scratch, owned by App so it outlives the draw→render cycle.
///
/// vaxis stores printed text by *reference*, not by copy, so every formatted
/// string must stay alive until vx.render() runs; a loop-local stack buffer
/// would dangle. Kept as a struct distinct from application state so the list
/// render passes can take `*const App` and write only here — the compiler then
/// proves they never touch cursor/viewport/results state (ROD-155).
pub const RenderScratch = struct {
    /// Per-row formatted meta strings. Soft cap of 256 slots: a terminal with
    /// more than 256 visible rows renders the overflow rows without the meta
    /// column (no crash, just no meta).
    meta: [256][48]u8 = undefined,
    /// Per-row progress-bar fraction strings ("N / M eps"). Same lifetime
    /// contract as `meta` — must outlive vx.render().
    bar: [256][32]u8 = undefined,
    /// Single-line scratch for the list passes' spinners and empty-state
    /// messages. Safe to share between Browse and History because only one view
    /// is active per frame. NOT for the detail pane: detail co-renders with
    /// Browse in split layout, so it has its own `detail_msg` to avoid clobbering
    /// a slice vaxis still holds by reference.
    msg: [160]u8 = undefined,
    /// Detail-pane cover spinner glyph. Separate from `msg` so the split-pane
    /// frame (Browse list + detail) never aliases one buffer (ROD-155 review).
    detail_msg: [32]u8 = undefined,
};

pub const App = struct {
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

    /// Per-frame render scratch (formatted meta/bar/message strings). Grouped
    /// off application state so the list passes can take `*const App` (ROD-155);
    /// see RenderScratch for the vaxis by-reference lifetime contract.
    scratch: RenderScratch = .{},

    /// Which top-level view is currently displayed.
    /// Defaults to .history — the M3 landing (§9.2).
    active_view: enum { browse, history, detail, settings } = .history,
    /// Which top-level view opened the standalone detail screen.
    detail_origin: enum { browse, history } = .browse,

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
    /// At most one joinable AniList enrichment worker is active at a time. A
    /// later search can queue one follow-up enrich request without blocking the UI.
    enrich_thread: ?std.Thread = null,
    pending_enrich: ?struct { offset: usize, count: usize } = null,

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
    /// Cover/image subsystem — fetch policy, decoded-pixel + Kitty-image state,
    /// and the cover worker-thread lifecycle. See `CoverState` (ROD-160).
    cover: CoverState = .{},
    /// Handle for the most recent play thread. Joined before a new spawn.
    play_thread: ?std.Thread = null,
    /// Whether mpv is running (play thread in-flight).
    playing: bool = false,
    /// Live mpv playback position from IPC.
    current_position: f64 = 0,
    /// Live mpv duration from IPC.
    current_duration: f64 = 0,
    /// Last persisted checkpoint position for the current playback.
    last_checkpoint_pos: f64 = 0,
    /// Source name for the currently playing episode. Borrowed from either the
    /// provider vtable or the history arena, both of which outlive App.
    playing_source: []const u8 = &.{},
    /// GPA-owned show id for the current playback session.
    playing_anime_id: []const u8 = &.{},
    /// GPA-owned raw episode label for the current playback session.
    playing_episode_raw: []const u8 = &.{},
    /// 1-based episode index used for recordPlay's high-water mark.
    playing_episode_index: u32 = 0,
    /// Translation active when playback started; decoupled from live UI toggles.
    playing_translation: domain.Translation = .sub,
    /// Store reference — set in run() for getResume in the play thread.
    store: ?*Store = null,
    /// User config (ROD-85). Set in run(); string fields are arena-borrowed and
    /// outlive every worker thread. The Settings tab (ROD-86) mutates this in
    /// place: cycle/toggle write scalar + preset-literal fields directly; the
    /// only editable *text* field (mpv_path) is committed into the settings
    /// subsystem's `text_buf`, so we never free a default literal or the load
    /// arena — we just re-point the slice.
    config: Config = .{},
    /// Resolved config-file path for `save()` on `q` (ROD-86). Borrowed from
    /// run()'s process-lifetime arena. Null when no $HOME/$XDG_CONFIG_HOME — in
    /// which case settings still edit live but can't persist.
    config_path: ?[]const u8 = null,
    /// Active color palette (ROD-87). Points to one of the Palette presets in
    /// colors.zig; updated live when the user cycles the palette setting.
    palette: *const colors.Palette = &colors.terminal_ghost,

    /// Settings tab controller (ROD-161): row cursor, text-edit buffer, and the
    /// cycle/toggle/edit handlers over `config`. Extracted from App following the
    /// ROD-160 `CoverState` pattern; embedded by value so `App{}` stays trivially
    /// constructible. See `SettingsState`.
    settings: SettingsState = .{},
    /// Scratch for episode grid cell text (avoids dangling stack buffers in draw).
    /// vaxis stores text by reference, so we need stable storage that survives vx.render().
    /// 8 bytes per slot: "[" + up to 5-char label + "]" + spare = 8. 6 was too tight
    /// for labels like "1000a" — silently fell back to "[?]".
    ep_scratch: [512][8]u8 = undefined,
    /// Stable storage for the detail-pane score line.
    detail_score_buf: [32]u8 = undefined,
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
    pub fn querySlice(self: *const App) []const u8 {
        return self.search_query[0..self.search_len];
    }

    /// Palette-aware style: `bg` defaults to `self.palette.bg_base` when null.
    /// All draw methods use this instead of the plain `style()` import so that
    /// switching palettes re-colors every cell, not just ones with explicit bg.
    /// pub: part of the cross-module render contract — the view/ passes call
    /// `self.s(...)` directly (ROD-144).
    pub inline fn s(self: *const App, fg: vaxis.Color, opts: struct {
        bg: ?vaxis.Color = null,
        bold: bool = false,
        italic: bool = false,
        blink: bool = false,
        dim: bool = false,
    }) vaxis.Style {
        return .{
            .fg = fg,
            .bg = opts.bg orelse self.palette.bg_base,
            .bold = opts.bold,
            .italic = opts.italic,
            .blink = opts.blink,
            .dim = opts.dim,
        };
    }

    const spinner_frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"; // 10 × 3 UTF-8 bytes
    pub fn spinnerChar(self: *const App) []const u8 {
        const b = @as(usize, self.spinner_frame) * 3;
        return spinner_frames[b .. b + 3];
    }

    /// §3.6: has the current async op outlived the slow-path threshold? Drives
    /// the cyan → hot spinner shift in both the bottom bar and the cover block.
    pub fn isSlowPath(self: *const App) bool {
        return self.async_start_ms > 0 and
            self.now_ms - self.async_start_ms > slow_path_threshold_ms;
    }

    fn pushToast(self: *App, kind: Toast.Kind, text: []const u8, persistent: bool) void {
        var idx: usize = 3;
        for (self.toast_queue, 0..) |slot, i| {
            if (slot == null) {
                idx = i;
                break;
            }
        }
        if (idx == 3) {
            self.toast_queue[0] = self.toast_queue[1];
            self.toast_queue[1] = self.toast_queue[2];
            idx = 2;
        }
        var t: Toast = .{ .kind = kind, .persistent = persistent, .ttl_ms = if (persistent) 0 else 2500 };
        const n = @min(text.len, 79);
        @memcpy(t.text[0..n], text[0..n]);
        t.text_len = n;
        self.toast_queue[idx] = t;
    }

    /// Free all accumulated search results and reset search state.
    /// Call before a new page-1 search and when Esc clears the query.
    fn clearResults(self: *App) void {
        self.pending_enrich = null;
        for (self.results.items) |r| freeOwnedAnime(self.gpa, r);
        self.results.clearRetainingCapacity();
        self.search_page = 0;
    }

    /// Unified teardown for app-owned runtime state. Thread joins live in
    /// run() and must execute before this cleanup touches anything workers can
    /// still reference.
    pub fn deinitOwnedState(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer) void {
        self.clearResults();
        self.results.deinit(self.gpa);
        self.results = .empty;
        self.freeEpisodeResults();
        self.clearPlayingSession();
        self.cover.freeAll(self.gpa, vx, writer);
        self.cover.deinitCaches(self.gpa);
    }

    fn selectedAnime(self: *const App) ?Anime {
        if (self.results.items.len == 0 or self.list_cursor >= self.results.items.len) return null;
        return self.results.items[self.list_cursor];
    }

    fn selectedHistoryRecord(self: *const App) ?AnimeRecord {
        if (self.history.len == 0) return null;
        var visible_i: usize = 0;
        for (self.history) |rec| {
            if (!self.historyEntryVisible(rec.title)) continue;
            if (visible_i == self.list_cursor) return rec;
            visible_i += 1;
        }
        return null;
    }

    fn animeFromHistoryRecord(rec: AnimeRecord) Anime {
        return .{
            .id = rec.source_id,
            .name = rec.title,
            .english_name = rec.title_english,
            .mal_id = if (rec.mal_id) |x| std.math.cast(u64, x) else null,
            .anilist_id = if (rec.anilist_id) |x| std.math.cast(u64, x) else null,
            .thumb = rec.cover_url,
            .total_episodes = if (rec.total_episodes) |x| std.math.cast(u32, x) else null,
            .year = if (rec.year) |x| std.math.cast(u32, x) else null,
            .status = rec.status,
            .description = rec.description,
            .score = if (rec.score) |x| std.math.cast(u32, x) else null,
        };
    }

    pub fn currentDetailAnime(self: *const App) ?Anime {
        return switch (self.active_view) {
            .browse => if (self.active_pane == .detail) self.selectedAnime() else null,
            .detail => switch (self.detail_origin) {
                .browse => self.selectedAnime(),
                .history => if (self.selectedHistoryRecord()) |rec| animeFromHistoryRecord(rec) else null,
            },
            .history, .settings => null,
        };
    }

    fn renderedDetailAnime(self: *const App) ?Anime {
        return switch (self.active_view) {
            .browse => self.selectedAnime(),
            .detail => switch (self.detail_origin) {
                .browse => self.selectedAnime(),
                .history => if (self.selectedHistoryRecord()) |rec| animeFromHistoryRecord(rec) else null,
            },
            .history, .settings => null,
        };
    }

    const DetailRenderInfo = struct {
        anime: ?Anime,
        title: []const u8,
        meta: []const u8,
        has_meta: bool,
    };

    pub fn detailRenderInfo(self: *App) DetailRenderInfo {
        const anime = self.renderedDetailAnime();
        const title: []const u8 = if (anime) |a|
            if (a.name.len > 0) a.name else "—"
        else
            "—";
        const meta: []const u8 = if (anime) |a| blk: {
            const eps = a.episodeCount(self.translation);
            if (eps > 0) break :blk std.fmt.bufPrint(&self.detail_meta_buf, "{d} eps", .{eps}) catch "? eps";
            if (a.total_episodes) |total| break :blk std.fmt.bufPrint(&self.detail_meta_buf, "{d} eps", .{total}) catch "? eps";
            break :blk "? eps";
        } else "? eps";
        const has_meta = if (anime) |a| a.episodeCount(self.translation) > 0 or a.total_episodes != null else false;
        return .{ .anime = anime, .title = title, .meta = meta, .has_meta = has_meta };
    }

    fn currentDetailSourceName(self: *const App, provider: SourceProvider) []const u8 {
        if (self.active_view == .detail and self.detail_origin == .history) {
            if (self.selectedHistoryRecord()) |rec| return rec.source;
        }
        return provider.name();
    }

    fn seedHistoryEpisodeCursor(self: *App, rec: AnimeRecord, episodes: []domain.EpisodeNumber) void {
        const progress: usize = if (rec.progress > 0) @intCast(rec.progress) else 0;
        if (progress == 0) return;

        const current_idx = progress - 1;
        if (current_idx < episodes.len) {
            if (self.store) |st| {
                if (st.getResume(rec.source, rec.source_id, self.translation, episodes[current_idx].raw) catch null) |saved_resume| {
                    if (saved_resume.startSeconds() > 0) {
                        self.episode_cursor = current_idx;
                        return;
                    }
                }
            }
        }

        if (progress < episodes.len) {
            self.episode_cursor = progress;
        }
    }

    fn clearPlayingSession(self: *App) void {
        if (self.playing_anime_id.len > 0) self.gpa.free(self.playing_anime_id);
        if (self.playing_episode_raw.len > 0) self.gpa.free(self.playing_episode_raw);
        self.playing_source = &.{};
        self.playing_anime_id = &.{};
        self.playing_episode_raw = &.{};
        self.playing_episode_index = 0;
        self.playing_translation = .sub;
        self.last_checkpoint_pos = 0;
    }

    fn beginPlayingSession(
        self: *App,
        source: []const u8,
        anime_id: []const u8,
        episode_raw: []const u8,
        episode_index: u32,
        start_seconds: u64,
    ) bool {
        self.clearPlayingSession();
        const owned_id = self.gpa.dupe(u8, anime_id) catch return false;
        const owned_episode = self.gpa.dupe(u8, episode_raw) catch {
            self.gpa.free(owned_id);
            return false;
        };

        self.playing_source = source;
        self.playing_anime_id = owned_id;
        self.playing_episode_raw = owned_episode;
        self.playing_episode_index = episode_index;
        self.playing_translation = self.translation;
        self.last_checkpoint_pos = @floatFromInt(start_seconds);
        return true;
    }

    fn maybeCheckpointProgress(self: *App, time_pos: f64, duration: f64) void {
        const st = self.store orelse return;
        if (self.playing_anime_id.len == 0 or self.playing_episode_raw.len == 0) return;
        if (time_pos - self.last_checkpoint_pos < 30.0) return;

        st.saveProgress(
            self.playing_source,
            self.playing_anime_id,
            self.playing_translation,
            self.playing_episode_raw,
            time_pos,
            duration,
            Store.nowSecs(),
        ) catch |e| log.debug("saveProgress (checkpoint) failed: {s}", .{@errorName(e)});
        self.last_checkpoint_pos = time_pos;
    }

    fn observedPlaybackWasMeaningful(final_update: ?event_mod.PositionUpdate) bool {
        const update = final_update orelse return false;
        return std.math.isFinite(update.time_pos) and update.time_pos > 0;
    }

    fn finishPlayback(self: *App, final_update: ?event_mod.PositionUpdate, record_play: bool) void {
        if (self.store) |st| {
            if (self.playing_anime_id.len > 0 and self.playing_episode_raw.len > 0) {
                if (observedPlaybackWasMeaningful(final_update)) {
                    const update = final_update.?;
                    st.saveProgress(
                        self.playing_source,
                        self.playing_anime_id,
                        self.playing_translation,
                        self.playing_episode_raw,
                        update.time_pos,
                        update.duration,
                        Store.nowSecs(),
                    ) catch |e| log.debug("saveProgress (final) failed: {s}", .{@errorName(e)});
                }
                if (record_play and self.playing_episode_index > 0) {
                    st.recordPlay(self.playing_source, self.playing_anime_id, self.playing_episode_index, Store.nowSecs()) catch |e|
                        log.debug("recordPlay failed: {s}", .{@errorName(e)});
                }
            }
        }

        self.playing = false;
        self.current_position = 0;
        self.current_duration = 0;
        self.clearPlayingSession();
        self.async_start_ms = 0;
    }

    fn fireEnrich(self: *App, loop: *Loop, io: std.Io, offset: usize, count: usize) void {
        if (builtin.is_test) return;
        if (count == 0 or offset >= self.results.items.len) return;

        if (self.enrich_thread != null) {
            self.pending_enrich = .{ .offset = offset, .count = count };
            return;
        }

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
            loop, self.gpa, io, exact, q_copy, offset,
        }) catch {
            self.enrich_thread = null;
            for (exact) |a| freeOwnedAnime(self.gpa, a);
            self.gpa.free(exact);
            self.gpa.free(q_copy);
            return;
        };
    }

    pub fn freeEpisodeResults(self: *App) void {
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

    pub fn setHistory(self: *App, recs: []AnimeRecord) void {
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

    fn persistResults(self: *App, source_name: []const u8, offset: usize, count: usize, visible: bool) void {
        const st = self.store orelse return;
        const end = @min(self.results.items.len, offset + count);
        var i = offset;
        while (i < end) : (i += 1) {
            var rec = AnimeRecord.fromDomain(source_name, self.results.items[i], self.translation);
            rec.history_visible = visible;
            st.upsertAnime(rec, Store.nowSecs()) catch |e| log.debug("upsertAnime failed: {s}", .{@errorName(e)});
        }
    }

    // ── tick: fold one event into state ──────────────────────────────────────
    pub fn tick(self: *App, event: Event, loop: *Loop, io: std.Io, provider: SourceProvider) !void {
        switch (event) {
            .key_press => |key| self.onKey(key, loop, io, provider),
            .winsize => |ws| {
                // Screen resize is handled in run()'s loop (it owns vx), but the
                // app still normalizes browse layout state here so draw remains pure.
                if (ws.cols < 60 and self.active_view == .browse) self.active_pane = .list;
            },
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
                self.results.appendSlice(self.gpa, ev.results) catch |e| {
                    // OOM appending this page — the duped Anime in ev.results would
                    // otherwise leak (we free the outer slice but not the elements).
                    log.debug("appending search results failed: {s}", .{@errorName(e)});
                    for (ev.results) |r| freeOwnedAnime(self.gpa, r);
                };
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
                self.persistResults(source_name, offset, added, false);
                self.fireEnrich(loop, io, offset, added);
            },
            .search_enriched => |ev| {
                if (!std.mem.eql(u8, ev.for_query, self.querySlice())) {
                    for (ev.results) |r| freeOwnedAnime(self.gpa, r);
                    self.gpa.free(ev.results);
                    self.gpa.free(ev.for_query);
                    if (self.enrich_thread) |t| {
                        t.join();
                        self.enrich_thread = null;
                    }
                    if (self.pending_enrich) |p| {
                        self.pending_enrich = null;
                        self.fireEnrich(loop, io, p.offset, p.count);
                    }
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
                self.persistResults(source_name, ev.offset, ev.results.len, false);
                if (self.enrich_thread) |t| {
                    t.join();
                    self.enrich_thread = null;
                }
                if (self.pending_enrich) |p| {
                    self.pending_enrich = null;
                    self.fireEnrich(loop, io, p.offset, p.count);
                }
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
                if (self.active_view == .detail and self.detail_origin == .history) {
                    if (self.selectedHistoryRecord()) |rec| {
                        self.seedHistoryEpisodeCursor(rec, ev.episodes);
                    }
                }
            },
            .episodes_error => {
                self.episode_loading = false;
                self.async_start_ms = 0;
            },
            .cover_done => |ev| {
                defer self.gpa.free(ev.for_id);
                if (self.cover.for_id == null or !std.mem.eql(u8, ev.for_id, self.cover.for_id.?)) {
                    self.gpa.free(ev.rgba);
                    return;
                }
                self.cover.loading = false;
                self.cover.joinThread();
                if (!self.search_loading and !self.episode_loading and !self.playing) self.async_start_ms = 0;

                // The result is stale if the selection moved off this id while
                // the fetch was in flight; the controller owns that nav check.
                const target_id = if (self.currentDetailAnime()) |a| a.id else null;
                const keep = target_id != null and std.mem.eql(u8, target_id.?, ev.for_id);
                if (!keep) {
                    self.cover.clear(self.gpa);
                    self.gpa.free(ev.rgba);
                    return;
                }

                self.cover.acceptPixels(self.gpa, ev.rgba, ev.width, ev.height);
            },
            .cover_error => |for_id| {
                defer self.gpa.free(for_id);
                if (self.cover.for_id == null or !std.mem.eql(u8, for_id, self.cover.for_id.?)) return;
                self.cover.loading = false;
                self.cover.joinThread();
                if (!self.search_loading and !self.episode_loading and !self.playing) self.async_start_ms = 0;
                // Record the failed url *before* clear() frees it.
                self.cover.noteFailure(self.gpa, self.now_ms, for_id, self.cover.inflight_url);
                self.cover.clear(self.gpa);
                std.log.debug("cover fetch/decode failed for {s}", .{for_id});
            },
            .position_update => |ev| {
                self.current_position = ev.time_pos;
                self.current_duration = ev.duration;
                self.maybeCheckpointProgress(ev.time_pos, ev.duration);
            },
            .play_done => |final_update| {
                self.finishPlayback(final_update, true);
            },
            .play_error => |final_update| {
                self.finishPlayback(final_update, observedPlaybackWasMeaningful(final_update));
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

        if (event != .tick) {
            // Resolve the cover target from navigation state here (the controller's
            // job) and hand the primitives to the subsystem — CoverState never
            // reaches into selection state itself (ROD-160).
            const anime = self.currentDetailAnime();
            const started = self.cover.sync(
                self.gpa,
                loop,
                io,
                self.now_ms,
                if (anime) |a| a.id else null,
                if (anime) |a| a.thumb else null,
            );
            if (started) self.async_start_ms = self.now_ms;
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

    fn fireEpisodesForId(self: *App, loop: *Loop, io: std.Io, provider: SourceProvider, source_id: []const u8) void {
        if (self.episode_thread) |t| {
            t.join();
            self.episode_thread = null;
        }

        self.freeEpisodeResults();
        self.episode_loading = true;
        self.episode_cursor = 0;
        self.async_start_ms = self.now_ms;

        // Two GPA-duped copies: one for App.detail_for_id, one for the task (→ event).
        const id_for_app = self.gpa.dupe(u8, source_id) catch return;
        const id_for_task = self.gpa.dupe(u8, source_id) catch {
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

    fn fireEpisodes(self: *App, loop: *Loop, io: std.Io, provider: SourceProvider) void {
        const selected = self.selectedAnime() orelse return;
        self.fireEpisodesForId(loop, io, provider, selected.id);
    }

    fn openHistoryDetail(self: *App, loop: *Loop, io: std.Io, provider: SourceProvider) void {
        const rec = self.selectedHistoryRecord() orelse return;
        self.active_view = .detail;
        self.detail_origin = .history;
        self.active_pane = .detail;
        self.fireEpisodesForId(loop, io, provider, rec.source_id);
    }

    fn firePlay(self: *App, loop: *Loop, io: std.Io, provider: SourceProvider) void {
        const eps = self.episode_results orelse return;
        if (eps.len == 0 or self.episode_cursor >= eps.len) return;
        if (self.playing) return;

        if (self.play_thread) |t| {
            t.join();
            self.play_thread = null;
        }

        const selected_id = self.detail_for_id orelse return;
        const ep = eps[self.episode_cursor];
        const source_name = self.currentDetailSourceName(provider);
        const episode_index: u32 = @intCast(self.episode_cursor + 1);

        var start_seconds: u64 = 0;
        if (self.store) |st| {
            if (st.getResume(source_name, selected_id, self.translation, ep.raw) catch null) |saved_resume| {
                start_seconds = saved_resume.startSeconds();
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
        if (!self.beginPlayingSession(source_name, selected_id, ep.raw, episode_index, start_seconds)) {
            self.gpa.free(id_copy);
            self.gpa.free(ep_copy);
            self.gpa.free(title_copy);
            return;
        }

        self.play_thread = std.Thread.spawn(.{}, playTask, .{
            loop,
            self.gpa,
            io,
            provider,
            id_copy,
            ep_copy,
            self.translation,
            title_copy,
            start_seconds,
            mal_id,
            episode_index,
            self.config.mpv_path,
            self.config.skip_mode,
        }) catch {
            self.clearPlayingSession();
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

    // ── Settings tab (ROD-86, controller glue for ROD-161 SettingsState) ─────

    /// Drive a key into the Settings subsystem and project its verdict onto
    /// App-live state. Returns true if the key was consumed; false lets it fall
    /// through to the global chain (F-keys to switch views, Esc to leave, Ctrl-C
    /// to quit). The subsystem never touches nav/palette/translation/toasts — it
    /// reports *what changed* and the projection lives here, in the controller.
    fn onSettingsKey(self: *App, key: vaxis.Key, io: std.Io) bool {
        switch (self.settings.onKey(key, &self.config)) {
            .ignored => return false,
            .consumed => return true,
            .config_changed => {
                // Re-derive the App-live values the settings change projects to.
                // Idempotent for non-projecting fields; the source of truth is
                // `config`, which the subsystem just mutated.
                self.translation = self.config.translationEnum();
                self.palette = paletteFromConfig(self.config.palette);
                return true;
            },
            .save_and_exit => {
                // `q` saves-then-leaves. Persistence + the nav writes stay in the
                // controller; the subsystem only signals the intent.
                self.saveSettings(io);
                self.active_view = .browse;
                self.active_pane = .list;
                return true;
            },
        }
    }

    /// Persist the live config to disk (ROD-85 `save`), toasting the outcome.
    /// Stays on App: it owns `config_path` and the toast queue, neither of which
    /// belongs in the settings edit subsystem.
    fn saveSettings(self: *App, io: std.Io) void {
        const path = self.config_path orelse {
            self.pushToast(.warn, "no config dir — not saved", false);
            return;
        };
        config_mod.save(io, self.config, path) catch {
            self.pushToast(.@"error", "settings save failed", false);
            return;
        };
        self.pushToast(.success, "settings saved", false);
    }

    fn onKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io, provider: SourceProvider) void {
        // Settings owns its keys first (cycle/toggle/edit/save); anything it
        // doesn't consume falls through to the global chain below.
        if (self.active_view == .settings and self.onSettingsKey(key, io)) return;

        // q key behavior by view (§10.6).
        if (key.matches('q', .{})) {
            switch (self.active_view) {
                .browse => self.should_quit = true,
                // Settings never reaches here: onSettingsKey above intercepts q
                // to save-then-leave. Keep it out of this arm so a future change
                // can't silently route a settings-q exit past saveSettings.
                .history => {
                    self.active_view = .browse;
                    self.active_pane = .list;
                },
                .settings => unreachable,
                .detail => {
                    self.active_view = switch (self.detail_origin) {
                        .browse => .browse,
                        .history => .history,
                    };
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
        if (self.input_mode == .normal and (key.matches('H', .{ .shift = true }) or key.matches('H', .{}))) {
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
                // Land on a clean Settings state: top row, not editing, and
                // never inheriting a stray search mode from the prior view.
                self.settings.reset();
                self.input_mode = .normal;
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
        if (self.input_mode == .normal and key.matches('h', .{})) {
            if (self.active_view == .browse and self.active_pane == .detail) {
                self.active_pane = .list;
            } else if (self.active_view == .detail) {
                self.active_view = switch (self.detail_origin) {
                    .browse => .browse,
                    .history => .history,
                };
                self.active_pane = .list;
            }
            return;
        }
        // Enter is only handled here in normal mode. In search mode it must fall
        // through to the search mode check below so onSearchKey can lock the results.
        if (self.input_mode == .normal and (key.matches('l', .{}) or key.matches(vaxis.Key.enter, .{}))) {
            switch (self.active_view) {
                .browse => {
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
                },
                .history => {
                    if (key.matches(vaxis.Key.enter, .{})) self.openHistoryDetail(loop, io, provider);
                },
                .detail => {
                    if (key.matches(vaxis.Key.enter, .{})) self.firePlay(loop, io, provider);
                },
                .settings => {},
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
            } else if (self.active_view == .detail) {
                self.active_view = switch (self.detail_origin) {
                    .browse => .browse,
                    .history => .history,
                };
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
        if ((self.active_view == .browse and self.active_pane == .detail) or self.active_view == .detail) {
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
            .detail, .settings => return,
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
        self.cover.flushPendingFree(vx, writer);

        const win = vx.window();
        win.clear();
        win.fill(.{ .style = .{ .bg = self.palette.bg_base } });

        const w = win.width;
        const h = win.height;
        if (h < 4 or w < 16) {
            // Too small to lay out — just say so.
            put(win, 0, 0, "terminal too small", self.s(self.palette.warn, .{}));
            try vx.render(writer);
            return;
        }

        chrome.drawTopBar(self, win, w);
        self.drawContent(vx, writer, win, h);
        chrome.drawToasts(self, win, h);
        chrome.drawBottomBar(self, win, h);

        try vx.render(writer);
    }

    fn drawContent(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer, win: vaxis.Window, h: u16) void {
        // Row 0 is the top bar; row 1 is intentional breathing room; content
        // starts at row 2 and runs to h-2; the bottom bar owns h-1.
        const top: u16 = 2;
        const visible: u16 = h - 3;
        const body_w: u16 = if (win.width > 2) win.width - 2 else 0;

        const w = win.width;

        switch (self.active_view) {
            .history => history.draw(self, &self.scratch, win, top, visible, w, body_w),

            .browse => {
                const pane_h: u16 = visible;
                if (w < 60) {
                    const list_win = win.child(.{ .x_off = 2, .y_off = top, .width = body_w, .height = pane_h });
                    browse.drawBrowseList(self, &self.scratch, list_win, pane_h, body_w);
                    return;
                }

                const list_w: u16 = @max(30, (w * 38) / 100);
                const detail_x: u16 = 2 + list_w + 2;
                const detail_w: u16 = if (w > detail_x + 1) w - detail_x - 1 else 0;

                const list_win = win.child(.{ .x_off = 2, .y_off = top, .width = list_w, .height = pane_h });
                const detail_win = win.child(.{ .x_off = @intCast(detail_x), .y_off = top, .width = detail_w, .height = pane_h });

                browse.drawBrowseList(self, &self.scratch, list_win, pane_h, list_w);
                detail.drawDetailPane(self, vx, writer, detail_win, detail_w, pane_h, w);
            },

            .detail => {
                const detail_win = win.child(.{ .x_off = 2, .y_off = top, .width = body_w, .height = visible });
                detail.drawDetailPane(self, vx, writer, detail_win, body_w, visible, w);
            },

            .settings => settings.drawSettings(self, win, top, visible, w),
        }
    }

    /// Settle the list viewport against the current terminal geometry.
    ///
    /// This is the *state* half of the scroll seam (ROD-155): it used to live
    /// inside the `view/` draw passes, which made a render pass mutate
    /// `list_top` and quietly broke the "draw is a pure function of state"
    /// contract. run() now calls it between tick() and draw(), so the viewport
    /// settles as an explicit state transition and draw() only ever *reads*
    /// `list_top`. `h`/`w` are the full terminal size; the per-view budget math
    /// mirrors drawContent's (content rows = h-3; History packs 2 rows/entry).
    pub fn layout(self: *App, h: u16, w: u16) void {
        // Match draw()'s too-small guard: below this there's no viewport to settle.
        if (h < 4 or w < 16) return;
        const visible: u16 = h - 3;
        switch (self.active_view) {
            // @max(1, …) guards visible=1 producing a zero slot count, which
            // would corrupt list_top via scrollIntoView's arithmetic.
            .history => self.scrollIntoView(@max(1, visible / 2)),
            .browse => self.scrollIntoView(visible),
            .detail, .settings => {},
        }
    }

    pub fn scrollIntoView(self: *App, visible: u16) void {
        const v: usize = visible;
        if (self.list_cursor < self.list_top) {
            self.list_top = self.list_cursor;
        } else if (self.list_cursor >= self.list_top + v) {
            self.list_top = self.list_cursor + 1 - v;
        }
    }

    pub fn historyEntryVisible(self: *const App, title: []const u8) bool {
        if (self.history_filter_len == 0) return true;
        return std.ascii.indexOfIgnoreCase(title, self.history_filter[0..self.history_filter_len]) != null;
    }

    pub fn filteredHistoryLen(self: *const App) usize {
        if (self.history_filter_len == 0) return self.history.len;
        var n: usize = 0;
        for (self.history) |rec| {
            if (self.historyEntryVisible(rec.title)) n += 1;
        }
        return n;
    }
};

const testing = std.testing;

test "paletteFromConfig resolves known names and falls back for unknowns" {
    try testing.expectEqual(&colors.terminal_ghost, paletteFromConfig("terminal_ghost"));
    try testing.expectEqual(&colors.phosphor, paletteFromConfig("phosphor"));
    try testing.expectEqual(&colors.nord, paletteFromConfig("nord"));
    try testing.expectEqual(&colors.terminal_ghost, paletteFromConfig("garbage"));
    try testing.expectEqual(&colors.terminal_ghost, paletteFromConfig(""));
}
