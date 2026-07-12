//! Zigoku — TUI shell (ROD-71).
//!
//! The libvaxis application skeleton the rest of the app builds into. It owns:
//!   - vaxis init / alt-screen / teardown,
//!   - the event loop with a clean render/tick split (tick mutates state, draw is a
//!     pure function of state),
//!   - resize handling,
//!   - the worker→UI seam: background work posts into vaxis's event queue via
//!     Loop.postEvent, and the main loop drains it through nextEvent.
//!
//! Landing view is History (a locked default; the startup view is resolved from
//! config.landingEnum below).

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

// Per-view render passes, extracted along the tick/draw seam (ROD-144).
const chrome = @import("view/chrome.zig");
const history = @import("view/history.zig");
const browse = @import("view/browse.zig");
const detail = @import("view/detail.zig");
const settings = @import("view/settings.zig");
const discover_view = @import("view/discover.zig");
const connect_view = @import("view/connect.zig");
const discover_covers_mod = @import("discover_covers.zig");
const login_loopback = @import("../login_loopback.zig");

/// Current-selection resolution (ROD-277): resolves which anime/record is
/// focused across Browse/History/Discover/Detail and formats the derived
/// display strings. The App methods below forward into it; the canonical docs
/// live there.
const selection = @import("selection.zig");
const input = @import("input.zig");

const Allocator = std.mem.Allocator;
const AnimeRecord = store_mod.AnimeRecord;
const Store = store_mod.Store;
const Config = config_mod.Config;
const SourceProvider = source_mod.SourceProvider;
const Registry = source_mod.Registry;
const Anime = domain.Anime;
const Event = event_mod.Event;
const Loop = event_mod.Loop;
// Only `put` survives in app.zig (the "terminal too small" guard in `draw()`);
// the rest of the render helpers now live with the per-view passes (ROD-144).
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

/// mpv playback session subsystem (ROD-162). Owns the playing-episode record +
/// progress/watched-state persistence in its own module; re-exported here so
/// existing `app_mod.PlaybackSession` references keep resolving.
pub const PlaybackSession = @import("playback_session.zig").PlaybackSession;

/// Episode cache + detail-grid subsystem (ROD-180). Owns the detail pane's
/// episode list/cursor/watched-mark + the two-tier episode cache in its own
/// module; re-exported here so existing `app_mod.EpisodeState` references keep
/// resolving.
pub const EpisodeState = @import("episode_state.zig").EpisodeState;

/// Search + enrich controller subsystem (ROD-219). Owns the catalogue-search
/// record (query / results / page / loading + the queued enrich request) in its
/// own module; transport (the worker threads, `async_start_ms`, debounce) and
/// the `fireSearch` spawn stay on App, matching the EpisodeState
/// carve. Re-exported here so existing `app_mod.SearchController` references keep
/// resolving.
pub const SearchController = @import("search_state.zig").SearchController;
pub const DiscoverState = @import("discover_state.zig").DiscoverState;
pub const DiscoverCovers = @import("discover_covers.zig").DiscoverCovers;

/// Run the TUI to completion. `store` is optional and best-effort, exactly like
/// the CLI path: a DB hiccup means "no history," never a refusal to run.
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
    // Learn terminal caps (kitty graphics/keyboard) before the first paint.
    try vx.queryTerminal(writer, .fromMilliseconds(500));

    // Honour COLORTERM=truecolor/24bit. vaxis only flips caps.rgb on a terminal
    // XTGETTCAP reply (Loop.zig `cap_rgb`); a terminal that does 24-bit color but
    // doesn't answer that query — notably vhs's headless recorder, but also some
    // tmux/ssh setups — otherwise downsamples our truecolor palette to 256-color.
    // COLORTERM is the standard signal; vaxis's own check is commented out upstream.
    if (environ_map.get("COLORTERM")) |ct| {
        if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit"))
            vx.caps.rgb = true;
    }

    // Drain events that accumulated during queryTerminal before the first paint. The
    // tty reader may have posted an initial .winsize and/or CPR-derived key_press:
    // vaxis's width queries produce \e[1;1R, which Parser decodes as F3-no-mods, and
    // Loop's guard only consumes F3+shift/alt, so it leaks through and would trigger the
    // Discover keybind (ROD-249). getWinsize() below compensates for a swallowed
    // .winsize.
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
    app.app_version = std.fmt.bufPrint(&app.version_buf, "v{s}", .{app_version}) catch app_version;
    // Seed the cell-pixel cache from the initial resize (the .winsize event was
    // drained above, so read vaxis's settled screen) — Discover's cover-fill height
    // needs it on the first frame (ROD-247).
    app.term_x_pixel = @intCast(vx.screen.width_pix);
    app.term_y_pixel = @intCast(vx.screen.height_pix);
    // Resolve the cover-cache path once for the Settings "cover art cache" row,
    // HOME-collapsed for display. Best-effort: a missing cache home leaves this
    // null and the row falls back to a literal (ROD-225).
    app.cover_cache_display = blk: {
        const abs = workers.coverCacheDir(gpa) catch break :blk null;
        defer gpa.free(abs);
        break :blk paths.collapseHome(gpa, abs) catch null;
    };
    app.palette = paletteFromConfig(config.palette);
    // The configured sub/dub default seeds the search translation; the user can
    // still toggle it live in-session (ROD-85).
    app.translation = config.translationEnum();
    // Seed the startup view from config (ROD-228). `.last_watched` folds to
    // History until ROD-229 wires the resume-landing; Browse with no results
    // lands on its idle search prompt (view/browse.zig), never a blank pane.
    app.active_view = switch (config.landingEnum()) {
        .browse => .browse,
        .history, .last_watched => .history,
    };
    // Preset list for the Settings provider row (ROD-344): the registry's names
    // in construction order. The names are static vtable strings; only the
    // slice needs an owner, and it must outlive the app loop.
    const provider_names = try gpa.alloc([]const u8, registry.providers.len);
    defer gpa.free(provider_names);
    for (registry.providers, 0..) |p, pi| provider_names[pi] = p.name();
    app.settings.provider_names = provider_names;
    defer app.deinitOwnedState(&vx, writer);

    // ── AniList connection (ROD-291) ──────────────────────────────────────────
    // Resolve the token once at boot into a session-lived arena so each background
    // flush reuses it without re-reading the file. Best-effort like the CLI's runSync:
    // an absent/unreadable token leaves `anilist_connected` false and every armSyncFlush
    // a no-op. Mid-session expiry is not re-checked here (the flush returns a no-op and
    // drops `anilist_connected`; reconnect nudge is ROD-295). The arena's deinit defer is
    // registered before the sync-thread join, so LIFO frees the token only after that
    // join on the error-unwind path (the quit path skips both via `_exit`).
    var auth_arena = std.heap.ArenaAllocator.init(gpa);
    defer auth_arena.deinit();
    if (auth_mod.defaultPath(auth_arena.allocator())) |auth_path| {
        app.anilist_auth = auth_mod.load(auth_arena.allocator(), io, auth_path);
        app.anilist_connected = app.anilist_auth.hasAniList() and
            !app.anilist_auth.anilist.isExpired(Store.nowSecs());
    } else |e| {
        log.debug("anilist: no config dir for token: {s}", .{@errorName(e)});
    }

    // Seed the tick clock now so a mutation landing before the first .tick (a scripted
    // launch keypress from a capture/e2e harness) arms the sync debounce off a real
    // timestamp, not the 0 default (which would put the first deadline ~3s past the
    // epoch and fire on the next tick, collapsing the debounce window; ROD-291 review).
    app.now_ms = nowMs(io);

    // History memory lives in a double-buffered pair of arenas owned here, freed on
    // exit (ROD-191). One arena backs the live `self.history` slice (`hist_live`), the
    // other is idle; a post-playback reload fills the idle arena off-thread and swaps
    // via setHistory once .history_loaded lands, so the old slice stays valid for vaxis
    // until the new one is ready. (ROD-141: a slice handed to vaxis must outlive the
    // frame; that applies to the whole history slice, not just a chip.)
    var hist_arenas: [2]std.heap.ArenaAllocator = .{
        std.heap.ArenaAllocator.init(gpa),
        std.heap.ArenaAllocator.init(gpa),
    };
    defer for (&hist_arenas) |*a| a.deinit();
    var hist_live: usize = 0;

    // The worker→UI seam: load history off a background thread. It posts the
    // result into the same queue the tty reader feeds; tick() drains it. The
    // thread is short-lived and joined before teardown.
    var hist_thread: ?std.Thread = null;
    // On quit, abandon an in-flight history query before joining so teardown never
    // blocks on the SELECT: sqlite3_interrupt makes the worker's sqlite3_step bail, the
    // join returns at once, the discarded result is never read. (The episode-prefetch
    // half of ROD-179 detaches a superseded fetch instead; see `episode_drain`.)
    //
    // Declared before the search join and episode drain, so by LIFO it runs
    // AFTER them: every other worker is already reaped when interrupt fires, so it can
    // only hit loadHistory's statement, never one another worker started.
    defer if (hist_thread) |t| {
        if (store) |st| st.interrupt();
        t.join();
    };
    if (store) |st| {
        hist_thread = std.Thread.spawn(.{}, loadHistoryTask, .{ &loop, hist_arenas[0].allocator(), st }) catch blk: {
            // Couldn't spawn — fall back to a synchronous load so the user still
            // sees their history.
            app.setHistory(st.loadHistory(hist_arenas[0].allocator()) catch &.{});
            // ROD-229: same resume-landing resolution as the async .history_loaded
            // path, so a spawn-failure boot still honors landing == last_watched.
            app.maybeResumeLanding(&loop, io, registry);
            break :blk null;
        };
    } else {
        app.history_loading = false;
    }

    // Join the last search thread before loop teardown so in-flight threads
    // can't dereference a torn-down loop or gpa. Declared after loop.stop()'s
    // defer so it executes first (Zig defers are LIFO).
    defer if (app.search_thread) |t| t.join();
    // ROD-291: join an in-flight AniList flush on the error-unwind / test teardown path
    // so it can't touch a torn-down loop/store/gpa or the freed token arena. Like the
    // search/cover joins above, this defer is SKIPPED on the ordinary quit path
    // (q/Ctrl-C fall through to the ROD-232 fast-exit `_exit(0)`). Safe for this writer:
    // the DB is WAL crash-safe and SaveMediaListEntry is idempotent, so a push abandoned
    // before its markSynced leaves the row dirty and re-flushes next session.
    defer if (app.sync_thread) |t| t.join();
    // ROD-286: reap an open connect modal on the error-unwind / test path — cancel the
    // worker (waking its blocked accept), join it, close the listener, free the arena.
    // Skipped on the ordinary quit path (`_exit` abandons it, like every other worker);
    // the worker skips its final postEvent on cancel, so this join can't stall.
    defer app.teardownConnect(io);
    defer app.discover_drain.drain();
    defer app.episode_drain.drain();
    defer app.enrich_refresh_drain.drain(); // ROD-182 refresh-on-view workers
    defer app.add_resolve_drain.drain(); // ROD-327 tier-A add-resolve workers
    defer app.play_resolve_drain.drain(); // ROD-328 tier-C Play resolve workers
    defer app.prewarm_drain.drain(); // ROD-351 eager pre-warm walk
    // Cover worker must be joined on both the normal shutdown path and any
    // error unwind path before `loop`, `gpa`, or the caches are torn down.
    defer app.cover.joinThread();
    // Discover-grid cover workers: drain the bounded fan-out (ROD-240). Same
    // contract as the single-cover join — the quit `_exit` path skips this defer and
    // abandons the workers (the global Kitty clear drops their images, nothing is
    // freed); this drain covers the error-unwind/test paths, blocking until every
    // in-flight cover worker has finished before `loop`/`gpa`/caches tear down.
    defer app.discover_cover_drain.drain();
    // Error-unwind/test path only (the quit `_exit` skips this defer — see ROD-232
    // block below). Since ROD-309 the play worker may be mid retry-backoff on a CDN
    // penalty window, so this join can now sit up to ~6s longer than a single mpv run.
    defer if (app.play_thread) |t| t.join();

    // Tick thread: 100ms heartbeat for spinner + search debounce. Joins before
    // loop.stop() (LIFO — this defer is declared after the loop.stop() defer).
    var tick_quit: std.atomic.Value(bool) = .init(false);
    const tick_thread = std.Thread.spawn(.{}, tickTask, .{ &loop, io, &tick_quit }) catch null;
    defer {
        tick_quit.store(true, .release);
        if (tick_thread) |t| t.join();
    }

    // History-reload coordination (ROD-191). The reload worker posts a dedicated
    // terminal event (success or failure) that bumps `history_reload_settled`; we
    // detect that, join the worker, and flip `hist_live` only on success. A single
    // reload runs at a time; a play that finishes mid-reload leaves the dirty flag
    // set so the next iteration re-arms with the newer store state.
    var reload_inflight = false;
    var reload_settled_at_spawn: u32 = 0;

    // ROD-293: kick a background pull-on-launch so local reflects edits made on other
    // devices since last run. Pull-only, off-thread, ambient — no-op when unconnected /
    // no store. Reconciles into the store; a changed row flags a history reload at the
    // safe seam (the reload gate already waits for the initial load via !history_loading,
    // so this can't race the first paint) and whispers a low-key `↓ N from AniList`. The
    // teardown join defer above already covers its `sync_thread` handle. It shares the
    // action flush's one-flush gate, so a very early mutation just re-arms behind it
    // (fireSyncFlush sees inflight and waits).
    app.fireLaunchPull(&loop, io);

    // ROD-370: best-effort boot update check on its own thread; compares our build
    // against GitHub's latest release and whispers `.update_available` if we're behind.
    // Gated by config (the hard opt-out) and skipped under test. The worker keeps all
    // its state thread-local (posts a payloadless event), so a plain spawn/join suffices.
    const update_thread: ?std.Thread = if (config.check_for_updates and !builtin.is_test)
        std.Thread.spawn(.{}, workers.updateCheckTask, .{ &loop, gpa, io, app_version }) catch null
    else
        null;
    defer if (update_thread) |t| t.join();

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
        if (event == .winsize) {
            try vx.resize(gpa, writer, event.winsize);
            // Cache pixel metrics for the Discover cover-fill height (ROD-247);
            // term_cols/term_rows are reseeded in layout() right after tick().
            app.term_x_pixel = @intCast(vx.screen.width_pix);
            app.term_y_pixel = @intCast(vx.screen.height_pix);
        }
        try app.tick(event, &loop, io, registry);

        // ROD-191: reap a finished reload. Its terminal event (success OR failure)
        // bumped history_reload_settled, so the latch always clears — even when
        // loadHistory errors (a transient SQLITE_BUSY must not wedge every future
        // refresh). Flip hist_live to the just-filled arena ONLY on
        // success: on failure setHistory never ran, so the live slice still points
        // into the old arena and flipping would dangle it on the next reload.
        if (reload_inflight and app.history_reload_settled != reload_settled_at_spawn) {
            if (hist_thread) |t| t.join();
            hist_thread = null;
            if (app.history_reload_ok) hist_live = 1 - hist_live;
            reload_inflight = false;
        }
        // Re-arm: a meaningful playback dirtied history. Wait for the initial load
        // to land first (!history_loading) so a stale initial .history_loaded can't
        // clobber a reload's slice, and never stack two reloads (!reload_inflight).
        if (app.history_dirty and !reload_inflight and !app.history_loading) {
            if (store) |st| {
                if (hist_thread) |t| t.join(); // reap the (finished) initial/previous load
                hist_thread = null;
                const next = 1 - hist_live;
                // Safe to reset: the previous worker is joined (nothing still
                // allocates here), and the live slice lives in the *other* arena.
                _ = hist_arenas[next].reset(.retain_capacity);
                reload_settled_at_spawn = app.history_reload_settled;
                hist_thread = std.Thread.spawn(.{}, reloadHistoryTask, .{ &loop, hist_arenas[next].allocator(), st }) catch null;
                if (hist_thread != null) {
                    reload_inflight = true;
                    app.history_dirty = false;
                } else {
                    // Spawn failed — load synchronously into the idle arena. Flip
                    // only on success; on failure keep the current slice (don't wipe
                    // the watchlist to empty over a transient error) and leave
                    // hist_live untouched.
                    if (st.loadHistory(hist_arenas[next].allocator())) |recs| {
                        app.setHistory(recs);
                        hist_live = next;
                    } else |e| {
                        log.debug("sync history reload failed: {s}", .{@errorName(e)});
                    }
                    app.history_dirty = false;
                }
            } else {
                app.history_dirty = false; // no store — nothing to reload
            }
        }

        // Settle the list viewport before drawing: layout() is the state half
        // of the scroll seam, so draw() reads list_top without writing it
        // (ROD-155). run() owns geometry, so it feeds the terminal size in.
        const win = vx.window();
        app.layout(win.height, win.width);
        // ROD-243: fetch the visible grid's covers off-thread once scroll is settled
        // (geometry known). No-op outside Discover / when nothing's missing.
        app.pumpDiscoverCovers(&loop, io, registry);
        // ROD-272: top the feed up to the visible grid on a large monitor / after a
        // resize — same settled geometry, debounced by the slot's in-flight flag.
        app.maybeFillDiscover(&loop, io);
        try app.draw(&vx, writer);
    }

    // ROD-232: fast-exit on the quit path. Falling out of the loop only happens on a
    // user quit (q / Ctrl-C), which has nothing to wait for: the durable writes already
    // landed (Settings saves synchronously in onKey; playback progress is checkpointed
    // on the main thread as .position_update events arrive), so abandoning the play
    // worker loses at most a few seconds of resume position, not the row (mpv is a
    // detached child and keeps running). The other workers (enrich/episode/cover/search)
    // are network reads; the DB is autocommit and the cover cache is crash-safe via
    // atomic rename. So rather than the graceful drain below (which can sit 5+s on each
    // worker's withDeadline (ROD-153) and can deadlock when the bounded event queue
    // fills, a worker's final postEvent blocking in push() while the loop stopped
    // popping; ROD-179), we restore the terminal and terminate, leaving the workers for
    // the OS to reap.
    //
    // Terminate, don't return: the abandoned workers postEvent into the loop's queue, so
    // the queue must die WITH the process; we can't loop.stop() out from under them
    // (use-after-free). And it must be _exit, not std.process.exit: libc is linked, so
    // the latter routes through C exit(), which runs atexit handlers and flushes stdio on
    // THIS thread while the workers are still live: the exact wedge we're killing. _exit
    // is the exit syscall directly, no handlers/locks/stdio. The terminal is restored and
    // flushed below first, and every defer (the ThreadDrain barrier + the worker joins)
    // is skipped; those stay for the error-unwind path and tests, which can't _exit.
    //
    // ROD-238: a Kitty cover can leave a stray terminal response in the tty queue at
    // exit (the vaxis fork's q=2 quiet placement means the terminal never acks, but we
    // still sweep residuals below and clear the images here when a cover was shown).
    // `next_img_id` starts at 1 and only `transmitImage` bumps it, so `> 1` means a
    // cover was sent; a cover-less quit pays nothing. Captured before `vx.deinit`.
    const transmitted_cover = vx.next_img_id > 1;
    if (vx.caps.kitty_graphics) {
        // Drop lingering cover images explicitly — leaving the alt-screen does
        // not reliably clear Kitty graphics on every terminal. `q=2` so the
        // delete itself is not acked onto the prompt. A pure terminal write: it
        // touches none of the cover caches a cover worker may still be reading,
        // so nothing is freed here.
        writer.writeAll(kitty_graphics_clear_quiet) catch {};
    }
    // resetState only (alloc = null): show cursor, sgr/kitty-keyboard reset,
    // leave alt-screen, flush — no frees, since _exit reclaims it all and
    // skipping the frees keeps us off vx.screen entirely. The output side is the
    // tty reader thread's blind spot (it reads input), so this can't race it.
    vx.deinit(null, writer);
    // Must run before tty.deinit (which closes /dev/tty off macOS) while the fd
    // is still open. Best-effort and safe against the still-parked reader thread:
    // whichever of the two reads a stray byte, the other just finds nothing, and
    // Loop.ttyRun swallows read errors (`catch {}`), so a WouldBlock on the
    // reader's NEXT read ends it cleanly.
    if (transmitted_cover) drainTtyResponses(tty.fd.handle);
    // Restore cooked-mode termios (and close /dev/tty off macOS). The reader
    // thread is parked in read(); tcsetattr is safe concurrently, and the close
    // can't fault before _exit reaps the thread on its heels.
    tty.deinit();
    // ROD-294: last act before _exit — flush any still-dirty rows to AniList within a
    // hard, pool-independent deadline (the mirror of the ROD-293 launch pull at the other
    // end of the session). The terminal is already restored, so the bounded wait shows a
    // normal cooked-mode prompt, not a frozen TUI; the bound holds even under thread-pool
    // starvation, so a dead socket can't hang quit. No-op when disconnected or when any
    // sync worker is inflight (never push alongside a pull — ROD-285 ordering).
    app.quitFlush(io);
    std.c._exit(0);
}

/// Kitty graphics "delete all" with the `q=2` quiet flag appended, so the
/// terminal does not ack the delete onto the shell on the `_exit` quit path
/// (vaxis's `ctlseqs.kitty_graphics_clear` omits `q`). ROD-238.
const kitty_graphics_clear_quiet = "\x1b_Ga=d,q=2\x1b\\";

/// ROD-238: a fast residual sweep of the tty input queue before the ROD-232 `_exit`.
/// The real fix is upstream: the vaxis fork places covers with the Kitty `q=2` quiet
/// flag, so the terminal no longer acks each placement and the `_Gi=N;OK` flood ROD-236
/// chased never exists. This is belt-and-suspenders for any lone byte already in the
/// buffer (a stray response, a final keypress) so it can't echo onto the shell.
///
/// Deliberately NOT a sentinel fence: with the flood gone there is nothing to fence, and
/// a sentinel's own reply would become the response left in flight; over a high-latency
/// link (tmux/SSH) a bounded wait could give up before it round-trips and leak `ESC [ ?
/// … c`, recreating the very bug (ROD-236 leaked over exactly such a link). So we drain
/// only what has already arrived: poll a short grace window and stop the instant a poll
/// finds nothing (a clean q=2 quit returns in one poll), bounded by `max_rounds *
/// poll_ms`. Best-effort; racing the parked reader is safe (it swallows read errors).
/// The fd is left non-blocking on return, since we `_exit` next.
pub fn drainTtyResponses(fd: std.posix.fd_t) void {
    // fcntl moved behind Io in Zig 0.16; with libc linked, std.c.fcntl is the
    // escape (matches the std.c.unlink/c.time pattern already in store.zig).
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
        _ = std.c.poll(&pfd, 1, poll_ms); // brief grace for an already-in-flight byte
        if ((pfd[0].revents & std.c.POLL.IN) == 0) break; // nothing waiting → done
        inner: while (true) {
            const n = std.posix.read(fd, &buf) catch break :inner; // WouldBlock/empty
            if (n == 0) break :inner; // EOF
        }
    }
}

pub const Toast = struct {
    pub const Kind = enum { info, success, @"error", warn };
    /// §4.7 width contract, one source of truth for both the push-time truncation
    /// (`pushToast`) and the render (`chrome.drawToasts`). The toast box is at most
    /// `max_box_cols` display columns wide *including* the 4-column "[!] " glyph
    /// prefix, so dynamic copy gets `max_copy_cols` (= 36). The only copy that can
    /// exceed it today is `task_error`'s `@errorName` payload; it is truncated to
    /// fit with a trailing "…" (ROD-166).
    pub const max_box_cols: u16 = 40;
    pub const glyph_cols: u16 = 4; // "[!] "/"[✓] "/"[~] " all paint 4 cells.
    pub const max_copy_cols: u16 = max_box_cols - glyph_cols;
    /// Which subsystem owns a persistent error, so each view's recovery clears
    /// only its own (ROD-239): a feed success must not wipe a Browse search error,
    /// or vice versa. Non-error / transient toasts ignore it.
    pub const Topic = enum { general, feed };
    kind: Kind,
    text: [80]u8 = undefined,
    text_len: usize = 0,
    /// Remaining TTL in ms. Ignored when persistent = true.
    ttl_ms: i32 = 4000,
    /// Persistent toasts survive TTL and are only cleared by a recovery path.
    persistent: bool = false,
    /// Recovery scope for persistent errors — see `Topic`.
    topic: Topic = .general,
};

/// Resolve a config palette name to its static `colors.Palette`, falling back
/// to the default for anything unrecognized. Stays on App (not in
/// `SettingsState`): it's an App-live projection the controller re-derives after
/// a settings change, and `run()` also calls it at startup.
pub fn paletteFromConfig(name: []const u8) *const colors.Palette {
    if (std.mem.eql(u8, name, "phosphor")) return &colors.phosphor;
    if (std.mem.eql(u8, name, "nord")) return &colors.nord;
    if (std.mem.eql(u8, name, "tokyonight")) return &colors.tokyonight;
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
    /// Per-row Browse score badges (compact "[NN]" list form, no `/100`),
    /// right-anchored in the list meta column (ROD-226). Separate from `meta`
    /// (the eps count) because both render on the same row at different columns
    /// and so must coexist until vx.render(). [8] covers "[100]" with slack.
    score: [256][8]u8 = undefined,
    /// Single-line scratch for the list passes' spinners and empty-state
    /// messages. Safe to share between Browse and History because only one view
    /// is active per frame. NOT for the detail pane: detail co-renders with
    /// Browse in split layout, so it has its own `detail_msg` to avoid clobbering
    /// a slice vaxis still holds by reference.
    msg: [160]u8 = undefined,
    /// Detail-pane cover spinner glyph. Separate from `msg` so the split-pane
    /// frame (Browse list + detail) never aliases one buffer (ROD-155 review).
    detail_msg: [32]u8 = undefined,
    /// Per-group "(N)" count strings for the History group headers (ROD-139). One
    /// slot per status group; same outlive-vx.render() contract as `meta`. 8 slots:
    /// 5 statuses today, 3 spare. Headers past the 8th silently drop their count.
    hist_header: [8][24]u8 = undefined,
    /// Per-card Discover title strings, ellipsis-truncated to the card width
    /// (ROD-245). vaxis holds the printed slice by reference, so the truncated copy
    /// must outlive vx.render() — same contract as `meta`/`score`. [80] is the safe
    /// byte ceiling for a 20-col card title: at most 19 display columns survive (the
    /// 20th is reserved for "…"), and the densest *single code point* is 4 bytes →
    /// 19×4 + 3 ("…") = 79. Grapheme clusters spanning multiple code points are
    /// rarer and wider, but `truncateToWidth` self-guards on the byte budget before
    /// overrunning regardless.
    title: [256][80]u8 = undefined,
    /// Per-card Discover score badges ("[NN]"/"[--]", ROD-247), right-anchored on
    /// the card rank row. Separate from `score` (the Browse list form) and from the
    /// card's rank string because all three can live on screen the same frame; same
    /// outlive-vx.render() contract. [8] covers "[100]" with slack.
    disc_badge: [256][8]u8 = undefined,
    /// Per-card Discover genre glyphs (up to two monochrome symbols, ROD-247),
    /// right-anchored on the view-count row. Blank for unenriched/unmapped cards.
    /// Same outlive-vx.render() contract as `title`. [48] is ample for two ≤4-byte
    /// glyphs.
    disc_genre: [256][48]u8 = undefined,
};

/// Single-level undo record for manual watch-state mutations (ROD-193). Tagged
/// union only — Zig has no closures. Each variant carries the full revert payload
/// so `applyUndo` can reconstruct the prior state without re-reading the store.
pub const UndoEntry = union(enum) {
    set_list_status: struct {
        source: []u8, // GPA-owned, duped at push
        source_id: []u8, // GPA-owned, duped at push
        prev_status: domain.ListStatus,
        prev_progress: i64,
    },

    /// Release GPA-owned slices. Call before discarding an entry.
    pub fn free(self: UndoEntry, gpa: Allocator) void {
        switch (self) {
            .set_list_status => |e| {
                gpa.free(e.source);
                gpa.free(e.source_id);
            },
        }
    }
};

/// The live in-TUI AniList connect flow (ROD-286). Non-null exactly while the connect
/// modal is up: a bound loopback listener + its accept-loop worker are running and the
/// modal overlays Settings. Every field the worker touches lives behind the boxed
/// `arena`, so its address is stable no matter where this optional sits in `App`: the
/// worker borrows `listener` (accept) and `cancel` (poll); the render thread reads
/// `listener.url` and, on esc, sets `cancel` then wakes the blocked accept
/// (`login_loopback.requestCancel`). Torn down by `App.teardownConnect`.
pub const ConnectState = struct {
    /// Heap-boxed so `listener`/`cancel` keep stable addresses across the thread
    /// seam; owns the `url`/`path`/`listener`/`cancel` allocations. Freed (with the
    /// box) in `teardownConnect`, only after the worker is joined.
    arena: *std.heap.ArenaAllocator,
    /// The listener the worker accepts on; `url` renders in the modal + opens the
    /// browser. Lives in `arena`.
    listener: *login_loopback.Listener,
    /// Worker cancel flag: set (release) before `requestCancel` so the woken accept
    /// bails. Lives in `arena`. `std.atomic` for the cross-thread read.
    cancel: *std.atomic.Value(bool),
    /// The accept-loop worker handle, joined in `teardownConnect`.
    thread: ?std.Thread,
    /// The `[c]` keypress latched an OSC-52 clipboard copy request; serviced in
    /// `draw` (which owns the tty), which then sets `copied`.
    copy_requested: bool = false,
    /// The copy landed (best-effort) — flips the modal hint to "copied ✓".
    copied: bool = false,
    /// Tick clock (ms) when the flow began — drives the modal's elapsed hint.
    started_ms: i64 = 0,
    /// Scratch for the modal's formatted "waiting… Ns" status line. Owned here, NOT a
    /// draw-local stack buffer: vaxis keeps the printed slice by reference until
    /// `vx.render()`, which runs after the view's stack frame is gone — a local buffer
    /// would dangle and render as garbage (the same hazard as `SettingsState.value_buf`
    /// and the settings hairline). The connect modal is up for one flow, so one buffer
    /// on this per-flow state is the natural home.
    status_buf: [48]u8 = undefined,
};

pub const App = struct {
    /// Ceiling on registry providers the detail rail tracks (ROD-348).
    /// Providers past it drop off the rail SILENTLY, serving marker included.
    /// Sized well past the 2-4 the design targets; `detail_provider_buf` is
    /// the binding constraint and needs widening first (§5.3a).
    pub const max_rail_providers = 8;

    should_quit: bool = false,

    /// Landing data. Backed by run()'s history arena — App only reads it.
    history: []AnimeRecord = &.{},
    history_loading: bool = true,
    /// Set if the background history load failed.
    load_error: ?[]const u8 = null,

    /// ROD-191: a meaningful playback wrote/moved a history row that the in-memory
    /// `history` slice may not know about (a brand-new show only exists in the store
    /// after recordPlay). run()'s loop consumes this to fire an off-thread history
    /// reload at a safe seam — between frames, never mid-render.
    history_dirty: bool = false,
    /// Bumped when a reload reaches a terminal state — success (.history_reloaded)
    /// OR failure (.history_reload_failed). run() watches it to reap the worker and
    /// clear `reload_inflight`, so a failed reload can never latch the reloader off.
    /// A wrapping counter — only frame-to-frame equality matters.
    history_reload_settled: u32 = 0,
    /// Whether the last settled reload succeeded — gates the double-buffer flip in
    /// run(): flip the live arena only when setHistory actually swapped the slice.
    history_reload_ok: bool = false,

    /// ROD-229: resume-landing one-shot. Set the first time history finishes its
    /// INITIAL load, so a `landing = "last_watched"` auto-open fires exactly once
    /// at boot and never on a post-playback reload (reloads post .history_reloaded,
    /// not .history_loaded, so this guard is belt-and-suspenders).
    resume_landing_done: bool = false,
    /// ROD-229: true while an auto-opened resume grid fetch is in flight. If that
    /// fetch fails (offline / source error) we demote back to History rather than
    /// strand the user on a blank detail pane. Cleared by any superseding fetch,
    /// by grid-load success, or by the demote itself.
    resume_landing_pending: bool = false,

    /// ROD-327: the canonical anilist_id to bind once the current Browse episode fetch
    /// (the tier-A existence probe) confirms the play provider stocks the show. Set right
    /// after a resolving Browse fire; consumed by `.episodes_done` (mint the binding) and
    /// cleared by `.episodes_error` (the resolver miss). `fireEpisodesForId` nulls it at
    /// entry so a non-resolving open (History/Discover) can never inherit a stale bind.
    pending_bind: ?i64 = null,

    /// ROD-346: the in-flight provider-fallback walk, or null. Built at the FIRST
    /// failure of a canonical-capable episode fetch (never at fire time: the fetch
    /// identity (for_source, for_id) is the H2-safe key, live nav state is not),
    /// advanced by each subsequent failure, freed on grid success, exhaustion, or
    /// any user-driven fire. Walk hops take it out of this field before re-entering
    /// `fireEpisodesForId` (which clears it, same idiom as `pending_bind`) and put
    /// it back once the hop is in flight.
    fallback: ?Fallback = null,

    /// ROD-345: the open show's provider pin (gpa-owned copy), cached at grid-open
    /// and flip time so the render path never reads the DB. Null = unpinned (or no
    /// canonical identity). Refreshed via `refreshShowPin`.
    show_pin: ?[]u8 = null,

    /// ROD-348: per-provider availability for the open show, index-aligned with
    /// `settings.provider_names` (registry construction order, §5.3a). Cached
    /// beside the pin for the same reason (render never reads the DB); re-read
    /// on any bind/absence write for the same show (`noteAvailabilityWrite`).
    /// A null `show_avail_aid` means no canonical identity: both render forms
    /// omit the Provider field outright.
    show_avail: [max_rail_providers]Store.ProviderAvailability = @splat(.unchecked),
    show_avail_aid: ?i64 = null,

    history_filter: [128]u8 = undefined,
    history_filter_len: usize = 0,

    list_cursor: usize = 0,
    /// Topmost visible row index — the viewport offset for scrolling.
    list_top: usize = 0,

    /// Per-frame render scratch (formatted meta/bar/message strings). Grouped
    /// off application state so the list passes can take `*const App` (ROD-155);
    /// see RenderScratch for the vaxis by-reference lifetime contract.
    scratch: RenderScratch = .{},

    /// Which top-level view is currently displayed. The struct default is
    /// `.history`, but `run()` overwrites it at startup from the configured
    /// landing view (`config.landingEnum()`, ROD-228) before the first frame —
    /// History remains the default when unset/unrecognized (§9.2).
    active_view: enum { browse, history, detail, settings, discover } = .history,
    /// Which top-level view opened the standalone detail screen.
    detail_origin: enum { browse, history, discover } = .browse,

    /// Which pane has keyboard focus within the current view.
    /// Meaningful in both Browse and History (two-pane at `w >= pane_split_min`,
    /// ROD-170): it drives the `h`/`l` pane toggle, the top-bar `·`, and the
    /// focus-aware selection step-down (ROD-194 — the list selection recedes when
    /// the detail pane has focus). Settings is single-pane and pins it to .list;
    /// History below pane_split_min is clamped to .list (single column).
    active_pane: enum { list, detail } = .list,

    /// Current input mode. `.search` = typing a query; `.normal` = list navigation.
    input_mode: enum { normal, search } = .normal,

    /// Catalogue-search controller (ROD-219): the query buffer, accumulated
    /// (owned) results, loaded-page count, in-flight flag, and queued enrich
    /// request. Transport — the worker threads below, `async_start_ms`, and the
    /// search debounce — stays on App; the controller owns only the record + its
    /// clear/hydrate/persist helpers. Embedded by value so `App{}` stays trivially
    /// constructible. See `SearchController`.
    search: SearchController = .{},

    /// Discover feed controller (ROD-239): the active ranking axis, the grid
    /// cursor/scroll, and the per-axis result cache. Transport (the feed worker
    /// thread, the slow-path timer) stays on App, like SearchController. Embedded
    /// by value so `App{}` stays trivially constructible. See `DiscoverState`.
    discover: DiscoverState = .{},

    /// GPA reference for freeing search results. Set in run() before the event loop.
    /// Intentionally not zero-initialised — only valid after run() sets it.
    gpa: Allocator = undefined,

    /// Handle for the most recent search thread. Joined in fireSearch before a new
    /// spawn, and in run() teardown. This bounds concurrent search threads to 1,
    /// preventing use-after-free of `loop` and `gpa` on fast quit.
    search_thread: ?std.Thread = null,

    /// Drain barrier for the Discover feed fetches (down from three worker kinds:
    /// the enrich passes died with the AniList cutover, ROD-336). Before ROD-251 the
    /// fetch's thread handle was joined ON the event thread before spawning its
    /// replacement, so cycling axes (1→2→3→4) on a slow link froze the UI on the prior
    /// join. Now every worker is detached and accounted here like `episode_drain`: a
    /// superseded fetch is never joined, its stale result lands in its own axis slot,
    /// and teardown waits the in-flight set out.
    discover_drain: workers.ThreadDrain = .{},

    /// Bounded Discover-grid cover worker fan-out (ROD-240). Each visible cover is
    /// fetched by its own detached `discoverCoverTask`; `pump` caps how many run at
    /// once at `config.discoverCoverConcurrency` by gating spawns on `inflight`. The
    /// drain's counter doubles as that live in-flight tally (read each frame to size
    /// the next top-up) and as the teardown barrier — `drain()` blocks until every
    /// worker's `finish()` ran, so nothing still references `loop`/`gpa`/`caches`
    /// when they're torn down (replaces ROD-243's single batch thread + active flag).
    discover_cover_drain: workers.ThreadDrain = .{},

    /// Sub/dub translation for searches.
    translation: domain.Translation = .sub,

    /// Drain barrier for episode-fetch workers (ROD-179). A superseded prefetch
    /// is detached, not joined, so the main loop never blocks on a stale fetch;
    /// this accounts for the in-flight set so teardown can wait them all out
    /// before loop/gpa/io die. The episode record/cache lives in `episodes`.
    episode_drain: workers.ThreadDrain = .{},
    /// ROD-182: drain barrier for refresh-on-view enrichment workers. Detached and
    /// accounted like `episode_drain` so teardown waits them out before loop/gpa/io
    /// die; a duplicate refresh (same show re-opened mid-flight) is never joined.
    enrich_refresh_drain: workers.ThreadDrain = .{},
    /// ROD-327: drain barrier for tier-A add-to-watchlist resolve workers. Detached and
    /// accounted like `episode_drain` so teardown waits them out before loop/gpa/io die;
    /// each probes a play provider then posts `.resolve_add_result`.
    add_resolve_drain: workers.ThreadDrain = .{},
    /// ROD-327: true while a tier-A add-resolve probe is in flight. Bounds Add to ONE probe
    /// at a time so a mashed/held P can't fan concurrent requests at the provider CDN (the
    /// ROD-309 rate-scoring trap). Set in `fireResolveAdd`, cleared in `.resolve_add_result`.
    add_resolving: bool = false,
    /// ROD-328: drain barrier for tier-C Play resolve workers (title-search the play
    /// provider for a Browse hit that could not tier-A). Detached + accounted like
    /// `episode_drain`; each posts `.resolve_play_target`. Distinct from the Add drain so a
    /// play-resolve and an add-resolve can be outstanding at once.
    play_resolve_drain: workers.ThreadDrain = .{},
    /// ROD-328: true while a tier-C Play resolve search is in flight. Bounds Play's tier-C
    /// fallback to ONE search at a time (same ROD-309 discipline as `add_resolving`). Set in
    /// `fireResolvePlaySearch`, cleared in `.resolve_play_target`.
    play_resolving: bool = false,
    /// ROD-346: the anilist_id the in-flight Play search was fired FOR. The
    /// `.resolve_play_target` handler drops a result that no longer matches, so a
    /// late search can't hijack the grid of a show the user has since opened
    /// (`fireEpisodesForId` has no keep-check of its own). Set beside
    /// `play_resolving`; cleared by the handler and by any user-driven fire.
    play_resolve_aid: ?i64 = null,
    /// ROD-351: drain barrier for the eager pre-warm walk. Detached + accounted
    /// like `episode_drain`; posts `.prewarm_result` per provider + `.prewarm_done`.
    prewarm_drain: workers.ThreadDrain = .{},
    /// ROD-351: true while a pre-warm walk is in flight. ONE walk at a time,
    /// app-wide (the walk itself is already sequential per ROD-309); cleared by
    /// `.prewarm_done`. Distinct from `add_resolving`/`play_resolving`: a
    /// background warm must never block a user-facing resolve, or vice versa.
    prewarm_active: bool = false,
    /// ROD-351: canonical ids a pre-warm already ran for this session. Stops an
    /// `unknown`-heavy walk (network flake, nothing persisted) from re-firing on
    /// every play of the same show. A fixed ring, not a map: allocation-free (an
    /// `App{}` stays trivially constructible, nothing to free) and eviction is
    /// harmless because the dedup is soft: a re-fire past the ring hits the
    /// store-backed candidate filter and no-ops. Optionals, not a 0 sentinel:
    /// nothing enforces anilist_id > 0, and an id equal to the sentinel would
    /// silently read as always-attempted.
    prewarm_attempted: [32]?i64 = @splat(null),
    prewarm_attempted_next: usize = 0,
    /// ROD-351: wall-clock of the last pre-warm walk START. Floors the spacing
    /// between walks app-wide: the per-show ring alone would let ring-eviction
    /// replay (33+ shows churned, then re-played) drip request bursts at a
    /// rate-scoring CDN (the ROD-309 class). A floored fire is NOT marked
    /// attempted, so the show retries on a later trigger.
    prewarm_last_start_ms: ?i64 = null,
    /// ROD-351: cooperative cancel for an in-flight pre-warm walk, checked by
    /// the worker between provider hops. Any advancing fallback walk sets it: a
    /// user fighting a broken provider must not compete with a background warm
    /// for the same CDN budget. Re-armed (false) on the next walk start.
    prewarm_cancel: std.atomic.Value(bool) = .init(false),
    /// Episode cache + detail-grid subsystem (ROD-180): the fetched episode list,
    /// the show it belongs to, the grid cursor + watched high-water mark, and the
    /// two-tier episode cache. Transport (episode_drain/async_start_ms) stays on
    /// App; the subsystem owns only the record + cache. Embedded by value so
    /// `App{}` stays trivially constructible. See `EpisodeState`.
    episodes: EpisodeState = .{},
    /// Cover/image subsystem — fetch policy, decoded-pixel + Kitty-image state,
    /// and the cover worker-thread lifecycle. See `CoverState` (ROD-160).
    cover: CoverState = .{},
    /// Shared, mutex-guarded cover caches (raw + decoded LRU). App-owned so both the
    /// single-cover path and the Discover grid fetch against the same URL-keyed
    /// caches under one lock (ROD-243). Freed in `deinitOwnedState` after the cover
    /// workers join.
    cover_caches: workers.CoverCaches = .{},
    /// Discover-grid multi-cover pool (ROD-243): URL-keyed slots, each owning its
    /// decoded pixels + Kitty image. Shares `cover_caches`; driven by `pump` and the
    /// `.discover_cover_*` handlers. Freed in `deinitOwnedState` after the workers join.
    discover_covers: DiscoverCovers = .{},
    /// Handle for the most recent play thread. Joined before a new spawn.
    play_thread: ?std.Thread = null,
    /// Whether mpv is running (play thread in-flight).
    playing: bool = false,
    /// Live mpv playback position from IPC.
    current_position: f64 = 0,
    /// Live mpv duration from IPC.
    current_duration: f64 = 0,
    /// mpv playback session record (ROD-162): the playing show/episode/source,
    /// the checkpoint mark, and the progress/watched-state persistence. Transport
    /// (playing/play_thread/current_*) stays on App; the session owns only the
    /// record. Embedded by value so `App{}` stays trivially constructible. See
    /// `PlaybackSession`.
    session: PlaybackSession = .{},
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
    /// Built-in version for the Settings "current version" inert row (ROD-370),
    /// formatted `v{version}` once in run() into `version_buf`. Slice into an
    /// App-owned buffer, so it outlives every frame.
    app_version: []const u8 = "",
    version_buf: [16]u8 = undefined,
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
    /// 16 bytes/slot (ROD-192): the glyph path "[▸XX]" = 1 + 3 (▸ is 3 UTF-8 bytes)
    /// + 2 + 1 = 7 bytes — the ▸ only fires for labels < 3 chars — and a plain
    /// "[1000a]" is 7; [16] leaves headroom. The prior [8] was tight and silently
    /// fell back to "[?]".
    ep_scratch: [512][16]u8 = undefined,
    /// Stable storage for the detail-pane score line.
    detail_score_buf: [32]u8 = undefined,
    /// Stable storage for the detail meta grammar (ROD-260). `detail_meta_buf`
    /// holds the formatted episode-count value; `detail_meta_fields` the ordered
    /// field list both renderers (drawMetaLine / drawMetaRail) read. vaxis cells
    /// hold slices into these, not copies, so both must outlive the frame — hence
    /// App-owned, like the season/score buffers below (the ROD-141 dangling-buffer
    /// lesson). Sized for the eventual field union (the AniList-enrichment
    /// follow-up adds studios/source/duration/rank between Format and the tail).
    detail_meta_buf: [32]u8 = undefined,
    /// Studios rail value (ROD-261), its own buffer so it can't collide with the
    /// episode-count value in `detail_meta_buf` when both fields emit. Holds the
    /// collapse-formatted `A, B +N` string; 64 bytes covers two studio names plus
    /// the overflow marker.
    detail_studios_buf: [64]u8 = undefined,
    /// Duration rail value (ROD-261), "N min" — its own buffer for the same
    /// reason: every emitted field needs a value slice that outlives the frame.
    detail_duration_buf: [16]u8 = undefined,
    /// Source rail value (ROD-261), the prettified adaptation source ("Light
    /// novel"). Own buffer, same frame-lifetime reason.
    detail_source_buf: [24]u8 = undefined,
    /// Rank rail value (ROD-261), rail-only "#N rated YYYY". Own buffer.
    detail_rank_buf: [24]u8 = undefined,
    /// Provider field value (ROD-348/356), "▸senshi +megaplay", both render
    /// forms. Budgeted for 4 providers of marker + ≤16-char name + separators
    /// (§5.3a); a registry past that needs this widened or the field degrades
    /// to omission.
    detail_provider_buf: [96]u8 = undefined,
    /// Airing-countdown chip value (ROD-261), "Ep14 · 3d" — its own frame-lived
    /// buffer alongside the season chip's `detail_season_buf`.
    detail_airing_buf: [24]u8 = undefined,
    detail_meta_fields: [8]MetaField = undefined,
    /// Stable storage for the "冬 2026" season chip (ROD-141). Must outlive the
    /// frame: vaxis cells hold a slice into this buffer, not a copy, so a stack
    /// local would dangle by `render()` and emit garbage.
    detail_season_buf: [16]u8 = undefined,
    /// Stable storage for the scope-tagged result count in drawBottomBar search
    /// mode — e.g. "[catalogue · 128]" / "[watchlist · 12]" (ROD-211). Sized for
    /// the longest tag + a multi-digit count ("·" is 2 UTF-8 bytes; the full
    /// " · " separator is 4 — [16] fell one byte short for "[catalogue · NN]").
    cnt_scratch: [32]u8 = undefined,
    /// Stable storage for the top-bar season/year chip text (e.g. "冬 2024",
    /// ROD-186). App-owned so vaxis holds a valid slice after drawTopBar returns
    /// (the ROD-141 cell-slice lifetime trap).
    chip_buf: [16]u8 = undefined,

    // ── async feedback (ROD-76) ───────────────────────────────────────────────
    /// Current Braille spinner frame index (0–9, wraps on .tick).
    spinner_frame: u8 = 0,
    /// Timestamp (ms) when the current async op started. 0 = nothing running.
    async_start_ms: i64 = 0,
    /// Deadline for search debounce (ms). 0 = no pending debounce.
    debounce_deadline_ms: i64 = 0,
    /// Deadline for the cover-preview settle debounce (ms). Armed when the list
    /// cursor moves in a context where the cover tracks the cursor (split browse /
    /// wide history); fired in .tick. Stops a fast j/k scroll from fetching — and
    /// blocking the UI thread on the cover joinThread for — every row's art it
    /// scrolls past (ROD-202). 0 = no pending settle.
    cover_sync_deadline_ms: i64 = 0,

    // ── action-triggered AniList push (ROD-291) ───────────────────────────────
    /// The loaded AniList token, resolved once at boot in run() into a session-lived
    /// arena. Passed by value to each background flush; a mid-session expiry just
    /// makes `pushAll` return its no-op `.expired` arm (the reconnect nudge is ROD-295).
    anilist_auth: auth_mod.Auth = .{},
    /// Cached at boot: `hasAniList() and !isExpired`. The single gate `armSyncFlush`
    /// checks — with no usable token, arming is a no-op and the push machinery never
    /// spins. Deliberately a boot snapshot; ROD-295 owns re-evaluating it on expiry.
    anilist_connected: bool = false,
    /// Debounce deadline (ms) for the background push, mirroring
    /// `cover_sync_deadline_ms`. A local mutation to a linked row arms it; a binge of
    /// episode-marks coalesces into one flush. Serviced in .tick. 0 = nothing pending.
    sync_flush_deadline_ms: i64 = 0,
    /// One sync at a time. Set true when a `syncFlushTask` is spawned; cleared ONLY by
    /// the worker's own teardown defer (`inflight.store(false)`), which runs on every
    /// exit path — so a dropped `postEvent` can't latch it on. The `.sync_flushed`
    /// handler does NOT clear it. A deadline that fires while this holds re-arms instead
    /// of stacking a second flush onto the same dirty set. Shared with the ROD-293
    /// launch pull, which reuses this exact gate so the launch refresh and the first
    /// action flush can never run two syncs against the store at once.
    sync_flush_inflight: std.atomic.Value(bool) = .init(false),
    /// Handle for the in-flight sync thread (action flush or ROD-293 launch pull — only
    /// ever one, per the gate above); joined before spawning the next, and on the
    /// error-unwind / test teardown path. The ordinary quit path (`_exit(0)`, ROD-232)
    /// skips that join and abandons the thread — safe and self-healing (see the join
    /// defer in run()).
    sync_thread: ?std.Thread = null,

    // ── in-TUI connect modal (ROD-286) ────────────────────────────────────────
    /// Non-null while the AniList connect modal is live (see `ConnectState`).
    /// Cleared by `teardownConnect` — from the event drain on a settled outcome,
    /// from esc-cancel, or from run() teardown on the error-unwind/test path.
    connect: ?ConnectState = null,
    /// Session-lived homes for tokens RELOADED after in-session connects. Boot's token
    /// lives in run()'s auth arena; a fresh connect persists auth.zon and reloads it into
    /// a new boxed arena here so `anilist_auth`'s slices outlive the short-lived connect
    /// arena.
    ///
    /// A LIST, not a single slot, and never freed mid-session (ROD-286): `spawnSyncWorker`
    /// hands `anilist_auth` to a flush worker BY VALUE, slices and all, and a paced push
    /// holds them for many seconds. A second connect must NOT free the arena a running
    /// flush is reading its token from, so each reconnect RETIRES the prior arena rather
    /// than freeing it (`anilist_auth` always points into the last entry). All are freed
    /// together in `deinitOwnedState`, which runs LAST (LIFO, after every sync-worker
    /// join), so no flush can outlive its token.
    auth_reload_arenas: std.ArrayListUnmanaged(*std.heap.ArenaAllocator) = .empty,

    /// Last-seen terminal width (columns). Seeded in layout() every frame from
    /// real geometry so onKey/tick can gate split-browse and wide-history
    /// behaviour without being passed the winsize event.
    term_cols: u16 = 0,
    /// Last-seen terminal height (rows). Seeded in layout() alongside term_cols so
    /// the Discover cover `pump` (run from run(), not layout) can resolve the grid
    /// geometry from the last settled frame (ROD-243).
    term_rows: u16 = 0,
    /// Last-seen terminal size in PIXELS, cached at each vaxis resize (run() owns
    /// resize). 0 when the terminal doesn't report pixel metrics (tmux/headless).
    /// Divided by term_cols/term_rows to get the cell aspect, which sizes the
    /// Discover covers so a poster fills its width instead of pillarboxing (ROD-247).
    term_x_pixel: u16 = 0,
    term_y_pixel: u16 = 0,
    /// Last tick timestamp (ms). Updated on every .tick event; used by draw functions.
    now_ms: i64 = 0,
    /// Toast queue (oldest first). null = empty slot.
    toast_queue: [3]?Toast = .{ null, null, null },

    /// Single-level undo slot for manual watch-state mutations (ROD-193 §B).
    /// Non-null while there is an undoable action. Freed in `deinitOwnedState`.
    undo: ?UndoEntry = null,

    /// GPA-owned display string for the Settings "cover art cache" inert row:
    /// the real `<cacheDir>/covers` path (honours `$XDG_CACHE_HOME`), with the
    /// `$HOME` prefix collapsed to `~`. Resolved once in `run()`; null when no
    /// cache home resolves, in which case the row falls back to a literal. vaxis
    /// holds the printed slice by reference until render, so this must be
    /// App-owned, not a draw-local stack buffer (ROD-225). Freed in
    /// `deinitOwnedState`.
    cover_cache_display: ?[]const u8 = null,

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

    /// §2.2 score-tier colour. Canonical mapping shared by the detail pane
    /// (`drawScore`) and the Browse list-row meta (ROD-226) so the two surfaces
    /// can never drift. Only the tier→style mapping lives here; the `[NN/100]`
    /// text and the detail-only `✦` prefix stay per-surface. `bg` threads the
    /// row background (null → the palette default, via `s`).
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

    /// §3.6: has the current async op outlived the slow-path threshold? Drives
    /// the cyan → hot spinner shift in both the bottom bar and the cover block.
    pub fn isSlowPath(self: *const App) bool {
        return self.async_start_ms > 0 and
            self.now_ms - self.async_start_ms > slow_path_threshold_ms;
    }

    pub fn pushToast(self: *App, kind: Toast.Kind, text: []const u8, persistent: bool) void {
        self.pushToastTopic(kind, text, persistent, .general);
    }

    /// Like `pushToast`, but tags the recovery scope (ROD-239): a persistent error
    /// is cleared only by its own subsystem's recovery (feed success clears feed
    /// errors; search success clears general errors), never cross-view.
    fn pushToastTopic(self: *App, kind: Toast.Kind, text: []const u8, persistent: bool, topic: Toast.Topic) void {
        const cap = self.toast_queue.len;

        // Persistent toasts are a per-topic SINGLETON (ROD-293): refresh an existing
        // same-topic persistent slot in place rather than appending a duplicate. Without
        // this, repeated failures (typing offline, cycling Discover offline) stack
        // duplicate persistent toasts until all three slots are persistent, and the
        // evict-oldest-non-persistent policy below then has no slot to take, starving
        // every later toast including transient successes. With it, persistent occupancy
        // is capped at the two persistent topics (.general, .feed), so a free slot for
        // transients always exists and the all-persistent branch is unreachable.
        if (persistent) {
            for (&self.toast_queue) |*slot| {
                if (slot.*) |existing| {
                    if (existing.persistent and existing.topic == topic) {
                        slot.* = makeToast(kind, text, persistent, topic);
                        return;
                    }
                }
            }
        }

        var idx: usize = cap; // sentinel: no free slot yet
        for (self.toast_queue, 0..) |slot, i| {
            if (slot == null) {
                idx = i;
                break;
            }
        }
        if (idx == cap) {
            // Queue full: evict the OLDEST NON-persistent toast so a still-showing
            // persistent error is never shifted out for a transient whisper (ROD-293
            // chaos review: a two-way sync flush pushes TWO toasts at once, ↓ then ↑,
            // and the old blind evict-slot-0 dropped a persistent banner). The per-topic
            // singleton above guarantees a non-persistent slot exists; the all-persistent
            // fallback is defensive only, logging and evicting the oldest so new info
            // still lands rather than silently starving.
            var victim: usize = 0;
            const found = for (self.toast_queue, 0..) |slot, i| {
                if (slot) |t| {
                    if (!t.persistent) break i;
                }
            } else null;
            if (found) |v| {
                victim = v;
            } else {
                log.debug("toast: queue all-persistent, evicting oldest (unexpected — the per-topic singleton should prevent this)", .{});
            }
            // Compact left over the victim, opening the last slot for the newcomer
            // while preserving the oldest→newest order the TTL sweep and this evict
            // both assume.
            var j = victim;
            while (j + 1 < cap) : (j += 1) self.toast_queue[j] = self.toast_queue[j + 1];
            idx = cap - 1;
        }
        self.toast_queue[idx] = makeToast(kind, text, persistent, topic);
    }

    /// Build one `Toast`, capping the copy to the §4.7 36-column budget at this single
    /// choke point so a long dynamic payload (task_error's `@errorName`) gets a "…"
    /// affordance instead of being silently sheared by the render clip (ROD-166). The
    /// [80]u8 text buffer is copied out by value on return — nothing aliases the local.
    /// 4000ms TTL (not 2500): a state-change toast (e.g. "episode N done") is posted the
    /// instant mpv exits, but on a tiling WM focus is still returning from mpv's window,
    /// eating the first ~1s; matches the `Toast.ttl_ms` struct default.
    fn makeToast(kind: Toast.Kind, text: []const u8, persistent: bool, topic: Toast.Topic) Toast {
        var t: Toast = .{ .kind = kind, .persistent = persistent, .ttl_ms = if (persistent) 0 else 4000, .topic = topic };
        const copy = render.truncateToWidth(&t.text, text, Toast.max_copy_cols);
        t.text_len = copy.len;
        return t;
    }

    /// Unified teardown for app-owned runtime state. Thread joins live in
    /// run() and must execute before this cleanup touches anything workers can
    /// still reference.
    pub fn deinitOwnedState(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer) void {
        self.clearFallback();
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
        // ROD-286: every token reloaded after an in-session connect lives in its own
        // boxed arena, retired (never freed mid-session — C1) rather than on the next
        // reconnect. deinitOwnedState runs LAST (LIFO), after every sync-worker join, so
        // a flush handed `anilist_auth`'s slices can never outlive them.
        self.freeAuthReloadArenas();
    }

    /// Free every retired reload arena (C1, ROD-286). Split from `deinitOwnedState` so
    /// the retirement invariant is testable without constructing a vaxis/writer. pub for
    /// the app_test regression around `adoptReloadedAuth`.
    pub fn freeAuthReloadArenas(self: *App) void {
        for (self.auth_reload_arenas.items) |box| {
            box.deinit();
            self.gpa.destroy(box);
        }
        self.auth_reload_arenas.deinit(self.gpa);
    }

    /// Patch `EpisodeState.progress` (and re-seed the cursor) when the detail pane
    /// is currently bound to this exact show (ROD-193 §D two-progress-field sync).
    /// Matches on the full (source, source_id) pair, so two providers that ever
    /// share a source_id can't cross-patch. Conservative: if the pane isn't
    /// confirmably on this show, leave it alone rather than corrupting unrelated
    /// episode state.
    pub fn syncEpisodeProgress(self: *App, source: []const u8, source_id: []const u8, new_progress: i64) void {
        const bound_id = self.episodes.for_id orelse return;
        const bound_source = self.episodes.for_source orelse return;
        if (!std.mem.eql(u8, bound_id, source_id)) return;
        if (!std.mem.eql(u8, bound_source, source)) return;
        const clamped: u32 = if (new_progress > 0) std.math.cast(u32, new_progress) orelse std.math.maxInt(u32) else 0;
        self.episodes.progress = clamped;
        // Re-seed through the shared resumeSeed so a mid-episode checkpoint keeps
        // the cursor ON the in-progress episode (ROD-355). Only move when results
        // are loaded; else the next open re-seeds.
        if (self.episodes.results) |eps| {
            if (EpisodeState.resumeSeed(self.store, self.translation, source, source_id, @intCast(clamped), eps)) |idx| {
                self.episodes.cursor = idx;
                self.episodes.resume_idx = idx;
            } else {
                // Nothing watched (0) or fully caught up: park cursor, no resume.
                self.episodes.cursor = 0;
                self.episodes.resume_idx = null;
            }
        }
    }

    /// Raise the landed binding's progress through the canonical union and patch
    /// the open grid (ROD-352, generalizing ROD-346's walk-landing raise to every
    /// grid landing). A plain open of a multi-binding show seeds dimming from the
    /// landed binding's own progress column, which can lag the union until
    /// afterPlay recomputes: the grid under-dims and sync is handed the lower
    /// number (the ROD-323 shape). Raise-only, so landing on a force-completed
    /// sibling can't un-complete it. Deliberate cost: one extra write per grid
    /// landing, moving the union catch-up from play-time to view-time.
    fn raiseLandingProgress(self: *App, source: []const u8, source_id: []const u8) void {
        const st = self.store orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const hw = st.raiseProgressToUnion(arena.allocator(), source, source_id, self.translation) catch |e| {
            log.debug("landing raise failed: {s}", .{@errorName(e)});
            return;
        };
        if (hw > 0) self.syncEpisodeProgress(source, source_id, hw);
    }

    /// Store `entry` in the single-level undo slot (ROD-193 §B). If a prior entry
    /// exists, free it first so we never leak GPA memory at depth > 1.
    fn pushUndo(self: *App, entry: UndoEntry) void {
        if (self.undo) |old| old.free(self.gpa);
        self.undo = entry;
    }

    /// Pop the undo slot and revert the last watch-state mutation (ROD-193 §B).
    /// Looks up the record by (source, source_id) via `history.indexById`; if not
    /// found (rare: history reloaded between the mutation and `u`), just frees and
    /// returns silently. Syncs EpisodeState progress when the detail pane is bound
    /// to the same show (the two-progress-field sync, ROD-193 §D).
    pub fn applyUndo(self: *App) void {
        const entry = self.undo orelse return;
        self.undo = null; // clear slot before any early-return so we always free

        switch (entry) {
            .set_list_status => |e| {
                defer entry.free(self.gpa);

                const st = self.store orelse return;
                const idx = history.indexById(self, e.source, e.source_id) orelse return;
                const rec = &self.history[idx];

                // Restore the EXACT captured pair — restoreListStatus writes
                // progress verbatim, so undoing a force-complete doesn't leave the
                // store's progress snapped to the finale while memory reverts (the
                // divergence the app_test caught, ROD-193).
                st.restoreListStatus(e.source, e.source_id, e.prev_status, e.prev_progress) catch |err| {
                    log.debug("applyUndo: restoreListStatus failed: {s}", .{@errorName(err)});
                    return;
                };

                rec.list_status = e.prev_status;
                rec.progress = e.prev_progress;

                // Sync EpisodeState when the detail pane is bound to this show.
                syncEpisodeProgress(self, e.source, e.source_id, e.prev_progress);

                // ROD-291: an undo restores a prior pair — itself a mutation AniList
                // must learn about (the restored value may differ from what we last
                // pushed), so schedule a push like any other local change.
                self.armSyncFlush();

                self.pushToast(.info, "undone", false);
            },
        }
    }

    /// The focused record, in the History view's §5.4 grouped order. Delegates to
    /// the renderer's walk so the highlighted row and the focused record share one
    /// ordering definition (ROD-139).
    pub fn selectedHistoryRecord(self: *const App) ?AnimeRecord {
        return history.recordAtCursor(self);
    }

    pub fn cellPx(self: *const App) [2]u16 {
        return selection.cellPx(self);
    }

    pub fn topBarSeasonChip(self: *App) []const u8 {
        return selection.topBarSeasonChip(self);
    }

    pub fn isNewRelease(self: *const App, a: Anime) bool {
        return selection.isNewRelease(self, a);
    }

    /// Apply a manual watch-state transition to the focused History entry
    /// (ROD-139 §1 — the p/x/c/w keybinds). Persists through the store, then
    /// mutates the in-memory record so the grouped view regroups it on the next
    /// draw — no full reload. On a store error the in-memory state is left
    /// untouched so the two never diverge. No-op if nothing is focused.
    ///
    /// Instruments single-level undo (ROD-193 §B): captures prev_status +
    /// prev_progress before the store write; pushes the entry only on success.
    /// All four keys (p/x/c/w) are undoable — this is the shared path for all.
    pub fn setSelectedHistoryStatus(self: *App, status: domain.ListStatus) void {
        const st = self.store orelse return;
        const idx = history.indexAtCursor(self) orelse return;
        const rec = &self.history[idx];

        // Capture prev state for undo BEFORE the store write.
        const prev_status = rec.list_status;
        const prev_progress = rec.progress;
        // GPA-dupe the key strings now; free them if the store write fails.
        const src_copy = self.gpa.dupe(u8, rec.source) catch null;
        const sid_copy = self.gpa.dupe(u8, rec.source_id) catch null;

        st.setListStatus(rec.source, rec.source_id, status) catch |e| {
            log.debug("setListStatus failed: {s}", .{@errorName(e)});
            if (src_copy) |buf| self.gpa.free(buf);
            if (sid_copy) |buf| self.gpa.free(buf);
            return;
        };

        // Store write succeeded — push the undo entry only if BOTH key copies
        // exist; otherwise free whichever did allocate (OOM just makes the mutation
        // non-undoable). The old code leaked sid_copy when only the first dupe
        // failed (ROD-193 review).
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
        // Mirror the store's force-complete progress snap: a real total fills the
        // bar; unknown/0 leaves progress as-is (same guard as Store.setListStatus).
        // We deliberately do NOT mirror history_visible=1 that the store sets — every
        // record in self.history is already visible (loadHistory filters on it), so
        // there's nothing to flip. And w/x/p (incl. `w` on a completed show) leave
        // progress untouched by design: re-watching keeps the full bar until a play
        // moves the high-water — matching Store.setListStatus exactly.
        if (status == .completed) {
            if (rec.total_episodes) |t| {
                if (t > 0) rec.progress = t;
            }
        }

        // ROD-291: the status key (p/x/c/w) moved this row's pair; schedule a push.
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

    /// Controller glue for the playback-event handlers (ROD-162): hand the final
    /// state to the session for persistence + clear, then reset the App-owned
    /// transport. The session owns the record; the shell owns playing/current_*.
    /// Whether the final observed position counts the episode as watched — the
    /// store's NATURAL_END_RATIO completion bar (ROD-168). One coherent signal
    /// for both play_done and play_error: a clean mpv quit is no longer treated
    /// as a watch (you can quit at any second), and the bar matches the store's
    /// resume "done" notion so the progress high-water mark, the §4.6 dim, and
    /// the cursor advance never disagree.
    fn watchCompleted(final_update: ?event_mod.PositionUpdate) bool {
        const u = final_update orelse return false;
        return u.reachedCompletion(store_mod.NATURAL_END_RATIO);
    }

    /// The §4.7 toast line for a play/episode failure cause, formatted into `buf`, or
    /// null when `cause` isn't one we differentiate (the caller supplies its own generic
    /// fallback). Two families: source classes (ROD-173; the source-named ones
    /// interpolate `provider.displayName()`, never a hardcoded site name) and
    /// player-spawn classes (ROD-230, about the local mpv binary, so static). The
    /// player-spawn arms only fire on the play path; `episodes_error` shares this mapper
    /// but never spawns mpv, so a third caller must not assume those arms apply. These
    /// phrasings pair with DESIGN.md §4.10 and move together. A short source name keeps
    /// the copy within the §4.7 36-col budget; a long one is truncated by pushToast
    /// (ROD-166), and an overflow of `buf` falls through to the generic line via `catch
    /// null`, as do data-shape errors (NoEpisodeData, NoDirectStream).
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

    /// The sync rail's master gate: a usable token (`anilist_connected`) AND the user
    /// hasn't paused sync (the ROD-286 `anilist_sync_enabled` toggle). Every arm/fire
    /// reads this, so flipping the toggle off makes the whole rail inert (no arm, flush,
    /// launch pull, or connect bootstrap) without touching the token.
    fn syncEnabled(self: *const App) bool {
        return self.anilist_connected and self.config.anilist_sync_enabled;
    }

    /// Arm the debounced AniList sync (ROD-291) at a local mutation that can move a linked
    /// row's (list_status, progress): a finished episode, a status key, an undo. Only sets
    /// the deadline; .tick fires the off-thread flush once it elapses, coalescing a burst
    /// into one. Uses the last-tick `now_ms` (a ≤100ms-stale stamp is immaterial against a
    /// 3s settle) so no call site needs an `io` param.
    fn armSyncFlush(self: *App) void {
        if (!self.syncEnabled()) return;
        self.sync_flush_deadline_ms = self.now_ms + App.sync_flush_settle_ms;
    }

    /// Fire the debounced flush (ROD-291): spawn `syncFlushTask` (pull-then-push, off the
    /// render thread) when `sync_flush_deadline_ms` elapses. Both engines are total, so
    /// this just kicks a worker; a dropped run self-heals (rows stay dirty for the next
    /// arm/launch). One at a time: if a flush is still running, re-arm rather than stack a
    /// second on the same dirty set.
    ///
    /// Tested-debt: the body short-circuits under `builtin.is_test` (it spawns a real
    /// network thread), so the inflight gate, reap-before-spawn, and spawn-failure
    /// recovery are exercised only by hand. Accepted: the tested logic is in the pure
    /// engines (`sync.zig`'s `reconcile` + `Effects` seam); this is thin orchestration
    /// around a thread spawn with no unit-testable seam worth the contortion.
    fn fireSyncFlush(self: *App, loop: *Loop, io: std.Io) void {
        if (builtin.is_test) return; // don't spawn a real network flush under test
        const st = self.store orelse return;
        if (!self.syncEnabled()) return;
        if (self.sync_flush_inflight.load(.acquire)) {
            // Still flushing — retry shortly after it finishes; rows stay dirty.
            self.sync_flush_deadline_ms = nowMs(io) + App.sync_flush_settle_ms;
            return;
        }
        // Reap the previous (now-finished, since inflight is clear) handle before
        // spawning the next, matching the search/enrich single-handle discipline.
        if (self.sync_thread) |t| {
            t.join();
            self.sync_thread = null;
        }
        self.spawnSyncWorker(loop, io, st, false); // pull-then-push
    }

    /// Background pull-on-launch (ROD-293): one `MediaListCollection` round trip at
    /// startup so local reflects edits made on other devices since last run. Pull-ONLY;
    /// the paced push belongs to the action flush (ROD-291) and quit flush (ROD-294).
    /// Shares the one-at-a-time gate and thread handle with the action flush (guard
    /// uniformly so it can never stack a second sync). Ambient: a reconciled remote change
    /// flags a history reload and whispers `↓ N from AniList` (no ↑ line). Called once
    /// from run(); the `is_test` guard matches `fireSyncFlush`.
    fn fireLaunchPull(self: *App, loop: *Loop, io: std.Io) void {
        if (builtin.is_test) return; // don't spawn a real network pull under test
        const st = self.store orelse return;
        if (!self.syncEnabled()) return;
        if (self.sync_flush_inflight.load(.acquire)) return; // never stack two syncs
        if (self.sync_thread) |t| {
            t.join();
            self.sync_thread = null;
        }
        self.spawnSyncWorker(loop, io, st, true); // pull-only
    }

    /// Spawn the shared AniList sync worker (ROD-291/293), storing the joinable handle
    /// and raising the one-flush gate; a spawn failure clears the gate so the coordinator
    /// isn't latched off. `pull_only` picks the mode: false = the action flush's
    /// pull-then-push, true = the launch pull-refresh. The caller has already checked the
    /// gate is clear and reaped any prior handle.
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

    /// ROD-294: bounded best-effort push on quit — the mirror of `fireLaunchPull` at the
    /// far end of the session. Called once from run()'s fast-exit path, after the terminal
    /// is restored and before `_exit`. Skips when disconnected, and when ANY sync worker is
    /// inflight: the quit push must never run alongside a pull. Both the action flush and
    /// the ROD-293 launch pull are pull-THEN-push, and pushing concurrently with an
    /// inflight pull would race its snapshot writes and could POST stale, pre-reconcile
    /// progress to AniList (a silent cross-device downgrade) — the exact ordering ROD-285's
    /// pull-then-push discipline exists to hold. Accepted residual: the launch pull holds
    /// this gate for the first ~10 s of every connected session, so a launch-then-quit
    /// inside that window drops the quit push — those rows are NOT lost, they re-flush on
    /// any later action (which arms an action flush) or on a quit taken after the pull
    /// settles. Orchestration around a real network call, so no unit-testable seam (like
    /// `fireSyncFlush`); the push engine (`sync.pushAll`, incl. the partial-progress safety
    /// net) is covered in sync.zig.
    fn quitFlush(self: *App, io: std.Io) void {
        if (builtin.is_test) return; // real network; no unit-test path (see fireSyncFlush)
        const st = self.store orelse return;
        if (!self.syncEnabled()) return;
        if (self.sync_flush_inflight.load(.acquire)) return; // never push alongside an inflight pull
        workers.pushOnQuit(self.gpa, io, st, self.anilist_auth, Store.nowSecs(), App.quit_push_deadline_ms);
    }

    // ── in-TUI connect modal (ROD-286) ────────────────────────────────────────

    /// Kick off the in-TUI AniList connect. Binds the loopback listener on THIS
    /// (render) thread — so a bind failure is an immediate toast, not a half-open
    /// modal — opens the browser, spawns the accept-loop worker, and raises the modal.
    /// A second trigger while a modal is up is ignored (guarded on `connect == null`,
    /// and a busy port would fail the bind anyway). Errors collapse to one short toast.
    pub fn beginConnect(self: *App, loop: *Loop, io: std.Io) void {
        // Like the sync spawns, a no-op under test: it binds a real port and spawns a
        // worker, neither of which a unit test can have. The connect-row wiring is
        // tested at the subsystem seam (SettingsState returns `.connect_requested`).
        if (builtin.is_test) return;
        if (self.connect != null) return; // one modal at a time
        self.connect = self.startConnect(loop, io) catch |e| {
            // Point the user at the terminal-safe fallback, not a dead end — a busy port
            // or a spawn failure both leave `zigoku login --paste` as the way through.
            const msg = switch (e) {
                error.LoopbackUnavailable => "port busy: zigoku login --paste",
                else => "can't start: zigoku login --paste",
            };
            self.pushToast(.@"error", msg, false);
            log.debug("connect start failed: {s}", .{@errorName(e)});
            return;
        };
    }

    /// The fallible half of `beginConnect`: allocate the boxed connect arena, bind the
    /// listener, open the browser, and spawn the worker — with `errdefer` unwinding
    /// each step (close the socket, free the arena) on any later failure, so a failed
    /// start never leaks a socket or half-initializes `connect`.
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
        errdefer listener.server.deinit(io); // close the bound socket if a later step fails

        const cancel = try a.create(std.atomic.Value(bool));
        cancel.* = .init(false);

        // Best-effort browser launch; the URL is rendered in the modal for manual open.
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

    /// Tear down the connect modal: wake + join the worker, close the listener, free
    /// the arena, clear the slot. Safe whether the worker already returned (event
    /// drain — a plain join reaps it) or is still blocked in `accept` (esc-cancel /
    /// run() teardown — the cancel flag + self-connect wake unblock it, and the worker
    /// skips its `postEvent` on `.canceled`, so the join can't stall on a full queue).
    /// No-op when no modal is up.
    fn teardownConnect(self: *App, io: std.Io) void {
        if (self.connect == null) return;
        const cs = &self.connect.?;
        cs.cancel.store(true, .release);
        login_loopback.requestCancel(io); // wake a blocked accept so the join can't hang
        if (cs.thread) |t| t.join();
        cs.listener.server.deinit(io); // close the listen socket (arena won't — it's an fd)
        cs.arena.deinit();
        self.gpa.destroy(cs.arena);
        self.connect = null;
    }

    /// esc from the modal: tear it down and whisper that the attempt was dropped.
    fn cancelConnect(self: *App, io: std.Io) void {
        self.teardownConnect(io);
        self.pushToast(.info, "sign-in canceled", false);
    }

    /// Keys while the connect modal is up. esc cancels; `c` requests an OSC-52 copy of
    /// the auth URL (serviced in `draw`, which owns the tty). Every other key is
    /// swallowed so a stray F-key can't switch views mid-connect. Ctrl-C (emergency
    /// quit) is handled by `onKey` before this ever runs.
    pub fn onConnectKey(self: *App, key: vaxis.Key, io: std.Io) void {
        if (key.matches(vaxis.Key.escape, .{})) {
            self.cancelConnect(io);
            return;
        }
        if (key.matches('c', .{})) {
            if (self.connect) |*cs| cs.copy_requested = true;
            return;
        }
        // everything else: swallowed (modal captures input)
    }

    /// Drain a settled connect attempt. Close the modal, then react to the POD outcome.
    /// On `.ok` the worker already persisted auth.zon: reload identity into a
    /// session-lived arena, mark connected, toast, and kick a pull-then-push bootstrap
    /// (the in-app twin of the CLI login bootstrap, ROD-292). Failure arms close with a
    /// short toast; `.canceled` never reaches here (the worker skips its post on cancel).
    fn onConnectResult(self: *App, outcome: login_loopback.ConnectOutcome, loop: *Loop, io: std.Io) void {
        // A racing esc may already have torn the modal down; the worker's event still
        // lands. teardownConnect is a no-op then — but a persisted token still deserves
        // to be adopted, so we apply the outcome regardless.
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
                    // Persisted but not usable (e.g. saved already-expired) — say so
                    // rather than a silent no-op.
                    self.pushToast(.warn, "connected, token unusable", false);
                }
            },
            .no_token => self.pushToast(.@"error", "sign-in: no token returned", false),
            .rejected => self.pushToast(.@"error", "sign-in rejected by AniList", false),
            .verify_failed => self.pushToast(.@"error", "sign-in: couldn't verify", false),
            .save_failed => self.pushToast(.@"error", "sign-in: couldn't save token", false),
            .accept_failed => self.pushToast(.@"error", "sign-in: listener failed", false),
            .canceled => {}, // esc path already toasted + cleared
        }
    }

    /// Reload auth.zon into a fresh session-lived arena after an in-session connect, so
    /// `anilist_auth`'s slices survive the connect arena's teardown, and adopt it as the
    /// live token. On failure (no config dir / OOM) `anilist_connected` is left as it
    /// was, which the caller surfaces as "connected, token unusable".
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
            // Couldn't track the arena → it would leak at exit; drop this reload rather
            // than the arena. `anilist_auth` keeps pointing at the prior (still-tracked)
            // token, so the connect just reads as "token unusable" this session.
            box.deinit();
            self.gpa.destroy(box);
        };
    }

    /// Adopt `reloaded` (whose string slices live in `box`) as the live token: RETIRE
    /// `box` into `auth_reload_arenas` (never freed mid-session — C1) and repoint
    /// `anilist_auth`/`anilist_connected`. Split out so the retirement invariant is
    /// unit-testable without a live OAuth round trip. Only fails if the list append OOMs
    /// — the caller then frees `box` itself (it isn't yet tracked here).
    pub fn adoptReloadedAuth(self: *App, box: *std.heap.ArenaAllocator, reloaded: auth_mod.Auth) !void {
        try self.auth_reload_arenas.append(self.gpa, box);
        self.anilist_auth = reloaded;
        self.anilist_connected = reloaded.hasAniList() and !reloaded.anilist.isExpired(Store.nowSecs());
    }

    /// One-shot pull-then-push right after an in-session connect — the in-app twin of
    /// the CLI login bootstrap (ROD-292). Reuses the shared sync worker + one-flush
    /// gate; a no-op under the master switch/disconnected, or with a flush already live
    /// (a launch pull / action flush), in which case a later mutation re-arms it.
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
        // Capture the session facts ROD-131 needs *before* finish() clears them:
        // the played episode (1-based) and whether the detail pane still shows
        // that show. `session.finish` calls `clear`, which zeroes both.
        const played_index = self.session.episode_index;
        const same_show = self.episodes.for_id != null and self.session.anime_id.len > 0 and
            std.mem.eql(u8, self.session.anime_id, self.episodes.for_id.?);

        // ROD-191: a *meaningful* final position is what writes/moves a history row
        // (and can promote a hidden row into the watchlist). This is a superset of
        // session.finish's recordPlay gate (which also requires anime_id/episode_raw
        // set, and episode_index > 0) — so we may occasionally over-reload, but we
        // never miss a written row. The in-memory `history` slice has no record for a
        // brand-new show, so mark it dirty; run() reloads at a safe seam. A trivial
        // quit (no meaningful position) recorded nothing → no reload.
        if (final_update) |u| {
            if (u.isMeaningful()) {
                self.history_dirty = true;
                // ROD-291: a meaningful finish moved this row's progress (session.finish's
                // recordPlay); schedule a debounced push. The isMeaningful gate is a
                // superset of finish's recordPlay gate, so this can't miss a written row.
                self.armSyncFlush();
            }
        }

        self.session.finish(self.gpa, self.store, final_update, completed);
        self.playing = false;
        self.current_position = 0;
        self.current_duration = 0;
        self.async_start_ms = 0;

        // Reflect a *completed* watch in the detail pane (ROD-131 / ROD-168):
        // advance + dim only when the watch cleared NATURAL_END_RATIO, matching
        // the progress high-water mark the store records. A partial watch is
        // still in history (session.finish touches it) but must not advance N.
        if (completed and played_index > 0 and same_show) self.advanceAfterWatch(played_index);
    }

    /// Project a counted watch of 1-based `played_index` onto the detail pane:
    /// bump the watched high-water mark, advance the cursor to the next episode
    /// if one exists, and toast the outcome (ROD-131). The caller guarantees the
    /// detail pane still shows the played show.
    fn advanceAfterWatch(self: *App, played_index: u32) void {
        // Bail before touching anything if the grid isn't loaded (a contrived
        // navigate-away-and-back-mid-play case): `episodes_done` re-seeds
        // `episodes.progress` from the store, so a bump here would be dropped.
        const eps = self.episodes.results orelse return;
        self.episodes.progress = @max(self.episodes.progress, played_index);
        // played_index is 1-based, so the next episode is at 0-based index
        // played_index. When that is past the end, N was the finale.
        const next: usize = played_index;
        if (next < eps.len) {
            self.episodes.cursor = next;
            // ROD-192: the ▸ resume marker advances in-session to the next
            // episode, tracking the high-water bump above.
            self.episodes.resume_idx = next;
            var buf: [32]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "episode {d} done", .{played_index}) catch "episode done";
            self.pushToast(.success, msg, false);
        } else {
            // Finale: deliberately leave the cursor where it is (on the last
            // cell the user played from) — there is no N+1 to move to. Caught up,
            // so there is nothing to resume (ROD-192).
            self.episodes.resume_idx = null;
            self.pushToast(.success, "all caught up", false);
        }
    }

    pub fn setHistory(self: *App, recs: []AnimeRecord) void {
        self.history = recs;
        self.history_loading = false;
        // ROD-234: a successful (re)load clears any prior history-load banner, so a
        // transient failure can never latch History as "unavailable" for the session.
        self.load_error = null;
        // Clamp against filtered len so an active filter can't leave the cursor
        // pointing past the visible range when history reloads.
        const cap = self.filteredHistoryLen();
        if (self.list_cursor >= cap) self.list_cursor = if (cap == 0) 0 else cap - 1;
    }

    // ── tick: fold one event into state ──────────────────────────────────────
    pub fn tick(self: *App, event: Event, loop: *Loop, io: std.Io, registry: Registry) !void {
        // Snapshot the cursor so the post-dispatch cover sync can tell a cursor
        // move (debounce) from discrete nav (sync now) — ROD-202.
        const cursor_before = self.list_cursor;
        switch (event) {
            .key_press => |key| input.onKey(self, key, loop, io, registry),
            .winsize => |ws| {
                // Screen resize is handled in run()'s loop (it owns vx), but the
                // app still normalizes browse layout state here so draw remains pure.
                // term_cols is seeded in layout(), which run() calls right after
                // this every frame, so it stays correct without a write here.
                // ROD-170: below the two-pane threshold there is no detail pane to
                // focus in either list view — clamp focus back to the list so a
                // stale .detail focus can't strand input on a pane that isn't drawn.
                if (ws.cols < pane_split_min and
                    (self.active_view == .browse or self.active_view == .history))
                    self.active_pane = .list;
            },
            .focus_in, .focus_out => {},
            .history_loaded => |recs| {
                self.setHistory(recs);
                // ROD-229: the initial load just landed — resolve the resume
                // landing (no-op unless landing == last_watched). One-shot.
                self.maybeResumeLanding(loop, io, registry);
            },
            .history_reloaded => |recs| {
                // ROD-191: a reload landed. setHistory swaps the slice; run() flips
                // the live double-buffer arena because history_reload_ok is set.
                self.setHistory(recs);
                self.history_reload_ok = true;
                self.history_reload_settled +%= 1;
            },
            .history_reload_failed => {
                // ROD-191: keep the current slice (a transient store error must not
                // wipe the watchlist) and signal run() to clear the latch without a
                // flip. A quiet toast so the user knows the refresh didn't take.
                self.history_reload_ok = false;
                self.history_reload_settled +%= 1;
                self.pushToast(.warn, "watchlist refresh failed", false);
            },
            .history_load_failed => |msg| {
                // ROD-234: the initial history load failed for real — raise the
                // banner and stop the spinner. Scoped to history so a Browse error
                // (task_error) can no longer falsely mark History "unavailable".
                self.load_error = msg;
                self.history_loading = false;
            },
            .task_error => |msg| {
                // ROD-234: a Browse search/enrich failure. Surfaces as a persistent
                // toast only — it must NOT touch History state (no load_error, no
                // history_loading), or it falsely bricks the History landing view.
                self.search.loading = false;
                self.debounce_deadline_ms = 0;
                self.cover_sync_deadline_ms = 0;
                self.async_start_ms = 0;
                self.pushToast(.@"error", msg, true);
            },
            .sync_flushed => |outcome| {
                // ROD-291: the pull-then-push flush settled — or, with pushed == 0, the
                // ROD-293 launch pull-refresh (same event). inflight was already cleared
                // by the worker's defer — nothing to unlatch here.
                // The pull reconciled remote changes into local rows: if any actually
                // changed, the in-memory history slice is stale, so flag a reload at a
                // safe seam (the same signal a playback write uses), and whisper the ↓
                // direction (ROD-293) — the git-style ahead/behind idiom, symmetric with
                // the ↑ push below. A reconciled change re-baselines the sync snapshot, so
                // it counts as `reconciled` exactly once and can't re-toast on later flushes.
                if (outcome.reconciled > 0) {
                    self.history_dirty = true;
                    var buf: [40]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "↓ {d} from AniList", .{outcome.reconciled}) catch "↓ from AniList";
                    self.pushToast(.info, msg, false);
                }
                // Token rejected mid-session: drop the cached connected flag so we stop
                // spawning do-nothing flushes on every edit, and seed ROD-295's reconnect
                // nudge (which re-evaluates connection). The user-facing surface is 295's.
                if (outcome.expired) self.anilist_connected = false;
                // Ambient feedback only: whisper a low-key toast when a push actually
                // landed, stay silent on a no-op or soft failure (unpushed rows stay dirty
                // and retry on the next flush). Enqueued after the ↓ above so a flush that
                // moved both directions reads in execution order — reconcile, then push.
                if (outcome.pushed > 0) {
                    var buf: [40]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "↑ {d} to AniList", .{outcome.pushed}) catch "↑ to AniList";
                    self.pushToast(.info, msg, false);
                }
            },
            .update_available => {
                // ROD-370: the boot check found a newer release. A fixed-width whisper
                // (no version) so it can never clip the actionable command; the version
                // lives in Settings and in `zigoku update`'s own output.
                self.pushToast(.info, "update available · run zigoku update", false);
            },
            .connect_result => |outcome| self.onConnectResult(outcome, loop, io),
            .search_done => |ev| {
                // Stale check: ignore if query has changed since this search was fired.
                if (!std.mem.eql(u8, ev.for_query, self.search.querySlice())) {
                    for (ev.results) |r| freeOwnedAnime(self.gpa, r);
                    self.gpa.free(ev.for_query);
                    self.gpa.free(ev.results);
                    return;
                }
                self.search.loading = false;
                self.async_start_ms = 0;
                // Clear persistent search-error toasts on a good result — only the
                // general-topic ones, so a feed error survives a Browse search (ROD-239).
                for (&self.toast_queue) |*slot| {
                    if (slot.*) |t| {
                        if (t.persistent and t.kind == .@"error" and t.topic == .general) slot.* = null;
                    }
                }
                if (ev.page == 1) {
                    self.search.clearResults(self.gpa); // free old data
                }
                const offset = self.search.results.items.len;
                self.search.page = ev.page;
                // Take ownership: append results into self.search.results, which already holds
                // old page(s) for page > 1. The strings are already gpa-owned.
                self.search.results.appendSlice(self.gpa, ev.results) catch |e| {
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
                const added = self.search.results.items.len - offset;
                // ROD-327: AniList hits arrive fully enriched, so no second enrich pass is
                // needed. Hydrate warms from the canonical spine; persist mirrors each hit
                // as a canonical entity only (binding to a play provider is the resolver's job).
                self.search.hydrateResultsFromStore(self.gpa, self.store, offset, added);
                self.search.persistResults(self.gpa, self.store, offset, added);
            },

            .resolve_add_result => |ev| {
                // ROD-327/328: add-resolve settled; free the id (a tier-C miss carries an
                // empty, non-owned slice) and clear the in-flight guard on both arms.
                defer if (ev.source_id.len > 0) self.gpa.free(ev.source_id);
                defer if (ev.absent_sources.len > 0) self.gpa.free(ev.absent_sources);
                // ROD-347: cache the walk's definitive misses on both arms, before any
                // early return. The widen below filters its provider snapshot through
                // providerAbsentFresh, so this persist must run first or a just-learned
                // absence isn't excluded from the re-search.
                self.persistProviderAbsences(ev.anilist_id, ev.absent_sources);
                self.async_start_ms = 0;
                self.add_resolving = false;
                if (!ev.ok) {
                    // ROD-346: a single-provider tier-A probe miss (ev.source names the
                    // probed provider) widens to a search over the REMAINING providers
                    // before persisting the no-source verdict. The search walk itself
                    // posts an empty source, so this fires at most once per add.
                    if (ev.source.len > 0 and self.fireResolveAddWiden(loop, io, registry, ev.anilist_id, ev.source)) return;
                    // Resolver miss (tier-A + tier-C both missed): persist the unbound
                    // terminal state (ROD-329) instead of a dead-end toast. A null store or
                    // a false return (no canonical row) falls back to the plain error, never
                    // a false success.
                    const st = self.store orelse {
                        self.pushToast(.@"error", "couldn't add to watchlist", false);
                        return;
                    };
                    var miss_arena = std.heap.ArenaAllocator.init(self.gpa);
                    defer miss_arena.deinit();
                    const marked = st.markUnbound(ev.anilist_id, Store.nowSecs(), miss_arena.allocator()) catch |e| {
                        log.debug("markUnbound failed: {s}", .{@errorName(e)});
                        self.pushToast(.@"error", "couldn't add to watchlist", false);
                        return;
                    };
                    if (!marked) {
                        self.pushToast(.@"error", "couldn't add to watchlist", false);
                        return;
                    }
                    // Surface it this session (mirrors the success arm's reload flag).
                    self.history_dirty = true;
                    self.pushToast(.warn, "added, no source available", false);
                    return;
                }
                // Bind + reveal. A thrown error, a null store, or a false return (no canonical
                // row, so nothing was written) must all toast the miss, never a false success.
                const st = self.store orelse {
                    self.pushToast(.@"error", "couldn't add to watchlist", false);
                    return;
                };
                var arena = std.heap.ArenaAllocator.init(self.gpa);
                defer arena.deinit();
                const bound = st.bindCanonical(ev.source, ev.source_id, ev.anilist_id, true, Store.nowSecs(), arena.allocator()) catch |e| {
                    log.debug("bindCanonical (add) failed: {s}", .{@errorName(e)});
                    self.pushToast(.@"error", "couldn't add to watchlist", false);
                    return;
                };
                if (!bound) {
                    self.pushToast(.@"error", "couldn't add to watchlist", false);
                    return;
                }
                // P adds a row not yet in self.history, so flag a reload so it surfaces this
                // session (mirrors addToWatchlist).
                self.history_dirty = true;
                self.noteAvailabilityWrite(ev.anilist_id);
                self.pushToast(.success, "added to watchlist", false);
                self.firePrewarm(loop, io, registry, ev.anilist_id); // ROD-351: warm the siblings
            },

            .resolve_play_target => |ev| {
                // ROD-328: tier-C Play resolve settled. Free the resolved id (empty on a
                // miss) and clear the in-flight guard.
                defer if (ev.source_id.len > 0) self.gpa.free(ev.source_id);
                defer if (ev.absent_sources.len > 0) self.gpa.free(ev.absent_sources);
                // ROD-347: a definitive absence is a fact about the catalog, so it is
                // cached even when the staleness gate below drops the result itself.
                self.persistProviderAbsences(ev.anilist_id, ev.absent_sources);
                self.async_start_ms = 0;
                self.play_resolving = false;
                // ROD-346: drop a result the user has superseded (they fired another
                // show's fetch, which cleared play_resolve_aid). Installing it would
                // hijack the currently-displayed grid; its dead-end toast would name a
                // show they already left.
                const wanted = self.play_resolve_aid != null and self.play_resolve_aid.? == ev.anilist_id;
                self.play_resolve_aid = null;
                if (!wanted) return;
                if (!ev.ok) {
                    // ROD-346: a walk hop's search missed; advance to the next provider.
                    // Guarded on the walk's anilist_id so a late miss for a superseded
                    // search can never advance a newer show's walk.
                    if (self.fallback != null and self.fallback.?.anilist_id == ev.anilist_id) {
                        if (self.advanceFallback(loop, io, registry, null, null)) return;
                    }
                    // ROD-346/ROD-229: a walk that started from the auto-resume landing
                    // and exhausted HERE (tier-C was the last hop) must demote just like
                    // the episodes_error dead end, or the user strands on a blank pane.
                    self.demoteResumeLanding();
                    // No confident provider match (unmatched, ROD-329): same dead-end as a
                    // failed episode fetch.
                    self.pushToast(.@"error", "couldn't load episodes", false);
                    return;
                }
                // The staleness gate above makes this walk (if any) this result's own:
                // both were keyed by the same fire (play_resolve_aid == ev.anilist_id).
                std.debug.assert(self.fallback == null or self.fallback.?.anilist_id == ev.anilist_id);
                // Confirmed match: fire the episode fetch on the provider that matched
                // (ev.source, ROD-343), then arm pending_bind (order matters:
                // fireEpisodesForId nulls it at entry, same trap as fireEpisodesResolved).
                // The walk (if any) survives the fire the same way: its hop's probe
                // failure must still be able to advance it.
                const walk = self.fallback;
                self.fallback = null;
                self.fireEpisodesForId(loop, io, registry, ev.source_id, ev.source, if (walk) |w| domain.expectedEpisodeCount(w.canonical) else null);
                if (self.episodes.loading) {
                    self.fallback = walk;
                } else if (walk) |w| {
                    var done = w; // fetch settled synchronously: the walk is finished
                    done.deinit(self.gpa);
                }
                self.pending_bind = ev.anilist_id;
            },

            .prewarm_result => |ev| {
                // ROD-351: one provider settled. Mint HIDDEN (a play reveals it;
                // History must not grow rows the user never engaged) or cache the
                // negative (ROD-347). Best-effort on every branch: the warm is an
                // optimization, and the next resolve self-heals anything dropped.
                defer if (ev.source_id.len > 0) self.gpa.free(ev.source_id);
                const st = self.store orelse return;
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
            },

            .prewarm_done => self.prewarm_active = false,

            .discover_feed => |ev| {
                // Land the page into ITS OWN axis slot (by ev.axis), never the
                // active one: an axis switch mid-flight must not misfile the
                // result (the DiscoverState invariant). No "stale drop": every
                // page is valid cached data for the axis it was fetched for.
                const idx = @intFromEnum(ev.axis);
                const slot = &self.discover.slots[idx];
                slot.loading = false;
                slot.failed = false; // a good page clears the feed's error state
                const is_active = idx == @intFromEnum(self.discover.axis);
                if (is_active) self.async_start_ms = 0;
                // Clear the persistent feed-error toast on first success — only the
                // feed-topic one, so a Browse search error survives (§9.3b, ROD-239).
                for (&self.toast_queue) |*ts| {
                    if (ts.*) |t| {
                        if (t.persistent and t.kind == .@"error" and t.topic == .feed) ts.* = null;
                    }
                }
                // Page 1 is a fresh axis load, so free the old slot contents first.
                if (ev.page == 1) self.discover.clearSlot(self.gpa, idx);
                const offset = slot.results.items.len;
                // Take ownership: the duped Anime (strings already gpa-owned) move
                // into the slot's list, which may hold earlier pages for page > 1.
                slot.results.appendSlice(self.gpa, ev.results) catch |e| {
                    // OOM: free the page and bail WITHOUT stamping fetched_at/page —
                    // leaving the slot page-0 so refreshDiscover refetches it, rather
                    // than a fresh+exhausted+empty TTL-locked dead end (ROD-239 review).
                    log.debug("appending feed results failed: {s}", .{@errorName(e)});
                    for (ev.results) |r| freeOwnedAnime(self.gpa, r);
                    self.gpa.free(ev.results);
                    return;
                };
                self.gpa.free(ev.results);
                // Stamp freshness + exhaustion only on a successful append. Exhaustion
                // is AniList's own has-more signal (pageInfo.hasNextPage, §9.6) or the
                // retention cap (max_feed_rows, ROD-339); never the retired "page came
                // back short" heuristic.
                slot.fetched_at = Store.nowSecs();
                slot.page = ev.page;
                slot.exhausted = !ev.has_next or slot.results.items.len >= DiscoverState.max_feed_rows;
                // Rows arrive fully enriched (full GQL_FIELDS); no enrich pass.
                // Mirror them into the canonical spine so a later Browse hit or
                // detail open hydrates rich (persist like search, ROD-336).
                const added = slot.results.items.len - offset;
                self.discover.persistSlot(self.gpa, self.store, idx, offset, added);
                // Reset the grid cursor on a fresh load of the visible axis.
                if (is_active and ev.page == 1) {
                    self.discover.cursor = 0;
                    self.discover.scroll = 0;
                }
            },

            .discover_feed_error => |ev| {
                // Feed fetch failed (ROD-239, §9.3b). Mark the slot failed + clear
                // its spinner; the view shows "can't reach the feed" while the slot
                // is empty, and [ ] / 1-4 / re-entry retry (refreshDiscover re-fires
                // a page-0 slot). Persistent toast, cleared on the next good page.
                const slot = &self.discover.slots[@intFromEnum(ev.axis)];
                slot.loading = false;
                slot.failed = true;
                if (@intFromEnum(ev.axis) == @intFromEnum(self.discover.axis)) self.async_start_ms = 0;
                log.debug("discover feed fetch failed: {s}", .{@errorName(ev.cause)});
                self.pushToastTopic(.@"error", "can't reach the feed", true, .feed);
            },
            .enrichment_refreshed => |ev| {
                // ROD-182: a stale show was re-enriched on view. ROD-278: only persist
                // + stamp when AniList actually answered (a match or a confirmed
                // no-match). A transport failure (`answered == false`) changed nothing
                // and must NOT advance the freshness clock — skip the write entirely so
                // the next view retries rather than waiting out the TTL on a failed fetch.
                if (ev.answered) {
                    if (self.store) |st| {
                        // Persist the fresh content: upsert's COALESCE overwrites the
                        // drift fields (status/score/description/total_episodes), preserves
                        // user columns, keeps any field AniList returned null for, and
                        // stamps freshness, then flags a history reload. history_visible
                        // stays false: the MAX-merge preserves the row's stored visibility,
                        // so a Browse refresh of a hidden cache row never reveals an
                        // untracked show. stamp_fresh=true is safe here (inside
                        // `if (ev.answered)`, a confirmed answer; upsertEnriched owns the gate).
                        var arena = std.heap.ArenaAllocator.init(self.gpa);
                        defer arena.deinit();
                        st.upsertEnriched(ev.source, ev.result, self.translation, false, true, Store.nowSecs(), arena.allocator()) catch |e|
                            log.debug("enrichment refresh upsert failed: {s}", .{@errorName(e)});
                        self.history_dirty = true; // reload so detail/list show fresh content
                    }
                }
                freeOwnedAnime(self.gpa, ev.result);
                self.gpa.free(ev.source);
                // Detached worker (enrich_refresh_drain) — already exited; no join here.
            },
            .episodes_done => |ev| {
                defer self.gpa.free(ev.for_id);
                // Stale: discard if not for the current detail show.
                if (self.episodes.for_id == null or !std.mem.eql(u8, ev.for_id, self.episodes.for_id.?)) {
                    for (ev.episodes) |ep| self.gpa.free(ep.raw);
                    self.gpa.free(ev.episodes);
                    return;
                }
                self.episodes.loading = false;
                self.async_start_ms = 0;
                // ROD-368: a 200-with-empty listing is the provider's authoritative
                // "doesn't stock this show" (senshi's shape; the same signal
                // resolveAddTask reads as `.absent`), NOT a real 0-episode grid.
                // Binding it strands the detail on an empty pane and the provider
                // ladder never walks, since only `episodes_error` walked. Treat it
                // like that error: cache the absence and hop to a provider that does
                // carry the show (megaplay) before conceding a dead end. pending_bind
                // is the aid for a tier-A/resolve open; a plain History open reads it
                // off the row being served.
                if (ev.episodes.len == 0) {
                    self.gpa.free(ev.episodes);
                    const failed_bind = self.pending_bind;
                    self.pending_bind = null;
                    if (self.episodes.for_source) |src| {
                        const aid: ?i64 = failed_bind orelse blk: {
                            const st = self.store orelse break :blk null;
                            var a = std.heap.ArenaAllocator.init(self.gpa);
                            defer a.deinit();
                            const rec = (st.getAnime(a.allocator(), src, ev.for_id) catch null) orelse break :blk null;
                            break :blk rec.anilist_id;
                        };
                        if (aid) |id| self.persistProviderAbsences(id, &.{src});
                    }
                    if (self.advanceFallback(loop, io, registry, failed_bind, self.owningProvider(registry).displayName())) return;
                    // The whole ladder came up empty: no provider stocks it, so render
                    // the unbound state ("no source available") rather than a bare
                    // 0-episode grid. In-memory only; a plain browse peek must not mint
                    // a persisted unbound row (that is the Add path's call, ROD-329).
                    self.demoteResumeLanding();
                    self.episodes.unbound = true;
                    return;
                }
                // ROD-229: the resume grid loaded — the auto-open succeeded, so
                // there is nothing left to demote from.
                self.resume_landing_pending = false;
                // Free any old results (fireEpisodes clears them, but be defensive).
                if (self.episodes.results) |old| {
                    for (old) |ep| self.gpa.free(ep.raw);
                    self.gpa.free(old);
                }
                // This is the one site that writes `results` without going through
                // `applyCached`. `for_id`/`for_source` are intentionally left as
                // `fireEpisodesForId` set them before spawning the thread (they stay
                // live across the flight so syncEpisodeProgress can match) — we own
                // only `ev.episodes` here. If a future caller ever sets `results`
                // directly, it must keep the (for_id, for_source) pair in lockstep
                // (ROD-193 review).
                self.episodes.results = ev.episodes;
                self.episodes.cursor = 0;
                self.episodes.progress = 0;
                self.episodes.resume_idx = null;
                // Seed the §4.6 watched-dim + resume cursor for either origin
                // (ROD-163): history reuses the in-memory record, browse reads
                // stored progress keyed off for_source/for_id — the authoritative
                // (source, source_id) for this result, set together at fire time
                // (line ~1593) and held live across the flight, not live UI state
                // (the H2 caveat below). detailSeedRecord handles a null source.
                {
                    var seed_arena = std.heap.ArenaAllocator.init(self.gpa);
                    defer seed_arena.deinit();
                    if (selection.detailSeedRecord(self, seed_arena.allocator(), self.episodes.for_source, ev.for_id)) |rec| {
                        self.episodes.seedHistoryCursor(self.store, self.translation, rec, ev.episodes);
                    }
                    // seed_arena (and rec's browse-origin slices) freed here.
                }
                // ROD-130: mirror the fresh fetch into the DB + hot LRU so the next visit
                // to this show is a synchronous cache hit. `for_source` is the fetch's
                // source captured at fire time (ROD-343), so a late result binds and
                // caches under the provider that actually served it even if nav moved
                // on; the nav-state fallback only covers a for_source-less edge that
                // the async path can't actually produce.
                const source = self.episodes.for_source orelse selection.currentDetailSourceName(self, registry);
                const status: ?[]const u8 = if (self.currentDetailAnime()) |a| a.status else null;
                // ROD-327: tier-A resolve write. Bind BEFORE caching: episode_cache has an FK
                // to anime(source, source_id), so the parent binding row must exist first, or
                // the cache write FK-fails. Hidden (`false`); recordPlay reveals it on first play.
                if (self.pending_bind) |aid| {
                    self.pending_bind = null;
                    if (self.store) |st| {
                        var arena = std.heap.ArenaAllocator.init(self.gpa);
                        defer arena.deinit();
                        if (st.bindCanonical(source, ev.for_id, aid, false, Store.nowSecs(), arena.allocator())) |bound| {
                            // A false bind leaves this show unbindable: the grid still renders
                            // from the event payload, but a later recordPlay would FK-fail.
                            if (!bound) log.debug("bindCanonical (play): no canonical for anilist_id {d}", .{aid});
                            if (bound) self.noteAvailabilityWrite(aid);
                        } else |e| log.debug("bindCanonical (play) failed: {s}", .{@errorName(e)});
                    }
                }
                // ROD-352: every async landing (fresh mint, walk hop, plain open) raises
                // through the canonical union. Must run after the mint above so a fresh
                // binding has a row to raise; the seed pass ran on the stale (or pre-mint)
                // value, so the raise patches the in-memory grid too.
                self.raiseLandingProgress(source, ev.for_id);
                self.episodes.cacheEpisodes(self.gpa, self.store, source, ev.for_id, self.translation, status, ev.episodes);
                // ROD-346: the grid landed, so any fallback walk delivered: retire
                // it, or run its play continuation (which keeps the walk armed
                // across the relaunch, see completeFallback).
                self.completeFallback(loop, io, registry);
            },
            .episodes_error => |ev| {
                defer self.gpa.free(ev.for_id);
                // Stale: a superseded fetch's failure must not clear the live load
                // nor toast for a show the user already left (ROD-179 — mirrors the
                // episodes_done keep-check above).
                if (self.episodes.for_id == null or !std.mem.eql(u8, ev.for_id, self.episodes.for_id.?)) return;
                self.episodes.loading = false;
                self.async_start_ms = 0;
                // ROD-327: the tier-A existence probe failed → resolver miss, write no
                // state (the unmatched terminal state is ROD-329). Captured first: a
                // virgin probe's aid is the walk's only handle on the canonical.
                const failed_bind = self.pending_bind;
                self.pending_bind = null;
                // ROD-346: walk the remaining providers before declaring the dead end.
                // A fired hop suppresses the demote + toast below; exhaustion (or a
                // show that can't fall back) falls through to them.
                if (self.advanceFallback(loop, io, registry, failed_bind, self.owningProvider(registry).displayName())) return;
                // ROD-229: an auto-opened resume landing whose grid fetch failed
                // must not strand the user on a blank detail pane — demote to the
                // History view (cursor already parked on the target row). The toast
                // below still explains the failure. A user-driven open is never
                // pending here (cleared at fire time), so it stays put.
                self.demoteResumeLanding();
                // §4.10: an empty grid with no explanation is indistinguishable
                // from a show that genuinely has no episodes — surface the fetch
                // failure so the blank pane isn't a silent dead end. ROD-173 names
                // the network/blocked/server class when we know it; data-shape
                // failures fall back to the generic line.
                var buf: [128]u8 = undefined;
                const copy = failureClassCopy(ev.cause, self.owningProvider(registry).displayName(), &buf) orelse "couldn't load episodes";
                self.pushToast(.@"error", copy, false);
            },
            .cover_done => |ev| {
                defer self.gpa.free(ev.for_id);
                if (self.cover.for_id == null or !std.mem.eql(u8, ev.for_id, self.cover.for_id.?)) {
                    self.gpa.free(ev.rgba);
                    return;
                }
                self.cover.loading = false;
                self.cover.joinThread();
                if (!self.search.loading and !self.episodes.loading and !self.playing) self.async_start_ms = 0;

                // The result is stale if the selection moved off this id while
                // the fetch was in flight; the controller owns that nav check.
                // Must use the same resolver cover.sync started from — in split
                // browse that's the list cursor, else the keep-check would reject
                // every cover the list-pane prefetch just fetched (ROD-156 #2).
                const target_id = if (self.detailSyncTarget()) |a| a.id else null;
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
                if (!self.search.loading and !self.episodes.loading and !self.playing) self.async_start_ms = 0;
                // Record the failed url *before* clear() frees it.
                self.cover.noteFailure(self.gpa, self.now_ms, for_id, self.cover.inflight_url);
                self.cover.clear(self.gpa);
                std.log.debug("cover fetch/decode failed for {s}", .{for_id});
            },
            .discover_cover_done => |ev| {
                // Covers are URL-keyed and window-agnostic, so this is always a valid
                // cover for ev.url — adopt it into the slot (recreated if it was
                // evicted mid-flight). acceptPixels takes ownership of ev.rgba,
                // freeing it only if no slot can hold it (OOM). The url is borrowed
                // (the slot dupes its own key) and freed here.
                defer self.gpa.free(ev.url);
                self.discover_covers.acceptPixels(self.gpa, ev.url, ev.rgba, ev.width, ev.height);
            },
            .discover_cover_error => |url| {
                // Record the per-url cooldown so pump won't hammer a transient miss,
                // then free the url. No async_start_ms / spinner: the rank placeholder
                // is the per-card loading affordance, not a blocking wait.
                defer self.gpa.free(url);
                self.discover_covers.noteFailure(self.gpa, url, self.now_ms);
            },
            .position_update => |ev| {
                self.current_position = ev.time_pos;
                self.current_duration = ev.duration;
                self.session.maybeCheckpoint(self.store, ev.time_pos, ev.duration);
            },
            .play_done => |final_update| {
                // ROD-168: a clean exit is no longer proof of a watch — you can
                // quit mpv at any second. Count it only if the final position
                // cleared the completion bar.
                self.finishPlayback(final_update, watchCompleted(final_update));
                // ROD-346: playback worked, so any relaunch walk is finished.
                self.clearFallback();
            },
            .play_error => |ev| {
                const completed = watchCompleted(ev.final);
                // ROD-346: only a stream that never meaningfully played hops the
                // walk (the CF-penalty shape). A mid-episode death relaunching
                // elsewhere would be a loop hazard, not a rescue. The continuation
                // is captured BEFORE finishPlayback clears the session, and only
                // when the detail grid still shows the played binding (nav state
                // can have moved on; a mismatched relaunch would be chaos).
                const never_played = if (ev.final) |f| !f.isMeaningful() else true;
                const cont_ok = !completed and never_played and self.store != null and
                    self.episodes.for_id != null and self.session.anime_id.len > 0 and
                    std.mem.eql(u8, self.session.anime_id, self.episodes.for_id.?) and
                    self.episodes.for_source != null and self.session.source.len > 0 and
                    std.mem.eql(u8, self.session.source, self.episodes.for_source.?);
                const ep_copy: ?[]const u8 = if (cont_ok) self.gpa.dupe(u8, self.session.episode_raw) catch null else null;
                const ordinal = self.session.episode_index;
                self.finishPlayback(ev.final, completed);
                // §4.10: a play that errored without reaching the watched bar is a
                // genuine failure (resolve failed, or mpv died mid-episode) —
                // surface it. A completed watch that errored at the very end took
                // the success path in finishPlayback instead. ROD-173 names the
                // resolve-side network/blocked/server class when we know it; the
                // mpv-spawn classes fall back to the generic line (ROD-230 refines).
                if (!completed) {
                    if (ep_copy) |raw| {
                        if (self.advancePlayFallback(loop, io, registry, raw, ordinal)) return;
                    } else {
                        // Not hopping (mid-episode death, or the pane moved on):
                        // any armed relaunch walk is over.
                        self.clearFallback();
                    }
                    var buf: [128]u8 = undefined;
                    const copy = failureClassCopy(ev.cause, self.owningProvider(registry).displayName(), &buf) orelse "playback failed";
                    self.pushToast(.@"error", copy, false);
                } else {
                    self.clearFallback();
                }
            },
            .play_retry => |r| {
                // ROD-309: the CDN 403'd the stream open (a Cloudflare penalty window)
                // and the worker is re-resolving after a backoff. Transient warn so the
                // wait reads as "retrying", not a frozen launch.
                var buf: [48]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "stream didn't open — retrying {d}/{d}", .{ r.attempt, r.max }) catch "stream didn't open — retrying";
                self.pushToast(.warn, msg, false);
            },
            .tick => {
                const now = nowMs(io);
                self.now_ms = now;
                self.spinner_frame = (self.spinner_frame + 1) % 10;
                if (self.debounce_deadline_ms > 0 and now >= self.debounce_deadline_ms) {
                    self.debounce_deadline_ms = 0;
                    self.search.clearResults(self.gpa);
                    self.fireSearch(loop, io, 1);
                }
                // The cursor settled: fetch the cover for the show it landed on
                // (ROD-202). cover.sync's up_to_date short-circuit makes a re-fire
                // for the same show a no-op, so a settle that didn't change the
                // target costs nothing.
                if (self.cover_sync_deadline_ms > 0 and now >= self.cover_sync_deadline_ms) {
                    self.cover_sync_deadline_ms = 0;
                    selection.syncCover(self, loop, io, registry);
                }
                // The action-sync debounce settled (ROD-291): flush dirty local rows up
                // to AniList off-thread. fireSyncFlush no-ops when unconnected or already
                // flushing, so a settle that has nothing to do costs nothing.
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
            },
        }

        if (event != .tick) {
            // ROD-202 cover-settle debounce. Three cases for a non-tick event:
            // A scroll is a j/k/↓/↑ step in normal mode that actually moved the
            // cursor — NOT a jump key, filter keystroke, or view switch (those move
            // the cursor too but are discrete settle points: review M1/E1/E2).
            const key_scroll = event == .key_press and
                self.input_mode == .normal and
                selection.isListScrollKey(event.key_press) and
                self.list_cursor != cursor_before;
            if (key_scroll and selection.coverTracksCursor(self)) {
                // 1. Scroll step where the cover tracks the cursor: only arm (re-arm)
                //    the settle — the actual fetch fires from .tick once the cursor
                //    stops (the next tick ≥ cover_settle_ms later). Without this a fast
                //    j/k scroll calls cover.sync per row, each blocking the UI thread on
                //    joinThread for the prior row's decode before respawning — the stutter.
                self.cover_sync_deadline_ms = nowMs(io) + cover_settle_ms;
            } else if (event == .key_press) {
                // 2. Discrete key nav (jump, pane/view switch, a settled cursor): sync
                //    now and cancel any pending settle — the cover must never lag a
                //    deliberate keystroke.
                self.cover_sync_deadline_ms = 0;
                selection.syncCover(self, loop, io, registry);
            } else {
                // 3. Async completion / resize: refresh the cover, but don't stomp a
                //    pending scroll settle — let the cursor settle drive it instead of
                //    fetching the row we happen to be mid-scroll over.
                if (self.cover_sync_deadline_ms == 0) selection.syncCover(self, loop, io, registry);
            }
        }
    }

    pub fn fireSearch(self: *App, loop: *Loop, io: std.Io, page: u32) void {
        const q = self.search.querySlice();
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
        self.search.loading = true;
        self.async_start_ms = self.now_ms;
        // ROD-327: discovery search is off the SourceProvider vtable; searchTask queries
        // AniList directly, so no provider/translation is threaded here.
        self.search_thread = std.Thread.spawn(.{}, searchTask, .{
            loop, self.gpa, io, q_copy, page,
        }) catch {
            self.gpa.free(q_copy);
            self.search.loading = false;
            return;
        };
    }

    /// Soft cap on concurrently-spawned Discover feed fetches (ROD-264). Each fetch
    /// spawns an uncapped `std.Thread` on the shared `Io.Threaded` pool, whose own
    /// `concurrent_limit` is unbounded, so an app-level cap is the only backstop. A
    /// saturation storm (rapid paging + axis cycling on a slow link) could pile enough
    /// live threads to approach the OS thread/fd ceiling, where `std.Thread.spawn`
    /// starts failing, which is exactly what tips a fetch onto `withDeadline`'s
    /// unbounded inline fallback (ROD-264). Bounding our own fan-out keeps us clear.
    /// Under the current call graph this is pure headroom, not a reachable limit:
    /// every fireDiscoverFeed caller fires only the active axis behind its own
    /// `loading` gate, so at most one fetch per axis (4 total) is ever in flight
    /// (ROD-339); kept as the backstop for any future fan-out caller. (Covers ride
    /// their own drain + cap, ROD-240.)
    const discover_feed_cap = 8;

    /// True when the Discover feed pool is at the soft cap (ROD-264 #3): the
    /// caller should DROP its spawn rather than queue it. Every feed fetch is
    /// idempotent and recovered by a later trigger — `refreshDiscover`'s !loading
    /// recheck, or the prefetch/fill passes re-firing, so a dropped spawn is
    /// deferred, not lost, the same drop-and-re-plan the cover pump uses (ROD-240).
    /// `.acquire` pairs with `finish()`'s release so a just-freed slot is observed
    /// promptly.
    fn discoverPoolSaturated(self: *App) bool {
        return self.discover_drain.inflight.load(.acquire) >= discover_feed_cap;
    }

    /// Spawn the Discover feed fetch for `axis`/`page` (ROD-336): AniList, off the
    /// vtable, rows arrive fully enriched. Detached and accounted via `discover_drain`
    /// (ROD-251); never joins a prior in-flight fetch (that join on the event thread
    /// was the UI-freeze that ticket fixed). Sets the target slot's loading flag; the
    /// `.discover_feed` arm clears it and lands the results in that slot (by axis,
    /// not necessarily the active one).
    fn fireDiscoverFeed(self: *App, loop: *Loop, io: std.Io, axis: anilist.DiscoverAxis, page: u32) void {
        // This Season derives its cour from now_ms, whose pre-epoch clamp would turn a
        // pre-tick call (now_ms == 0) into a wrong-but-plausible WINTER-1970 query;
        // skip instead, like courChip/isNewRelease. run() stamps now_ms before the
        // loop starts, so this never bites in practice; the slot stays !loading, so
        // the next trigger re-fires.
        if (axis == .this_season and self.now_ms <= 0) return;
        // ROD-264 #3: drop past the soft cap. Left un-set, the slot stays !loading,
        // so refreshDiscover / the prefetch trigger re-fire once the pool drains.
        if (self.discoverPoolSaturated()) {
            log.debug("discover pool at cap ({d}): dropping feed fetch, will re-fire", .{discover_feed_cap});
            return;
        }
        // ROD-251: detach, don't join a prior in-flight feed fetch: cycling axes
        // (1→2→3→4) on a slow link would otherwise block the event thread on the old
        // fetch's join. Each axis writes its own slot (.discover_feed), so a superseded
        // fetch is harmless; refreshDiscover's `slot.loading` guard already blocks a
        // same-axis double page-1 fire, and teardown waits the set out via
        // discover_drain.
        const slot = &self.discover.slots[@intFromEnum(axis)];
        slot.loading = true;
        self.async_start_ms = self.now_ms;
        // Account before the spawn so teardown's drain can never observe a gap.
        self.discover_drain.begin();
        // No real worker under test (the fetch would hit the live AniList API). The
        // loading mark above is what tests exercise; rebalance the drain since no
        // worker will finish it.
        if (builtin.is_test) {
            self.discover_drain.finish();
            return;
        }
        const t = std.Thread.spawn(.{}, workers.discoverFeedTask, .{
            loop, self.gpa, io, axis, page, self.now_ms, &self.discover_drain,
        }) catch {
            self.discover_drain.finish(); // no worker will run — rebalance the count
            slot.loading = false;
            self.async_start_ms = 0;
            return;
        };
        t.detach();
    }

    /// Cache-or-fetch the active Discover axis (ROD-239). Renders the cached slot
    /// untouched when it's fresh (fetched within `feed_ttl_secs`); otherwise fires
    /// a page-1 fetch. Called on entering Discover and on every axis switch. The
    /// per-axis slot is the whole point; see the DiscoverState invariant.
    pub fn refreshDiscover(self: *App, loop: *Loop, io: std.Io) void {
        const slot = self.discover.activeSlot();
        if (slot.loading) return; // a fetch for this axis is already in flight
        const fresh = slot.page > 0 and (Store.nowSecs() - slot.fetched_at) < feed_ttl_secs;
        if (fresh) return; // cache hit — render the slot as-is, no network
        self.fireDiscoverFeed(loop, io, self.discover.axis, 1);
    }

    /// Pool cap for Discover-grid covers (ROD-243): retain roughly two large-tier
    /// grid pages of recently-seen *off-screen* covers so scrolling back stays
    /// instant without unbounded memory. On-screen and in-flight slots are never
    /// evicted, so the live footprint is (visible set + this). ROD-241 makes it a
    /// configurable knob.
    const discover_cover_cap = 30;
    /// Upper bound on visible+prefetch cards a single pump considers — far above any
    /// real grid (a 200×60 terminal is ~54) — so the on-stack planner buffers are
    /// fixed-size. Past this the tail cards keep their placeholder until `scroll`
    /// brings them within the first `max_pump_urls`; only reachable on absurd
    /// geometries, never in practice (ROD-243 review).
    const max_pump_urls = 128;

    /// Fetch covers for the visible Discover cards + one prefetch row, then evict
    /// off-screen slots back to the pool cap (ROD-243). Runs on the UI thread from run()
    /// after `layout` settles `scroll`, so grid geometry is known. Bounded parallelism
    /// (ROD-240): each missing cover gets a detached worker, capped at
    /// `config.discoverCoverConcurrency` in flight. No explicit queue; every frame
    /// re-plans against live slot state and tops the in-flight set back to the cap as
    /// workers finish, so covers beyond the cap wait and fast scrolling can't spawn
    /// unbounded requests. No-op outside Discover; the spawn is gated under test (the plan
    /// + in-flight mark still run).
    pub fn pumpDiscoverCovers(self: *App, loop: *Loop, io: std.Io, registry: Registry) void {
        if (self.active_view != .discover) return;

        const w = self.term_cols;
        const visible: u16 = if (self.term_rows >= 4 and w >= 16) self.term_rows - 3 else 0;
        const cp = self.cellPx();
        const geo = discover_view.geometry(w, visible, cp[0], cp[1]);
        if (geo.cols == 0 or geo.rows_visible == 0) return;

        const items = self.discover.activeSlot().results.items;
        if (items.len == 0) return;

        // Visible card range + one prefetch row (ROD-243 scope: no full-feed sweep).
        const start = self.discover.scroll * geo.cols;
        const span = (@as(usize, geo.rows_visible) + 1) * @as(usize, geo.cols);
        const end = @min(items.len, start + span);
        if (start >= end) return;

        self.discover_covers.frame +%= 1;
        const frame = self.discover_covers.frame;

        // Build the planner inputs over the visible cover URLs (skip cards with no
        // thumb), stamping each present slot's recency for eviction. URLs are
        // borrowed from the slot's results — valid for this synchronous pump.
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

        // Evict off-screen slots back to cap now that visible recency is stamped.
        self.evictDiscoverCovers(urls[0..n]);

        if (n == 0) return;

        // Pure plan: which visible URLs need a fetch (missing, not in flight, not
        // inside the failure cooldown).
        const plan: discover_covers_mod.FetchPlan = .{
            .has_pixels = has_pixels[0..n],
            .inflight = inflight[0..n],
            .failed_at = failed_at[0..n],
            .now_ms = self.now_ms,
        };
        var chosen: [max_pump_urls]usize = undefined;
        const m = plan.eval(chosen[0..n]);
        if (m == 0) return;

        // Bounded fan-out (ROD-240): top the in-flight worker set back up to the
        // configured cap. Covers beyond the cap simply aren't spawned this frame —
        // the next pump re-runs against live slot state and picks them up as workers
        // finish, so the "queue" is implicit and always re-prioritized to the live
        // viewport (a fetch is never spent on a card scrolled out of view). The cap
        // is read + clamped every frame, so a config change takes effect live.
        const cap: usize = self.config.discoverCoverConcurrency();
        const busy = self.discover_cover_drain.inflight.load(.acquire);
        if (busy >= cap) return; // at or above the cap — let the workers drain first
        // (>, not just ==, since a live cap decrease can leave busy above the new cap)
        var budget = cap - busy;

        for (chosen[0..m]) |ci| {
            if (budget == 0) break;
            const url = urls[ci];

            // Mark in-flight BEFORE spawning, from the BORROWED `urls` (stable for
            // this synchronous pump) — never from the dup the worker takes ownership
            // of. A stranded `.loading` slot is eviction-protected AND skipped by the
            // planner, so every early-out below resets it or it would never recover
            // (ROD-243). Done before the spawn so the in-test path exercises it too.
            self.discover_covers.markLoading(self.gpa, url);

            // No real worker under test — the mark above is what tests exercise; the
            // spawn is the only threaded line. Spend the budget so the loop still
            // bounds itself, then continue without a thread.
            if (builtin.is_test) {
                budget -= 1;
                continue;
            }

            // Snapshot the url (gpa-owned) for the worker to consume + free; it owns
            // the dup the instant it spawns and transfers it to the result event.
            const owned_url = self.gpa.dupe(u8, url) catch {
                self.resetLoadingSlot(url);
                continue;
            };

            // Account for the worker before the spawn so the teardown drain can never
            // observe a gap (ROD-179); rebalance + reset the slot on a spawn failure
            // (nothing else would resolve this url, leaving it stranded `.loading`).
            self.discover_cover_drain.begin();
            const t = std.Thread.spawn(.{}, workers.discoverCoverTask, .{
                loop, self.gpa, io, registry.primary(), owned_url, &self.cover_caches, &self.discover_cover_drain,
            }) catch {
                self.discover_cover_drain.finish();
                self.resetLoadingSlot(url);
                self.gpa.free(owned_url);
                continue;
            };
            t.detach(); // fire-and-forget; the drain barrier is the only synchronization.
            budget -= 1;
        }
    }

    /// Reset a slot stranded in `.loading` back to `.idle` (ROD-240): when the worker
    /// for `url` never launches (dup OOM / spawn failure) nothing will resolve it,
    /// and a `.loading` slot is eviction-protected and skipped by the planner — so it
    /// would never recover without this. No-op if the slot is gone or isn't loading.
    fn resetLoadingSlot(self: *App, url: []const u8) void {
        if (self.discover_covers.get(url)) |slot| {
            if (slot.status == .loading) slot.status = .idle;
        }
    }

    /// Evict the off-screen Discover cover slots overflowing the pool cap, dropping
    /// the least-recently-visible first and never a currently-visible or in-flight
    /// slot (ROD-243). `visible_urls` are the cards in view this frame.
    fn evictDiscoverCovers(self: *App, visible_urls: []const []const u8) void {
        const slots = self.discover_covers.slots.items;
        if (slots.len <= discover_cover_cap) return;
        const max_slots = 256;
        // The pool is `cap` + at most one grid's fresh slots, well under 256. Assert
        // in debug so a future tuning regression (ROD-241) is loud, but keep the
        // release-safe clamp — the fixed buffers below are sized to `max_slots`.
        std.debug.assert(slots.len <= max_slots);
        if (slots.len > max_slots) return;

        var last_seen: [max_slots]u64 = undefined;
        var vis: [max_slots]bool = undefined;
        for (slots, 0..) |*slot, i| {
            last_seen[i] = slot.last_seen_frame;
            // Protect on-screen and in-flight slots from eviction.
            vis[i] = slot.status == .loading or containsUrl(visible_urls, slot.url);
        }
        var out: [max_slots]usize = undefined;
        const k = discover_covers_mod.planEvictions(last_seen[0..slots.len], vis[0..slots.len], discover_cover_cap, out[0..slots.len]);
        if (k == 0) return;

        // Capture the urls to evict before mutating the pool: swapRemove moves slot
        // structs but not their key allocations, so these slices stay valid until
        // each is freed by its own evict().
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

    /// The pure refresh-on-view decision, split from `maybeRefreshEnrichment` so it's
    /// unit-testable without that function's `is_test` network guard. Refresh a TRACKED,
    /// STALE show UNLESS a competing enrich path already covers it:
    ///   * `discover_inflight`:    a Discover feed fetch is running (its rows arrive
    ///                             fully enriched and persist fresh, ROD-336),
    ///   * `search_enrich_active`: a live Browse search-page enrich is running (fed a
    ///                             constant false since ROD-330 excised that path; kept
    ///                             as the guard seam for a future search-side enrich),
    ///   * `refresh_inflight`:     another refresh-on-view is already in flight.
    ///
    /// Only tracked rows refresh here: a hidden Browse/Discover cache row has its OWN
    /// enrich path, so refreshing it would double-fetch. The skips exist because those
    /// paths also persist and freshness-stamp the row (ROD-279/280), so letting refresh
    /// fire too would double-hit AniList. Coarse by design (any competing enrich, not
    /// per-id): a skipped refresh just heals on the next open.
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

    /// ROD-182: refresh-on-view gate. Re-enrich the just-opened show when its
    /// persisted enrichment is stale (`Store.enrichmentStale` — TTL lapsed, never
    /// enriched, or filled under an older field set). `rec` is the seed record
    /// `fireEpisodesForId` already resolved (History in-memory or the store); null
    /// means nothing is persisted yet, so the search/discover enrich path owns
    /// freshness and there's nothing to refresh. Delegates the yes/no to
    /// `shouldRefreshOnView` (with the live competing-enrich state) and fires the
    /// detached worker when it says go.
    fn maybeRefreshEnrichment(self: *App, loop: *Loop, io: std.Io, source: ?[]const u8, source_id: []const u8, rec: ?AnimeRecord) void {
        // Never fire a live network refresh under `zig build test` — this runs before
        // the episode cache-hit early-return in fireEpisodesForId, so without the
        // guard even a synchronous cache-hit test spawns a detached network thread
        // (leak + dangling thread). Same guard every sibling here carries
        // (fireDiscoverFeed); tests exercise `shouldRefreshOnView` directly.
        if (builtin.is_test) return;
        if (self.store == null) return;
        const r = rec orelse return;
        const src = source orelse return;
        if (!shouldRefreshOnView(
            r,
            Store.nowSecs(),
            self.discover_drain.inflight.load(.acquire) > 0,
            // ROD-330: the Browse second-pass enrich was excised, so no live search-enrich
            // competes here. The param stays as the guard seam for a future search-side enrich.
            false,
            self.enrich_refresh_drain.inflight.load(.acquire) > 0,
        )) return;
        self.fireRefreshEnrich(loop, io, src, source_id, r);
    }

    /// Spawn the detached refresh worker for `rec`. Builds a gpa-owned identity stub
    /// (id/name/english_name/anilist_id — all `anilist.enrich` needs to take the
    /// exact `enrichById` path or fall back to a title search) plus a gpa-owned
    /// source; both transfer to `refreshEnrichTask` → the `enrichment_refreshed`
    /// event. Accounted through `enrich_refresh_drain` (ROD-179 shape). Best effort:
    /// a failed dupe or spawn just skips the refresh.
    fn fireRefreshEnrich(self: *App, loop: *Loop, io: std.Io, source: []const u8, source_id: []const u8, rec: AnimeRecord) void {
        const gpa = self.gpa;
        // seed_rec's strings are arena-owned and die when fireEpisodesForId returns,
        // so the stub gets its own GPA copies (freed by freeOwnedAnime on the event).
        const id = gpa.dupe(u8, source_id) catch return;
        const name = gpa.dupe(u8, rec.title) catch {
            gpa.free(id);
            return;
        };
        const src = gpa.dupe(u8, source) catch {
            gpa.free(id);
            gpa.free(name);
            return;
        };
        const english: ?[]const u8 = if (rec.title_english) |e| (gpa.dupe(u8, e) catch null) else null;
        const stub: Anime = .{
            .id = id,
            .name = name,
            .english_name = english,
            .anilist_id = if (rec.anilist_id) |x| std.math.cast(u64, x) else null,
        };
        // ROD-268 known residual (accepted, not fixed): a row with a stored
        // anilist_id takes the exact enrichById path above. A row WITHOUT one still
        // title-matches on refresh, and this stub carries eps_sub/eps_dub=0 — so
        // bestMatch's episode-count disambiguation guard (anilist.zig candidateScore)
        // is skipped, weakening the match for precisely the id-less rows. Carrying
        // stored episode counts into the stub would restore the guard; deferred as a
        // follow-up since it only bites the shrinking set of never-matched rows.

        self.enrich_refresh_drain.begin();
        const t = std.Thread.spawn(.{}, workers.refreshEnrichTask, .{
            loop, gpa, io, stub, src, &self.enrich_refresh_drain,
        }) catch {
            self.enrich_refresh_drain.finish(); // no worker will run — rebalance
            freeOwnedAnime(gpa, stub);
            gpa.free(src);
            return;
        };
        t.detach();
    }

    /// The provider that owns the episode pane's show (ROD-343). `for_source` is
    /// captured at fire time, so a late async failure names the right source even
    /// after nav moved on. Default provider before any fetch exists, or when the
    /// row's source is no longer registered (a retired provider's rows fetch on
    /// the default rather than dead-ending).
    fn owningProvider(self: *const App, registry: Registry) SourceProvider {
        const src = self.episodes.for_source orelse return registry.primary();
        return registry.byName(src) orelse registry.primary();
    }

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

    /// Re-cache everything the rail holds per open show (pin + provider
    /// availability). The one funnel every grid open routes through, so the two
    /// caches can't drift onto different shows (ROD-345/348).
    fn refreshShowMeta(self: *App, aid: ?i64) void {
        self.refreshShowPin(aid);
        self.refreshShowProviders(aid);
    }

    /// Re-cache `show_avail` for the show identified by `aid` (ROD-348).
    /// Best-effort like the pin: a store error reads unchecked, which renders
    /// as `?`. No store at all leaves the aid null, omitting the field, since
    /// an all-`?` line would claim a knowable state nothing can ever refresh.
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

    /// A bind or absence verdict just landed for `anilist_id`: when that is the
    /// show on screen, fold it into the cached rail snapshot so the Provider
    /// field tracks pre-warm/resolve traffic live (ROD-348).
    fn noteAvailabilityWrite(self: *App, anilist_id: i64) void {
        const aid = self.show_avail_aid orelse return;
        if (aid == anilist_id) self.refreshShowProviders(aid);
    }

    /// Re-cache `show_pin` for the show identified by `aid` (ROD-345). Best-effort:
    /// a store error or OOM leaves it null, which renders as unpinned. The pin
    /// itself is authoritative in the DB; this copy only feeds the rail.
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

    /// `count_hint` (ROD-359): the canonical's expected episode count for a
    /// provider with no listing endpoint (megaplay), from a caller that holds
    /// the canonical (a resolve verdict's `sel`, a walk's `canonical`). Null
    /// derives it from the seed record below, which covers every open of an
    /// already-persisted binding; only a virgin resolve has no row to read.
    fn fireEpisodesForId(self: *App, loop: *Loop, io: std.Io, registry: Registry, source_id: []const u8, origin: ?[]const u8, count_hint: ?u32) void {
        // ROD-179: do NOT join a prior in-flight episode fetch here — that would
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
        self.clearFallback();
        self.play_resolve_aid = null;
        // ROD-329: clears the sentinel flag; a populated grid must never render "no source
        // available" (the History gate re-sets it, this fetch never runs for a sentinel row).
        self.episodes.unbound = false;

        // ROD-130: a synchronous LRU/DB hit opens the pane instantly — no thread.
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
        // ROD-182: opening a show is the refresh-on-view trigger — re-enrich it when
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
        // `loading` is set only once the spawn is committed below — an OOM in this
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
            self.episode_drain.finish(); // no worker will run — rebalance the count
            self.gpa.free(id_for_task);
            self.episodes.loading = false;
            return;
        };
        t.detach();
    }

    /// How a Browse selection resolves to a playable provider id (ROD-328, generalizing
    /// ROD-327's inline tier-A into the provider-agnostic resolver). An unresolved AniList
    /// hit is marked by `id == stringified anilist_id` (`metaToAnime`'s convention).
    pub const ResolveVerdict = union(enum) {
        /// Already provider-keyed (History origin, or not an AniList hit): fetch
        /// `id` as-is, no binding.
        direct: []const u8,
        /// Tier 0: this canonical is already bound on `provider` (a prior resolve
        /// persisted the row), so reuse the stored provider id. No probe, no search, no
        /// re-bind. `anilist_id` is carried only for symmetry; the binding already exists.
        bound: struct { provider: SourceProvider, id: []const u8, anilist_id: i64 },
        /// Tier A: `provider` keys its own catalog by a canonical id, so it handed
        /// back its opaque id (`canonicalKey`). The episode fetch confirms it stocks the
        /// show, then the binding is minted to `anilist_id`.
        tier_a: struct { provider: SourceProvider, id: []const u8, anilist_id: i64 },
        /// Tier C: no provider id-keys on this canonical, so a title search must
        /// recover an id (the search worker walks the registry itself). Carries the
        /// `anilist_id` to bind once the search + episode fetch land (ROD-328).
        needs_search: i64,
    };

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
    pub fn browseResolveTarget(registry: Registry, preferred: []const u8, sel: Anime, store: ?*Store, scratch: Allocator) ResolveVerdict {
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
        self.clearFallback();
        self.play_resolve_aid = null;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        // The selection is the canonical entity (fully enriched on the AniList
        // paths), so it carries the count hint for listing-less providers.
        const hint = domain.expectedEpisodeCount(sel);
        switch (browseResolveTarget(registry, self.effectivePreference(arena.allocator(), canonicalAid(sel)), sel, self.store, arena.allocator())) {
            .direct => |id| self.fireEpisodesResolved(loop, io, registry, null, id, null, hint),
            // Tier 0: the binding already exists, so fetch by the stored id with no re-bind.
            .bound => |b| self.fireEpisodesResolved(loop, io, registry, b.provider.name(), b.id, null, hint),
            .tier_a => |t| self.fireEpisodesResolved(loop, io, registry, t.provider.name(), t.id, t.anilist_id, hint),
            .needs_search => |aid| self.fireResolvePlaySearch(loop, io, registry, sel, aid),
        }
    }

    /// Browse's Enter/l entry into `fireEpisodesCanonical`: resolve the list selection.
    pub fn fireEpisodesBrowse(self: *App, loop: *Loop, io: std.Io, registry: Registry) void {
        const sel = selection.selectedAnime(self) orelse return;
        self.fireEpisodesCanonical(loop, io, registry, sel);
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
        self.fireEpisodesForId(loop, io, registry, id, origin, count_hint);
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
        const providers = self.orderedSearchProviders(gpa, registry, self.effectivePreference(pref_arena.allocator(), anilist_id), anilist_id) catch {
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

    /// ROD-346: one provider-fallback walk (see the `fallback` field doc for the
    /// lifecycle). Provider-major, per the ticket: each remaining provider gets its
    /// full tier-0 → tier-A → tier-C shot before the next is tried, in effective
    /// order. The initial resolve stays tier-major (ROD-343, don't re-open); this
    /// walk only runs once that resolve's provider has already failed.
    pub const Fallback = struct {
        /// gpa-owned deep copy of the canonical entity: the fuel for
        /// `canonicalKey` and the tier-C title search.
        canonical: Anime,
        anilist_id: i64,
        /// Effective-order snapshot at walk creation, gpa-owned (mirrors the
        /// tier-C worker: a preference change mid-walk must not reshuffle it).
        providers: []SourceProvider,
        /// providers[0..next) are consumed; monotonic, so every provider is
        /// attempted at most once per walk. That bound is the whole probe budget.
        next: usize = 0,
        /// Bitmask over providers[]: entries that already failed BEFORE the walk
        /// reached them (the provider whose failure created the walk).
        tried: u16 = 0,
        /// Play continuation (ROD-346): once a hop's grid lands, re-land this
        /// episode and relaunch. Raw label is gpa-owned; `ordinal` (1-based) is
        /// the positional fallback when the hop provider labels episodes
        /// differently. Null for a plain episode-fetch walk.
        play: ?PlayCont = null,
        /// ROD-347: a user-armed walk (the 'v' pin flip) probes through a fresh
        /// absence verdict instead of skipping on it; an explicit flip is the
        /// override, and its re-probe refreshes or clears the cached negative.
        manual: bool = false,

        pub const PlayCont = struct { episode_raw: []const u8, ordinal: u32 };

        fn deinit(self: *Fallback, gpa: Allocator) void {
            workers.freeOwnedAnime(gpa, self.canonical);
            gpa.free(self.providers);
            if (self.play) |cont| gpa.free(cont.episode_raw);
        }
    };

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

    /// ROD-229's demote, shared by every "the auto-resume landing dead-ended" site
    /// (episodes_error, and the walk's tier-C exhaustion in resolve_play_target):
    /// back to History rather than a stranded blank pane. No-op unless pending.
    fn demoteResumeLanding(self: *App) void {
        if (!self.resume_landing_pending) return;
        self.active_view = .history;
        self.active_pane = .list;
        self.resume_landing_pending = false;
    }

    /// Persist a resolve walk's definitive per-provider misses into the ROD-347
    /// negative cache. Best-effort: a missing canonical row FK-fails the insert
    /// (nothing to key the verdict on) and is logged, never surfaced. The cache
    /// is an optimization; no user path may fail on it.
    fn persistProviderAbsences(self: *App, anilist_id: i64, names: []const []const u8) void {
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

    /// Minimum spacing between pre-warm walk starts, app-wide (see
    /// `prewarm_last_start_ms`). Generous against the replay drip, small enough
    /// that a short add-burst's later shows still warm on their first play.
    const prewarm_spacing_ms: i64 = 30_000;

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
    fn firePrewarm(self: *App, loop: *Loop, io: std.Io, registry: Registry, anilist_id: i64) void {
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
            self.markPrewarmAttempted(anilist_id);
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
        self.markPrewarmAttempted(anilist_id); // only a walk that actually ran counts
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
        const providers = registry.orderedAlloc(self.gpa, self.effectivePreference(arena.allocator(), aid)) catch {
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
        if (self.fallback == null and !self.beginFallback(registry, pending_aid)) return false;
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
                self.fireFallbackFetch(loop, io, registry, walk, p, sid, null, failed_name);
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
                self.fireFallbackFetch(loop, io, registry, walk, p, key, walk.anilist_id, failed_name);
                return true;
            }
            // Tier C: single-provider title search; its miss advances the walk again
            // via `.resolve_play_target`. A failed spawn counts as tried, keep walking.
            if (self.spawnFallbackSearch(loop, io, p, walk.canonical, walk.anilist_id, failed_name)) {
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
    fn fireFallbackFetch(self: *App, loop: *Loop, io: std.Io, registry: Registry, walk: Fallback, p: SourceProvider, id: []const u8, bind: ?i64, failed_name: ?[]const u8) void {
        self.toastFallbackHop(p, failed_name);
        const landing = self.resume_landing_pending;
        self.fireEpisodesResolved(loop, io, registry, p.name(), id, bind, domain.expectedEpisodeCount(walk.canonical));
        self.resume_landing_pending = landing and self.episodes.loading;
        self.fallback = walk;
        // A synchronous cache hit already landed the grid: no episodes_done will
        // come, so the walk completes (or retires) here.
        if (!self.episodes.loading) self.completeFallback(loop, io, registry);
    }

    /// The walk's grid landed (ROD-346). A plain episode walk just retires. A play
    /// continuation re-lands the failed episode on the hop provider and relaunches;
    /// the walk STAYS ARMED across that relaunch, so a stream that fails on this
    /// provider too advances the SAME walk. That is the relaunch chain's bound:
    /// each provider gets at most one shot per walk, never a ping-pong of fresh
    /// walks between two broken providers.
    fn completeFallback(self: *App, loop: *Loop, io: std.Io, registry: Registry) void {
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
        self.firePlay(loop, io, registry);
    }

    /// ROD-346 play surface: a stream that never opened (`isMeaningful` false on the
    /// final position) hops the walk. A relaunch failure advances the walk the last
    /// hop left armed; a first failure builds a fresh one from the played binding.
    /// Takes ownership of `episode_raw` on every path. Returns true when a hop is in
    /// flight (the caller suppresses the failure toast).
    fn advancePlayFallback(self: *App, loop: *Loop, io: std.Io, registry: Registry, episode_raw: []const u8, ordinal: u32) bool {
        if (self.fallback) |*w| {
            if (w.play != null) {
                // Same episode, standing walk: the fresh dupe is redundant. firePlay's
                // `playing` guard structurally prevents a different episode starting
                // while the relaunch is in flight; assert that non-local proof here.
                std.debug.assert(std.mem.eql(u8, w.play.?.episode_raw, episode_raw));
                self.gpa.free(episode_raw);
                return self.advanceFallback(loop, io, registry, null, self.owningProvider(registry).displayName());
            }
            // An episode walk without a play continuation can't own a play failure.
            self.clearFallback();
        }
        if (!self.beginFallback(registry, null)) {
            self.gpa.free(episode_raw);
            return false;
        }
        self.fallback.?.play = .{ .episode_raw = episode_raw, .ordinal = ordinal };
        return self.advanceFallback(loop, io, registry, null, self.owningProvider(registry).displayName());
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
        self.toastFallbackHop(p, failed_name);
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

    /// ROD-229: index of the show to resume — the most-recently-watched row, i.e.
    /// the first with a non-null `last_watched_at`. `loadHistory` sorts those rows
    /// first (DESC NULLS LAST), so this is normally index 0; the scan keeps it
    /// correct even if that ORDER BY ever changes. null when nothing was ever
    /// played (every row's `last_watched_at` is null, or history is empty). Pure —
    /// drives `maybeResumeLanding` and is unit-tested without a tty.
    pub fn resumeTargetIndex(self: *const App) ?usize {
        return for (self.history, 0..) |rec, i| {
            if (rec.last_watched_at != null) break i;
        } else null;
    }

    /// ROD-229: on the INITIAL history load, when `landing = "last_watched"`, open
    /// the most-recently-watched show's detail pane parked on its resume episode.
    /// One-shot (the `resume_landing_done` guard). Falls back to the History view
    /// when there is nothing to resume. The grid seed (`seedHistoryCursor`) plants
    /// the resume cursor on arrival; a failed grid fetch demotes via
    /// `resume_landing_pending` (see the `episodes_error` handler). Called after
    /// the initial `setHistory`, so a no-resume case simply leaves us on History
    /// (where the ROD-228 startup map already put `.last_watched`).
    fn maybeResumeLanding(self: *App, loop: *Loop, io: std.Io, registry: Registry) void {
        if (self.resume_landing_done) return;
        self.resume_landing_done = true;
        if (self.config.landingEnum() != .last_watched) return;

        const idx = self.resumeTargetIndex() orelse return;
        const rec = self.history[idx];
        // `list_cursor` is a grouped/filtered ENTRY ORDINAL, not a self.history
        // index — the History list is grouped by status (§5.4), so the two spaces
        // diverge whenever the most-recent show isn't in the first group. Map the
        // record to its cursor ordinal so the seeded highlight, the detail meta
        // (resolved via recordAtCursor) and the episode grid all land on the same
        // show. (`resumeTargetIndex` picks the record; `ordinalOf` places it.)
        const ordinal = history.ordinalOf(self, rec.source, rec.source_id) orelse return;
        self.list_cursor = ordinal;
        // Open whichever surface actually SHOWS the episode grid at this width —
        // the grid parked on the resume episode is the whole point. The two-pane
        // detail renders the in-pane grid at any two-pane width now (ROD-259), so
        // >= pane_split_min focuses the pane; below that (single column, no pane)
        // the full-screen zoom is the only grid surface. The spawn-failure call
        // site runs before the first layout(), so term_cols is 0 there → the zoom
        // branch, the correct single-surface fallback.
        if (self.term_cols >= pane_split_min) {
            self.active_pane = .detail;
            self.fireEpisodesForHistoryRecord(loop, io, registry, rec);
        } else {
            self.openHistoryZoom(loop, io, registry, rec);
        }
        // Arm the demote-on-failure only when the open actually started an async
        // fetch — a synchronous cache hit already has the grid, so there is nothing
        // to fall back from. (`fireEpisodesForId` clears the flag at entry, so this
        // assignment is the authoritative arm.)
        self.resume_landing_pending = self.episodes.loading;
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
            self.clearFallback();
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
            self.fireEpisodesForId(loop, io, registry, sid, pin, null);
            return;
        }
        // A real binding: the normal fetch, which clears `unbound` at entry.
        self.fireEpisodesForId(loop, io, registry, rec.source_id, rec.source, null);
    }

    /// ROD-170: open the full-screen zoom directly on a history record + fetch its
    /// episodes. Used below pane_split_min, where there is no two-pane to focus
    /// into, so the zoom is the only detail surface (the grid lives there).
    pub fn openHistoryZoom(self: *App, loop: *Loop, io: std.Io, registry: Registry, rec: AnimeRecord) void {
        self.detail_origin = .history;
        self.active_view = .detail;
        self.active_pane = .detail;
        self.fireEpisodesForHistoryRecord(loop, io, registry, rec);
    }

    /// ROD-194: open the full-screen zoom directly from the Browse list — the
    /// Browse twin of openHistoryZoom. Below pane_split_min there is no detail pane
    /// to focus into, so Enter/Space must reach the grid via the zoom (otherwise
    /// they only flip active_pane to a pane that isn't drawn — the regression).
    pub fn openBrowseZoom(self: *App, loop: *Loop, io: std.Io, registry: Registry) void {
        if (self.search.results.items.len == 0) return;
        self.detail_origin = .browse;
        self.active_view = .detail;
        self.active_pane = .detail;
        self.fireEpisodesBrowse(loop, io, registry);
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
        // borrow contract, see PlaybackSession.source). An unregistered (retired)
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
                if (rec.anilist_id) |aid| self.firePrewarm(loop, io, registry, aid);
            }
        }
    }

    /// Fire the next feed page when the grid cursor comes within ~2 card-rows of
    /// the end, unless the axis is exhausted, already loading, or unfetched. The
    /// page-> 1 tick arm appends (not clears) for page > 1, so the grid grows in
    /// place; `hasNextPage` false sets `exhausted` and stops this (ROD-239 load-more).
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

    /// Pure fill decision (ROD-272): the loaded feed covers the visible grid once
    /// it reaches `(rows_visible + 1) * cols` cards — the visible rows plus one peek
    /// row, matching pumpDiscoverCovers' fetch span so a filled grid also seeds the
    /// peek band. Returns true when the slot is short of that and a page should fire.
    /// Split from maybeFillDiscover so the geometry→target math is unit-testable with
    /// no live fetch. A zero-row grid (too-small terminal) never needs a fill (cols is
    /// `@max(1, …)`, never 0 — the cols guard is defensive parity with the cover pump).
    fn discoverNeedsFill(len: usize, geo: discover_view.Geometry) bool {
        if (geo.cols == 0 or geo.rows_visible == 0) return false;
        const target = (@as(usize, geo.rows_visible) + 1) * @as(usize, geo.cols);
        return len < target;
    }

    /// Whether the fill pass may fire for a slot in this state (ROD-272): an established
    /// feed (page > 0; page 1 is refreshDiscover's to own), idle (not loading), not
    /// exhausted, and not failed. The `failed` gate is what prevents a retry storm: a
    /// fill-fired page that errors sets `slot.failed` and wakes the loop (.discover_feed_error),
    /// so without it this every-frame pass would re-fire as fast as the fetch can fail. A
    /// later successful page (a user scroll re-fires the prefetch, clearing `failed`)
    /// resumes the fill; until then the grid degrades to under-filled, the pre-ROD-272
    /// graceful-degradation floor rather than a retry storm.
    fn discoverFillEligible(loading: bool, exhausted: bool, failed: bool, page: u32) bool {
        return page > 0 and !loading and !exhausted and !failed;
    }

    /// Top the active Discover axis up to the visible grid (ROD-272). The feed
    /// paginates in fixed `discover_page_size` chunks, so on a large monitor the first
    /// page leaves empty rows below the last card, and the cursor-proximity prefetch only
    /// fires once the cursor nears the end (on load it sits at 0). This fires the next
    /// page whenever the loaded set doesn't cover the visible rows (+ peek row), cascading
    /// page-by-page until the grid is full or the feed is exhausted. Called every frame
    /// with settled geometry, so it also refills after a resize. The state guard
    /// (discoverFillEligible) keeps one page in flight and backs off on a failed page, so
    /// a flaky feed can't turn this every-frame pass into a retry storm.
    fn maybeFillDiscover(self: *App, loop: *Loop, io: std.Io) void {
        if (self.active_view != .discover) return;
        const slot = self.discover.activeSlot();
        if (!discoverFillEligible(slot.loading, slot.exhausted, slot.failed, slot.page)) return;

        const w = self.term_cols;
        const visible: u16 = if (self.term_rows >= 4 and w >= 16) self.term_rows - 3 else 0;
        const cp = self.cellPx();
        const geo = discover_view.geometry(w, visible, cp[0], cp[1]);
        if (discoverNeedsFill(slot.results.items.len, geo)) {
            self.fireDiscoverFeed(loop, io, self.discover.axis, slot.page + 1);
        }
    }

    /// Switch the active feed axis and cache-or-fetch it (ROD-239). Resets the
    /// grid cursor/scroll; a no-op if already on `axis`.
    pub fn setDiscoverAxis(self: *App, axis: anilist.DiscoverAxis, loop: *Loop, io: std.Io) void {
        if (self.discover.axis != axis) {
            self.discover.axis = axis;
            self.discover.cursor = 0;
            self.discover.scroll = 0;
        }
        // Cache-or-fetch — also the retry path: a failed/stale slot refetches, a
        // fresh one is a no-op, so re-selecting the current axis retries it (§9.3b).
        self.refreshDiscover(loop, io);
    }

    /// P-add for a canonical-capable selection (ROD-327/328), shared by Browse and
    /// Discover (ROD-336): dispatches Add through the same resolver as the episode
    /// fetch (`browseResolveTarget`). `.tier_a` fires the async probe; `.needs_search`
    /// fires the tier-C title search; both mint the binding on success. `.direct` (an
    /// already provider-keyed row) adds synchronously.
    pub fn addSelectedCanonical(self: *App, loop: *Loop, io: std.Io, registry: Registry, anime: Anime) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        switch (browseResolveTarget(registry, self.effectivePreference(arena.allocator(), canonicalAid(anime)), anime, self.store, arena.allocator())) {
            // No resolve happened (already provider-keyed): the default provider owns it.
            .direct => self.addToWatchlist(registry.primary(), anime),
            // Tier 0: the binding already exists, so reveal it in place (no probe/search).
            .bound => |b| self.revealBoundFromBrowse(loop, io, registry, b.provider, b.id, b.anilist_id),
            .tier_a => |t| self.fireResolveAdd(loop, io, t.provider, t.id, t.anilist_id),
            .needs_search => |aid| self.fireResolveAddSearch(loop, io, registry, anime, aid),
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
        self.firePrewarm(loop, io, registry, anilist_id); // ROD-351: warm the siblings
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
        const providers = self.orderedSearchProviders(gpa, registry, self.effectivePreference(pref_arena.allocator(), anilist_id), anilist_id) catch {
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
    fn fireResolveAddWiden(self: *App, loop: *Loop, io: std.Io, registry: Registry, anilist_id: i64, failed_source: []const u8) bool {
        if (self.add_resolving) return false;
        const st = self.store orelse return false;
        const gpa = self.gpa;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const rec = (st.getCanonicalByAnilistId(arena.allocator(), anilist_id) catch null) orelse return false;
        const all = registry.orderedAlloc(gpa, self.effectivePreference(arena.allocator(), anilist_id)) catch return false;
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
        // yet — flag a background reload so it surfaces in History this session,
        // not just after a restart.
        self.history_dirty = true;
        self.pushToast(.success, "added to watchlist", false);
    }

    // ── draw: pure render from state ─────────────────────────────────────────
    fn draw(self: *App, vx: *vaxis.Vaxis, writer: *std.Io.Writer) !void {
        self.cover.flushPendingFree(vx, writer);
        // ROD-243: the grid covers' image lifecycle needs vx+writer on the UI thread,
        // so it runs here (the const view pass only reads slot.image and places it).
        // Release evicted/superseded grid images, then transmit any newly-decoded
        // covers while Discover is showing.
        self.discover_covers.flushPendingFrees(vx, writer);
        if (self.active_view == .discover) self.discover_covers.ensureImages(self.gpa, vx, writer);

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

        // ROD-286: the connect modal draws on top of everything — it's a captured
        // overlay, so nothing beneath it should read as interactive.
        if (self.connect != null) connect_view.draw(self, win, w, h);

        // Service a pending `[c] copy` here — draw owns the tty, and OSC 52 is a
        // control write separate from the cell buffer, so it rides the same writer as
        // render. Best-effort: over tmux/SSH the terminal may drop it, but the URL is
        // on screen to select by hand, and the "copied" hint reflects the request, not
        // a confirmation we can't get.
        if (self.connect) |*cs| {
            if (cs.copy_requested) {
                cs.copy_requested = false;
                vx.copyToSystemClipboard(writer, cs.listener.url, self.gpa) catch {};
                cs.copied = true;
            }
        }

        try vx.render(writer);
    }

    /// Width (in cols) at and above which a list view grows a persistent
    /// right-side detail pane, mirroring the Browse split. ROD-170 lowered this
    /// from 100 to 60 and unified Browse + History onto it: both views show the
    /// two-pane preview from 60 cols up. Below it, a single full-width list.
    /// ROD-259 made it the single detail-surface threshold: detail focus carries
    /// the in-pane grid at every two-pane width (the old zoom_min=100 grid gate,
    /// which withheld it from History at 60-99, is retired).
    pub const pane_split_min: u16 = 60;

    /// How long a fetched feed axis stays fresh in the in-memory cache (ROD-239).
    /// Re-opening Discover or flipping back to an axis within this window renders
    /// the cached slot with no network; past it, the slot refetches. "hour'ish" per
    /// the design steer: a feed isn't real-time, and the rankings move slowly
    /// enough that an hour is invisible to the user.
    pub const feed_ttl_secs: i64 = 3600;

    /// Cursor-settle window (ms) before a cursor-tracked cover preview actually
    /// fetches (ROD-202). Shorter than the 300 ms search debounce on purpose: the
    /// cover is a preview the user watches *while* navigating, so it should feel
    /// responsive on a single step, yet still collapse a held-key turbo scroll
    /// (key repeat ~30 ms) into one fetch at the settle instead of one per row.
    /// The 100 ms tick is the real floor, so this lands ~150–250 ms after settle.
    pub const cover_settle_ms: i64 = 150;

    /// Settle window (ms) before an action-triggered AniList push fires (ROD-291).
    /// Long compared with the cover/search debounces on purpose: a push is a paced
    /// network side-rail, not a preview, so coalescing a binge (finish ep 3→4→5 in
    /// quick succession → one flush, not three) matters more than latency. The user
    /// never waits on it, so a few seconds of settle is free.
    pub const sync_flush_settle_ms: i64 = 3000;

    /// Wall-clock ceiling (ms) for the best-effort push on quit (ROD-294). Bounded so a
    /// dead/slow AniList socket can never hang the ROD-232 fast-exit; whatever hasn't
    /// landed stays dirty and re-flushes next launch. Sized to ~one row: `sync.pushAll`
    /// paces 2 s between rows (MIN_INTERVAL), so this lands the freshest dirty row and
    /// bounces rather than stalling quit on a backlog — a safety net, not a bulk flush.
    /// This is the policy (how long); `workers.pushOnQuit` owns the wait mechanism.
    pub const quit_push_deadline_ms: i64 = 2000;

    pub const PaneSplit = struct { list_w: u16, detail_x: u16, detail_w: u16 };

    /// The §3.2 list/detail column split: a 38% list column (min 30 cols), a
    /// 2-cell gap after a 2-cell left margin, and the detail pane taking the
    /// remainder. Shared by the Browse and (wide) History arms of drawContent.
    pub fn paneSplit(w: u16) PaneSplit {
        const list_w: u16 = @max(30, (w * 38) / 100);
        const detail_x: u16 = 2 + list_w + 2;
        const detail_w: u16 = if (w > detail_x + 1) w - detail_x - 1 else 0;
        return .{ .list_w = list_w, .detail_x = detail_x, .detail_w = detail_w };
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
                // ROD-170: History is a persistent two-pane like Browse, growing
                // the right-side detail from pane_split_min (60) up — only when a
                // record is focused, so empty/loading/error states keep the
                // full-width single column (which also sidesteps the empty-state
                // centering edge case). Detail focus renders the full drawDetailPane
                // (interactive episode grid) at every two-pane width, matching Browse
                // (ROD-259); list focus keeps the no-grid preview stack — a light
                // glance while navigating. Rendering the grid only on focus also
                // sidesteps stale episodes: the fetch fires on focus, never on cursor move.
                const rec_opt = if (w >= pane_split_min) self.selectedHistoryRecord() else null;
                if (rec_opt) |rec| {
                    const sp = paneSplit(w);
                    // List draws into the full window (absolute coords, 2-col left
                    // margin), but with the narrowed list_w as its effective width
                    // so the meta column / focus band / centering stay inside the
                    // list pane instead of bleeding under the preview.
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
                // Two-column only for History-opened detail (ROD-113 scope); the
                // Browse-opened detail view keeps the single stack.
                detail.drawDetailPane(self, vx, writer, detail_win, body_w, visible, self.detail_origin == .history);
            },

            .settings => settings.drawSettings(self, win, top, visible, w),

            // Discover is full-canvas single-pane (ROD-239): the feed grid owns the
            // whole content area, no pane split.
            .discover => discover_view.draw(self, &self.scratch, win, top, visible, w),
        }
    }

    /// Settle the list viewport against the current terminal geometry.
    ///
    /// This is the *state* half of the scroll seam (ROD-155): it used to live
    /// inside the `view/` draw passes, which made a render pass mutate
    /// `list_top` and silently broke the "draw is a pure function of state"
    /// contract. run() now calls it between tick() and draw(), so the viewport
    /// settles as an explicit state transition and draw() only ever *reads*
    /// `list_top`. `h`/`w` are the full terminal size; the per-view budget math
    /// mirrors drawContent's (content rows = h-3; History packs 2 rows/entry).
    pub fn layout(self: *App, h: u16, w: u16) void {
        // Seed the split-browse/-history width gate from real geometry every
        // frame. run() drains the initial .winsize before tick() sees it, so the
        // .winsize handler alone would leave term_cols at 0 until the first manual
        // resize — and the prefetch would stay inert until then (ROD-156).
        self.term_cols = w;
        self.term_rows = h;
        // Match draw()'s too-small guard: below this there's no viewport to settle.
        if (h < 4 or w < 16) return;
        const visible: u16 = h - 3;
        switch (self.active_view) {
            // History: list_top is a physical-row offset (chrome-aware), so scroll
            // works in physical rows via the renderer's geometry — not the entry
            // units browse uses (ROD-139). Keep the cursor's whole 2-row entry in
            // view, then clamp the tail so we never scroll past the last row.
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
            // Discover: keep the cursor's card-row inside the grid viewport. scroll
            // is a card-row offset; geometry resolves cols + the visible row budget.
            .discover => {
                const cp = self.cellPx();
                const geo = discover_view.geometry(w, visible, cp[0], cp[1]);
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

    /// Whether a History row survives the `/` filter: true when the query is
    /// empty, or when it substring-matches (case-insensitive) ANY of the show's
    /// present title forms — romaji, english, or native. Matching every form, not
    /// just the one currently displayed, keeps a show findable by any of its names
    /// regardless of the `title_language` display preference (ROD-299): a user who
    /// sees the English label can still find it by the romaji, and vice versa.
    /// (`indexOfIgnoreCase` case-folds ASCII only, so native/CJK bytes still match
    /// by exact substring for anyone who types the Japanese name.)
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
    // Empty pool — always room to spawn.
    try testing.expect(!app.discoverPoolSaturated());
    // One below the cap — still room.
    app.discover_drain.inflight.store(App.discover_feed_cap - 1, .release);
    try testing.expect(!app.discoverPoolSaturated());
    // At the cap — drop. `>=`, not `==`, so a live cap decrease that strands
    // inflight above the new cap also reads saturated (same guard as the cover pump).
    app.discover_drain.inflight.store(App.discover_feed_cap, .release);
    try testing.expect(app.discoverPoolSaturated());
    app.discover_drain.inflight.store(App.discover_feed_cap + 5, .release);
    try testing.expect(app.discoverPoolSaturated());
    // Leave the counter balanced — hygiene; this bare App is never torn down.
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

    // A terminal too short to seat even one card-row has no grid to fill — never fetch,
    // whatever the loaded count, so the guard can't spin a fetch on a 0-row viewport.
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

    // A hidden (untracked) cache row never refreshes on view — its own enrich path owns it.
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
    // The stateful guard the every-frame fill pass rides — each blocker must veto
    // on its own; only an all-clear slot fires. Pinned here (not just via the pure
    // geometry math) because this guard is where a refactor regression would land.
    try testing.expect(App.discoverFillEligible(false, false, false, 1)); // all clear → fire
    try testing.expect(!App.discoverFillEligible(false, false, false, 0)); // page 0 is refreshDiscover's
    try testing.expect(!App.discoverFillEligible(true, false, false, 1)); // in flight → debounce
    try testing.expect(!App.discoverFillEligible(false, true, false, 1)); // feed exhausted
    // The review blocker: a failed page must veto, else .discover_feed_error wakes the loop
    // and the fill re-fires as fast as the fetch can fail — an unbounded retry storm.
    try testing.expect(!App.discoverFillEligible(false, false, true, 1));
}
