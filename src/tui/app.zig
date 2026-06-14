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
const cover_mod = @import("../cover.zig");
const event_mod = @import("event.zig");
const render = @import("render.zig");
const workers = @import("workers.zig");
const config_mod = @import("../config.zig");

const Allocator = std.mem.Allocator;
const AnimeRecord = store_mod.AnimeRecord;
const Store = store_mod.Store;
const Config = config_mod.Config;
const SourceProvider = source_mod.SourceProvider;
const Anime = domain.Anime;
const Event = event_mod.Event;
const Loop = event_mod.Loop;
const formatMeta = render.formatMeta;
const drawProgressBar = render.drawProgressBar;
const put = render.put;
const putClipped = render.putClipped;
const fillRow = render.fillRow;
const centerText = render.centerText;
const drawWrappedText = render.drawWrappedText;
const title_col = render.title_col;
const meta_col = render.meta_col;
const title_meta_gap = render.title_meta_gap;
const RawCoverCache = workers.RawCoverCache;
const DecodedCoverCache = workers.DecodedCoverCache;
const dupeOptText = workers.dupeOptText;
const dupeOwnedAnime = workers.dupeOwnedAnime;
const freeOwnedAnime = workers.freeOwnedAnime;
const searchTask = workers.searchTask;
const enrichTask = workers.enrichTask;
const loadHistoryTask = workers.loadHistoryTask;
const episodesTask = workers.episodesTask;
const playTask = workers.playTask;
const coverTask = workers.coverTask;
const tickTask = workers.tickTask;
const nowMs = workers.nowMs;
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
    defer app.joinCoverThread();
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

// ── Settings tab model (ROD-86) ─────────────────────────────────────────────
//
// The Settings tab edits `App.config` (ROD-85) in place. Only the *interactive*
// rows live in this table — Catalog's two read-only rows are rendered separately
// and skipped by navigation. Cycle/toggle write scalar or preset-literal fields
// (always safe — presets are static literals); the one editable text field
// (mpv_path) commits into `App.settings_text_buf`.

const SettingId = enum {
    mpv_path,
    default_quality,
    subtitle_language,
    resume_offset,
    skip_mode,
    cover_art,
    kanji_chips,
    palette,
};

const SettingKind = enum { text, cycle, toggle };

const SettingRow = struct {
    id: SettingId,
    label: []const u8,
    kind: SettingKind,
    hint: []const u8,
};

const settings_rows = [_]SettingRow{
    .{ .id = .mpv_path, .label = "mpv path", .kind = .text, .hint = "enter to edit" },
    .{ .id = .default_quality, .label = "default quality", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .subtitle_language, .label = "subtitle language", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .resume_offset, .label = "resume offset", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .skip_mode, .label = "skip mode", .kind = .cycle, .hint = "hjkl to cycle" },
    .{ .id = .cover_art, .label = "cover art", .kind = .toggle, .hint = "space to toggle" },
    .{ .id = .kanji_chips, .label = "kanji chips", .kind = .toggle, .hint = "space to toggle" },
    .{ .id = .palette, .label = "palette", .kind = .cycle, .hint = "hjkl to cycle" },
};

/// Number of interactive (focusable) settings rows — the Catalog rows are not
/// in `settings_rows` and are skipped by navigation. Exposed for tests.
pub const settings_row_count = settings_rows.len;

comptime {
    // `drawSettings` splits this table 0..5 = Player, 5..8 = Interface. Pin the
    // boundary so inserting/removing a row can't silently misattribute it to the
    // wrong group header — this breaks the build instead.
    std.debug.assert(settings_rows.len == 8);
    std.debug.assert(settings_rows[4].id == .skip_mode);
    std.debug.assert(settings_rows[5].id == .cover_art);
}

/// Static-lifetime hairline source for the Settings headers. vaxis stores
/// printed text *by reference* (a cell's grapheme points into the passed
/// slice), so this must outlive vx.render(): a comptime literal lives in
/// rodata; a stack buffer would dangle and render as garbage.
const settings_hairline_cols = 256;
const settings_hairline = "─" ** settings_hairline_cols;

const quality_presets = [_][]const u8{ "480", "720", "1080", "best" };
const language_presets = [_][]const u8{ "sub", "dub" };
const skip_presets = [_][]const u8{ "none", "intro", "outro", "both" };
const resume_presets = [_]u32{ 0, 3, 5, 10, 15, 30 };
const palette_presets = [_][]const u8{ "terminal_ghost", "phosphor", "nord" };

/// Step through a preset list to the value after (`dir > 0`) or before the
/// current one, wrapping. An unrecognized current value starts from index 0.
/// Returns a static preset literal — safe to assign into a config string field.
fn cyclePreset(presets: []const []const u8, current: []const u8, dir: i8) []const u8 {
    var idx: usize = 0;
    for (presets, 0..) |p, i| {
        if (std.mem.eql(u8, p, current)) {
            idx = i;
            break;
        }
    }
    const n = presets.len;
    return presets[if (dir > 0) (idx + 1) % n else (idx + n - 1) % n];
}

fn cyclePresetU32(presets: []const u32, current: u32, dir: i8) u32 {
    var idx: usize = 0;
    for (presets, 0..) |p, i| {
        if (p == current) {
            idx = i;
            break;
        }
    }
    const n = presets.len;
    return presets[if (dir > 0) (idx + 1) % n else (idx + n - 1) % n];
}

fn paletteFromConfig(name: []const u8) *const colors.Palette {
    if (std.mem.eql(u8, name, "phosphor")) return &colors.phosphor;
    if (std.mem.eql(u8, name, "nord")) return &colors.nord;
    return &colors.terminal_ghost;
}

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
    /// Handle for the most recent cover-fetch thread. Joined before a new spawn.
    cover_thread: ?std.Thread = null,
    /// Worker-thread raw-image cache (avoids refetch by URL).
    cover_raw_cache: RawCoverCache = .{},
    /// Worker-thread decoded-pixel cache (avoids re-decode by URL).
    cover_decoded_cache: DecodedCoverCache = .{},
    /// Decoded cover pixels for the currently tracked show id.
    cover_pixels: ?struct { rgba: []u8, w: u32, h: u32 } = null,
    /// Which show id the current cover state belongs to.
    cover_for_id: ?[]const u8 = null,
    /// Whether a cover fetch/decode is in flight.
    cover_loading: bool = false,
    /// Last show id whose cover fetch/decode failed; suppresses immediate refetch
    /// until the selection changes away from that id.
    cover_failed_for_id: ?[]const u8 = null,
    /// Dominant fallback color when Kitty graphics are unavailable.
    cover_fallback_color: vaxis.Color = .default,
    /// Uploaded Kitty image for the current cover, if any.
    cover_image: ?vaxis.Image = null,
    /// Old Kitty image id to delete on the next draw pass.
    pending_cover_free_id: ?u32 = null,
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
    /// only editable *text* field (mpv_path) is committed into
    /// `settings_text_buf` below, so we never free a default literal or the
    /// load arena — we just re-point the slice.
    config: Config = .{},
    /// Resolved config-file path for `save()` on `q` (ROD-86). Borrowed from
    /// run()'s process-lifetime arena. Null when no $HOME/$XDG_CONFIG_HOME — in
    /// which case settings still edit live but can't persist.
    config_path: ?[]const u8 = null,
    /// Active color palette (ROD-87). Points to one of the Palette presets in
    /// colors.zig; updated live when the user cycles the palette setting.
    palette: *const colors.Palette = &colors.terminal_ghost,

    /// Settings tab (ROD-86) cursor over the *interactive* rows only (the two
    /// Catalog rows are non-interactive and skipped by navigation).
    settings_cursor: usize = 0,
    /// Whether the focused text field is in edit mode (captures printable keys).
    settings_editing: bool = false,
    /// Live edit buffer while `settings_editing`; seeded from the field's value.
    settings_edit_buf: [256]u8 = undefined,
    settings_edit_len: usize = 0,
    /// Committed home for an edited mpv_path. `config.mpv_path` is re-pointed
    /// here on confirm, so the edited value outlives the edit buffer without
    /// touching the original literal/arena slice.
    settings_text_buf: [256]u8 = undefined,
    /// Scratch for a formatted settings value (e.g. "5s"). App-owned, not a
    /// draw-local stack buffer, because vaxis keeps the printed slice by
    /// reference until render — a stack buffer would dangle.
    settings_value_buf: [16]u8 = undefined,
    /// Scratch for episode grid cell text (avoids dangling stack buffers in draw).
    /// vaxis stores text by reference, so we need stable storage that survives vx.render().
    /// 8 bytes per slot: "[" + up to 5-char label + "]" + spare = 8. 6 was too tight
    /// for labels like "1000a" — silently fell back to "[?]".
    ep_scratch: [512][8]u8 = undefined,
    /// Stable storage for the "no results for…" message in drawBrowseList.
    no_results_buf: [160]u8 = undefined,
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
    fn querySlice(self: *const App) []const u8 {
        return self.search_query[0..self.search_len];
    }

    /// Palette-aware style: `bg` defaults to `self.palette.bg_base` when null.
    /// All draw methods use this instead of the plain `style()` import so that
    /// switching palettes re-colors every cell, not just ones with explicit bg.
    inline fn s(self: *const App, fg: vaxis.Color, opts: struct {
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
    fn spinnerChar(self: *const App) []const u8 {
        const b = @as(usize, self.spinner_frame) * 3;
        return spinner_frames[b .. b + 3];
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
        self.freeCoverState(vx, writer);
        self.deinitCoverCaches();
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

    fn currentCoverTargetId(self: *const App) ?[]const u8 {
        const anime = self.currentDetailAnime() orelse return null;
        return anime.id;
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
        ) catch {};
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
                    ) catch {};
                }
                if (record_play and self.playing_episode_index > 0) {
                    st.recordPlay(self.playing_source, self.playing_anime_id, self.playing_episode_index, Store.nowSecs()) catch {};
                }
            }
        }

        self.playing = false;
        self.current_position = 0;
        self.current_duration = 0;
        self.clearPlayingSession();
        self.async_start_ms = 0;
    }

    fn invalidateCoverImage(self: *App) void {
        if (self.cover_image) |img| {
            self.pending_cover_free_id = img.id;
            self.cover_image = null;
        }
    }

    fn freeCoverBuffers(self: *App) void {
        if (self.cover_pixels) |px| {
            self.gpa.free(px.rgba);
            self.cover_pixels = null;
        }
        self.cover_fallback_color = .default;
    }

    pub fn clearCoverFailure(self: *App) void {
        if (self.cover_failed_for_id) |id| {
            self.gpa.free(id);
            self.cover_failed_for_id = null;
        }
    }

    fn noteCoverFailure(self: *App, id: []const u8) void {
        self.clearCoverFailure();
        self.cover_failed_for_id = self.gpa.dupe(u8, id) catch null;
    }

    pub fn clearCoverState(self: *App) void {
        self.invalidateCoverImage();
        self.freeCoverBuffers();
        if (self.cover_for_id) |id| {
            self.gpa.free(id);
            self.cover_for_id = null;
        }
        self.cover_loading = false;
    }

    fn flushPendingCoverFree(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer) void {
        if (self.pending_cover_free_id) |id| {
            vx.freeImage(writer, id);
            self.pending_cover_free_id = null;
        }
    }

    fn freeCoverState(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer) void {
        self.flushPendingCoverFree(vx, writer);
        if (self.cover_image) |img| vx.freeImage(writer, img.id);
        self.cover_image = null;
        self.clearCoverState();
        self.clearCoverFailure();
    }

    fn deinitCoverCaches(self: *App) void {
        self.cover_decoded_cache.deinit(self.gpa);
        self.cover_decoded_cache = .{};
        self.cover_raw_cache.deinit(self.gpa);
        self.cover_raw_cache = .{};
    }

    fn joinCoverThread(self: *App) void {
        if (self.cover_thread) |t| {
            t.join();
            self.cover_thread = null;
        }
    }

    fn syncCover(self: *App, loop: *Loop, io: std.Io) void {
        if (builtin.is_test) return;
        const anime = self.currentDetailAnime() orelse return;
        const target_id = self.currentCoverTargetId() orelse return;
        if (self.cover_failed_for_id) |failed_id| {
            if (std.mem.eql(u8, failed_id, target_id)) return;
            self.clearCoverFailure();
        }
        const target_url = anime.thumb orelse {
            if (self.cover_for_id == null or !std.mem.eql(u8, self.cover_for_id.?, target_id)) self.clearCoverState();
            return;
        };
        if (self.cover_for_id) |id| {
            if (std.mem.eql(u8, id, target_id) and (self.cover_loading or self.cover_pixels != null)) return;
        }

        self.joinCoverThread();

        self.clearCoverState();
        self.cover_for_id = self.gpa.dupe(u8, target_id) catch return;
        const id_for_event = self.gpa.dupe(u8, target_id) catch {
            self.clearCoverState();
            return;
        };
        const url_copy = self.gpa.dupe(u8, target_url) catch {
            self.gpa.free(id_for_event);
            self.clearCoverState();
            return;
        };

        self.cover_thread = std.Thread.spawn(.{}, coverTask, .{
            loop,
            self.gpa,
            io,
            url_copy,
            id_for_event,
            &self.cover_raw_cache,
            &self.cover_decoded_cache,
        }) catch {
            self.gpa.free(url_copy);
            self.gpa.free(id_for_event);
            self.clearCoverState();
            return;
        };
        self.cover_loading = true;
        self.async_start_ms = self.now_ms;
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
            st.upsertAnime(rec, Store.nowSecs()) catch {};
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
                if (self.cover_for_id == null or !std.mem.eql(u8, ev.for_id, self.cover_for_id.?)) {
                    self.gpa.free(ev.rgba);
                    return;
                }
                self.cover_loading = false;
                self.joinCoverThread();
                if (!self.search_loading and !self.episode_loading and !self.playing) self.async_start_ms = 0;

                const target_id = self.currentCoverTargetId();
                const keep = target_id != null and std.mem.eql(u8, target_id.?, ev.for_id);
                if (!keep) {
                    self.clearCoverState();
                    self.gpa.free(ev.rgba);
                    return;
                }

                self.clearCoverFailure();
                self.invalidateCoverImage();
                self.freeCoverBuffers();
                self.cover_pixels = .{ .rgba = ev.rgba, .w = ev.width, .h = ev.height };
                self.cover_fallback_color = cover_mod.dominantColor(.{ .rgba = ev.rgba, .w = ev.width, .h = ev.height });
            },
            .cover_error => |for_id| {
                defer self.gpa.free(for_id);
                if (self.cover_for_id == null or !std.mem.eql(u8, for_id, self.cover_for_id.?)) return;
                self.cover_loading = false;
                self.joinCoverThread();
                if (!self.search_loading and !self.episode_loading and !self.playing) self.async_start_ms = 0;
                self.clearCoverState();
                self.noteCoverFailure(for_id);
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

        if (event != .tick) self.syncCover(loop, io);
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

    // ── Settings tab (ROD-86) ───────────────────────────────────────────────

    /// Handle a key while the Settings tab is active. Returns true if the key
    /// was consumed; false lets it fall through to the global chain (F-keys to
    /// switch views, Esc to leave, Ctrl-C to quit).
    fn onSettingsKey(self: *App, key: vaxis.Key, io: std.Io) bool {
        if (self.settings_editing) return self.onSettingsEditKey(key);

        const row = settings_rows[self.settings_cursor];
        if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
            if (self.settings_cursor + 1 < settings_rows.len) self.settings_cursor += 1;
            return true;
        }
        if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
            if (self.settings_cursor > 0) self.settings_cursor -= 1;
            return true;
        }
        if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
            if (row.kind == .cycle) self.settingsCycle(row.id, 1);
            return true;
        }
        if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
            if (row.kind == .cycle) self.settingsCycle(row.id, -1);
            return true;
        }
        if (key.matches(vaxis.Key.space, .{})) {
            if (row.kind == .toggle) self.settingsToggle(row.id);
            return true;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            if (row.kind == .text) self.beginSettingsEdit(row.id);
            return true;
        }
        if (key.matches('q', .{})) {
            self.saveSettings(io);
            self.active_view = .browse;
            self.active_pane = .list;
            return true;
        }
        return false;
    }

    /// Key handling while a text field is being edited. Swallows every key —
    /// except the Ctrl-C emergency quit — so a stray F-key can't switch views
    /// mid-edit; only Esc/Enter resolve the edit itself.
    fn onSettingsEditKey(self: *App, key: vaxis.Key) bool {
        // Ctrl-C must hard-quit from anywhere, including a modal text field.
        if (key.matches('c', .{ .ctrl = true })) return false;
        if (key.matches(vaxis.Key.escape, .{})) {
            self.settings_editing = false; // cancel — discard the buffer
            return true;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            self.commitSettingsEdit();
            return true;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.settings_edit_len > 0) self.settings_edit_len -= 1;
            return true;
        }
        if (key.text) |text| {
            for (text) |ch| {
                // Printable ASCII only — paths and presets never need control bytes.
                if (ch >= 0x20 and ch < 0x7f and self.settings_edit_len < self.settings_edit_buf.len) {
                    self.settings_edit_buf[self.settings_edit_len] = ch;
                    self.settings_edit_len += 1;
                }
            }
        }
        return true;
    }

    fn settingsCycle(self: *App, id: SettingId, dir: i8) void {
        switch (id) {
            .default_quality => self.config.default_quality = cyclePreset(&quality_presets, self.config.default_quality, dir),
            .subtitle_language => {
                self.config.translation = cyclePreset(&language_presets, self.config.translation, dir);
                // Keep the live search translation in lockstep with the setting.
                self.translation = self.config.translationEnum();
            },
            .skip_mode => self.config.skip_mode = cyclePreset(&skip_presets, self.config.skip_mode, dir),
            .resume_offset => self.config.resume_offset_sec = cyclePresetU32(&resume_presets, self.config.resume_offset_sec, dir),
            .palette => {
                self.config.palette = cyclePreset(&palette_presets, self.config.palette, dir);
                self.palette = paletteFromConfig(self.config.palette);
            },
            else => {},
        }
    }

    fn settingsToggle(self: *App, id: SettingId) void {
        switch (id) {
            .cover_art => self.config.cover_art = !self.config.cover_art,
            .kanji_chips => self.config.kanji_chips = !self.config.kanji_chips,
            else => {},
        }
    }

    fn beginSettingsEdit(self: *App, id: SettingId) void {
        const cur: []const u8 = switch (id) {
            .mpv_path => self.config.mpv_path,
            else => return, // only text fields are editable
        };
        const n = @min(cur.len, self.settings_edit_buf.len);
        @memcpy(self.settings_edit_buf[0..n], cur[0..n]);
        self.settings_edit_len = n;
        self.settings_editing = true;
    }

    /// Commit the edit buffer into the field. mpv_path is the only text field;
    /// an empty buffer is treated as a no-op so we never hand mpv a blank argv0.
    fn commitSettingsEdit(self: *App) void {
        defer self.settings_editing = false;
        const n = self.settings_edit_len;
        if (n == 0) return;
        @memcpy(self.settings_text_buf[0..n], self.settings_edit_buf[0..n]);
        self.config.mpv_path = self.settings_text_buf[0..n];
    }

    /// Persist the live config to disk (ROD-85 `save`), toasting the outcome.
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

    /// Display string for a setting's current value. `buf` backs the formatted
    /// scalar values (resume offset, on/off); string fields return a borrow.
    fn settingsValue(self: *App, id: SettingId, buf: []u8) []const u8 {
        return switch (id) {
            .mpv_path => self.config.mpv_path,
            .default_quality => self.config.default_quality,
            .subtitle_language => self.config.translation,
            .skip_mode => self.config.skip_mode,
            .resume_offset => std.fmt.bufPrint(buf, "{d}s", .{self.config.resume_offset_sec}) catch "?",
            .cover_art => if (self.config.cover_art) "on" else "off",
            .kanji_chips => if (self.config.kanji_chips) "on" else "off",
            .palette => self.config.palette,
        };
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
                self.settings_cursor = 0;
                self.settings_editing = false;
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
        self.flushPendingCoverFree(vx, writer);

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

        self.drawTopBar(win, w);
        self.drawContent(vx, writer, win, h);
        self.drawToasts(win, h);
        self.drawBottomBar(win, h);

        try vx.render(writer);
    }

    /// §3.4: the top bar is read-only context, not navigation — `地獄 zigoku`
    /// as one primary H1 unit, then a hairline separator. No tabs here: the tab
    /// system + focus model is ROD-72 and needs a designed home (the active-tab
    /// cyan would collide with the focus color if it lived in this bar).
    fn drawTopBar(self: *App, win: vaxis.Window, w: u16) void {
        put(win, 0, 2, "地獄 zigoku", self.s(self.palette.fg, .{ .bold = true }));
        if (w > 16) put(win, 0, 14, "░", self.s(self.palette.chrome, .{}));

        // Render the chip after the separator (§10.3b).
        const chip_col: u16 = 16;
        const chip: []const u8 = switch (self.active_view) {
            .history => "Watchlist",
            .detail => switch (self.detail_origin) {
                .browse => std.fmt.bufPrint(&self.chip_buf, "{s} search", .{self.spinnerChar()}) catch "⠋ search",
                .history => "Watchlist",
            },
            .settings => "Settings",
            .browse => std.fmt.bufPrint(&self.chip_buf, "{s} search", .{self.spinnerChar()}) catch "⠋ search",
        };
        put(win, 0, chip_col, chip, self.s(self.palette.focus, .{}));

        // Render the · indicator right-aligned (§10.3b).
        const dot_color = switch (self.active_view) {
            .browse => if (self.active_pane == .detail) self.palette.focus else self.palette.fg3,
            .history, .detail, .settings => self.palette.focus,
        };
        if (w > 2) put(win, 0, w - 2, "·", self.s(dot_color, .{}));
    }

    fn drawContent(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer, win: vaxis.Window, h: u16) void {
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
                    putClipped(win, top, 2, body_w, hist_spin, self.s(self.palette.focus, .{}));
                    return;
                }
                if (self.load_error) |msg| {
                    // Hard failure → magenta (state.error = state.now, §1.1).
                    put(win, top, 2, "history unavailable", self.s(self.palette.hot, .{ .bold = true }));
                    putClipped(win, top + 1, 2, body_w, msg, self.s(self.palette.fg3, .{}));
                    return;
                }
                if (self.history.len == 0) {
                    // First-run empty state (§9.2): the void, one quiet line, one
                    // invitation — both centered. `/` wires up in ROD-73.
                    const mid = top + visible / 2;
                    centerText(win, mid -| 1, w, "nothing here yet", self.s(self.palette.fg3, .{ .italic = true }));
                    const action = " to search for a show";
                    const total: u16 = 1 + @as(u16, @intCast(action.len));
                    const start: u16 = if (w > total) (w - total) / 2 else 0;
                    put(win, mid + 1, start, "/", self.s(self.palette.focus, .{ .bold = true }));
                    putClipped(win, mid + 1, start + 1, w -| (start + 1), action, self.s(self.palette.fg2, .{}));
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
                    if (visible_i < self.list_top) {
                        visible_i += 1;
                        continue;
                    }
                    if (row + 1 >= top + visible) break;

                    const selected = visible_i == self.list_cursor;

                    // §4.1 focus affordance: the focused row's background shifts to
                    // bg.surface (a full-width band), its marker is the ▸ play glyph in
                    // focus cyan, and its title goes cyan+bold. Magenta is reserved for
                    // the one cursor in the status bar — never a list marker (§8).
                    const is_completed = std.mem.eql(u8, rec.list_status, "completed");
                    const is_dropped = std.mem.eql(u8, rec.list_status, "dropped");
                    const is_watching = std.mem.eql(u8, rec.list_status, "watching");
                    const is_paused = std.mem.eql(u8, rec.list_status, "paused");

                    const row_bg = if (selected) self.palette.bg_surface else self.palette.bg_base;
                    if (selected) {
                        fillRow(win, row, w, self.palette.bg_surface);
                        fillRow(win, row + 1, w, self.palette.bg_surface);
                    }

                    // §2.4 watchlist status glyphs. Focus `▸` overrides when selected.
                    // Colors: watching/paused=focus(+dim for paused), dropped=fg3, else fg2.
                    const marker: []const u8 =
                        if (selected or is_watching) "▸ "
                        else if (is_completed) "● "
                        else if (is_paused) "◐ "
                        else if (is_dropped) "· "
                        else "○ ";
                    const marker_color =
                        if (selected or is_watching or is_paused) self.palette.focus
                        else if (is_dropped) self.palette.fg3
                        else self.palette.fg2;
                    // §2.4: paused = state.focus + dim (SGR 2), but not when focused row.
                    const marker_dim = is_paused and !selected;
                    put(win, row, 2, marker, self.s(marker_color, .{ .bg = row_bg, .dim = marker_dim }));

                    // §4.1: completed/dropped rows use text.dim for title; watching/planning fg.
                    const de_emphasized = is_completed or is_dropped;
                    const title_style = if (selected)
                        self.s(self.palette.focus, .{ .bg = row_bg, .bold = true })
                    else if (de_emphasized)
                        self.s(self.palette.fg3, .{ .bg = row_bg })
                    else
                        self.s(self.palette.fg, .{ .bg = row_bg });
                    putClipped(win, row, title_col, title_w, rec.title, title_style);

                    if (show_meta and slot < self.meta_scratch.len) {
                        const meta = formatMeta(&self.meta_scratch[slot], rec);
                        putClipped(win, row, meta_col, w - meta_col, meta, self.s(self.palette.fg3, .{ .bg = row_bg }));
                    }

                    // Row 2: §4.5 progress bar (inherits row_bg for the focus band).
                    if (slot < self.bar_scratch.len) {
                        drawProgressBar(win, row + 1, title_col, bar_w, rec, row_bg, &self.bar_scratch[slot], self.palette);
                    }

                    slot += 1;
                    row += 2;
                    visible_i += 1;
                }
            },

            .browse => {
                const pane_h: u16 = visible;
                if (w < 60) {
                    const list_win = win.child(.{ .x_off = 2, .y_off = top, .width = body_w, .height = pane_h });
                    self.drawBrowseList(list_win, pane_h, body_w);
                    return;
                }

                const list_w: u16 = @max(30, (w * 38) / 100);
                const detail_x: u16 = 2 + list_w + 2;
                const detail_w: u16 = if (w > detail_x + 1) w - detail_x - 1 else 0;

                const list_win = win.child(.{ .x_off = 2, .y_off = top, .width = list_w, .height = pane_h });
                const detail_win = win.child(.{ .x_off = @intCast(detail_x), .y_off = top, .width = detail_w, .height = pane_h });

                self.drawBrowseList(list_win, pane_h, list_w);
                self.drawDetailPane(vx, writer, detail_win, detail_w, pane_h, w);
            },

            .detail => {
                const detail_win = win.child(.{ .x_off = 2, .y_off = top, .width = body_w, .height = visible });
                self.drawDetailPane(vx, writer, detail_win, body_w, visible, w);
            },

            .settings => self.drawSettings(win, top, visible, w),
        }
    }

    // ── Settings render (ROD-86, Mira's §5.5 contract) ──────────────────────
    //
    // Columns (relative to the body window): marker 0–1, label @4, value @36,
    // hint right-anchored at w-2-len. Focus matches the Browse list (bg_surface
    // fill, no loud cyan). Edit mode deepens to bg_elevated + a magenta marker.

    const settings_label_col: u16 = 4;
    const settings_value_col: u16 = 36;

    fn drawSettings(self: *App, win: vaxis.Window, top: u16, visible: u16, w: u16) void {
        _ = visible; // settings fits; vaxis clips any overflow against the window
        var y = top;

        // Player — the first five interactive rows.
        y = self.drawSettingsHeader(win, y, w, "Player");
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const r = settings_rows[i];
            self.drawSettingRow(win, y, w, r, self.settingsValue(r.id, &self.settings_value_buf), i == self.settings_cursor);
            y += 1;
        }
        y += 1;

        // Catalog — read-only system state, never focusable (skipped by nav).
        y = self.drawSettingsHeader(win, y, w, "Catalog");
        self.drawInertRow(win, y, w, "enrichment sync", "not available until M4");
        y += 1;
        self.drawInertRow(win, y, w, "cover art cache", "~/.cache/zigoku/covers");
        y += 1;
        y += 1;

        // Interface — the remaining toggle rows.
        y = self.drawSettingsHeader(win, y, w, "Interface");
        while (i < settings_rows.len) : (i += 1) {
            const r = settings_rows[i];
            self.drawSettingRow(win, y, w, r, self.settingsValue(r.id, &self.settings_value_buf), i == self.settings_cursor);
            y += 1;
        }
    }

    fn drawSettingsHeader(self: *const App, win: vaxis.Window, y: u16, w: u16, title: []const u8) u16 {
        put(win, y, settings_label_col, title, self.s(self.palette.fg, .{ .bold = true }));
        // Full-width hairline in `chrome` — a deliberate section boundary. The
        // source is a static literal (see settings_hairline): vaxis keeps the
        // slice by reference until render, so a stack buffer would dangle.
        const cols: u16 = @min(w, settings_hairline_cols);
        put(win, y + 1, 0, settings_hairline[0 .. cols * 3], self.s(self.palette.chrome, .{}));
        return y + 2;
    }

    fn drawSettingRow(self: *App, win: vaxis.Window, y: u16, w: u16, row: SettingRow, value: []const u8, focused: bool) void {
        const editing = focused and self.settings_editing;
        const row_bg = if (editing) self.palette.bg_elevated else if (focused) self.palette.bg_surface else self.palette.bg_base;
        if (editing) {
            fillRow(win, y, w, self.palette.bg_elevated);
        } else if (focused) {
            fillRow(win, y, w, self.palette.bg_surface);
        }

        // ASCII separator on purpose: hint_col is computed from byte length, so a
        // multi-byte glyph (e.g. U+00B7) would misalign the right-anchored hint.
        const hint: []const u8 = if (editing) "esc  enter" else row.hint;
        const hint_len: u16 = @intCast(hint.len);
        const hint_col: u16 = if (w > hint_len + 2) w - 2 - hint_len else 0;

        const marker = if (focused) "▸ " else "  ";
        const marker_color = if (editing) self.palette.hot else self.palette.focus;
        put(win, y, 0, marker, self.s(marker_color, .{ .bg = row_bg }));

        const label_style = if (focused)
            self.s(self.palette.focus, .{ .bg = row_bg, .bold = true })
        else
            self.s(self.palette.fg, .{ .bg = row_bg });
        putClipped(win, y, settings_label_col, settings_value_col -| settings_label_col -| 2, row.label, label_style);

        const value_budget: u16 = if (hint_col > settings_value_col + 2) hint_col - settings_value_col - 2 else 0;
        if (editing) {
            self.drawSettingsEditField(win, y, settings_value_col, value_budget, row_bg);
        } else if (row.kind == .toggle) {
            // §5.5: visual toggle widget. ON = focus cyan; OFF = fg3 dim.
            const is_on = std.mem.eql(u8, value, "on");
            const toggle_color = if (is_on) self.palette.focus else self.palette.fg3;
            const toggle_text: []const u8 = if (is_on) "[████ on ████]" else "[████ off ████]";
            putClipped(win, y, settings_value_col, value_budget, toggle_text, self.s(toggle_color, .{ .bg = row_bg }));
        } else {
            const value_style = if (focused)
                self.s(self.palette.fg, .{ .bg = row_bg })
            else
                self.s(self.palette.fg2, .{ .bg = row_bg });
            putClipped(win, y, settings_value_col, value_budget, value, value_style);
        }

        put(win, y, hint_col, hint, self.s(self.palette.fg3, .{ .bg = row_bg }));
    }

    /// Render the live edit buffer with an inverted cursor block at the end
    /// (input is append-only, so the cursor always trails the text).
    fn drawSettingsEditField(self: *App, win: vaxis.Window, y: u16, col: u16, budget: u16, row_bg: vaxis.Color) void {
        const buf = self.settings_edit_buf[0..self.settings_edit_len];
        const text_budget: u16 = if (budget > 1) budget - 1 else 0;
        putClipped(win, y, col, text_budget, buf, self.s(self.palette.fg, .{ .bg = row_bg }));
        const cursor_off: u16 = @intCast(@min(buf.len, text_budget));
        if (budget > 0) put(win, y, col + cursor_off, " ", self.s(self.palette.fg, .{ .bg = self.palette.hot }));
    }

    /// A non-interactive Catalog row: dim+italic, no marker, no hint.
    fn drawInertRow(self: *const App, win: vaxis.Window, y: u16, w: u16, label: []const u8, value: []const u8) void {
        const sty = self.s(self.palette.fg3, .{ .italic = true });
        putClipped(win, y, settings_label_col, settings_value_col -| settings_label_col -| 2, label, sty);
        putClipped(win, y, settings_value_col, w -| settings_value_col, value, sty);
    }

    fn drawBrowseList(self: *App, win: vaxis.Window, pane_h: u16, pane_w: u16) void {
        const w = pane_w;
        if (self.search_len == 0) {
            const mid = pane_h / 2;
            centerText(win, mid -| 1, w, "no feed yet", self.s(self.palette.fg3, .{ .italic = true }));
            const action = " to start a search";
            const total: u16 = 1 + @as(u16, @intCast(action.len));
            const start: u16 = if (w > total) (w - total) / 2 else 0;
            put(win, mid + 1, start, "/", self.s(self.palette.focus, .{ .bold = true }));
            putClipped(win, mid + 1, start + 1, w -| (start + 1), action, self.s(self.palette.fg2, .{}));
            return;
        }
        const search_pending = self.search_loading or self.debounce_deadline_ms > 0;
        if (search_pending and self.results.items.len == 0) {
            const spin_msg = std.fmt.bufPrint(&self.no_results_buf, "{s} searching\u{2026}", .{self.spinnerChar()}) catch "⠋ searching\u{2026}";
            centerText(win, pane_h / 2, w, spin_msg, self.s(self.palette.focus, .{}));
            return;
        }
        if (!search_pending and self.results.items.len == 0) {
            const q = self.querySlice();
            const msg = std.fmt.bufPrint(&self.no_results_buf, "no results for \"{s}\"", .{q}) catch "no results";
            putClipped(win, 0, 0, w, msg, self.s(self.palette.fg3, .{ .italic = true }));
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

            const row_bg = if (selected) self.palette.bg_surface else self.palette.bg_base;
            if (selected) fillRow(win, row, w, self.palette.bg_surface);

            const marker = if (selected) "▸ " else "  ";
            put(win, row, 0, marker, self.s(self.palette.focus, .{ .bg = row_bg }));

            const title_style = if (selected)
                self.s(self.palette.focus, .{ .bg = row_bg, .bold = true })
            else
                self.s(self.palette.fg, .{ .bg = row_bg });
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
                putClipped(win, row, list_meta_col, w - list_meta_col, meta, self.s(self.palette.fg3, .{ .bg = row_bg }));
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
            const footer_color = if (self.search_loading) self.palette.focus else self.palette.fg3;
            centerText(win, row, w, footer, self.s(footer_color, .{}));
        }
    }

    fn ensureCoverImage(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer) bool {
        if (!vx.caps.kitty_graphics) return false;
        if (self.cover_image != null) return true;
        const px = self.cover_pixels orelse return false;
        if (px.w == 0 or px.h == 0 or px.w > std.math.maxInt(u16) or px.h > std.math.maxInt(u16)) return false;

        const enc_len = std.base64.standard.Encoder.calcSize(px.rgba.len);
        const b64 = self.gpa.alloc(u8, enc_len) catch return false;
        defer self.gpa.free(b64);
        const encoded = std.base64.standard.Encoder.encode(b64, px.rgba);

        self.cover_image = vx.transmitPreEncodedImage(
            writer,
            encoded,
            @intCast(px.w),
            @intCast(px.h),
            .rgba,
        ) catch return false;
        return true;
    }

    fn drawFallbackCover(self: *const App, cover_win: vaxis.Window) void {
        cover_win.fill(.{ .style = .{ .bg = self.cover_fallback_color } });
    }

    fn drawKittyCover(self: *const App, img: vaxis.Image, cover_win: vaxis.Window) void {
        const cols = cover_win.screen.width;
        const rows = cover_win.screen.height;
        if (cols == 0 or rows == 0 or cover_win.width == 0 or cover_win.height == 0) return;

        const pix_per_col = std.math.divCeil(usize, cover_win.screen.width_pix, cols) catch return;
        const pix_per_row = std.math.divCeil(usize, cover_win.screen.height_pix, rows) catch return;
        const slot_w = pix_per_col * cover_win.width;
        const slot_h = pix_per_row * cover_win.height;
        if (slot_w == 0 or slot_h == 0) return;

        const img_w = @as(usize, img.width);
        const img_h = @as(usize, img.height);
        if (img_w == 0 or img_h == 0) return;

        var draw_cols: u16 = cover_win.width;
        var draw_rows: u16 = cover_win.height;

        if (img_w * slot_h > img_h * slot_w) {
            const fit_h_px = @max(@as(usize, 1), (img_h * slot_w) / img_w);
            draw_rows = @intCast(@max(@as(usize, 1), @min(@as(usize, cover_win.height), fit_h_px / pix_per_row)));
        } else if (img_w * slot_h < img_h * slot_w) {
            const fit_w_px = @max(@as(usize, 1), (img_w * slot_h) / img_h);
            draw_cols = @intCast(@max(@as(usize, 1), @min(@as(usize, cover_win.width), fit_w_px / pix_per_col)));
        }

        const draw_win = cover_win.child(.{
            .x_off = @intCast((cover_win.width - draw_cols) / 2),
            .y_off = @intCast((cover_win.height - draw_rows) / 2),
            .width = draw_cols,
            .height = draw_rows,
        });
        img.draw(draw_win, .{ .scale = .fit }) catch self.drawFallbackCover(cover_win);
    }

    fn coverSlotHeight(win: vaxis.Window, cover_w: u16, max_h: u16) u16 {
        if (cover_w == 0 or max_h == 0) return 0;
        if (win.screen.width == 0 or win.screen.height == 0) return max_h;

        const pix_per_col = std.math.divCeil(u32, win.screen.width_pix, win.screen.width) catch return max_h;
        const pix_per_row = std.math.divCeil(u32, win.screen.height_pix, win.screen.height) catch return max_h;
        if (pix_per_col == 0 or pix_per_row == 0) return max_h;

        const slot_w_px = @as(u32, cover_w) * pix_per_col;
        const desired_h_px = std.math.divCeil(u32, slot_w_px * 3, 2) catch return max_h;
        const cover_h = std.math.divCeil(u32, desired_h_px, pix_per_row) catch return max_h;
        return @intCast(@max(@as(u32, 1), @min(@as(u32, max_h), cover_h)));
    }

    fn drawDetailPane(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer, win: vaxis.Window, w: u16, h: u16, term_w: u16) void {
        if (w < 10) return;

        var row: u16 = 0;

        const info = self.detailRenderInfo();
        const anime = info.anime;

        // Cover art block (§3.3 + §7.3/§7.5).
        // Width stays fixed by layout tier; height is derived from terminal pixel
        // geometry so the panel itself stays poster-shaped instead of cell-tall.
        const cover_w: u16 = if (term_w >= 100) 20 else if (term_w >= 80) 14 else 0;
        const cover_h: u16 = if (term_w >= 100) coverSlotHeight(win, cover_w, 28) else if (term_w >= 80) coverSlotHeight(win, cover_w, 20) else 0;
        if (cover_w > 0 and cover_h > 0) {
            const cover_win = win.child(.{ .x_off = 0, .y_off = row, .width = cover_w, .height = cover_h });
            cover_win.fill(.{ .style = .{ .bg = self.palette.bg_surface } });
            if (anime) |a| {
                const has_pixels = self.cover_pixels != null and self.cover_for_id != null and std.mem.eql(u8, self.cover_for_id.?, a.id);
                if (a.thumb == null) {
                    if (cover_h > 1) centerText(cover_win, cover_h / 2, cover_w, "no art yet", self.s(self.palette.fg3, .{ .italic = true }));
                } else if (self.cover_loading and self.cover_for_id != null and std.mem.eql(u8, self.cover_for_id.?, a.id)) {
                    const spin = std.fmt.bufPrint(&self.no_results_buf, "{s}", .{self.spinnerChar()}) catch "⠋";
                    centerText(cover_win, cover_h / 2, cover_w, spin, self.s(self.palette.focus, .{}));
                } else if (has_pixels) {
                    if (self.ensureCoverImage(vx, writer)) {
                        if (self.cover_image) |img| {
                            self.drawKittyCover(img, cover_win);
                        } else {
                            self.drawFallbackCover(cover_win);
                        }
                    } else {
                        self.drawFallbackCover(cover_win);
                    }
                } else if (cover_h > 1) {
                    centerText(cover_win, cover_h / 2, cover_w, "no art yet", self.s(self.palette.fg3, .{ .italic = true }));
                }
            } else if (cover_h > 1) {
                centerText(cover_win, cover_h / 2, cover_w, "no art yet", self.s(self.palette.fg3, .{ .italic = true }));
            }
            row += cover_h + 1;
        }

        // Title — the selected result's name, or placeholder.
        if (anime != null and !std.mem.eql(u8, info.title, "—")) {
            putClipped(win, row, 0, w, info.title, self.s(self.palette.fg, .{ .bold = true }));
        } else {
            putClipped(win, row, 0, w, info.title, self.s(self.palette.fg3, .{}));
        }
        row += 1;

        // Score — placeholder until enrichment lands, then tiered AniList score rendering.
        const score_text: []const u8 = if (anime) |a| blk: {
            if (a.score) |score| {
                if (score >= 91) {
                    break :blk std.fmt.bufPrint(&self.detail_score_buf, "✦ [{d}/100]", .{score}) catch "[--/100]";
                }
                break :blk std.fmt.bufPrint(&self.detail_score_buf, "[{d}/100]", .{score}) catch "[--/100]";
            }
            break :blk "[--/100]";
        } else "[--/100]";
        const score_style = if (anime) |a| blk: {
            if (a.score) |score| {
                if (score >= 91) break :blk self.s(self.palette.hot, .{ .bold = true });
                if (score >= 76) break :blk self.s(self.palette.fg, .{});
                if (score >= 51) break :blk self.s(self.palette.fg2, .{});
            }
            break :blk self.s(self.palette.fg3, .{});
        } else self.s(self.palette.fg3, .{});
        putClipped(win, row, 0, w, score_text, score_style);
        row += 1;

        // Hairline — clipped to window width so it never wraps onto the next row.
        // "─" is 3 UTF-8 bytes; we need exactly `cols` glyphs = `cols * 3` bytes.
        if (row < h) {
            const cols: u16 = @min(w, 160);
            put(win, row, 0, ("─" ** 160)[0 .. @as(usize, cols) * 3],
                self.s(self.palette.chrome, .{}));
        }
        row += 1;

        // Metadata: episode count, falling back to AniList total when needed.
        if (row < h) {
            const meta_style = if (info.has_meta) self.s(self.palette.fg2, .{}) else self.s(self.palette.fg3, .{});
            putClipped(win, row, 0, w, info.meta, meta_style);
            row += 1;
        }

        // Synopsis: real metadata when present, otherwise the existing stub.
        if (row < h) {
            if (anime) |a| {
                if (a.description) |desc| {
                    row += drawWrappedText(win, row, 0, w, h - row, desc, self.s(self.palette.fg2, .{}));
                } else {
                    putClipped(win, row, 0, w, "no synopsis yet", self.s(self.palette.fg2, .{ .italic = true }));
                    row += 1;
                }
            } else {
                putClipped(win, row, 0, w, "no synopsis yet", self.s(self.palette.fg2, .{ .italic = true }));
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
            centerText(win, 0, w, "⠋ loading episodes…", self.s(self.palette.focus, .{}));
            return;
        }
        const eps = self.episode_results orelse {
            // No fetch fired yet (detail pane opened but no item selected).
            return;
        };
        if (eps.len == 0) {
            putClipped(win, 0, 0, w, "no episodes", self.s(self.palette.fg3, .{ .italic = true }));
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
                    self.s(self.palette.focus, .{ .bg = self.palette.bg_surface, .bold = true })
                else
                    self.s(self.palette.fg2, .{});

                if (focused) {
                    const cell_win = win.child(.{
                        .x_off = @intCast(col_off),
                        .y_off = @intCast(grid_row),
                        .width = cell_w,
                        .height = 1,
                    });
                    cell_win.fill(.{ .style = .{ .bg = self.palette.bg_surface } });
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
            put(win, row, 2, "/", self.s(self.palette.focus, .{ .bold = true }));
            const cursor_col: u16 = 3 + @as(u16, @intCast(q.len));
            if (q.len > 0) {
                putClipped(win, row, 3, cursor_col -| 3, q, self.s(self.palette.fg, .{ .bold = true }));
            }
            if (cursor_col < w) put(win, row, cursor_col, "_", self.s(self.palette.focus, .{ .bold = true }));
            // Right-aligned count (text.muted = fg2 per §3.5).
            const cnt: []const u8 = if ((self.search_loading or self.debounce_deadline_ms > 0) and self.results.items.len == 0)
                "…"
            else if (self.results.items.len > 0)
                std.fmt.bufPrint(&self.cnt_scratch, "[{d} results]", .{self.results.items.len}) catch ""
            else if (self.search_len > 0)
                "[0 results]"
            else
                "";
            if (cnt.len > 0) {
                const cnt_col: u16 = if (w > @as(u16, @intCast(cnt.len)) + 1) w - @as(u16, @intCast(cnt.len)) - 1 else 0;
                // Overlap guard: suppress count if it would collide with the cursor.
                if (cnt_col > cursor_col + 1) {
                    putClipped(win, row, cnt_col, @as(u16, @intCast(cnt.len)), cnt, self.s(self.palette.fg2, .{}));
                }
            }
            return;
        }

        // Search mode in History: suppress ▌, show /filter_ + filtered count.
        if (self.active_view == .history and self.input_mode == .search) {
            const q = self.history_filter[0..self.history_filter_len];
            put(win, row, 2, "/", self.s(self.palette.focus, .{ .bold = true }));
            const cursor_col: u16 = 3 + @as(u16, @intCast(q.len));
            if (q.len > 0) {
                putClipped(win, row, 3, cursor_col -| 3, q, self.s(self.palette.fg, .{ .bold = true }));
            }
            if (cursor_col < w) put(win, row, cursor_col, "_", self.s(self.palette.focus, .{ .bold = true }));
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
                    putClipped(win, row, cnt_col, @as(u16, @intCast(cnt.len)), cnt, self.s(self.palette.fg2, .{}));
                }
            }
            return;
        }

        // When anything is loading, replace the ▌ with an animated spinner.
        const any_loading = self.search_loading or self.history_loading or
            self.episode_loading or self.cover_loading or self.debounce_deadline_ms > 0;
        if (any_loading) {
            const spin_color: vaxis.Color = if (self.async_start_ms > 0 and
                self.now_ms - self.async_start_ms > 3000)
                self.palette.hot
            else
                self.palette.focus;
            put(win, row, 2, self.spinnerChar(), self.s(spin_color, .{}));
        } else {
            put(win, row, 2, "▌", self.s(self.palette.hot, .{ .blink = true }));
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
            .detail => "hjkl scroll · h back · enter play · q back",
            .settings => if (self.settings_editing)
                "type to edit · enter confirm · esc cancel"
            else
                "hjkl navigate · space toggle · enter edit · esc cancel · q save & back",
        };
        putClipped(win, row, 4, if (w > 4) w - 4 else 0, help, self.s(self.palette.fg3, .{}));
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
            // §4.7 color map: info=[~] fg2(text.muted), success=[✓] fg(state.success),
            //   error=[!] hot, warn=[!] warn.
            const fg_color: vaxis.Color = switch (t.kind) {
                .@"error" => self.palette.hot,
                .warn => self.palette.warn,
                .success => self.palette.fg,
                .info => self.palette.fg2,
            };
            const prefix: []const u8 = switch (t.kind) {
                .@"error", .warn => "[!] ",
                .success => "[✓] ",
                .info => "[~] ",
            };
            const w = win.width;
            // §4.7: right-aligned, max 40 display columns.
            // All prefixes are exactly 4 display cells regardless of UTF-8 byte length
            // ([✓] = 6 bytes but 4 cells; ASCII variants are 4 bytes = 4 cells).
            const pre_w: u16 = 4;
            const txt_len: u16 = @intCast(t.text_len);
            const toast_w: u16 = @min(pre_w + txt_len, @min(40, w -| 2));
            const pre_col: u16 = if (w > toast_w + 1) w - toast_w - 1 else 0;
            fillRow(win, row, w, self.palette.bg_elevated);
            put(win, row, pre_col, prefix, self.s(fg_color, .{ .bold = true, .bg = self.palette.bg_elevated }));
            const txt_col: u16 = pre_col + pre_w;
            const txt_w: u16 = if (toast_w > pre_w) toast_w - pre_w else 0;
            putClipped(win, row, txt_col, txt_w, t.text[0..t.text_len], self.s(fg_color, .{ .bg = self.palette.bg_elevated }));
            row -|= 1;
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

    fn historyEntryVisible(self: *const App, title: []const u8) bool {
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
