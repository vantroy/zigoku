//! Zigoku — Discover/Popular feed controller subsystem (ROD-239).
//!
//! The sixth cut of the controller/subsystem split (after CoverState,
//! SettingsState, PlaybackSession, EpisodeState, and SearchController). Owns the
//! *record* of the Popular feed: the active popularity window, the grid
//! cursor/scroll, and a short-lived per-window result cache. Transport (the
//! worker thread, the slow-path timer) stays on App, mirroring SearchController —
//! App resolves nav state and hands primitives in; this struct never reaches back
//! into App. Embed by value (`discover: DiscoverState = .{}`).
//!
//! The view (`view/discover.zig`) renders this through `self.discover.*`;
//! DiscoverState is re-exported from app.zig so `app_mod.*` references resolve.

const std = @import("std");
const domain = @import("../domain.zig");
const source = @import("../source.zig");
const workers = @import("workers.zig");

const Allocator = std.mem.Allocator;
const Anime = domain.Anime;
const freeOwnedAnime = workers.freeOwnedAnime;

/// One cached popularity window. Holds *that window's* fetched page(s), the
/// loaded-page count, the fetch timestamp (for the TTL), and the in-flight flag.
pub const Slot = struct {
    /// Accumulated, gpa-owned results for this window — freed on TTL-expiry
    /// refetch and on teardown. Access via `self.discover.activeSlot().results`.
    results: std.ArrayListUnmanaged(Anime) = .empty,
    /// Loaded-page count (0 = never fetched, 1 = first page, …).
    page: u32 = 0,
    /// `Store.nowSecs()` stamp of the last successful fetch (0 = never). The TTL
    /// (`feed_ttl_secs`) is measured from here on window-switch / re-open.
    fetched_at: i64 = 0,
    /// Whether a fetch for this window is in flight.
    loading: bool = false,
};

/// The Popular-feed controller (ROD-239).
///
/// ── LOAD-BEARING INVARIANT: one independent slot per window ──────────────────
/// `slots` is FOUR separate owned lists, one per `PopularWindow` — NEVER a single
/// shared list that gets re-windowed. This is not an optimization choice; it is a
/// correctness requirement, because each card's `view_count` is the *windowed*
/// count (`rangeViews`), so the SAME show carries DIFFERENT counts in different
/// windows (e.g. ~12k Daily / ~40k Weekly / ~660k lifetime). The feed is also
/// ranked by that windowed count, so the displayed number must match the slot it
/// came from or it desyncs from the card's rank. Therefore:
///   • Never re-tag/re-window a single result list — switch to the window's slot.
///   • Never intern or share an `Anime` instance across slots; a show present in
///     all four windows is four independent owned copies.
///   • Never persist `view_count` to the store — it is window-specific; the
///     durable `AnimeRecord` (shared with Browse) carries only window-agnostic
///     facts. (Enforced today: `AnimeRecord` has no view-count column.)
/// "Optimize" any of these into a shared/persisted count and the displayed number
/// silently lies about the rank the moment the window changes — see ROD-239.
pub const DiscoverState = struct {
    /// The active popularity window — drives both the segmented bar and the fetch.
    window: source.PopularWindow = .daily,

    /// Grid cursor: a flat index into the active window's results (the episode-grid
    /// flat-index→2D positioning is resolved render-side from the column count).
    cursor: usize = 0,
    /// Top card-row offset for the scrolled grid viewport (settled in App.layout).
    scroll: usize = 0,

    /// Per-window result cache — see the struct-level invariant. Indexed by
    /// `@intFromEnum(window)` (daily=0, weekly=1, monthly=2, all_time=3).
    slots: [4]Slot = .{ .{}, .{}, .{}, .{} },

    /// The slot for the active window (const — render path).
    pub fn activeSlot(self: *const DiscoverState) *const Slot {
        return &self.slots[@intFromEnum(self.window)];
    }

    /// The slot for the active window (mutable — fetch/cache path).
    pub fn activeSlotMut(self: *DiscoverState) *Slot {
        return &self.slots[@intFromEnum(self.window)];
    }

    /// Free one window's accumulated results and reset it to "never fetched".
    /// `gpa` is the same allocator the results were appended with (App's `gpa`).
    pub fn clearSlot(self: *DiscoverState, gpa: Allocator, idx: usize) void {
        const slot = &self.slots[idx];
        for (slot.results.items) |r| freeOwnedAnime(gpa, r);
        slot.results.clearRetainingCapacity();
        slot.page = 0;
        slot.fetched_at = 0;
    }

    /// Release every window's results on teardown. Call once from App's
    /// `deinitOwnedState`, after the worker thread has joined — so nothing a
    /// worker still references is freed out from under it.
    pub fn deinit(self: *DiscoverState, gpa: Allocator) void {
        for (&self.slots) |*slot| {
            for (slot.results.items) |r| freeOwnedAnime(gpa, r);
            slot.results.deinit(gpa);
            slot.results = .empty;
        }
    }
};
