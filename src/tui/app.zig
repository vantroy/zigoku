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
const vaxis = @import("vaxis");
const colors = @import("colors.zig");
const store_mod = @import("../store.zig");
const source_mod = @import("../source.zig");
const domain = @import("../domain.zig");

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
    // Join the last search thread before loop teardown so in-flight threads
    // can't dereference a torn-down loop or gpa. Declared after loop.stop()'s
    // defer so it executes first (Zig defers are LIFO).
    defer if (app.search_thread) |t| t.join();

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
    for (app.results.items) |r| { gpa.free(r.id); gpa.free(r.name); }
    app.results.deinit(gpa);
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

    // Dupe id+name into GPA so they survive arena teardown.
    // Other Anime fields (eps_sub, eps_dub, status, thumb…) are value types or
    // null — copy them as-is. Arena-pointing optional strings (status, thumb…)
    // are omitted so they default to null rather than dangling after arena teardown.
    var owned = std.ArrayListUnmanaged(Anime).empty;
    owned.ensureTotalCapacity(gpa, raw.len) catch {
        gpa.free(query);
        loop.postEvent(.{ .task_error = "search OOM" }) catch {};
        return;
    };
    for (raw) |a| {
        const id_owned = gpa.dupe(u8, a.id) catch continue;
        const name_owned = gpa.dupe(u8, a.name) catch { gpa.free(id_owned); continue; };
        owned.appendAssumeCapacity(.{
            .id = id_owned,
            .name = name_owned,
            .eps_sub = a.eps_sub,
            .eps_dub = a.eps_dub,
        });
    }

    loop.postEvent(.{ .search_done = .{
        .results = owned.items,
        .for_query = query,
        .page = page,
    }}) catch {
        // Post failed — we still own everything; free it all.
        for (owned.items) |r| { gpa.free(r.id); gpa.free(r.name); }
        owned.deinit(gpa); // free the backing array (strings already freed above)
        gpa.free(query);
    };
    // On success: `owned.items` and `query` are now owned by the event.
    // Do NOT call owned.deinit here — that would free the slice the UI thread holds.
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

const App = struct {
    should_quit: bool = false,

    /// Landing data. Backed by run()'s history arena — App only reads it.
    history: []AnimeRecord = &.{},
    history_loading: bool = true,
    /// Set if the background history load failed.
    load_error: ?[]const u8 = null,

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

    /// Sub/dub translation for searches.
    translation: domain.Translation = .sub,

    /// Current query as a slice (may be empty).
    fn querySlice(self: *const App) []const u8 {
        return self.search_query[0..self.search_len];
    }

    /// Free all accumulated search results and reset search state.
    /// Call before a new page-1 search and when Esc clears the query.
    fn clearResults(self: *App) void {
        for (self.results.items) |r| {
            self.gpa.free(r.id);
            self.gpa.free(r.name);
        }
        self.results.clearRetainingCapacity();
        self.search_page = 0;
    }

    fn setHistory(self: *App, recs: []AnimeRecord) void {
        self.history = recs;
        self.history_loading = false;
        if (self.list_cursor >= recs.len) self.list_cursor = if (recs.len == 0) 0 else recs.len - 1;
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
            },
            .search_done => |ev| {
                // Stale check: ignore if query has changed since this search was fired.
                if (!std.mem.eql(u8, ev.for_query, self.querySlice())) {
                    for (ev.results) |r| { self.gpa.free(r.id); self.gpa.free(r.name); }
                    self.gpa.free(ev.for_query);
                    // NOTE: ev.results is a slice into a GPA-allocated backing array.
                    // We freed each element's strings above; now free the backing array itself.
                    self.gpa.free(ev.results);
                    return;
                }
                self.search_loading = false;
                if (ev.page == 1) {
                    self.clearResults(); // free old data
                }
                self.search_page = ev.page;
                // Take ownership: append results into self.results, which already holds
                // old page(s) for page > 1. The strings are already gpa-owned.
                self.results.appendSlice(self.gpa, ev.results) catch {};
                // Free the slice header (but NOT the strings, now owned by self.results).
                self.gpa.free(ev.results);
                self.gpa.free(ev.for_query);
                // Reset cursor to top on fresh search.
                if (ev.page == 1) {
                    self.list_cursor = 0;
                    self.list_top = 0;
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
        self.search_thread = std.Thread.spawn(.{}, searchTask, .{
            loop, self.gpa, io, provider, q_copy, page, self.translation,
        }) catch {
            self.gpa.free(q_copy);
            self.search_loading = false;
            return;
        };
    }

    fn onSearchKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io, provider: SourceProvider) void {
        // Esc: clear query, clear results, return to normal mode.
        if (key.matches(vaxis.Key.escape, .{})) {
            self.search_len = 0;
            self.clearResults();
            self.search_loading = false;
            self.input_mode = .normal;
            return;
        }
        // Enter: lock results, return to normal mode (focus to list).
        if (key.matches(vaxis.Key.enter, .{})) {
            self.input_mode = .normal;
            return;
        }
        // Backspace: pop last char, re-search.
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.search_len > 0) {
                self.search_len -= 1;
                if (self.search_len == 0) {
                    self.clearResults();
                    self.search_loading = false;
                } else {
                    self.clearResults();
                    self.fireSearch(loop, io, provider, 1);
                }
            }
            return;
        }
        // Printable ASCII: append and search.
        if (key.text) |text| {
            if (text.len > 0 and self.search_len + text.len <= 127) {
                @memcpy(self.search_query[self.search_len..][0..text.len], text);
                self.search_len += text.len;
                self.clearResults();
                self.fireSearch(loop, io, provider, 1);
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
            if (self.active_view == .browse) self.active_pane = .list;
            return;
        }
        if (key.matches('l', .{})) {
            if (self.active_view == .browse) self.active_pane = .detail;
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
        // '/' in Browse enters search mode.
        if (key.matches('/', .{})) {
            if (self.active_view == .browse) {
                self.input_mode = .search;
            }
            return;
        }

        // Navigation is active in both history (over history slice) and
        // browse (over results list). Silent no-op in settings.
        const nav_len: usize = switch (self.active_view) {
            .history => self.history.len,
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
        // "possible" = last results page was full (26 items == might have more).
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

        drawTopBar(win, w, self.active_view, self.active_pane);
        self.drawContent(win, h);
        self.drawBottomBar(win, h);

        try vx.render(writer);
    }

    /// §3.4: the top bar is read-only context, not navigation — `地獄 zigoku`
    /// as one primary H1 unit, then a hairline separator. No tabs here: the tab
    /// system + focus model is ROD-72 and needs a designed home (the active-tab
    /// cyan would collide with the focus color if it lived in this bar).
    fn drawTopBar(win: vaxis.Window, w: u16, active_view: @TypeOf(@as(App, undefined).active_view), active_pane: @TypeOf(@as(App, undefined).active_pane)) void {
        put(win, 0, 2, "地獄 zigoku", style(colors.fg, .{ .bold = true }));
        if (w > 16) put(win, 0, 14, "░", style(colors.chrome, .{}));

        // Render the chip after the separator (§10.3b).
        const chip_col: u16 = 16;
        const chip = switch (active_view) {
            .history => "Watchlist",
            .settings => "Settings",
            .browse => "⠋ search",
        };
        const chip_color = switch (active_view) {
            .history, .settings => colors.focus,
            .browse => colors.fg3,
        };
        put(win, 0, chip_col, chip, style(chip_color, .{}));

        // Render the · indicator right-aligned (§10.3b).
        const dot_color = switch (active_view) {
            .browse => if (active_pane == .detail) colors.focus else colors.fg3,
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
                    // Static placeholder; the animated Braille spinner is ROD-76.
                    putClipped(win, top, 2, body_w, "⠋ loading history", style(colors.focus, .{}));
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

                // Keep the cursor inside the viewport.
                self.scrollIntoView(visible);

                // Meta only earns its column when the terminal is wide enough to hold it
                // without colliding the title — otherwise the title takes the full width.
                const show_meta = w >= meta_col + 12;
                const title_right: u16 = if (show_meta) meta_col - title_meta_gap else w;
                const title_w: u16 = if (title_right > title_col) title_right - title_col else 0;

                var row: u16 = top;
                var slot: usize = 0;
                var i: usize = self.list_top;
                while (i < self.history.len and row < top + visible) : (i += 1) {
                    const rec = self.history[i];
                    const selected = i == self.list_cursor;

                    // §4.1 focus affordance: the focused row's background shifts to
                    // bg.surface (a full-width band), its marker is the ▸ play glyph in
                    // focus cyan, and its title goes cyan+bold. Magenta is reserved for
                    // the one cursor in the status bar — never a list marker (§8).
                    const row_bg = if (selected) colors.bg_surface else colors.bg_base;
                    if (selected) fillRow(win, row, w, colors.bg_surface);

                    const marker = if (selected) "▸ " else "  ";
                    put(win, row, 2, marker, style(colors.focus, .{ .bg = row_bg }));

                    const title_style = if (selected)
                        style(colors.focus, .{ .bg = row_bg, .bold = true })
                    else
                        style(colors.fg, .{ .bg = row_bg });
                    // Clipped to its column budget so long titles can't bleed into meta.
                    putClipped(win, row, title_col, title_w, rec.title, title_style);

                    // Format into App-owned scratch (see meta_scratch's note on why a
                    // stack buffer would dangle by render time). Skip if we somehow have
                    // more visible rows than slots.
                    if (show_meta and slot < self.meta_scratch.len) {
                        const meta = formatMeta(&self.meta_scratch[slot], rec);
                        putClipped(win, row, meta_col, w - meta_col, meta, style(colors.fg3, .{ .bg = row_bg }));
                        slot += 1;
                    }

                    row += 1;
                }
            },

            .browse => {
                if (self.search_len == 0) {
                    // Idle: invite the user to search.
                    const mid = top + visible / 2;
                    centerText(win, mid -| 1, w, "no feed yet", style(colors.fg3, .{ .italic = true }));
                    const action = " to start a search";
                    const total: u16 = 1 + @as(u16, @intCast(action.len));
                    const start: u16 = if (w > total) (w - total) / 2 else 0;
                    put(win, mid + 1, start, "/", style(colors.focus, .{ .bold = true }));
                    putClipped(win, mid + 1, start + 1, w -| (start + 1), action, style(colors.fg2, .{}));
                } else if (self.search_loading and self.results.items.len == 0) {
                    // First load spinner.
                    const mid = top + visible / 2;
                    centerText(win, mid, w, "⠋ searching…", style(colors.focus, .{}));
                } else if (!self.search_loading and self.results.items.len == 0) {
                    // No results — top-aligned per §9.3a.
                    const q = self.querySlice();
                    var buf: [160]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "no results for \"{s}\"", .{q}) catch "no results";
                    putClipped(win, top, 2, body_w, msg, style(colors.fg3, .{ .italic = true }));
                } else {
                    // Results list — same row format as history.
                    self.scrollIntoView(visible);
                    const show_meta = w >= meta_col + 12;
                    const title_right: u16 = if (show_meta) meta_col - title_meta_gap else w;
                    const title_w: u16 = if (title_right > title_col) title_right - title_col else 0;

                    var row: u16 = top;
                    var slot: usize = 0;
                    var i: usize = self.list_top;
                    while (i < self.results.items.len and row < top + visible) : (i += 1) {
                        const a = self.results.items[i];
                        const selected = i == self.list_cursor;

                        const row_bg = if (selected) colors.bg_surface else colors.bg_base;
                        if (selected) fillRow(win, row, w, colors.bg_surface);

                        const marker = if (selected) "▸ " else "  ";
                        put(win, row, 2, marker, style(colors.focus, .{ .bg = row_bg }));

                        const title_style = if (selected)
                            style(colors.focus, .{ .bg = row_bg, .bold = true })
                        else
                            style(colors.fg, .{ .bg = row_bg });
                        putClipped(win, row, title_col, title_w, a.name, title_style);

                        if (show_meta and slot < self.meta_scratch.len) {
                            const tt = self.translation;
                            const eps = if (tt == .dub) a.eps_dub else a.eps_sub;
                            const meta = std.fmt.bufPrint(&self.meta_scratch[slot], "{d} {s} eps", .{ eps, tt.str() }) catch "";
                            putClipped(win, row, meta_col, w - meta_col, meta, style(colors.fg3, .{ .bg = row_bg }));
                            slot += 1;
                        }

                        row += 1;
                    }

                    // Load-more footer if we might have more pages.
                    if (row < top + visible and
                        self.search_page > 0 and
                        self.results.items.len % 26 == 0 and
                        self.results.items.len > 0)
                    {
                        const footer = if (self.search_loading) "⠋ loading more…" else "╌  load more  ╌";
                        const footer_color = if (self.search_loading) colors.focus else colors.fg3;
                        centerText(win, row, w, footer, style(footer_color, .{}));
                    }
                }
            },

            .settings => {
                // Settings stub (ROD-75/76 territory).
                const mid = top + visible / 2;
                centerText(win, mid, w, "settings — coming soon", style(colors.fg3, .{ .italic = true }));
            },
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
            var cnt_buf: [16]u8 = undefined;
            const cnt: []const u8 = if (self.search_loading and self.results.items.len == 0)
                "…"
            else if (self.results.items.len > 0)
                std.fmt.bufPrint(&cnt_buf, "[{d}]", .{self.results.items.len}) catch ""
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

        // The signature: a magenta block cursor, terminal-blinked, always alive.
        put(win, row, 2, "▌", style(colors.hot, .{ .blink = true }));

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

    fn scrollIntoView(self: *App, visible: u16) void {
        const v: usize = visible;
        if (self.list_cursor < self.list_top) {
            self.list_top = self.list_cursor;
        } else if (self.list_cursor >= self.list_top + v) {
            self.list_top = self.list_cursor + 1 - v;
        }
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
}) vaxis.Style {
    return .{ .fg = fg, .bg = opts.bg, .bold = opts.bold, .italic = opts.italic, .blink = opts.blink };
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

const dummy_vtable: SourceProvider.VTable = .{
    .search = dummySearchFn,
    .episodes = dummyEpisodesFn,
    .resolve = dummyResolveFn,
};

fn dummyProvider() SourceProvider {
    return .{ .ptr = undefined, .vtable = &dummy_vtable };
}

fn testTick(app: *App, event: Event) !void {
    var loop: Loop = undefined;
    const io: std.Io = undefined;
    try app.tick(event, &loop, io, dummyProvider());
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
    app.active_view = .browse;
    app.active_pane = .list;
    try testTick(&app, keyEv('l', .{}));
    try testing.expectEqual(@as(@TypeOf(app.active_pane), .detail), app.active_pane);
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

test "/ in History is a no-op for search mode" {
    var app: App = .{};
    app.active_view = .history;
    try testTick(&app, keyEv('/', .{}));
    try testing.expectEqual(.normal, app.input_mode);
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

    for (app.results.items) |r| { std.testing.allocator.free(r.id); std.testing.allocator.free(r.name); }
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

    for (app.results.items) |r| { std.testing.allocator.free(r.id); std.testing.allocator.free(r.name); }
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

    for (app.results.items) |r| { std.testing.allocator.free(r.id); std.testing.allocator.free(r.name); }
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
