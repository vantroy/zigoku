//! TUI shell: vaxis lifecycle, event loop, App state, worker-to-UI seam (ROD-71).
//!
//! tick mutates state; draw is pure. Background work posts via Loop.postEvent.
//! Startup view comes from config.landingEnum.

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
const anilist = @import("../anilist.zig");
const paths = @import("../paths.zig");
const log = @import("../log.zig");
const auth_mod = @import("../auth.zig");

const chrome = @import("view/chrome.zig");
const history = @import("view/history.zig");
const browse = @import("view/browse.zig");
const detail = @import("view/detail.zig");
const settings = @import("view/settings.zig");
const discover_view = @import("view/discover.zig");
const connect_view = @import("view/connect.zig");
const discover_covers_mod = @import("discover_covers.zig");
const login_loopback = @import("../login_loopback.zig");

const selection = @import("selection.zig");
const input = @import("input.zig");
const resolve = @import("resolve.zig");

const Allocator = std.mem.Allocator;
const AnimeRecord = store_mod.AnimeRecord;
const Store = store_mod.Store;
const Config = config_mod.Config;
const SourceProvider = source_mod.SourceProvider;
const Registry = source_mod.Registry;
const Anime = domain.Anime;
const Event = event_mod.Event;
const Loop = event_mod.Loop;
const put = render.put;
const dupeOptText = workers.dupeOptText;
const dupeOwnedStrList = workers.dupeOwnedStrList;
const dupeOwnedAnime = workers.dupeOwnedAnime;
const freeOwnedAnime = workers.freeOwnedAnime;
const searchTask = workers.searchTask;
const loadHistoryTask = workers.loadHistoryTask;
const reloadHistoryTask = workers.reloadHistoryTask;
const episodesTask = workers.episodesTask;
const playTask = workers.playTask;
const tickTask = workers.tickTask;
const nowMs = workers.nowMs;

/// After this many ms, in-flight spinners switch to the slow-path `hot` colour.
const slow_path_threshold_ms: i64 = 3000;

// Subsystems carved out of App; re-exported so existing `app_mod.*` sites keep working.
pub const CoverState = @import("cover_state.zig").CoverState;
const settings_state = @import("settings_state.zig");
pub const SettingsState = settings_state.SettingsState;
pub const SettingId = settings_state.SettingId;
pub const SettingKind = settings_state.SettingKind;
pub const SettingRow = settings_state.SettingRow;
pub const settings_rows = settings_state.settings_rows;
pub const settings_row_count = settings_state.settings_row_count;
pub const PlaybackSession = @import("playback_session.zig").PlaybackSession;
pub const EpisodeState = @import("episode_state.zig").EpisodeState;
// Search transport (threads, debounce, fireSearch) stays on App; record lives in search_state.
pub const SearchController = @import("search_state.zig").SearchController;
pub const DiscoverState = @import("discover_state.zig").DiscoverState;
pub const DiscoverCovers = @import("discover_covers.zig").DiscoverCovers;
pub const PrewarmState = @import("prewarm_state.zig").PrewarmState;
pub const ResolveTransport = @import("resolve_state.zig").ResolveTransport;

/// Run the TUI to completion. `store` is optional: a DB hiccup means no history, not a refused launch.
pub fn run(
    gpa: Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    store: ?*Store,
    registry: Registry,
    config: Config,
    config_path: ?[]const u8,
    app_version: []const u8,
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
    try vx.queryTerminal(writer, .fromMilliseconds(500));

    // vaxis only sets caps.rgb from XTGETTCAP; terminals that do truecolor but skip
    // that reply (vhs, some tmux/ssh) need COLORTERM=truecolor|24bit (upstream check is off).
    if (environ_map.get("COLORTERM")) |ct| {
        if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit"))
            vx.caps.rgb = true;
    }

    // Drop queryTerminal leftovers before first paint: CPR `\e[1;1R` parses as F3 and
    // would hit the Discover keybind (ROD-249). getWinsize below covers a swallowed .winsize.
    while (loop.tryEvent() catch null) |_| {}

    // First paint needs resize now: vx.window() reads screen, only populated by resize (else 0x0).
    if (tty.getWinsize()) |ws| try vx.resize(gpa, writer, ws) else |_| {}

    var app: App = .{};
    app.gpa = gpa;
    app.store = store;
    app.config = config;
    app.config_path = config_path;
    app.app_version = std.fmt.bufPrint(&app.version_buf, "v{s}", .{app_version}) catch app_version;
    // Pixel metrics from settled screen (winsize was drained above).
    // Discover cover-fill needs them on frame 1 (ROD-247).
    app.term_x_pixel = @intCast(vx.screen.width_pix);
    app.term_y_pixel = @intCast(vx.screen.height_pix);
    // Settings "cover art cache" row; null if cache home missing (ROD-225).
    app.cover_cache_display = blk: {
        const abs = workers.coverCacheDir(gpa) catch break :blk null;
        defer gpa.free(abs);
        break :blk paths.collapseHome(gpa, abs) catch null;
    };
    app.palette = paletteFromConfig(config.palette);
    app.translation = config.translationEnum();
    // last_watched starts as History; resume-landing may retarget after load (ROD-228/229).
    app.active_view = switch (config.landingEnum()) {
        .browse => .browse,
        .history, .last_watched => .history,
    };
    // Provider row presets: names are static vtable strings; only the slice is owned
    // and must outlive the loop (ROD-344).
    const provider_names = try gpa.alloc([]const u8, registry.providers.len);
    defer gpa.free(provider_names);
    for (registry.providers, 0..) |p, pi| provider_names[pi] = p.name();
    app.settings.provider_names = provider_names;
    defer app.deinitOwnedState(&vx, writer);

    // Token once into session arena (best-effort; absent token leaves armSyncFlush a no-op).
    // auth_arena.deinit is registered before the sync-thread join, so LIFO frees the token
    // only after that join on error-unwind (quit skips both via `_exit`). ROD-291.
    var auth_arena = std.heap.ArenaAllocator.init(gpa);
    defer auth_arena.deinit();
    if (auth_mod.defaultPath(auth_arena.allocator())) |auth_path| {
        app.anilist_auth = auth_mod.load(auth_arena.allocator(), io, auth_path);
        app.anilist_connected = app.anilist_auth.hasAniList() and
            !app.anilist_auth.anilist.isExpired(Store.nowSecs());
    } else |e| {
        log.debug("anilist: no config dir for token: {s}", .{@errorName(e)});
    }

    // Seed now_ms so a pre-first-tick mutation (harness keypress) does not arm debounce from 0 (ROD-291).
    app.now_ms = nowMs(io);

    // Double-buffer: live history slice stays valid while reload fills the idle arena (ROD-191).
    // A slice handed to vaxis must outlive the frame (ROD-141).
    var hist_arenas: [2]std.heap.ArenaAllocator = .{
        std.heap.ArenaAllocator.init(gpa),
        std.heap.ArenaAllocator.init(gpa),
    };
    defer for (&hist_arenas) |*a| a.deinit();
    var hist_live: usize = 0;

    var hist_thread: ?std.Thread = null;
    // Interrupt in-flight SELECT before join so teardown never blocks on loadHistory.
    // Declared before search/episode drains so LIFO runs after them: interrupt only hits this statement.
    defer if (hist_thread) |t| {
        if (store) |st| st.interrupt();
        t.join();
    };
    if (store) |st| {
        hist_thread = std.Thread.spawn(.{}, loadHistoryTask, .{ &loop, hist_arenas[0].allocator(), st }) catch blk: {
            // Sync fallback so history still shows; resume-landing same as the async path (ROD-229).
            app.setHistory(st.loadHistory(hist_arenas[0].allocator()) catch &.{});
            app.maybeResumeLanding(&loop, io, registry);
            break :blk null;
        };
    } else {
        app.history_loading = false;
    }

    // After loop.stop defer so LIFO joins search before loop teardown.
    defer if (app.search_thread) |t| t.join();
    // Error-unwind/test only; quit `_exit` skips this. Safe to abandon (WAL crash-safe, idempotent push): row stays dirty, re-flushes next session (ROD-291).
    defer if (app.sync_thread) |t| t.join();
    // Error-unwind/test: cancel+join+close. Quit `_exit` abandons; worker skips postEvent on cancel (ROD-286).
    defer app.teardownConnect(io);
    // ThreadDrain contract (all 7, incl. discover_cover below): begin() before spawn, finish() after the worker's last postEvent, drain() only on teardown.
    defer app.discover_drain.drain();
    defer app.episode_drain.drain();
    defer app.enrich_refresh_drain.drain(); // ROD-182 refresh-on-view
    defer app.resolve.add_drain.drain(); // ROD-327 tier-A add-resolve
    defer app.resolve.play_drain.drain(); // ROD-328 tier-C Play resolve
    defer app.prewarm.drain.drain(); // ROD-351 pre-warm walk
    defer app.cover.joinThread();
    // Error-unwind/test; quit `_exit` abandons (Kitty clear drops images). Blocks until cover workers finish (ROD-240).
    defer app.discover_cover_drain.drain();
    // Error-unwind/test; may wait ~6s extra on CDN backoff (ROD-309).
    defer if (app.play_thread) |t| t.join();

    // Declared after loop.stop defer so LIFO joins tick first.
    var tick_quit: std.atomic.Value(bool) = .init(false);
    const tick_thread = std.Thread.spawn(.{}, tickTask, .{ &loop, io, &tick_quit }) catch null;
    defer {
        tick_quit.store(true, .release);
        if (tick_thread) |t| t.join();
    }

    // One reload at a time; flip hist_live only on success. Mid-reload play leaves dirty set (ROD-191).
    var reload_inflight = false;
    var reload_settled_at_spawn: u32 = 0;

    // Ambient pull-on-launch when connected; shares the one-flush gate with action sync (ROD-293).
    app.fireLaunchPull(&loop, io);

    // Best-effort GH release check; skipped if disabled or under test (ROD-370).
    const update_thread: ?std.Thread = if (config.check_for_updates and !builtin.is_test)
        std.Thread.spawn(.{}, workers.updateCheckTask, .{ &loop, gpa, io, app_version }) catch null
    else
        null;
    defer if (update_thread) |t| t.join();

    {
        const win = vx.window();
        app.layout(win.height, win.width);
    }
    try app.draw(&vx, writer);
    while (!app.should_quit) {
        const event = try loop.nextEvent();
        // run() owns resize so tick stays a pure state fold (no tty in tests).
        if (event == .winsize) {
            try vx.resize(gpa, writer, event.winsize);
            app.term_x_pixel = @intCast(vx.screen.width_pix);
            app.term_y_pixel = @intCast(vx.screen.height_pix);
        }
        try app.tick(event, &loop, io, registry);

        // Latch clears on success or failure (SQLITE_BUSY must not wedge future reloads).
        // Flip hist_live only on success: on failure the live slice still points at the old arena.
        if (reload_inflight and app.history_reload_settled != reload_settled_at_spawn) {
            if (hist_thread) |t| t.join();
            hist_thread = null;
            if (app.history_reload_ok) hist_live = 1 - hist_live;
            reload_inflight = false;
        }
        // Wait for initial load (!history_loading) so a stale .history_loaded cannot clobber a reload;
        // never stack two reloads (!reload_inflight).
        if (app.history_dirty and !reload_inflight and !app.history_loading) {
            if (store) |st| {
                if (hist_thread) |t| t.join();
                hist_thread = null;
                const next = 1 - hist_live;
                // Previous worker joined; live slice is in the other arena.
                _ = hist_arenas[next].reset(.retain_capacity);
                reload_settled_at_spawn = app.history_reload_settled;
                hist_thread = std.Thread.spawn(.{}, reloadHistoryTask, .{ &loop, hist_arenas[next].allocator(), st }) catch null;
                if (hist_thread != null) {
                    reload_inflight = true;
                    app.history_dirty = false;
                } else {
                    // Flip only on success; keep current slice on transient load failure.
                    if (st.loadHistory(hist_arenas[next].allocator())) |recs| {
                        app.setHistory(recs);
                        hist_live = next;
                    } else |e| {
                        log.debug("sync history reload failed: {s}", .{@errorName(e)});
                    }
                    app.history_dirty = false;
                }
            } else {
                app.history_dirty = false;
            }
        }

        // layout is the scroll state half; draw only reads list_top (ROD-155).
        const win = vx.window();
        app.layout(win.height, win.width);
        // After scroll settles (geometry known). No-op outside Discover / when nothing missing.
        app.pumpDiscoverCovers(&loop, io, registry);
        app.maybeFillDiscover(&loop, io);
        try app.draw(&vx, writer);
    }

    // Fast-exit on quit (ROD-232): durable work already landed (settings sync-save, position
    // checkpoints on the main thread). Abandon workers rather than join: withDeadline can sit
    // 5s+ and deadlock if the event queue fills while the loop stopped popping (ROD-153/179).
    // Must `_exit`, not return (workers still postEvent into the queue) and not process.exit
    // (libc atexit/stdio flush while workers run). Defers above cover error-unwind and tests only.
    //
    // next_img_id starts at 1 and only transmitImage bumps it, so >1 means a cover was sent (ROD-238).
    const transmitted_cover = vx.next_img_id > 1;
    if (vx.caps.kitty_graphics) {
        // Leaving alt-screen does not reliably clear Kitty graphics. q=2 so the delete is not
        // acked onto the prompt. Pure write: does not free cover caches workers may still read.
        writer.writeAll(kitty_graphics_clear_quiet) catch {};
    }
    // alloc=null: restore terminal without frees (_exit reclaims; keeps us off vx.screen).
    // Output path cannot race the tty reader (it only reads input).
    vx.deinit(null, writer);
    // Before tty.deinit closes the fd. Safe vs parked reader: Loop.ttyRun swallows read errors.
    if (transmitted_cover) drainTtyResponses(tty.fd.handle);
    tty.deinit();
    // Last act before _exit: bounded AniList push of dirty rows (mirror of launch pull). No-op when
    // disconnected or a sync worker is inflight (never push alongside a pull; ROD-285/294).
    app.quitFlush(io);
    std.c._exit(0);
}

/// Kitty delete-all with q=2 so the terminal does not ack onto the shell on `_exit` (ROD-238).
const kitty_graphics_clear_quiet = "\x1b_Ga=d,q=2\x1b\\";

/// Residual tty sweep before ROD-232 `_exit` (ROD-238). Covers are placed with q=2 so the old
/// `_Gi=N;OK` flood is gone; this only drains bytes already in the buffer so they do not echo.
/// Not a sentinel fence: a sentinel's own reply can leak over high-latency links (ROD-236).
/// Drain what has arrived, stop on empty poll, leave fd non-blocking (_exit next).
pub fn drainTtyResponses(fd: std.posix.fd_t) void {
    // Zig 0.16 moved fcntl behind Io; with libc linked, std.c.fcntl is the escape hatch.
    const cur = std.c.fcntl(fd, std.c.F.GETFL);
    if (cur == -1) return;
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
    if (std.c.fcntl(fd, std.c.F.SETFL, cur | nonblock) == -1) return;

    const poll_ms: c_int = 20;
    const max_rounds: u8 = 4;
    var buf: [4096]u8 = undefined;
    var rounds: u8 = 0;
    while (rounds < max_rounds) : (rounds += 1) {
        var pfd = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
        _ = std.c.poll(&pfd, 1, poll_ms);
        if ((pfd[0].revents & std.c.POLL.IN) == 0) break;
        inner: while (true) {
            const n = std.posix.read(fd, &buf) catch break :inner;
            if (n == 0) break :inner;
        }
    }
}

pub const Toast = struct {
    pub const Kind = enum { info, success, @"error", warn };
    /// Box width includes the 4-col glyph prefix; dynamic copy gets max_copy_cols (ROD-166).
    pub const max_box_cols: u16 = 40;
    pub const glyph_cols: u16 = 4; // "[!] "/"[✓] "/"[~] " each paint 4 cells
    pub const max_copy_cols: u16 = max_box_cols - glyph_cols;
    /// Persistent-error owner so one view's recovery cannot clear another's (ROD-239).
    pub const Topic = enum { general, feed };
    kind: Kind,
    text: [80]u8 = undefined,
    text_len: usize = 0,
    /// Remaining TTL in ms. Ignored when persistent.
    ttl_ms: i32 = 4000,
    /// Survives TTL; cleared only by a recovery path.
    persistent: bool = false,
    topic: Topic = .general,
};

pub fn paletteFromConfig(name: []const u8) *const colors.Palette {
    if (std.mem.eql(u8, name, "phosphor")) return &colors.phosphor;
    if (std.mem.eql(u8, name, "nord")) return &colors.nord;
    if (std.mem.eql(u8, name, "tokyonight")) return &colors.tokyonight;
    return &colors.terminal_ghost;
}

/// Per-frame render scratch. vaxis holds text by reference until vx.render();
/// loop-local buffers would dangle. Separate from App state so list passes take
/// `*const App` and only write here (ROD-155).
pub const RenderScratch = struct {
    /// Soft cap 256: overflow rows paint without meta (no crash).
    meta: [256][48]u8 = undefined,
    bar: [256][32]u8 = undefined,
    /// Separate from `meta`: both paint the same Browse row until render (ROD-226).
    score: [256][8]u8 = undefined,
    /// Shared by Browse/History (one list view per frame). Not for detail: split
    /// layout co-renders list+detail, so detail uses `detail_msg` to avoid clobber.
    msg: [160]u8 = undefined,
    /// Split-frame cover spinner; must not alias `msg` (ROD-155).
    detail_msg: [32]u8 = undefined,
    /// History group "(N)" counts (ROD-139). Past 8 headers: count omitted.
    hist_header: [8][24]u8 = undefined,
    /// Discover titles (ROD-245). [80] = 19 cols × 4-byte code points + "…" (79);
    /// truncateToWidth also guards the byte budget.
    title: [256][80]u8 = undefined,
    /// Discover badges; separate from Browse `score` so both can live one frame (ROD-247).
    disc_badge: [256][8]u8 = undefined,
    disc_genre: [256][48]u8 = undefined,
};

/// Single-level undo for manual watch-state mutations (ROD-193). Full revert
/// payload so applyUndo does not re-read the store.
pub const UndoEntry = union(enum) {
    set_list_status: struct {
        source: []u8, // GPA-owned, duped at push
        source_id: []u8, // GPA-owned, duped at push
        prev_status: domain.ListStatus,
        prev_progress: i64,
    },

    pub fn free(self: UndoEntry, gpa: Allocator) void {
        switch (self) {
            .set_list_status => |e| {
                gpa.free(e.source);
                gpa.free(e.source_id);
            },
        }
    }
};

/// In-TUI AniList connect modal (ROD-286). Non-null only while the modal is up.
/// Worker-touched fields live in the boxed arena so addresses stay stable wherever
/// this optional sits in App. Torn down by `App.teardownConnect`.
pub const ConnectState = struct {
    /// Heap-boxed so listener/cancel keep stable addresses across the thread seam.
    /// Freed in teardownConnect only after the worker is joined.
    arena: *std.heap.ArenaAllocator,
    listener: *login_loopback.Listener,
    /// Set (release) before requestCancel so the woken accept bails.
    cancel: *std.atomic.Value(bool),
    thread: ?std.Thread,
    /// Latched by [c]; serviced in draw (owns the tty), then sets `copied`.
    copy_requested: bool = false,
    copied: bool = false,
    started_ms: i64 = 0,
    /// Modal status line; App/flow-owned, not draw-local (vaxis by-reference).
    status_buf: [48]u8 = undefined,
};

pub const App = struct {
    /// Detail-rail provider ceiling (ROD-348). Past this, providers drop silently
    /// (serving marker included). Widen `detail_provider_buf` first if raising.
    pub const max_rail_providers = 8;

    should_quit: bool = false,

    /// Backed by run()'s history arena; App only reads.
    history: []AnimeRecord = &.{},
    history_loading: bool = true,
    load_error: ?[]const u8 = null,

    /// Meaningful playback changed store history the live slice may miss (ROD-191).
    /// run() reloads between frames, never mid-render.
    history_dirty: bool = false,
    /// Bumped on reload success or failure so a failed reload cannot latch the reloader off.
    /// Only frame-to-frame inequality is used.
    history_reload_settled: u32 = 0,
    /// Gates the double-buffer flip: true only when setHistory actually swapped the slice.
    history_reload_ok: bool = false,

    /// Resume-landing one-shot after the INITIAL history load, never post-playback reload (ROD-229).
    resume_landing_done: bool = false,
    /// Auto-opened resume grid in flight; on failure demote to History, not a blank detail (ROD-229).
    resume_landing_pending: bool = false,

    /// Open show's pin, cached at grid-open so render never reads the DB (ROD-345). Null = unpinned.
    show_pin: ?[]u8 = null,

    /// Per-provider availability for the open show, aligned with settings.provider_names (ROD-348).
    /// Null show_avail_aid: omit Provider field. Re-read on bind/absence writes.
    show_avail: [max_rail_providers]Store.ProviderAvailability = @splat(.unchecked),
    show_avail_aid: ?i64 = null,

    history_filter: [128]u8 = undefined,
    history_filter_len: usize = 0,

    list_cursor: usize = 0,
    list_top: usize = 0,

    /// Hard-delete confirm: history index awaiting y/Y (ROD-220). Separate key from X so
    /// key-repeat cannot arm and fire in one burst.
    confirm_delete: ?usize = null,

    /// See RenderScratch (vaxis by-reference + *const App list passes).
    scratch: RenderScratch = .{},

    /// Default .history; run() overwrites from config.landingEnum before first frame (ROD-228).
    active_view: enum { browse, history, detail, settings, discover } = .history,
    detail_origin: enum { browse, history, discover } = .browse,

    /// List vs detail focus in split Browse/History (ROD-170). Drives h/l, top-bar ·,
    /// and selection step-down when detail is focused (ROD-194). Settings pins .list.
    active_pane: enum { list, detail } = .list,

    input_mode: enum { normal, search } = .normal,

    /// Record only; transport (threads, debounce, async_start_ms) stays on App (ROD-219).
    search: SearchController = .{},

    /// Record only; feed worker transport stays on App (ROD-239).
    discover: DiscoverState = .{},

    /// Set in run() before the loop; only valid after that.
    gpa: Allocator = undefined,

    /// At most one search thread: joined before next spawn and on teardown.
    search_thread: ?std.Thread = null,

    /// Discover feed workers: superseded fetches detach; stale results land in their
    /// axis slot; teardown waits the set (no join on the event thread; ROD-251/239).
    discover_drain: workers.ThreadDrain = .{},

    /// Discover cover fan-out (ROD-240). inflight gates pump concurrency and is the teardown barrier.
    discover_cover_drain: workers.ThreadDrain = .{},

    translation: domain.Translation = .sub,

    /// Episode fetches: superseded detach, not join (ROD-179).
    episode_drain: workers.ThreadDrain = .{},
    /// Refresh-on-view enrich workers (ROD-182).
    enrich_refresh_drain: workers.ThreadDrain = .{},
    /// Tier-A/tier-C in-flight resolve state + provider-fallback walk (ROD-327/328/346/401).
    resolve: ResolveTransport = .{},
    /// Eager pre-warm walk (ROD-351/401).
    prewarm: PrewarmState = .{},
    /// Episode list/cursor/cache; transport on App (ROD-180).
    episodes: EpisodeState = .{},
    cover: CoverState = .{},
    /// Shared URL-keyed caches for single-cover and Discover grid under one lock (ROD-243).
    cover_caches: workers.CoverCaches = .{},
    /// Discover multi-cover pool; shares cover_caches (ROD-243).
    discover_covers: DiscoverCovers = .{},
    play_thread: ?std.Thread = null,
    playing: bool = false,
    current_position: f64 = 0,
    current_duration: f64 = 0,
    /// Playing show/episode/checkpoint record; transport stays on App (ROD-162).
    session: PlaybackSession = .{},
    store: ?*Store = null,
    /// String fields arena-borrowed for the session. Settings re-points mpv_path into
    /// text_buf; never free a default literal or the load arena (ROD-85/86).
    config: Config = .{},
    /// save() path; null means live edits only, no persist (ROD-86).
    config_path: ?[]const u8 = null,
    /// Settings version row; slice into version_buf (ROD-370).
    app_version: []const u8 = "",
    version_buf: [16]u8 = undefined,
    palette: *const colors.Palette = &colors.terminal_ghost,

    settings: SettingsState = .{},
    /// Episode grid cell text. Do not use `% len` indexing: that aliases cell N onto
    /// N-len mid-frame (ROD-396). Past the cap, borrow the owned label (scratchSlotFor).
    /// [16] leaves headroom for "[▸XX]" / "[1000a]" (ROD-192).
    ep_scratch: [2048][16]u8 = undefined,
    detail_score_buf: [32]u8 = undefined,
    /// Episode-count value for the meta grammar; must outlive the frame (ROD-141/260).
    detail_meta_buf: [32]u8 = undefined,
    /// Own buffer so it cannot collide with detail_meta_buf when both fields emit (ROD-261).
    detail_studios_buf: [64]u8 = undefined,
    detail_duration_buf: [16]u8 = undefined,
    detail_source_buf: [24]u8 = undefined,
    detail_rank_buf: [24]u8 = undefined,
    /// "▸senshi +megaplay"; widen or omit if registry grows past budget (ROD-348/356).
    detail_provider_buf: [96]u8 = undefined,
    detail_airing_buf: [24]u8 = undefined,
    detail_meta_fields: [8]MetaField = undefined,
    /// Season chip; stack local would dangle by render (ROD-141).
    detail_season_buf: [16]u8 = undefined,
    /// Scope-tagged result count; [16] was one byte short for "[catalogue · NN]" (ROD-211).
    cnt_scratch: [32]u8 = undefined,
    /// Delete-confirm title when truncated (ROD-220/141).
    confirm_scratch: [128]u8 = undefined,
    /// Top-bar season/year chip (ROD-186/141).
    chip_buf: [16]u8 = undefined,

    // ── async feedback (ROD-76) ───────────────────────────────────────────────
    spinner_frame: u8 = 0,
    /// 0 = nothing running.
    async_start_ms: i64 = 0,
    /// 0 = no pending debounce.
    debounce_deadline_ms: i64 = 0,
    /// Cover-preview settle: stop fast j/k from joinThread-fetching every scrolled row (ROD-202).
    /// 0 = none.
    cover_sync_deadline_ms: i64 = 0,

    // ── action-triggered AniList push (ROD-291) ───────────────────────────────
    /// Boot-loaded token in the session arena; passed by value into flush workers.
    anilist_auth: auth_mod.Auth = .{},
    /// Boot snapshot gating armSyncFlush. Re-eval on expiry is ROD-295.
    anilist_connected: bool = false,
    /// Debounced push deadline; binge marks coalesce. 0 = nothing pending.
    sync_flush_deadline_ms: i64 = 0,
    /// One sync at a time. Cleared only by the worker teardown defer (not .sync_flushed),
    /// so a dropped postEvent cannot latch it on. Shared with launch pull (ROD-293).
    sync_flush_inflight: std.atomic.Value(bool) = .init(false),
    /// Action flush or launch pull (one via the gate). Quit `_exit` abandons; error-unwind joins.
    sync_thread: ?std.Thread = null,

    // ── in-TUI connect modal (ROD-286) ────────────────────────────────────────
    connect: ?ConnectState = null,
    /// Arenas for tokens reloaded after in-session connects. A LIST never freed
    /// mid-session: flush workers hold anilist_auth by value for seconds, so reconnect
    /// retires the prior arena rather than free it. Freed in deinitOwnedState after joins.
    auth_reload_arenas: std.ArrayListUnmanaged(*std.heap.ArenaAllocator) = .empty,

    /// Seeded in layout so onKey/tick can gate split without a winsize event.
    term_cols: u16 = 0,
    /// With term_cols, Discover pump geometry from last settled frame (ROD-243).
    term_rows: u16 = 0,
    /// Pixel size at resize; 0 if terminal omits metrics. Cell aspect sizes Discover covers (ROD-247).
    term_x_pixel: u16 = 0,
    term_y_pixel: u16 = 0,
    now_ms: i64 = 0,
    /// Oldest first; null = empty slot.
    toast_queue: [3]?Toast = .{ null, null, null },

    undo: ?UndoEntry = null,

    /// Settings cover-cache path (~ collapsed). Null if no cache home (ROD-225).
    cover_cache_display: ?[]const u8 = null,

    /// Palette-aware style; null bg → palette.bg_base. View passes call self.s (ROD-144).
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

    /// Score-tier colour shared by detail and Browse list so they cannot drift (ROD-226).
    pub fn scoreStyle(self: *const App, score: ?u32, bg: ?vaxis.Color) vaxis.Style {
        if (score) |sc| {
            if (sc >= 91) return self.s(self.palette.hot, .{ .bold = true, .bg = bg });
            if (sc >= 76) return self.s(self.palette.fg, .{ .bg = bg });
            if (sc >= 51) return self.s(self.palette.fg2, .{ .bg = bg });
        }
        return self.s(self.palette.fg3, .{ .bg = bg });
    }

    const spinner_frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"; // 10 × 3 UTF-8 bytes
    pub fn spinnerChar(self: *const App) []const u8 {
        const b = @as(usize, self.spinner_frame) * 3;
        return spinner_frames[b .. b + 3];
    }

    /// True when the current async op has outlived slow_path_threshold_ms.
    pub fn isSlowPath(self: *const App) bool {
        return self.async_start_ms > 0 and
            self.now_ms - self.async_start_ms > slow_path_threshold_ms;
    }

    pub fn pushToast(self: *App, kind: Toast.Kind, text: []const u8, persistent: bool) void {
        self.pushToastTopic(kind, text, persistent, .general);
    }

    /// Like pushToast, with recovery scope (ROD-239): persistent errors clear only
    /// on their own subsystem's recovery, never cross-view.
    fn pushToastTopic(self: *App, kind: Toast.Kind, text: []const u8, persistent: bool, topic: Toast.Topic) void {
        const q = &self.toast_queue;

        // 1. Per-topic singleton (ROD-293): a persistent toast refreshes its topic's
        // slot in place, so repeated failures can't fill all 3 and starve transients.
        if (persistent) for (q) |*slot| {
            if (slot.*) |t| if (t.persistent and t.topic == topic) {
                slot.* = makeToast(kind, text, persistent, topic);
                return;
            };
        };

        // 2. Take a free slot.
        for (q) |*slot| if (slot.* == null) {
            slot.* = makeToast(kind, text, persistent, topic);
            return;
        };

        // 3. Full: evict the oldest non-persistent so a still-showing error survives
        // a transient (ROD-293); rule 1 should guarantee one exists. Compact left to
        // keep oldest→newest for the TTL sweep, then append.
        const victim = for (q, 0..) |slot, i| {
            if (slot) |t| if (!t.persistent) break i;
        } else v: {
            log.debug("toast: queue all-persistent, evicting oldest (singleton should prevent this)", .{});
            break :v 0;
        };
        var j = victim;
        while (j + 1 < q.len) : (j += 1) q[j] = q[j + 1];
        q[q.len - 1] = makeToast(kind, text, persistent, topic);
    }

    /// Cap copy to the §4.7 36-col budget here so long payloads get "…" not a silent
    /// render clip (ROD-166). 4000ms TTL: tiling WMs eat ~1s returning focus from mpv.
    fn makeToast(kind: Toast.Kind, text: []const u8, persistent: bool, topic: Toast.Topic) Toast {
        var t: Toast = .{ .kind = kind, .persistent = persistent, .ttl_ms = if (persistent) 0 else 4000, .topic = topic };
        const copy = render.truncateToWidth(&t.text, text, Toast.max_copy_cols);
        t.text_len = copy.len;
        return t;
    }

    /// App-owned runtime teardown. run() joins workers before this runs.
    pub fn deinitOwnedState(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer) void {
        resolve.clearFallback(self);
        if (self.show_pin) |p| {
            self.gpa.free(p);
            self.show_pin = null;
        }
        self.search.deinit(self.gpa);
        self.discover.deinit(self.gpa);
        self.episodes.freeResults(self.gpa);
        self.episodes.deinit(self.gpa);
        self.session.clear(self.gpa);
        self.cover.freeAll(self.gpa, vx, writer);
        self.discover_covers.freeAll(self.gpa, vx, writer);
        self.cover_caches.deinit(self.gpa);
        if (self.undo) |u| {
            u.free(self.gpa);
            self.undo = null;
        }
        if (self.cover_cache_display) |p| {
            self.gpa.free(p);
            self.cover_cache_display = null;
        }
        // Last (LIFO after sync joins): flush may still hold anilist_auth slices (ROD-286).
        self.freeAuthReloadArenas();
    }

    /// Free retired reload arenas (ROD-286 C1). Split out so the invariant is testable without vaxis.
    pub fn freeAuthReloadArenas(self: *App) void {
        for (self.auth_reload_arenas.items) |box| {
            box.deinit();
            self.gpa.destroy(box);
        }
        self.auth_reload_arenas.deinit(self.gpa);
    }

    /// Patch EpisodeState.progress when the detail pane is bound to this (source, source_id)
    /// (ROD-193 §D). Match the full pair so shared source_ids cannot cross-patch.
    pub fn syncEpisodeProgress(self: *App, source: []const u8, source_id: []const u8, new_progress: i64) void {
        const bound_id = self.episodes.for_id orelse return;
        const bound_source = self.episodes.for_source orelse return;
        if (!std.mem.eql(u8, bound_id, source_id)) return;
        if (!std.mem.eql(u8, bound_source, source)) return;
        const clamped: u32 = if (new_progress > 0) std.math.cast(u32, new_progress) orelse std.math.maxInt(u32) else 0;
        self.episodes.progress = clamped;
        // resumeSeed keeps the cursor on the in-progress ep (ROD-355); only if results loaded.
        if (self.episodes.results) |eps| {
            if (EpisodeState.resumeSeed(self.store, self.translation, source, source_id, @intCast(clamped), eps)) |idx| {
                self.episodes.cursor = idx;
                self.episodes.resume_idx = idx;
            } else {
                self.episodes.cursor = 0;
                self.episodes.resume_idx = null;
            }
        }
    }

    /// Raise landed binding progress to the canonical union and patch the open grid (ROD-352).
    /// Raise-only: a force-completed sibling must not un-complete. Catches multi-binding
    /// under-dim until afterPlay (ROD-323 shape).
    pub fn raiseLandingProgress(self: *App, source: []const u8, source_id: []const u8) void {
        const st = self.store orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const hw = st.raiseProgressToUnion(arena.allocator(), source, source_id, self.translation) catch |e| {
            log.debug("landing raise failed: {s}", .{@errorName(e)});
            return;
        };
        if (hw > 0) self.syncEpisodeProgress(source, source_id, hw);
    }

    /// Single-level undo slot (ROD-193 §B). Frees a prior entry first.
    fn pushUndo(self: *App, entry: UndoEntry) void {
        if (self.undo) |old| old.free(self.gpa);
        self.undo = entry;
    }

    /// Revert the last watch-state mutation (ROD-193 §B). Silent free if history no longer
    /// has the row. Syncs EpisodeState when bound (ROD-193 §D).
    pub fn applyUndo(self: *App) void {
        const entry = self.undo orelse return;
        self.undo = null; // clear before early-return so we always free

        switch (entry) {
            .set_list_status => |e| {
                defer entry.free(self.gpa);

                const st = self.store orelse return;
                const idx = history.indexById(self, e.source, e.source_id) orelse return;
                const rec = &self.history[idx];

                // Exact captured pair: restoreListStatus writes progress verbatim (ROD-193).
                st.restoreListStatus(e.source, e.source_id, e.prev_status, e.prev_progress) catch |err| {
                    log.debug("applyUndo: restoreListStatus failed: {s}", .{@errorName(err)});
                    return;
                };

                rec.list_status = e.prev_status;
                rec.progress = e.prev_progress;

                syncEpisodeProgress(self, e.source, e.source_id, e.prev_progress);

                // Restored pair may differ from last push; schedule AniList (ROD-291).
                self.armSyncFlush();

                self.pushToast(.info, "undone", false);
            },
        }
    }

    /// Focused History record in §5.4 grouped order (same walk as the highlight; ROD-139).
    pub fn selectedHistoryRecord(self: *const App) ?AnimeRecord {
        return history.recordAtCursor(self);
    }

    /// Arm hard-delete on the focused History row (ROD-220). Stores raw history index;
    /// setHistory clears it on reload. Confirm is a separate y/Y.
    pub fn armDelete(self: *App) void {
        if (self.active_pane != .list) return;
        const idx = history.indexAtCursor(self) orelse return;
        self.confirm_delete = idx;
    }

    /// Armed hard-delete (ROD-220 §4). Refuses while the show is playing. No-op if unarmed.
    pub fn executeDelete(self: *App) void {
        const idx = self.confirm_delete orelse return;
        self.confirm_delete = null;
        if (idx >= self.history.len) return;
        const rec = &self.history[idx];

        // session.anime_id is the show's source_id (PlaybackSession.begin).
        if (self.playing and
            std.mem.eql(u8, self.session.source, rec.source) and
            std.mem.eql(u8, self.session.anime_id, rec.source_id))
        {
            self.pushToast(.warn, "can't delete, currently playing", false);
            return;
        }

        const st = self.store orelse return;
        // Store first: rec.source/source_id alias the history arena, overwritten by compaction.
        const removed = st.deleteAnime(rec.source, rec.source_id) catch |e| {
            log.debug("deleteAnime failed: {s}", .{@errorName(e)});
            self.pushToast(.warn, "delete failed", false);
            return;
        };

        // Arena-backed rows: compact only; strings die on the next reload arena swap.
        std.mem.copyForwards(AnimeRecord, self.history[idx..], self.history[idx + 1 ..]);
        self.history = self.history[0 .. self.history.len - 1];

        if (self.undo) |u| {
            u.free(self.gpa);
            self.undo = null;
        }
        // Never leave detail focused on a row that just vanished.
        self.active_pane = .list;

        // Cursor stays on ordinal (now next row); last row steps back; empty → 0 (§9.2).
        const cap = self.filteredHistoryLen();
        if (self.list_cursor >= cap) self.list_cursor = if (cap == 0) 0 else cap - 1;

        // Toast only what the store actually deleted (ROD-220).
        if (removed) {
            self.pushToast(.success, "show deleted", false);
        } else {
            self.pushToast(.warn, "already gone", false);
        }
    }

    pub fn cellPx(self: *const App) [2]u16 {
        return selection.cellPx(self);
    }

    /// Discover grid geometry (ROD-276). Single home for fill/scroll sites so they
    /// cannot drift. `visible` is 0 below a usable size → empty grid.
    pub fn discoverGeometry(self: *const App) discover_view.Geometry {
        const w = self.term_cols;
        const visible: u16 = if (self.term_rows >= 4 and w >= 16) self.term_rows - 3 else 0;
        const cp = self.cellPx();
        return discover_view.geometry(w, visible, cp[0], cp[1]);
    }

    pub fn topBarSeasonChip(self: *App) []const u8 {
        return selection.topBarSeasonChip(self);
    }

    pub fn isNewRelease(self: *const App, a: Anime) bool {
        return selection.isNewRelease(self, a);
    }

    /// Manual watch-state transition on the focused History entry (ROD-139 §1, p/x/c/w).
    /// Store first; memory only on success. Undo capture (ROD-193 §B) on success only.
    pub fn setSelectedHistoryStatus(self: *App, status: domain.ListStatus) void {
        const st = self.store orelse return;
        const idx = history.indexAtCursor(self) orelse return;
        const rec = &self.history[idx];

        const prev_status = rec.list_status;
        const prev_progress = rec.progress;
        const src_copy = self.gpa.dupe(u8, rec.source) catch null;
        const sid_copy = self.gpa.dupe(u8, rec.source_id) catch null;

        st.setListStatus(rec.source, rec.source_id, status) catch |e| {
            log.debug("setListStatus failed: {s}", .{@errorName(e)});
            if (src_copy) |buf| self.gpa.free(buf);
            if (sid_copy) |buf| self.gpa.free(buf);
            return;
        };

        // Push undo only if both key copies exist; free partial on OOM (ROD-193).
        if (src_copy != null and sid_copy != null) {
            self.pushUndo(.{ .set_list_status = .{
                .source = src_copy.?,
                .source_id = sid_copy.?,
                .prev_status = prev_status,
                .prev_progress = prev_progress,
            } });
        } else {
            if (src_copy) |buf| self.gpa.free(buf);
            if (sid_copy) |buf| self.gpa.free(buf);
        }

        rec.list_status = status;
        // Mirror store force-complete snap only. Do not flip history_visible (loadHistory
        // already filters). w/x/p leave progress alone; re-watch keeps the full bar.
        if (status == .completed) {
            if (rec.total_episodes) |t| {
                if (t > 0) rec.progress = t;
            }
        }

        self.armSyncFlush();
    }

    pub fn animeFromHistoryRecord(rec: AnimeRecord) Anime {
        return selection.animeFromHistoryRecord(rec);
    }

    pub fn currentDetailAnime(self: *const App) ?Anime {
        return selection.currentDetailAnime(self);
    }

    pub fn episodeGridVisible(self: *const App) bool {
        return selection.episodeGridVisible(self);
    }

    pub fn detailSyncTarget(self: *const App) ?Anime {
        return selection.detailSyncTarget(self);
    }

    pub const DetailRenderInfo = selection.DetailRenderInfo;

    pub fn detailRenderInfo(self: *App) DetailRenderInfo {
        return selection.detailRenderInfo(self);
    }

    pub const MetaField = selection.MetaField;

    pub fn detailMetaFields(self: *App) []const MetaField {
        return selection.detailMetaFields(self);
    }

    pub fn detailMetaFieldsFor(self: *App, a: ?Anime) []const MetaField {
        return selection.detailMetaFieldsFor(self, a);
    }

    /// NATURAL_END_RATIO completion bar (ROD-168). Shared by play_done and play_error so
    /// a clean mpv quit is not a watch; matches store resume, §4.6 dim, and cursor advance.
    fn watchCompleted(final_update: ?event_mod.PositionUpdate) bool {
        const u = final_update orelse return false;
        return u.reachedCompletion(store_mod.NATURAL_END_RATIO);
    }

    /// §4.7 toast for a play/episode failure, or null for the caller's generic fallback.
    /// Source classes (ROD-173) use displayName; player-spawn (ROD-230) are static and
    /// play-path only. Phrasings pair with DESIGN.md §4.10.
    fn failureClassCopy(cause: anyerror, source_name: []const u8, buf: []u8) ?[]const u8 {
        return switch (cause) {
            // Source classes (ROD-173).
            error.NetworkDown => "network unreachable",
            error.Forbidden => std.fmt.bufPrint(buf, "{s} blocked us", .{source_name}) catch null,
            error.ServerError => std.fmt.bufPrint(buf, "{s} is down", .{source_name}) catch null,
            error.HttpNotOk => std.fmt.bufPrint(buf, "{s} returned an error", .{source_name}) catch null,
            // Player-spawn classes (ROD-230).
            error.MpvNotFound => "mpv not found — install mpv",
            error.MpvFailed => "mpv exited with error",
            error.MpvOpenFailed => "stream didn't open — try again",
            else => null,
        };
    }

    /// Token usable and anilist_sync_enabled (ROD-286). Off makes the whole sync rail inert.
    fn syncEnabled(self: *const App) bool {
        return self.anilist_connected and self.config.anilist_sync_enabled;
    }

    /// Arm debounced AniList push after a linked-row mutation (ROD-291). Uses now_ms so
    /// call sites need no io; .tick fires when the deadline elapses.
    fn armSyncFlush(self: *App) void {
        if (!self.syncEnabled()) return;
        self.sync_flush_deadline_ms = self.now_ms + App.sync_flush_settle_ms;
    }

    /// Spawn pull-then-push when the debounce elapses (ROD-291). One at a time: re-arm if
    /// inflight rather than stack. No-op under test (real network).
    fn fireSyncFlush(self: *App, loop: *Loop, io: std.Io) void {
        if (builtin.is_test) return;
        const st = self.store orelse return;
        if (!self.syncEnabled()) return;
        if (self.sync_flush_inflight.load(.acquire)) {
            self.sync_flush_deadline_ms = nowMs(io) + App.sync_flush_settle_ms;
            return;
        }
        if (self.sync_thread) |t| {
            t.join();
            self.sync_thread = null;
        }
        self.spawnSyncWorker(loop, io, st, false); // pull-then-push
    }

    /// Pull-only MediaListCollection at launch (ROD-293). Shares the one-sync gate with
    /// the action flush. Ambient; no-op under test.
    fn fireLaunchPull(self: *App, loop: *Loop, io: std.Io) void {
        if (builtin.is_test) return;
        const st = self.store orelse return;
        if (!self.syncEnabled()) return;
        if (self.sync_flush_inflight.load(.acquire)) return;
        if (self.sync_thread) |t| {
            t.join();
            self.sync_thread = null;
        }
        self.spawnSyncWorker(loop, io, st, true); // pull-only
    }

    /// Shared sync worker spawn (ROD-291/293). Caller cleared the gate and reaped prior handle.
    /// Spawn failure clears the gate so it cannot latch off.
    fn spawnSyncWorker(self: *App, loop: *Loop, io: std.Io, st: *Store, pull_only: bool) void {
        self.sync_flush_inflight.store(true, .release);
        self.sync_thread = std.Thread.spawn(.{}, workers.syncFlushTask, .{
            loop, self.gpa, io, st, self.anilist_auth, Store.nowSecs(), &self.sync_flush_inflight, pull_only,
        }) catch |e| blk: {
            log.debug("sync worker spawn failed: {s}", .{@errorName(e)});
            self.sync_flush_inflight.store(false, .release);
            break :blk null;
        };
    }

    /// Bounded quit push (ROD-294). Never alongside an inflight pull (ROD-285 ordering):
    /// concurrent push could POST pre-reconcile progress. Launch-then-quit during the
    /// launch pull drops this push; rows re-flush on a later action or a later quit.
    fn quitFlush(self: *App, io: std.Io) void {
        if (builtin.is_test) return;
        const st = self.store orelse return;
        if (!self.syncEnabled()) return;
        if (self.sync_flush_inflight.load(.acquire)) return;
        workers.pushOnQuit(self.gpa, io, st, self.anilist_auth, Store.nowSecs(), App.quit_push_deadline_ms);
    }

    // ── in-TUI connect modal (ROD-286) ────────────────────────────────────────

    /// In-TUI AniList connect (ROD-286). Bind on the render thread so failure is an
    /// immediate toast, not a half-open modal. No-op under test / if already open.
    pub fn beginConnect(self: *App, loop: *Loop, io: std.Io) void {
        if (builtin.is_test) return;
        if (self.connect != null) return;
        self.connect = self.startConnect(loop, io) catch |e| {
            // Terminal-safe fallback when bind/spawn fails.
            const msg = switch (e) {
                error.LoopbackUnavailable => "port busy: zigoku login --paste",
                else => "can't start: zigoku login --paste",
            };
            self.pushToast(.@"error", msg, false);
            log.debug("connect start failed: {s}", .{@errorName(e)});
            return;
        };
    }

    /// Fallible half of beginConnect. errdefer closes the socket and frees the arena.
    fn startConnect(self: *App, loop: *Loop, io: std.Io) !ConnectState {
        const box = try self.gpa.create(std.heap.ArenaAllocator);
        box.* = .init(self.gpa);
        errdefer {
            box.deinit();
            self.gpa.destroy(box);
        }
        const a = box.allocator();

        const listener = try a.create(login_loopback.Listener);
        listener.* = try login_loopback.begin(a, io);
        errdefer listener.server.deinit(io);

        const cancel = try a.create(std.atomic.Value(bool));
        cancel.* = .init(false);

        // Best-effort; URL stays in the modal for manual open.
        login_loopback.openBrowser(io, listener.url);

        const thread = try std.Thread.spawn(.{}, workers.connectTask, .{ loop, io, listener, a, cancel });
        return .{
            .arena = box,
            .listener = listener,
            .cancel = cancel,
            .thread = thread,
            .started_ms = self.now_ms,
        };
    }

    /// Wake + join worker, close listener, free arena. Worker skips postEvent on
    /// cancel so join cannot stall on a full queue.
    fn teardownConnect(self: *App, io: std.Io) void {
        if (self.connect == null) return;
        const cs = &self.connect.?;
        cs.cancel.store(true, .release);
        login_loopback.requestCancel(io);
        if (cs.thread) |t| t.join();
        cs.listener.server.deinit(io); // fd; arena will not close it
        cs.arena.deinit();
        self.gpa.destroy(cs.arena);
        self.connect = null;
    }

    fn cancelConnect(self: *App, io: std.Io) void {
        self.teardownConnect(io);
        self.pushToast(.info, "sign-in canceled", false);
    }

    /// Modal keys: esc cancel; `c` OSC-52 copy (serviced in draw). Else swallow.
    /// Ctrl-C is handled in onKey before this runs.
    pub fn onConnectKey(self: *App, key: vaxis.Key, io: std.Io) void {
        if (key.matches(vaxis.Key.escape, .{})) {
            self.cancelConnect(io);
            return;
        }
        if (key.matches('c', .{})) {
            if (self.connect) |*cs| cs.copy_requested = true;
            return;
        }
    }

    /// Settled connect. Apply outcome even if esc already tore the modal down (token
    /// may still need adopt). .ok → reload + bootstrap (ROD-292).
    fn onConnectResult(self: *App, outcome: login_loopback.ConnectOutcome, loop: *Loop, io: std.Io) void {
        self.teardownConnect(io);
        switch (outcome) {
            .ok => {
                self.reloadAuthAfterConnect(io);
                if (self.anilist_connected) {
                    var buf: [40]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "connected as {s}", .{self.anilist_auth.anilist.user_name}) catch "connected to AniList";
                    self.pushToast(.success, msg, false);
                    self.bootstrapSync(loop, io);
                } else {
                    self.pushToast(.warn, "connected, token unusable", false);
                }
            },
            .no_token => self.pushToast(.@"error", "sign-in: no token returned", false),
            .rejected => self.pushToast(.@"error", "sign-in rejected by AniList", false),
            .verify_failed => self.pushToast(.@"error", "sign-in: couldn't verify", false),
            .save_failed => self.pushToast(.@"error", "sign-in: couldn't save token", false),
            .accept_failed => self.pushToast(.@"error", "sign-in: listener failed", false),
            .canceled => {}, // esc already toasted
        }
    }

    /// Reload auth.zon into a new session arena after connect; adopt as live token.
    fn reloadAuthAfterConnect(self: *App, io: std.Io) void {
        const box = self.gpa.create(std.heap.ArenaAllocator) catch return;
        box.* = .init(self.gpa);
        const a = box.allocator();
        const path = auth_mod.defaultPath(a) catch {
            box.deinit();
            self.gpa.destroy(box);
            return;
        };
        const reloaded = auth_mod.load(a, io, path);
        self.adoptReloadedAuth(box, reloaded) catch {
            // Append failed: free box rather than leak; keep prior tracked token.
            box.deinit();
            self.gpa.destroy(box);
        };
    }

    /// Retire `box` into auth_reload_arenas (never free mid-session; ROD-286 C1) and
    /// repoint anilist_auth. Fails only on OOM append; caller frees box then.
    pub fn adoptReloadedAuth(self: *App, box: *std.heap.ArenaAllocator, reloaded: auth_mod.Auth) !void {
        try self.auth_reload_arenas.append(self.gpa, box);
        self.anilist_auth = reloaded;
        self.anilist_connected = reloaded.hasAniList() and !reloaded.anilist.isExpired(Store.nowSecs());
    }

    /// Post-connect pull-then-push (ROD-292). Shares the one-flush gate; no-op if inflight.
    fn bootstrapSync(self: *App, loop: *Loop, io: std.Io) void {
        if (builtin.is_test) return;
        const st = self.store orelse return;
        if (!self.syncEnabled()) return;
        if (self.sync_flush_inflight.load(.acquire)) return;
        if (self.sync_thread) |t| {
            t.join();
            self.sync_thread = null;
        }
        self.spawnSyncWorker(loop, io, st, false); // pull-then-push
    }

    fn finishPlayback(self: *App, final_update: ?event_mod.PositionUpdate, completed: bool) void {
        // Before finish() clear: 1-based ep and whether detail still shows this show (ROD-131).
        const played_index = self.session.episode_index;
        const same_show = self.episodes.for_id != null and self.session.anime_id.len > 0 and
            std.mem.eql(u8, self.session.anime_id, self.episodes.for_id.?);

        // Meaningful position writes/moves a history row (ROD-191). Superset of
        // recordPlay: may over-reload, never miss a written row.
        if (final_update) |u| {
            if (u.isMeaningful()) {
                self.history_dirty = true;
                self.armSyncFlush(); // ROD-291
            }
        }

        self.session.finish(self.gpa, self.store, final_update, completed);
        self.playing = false;
        self.current_position = 0;
        self.current_duration = 0;
        self.async_start_ms = 0;

        // Advance/dim only on NATURAL_END_RATIO completion (ROD-131/168). Partial stays in history.
        if (completed and played_index > 0 and same_show) self.advanceAfterWatch(played_index);
    }

    /// Counted watch onto the detail pane: high-water, next cursor, toast (ROD-131).
    fn advanceAfterWatch(self: *App, played_index: u32) void {
        // No grid: episodes_done re-seeds from store; a bump here would be dropped.
        const eps = self.episodes.results orelse return;
        self.episodes.progress = @max(self.episodes.progress, played_index);
        // played_index is 1-based; next ep is at 0-based index played_index.
        const next: usize = played_index;
        if (next < eps.len) {
            self.episodes.cursor = next;
            self.episodes.resume_idx = next; // ROD-192 in-session ▸ advance
            var buf: [32]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "episode {d} done", .{played_index}) catch "episode done";
            self.pushToast(.success, msg, false);
        } else {
            // Finale: leave cursor; clear resume (ROD-192).
            self.episodes.resume_idx = null;
            self.pushToast(.success, "all caught up", false);
        }
    }

    pub fn setHistory(self: *App, recs: []AnimeRecord) void {
        // Re-anchor cursor to the focused show across reload (ROD-386), not the
        // §5.4 ordinal (reorder must not desync from the episode grid). Copy keys
        // out of the old arena (ROD-141). Only in history context: list_cursor is
        // shared with Browse/Discover.
        const in_history_ctx = self.active_view == .history or
            (self.active_view == .detail and self.detail_origin == .history);
        var anchor_src: [64]u8 = undefined;
        var anchor_id: [128]u8 = undefined;
        const anchor: ?struct { src: []const u8, id: []const u8 } = blk: {
            if (!in_history_ctx) break :blk null;
            const rec = self.selectedHistoryRecord() orelse break :blk null;
            if (rec.source.len > anchor_src.len or rec.source_id.len > anchor_id.len) break :blk null;
            @memcpy(anchor_src[0..rec.source.len], rec.source);
            @memcpy(anchor_id[0..rec.source_id.len], rec.source_id);
            break :blk .{ .src = anchor_src[0..rec.source.len], .id = anchor_id[0..rec.source_id.len] };
        };

        self.history = recs;
        self.history_loading = false;
        // Reload reorders: armed delete index is meaningless (ROD-220).
        self.confirm_delete = null;
        // Clear history-load banner so a transient cannot latch "unavailable" (ROD-234).
        self.load_error = null;

        if (anchor) |a| {
            if (history.ordinalOf(self, a.src, a.id)) |ord| {
                self.list_cursor = ord;
                return;
            }
        }
        const cap = self.filteredHistoryLen();
        if (self.list_cursor >= cap) self.list_cursor = if (cap == 0) 0 else cap - 1;
    }

    // ── tick: fold one event into state ──────────────────────────────────────
    pub fn tick(self: *App, event: Event, loop: *Loop, io: std.Io, registry: Registry) !void {
        // Cursor snapshot for post-dispatch cover sync: move → debounce, discrete nav → now (ROD-202).
        const cursor_before = self.list_cursor;
        // A handler returning true skips the post-switch cover-settle pass (ROD-202).
        switch (event) {
            .key_press => |key| input.onKey(self, key, loop, io, registry),
            .winsize => |ws| {
                // run() owns vx resize; tick only normalizes layout for pure draw.
                // ROD-170: below two-pane threshold clamp focus to list (no detail pane drawn).
                if (ws.cols < pane_split_min and
                    (self.active_view == .browse or self.active_view == .history))
                    self.active_pane = .list;
            },
            .focus_in, .focus_out => {},
            .history_loaded => |recs| {
                self.setHistory(recs);
                // Initial load: one-shot resume landing (ROD-229).
                self.maybeResumeLanding(loop, io, registry);
            },
            .history_reloaded => |recs| {
                // run() flips the double-buffer when history_reload_ok is set (ROD-191).
                self.setHistory(recs);
                self.history_reload_ok = true;
                self.history_reload_settled +%= 1;
            },
            .history_reload_failed => {
                // Keep current slice; clear latch without flip (ROD-191).
                self.history_reload_ok = false;
                self.history_reload_settled +%= 1;
                self.pushToast(.warn, "watchlist refresh failed", false);
            },
            .history_load_failed => |msg| {
                // History-only banner; Browse task_error must not mark History unavailable (ROD-234).
                self.load_error = msg;
                self.history_loading = false;
            },
            .task_error => |msg| {
                // Browse search/enrich only: never touch History state (ROD-234).
                self.search.loading = false;
                self.debounce_deadline_ms = 0;
                self.cover_sync_deadline_ms = 0;
                self.async_start_ms = 0;
                self.pushToast(.@"error", msg, true);
            },
            .sync_flushed => |outcome| self.handleSyncFlushed(outcome),
            .update_available => {
                // Fixed copy so the command never clips; version is in Settings (ROD-370).
                self.pushToast(.info, "update available · run zigoku update", false);
            },
            .connect_result => |outcome| self.onConnectResult(outcome, loop, io),
            .search_done => |ev| if (self.handleSearchDone(ev)) return,

            .resolve_add_result => |ev| if (self.handleResolveAddResult(loop, io, registry, ev)) return,

            .resolve_play_target => |ev| if (self.handleResolvePlayTarget(loop, io, registry, ev)) return,

            .prewarm_result => |ev| if (self.handlePrewarmResult(ev)) return,

            .prewarm_done => self.prewarm.active = false,

            .discover_feed => |ev| if (self.handleDiscoverFeed(ev)) return,

            .discover_feed_error => |ev| self.handleDiscoverFeedError(ev),
            .enrichment_refreshed => |ev| self.handleEnrichmentRefreshed(ev),
            .episodes_done => |ev| if (self.handleEpisodesDone(loop, io, registry, ev)) return,
            .episodes_error => |ev| if (self.handleEpisodesError(loop, io, registry, ev)) return,
            .cover_done => |ev| if (self.handleCoverDone(ev)) return,
            .cover_error => |for_id| if (self.handleCoverError(for_id)) return,
            .discover_cover_done => |ev| {
                // URL-keyed; always adopt for ev.url (recreate slot if mid-flight eviction).
                defer self.gpa.free(ev.url);
                self.discover_covers.acceptPixels(self.gpa, ev.url, ev.rgba, ev.width, ev.height);
            },
            .discover_cover_error => |url| {
                // Cooldown so pump does not hammer; rank placeholder is the loading cue.
                defer self.gpa.free(url);
                self.discover_covers.noteFailure(self.gpa, url, self.now_ms);
            },
            .position_update => |ev| {
                self.current_position = ev.time_pos;
                self.current_duration = ev.duration;
                self.session.maybeCheckpoint(self.store, ev.time_pos, ev.duration);
            },
            .play_done => |final_update| {
                // Clean exit is not a watch; only NATURAL_END_RATIO counts (ROD-168).
                self.finishPlayback(final_update, watchCompleted(final_update));
                resolve.clearFallback(self);
            },
            .play_error => |ev| if (self.handlePlayError(loop, io, registry, ev)) return,
            .play_retry => |r| {
                // CDN 403 backoff: "retrying", not frozen launch (ROD-309).
                var buf: [48]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "stream didn't open — retrying {d}/{d}", .{ r.attempt, r.max }) catch "stream didn't open — retrying";
                self.pushToast(.warn, msg, false);
            },
            .tick => self.handleTickEvent(loop, io, registry),
        }

        if (event != .tick) {
            // ROD-202 cover-settle. Scroll = j/k arrows that moved cursor, not jump/filter/view.
            const key_scroll = event == .key_press and
                self.input_mode == .normal and
                selection.isListScrollKey(event.key_press) and
                self.list_cursor != cursor_before;
            if (key_scroll and selection.coverTracksCursor(self)) {
                // Arm only: .tick fetches after settle. Per-row sync joinThread-stutters (ROD-202).
                self.cover_sync_deadline_ms = nowMs(io) + cover_settle_ms;
            } else if (event == .key_press) {
                // Discrete nav: sync now; cancel pending settle.
                self.cover_sync_deadline_ms = 0;
                selection.syncCover(self, loop, io, registry);
            } else {
                // Async/resize: refresh unless a scroll settle is already armed.
                if (self.cover_sync_deadline_ms == 0) selection.syncCover(self, loop, io, registry);
            }
        }
    }

    fn handleSearchDone(self: *App, ev: anytype) bool {
        // Stale if query moved since fire.
        if (!std.mem.eql(u8, ev.for_query, self.search.querySlice())) {
            for (ev.results) |r| freeOwnedAnime(self.gpa, r);
            self.gpa.free(ev.for_query);
            self.gpa.free(ev.results);
            return true;
        }
        self.search.loading = false;
        self.async_start_ms = 0;
        // Clear general persistent errors only; feed errors survive (ROD-239).
        for (&self.toast_queue) |*slot| {
            if (slot.*) |t| {
                if (t.persistent and t.kind == .@"error" and t.topic == .general) slot.* = null;
            }
        }
        if (ev.page == 1) {
            self.search.clearResults(self.gpa);
        }
        const offset = self.search.results.items.len;
        self.search.page = ev.page;
        self.search.results.appendSlice(self.gpa, ev.results) catch |e| {
            // Free elements: outer free alone would leak owned Anime.
            log.debug("appending search results failed: {s}", .{@errorName(e)});
            for (ev.results) |r| freeOwnedAnime(self.gpa, r);
        };
        self.gpa.free(ev.results);
        self.gpa.free(ev.for_query);
        if (ev.page == 1) {
            self.list_cursor = 0;
            self.list_top = 0;
        }
        const added = self.search.results.items.len - offset;
        // Fully enriched from AniList; hydrate + persist spine only (ROD-327).
        self.search.hydrateResultsFromStore(self.gpa, self.store, offset, added);
        self.search.persistResults(self.gpa, self.store, offset, added);
        return false;
    }

    fn handleResolveAddResult(self: *App, loop: *Loop, io: std.Io, registry: Registry, ev: anytype) bool {
        defer if (ev.source_id.len > 0) self.gpa.free(ev.source_id);
        defer if (ev.absent_sources.len > 0) self.gpa.free(ev.absent_sources);
        // Before any early return: widen filters via providerAbsentFresh (ROD-347).
        resolve.persistProviderAbsences(self, ev.anilist_id, ev.absent_sources);
        self.async_start_ms = 0;
        self.resolve.add_resolving = false;
        if (!ev.ok) {
            // Tier-A miss: widen over remaining providers once (empty source = search walk).
            if (ev.source.len > 0 and resolve.fireResolveAddWiden(self, loop, io, registry, ev.anilist_id, ev.source)) return true;
            // Unbound terminal (ROD-329); never toast success without a write.
            const st = self.store orelse {
                self.pushToast(.@"error", "couldn't add to watchlist", false);
                return true;
            };
            var miss_arena = std.heap.ArenaAllocator.init(self.gpa);
            defer miss_arena.deinit();
            const marked = st.markUnbound(ev.anilist_id, Store.nowSecs(), miss_arena.allocator()) catch |e| {
                log.debug("markUnbound failed: {s}", .{@errorName(e)});
                self.pushToast(.@"error", "couldn't add to watchlist", false);
                return true;
            };
            if (!marked) {
                self.pushToast(.@"error", "couldn't add to watchlist", false);
                return true;
            }
            self.history_dirty = true;
            self.pushToast(.warn, "added, no source available", false);
            return true;
        }
        // Bind + reveal; null store / error / false = toast miss, never false success.
        const st = self.store orelse {
            self.pushToast(.@"error", "couldn't add to watchlist", false);
            return true;
        };
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const bound = st.bindCanonical(ev.source, ev.source_id, ev.anilist_id, true, Store.nowSecs(), arena.allocator()) catch |e| {
            log.debug("bindCanonical (add) failed: {s}", .{@errorName(e)});
            self.pushToast(.@"error", "couldn't add to watchlist", false);
            return true;
        };
        if (!bound) {
            self.pushToast(.@"error", "couldn't add to watchlist", false);
            return true;
        }
        self.history_dirty = true;
        self.noteAvailabilityWrite(ev.anilist_id);
        self.pushToast(.success, "added to watchlist", false);
        resolve.firePrewarm(self, loop, io, registry, ev.anilist_id); // ROD-351
        return false;
    }

    fn handleResolvePlayTarget(self: *App, loop: *Loop, io: std.Io, registry: Registry, ev: anytype) bool {
        defer if (ev.source_id.len > 0) self.gpa.free(ev.source_id);
        defer if (ev.absent_sources.len > 0) self.gpa.free(ev.absent_sources);
        // Catalog facts even when the staleness gate drops the result (ROD-347).
        resolve.persistProviderAbsences(self, ev.anilist_id, ev.absent_sources);
        self.async_start_ms = 0;
        self.resolve.play_resolving = false;
        // Superseded fire: do not hijack the current grid (ROD-346).
        const wanted = self.resolve.play_resolve_aid != null and self.resolve.play_resolve_aid.? == ev.anilist_id;
        self.resolve.play_resolve_aid = null;
        if (!wanted) return true;
        if (!ev.ok) {
            // Capture flip name before advance deinits the walk (ROD-357); for_source is stale.
            const flip_miss: ?[]const u8 = if (self.resolve.fallback) |w| (if (w.manual and w.anilist_id == ev.anilist_id and w.providers.len > 0) w.providers[0].displayName() else null) else null;
            if (self.resolve.fallback != null and self.resolve.fallback.?.anilist_id == ev.anilist_id) {
                if (resolve.advanceFallback(self, loop, io, registry, null, null)) return true;
            }
            // Resume walk exhausted on last tier-C hop: demote, not blank pane (ROD-229).
            self.demoteResumeLanding();
            if (resolve.toastFlipExhaust(self, flip_miss)) return true;
            self.pushToast(.@"error", "couldn't load episodes", false);
            return true;
        }
        std.debug.assert(self.resolve.fallback == null or self.resolve.fallback.?.anilist_id == ev.anilist_id);
        // fireEpisodesForId nulls pending_bind; arm after. Park walk across the fire.
        const walk = self.resolve.fallback;
        self.resolve.fallback = null;
        resolve.fireEpisodesForId(self, loop, io, registry, ev.source_id, ev.source, if (walk) |w| domain.expectedEpisodeCount(w.canonical) else null);
        if (self.episodes.loading) {
            self.resolve.fallback = walk;
        } else if (walk) |w| {
            var done = w;
            done.deinit(self.gpa);
        }
        self.resolve.pending_bind = ev.anilist_id;
        return false;
    }

    fn handlePrewarmResult(self: *App, ev: anytype) bool {
        // HIDDEN bind (play reveals) or absence cache; best-effort (ROD-351/347).
        defer if (ev.source_id.len > 0) self.gpa.free(ev.source_id);
        const st = self.store orelse return true;
        if (ev.source_id.len > 0) {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            _ = st.bindCanonical(ev.source, ev.source_id, ev.anilist_id, false, Store.nowSecs(), arena.allocator()) catch |e|
                log.debug("prewarm bind failed: {s}", .{@errorName(e)});
        } else if (ev.absent) {
            st.markProviderAbsent(ev.anilist_id, ev.source, Store.nowSecs()) catch |e|
                log.debug("markProviderAbsent failed: {s}", .{@errorName(e)});
        }
        self.noteAvailabilityWrite(ev.anilist_id);
        return false;
    }

    fn handleDiscoverFeed(self: *App, ev: anytype) bool {
        // Land into ev.axis slot, never the active axis mid-switch. No stale drop.
        const idx = @intFromEnum(ev.axis);
        const slot = &self.discover.slots[idx];
        slot.loading = false;
        slot.failed = false;
        const is_active = idx == @intFromEnum(self.discover.axis);
        if (is_active) self.async_start_ms = 0;
        // Feed-topic only; Browse search errors survive (§9.3b, ROD-239).
        for (&self.toast_queue) |*ts| {
            if (ts.*) |t| {
                if (t.persistent and t.kind == .@"error" and t.topic == .feed) ts.* = null;
            }
        }
        if (ev.page == 1) self.discover.clearSlot(self.gpa, idx);
        const offset = slot.results.items.len;
        slot.results.appendSlice(self.gpa, ev.results) catch |e| {
            // No stamp on OOM: leave page-0 so refreshDiscover refetches (ROD-239).
            log.debug("appending feed results failed: {s}", .{@errorName(e)});
            for (ev.results) |r| freeOwnedAnime(self.gpa, r);
            self.gpa.free(ev.results);
            return true;
        };
        self.gpa.free(ev.results);
        // Exhaustion: hasNextPage (§9.6) or max_feed_rows (ROD-339), not short-page heuristic.
        slot.fetched_at = Store.nowSecs();
        slot.page = ev.page;
        slot.exhausted = !ev.has_next or slot.results.items.len >= DiscoverState.max_feed_rows;
        // Full GQL_FIELDS; persist spine like search (ROD-336).
        const added = slot.results.items.len - offset;
        self.discover.persistSlot(self.gpa, self.store, idx, offset, added);
        if (is_active and ev.page == 1) {
            self.discover.cursor = 0;
            self.discover.scroll = 0;
        }
        return false;
    }

    fn handleEpisodesDone(self: *App, loop: *Loop, io: std.Io, registry: Registry, ev: anytype) bool {
        defer self.gpa.free(ev.for_id);
        // Stale: not for the current detail show.
        if (self.episodes.for_id == null or !std.mem.eql(u8, ev.for_id, self.episodes.for_id.?)) {
            for (ev.episodes) |ep| self.gpa.free(ep.raw);
            self.gpa.free(ev.episodes);
            return true;
        }
        self.episodes.loading = false;
        self.async_start_ms = 0;
        // ROD-368: empty 200 = "doesn't stock this", not a 0-ep grid. Walk like
        // episodes_error; only that path used to hop. pending_bind is tier-A aid.
        if (ev.episodes.len == 0) {
            self.gpa.free(ev.episodes);
            const failed_bind = self.resolve.pending_bind;
            self.resolve.pending_bind = null;
            if (self.episodes.for_source) |src| {
                const aid: ?i64 = failed_bind orelse blk: {
                    const st = self.store orelse break :blk null;
                    var a = std.heap.ArenaAllocator.init(self.gpa);
                    defer a.deinit();
                    const rec = (st.getAnime(a.allocator(), src, ev.for_id) catch null) orelse break :blk null;
                    break :blk rec.anilist_id;
                };
                if (aid) |id| resolve.persistProviderAbsences(self, id, &.{src});
            }
            const flip_miss: ?[]const u8 = if (self.resolve.fallback) |w| (if (w.manual and w.providers.len > 0) w.providers[0].displayName() else null) else null;
            if (resolve.advanceFallback(self, loop, io, registry, failed_bind, self.owningProvider(registry).displayName())) return true;
            // Ladder empty: in-memory unbound only (browse must not mint ROD-329).
            self.demoteResumeLanding();
            _ = resolve.toastFlipExhaust(self, flip_miss);
            self.episodes.unbound = true;
            return true;
        }
        self.resume_landing_pending = false; // ROD-229 auto-open succeeded
        if (self.episodes.results) |old| {
            for (old) |ep| self.gpa.free(ep.raw);
            self.gpa.free(old);
        }
        // Sole non-applyCached write of results. for_id/for_source stay as fire set
        // them (syncEpisodeProgress match); keep that pair in lockstep (ROD-193).
        self.episodes.results = ev.episodes;
        self.episodes.cursor = 0;
        self.episodes.progress = 0;
        self.episodes.resume_idx = null;
        // §4.6 dim + resume from fire-time (source, id), not live nav (ROD-163).
        {
            var seed_arena = std.heap.ArenaAllocator.init(self.gpa);
            defer seed_arena.deinit();
            if (selection.detailSeedRecord(self, seed_arena.allocator(), self.episodes.for_source, ev.for_id)) |rec| {
                self.episodes.seedHistoryCursor(self.store, self.translation, rec, ev.episodes);
            }
        }
        // Cache under fire-time for_source even if nav moved (ROD-130/343).
        const source = self.episodes.for_source orelse selection.currentDetailSourceName(self, registry);
        const status: ?[]const u8 = if (self.currentDetailAnime()) |a| a.status else null;
        // Bind BEFORE cache: episode_cache FKs anime (ROD-327). Hidden until play.
        if (self.resolve.pending_bind) |aid| {
            self.resolve.pending_bind = null;
            if (self.store) |st| {
                var arena = std.heap.ArenaAllocator.init(self.gpa);
                defer arena.deinit();
                if (st.bindCanonical(source, ev.for_id, aid, false, Store.nowSecs(), arena.allocator())) |bound| {
                    if (!bound) log.debug("bindCanonical (play): no canonical for anilist_id {d}", .{aid});
                    if (bound) self.noteAvailabilityWrite(aid);
                } else |e| log.debug("bindCanonical (play) failed: {s}", .{@errorName(e)});
            }
        }
        // After mint so a fresh binding has a row; patches seed that ran pre-mint (ROD-352).
        self.raiseLandingProgress(source, ev.for_id);
        self.episodes.cacheEpisodes(self.gpa, self.store, source, ev.for_id, self.translation, status, ev.episodes);
        resolve.completeFallback(self, loop, io, registry);
        return false;
    }

    fn handleEpisodesError(self: *App, loop: *Loop, io: std.Io, registry: Registry, ev: anytype) bool {
        defer self.gpa.free(ev.for_id);
        // Superseded fetch must not clear live load or toast (ROD-179).
        if (self.episodes.for_id == null or !std.mem.eql(u8, ev.for_id, self.episodes.for_id.?)) return true;
        self.episodes.loading = false;
        self.async_start_ms = 0;
        // Capture before clear: virgin probe's only handle on the canonical (ROD-327).
        const failed_bind = self.resolve.pending_bind;
        self.resolve.pending_bind = null;
        const flip_miss: ?[]const u8 = if (self.resolve.fallback) |w| (if (w.manual and w.providers.len > 0) w.providers[0].displayName() else null) else null;
        if (resolve.advanceFallback(self, loop, io, registry, failed_bind, self.owningProvider(registry).displayName())) return true;
        // Resume auto-open failed: demote to History, not blank detail (ROD-229).
        self.demoteResumeLanding();
        if (resolve.toastFlipExhaust(self, flip_miss)) return true;
        // §4.10: blank grid needs an explanation (ROD-173 class or generic).
        var buf: [128]u8 = undefined;
        const copy = failureClassCopy(ev.cause, self.owningProvider(registry).displayName(), &buf) orelse "couldn't load episodes";
        self.pushToast(.@"error", copy, false);
        return false;
    }

    fn handleCoverDone(self: *App, ev: anytype) bool {
        defer self.gpa.free(ev.for_id);
        if (self.cover.for_id == null or !std.mem.eql(u8, ev.for_id, self.cover.for_id.?)) {
            self.gpa.free(ev.rgba);
            return true;
        }
        self.cover.loading = false;
        self.cover.joinThread();
        if (!self.search.loading and !self.episodes.loading and !self.playing) self.async_start_ms = 0;

        // Same target as cover.sync (list cursor in split browse); else list
        // prefetch covers always fail the keep-check (ROD-156 #2).
        const target_id = if (self.detailSyncTarget()) |a| a.id else null;
        const keep = target_id != null and std.mem.eql(u8, target_id.?, ev.for_id);
        if (!keep) {
            self.cover.clear(self.gpa);
            self.gpa.free(ev.rgba);
            return true;
        }

        self.cover.acceptPixels(self.gpa, ev.rgba, ev.width, ev.height);
        return false;
    }

    fn handlePlayError(self: *App, loop: *Loop, io: std.Io, registry: Registry, ev: anytype) bool {
        const completed = watchCompleted(ev.final);
        // Hop only if never meaningfully played (CF-penalty shape); mid-episode
        // death must not relaunch. Capture continuation before finish clears session;
        // only when detail still shows the played binding (ROD-346).
        const never_played = if (ev.final) |f| !f.isMeaningful() else true;
        const cont_ok = !completed and never_played and self.store != null and
            self.episodes.for_id != null and self.session.anime_id.len > 0 and
            std.mem.eql(u8, self.session.anime_id, self.episodes.for_id.?) and
            self.episodes.for_source != null and self.session.source.len > 0 and
            std.mem.eql(u8, self.session.source, self.episodes.for_source.?);
        const ep_copy: ?[]const u8 = if (cont_ok) self.gpa.dupe(u8, self.session.episode_raw) catch null else null;
        const ordinal = self.session.episode_index;
        self.finishPlayback(ev.final, completed);
        // §4.10: incomplete error is a real failure; completed late-error took success path.
        if (!completed) {
            if (ep_copy) |raw| {
                if (resolve.advancePlayFallback(self, loop, io, registry, raw, ordinal)) return true;
            } else {
                resolve.clearFallback(self);
            }
            var buf: [128]u8 = undefined;
            const copy = failureClassCopy(ev.cause, self.owningProvider(registry).displayName(), &buf) orelse "playback failed";
            self.pushToast(.@"error", copy, false);
        } else {
            resolve.clearFallback(self);
        }
        return false;
    }

    fn handleSyncFlushed(self: *App, outcome: event_mod.SyncFlushOutcome) void {
        // Action flush or launch pull (pushed==0); worker already cleared inflight (ROD-291/293).
        if (outcome.reconciled > 0) {
            self.history_dirty = true;
            var buf: [40]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "↓ {d} from AniList", .{outcome.reconciled}) catch "↓ from AniList";
            self.pushToast(.info, msg, false);
        }
        // Stop do-nothing flushes; reconnect nudge is ROD-295.
        if (outcome.expired) self.anilist_connected = false;
        // Silent on no-op; ↓ then ↑ so both-direction flushes read in order.
        if (outcome.pushed > 0) {
            var buf: [40]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "↑ {d} to AniList", .{outcome.pushed}) catch "↑ to AniList";
            self.pushToast(.info, msg, false);
        }
    }

    fn handleDiscoverFeedError(self: *App, ev: anytype) void {
        // Failed slot + persistent feed toast; retry via refreshDiscover (ROD-239, §9.3b).
        const slot = &self.discover.slots[@intFromEnum(ev.axis)];
        slot.loading = false;
        slot.failed = true;
        if (@intFromEnum(ev.axis) == @intFromEnum(self.discover.axis)) self.async_start_ms = 0;
        log.debug("discover feed fetch failed: {s}", .{@errorName(ev.cause)});
        self.pushToastTopic(.@"error", "can't reach the feed", true, .feed);
    }

    fn handleEnrichmentRefreshed(self: *App, ev: anytype) void {
        // Persist + stamp only when AniList answered; transport fail must not advance TTL (ROD-182/278).
        if (ev.answered) {
            if (self.store) |st| {
                // history_visible false: MAX-merge keeps hidden rows hidden.
                var arena = std.heap.ArenaAllocator.init(self.gpa);
                defer arena.deinit();
                st.upsertEnriched(ev.source, ev.result, self.translation, false, true, Store.nowSecs(), arena.allocator()) catch |e|
                    log.debug("enrichment refresh upsert failed: {s}", .{@errorName(e)});
                self.history_dirty = true;
            }
        }
        freeOwnedAnime(self.gpa, ev.result);
        self.gpa.free(ev.source);
    }

    fn handleCoverError(self: *App, for_id: []const u8) bool {
        defer self.gpa.free(for_id);
        if (self.cover.for_id == null or !std.mem.eql(u8, for_id, self.cover.for_id.?)) return true;
        self.cover.loading = false;
        self.cover.joinThread();
        if (!self.search.loading and !self.episodes.loading and !self.playing) self.async_start_ms = 0;
        // Before clear() frees inflight_url.
        self.cover.noteFailure(self.gpa, self.now_ms, for_id, self.cover.inflight_url);
        self.cover.clear(self.gpa);
        std.log.debug("cover fetch/decode failed for {s}", .{for_id});
        return false;
    }

    fn handleTickEvent(self: *App, loop: *Loop, io: std.Io, registry: Registry) void {
        const now = nowMs(io);
        self.now_ms = now;
        self.spinner_frame = (self.spinner_frame + 1) % 10;
        if (self.debounce_deadline_ms > 0 and now >= self.debounce_deadline_ms) {
            self.debounce_deadline_ms = 0;
            self.search.clearResults(self.gpa);
            self.fireSearch(loop, io, 1);
        }
        // Cover settle (ROD-202); up_to_date short-circuit makes same-show re-fire free.
        if (self.cover_sync_deadline_ms > 0 and now >= self.cover_sync_deadline_ms) {
            self.cover_sync_deadline_ms = 0;
            selection.syncCover(self, loop, io, registry);
        }
        // Action-sync debounce (ROD-291).
        if (self.sync_flush_deadline_ms > 0 and now >= self.sync_flush_deadline_ms) {
            self.sync_flush_deadline_ms = 0;
            self.fireSyncFlush(loop, io);
        }
        for (&self.toast_queue) |*slot| {
            if (slot.*) |*t| {
                if (!t.persistent) {
                    t.ttl_ms -= 100;
                    if (t.ttl_ms <= 0) slot.* = null;
                }
            }
        }
    }

    pub fn fireSearch(self: *App, loop: *Loop, io: std.Io, page: u32) void {
        const q = self.search.querySlice();
        if (q.len == 0) return;
        // One search thread: join before spawn (UAF of loop/gpa on quit).
        if (self.search_thread) |t| {
            t.join();
            self.search_thread = null;
        }
        const q_copy = self.gpa.dupe(u8, q) catch return;
        self.search.loading = true;
        self.async_start_ms = self.now_ms;
        // AniList directly; not via SourceProvider (ROD-327).
        self.search_thread = std.Thread.spawn(.{}, searchTask, .{
            loop, self.gpa, io, q_copy, page,
        }) catch {
            self.gpa.free(q_copy);
            self.search.loading = false;
            return;
        };
    }

    /// Soft cap on concurrent Discover feed threads (ROD-264). Io.Threaded is unbounded;
    /// without this, spawn storm → OS ceiling → withDeadline inline fallback. Callers
    /// today keep ≤1 per axis (4 total, ROD-339); this is headroom for future fan-out.
    const discover_feed_cap = 8;

    /// At cap: DROP spawn; later refresh/prefetch re-fires (ROD-264 #3).
    fn discoverPoolSaturated(self: *App) bool {
        return self.discover_drain.inflight.load(.acquire) >= discover_feed_cap;
    }

    /// Discover feed fetch for axis/page (ROD-336). Detached (ROD-251); never joins a prior fetch (a join here blocks the event thread and freezes the UI). Lands in that axis slot, not necessarily the active one.
    fn fireDiscoverFeed(self: *App, loop: *Loop, io: std.Io, axis: anilist.DiscoverAxis, page: u32) void {
        // This Season uses now_ms; pre-tick 0 would query WINTER-1970. Slot stays !loading.
        if (axis == .this_season and self.now_ms <= 0) return;
        if (self.discoverPoolSaturated()) {
            log.debug("discover pool at cap ({d}): dropping feed fetch, will re-fire", .{discover_feed_cap});
            return;
        }
        const slot = &self.discover.slots[@intFromEnum(axis)];
        slot.loading = true;
        self.async_start_ms = self.now_ms;
        self.discover_drain.begin();
        if (builtin.is_test) {
            self.discover_drain.finish();
            return;
        }
        const t = std.Thread.spawn(.{}, workers.discoverFeedTask, .{
            loop, self.gpa, io, axis, page, self.now_ms, &self.discover_drain,
        }) catch {
            self.discover_drain.finish();
            slot.loading = false;
            self.async_start_ms = 0;
            return;
        };
        t.detach();
    }

    /// Cache-or-fetch active Discover axis (ROD-239). Fresh within feed_ttl_secs → no network.
    pub fn refreshDiscover(self: *App, loop: *Loop, io: std.Io) void {
        const slot = self.discover.activeSlot();
        if (slot.loading) return;
        const fresh = slot.page > 0 and (Store.nowSecs() - slot.fetched_at) < feed_ttl_secs;
        if (fresh) return;
        self.fireDiscoverFeed(loop, io, self.discover.axis, 1);
    }

    /// Off-screen Discover cover pool cap (~two large pages; on-screen never evicted; ROD-243).
    const discover_cover_cap = 30;
    /// Fixed planner buffer; real grids stay well under this (ROD-243).
    const max_pump_urls = 128;

    /// Visible + one prefetch row covers; cap-bounded fan-out (ROD-240/243). After layout
    /// settles scroll. Implicit queue: next frame re-plans the live viewport.
    pub fn pumpDiscoverCovers(self: *App, loop: *Loop, io: std.Io, registry: Registry) void {
        if (self.active_view != .discover) return;

        const geo = self.discoverGeometry();
        if (geo.cols == 0 or geo.rows_visible == 0) return;

        const items = self.discover.activeSlot().results.items;
        if (items.len == 0) return;

        const start = self.discover.scroll * geo.cols;
        const span = (@as(usize, geo.rows_visible) + 1) * @as(usize, geo.cols);
        const end = @min(items.len, start + span);
        if (start >= end) return;

        self.discover_covers.frame +%= 1;
        const frame = self.discover_covers.frame;

        // Borrow thumbs from results for this pump only; stamp recency for eviction.
        var urls: [max_pump_urls][]const u8 = undefined;
        var has_pixels: [max_pump_urls]bool = undefined;
        var inflight: [max_pump_urls]bool = undefined;
        var failed_at: [max_pump_urls]i64 = undefined;
        var n: usize = 0;
        var i = start;
        while (i < end and n < max_pump_urls) : (i += 1) {
            const thumb = items[i].thumb orelse continue;
            if (self.discover_covers.get(thumb)) |slot| {
                slot.last_seen_frame = frame;
                has_pixels[n] = slot.pixels != null;
                inflight[n] = slot.status == .loading;
                failed_at[n] = slot.failed_at_ms;
            } else {
                has_pixels[n] = false;
                inflight[n] = false;
                failed_at[n] = 0;
            }
            urls[n] = thumb;
            n += 1;
        }

        self.evictDiscoverCovers(urls[0..n]);

        if (n == 0) return;

        const plan: discover_covers_mod.FetchPlan = .{
            .has_pixels = has_pixels[0..n],
            .inflight = inflight[0..n],
            .failed_at = failed_at[0..n],
            .now_ms = self.now_ms,
        };
        var chosen: [max_pump_urls]usize = undefined;
        const m = plan.eval(chosen[0..n]);
        if (m == 0) return;

        // Top in-flight to concurrency; live cap re-read each frame (ROD-240).
        const cap: usize = self.config.discoverCoverConcurrency();
        const busy = self.discover_cover_drain.inflight.load(.acquire);
        if (busy >= cap) return; // busy can exceed cap after a live decrease
        var budget = cap - busy;

        for (chosen[0..m]) |ci| {
            if (budget == 0) break;
            const url = urls[ci];

            // Mark .loading before spawn from borrowed url; early-out must reset (ROD-243).
            self.discover_covers.markLoading(self.gpa, url);

            if (builtin.is_test) {
                budget -= 1;
                continue;
            }

            const owned_url = self.gpa.dupe(u8, url) catch {
                self.resetLoadingSlot(url);
                continue;
            };

            // begin before spawn so drain never sees a gap (ROD-179).
            self.discover_cover_drain.begin();
            const t = std.Thread.spawn(.{}, workers.discoverCoverTask, .{
                loop, self.gpa, io, registry.primary(), owned_url, &self.cover_caches, &self.discover_cover_drain,
            }) catch {
                self.discover_cover_drain.finish();
                self.resetLoadingSlot(url);
                self.gpa.free(owned_url);
                continue;
            };
            t.detach();
            budget -= 1;
        }
    }

    /// Clear stranded .loading when worker never launches (ROD-240).
    fn resetLoadingSlot(self: *App, url: []const u8) void {
        if (self.discover_covers.get(url)) |slot| {
            if (slot.status == .loading) slot.status = .idle;
        }
    }

    /// Evict LRU off-screen covers past cap; never visible or in-flight (ROD-243).
    fn evictDiscoverCovers(self: *App, visible_urls: []const []const u8) void {
        const slots = self.discover_covers.slots.items;
        if (slots.len <= discover_cover_cap) return;
        const max_slots = 256;
        // Debug-loud on a ROD-241 regression; the release clamp stays (buffers below are sized to max_slots).
        std.debug.assert(slots.len <= max_slots);
        if (slots.len > max_slots) return;

        var last_seen: [max_slots]u64 = undefined;
        var vis: [max_slots]bool = undefined;
        for (slots, 0..) |*slot, i| {
            last_seen[i] = slot.last_seen_frame;
            vis[i] = slot.status == .loading or containsUrl(visible_urls, slot.url);
        }
        var out: [max_slots]usize = undefined;
        const k = discover_covers_mod.planEvictions(last_seen[0..slots.len], vis[0..slots.len], discover_cover_cap, out[0..slots.len]);
        if (k == 0) return;

        // Capture urls before swapRemove; keys stay valid until each evict frees them.
        var ev_urls: [max_slots][]const u8 = undefined;
        for (out[0..k], 0..) |idx, j| ev_urls[j] = slots[idx].url;
        for (ev_urls[0..k]) |u| self.discover_covers.evict(self.gpa, u);
    }

    fn containsUrl(urls: []const []const u8, url: []const u8) bool {
        for (urls) |u| {
            if (std.mem.eql(u8, u, url)) return true;
        }
        return false;
    }

    /// Pure refresh-on-view predicate (testable without network). TRACKED + STALE unless
    /// a competing enrich already covers it (discover feed, search enrich seam, refresh
    /// inflight). Hidden rows have their own path; skip is coarse (any competitor) (ROD-182/336).
    fn shouldRefreshOnView(
        rec: AnimeRecord,
        now: i64,
        discover_inflight: bool,
        search_enrich_active: bool,
        refresh_inflight: bool,
    ) bool {
        if (!rec.history_visible) return false;
        if (!Store.enrichmentStale(rec.enrichment_fetched_at, rec.enrichment_fieldset_version, rec.status, now)) return false;
        if (discover_inflight or search_enrich_active or refresh_inflight) return false;
        return true;
    }

    /// Re-enrich opened show when enrichment is stale (ROD-182). null rec → nothing to refresh.
    pub fn maybeRefreshEnrichment(self: *App, loop: *Loop, io: std.Io, source: ?[]const u8, source_id: []const u8, rec: ?AnimeRecord) void {
        // Before cache-hit return in fireEpisodesForId; without this, tests spawn network.
        if (builtin.is_test) return;
        if (self.store == null) return;
        const r = rec orelse return;
        const src = source orelse return;
        if (!shouldRefreshOnView(
            r,
            Store.nowSecs(),
            self.discover_drain.inflight.load(.acquire) > 0,
            false, // ROD-330 excised Browse search enrich; param kept as future seam
            self.enrich_refresh_drain.inflight.load(.acquire) > 0,
        )) return;
        self.fireRefreshEnrich(loop, io, src, source_id, r);
    }

    /// Detached refresh worker: GPA identity stub (seed_rec dies with fireEpisodes arena).
    fn fireRefreshEnrich(self: *App, loop: *Loop, io: std.Io, source: []const u8, source_id: []const u8, rec: AnimeRecord) void {
        const gpa = self.gpa;
        const copies = workers.dupeAll(gpa, 3, .{ source_id, rec.title, source }) catch return;
        const id = copies[0];
        const name = copies[1];
        const src = copies[2];
        const english: ?[]const u8 = if (rec.title_english) |e| (gpa.dupe(u8, e) catch null) else null;
        const stub: Anime = .{
            .id = id,
            .name = name,
            .english_name = english,
            .anilist_id = if (rec.anilist_id) |x| std.math.cast(u64, x) else null,
        };
        // ROD-268 residual: id-less stub has eps=0, so bestMatch skips ep-count disambiguation.

        self.enrich_refresh_drain.begin();
        const t = std.Thread.spawn(.{}, workers.refreshEnrichTask, .{
            loop, gpa, io, stub, src, &self.enrich_refresh_drain,
        }) catch {
            self.enrich_refresh_drain.finish();
            freeOwnedAnime(gpa, stub);
            gpa.free(src);
            return;
        };
        t.detach();
    }

    /// Episode pane owner from fire-time for_source (ROD-343). Late errors still name right source.
    pub fn owningProvider(self: *const App, registry: Registry) SourceProvider {
        const src = self.episodes.for_source orelse return registry.primary();
        return registry.byName(src) orelse registry.primary();
    }

    /// Pin + availability for one open show; sole funnel so they cannot drift (ROD-345/348).
    pub fn refreshShowMeta(self: *App, aid: ?i64) void {
        self.refreshShowPin(aid);
        self.refreshShowProviders(aid);
    }

    /// show_avail cache (ROD-348). No store → omit field (null aid), not all-?.
    fn refreshShowProviders(self: *App, aid: ?i64) void {
        self.show_avail = @splat(.unchecked);
        self.show_avail_aid = null;
        const id = aid orelse return;
        const st = self.store orelse return;
        self.show_avail_aid = id;
        const now = Store.nowSecs();
        for (self.settings.provider_names, 0..) |name, i| {
            if (i >= self.show_avail.len) break;
            self.show_avail[i] = st.providerAvailability(id, name, now) catch .unchecked;
        }
    }

    /// Fold bind/absence into the rail if it is the open show (ROD-348).
    pub fn noteAvailabilityWrite(self: *App, anilist_id: i64) void {
        const aid = self.show_avail_aid orelse return;
        if (aid == anilist_id) self.refreshShowProviders(aid);
    }

    /// show_pin cache for the rail; DB is authoritative (ROD-345).
    pub fn refreshShowPin(self: *App, aid: ?i64) void {
        if (self.show_pin) |p| self.gpa.free(p);
        self.show_pin = null;
        const id = aid orelse return;
        const st = self.store orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const pin = (st.getProviderPin(arena.allocator(), id) catch null) orelse return;
        self.show_pin = self.gpa.dupe(u8, pin) catch null;
    }

    /// Browse → playable provider id (ROD-328). Unresolved AniList hit: id == stringified aid.
    pub const ResolveVerdict = union(enum) {
        /// Already provider-keyed: fetch as-is.
        direct: []const u8,
        /// Tier 0: bound on provider; reuse stored id.
        bound: struct { provider: SourceProvider, id: []const u8, anilist_id: i64 },
        /// Tier A: canonicalKey opaque id; fetch confirms, then bind.
        tier_a: struct { provider: SourceProvider, id: []const u8, anilist_id: i64 },
        /// Tier C: title search must recover an id (ROD-328).
        needs_search: i64,
    };

    /// Provider-major fallback walk after the first resolve provider fails (ROD-346).
    /// Initial resolve stays tier-major (ROD-343).
    pub const Fallback = struct {
        /// gpa-owned canonical for canonicalKey + tier-C search.
        canonical: Anime,
        anilist_id: i64,
        /// Snapshot at walk creation; mid-walk preference must not reshuffle.
        providers: []SourceProvider,
        /// providers[0..next) consumed; each provider at most once.
        next: usize = 0,
        /// Bitmask of providers that already failed before the walk reached them.
        tried: u16 = 0,
        /// After hop grid lands: re-land episode and relaunch (raw gpa-owned).
        play: ?PlayCont = null,
        /// User 'v' flip: probe through fresh absence, not skip (ROD-347).
        manual: bool = false,

        pub const PlayCont = struct { episode_raw: []const u8, ordinal: u32 };

        pub fn deinit(self: *Fallback, gpa: Allocator) void {
            workers.freeOwnedAnime(gpa, self.canonical);
            gpa.free(self.providers);
            if (self.play) |cont| gpa.free(cont.episode_raw);
        }
    };

    /// Resume landing dead-end → History, not blank detail (ROD-229).
    fn demoteResumeLanding(self: *App) void {
        if (!self.resume_landing_pending) return;
        self.active_view = .history;
        self.active_pane = .list;
        self.resume_landing_pending = false;
    }

    /// Most-recently-watched history index (DESC NULLS LAST; null if none; ROD-229).
    pub fn resumeTargetIndex(self: *const App) ?usize {
        return for (self.history, 0..) |rec, i| {
            if (rec.last_watched_at != null) break i;
        } else null;
    }

    /// One-shot last_watched open after initial history load (ROD-229). Failed grid demotes.
    fn maybeResumeLanding(self: *App, loop: *Loop, io: std.Io, registry: Registry) void {
        if (self.resume_landing_done) return;
        self.resume_landing_done = true;
        if (self.config.landingEnum() != .last_watched) return;

        const idx = self.resumeTargetIndex() orelse return;
        const rec = self.history[idx];
        // list_cursor is §5.4 grouped ordinal, not history index; map via ordinalOf.
        const ordinal = history.ordinalOf(self, rec.source, rec.source_id) orelse return;
        self.list_cursor = ordinal;
        // Two-pane: in-pane grid; else full-screen zoom. term_cols 0 before first layout → zoom.
        if (self.term_cols >= pane_split_min) {
            self.active_pane = .detail;
            resolve.fireEpisodesForHistoryRecord(self, loop, io, registry, rec);
        } else {
            resolve.openHistoryZoom(self, loop, io, registry, rec);
        }
        // Arm demote only if async; cache hit already has the grid.
        self.resume_landing_pending = self.episodes.loading;
    }

    /// Load-more when cursor within ~2 card-rows of end (ROD-239).
    pub fn maybePrefetchDiscover(self: *App, loop: *Loop, io: std.Io) void {
        const slot = self.discover.activeSlot();
        if (slot.loading or slot.exhausted or slot.page == 0) return;
        const len = slot.results.items.len;
        if (len == 0) return;
        const cols: usize = discover_view.gridCols(self.term_cols);
        if (self.discover.cursor + cols * 2 >= len) {
            self.fireDiscoverFeed(loop, io, self.discover.axis, slot.page + 1);
        }
    }

    /// True when feed is short of visible + peek row (pump span; ROD-272).
    fn discoverNeedsFill(len: usize, geo: discover_view.Geometry) bool {
        if (geo.cols == 0 or geo.rows_visible == 0) return false;
        const target = (@as(usize, geo.rows_visible) + 1) * @as(usize, geo.cols);
        return len < target;
    }

    /// Fill may fire: page>0, idle, not exhausted/failed. failed gates retry storm (ROD-272).
    fn discoverFillEligible(loading: bool, exhausted: bool, failed: bool, page: u32) bool {
        return page > 0 and !loading and !exhausted and !failed;
    }

    /// Every-frame top-up to visible grid after large monitor / resize (ROD-272).
    fn maybeFillDiscover(self: *App, loop: *Loop, io: std.Io) void {
        if (self.active_view != .discover) return;
        const slot = self.discover.activeSlot();
        if (!discoverFillEligible(slot.loading, slot.exhausted, slot.failed, slot.page)) return;

        const geo = self.discoverGeometry();
        if (discoverNeedsFill(slot.results.items.len, geo)) {
            self.fireDiscoverFeed(loop, io, self.discover.axis, slot.page + 1);
        }
    }

    /// Switch Discover axis; re-select current axis retries failed/stale (§9.3b, ROD-239).
    pub fn setDiscoverAxis(self: *App, axis: anilist.DiscoverAxis, loop: *Loop, io: std.Io) void {
        if (self.discover.axis != axis) {
            self.discover.axis = axis;
            self.discover.cursor = 0;
            self.discover.scroll = 0;
        }
        self.refreshDiscover(loop, io);
    }

    // ── draw: pure render from state ─────────────────────────────────────────
    fn draw(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer) !void {
        self.cover.flushPendingFree(vx, writer);
        // Cover image lifecycle needs vx+writer on UI thread (ROD-243).
        self.discover_covers.flushPendingFrees(vx, writer);
        if (self.active_view == .discover) self.discover_covers.ensureImages(self.gpa, vx, writer);

        const win = vx.window();
        win.clear();
        win.fill(.{ .style = .{ .bg = self.palette.bg_base } });

        const w = win.width;
        const h = win.height;
        if (h < 4 or w < 16) {
            put(win, 0, 0, "terminal too small", self.s(self.palette.warn, .{}));
            try vx.render(writer);
            return;
        }

        chrome.drawTopBar(self, win, w);
        self.drawContent(vx, writer, win, h);
        chrome.drawToasts(self, win, h);
        chrome.drawBottomBar(self, win, h);

        // Connect modal on top (ROD-286).
        if (self.connect != null) connect_view.draw(self, win, w, h);

        // OSC-52 copy: draw owns the tty. Best-effort; URL stays on screen if dropped.
        if (self.connect) |*cs| {
            if (cs.copy_requested) {
                cs.copy_requested = false;
                vx.copyToSystemClipboard(writer, cs.listener.url, self.gpa) catch {};
                cs.copied = true;
            }
        }

        try vx.render(writer);
    }

    /// Two-pane threshold for Browse/History (ROD-170/259). Below: full-width list.
    pub const pane_split_min: u16 = 60;

    /// Discover axis cache TTL (ROD-239).
    pub const feed_ttl_secs: i64 = 3600;

    /// Cover settle before fetch; shorter than search debounce so single-step feels live
    /// but held j/k collapses to one fetch (ROD-202).
    pub const cover_settle_ms: i64 = 150;

    /// AniList push debounce: binge marks coalesce (ROD-291).
    pub const sync_flush_settle_ms: i64 = 3000;

    /// Quit push wall-clock cap so a dead socket cannot hang ROD-232 (ROD-294). ~one row.
    pub const quit_push_deadline_ms: i64 = 2000;

    pub const PaneSplit = struct { list_w: u16, detail_x: u16, detail_w: u16 };

    /// §3.2 list/detail split: 38% list (min 30), 2+2 margins, detail takes remainder.
    pub fn paneSplit(w: u16) PaneSplit {
        const list_w: u16 = @max(30, (w * 38) / 100);
        const detail_x: u16 = 2 + list_w + 2;
        const detail_w: u16 = if (w > detail_x + 1) w - detail_x - 1 else 0;
        return .{ .list_w = list_w, .detail_x = detail_x, .detail_w = detail_w };
    }

    fn drawContent(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer, win: vaxis.Window, h: u16) void {
        // top bar 0; breath 1; content 2..h-2; bottom bar h-1.
        const top: u16 = 2;
        const visible: u16 = h - 3;
        const body_w: u16 = if (win.width > 2) win.width - 2 else 0;

        const w = win.width;

        switch (self.active_view) {
            .history => {
                // Two-pane from pane_split_min when a row is focused (ROD-170). Detail
                // focus gets full grid (ROD-259); list focus keeps preview. Fetch on focus only.
                const rec_opt = if (w >= pane_split_min) self.selectedHistoryRecord() else null;
                if (rec_opt) |rec| {
                    const sp = paneSplit(w);
                    // Narrow list_w so meta stays in the list column.
                    history.draw(self, &self.scratch, win, top, visible, sp.list_w, sp.list_w -| 2);
                    const detail_win = win.child(.{ .x_off = @intCast(sp.detail_x), .y_off = top, .width = sp.detail_w, .height = visible });
                    if (self.active_pane == .detail) {
                        detail.drawDetailPane(self, vx, writer, detail_win, sp.detail_w, visible, true);
                    } else {
                        detail.drawHistoryPreview(self, vx, writer, detail_win, sp.detail_w, visible, rec);
                    }
                } else {
                    history.draw(self, &self.scratch, win, top, visible, w, body_w);
                }
            },

            .browse => {
                const pane_h: u16 = visible;
                if (w < 60) {
                    const list_win = win.child(.{ .x_off = 2, .y_off = top, .width = body_w, .height = pane_h });
                    browse.drawBrowseList(self, &self.scratch, list_win, pane_h, body_w);
                    return;
                }

                const sp = paneSplit(w);
                const list_win = win.child(.{ .x_off = 2, .y_off = top, .width = sp.list_w, .height = pane_h });
                const detail_win = win.child(.{ .x_off = @intCast(sp.detail_x), .y_off = top, .width = sp.detail_w, .height = pane_h });

                browse.drawBrowseList(self, &self.scratch, list_win, pane_h, sp.list_w);
                detail.drawDetailPane(self, vx, writer, detail_win, sp.detail_w, pane_h, false);
            },

            .detail => {
                const detail_win = win.child(.{ .x_off = 2, .y_off = top, .width = body_w, .height = visible });
                // Two-column only for History origin (ROD-113).
                detail.drawDetailPane(self, vx, writer, detail_win, body_w, visible, self.detail_origin == .history);
            },

            .settings => settings.drawSettings(self, win, top, visible, w),

            .discover => discover_view.draw(self, &self.scratch, win, top, visible, w),
        }
    }

    /// Scroll state half (ROD-155): run() between tick and draw; draw only reads list_top.
    pub fn layout(self: *App, h: u16, w: u16) void {
        // Every frame: initial winsize was drained before tick, so term_* would stick at 0 (ROD-156).
        self.term_cols = w;
        self.term_rows = h;
        if (h < 4 or w < 16) return;
        const visible: u16 = h - 3;
        switch (self.active_view) {
            // History list_top is physical rows (2-row entries), not Browse entry units (ROD-139).
            .history => {
                const g = history.geometry(self);
                const v: usize = visible;
                if (v == 0) {
                    self.list_top = 0;
                } else {
                    const cur: usize = g.cursor_row;
                    if (cur < self.list_top) {
                        self.list_top = cur;
                    } else if (cur + 2 > self.list_top + v) {
                        self.list_top = (cur + 2) -| v;
                    }
                    const max_top: usize = if (g.total > v) g.total - v else 0;
                    if (self.list_top > max_top) self.list_top = max_top;
                }
            },
            .browse => self.scrollIntoView(visible),
            .detail, .settings => {},
            .discover => {
                const geo = self.discoverGeometry();
                if (geo.rows_visible == 0 or geo.cols == 0) {
                    self.discover.scroll = 0;
                } else {
                    const cur_row = self.discover.cursor / geo.cols;
                    if (cur_row < self.discover.scroll) {
                        self.discover.scroll = cur_row;
                    } else if (cur_row >= self.discover.scroll + geo.rows_visible) {
                        self.discover.scroll = cur_row + 1 - geo.rows_visible;
                    }
                }
            },
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

    /// History `/` filter: match any title form (romaji/english/native), not only display (ROD-299).
    pub fn historyEntryVisible(self: *const App, rec: AnimeRecord) bool {
        if (self.history_filter_len == 0) return true;
        const q = self.history_filter[0..self.history_filter_len];
        if (std.ascii.indexOfIgnoreCase(rec.title, q) != null) return true;
        if (rec.title_english) |t| {
            if (std.ascii.indexOfIgnoreCase(t, q) != null) return true;
        }
        if (rec.native_name) |t| {
            if (std.ascii.indexOfIgnoreCase(t, q) != null) return true;
        }
        return false;
    }

    pub fn filteredHistoryLen(self: *const App) usize {
        if (self.history_filter_len == 0) return self.history.len;
        var n: usize = 0;
        for (self.history) |rec| {
            if (self.historyEntryVisible(rec)) n += 1;
        }
        return n;
    }
};

const testing = std.testing;

test "paletteFromConfig resolves known names and falls back for unknowns" {
    try testing.expectEqual(&colors.terminal_ghost, paletteFromConfig("terminal_ghost"));
    try testing.expectEqual(&colors.phosphor, paletteFromConfig("phosphor"));
    try testing.expectEqual(&colors.nord, paletteFromConfig("nord"));
    try testing.expectEqual(&colors.tokyonight, paletteFromConfig("tokyonight"));
    try testing.expectEqual(&colors.terminal_ghost, paletteFromConfig("garbage"));
    try testing.expectEqual(&colors.terminal_ghost, paletteFromConfig(""));
}

test "discoverPoolSaturated trips at (not before) the soft cap (ROD-264)" {
    var app: App = .{};
    // Empty pool: always room to spawn.
    try testing.expect(!app.discoverPoolSaturated());
    // One below the cap: still room.
    app.discover_drain.inflight.store(App.discover_feed_cap - 1, .release);
    try testing.expect(!app.discoverPoolSaturated());
    // At the cap: drop. `>=`, not `==`, so a live cap decrease that strands
    // inflight above the new cap also reads saturated (same guard as the cover pump).
    app.discover_drain.inflight.store(App.discover_feed_cap, .release);
    try testing.expect(app.discoverPoolSaturated());
    app.discover_drain.inflight.store(App.discover_feed_cap + 5, .release);
    try testing.expect(app.discoverPoolSaturated());
    // Leave the counter balanced (hygiene; this bare App is never torn down).
    app.discover_drain.inflight.store(0, .release);
}

test "discoverNeedsFill: a short first page under-fills a wide grid, a full one doesn't (ROD-272)" {
    // A wide monitor (270 cols → 12 cards/row, ~5 visible rows on the fallback box)
    // wants (5+1)*12 = 72 cards to cover the grid + peek row. A couple of
    // discover_page_size pages still leave the bottom rows empty, the bug this tops up.
    const wide = discover_view.geometry(270, 57, 0, 0);
    try testing.expectEqual(@as(u16, 12), wide.cols);
    try testing.expectEqual(@as(u16, 5), wide.rows_visible);
    try testing.expect(App.discoverNeedsFill(30, wide)); // one page → short → fill
    try testing.expect(!App.discoverNeedsFill(72, wide)); // exactly the target → full
    try testing.expect(!App.discoverNeedsFill(100, wide)); // over-full (scrolled) → no fetch

    // Too short for a card-row: never fetch, whatever the loaded count.
    const tiny = discover_view.geometry(10, 5, 0, 0);
    try testing.expectEqual(@as(u16, 0), tiny.rows_visible);
    try testing.expect(!App.discoverNeedsFill(0, tiny));
    try testing.expect(!App.discoverNeedsFill(30, tiny));
}

test "shouldRefreshOnView: tracked+stale refreshes unless a competing enrich is in flight (ROD-279)" {
    const V = Store.ENRICHMENT_FIELDSET_VERSION;
    // A tracked, never-enriched (→ stale) row with no competing enrich → refresh.
    const stale_tracked: AnimeRecord = .{
        .source = "s",
        .source_id = "i",
        .title = "T",
        .history_visible = true,
        .enrichment_fetched_at = null, // never enriched → stale
    };
    try testing.expect(App.shouldRefreshOnView(stale_tracked, 1000, false, false, false));

    // Hidden cache row: own enrich path, never refresh-on-view.
    var hidden = stale_tracked;
    hidden.history_visible = false;
    try testing.expect(!App.shouldRefreshOnView(hidden, 1000, false, false, false));

    // A freshly-stamped row (current fieldset, within the FINISHED TTL) isn't stale.
    var fresh = stale_tracked;
    fresh.enrichment_fetched_at = 1000;
    fresh.enrichment_fieldset_version = V;
    fresh.status = "FINISHED";
    try testing.expect(!App.shouldRefreshOnView(fresh, 1000, false, false, false));

    // ROD-279: any single competing enrich in flight suppresses the refresh.
    try testing.expect(!App.shouldRefreshOnView(stale_tracked, 1000, true, false, false)); // discover feed/zoom enrich
    try testing.expect(!App.shouldRefreshOnView(stale_tracked, 1000, false, true, false)); // live browse search enrich
    try testing.expect(!App.shouldRefreshOnView(stale_tracked, 1000, false, false, true)); // another refresh in flight
}

test "discoverFillEligible gates the fill on an established, idle, live feed (ROD-272)" {
    // Each blocker must veto alone; only all-clear fires (ROD-272).
    try testing.expect(App.discoverFillEligible(false, false, false, 1));
    try testing.expect(!App.discoverFillEligible(false, false, false, 0)); // page 0 is refreshDiscover's
    try testing.expect(!App.discoverFillEligible(true, false, false, 1));
    try testing.expect(!App.discoverFillEligible(false, true, false, 1));
    // failed must veto, else every-frame fill becomes a retry storm.
    try testing.expect(!App.discoverFillEligible(false, false, true, 1));
}
