//! Key-dispatch for the TUI. Free functions taking `self: *App`.
//!
//! Boundary: key dispatch only. Resolve/fire, discover pump, connect, and
//! shared helpers stay on App (or resolve.zig). Entry: onKey from tick.

const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("app.zig");
const resolve = @import("resolve.zig");
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
    // Connect modal captures all keys except Ctrl-C hard-quit.
    if (self.connect != null) {
        if (key.matches('c', .{ .ctrl = true })) {
            self.should_quit = true;
            return;
        }
        self.onConnectKey(key, io);
        return;
    }

    // Settings first; unconsumed keys fall through to the global chain.
    if (self.active_view == .settings and onSettingsKey(self, key, loop, io)) return;

    // Hard-delete confirm: intercept everything so view-switch/nav cannot leak.
    // y/Y execute; re-pressed X is a no-op (key-repeat must not self-confirm);
    // anything else cancels. Ctrl-C still quits.
    if (self.confirm_delete != null) {
        if (key.matches('c', .{ .ctrl = true })) {
            self.should_quit = true;
        } else if (key.matches('y', .{}) or key.matches('Y', .{ .shift = true }) or key.matches('Y', .{})) {
            self.executeDelete();
        } else if (key.matches('X', .{ .shift = true }) or key.matches('X', .{})) {
            // stay armed
        } else {
            self.confirm_delete = null;
        }
        return;
    }

    // q quits, never back-nav. Guarded so a typed "q" in search/filter appends.
    if (self.input_mode == .normal and key.matches('q', .{})) {
        if (self.active_view == .settings) leaveSettings(self, io);
        self.should_quit = true;
        return;
    }

    // Ctrl-C: also flush dirty Settings on the way out.
    if (key.matches('c', .{ .ctrl = true })) {
        if (self.active_view == .settings) leaveSettings(self, io);
        self.should_quit = true;
        return;
    }

    // View switch: F1-F4 and B/H/D/S. Letters need normal mode so search
    // typing does not switch views. Match shift+letter and bare letter
    // (terminals disagree on shift reporting, same as g/G).
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
            self.settings.reset();
            self.input_mode = .normal;
        }
        return;
    }

    if (self.input_mode == .search) {
        onSearchKey(self, key, loop, io);
        return;
    }

    onNormalListKey(self, key, loop, io, registry);
}

/// Normal-mode nav. onKey has already gated globals and search mode.
pub fn onNormalListKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io, registry: Registry) void {
    // Discover owns its full key set: do not leak into Browse/History handlers.
    if (self.active_view == .discover) {
        onDiscoverKey(self, key, loop, io, registry);
        return;
    }

    if (onDrillKey(self, key, loop, io, registry)) return;
    if (onPaneFocusKey(self, key)) return;
    if (onZoomKey(self, key, loop, io, registry)) return;

    if (key.matches('/', .{})) {
        if (self.active_view == .browse or self.active_view == .history) self.input_mode = .search;
        return;
    }

    // Episode grid and list both use j/k/g/G: detail surface must run first.
    // v before onEpisodeGridKey: that handler consumes every key on an empty grid,
    // and empty is the state 'v' rescues.
    if (onProviderPinKey(self, key, loop, io, registry)) return;
    if (onEpisodeGridKey(self, key)) return;
    if (self.active_view == .history and onHistoryMutationKey(self, key)) return;
    if (onBrowseAddKey(self, key, loop, io, registry)) return;
    onListCursorKey(self, key, loop, io);
}

/// Discover normal-mode keys. Feed rows are anilist_id-keyed: episode fetch and
/// Add must go through the resolver, never fireEpisodesForId(a.id) / raw upsert.
pub fn onDiscoverKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io, registry: Registry) void {
    if (key.matches(vaxis.Key.enter, .{})) {
        if (selection.selectedDiscoverAnime(self)) |a| {
            self.detail_origin = .discover;
            self.active_view = .detail;
            self.active_pane = .detail;
            resolve.fireEpisodesCanonical(self, loop, io, registry, a);
        }
        return;
    }
    if (key.matches('P', .{ .shift = true }) or key.matches('P', .{})) {
        if (selection.selectedDiscoverAnime(self)) |a| resolve.addSelectedCanonical(self, loop, io, registry, a);
        return;
    }
    if (key.matches('/', .{})) {
        self.active_view = .browse;
        self.active_pane = .list;
        self.list_cursor = 0;
        self.list_top = 0;
        self.input_mode = .search;
        return;
    }

    if (key.matches(']', .{}) or key.matches('[', .{})) {
        const n = std.meta.fields(anilist.DiscoverAxis).len;
        // Widen to usize before arithmetic: @intFromEnum is u2 for a 4-member
        // enum; cur+1 overflows as u2 when cur == 3.
        const cur: usize = @intFromEnum(self.discover.axis);
        const next = if (key.matches(']', .{})) (cur + 1) % n else (cur + n - 1) % n;
        self.setDiscoverAxis(@enumFromInt(next), loop, io);
        return;
    }
    if (key.matches('1', .{})) return self.setDiscoverAxis(.trending, loop, io);
    if (key.matches('2', .{})) return self.setDiscoverAxis(.popular, loop, io);
    if (key.matches('3', .{})) return self.setDiscoverAxis(.top_rated, loop, io);
    if (key.matches('4', .{})) return self.setDiscoverAxis(.this_season, loop, io);

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
    self.maybePrefetchDiscover(loop, io);
}

/// l/→/Enter: drill into detail, play, or open zoom in single-column.
/// true when the key is l/→/Enter (consumed).
pub fn onDrillKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io, registry: Registry) bool {
    if (!(key.matches('l', .{}) or key.matches(vaxis.Key.right, .{}) or key.matches(vaxis.Key.enter, .{}))) return false;
    switch (self.active_view) {
        .browse => {
            if (self.active_pane == .list and self.search.results.items.len > 0) {
                if (self.term_cols >= App.pane_split_min) {
                    self.active_pane = .detail;
                    resolve.fireEpisodesBrowse(self, loop, io, registry);
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    // Single-column: no pane; Enter opens zoom. l/right are no-ops.
                    resolve.openBrowseZoom(self, loop, io, registry);
                }
            } else if (self.active_pane == .detail) {
                if (key.matches(vaxis.Key.enter, .{})) {
                    resolve.firePlay(self, loop, io, registry);
                }
            }
        },
        .history => {
            // History never prefetches: fetch fires on focus against the just-focused record.
            if (self.active_pane == .list) {
                if (self.selectedHistoryRecord()) |rec| {
                    if (self.term_cols >= App.pane_split_min) {
                        self.active_pane = .detail;
                        resolve.fireEpisodesForHistoryRecord(self, loop, io, registry, rec);
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        resolve.openHistoryZoom(self, loop, io, registry, rec);
                    }
                }
            } else if (key.matches(vaxis.Key.enter, .{})) {
                resolve.firePlay(self, loop, io, registry);
            }
        },
        .detail => {
            if (key.matches(vaxis.Key.enter, .{})) resolve.firePlay(self, loop, io, registry);
        },
        .settings => {},
        // Discover drills via onDiscoverKey, never reached here.
        .discover => {},
    }
    return true;
}

/// h/←/Esc: peel one layer (zoom → origin pane or list → list). Base-view list is a no-op.
/// Search Esc never reaches here (onSearchKey handles it).
pub fn onPaneFocusKey(self: *App, key: vaxis.Key) bool {
    if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
        if (self.active_view == .detail) {
            self.active_view = switch (self.detail_origin) {
                .browse => .browse,
                .history => .history,
                .discover => .discover,
            };
            self.active_pane = if (self.term_cols >= App.pane_split_min) .detail else .list;
        } else if ((self.active_view == .browse or self.active_view == .history) and
            self.active_pane == .detail)
        {
            self.active_pane = .list;
        }
        return true;
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        if ((self.active_view == .browse or self.active_view == .history) and
            self.active_pane == .detail)
        {
            self.active_pane = .list;
        } else if (self.active_view == .detail) {
            self.active_view = switch (self.detail_origin) {
                .browse => .browse,
                .history => .history,
                .discover => .discover,
            };
            self.active_pane = if (self.term_cols >= App.pane_split_min) .detail else .list;
        }
        // Base-view list: no-op. View changes only via B/H/D/S / F-keys; q quits.
        return true;
    }
    return false;
}

/// Space: zoom toggle. Below pane_split_min, opens zoom from the list (no pane).
pub fn onZoomKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io, registry: Registry) bool {
    if (!key.matches(vaxis.Key.space, .{})) return false;
    if (self.active_view == .detail) {
        self.active_view = switch (self.detail_origin) {
            .browse => .browse,
            .history => .history,
            .discover => .discover,
        };
        self.active_pane = if (self.term_cols >= App.pane_split_min) .detail else .list;
    } else if ((self.active_view == .browse or self.active_view == .history) and
        self.active_pane == .detail)
    {
        self.detail_origin = if (self.active_view == .history) .history else .browse;
        self.active_view = .detail;
    } else if (self.active_view == .history and self.active_pane == .list and
        self.term_cols < App.pane_split_min)
    {
        if (self.selectedHistoryRecord()) |rec| resolve.openHistoryZoom(self, loop, io, registry, rec);
    } else if (self.active_view == .browse and self.active_pane == .list and
        self.term_cols < App.pane_split_min)
    {
        resolve.openBrowseZoom(self, loop, io, registry);
    }
    return true;
}

/// In-pane detail focus or full-screen zoom: shared gate for grid-scoped keys.
pub fn onDetailSurface(self: *const App) bool {
    return (self.active_view == .browse and self.active_pane == .detail) or
        self.active_view == .detail or
        (self.active_view == .history and self.active_pane == .detail);
}

/// 'v' cycles the open show's provider pin: unpinned → each provider → unpinned.
/// Setting a pin re-routes via a one-provider manual walk (bound-but-empty is not
/// an automatic-fallback failure). Clearing only persists; open grid stands.
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
    // for_source/for_id name the focused show (fetch fires at nav time).
    // Failed flip may have no row for the current provider: recover aid from detail.
    const aid: i64 = id_blk: {
        if (st.getAnime(arena.allocator(), src, fid) catch null) |rec| {
            break :id_blk rec.anilist_id orelse {
                self.pushToast(.info, "no canonical identity: can't pin a provider", false);
                return true;
            };
        }
        const sel = self.currentDetailAnime() orelse {
            self.pushToast(.info, "still resolving, try again shortly", false);
            return true;
        };
        break :id_blk std.math.cast(i64, sel.anilist_id orelse {
            self.pushToast(.info, "no canonical identity: can't pin a provider", false);
            return true;
        }) orelse {
            self.pushToast(.info, "no canonical identity: can't pin a provider", false);
            return true;
        };
    };

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
        } else next_idx = count; // unknown/retired pin → unpinned
    }

    if (next_idx >= count) {
        st.setProviderPin(aid, null) catch {
            self.pushToast(.@"error", "couldn't clear the provider pin", false);
            return true;
        };
        self.refreshShowPin(aid);
        self.pushToast(.info, "provider pin cleared", false);
        return true;
    }

    const target = providers_buf[next_idx];
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
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "pinned to {s}", .{target.displayName()}) catch "provider pinned";
        self.pushToast(.success, msg, false);
        return true;
    }

    // Hop toast is the feedback; skip a second "pinned" toast.
    const canonical = workers.dupeOwnedAnime(self.gpa, selection.animeFromHistoryRecord(canon_rec)) catch return true;
    const providers = self.gpa.alloc(SourceProvider, 1) catch {
        workers.freeOwnedAnime(self.gpa, canonical);
        return true;
    };
    providers[0] = target;
    resolve.clearFallback(self);
    self.resolve.fallback = .{ .canonical = canonical, .anilist_id = aid, .providers = providers, .tried = 0, .manual = true };
    if (!resolve.advanceFallback(self, loop, io, registry, null, null)) {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "couldn't reach {s}", .{target.displayName()}) catch "couldn't switch provider";
        self.pushToast(.warn, msg, false);
    }
    return true;
}

/// Episode-grid j/k/g/G on a detail surface. true for every key while focused
/// (non-nav keys are inert but consumed); false when not on a detail surface.
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
        // Terminals disagree: shift+G vs bare uppercase G.
        self.episodes.cursor = ep_len - 1;
    }
    return true;
}

/// Browse P: add focused result via the resolver. Consumed in Browse-list either way.
pub fn onBrowseAddKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io, registry: Registry) bool {
    if (!(self.active_view == .browse and self.active_pane == .list and
        (key.matches('P', .{ .shift = true }) or key.matches('P', .{})))) return false;
    if (selection.selectedAnime(self)) |anime| resolve.addSelectedCanonical(self, loop, io, registry, anime);
    return true;
}

/// List j/k/g/G. At last Browse row, j/Down pages load-more.
/// Cursor moves never prefetch episodes (lazy on detail entry).
pub fn onListCursorKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io) void {
    const nav_len: usize = switch (self.active_view) {
        .history => self.filteredHistoryLen(),
        .browse => self.search.results.items.len,
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
        self.list_cursor = nav_len - 1;
    }
    // Load-more accepts Down as well as j (arrow users hit the footer too).
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

/// History: p paused · x dropped · c completed · w watching · P planning ·
/// r recompute · u undo · X arm hard-delete.
/// Unbound: r frozen (no episode_progress); p/c/w/P/u stay live.
pub fn onHistoryMutationKey(self: *App, key: vaxis.Key) bool {
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
    } else if (key.matches('X', .{ .shift = true }) or key.matches('X', .{})) {
        // Distinct from lowercase x (.dropped). Confirm is a separate y/Y.
        self.armDelete();
        return true;
    } else if (key.matches('c', .{})) {
        self.setSelectedHistoryStatus(.completed);
        return true;
    } else if (key.matches('w', .{})) {
        self.setSelectedHistoryStatus(.watching);
        return true;
    } else if (key.matches('P', .{ .shift = true }) or key.matches('P', .{})) {
        self.setSelectedHistoryStatus(.planning);
        return true;
    } else if (key.matches('r', .{})) {
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
        // r overwrites progress: a pre-mutation undo would skip past the recompute.
        if (self.undo) |u| {
            u.free(self.gpa);
            self.undo = null;
        }
        self.syncEpisodeProgress(rec.source, rec.source_id, hw);
        self.pushToast(.success, "progress reset", false);
        return true;
    } else if (key.matches('u', .{})) {
        // Un-gated by cursor on purpose: applyUndo keys off the captured row id, not the cursor.
        self.applyUndo();
        return true;
    }
    return false;
}

/// Search prompt: History filters in-memory; Browse drives SearchController and
/// projects the verdict onto debounce / fire / input_mode (controller never touches those).
pub fn onSearchKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io) void {
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

/// Settings keys → project verdict onto App-live state. false falls through to globals.
pub fn onSettingsKey(self: *App, key: vaxis.Key, loop: *Loop, io: std.Io) bool {
    switch (self.settings.onKey(key, &self.config)) {
        .ignored => return false,
        .consumed => return true,
        .config_changed => {
            self.translation = self.config.translationEnum();
            self.palette = app_mod.paletteFromConfig(self.config.palette);
            return true;
        },
        .connect_requested => {
            self.beginConnect(loop, io);
            return true;
        },
    }
}

/// true only when bytes landed (failed write leaves tab dirty for retry).
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

/// Persist dirty Settings on leave/quit. Clear dirty only on success.
pub fn leaveSettings(self: *App, io: std.Io) void {
    if (!self.settings.dirty) return;
    if (saveSettings(self, io)) self.settings.dirty = false;
}
