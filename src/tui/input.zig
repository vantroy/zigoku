//! Key-dispatch layer for the TUI (ROD-361). Carved out of app.zig, which had
//! grown past 5k lines; every feature touch was blowing review context past 1M.
//! These are the pure input handlers — interpret a keypress, mutate nav state,
//! delegate the heavy lifting back to App. They take `self: *App` and call App's
//! pub methods as `self.foo()`, matching the view/*.zig free-function convention.
//!
//! Boundary: only key dispatch lives here. The resolve/fire machinery, the
//! discover-feed pump, connect, and the shared helpers stay on App (the fire*,
//! setDiscoverAxis, pushToast, etc. this file calls) — destined for their own
//! later cuts. onKey is the entry point; run()'s tick dispatches into it.

const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("app.zig");
const App = app_mod.App;

const selection = @import("selection.zig");
const discover_view = @import("view/discover.zig");
const history = @import("view/history.zig");
const workers = @import("workers.zig");

const anilist = @import("../anilist.zig");
const config_mod = @import("../config.zig");
const log = @import("../log.zig");
const source_mod = @import("../source.zig");
const store_mod = @import("../store.zig");

const Loop = @import("event.zig").Loop;
const SourceProvider = source_mod.SourceProvider;
const Registry = source_mod.Registry;

const nowMs = workers.nowMs;

pub fn onKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io, registry: Registry) void {
    // ROD-286: the connect modal is a captured overlay. While it's up it owns esc
    // (cancel) and c (copy URL); every other key is swallowed so nothing switches
    // views mid-connect. Ctrl-C still hard-quits (emergency exit) — its worker is
    // abandoned by the ROD-232 `_exit`, exactly like every other in-flight thread.
    if (self.connect != null) {
        if (key.matches('c', .{ .ctrl = true })) {
            self.should_quit = true;
            return;
        }
        self.onConnectKey(key, io);
        return;
    }

    // Settings owns its keys first (cycle/toggle/edit/save); anything it
    // doesn't consume falls through to the global chain below.
    if (self.active_view == .settings and onSettingsKey(self, key, loop, io)) return;

    // q quits the app — full stop (§10.6, ROD-210), with no back-nav: unlike
    // Esc, q never peels a layer. The `input_mode == .normal` guard keeps a
    // literal "q" typed into a Browse search or History filter from quitting —
    // it falls through to onSearchKey below and appends instead.
    if (self.input_mode == .normal and key.matches('q', .{})) {
        // Settings persists on the way out — the save that used to ride the
        // q → .save_and_exit verdict now rides quit. leaveSettings is a no-op
        // unless the tab is dirty; other views have nothing to flush.
        if (self.active_view == .settings) leaveSettings(self, io);
        self.should_quit = true;
        return;
    }

    // Ctrl-C quit. Like q, it persists a dirty Settings tab on the way out
    // (ROD-210) so an emergency exit doesn't drop just-made changes.
    if (key.matches('c', .{ .ctrl = true })) {
        if (self.active_view == .settings) leaveSettings(self, io);
        self.should_quit = true;
        return;
    }

    // View switching (ROD-249): four destinations, each an F-key alias (F1-F4) and a
    // vim-native letter: F1/B Browse, F2/H History, F3/D Discover, F4/S Settings. The
    // F-keys are global; each letter carries the normal-mode guard so a literal
    // B/H/D/S in a search/filter appends to the query instead of switching. Each is a
    // no-op if already on that view; leaving Settings persists a dirty tab. H is a
    // DIRECT goto, not a toggle. Match shift+letter and bare letter for the same
    // cross-terminal reason as the g/G nav.
    if (key.matches(vaxis.Key.f1, .{}) or
        (self.input_mode == .normal and (key.matches('B', .{ .shift = true }) or key.matches('B', .{}))))
    {
        if (self.active_view != .browse) {
            if (self.active_view == .settings) leaveSettings(self, io);
            self.active_view = .browse;
            self.active_pane = .list;
            self.list_cursor = 0;
            self.list_top = 0;
        }
        return;
    }
    if (key.matches(vaxis.Key.f2, .{}) or
        (self.input_mode == .normal and (key.matches('H', .{ .shift = true }) or key.matches('H', .{}))))
    {
        if (self.active_view != .history) {
            if (self.active_view == .settings) leaveSettings(self, io);
            self.active_view = .history;
            self.active_pane = .list;
            self.list_cursor = 0;
            self.list_top = 0;
        }
        return;
    }
    if (key.matches(vaxis.Key.f3, .{}) or
        (self.input_mode == .normal and (key.matches('D', .{ .shift = true }) or key.matches('D', .{}))))
    {
        if (self.active_view != .discover) {
            if (self.active_view == .settings) leaveSettings(self, io);
            self.active_view = .discover;
            self.active_pane = .list;
            self.list_cursor = 0;
            self.list_top = 0;
            // Cache-or-fetch the active axis on entry: a fresh slot renders
            // instantly, a stale/empty one fires a page-1 fetch (ROD-239).
            self.refreshDiscover(loop, io);
        }
        return;
    }
    if (key.matches(vaxis.Key.f4, .{}) or
        (self.input_mode == .normal and (key.matches('S', .{ .shift = true }) or key.matches('S', .{}))))
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

    // Search mode intercepts every remaining key (including Esc) before the
    // normal-mode chain — onKey owns the normal-vs-search split, onSearchKey
    // owns the query buffer (the ROD-219 verdict glue).
    if (self.input_mode == .search) {
        onSearchKey(self, key, loop, io);
        return;
    }

    // Anything past the globals + search dispatch is normal-mode navigation.
    onNormalListKey(self, key, loop, io, registry);
}

/// Normal-mode (non-search) key dispatch (ROD-218). onKey handles the global
/// keys and routes search-mode keys to onSearchKey before calling this, so
/// normal mode is guaranteed here — the per-block `input_mode == .normal` guards
/// from the original onKey were dropped from the extracted handlers (always true
/// at this call site, and pure noise inside per-intent functions). Delegates to
/// the handlers below; the only inline arm is '/' search-mode entry.
pub fn onNormalListKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io, registry: Registry) void {
    // Discover owns its full normal-mode key set (grid nav, window toggle,
    // Enter→zoom, P, /) — route there before the Browse/History drill+list
    // chain so a discover keypress can never leak into another view's handler.
    if (self.active_view == .discover) {
        onDiscoverKey(self, key, loop, io, registry);
        return;
    }

    // Spatial pane/zoom navigation (ROD-170 focus model). These keys —
    // l/→/Enter, h/←/Esc, Space — are mutually exclusive by keycode, so the
    // order among the three handlers is immaterial.
    if (onDrillKey(self, key, loop, io, registry)) return; // l / → / Enter: drill in / play
    if (onPaneFocusKey(self, key)) return; // h / ← / Esc — peel focus back one layer
    if (onZoomKey(self, key, loop, io, registry)) return; // Space: zoom toggle

    // '/' enters search/filter mode in Browse and History.
    if (key.matches('/', .{})) {
        if (self.active_view == .browse or self.active_view == .history) self.input_mode = .search;
        return;
    }

    // j/k/g/G is shared by the episode grid and the list, so the grid (any
    // focused detail surface) must run before the list-cursor fallthrough.
    // The P/p/x/c/w/r/u actions sit between them, view-gated.
    if (onProviderPinKey(self, key, loop, io, registry)) return; // v: per-show provider pin (ROD-345)
    if (onEpisodeGridKey(self, key)) return; // j/k/g/G — episode grid (detail surfaces)
    if (self.active_view == .history and onHistoryMutationKey(self, key)) return; // p/x/c/w/P/r/u
    if (onBrowseAddKey(self, key, loop, io, registry)) return; // P: add result to watchlist
    onListCursorKey(self, key, loop, io); // j/k/g/G: list cursor + load-more
}

/// Normal-mode keys while Discover is active (ROD-239): axis toggle ([ ] /
/// 1-4) and the 2D grid cursor (hjkl + g/G). Entry/exit ride the global F-key
/// chain in onKey; this intercept owns everything else so a keypress can't leak
/// into the Browse/History handlers.
pub fn onDiscoverKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io, registry: Registry) void {
    // Enter → open the full-screen detail zoom for the selected card, exactly
    // like Browse/History (origin=.discover, so the back-nav returns here).
    // Feed rows are anilist_id-keyed canonical rows (`a.id` is the stringified
    // anilist_id, never a provider id, ROD-336), so the episode fetch routes
    // through the resolver like Browse; a raw fireEpisodesForId(a.id) would hand
    // the play provider an AniList id.
    if (key.matches(vaxis.Key.enter, .{})) {
        if (selection.selectedDiscoverAnime(self)) |a| {
            self.detail_origin = .discover;
            self.active_view = .detail;
            self.active_pane = .detail;
            self.fireEpisodesCanonical(loop, io, registry, a);
        }
        return;
    }
    // P → add the selected card to the watchlist, through the same resolver
    // routing as Browse-P (ROD-336): a direct addToWatchlist would persist a
    // bogus (provider, anilist_id) row.
    if (key.matches('P', .{ .shift = true }) or key.matches('P', .{})) {
        if (selection.selectedDiscoverAnime(self)) |a| self.addSelectedCanonical(loop, io, registry, a);
        return;
    }
    // / → jump to Browse and open its search prompt (the discovery→search seam).
    if (key.matches('/', .{})) {
        self.active_view = .browse;
        self.active_pane = .list;
        self.list_cursor = 0;
        self.list_top = 0;
        self.input_mode = .search;
        return;
    }

    // Axis toggle: [ ] cycle, 1-4 direct select (§3.8). Drives the feed
    // regardless of the grid cursor (the segmented bar is passive).
    if (key.matches(']', .{}) or key.matches('[', .{})) {
        const n = std.meta.fields(anilist.DiscoverAxis).len;
        // Widen to usize BEFORE the arithmetic (ROD-246): `@intFromEnum` infers
        // the enum's minimum tag type — u2 for a 4-member enum. The forward
        // `cur + 1` peer-resolves to u2 (the `comptime_int` 1 carries no width of
        // its own), so it overflows when cur == 3 (this_season) and panics. The
        // backward `cur + n - 1` escaped only because `n` is usize, peer-resolving
        // cur upward; the explicit cast makes both branches do the math in usize.
        const cur: usize = @intFromEnum(self.discover.axis);
        const next = if (key.matches(']', .{})) (cur + 1) % n else (cur + n - 1) % n;
        self.setDiscoverAxis(@enumFromInt(next), loop, io);
        return;
    }
    if (key.matches('1', .{})) return self.setDiscoverAxis(.trending, loop, io);
    if (key.matches('2', .{})) return self.setDiscoverAxis(.popular, loop, io);
    if (key.matches('3', .{})) return self.setDiscoverAxis(.top_rated, loop, io);
    if (key.matches('4', .{})) return self.setDiscoverAxis(.this_season, loop, io);

    // Grid cursor over the active axis's results (flat index; the column
    // count resolves the 2D step). Inert while the slot is empty.
    const len = self.discover.activeSlot().results.items.len;
    if (len == 0) return;
    const cols: usize = discover_view.gridCols(self.term_cols);
    if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
        if (self.discover.cursor + 1 < len) self.discover.cursor += 1;
    } else if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
        if (self.discover.cursor > 0) self.discover.cursor -= 1;
    } else if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        self.discover.cursor = if (self.discover.cursor + cols < len) self.discover.cursor + cols else len - 1;
    } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        self.discover.cursor = if (self.discover.cursor >= cols) self.discover.cursor - cols else 0;
    } else if (key.matches('g', .{})) {
        self.discover.cursor = 0;
    } else if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) {
        self.discover.cursor = len - 1;
    }
    // Prefetch the next page once the cursor nears the grid's end (ROD-239).
    self.maybePrefetchDiscover(loop, io);
}

/// Drill forward (ROD-170 focus model): l/→/Enter reveal+focus the detail pane
/// (lazy-loading the episode grid), play the focused episode, or open the zoom
/// in single-column. Per-view because each surface drills differently. Returns
/// true when `key` is l/→/Enter (consumed). Normal mode only (onKey gates
/// search keys), so no input_mode guard is needed.
pub fn onDrillKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io, registry: Registry) bool {
    if (!(key.matches('l', .{}) or key.matches(vaxis.Key.right, .{}) or key.matches(vaxis.Key.enter, .{}))) return false;
    switch (self.active_view) {
        .browse => {
            if (self.active_pane == .list and self.search.results.items.len > 0) {
                if (self.term_cols >= App.pane_split_min) {
                    // Two-pane: reveal/focus the detail pane + lazy-load the
                    // episode grid (ROD-202). The fetch lands through its own
                    // event; fireEpisodesBrowse's in-flight guard avoids
                    // respawning a fetch already running for this same show.
                    self.active_pane = .detail;
                    self.fireEpisodesBrowse(loop, io, registry);
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    // Single-column (< 60): no pane — Enter opens the zoom
                    // (mirrors History; ROD-194 regression fix). `l`/right
                    // are no-ops here, nothing to focus rightward.
                    self.openBrowseZoom(loop, io, registry);
                }
            } else if (self.active_pane == .detail) {
                // Enter on episode in detail pane: play
                if (key.matches(vaxis.Key.enter, .{})) {
                    self.firePlay(loop, io, registry);
                }
                // l in detail: no-op (already rightmost)
            }
        },
        .history => {
            // ROD-170/ROD-259: l/Enter drills toward the grid, exactly like
            // Browse. The in-pane grid renders wherever the two-pane exists
            // (>= App.pane_split_min); below that the zoom is the only grid surface.
            // History never prefetches (ROD-156), so the fetch fires here on
            // focus, against the just-focused record.
            if (self.active_pane == .list) {
                if (self.selectedHistoryRecord()) |rec| {
                    if (self.term_cols >= App.pane_split_min) {
                        // Two-pane: focus the detail pane + fetch its grid.
                        self.active_pane = .detail;
                        self.fireEpisodesForHistoryRecord(loop, io, registry, rec);
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        // Single-column (< 60): no pane — Enter opens the zoom.
                        self.openHistoryZoom(loop, io, registry, rec);
                    }
                }
            } else if (key.matches(vaxis.Key.enter, .{})) {
                // Detail pane focused: the in-pane grid is present at every
                // two-pane width now (ROD-259) → play the focused episode.
                // Space still promotes to the full-screen zoom for a roomier grid.
                self.firePlay(loop, io, registry);
            }
        },
        .detail => {
            if (key.matches(vaxis.Key.enter, .{})) self.firePlay(loop, io, registry);
        },
        .settings => {},
        // Discover routes its own drill (Enter→zoom) through onDiscoverKey,
        // intercepted before this chain in onNormalListKey; never reached here.
        .discover => {},
    }
    return true;
}

/// Peel focus back one layer (ROD-170 focus model): h/← and Esc both demote a
/// step — zoom → origin pane (or list if there's no room) → list. A base-view
/// list is a no-op (base-view changes go through B/H/D/S + F1-F4; q quits). The
/// two keys share this transition; they stay distinct blocks (verbatim from
/// onKey) rather than dedup, so a behavior change would show as a real diff.
/// Returns true when `key` is h/←/Esc (consumed). Search-mode Esc never reaches
/// here — onSearchKey handles it, dispatched from onKey.
pub fn onPaneFocusKey(self: *App, key: vaxis.Key) bool {
    // h / ← : pane switching (Browse/History) + zoom demote (§10.3c). Left/right
    // arrows mirror h/l for parity with the j/k ↔ up/down list-nav (ROD-156 #1).
    if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
        if (self.active_view == .detail) {
            // ROD-170: from the zoom, h demotes one step (Esc/Space behave the
            // same). q no longer backs out — it quits now (ROD-210).
            // detail_origin carries us back to Browse or History; we land on
            // the pane if there's room, otherwise the list (single-column
            // below pane_split_min).
            self.active_view = switch (self.detail_origin) {
                .browse => .browse,
                .history => .history,
                .discover => .discover, // zoom opened from Discover returns to it
            };
            self.active_pane = if (self.term_cols >= App.pane_split_min) .detail else .list;
        } else if ((self.active_view == .browse or self.active_view == .history) and
            self.active_pane == .detail)
        {
            self.active_pane = .list;
        }
        return true;
    }
    // Esc chain (§10.4, ROD-210): peel exactly one transient layer — never
    // switch the base view.
    if (key.matches(vaxis.Key.escape, .{})) {
        if ((self.active_view == .browse or self.active_view == .history) and
            self.active_pane == .detail)
        {
            // ROD-170: detail pane focused → return focus to the list (= h).
            self.active_pane = .list;
        } else if (self.active_view == .detail) {
            // ROD-170: zoom → demote one step (q quits instead of backing
            // out). Land on the pane if there's room, else the list.
            self.active_view = switch (self.detail_origin) {
                .browse => .browse,
                .history => .history,
                .discover => .discover, // zoom opened from Discover returns to it
            };
            self.active_pane = if (self.term_cols >= App.pane_split_min) .detail else .list;
        }
        // Any base-view list (Browse/History/Settings): no-op. ROD-210 removed
        // the old History/Settings → Browse jump — base-view changes happen
        // only via the B/H/D/S letters (and their F1-F4 aliases). q quits.
        return true;
    }
    return false;
}

/// Space: zoom toggle (ROD-170, §10.2): promote a focused detail pane to the
/// full-screen zoom (the surface that always carries the grid), or demote the
/// zoom back (to the pane if there's room, else the list). At < App.pane_split_min
/// there is no pane, so Space opens the zoom straight from the list (same as
/// Enter). Space is layout-neutral (no Colemak-DH adjacency to p/x/c/w) and
/// toggle-friendly. Returns true when `key` is Space (consumed).
pub fn onZoomKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io, registry: Registry) bool {
    if (!key.matches(vaxis.Key.space, .{})) return false;
    if (self.active_view == .detail) {
        self.active_view = switch (self.detail_origin) {
            .browse => .browse,
            .history => .history,
            .discover => .discover, // zoom opened from Discover returns to it
        };
        self.active_pane = if (self.term_cols >= App.pane_split_min) .detail else .list;
    } else if ((self.active_view == .browse or self.active_view == .history) and
        self.active_pane == .detail)
    {
        // Promote a focused detail pane to the zoom. Works at any two-pane
        // width — the zoom is a roomier grid than the in-pane one, not the
        // only way to reach it (episodes were fetched when the pane took focus).
        self.detail_origin = if (self.active_view == .history) .history else .browse;
        self.active_view = .detail;
    } else if (self.active_view == .history and self.active_pane == .list and
        self.term_cols < App.pane_split_min)
    {
        // Single-column History: no pane to toggle — Space opens the zoom.
        if (self.selectedHistoryRecord()) |rec| self.openHistoryZoom(loop, io, registry, rec);
    } else if (self.active_view == .browse and self.active_pane == .list and
        self.term_cols < App.pane_split_min)
    {
        // Single-column Browse: no pane to toggle — Space opens the zoom
        // (mirrors History; ROD-194 regression fix).
        self.openBrowseZoom(loop, io, registry);
    }
    return true;
}

/// Episode-grid cursor (ROD-170): while any detail surface is focused, j/k/g/G
/// move the episode cursor. Consumes *every* key in that context (returns true)
/// — non-nav keys are inert there, matching the pre-split fallthrough. The grid
/// renders at every two-pane width now (ROD-259), so j/k move a visible cursor
/// whenever episodes are loaded; while they are still loading (ep_len == 0) the
/// keys are inert but still consumed. Returns false when no detail surface is
/// focused, leaving j/k/g/G to onListCursorKey.
/// A focused detail surface: the in-pane grid (Browse/History detail focus)
/// or the full-screen zoom. The gate shared by every grid-scoped key
/// (j/k/g/G nav, the v provider pin) so the surfaces can't drift apart.
pub fn onDetailSurface(self: *const App) bool {
    return (self.active_view == .browse and self.active_pane == .detail) or
        self.active_view == .detail or
        (self.active_view == .history and self.active_pane == .detail);
}

/// ROD-345: 'v' on a detail surface cycles the open show's provider pin:
/// unpinned → each provider in construction order → unpinned. Setting a pin
/// re-routes the grid immediately through a one-provider ROD-346 walk (tier-0
/// sibling binding, else tier-A/tier-C resolve-and-mint): the manual rescue
/// for the bound-but-empty shape the automatic fallback never sees (an
/// authoritative 200-empty grid is not a fetch failure). Clearing a pin only
/// persists; the open grid stands. Runs BEFORE onEpisodeGridKey in dispatch:
/// that handler consumes every key on an empty grid, and empty is exactly the
/// state this key rescues.
pub fn onProviderPinKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io, registry: Registry) bool {
    if (!onDetailSurface(self) or !key.matches('v', .{})) return false;
    const st = self.store orelse return true;
    const src = self.episodes.for_source orelse {
        self.pushToast(.info, "no source: nothing to pin", false);
        return true;
    };
    const fid = self.episodes.for_id orelse return true;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const rec = (st.getAnime(arena.allocator(), src, fid) catch null) orelse {
        // A tier-A probe's row mints only on episodes_done; a flip inside
        // that window has no persisted identity yet. Say so rather than
        // eating the key.
        self.pushToast(.info, "still resolving, try again shortly", false);
        return true;
    };
    const aid = rec.anilist_id orelse {
        self.pushToast(.info, "no canonical identity: can't pin a provider", false);
        return true;
    };

    // Next stop in the cycle: construction order, one past the current pin.
    var order = registry.ordered("");
    var providers_buf: [16]SourceProvider = undefined;
    var count: usize = 0;
    while (order.next()) |p| : (count += 1) {
        if (count >= providers_buf.len) break;
        providers_buf[count] = p;
    }
    const cur = st.getProviderPin(arena.allocator(), aid) catch null;
    var next_idx: usize = 0;
    if (cur) |name| {
        for (providers_buf[0..count], 0..) |p, i| {
            if (std.mem.eql(u8, p.name(), name)) {
                next_idx = i + 1;
                break;
            }
        } else next_idx = count; // unknown (retired) pin cycles to unpinned
    }

    if (next_idx >= count) {
        // Wrap to unpinned: the show returns to the global order.
        st.setProviderPin(aid, null) catch {
            self.pushToast(.@"error", "couldn't clear the provider pin", false);
            return true;
        };
        self.refreshShowPin(aid);
        self.pushToast(.info, "provider pin cleared", false);
        return true;
    }

    const target = providers_buf[next_idx];
    // The pin write needs the canonical row (FK target), and the walk below
    // needs the canonical entity anyway, so resolve it first and gate both.
    const canon_rec = (st.getCanonicalByAnilistId(arena.allocator(), aid) catch null) orelse {
        self.pushToast(.info, "no canonical identity: can't pin a provider", false);
        return true;
    };
    st.setProviderPin(aid, target.name()) catch {
        self.pushToast(.@"error", "couldn't save the provider pin", false);
        return true;
    };
    self.refreshShowPin(aid);

    if (std.mem.eql(u8, target.name(), src)) {
        // Already on the pinned provider: nothing to re-route.
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "pinned to {s}", .{target.displayName()}) catch "provider pinned";
        self.pushToast(.success, msg, false);
        return true;
    }

    // Re-route the open grid through a one-provider ROD-346 walk. The hop
    // toast ("trying X…") is the user feedback; a second "pinned" toast on
    // top would just be noise.
    const canonical = workers.dupeOwnedAnime(self.gpa, selection.animeFromHistoryRecord(canon_rec)) catch return true;
    const providers = self.gpa.alloc(SourceProvider, 1) catch {
        workers.freeOwnedAnime(self.gpa, canonical);
        return true;
    };
    providers[0] = target;
    self.clearFallback();
    self.fallback = .{ .canonical = canonical, .anilist_id = aid, .providers = providers, .tried = 0, .manual = true };
    if (!self.advanceFallback(loop, io, registry, null, null)) {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "couldn't reach {s}", .{target.displayName()}) catch "couldn't switch provider";
        self.pushToast(.warn, msg, false);
    }
    return true;
}

pub fn onEpisodeGridKey(self: *App, key: vaxis.Key) bool {
    if (!onDetailSurface(self)) return false;
    const ep_len: usize = if (self.episodes.results) |eps| eps.len else 0;
    if (ep_len == 0) return true;
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (self.episodes.cursor + 1 < ep_len) self.episodes.cursor += 1;
    } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (self.episodes.cursor > 0) self.episodes.cursor -= 1;
    } else if (key.matches('g', .{})) {
        self.episodes.cursor = 0;
    } else if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) {
        // libvaxis delivers shift+g inconsistently across terminals: some
        // report the 'G' codepoint with .shift set, others report bare 'G'
        // (already-uppercased) with no modifier. Match both so G lands
        // regardless of terminal.
        self.episodes.cursor = ep_len - 1;
    }
    return true;
}

/// Browse P (shift+P): track a not-yet-watched result as planning (ROD-189).
/// upsertAnime's ON CONFLICT preserves list_status/progress/play_count and
/// MAX-merges history_visible, so a brand-new row inserts as planning and a
/// hidden search-cache row (history_visible 0) is revealed (→1) — neither
/// clobbers existing user state. Match shift+'P' and bare 'P' for the same
/// cross-terminal reason as the G nav. Returns true when P is pressed on a
/// focused Browse result (consumed), false otherwise.
pub fn onBrowseAddKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io, registry: Registry) bool {
    if (!(self.active_view == .browse and self.active_pane == .list and
        (key.matches('P', .{ .shift = true }) or key.matches('P', .{})))) return false;
    if (selection.selectedAnime(self)) |anime| self.addSelectedCanonical(loop, io, registry, anime);
    return true; // P is consumed in Browse-list focus whether or not a row is selected
}

/// List-cursor navigation (Browse results + History list): j/k/g/G move the
/// list cursor, and a downward step at the last Browse result pages in the next
/// page (ROD-201 load-more). The tail of onNormalListKey's dispatch — Settings
/// and the zoom have no list here and bail. Reached only after onEpisodeGridKey,
/// so a focused detail surface never lands here (it consumes j/k/g/G first).
pub fn onListCursorKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io) void {
    const nav_len: usize = switch (self.active_view) {
        .history => self.filteredHistoryLen(),
        .browse => self.search.results.items.len,
        // Discover's grid cursor is driven by its own handler (onDiscoverKey),
        // not this list-cursor path; never reached, but the switch is exhaustive.
        .detail, .settings, .discover => return,
    };
    if (nav_len == 0) return;

    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (self.list_cursor + 1 < nav_len) self.list_cursor += 1;
    } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (self.list_cursor > 0) self.list_cursor -= 1;
    } else if (key.matches('g', .{})) {
        self.list_cursor = 0;
    } else if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) {
        // Match both shift+'G' and bare uppercase 'G' (see episode-grid nav
        // above): terminals disagree on whether shift is reported separately.
        self.list_cursor = nav_len - 1;
    }
    // ROD-202: a cursor move never prefetches episodes. The grid loads lazily on
    // detail entry (l/→/Enter → fireEpisodesBrowse), so scrolling the results list
    // stays smooth. The cover preview still tracks the cursor (detailSyncTarget,
    // resolved every frame, not an episode fetch).
    //
    // Load-more: at the last result, a downward keystroke pages in the next page.
    // Must accept Down as well as 'j' (the cursor-nav above honors both, so a j-only
    // trigger left the ╌ more ╌ footer unreachable for arrow users; ROD-201).
    if ((key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) and
        self.active_view == .browse and
        self.list_cursor == nav_len - 1 and
        self.search.page > 0 and
        nav_len % source_mod.search_page_size == 0 and
        !self.search.loading)
    {
        self.fireSearch(loop, io, self.search.page + 1);
    }
}

/// History watch-state cluster (ROD-139/189/193): p paused · x dropped · c
/// completed · w watching · P planning (re-plan) · r recompute-progress · u
/// undo. Returns true when it consumed `key`, so onNormalListKey stops before
/// the list-nav fallthrough; false leaves the key to that nav. Acts on the
/// cursor-focused entry; the grouped view regroups on the next draw. `c` is the
/// bare codepoint — Ctrl-C (quit) is matched earlier in onKey, so no clash.
/// Extracted from onKey verbatim (ROD-218, no behavior change).
pub fn onHistoryMutationKey(self: *App, key: vaxis.Key) bool {
    // ROD-329: r (progress recompute) is frozen on an unbound row because it rebuilds
    // progress from episode_progress rows a sentinel never has, so it would only zero
    // it. p/c/w/P stay live: a user tracking a show watched elsewhere can still mark it
    // watching/completed and have it sync (loadDirtyForSync is source-agnostic). u is
    // NOT gated either: applyUndo keys off the mutation's own row (indexById), not the
    // cursor, so gating it here would block undoing an unrelated row's edit.
    if (key.matches('r', .{})) {
        const on_unbound = if (self.selectedHistoryRecord()) |rec|
            std.mem.eql(u8, rec.source, store_mod.SOURCE_UNBOUND)
        else
            false;
        if (on_unbound) {
            self.pushToast(.info, "no source: nothing to recompute", false);
            return true;
        }
    }
    if (key.matches('p', .{})) {
        self.setSelectedHistoryStatus(.paused);
        return true;
    } else if (key.matches('x', .{})) {
        self.setSelectedHistoryStatus(.dropped);
        return true;
    } else if (key.matches('c', .{})) {
        self.setSelectedHistoryStatus(.completed);
        return true;
    } else if (key.matches('w', .{})) {
        self.setSelectedHistoryStatus(.watching);
        return true;
    } else if (key.matches('P', .{ .shift = true }) or key.matches('P', .{})) {
        // ROD-189: re-plan — the missing 5th manual transition, paired with
        // Browse's P so the key means "plan it" in both views.
        // setSelectedHistoryStatus routes through setListStatus's re-plan path
        // and the undo seam, so it's undoable like p/x/c/w. Match shift+'P' and
        // bare 'P' (terminal compat); lowercase 'p' above is paused — no clash.
        self.setSelectedHistoryStatus(.planning);
        return true;
    } else if (key.matches('r', .{})) {
        // ROD-193: recompute progress from episode_progress rows (strategy A).
        // Non-adjacent to `c` on Colemak-DH; ships as a keybind (not `:reset`)
        // because single-level undo goes stale after any subsequent key.
        const st = self.store orelse return true;
        const idx = history.indexAtCursor(self) orelse return true;
        const rec = &self.history[idx];
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const hw = st.recomputeProgress(arena.allocator(), rec.source, rec.source_id, self.translation) catch |e| {
            log.debug("recomputeProgress failed: {s}", .{@errorName(e)});
            return true;
        };
        rec.progress = hw;
        // r overwrites progress, so a stale undo entry (captured pre-`c`)
        // would revert PAST this recompute on a later `u`. Invalidate it so
        // `c → r → u` keeps the recomputed value (ROD-193 review).
        if (self.undo) |u| {
            u.free(self.gpa);
            self.undo = null;
        }
        self.syncEpisodeProgress(rec.source, rec.source_id, hw);
        self.pushToast(.success, "progress reset", false);
        return true;
    } else if (key.matches('u', .{})) {
        // ROD-193: single-level undo of the last watch-state mutation.
        self.applyUndo();
        return true;
    }
    return false;
}

/// Drive a key into the search prompt and project the controller's verdict
/// (ROD-219, the SettingsState keystone). History view filters the in-memory
/// watchlist — nav state, so it stays here in `onHistoryFilterKey`. Browse
/// drives `SearchController.onKey`, which owns the query + results; App then
/// applies the verdict onto nav mode, the debounce timer, and the fire
/// transport — the three things the controller deliberately never touches.
pub fn onSearchKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io) void {
    // History view: local in-memory filter — no network, no search controller.
    if (self.active_view == .history) return onHistoryFilterKey(self, key);

    const debounce_pending = self.debounce_deadline_ms > 0;
    switch (self.search.onKey(self.gpa, key, debounce_pending)) {
        .ignored => {},
        .edited => self.debounce_deadline_ms = nowMs(io) + 300,
        .cleared => |c| {
            self.debounce_deadline_ms = 0;
            if (c.exit) self.input_mode = .normal;
        },
        .submit => |sub| {
            if (sub.fire) {
                self.debounce_deadline_ms = 0;
                self.fireSearch(loop, io, 1);
            }
            self.input_mode = .normal;
        },
    }
}

/// History view's in-memory watchlist filter (no network). Owns the
/// `history_filter` buffer + the cursor/viewport reset that keeps the
/// selection valid as the filtered set shrinks. Stays on App: this is
/// history/nav state, never search — the search half moved to
/// `SearchController.onKey` when ROD-219 split the fused handler.
pub fn onHistoryFilterKey(self: *App, key: vaxis.Key) void {
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
}

/// Drive a key into the Settings subsystem and project its verdict onto
/// App-live state. Returns true if the key was consumed; false lets it fall
/// through to the global chain (F-keys/H to switch views, q/Ctrl-C to quit;
/// Esc is a no-op in Settings under the ROD-210 contract). The subsystem
/// never touches nav/palette/translation/toasts — it reports *what changed*
/// and the projection lives here, in the controller. Persistence no longer
/// rides a key verdict: it moved to App.leaveSettings (ROD-210).
pub fn onSettingsKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io) bool {
    switch (self.settings.onKey(key, &self.config)) {
        .ignored => return false,
        .consumed => return true,
        .config_changed => {
            // Re-derive the App-live values the settings change projects to.
            // Idempotent for non-projecting fields; the source of truth is
            // `config`, which the subsystem just mutated.
            self.translation = self.config.translationEnum();
            self.palette = app_mod.paletteFromConfig(self.config.palette);
            return true;
        },
        // ROD-286: the connect action row fires the in-TUI OAuth flow. The
        // settings subsystem can't reach `loop`/`io` (by design — it never touches
        // App-live state), so it reports the intent and the controller projects it.
        .connect_requested => {
            self.beginConnect(loop, io);
            return true;
        },
    }
}

/// Persist the live config to disk (ROD-85 `save`), toasting the outcome. Stays
/// on App: it owns `config_path` and the toast queue, neither of which belongs
/// in the settings edit subsystem. Returns true only when the bytes actually
/// landed — both early-outs (no config dir, write error) toast and return false
/// so callers can keep the tab dirty for a retry (ROD-210 M1).
pub fn saveSettings(self: *App, io: std.Io) bool {
    const path = self.config_path orelse {
        self.pushToast(.warn, "no config dir — not saved", false);
        return false;
    };
    config_mod.save(io, self.config, path) catch {
        self.pushToast(.@"error", "settings save failed", false);
        return false;
    };
    self.pushToast(.success, "settings saved", false);
    return true;
}

/// Persist Settings on the way out — a base-view switch (B/H/D or F1/F2/F3) or a quit
/// (q/Ctrl-C). Saves only when the tab is dirty, so tabbing through Settings
/// unchanged neither rewrites the config file nor toasts. ROD-210 moved
/// persistence here off the retired `q → .save_and_exit` verdict. `dirty` is
/// cleared only on a *successful* write — a failed save (no config dir / I/O
/// error) leaves it set, so a later leave/quit retries instead of silently
/// dropping the change (ROD-210 M1, matters on the F-key/H switch-away path).
pub fn leaveSettings(self: *App, io: std.Io) void {
    if (!self.settings.dirty) return;
    if (saveSettings(self, io)) self.settings.dirty = false;
}
