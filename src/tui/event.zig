//! Zigoku — TUI event types and loop alias.

const std = @import("std");
const vaxis = @import("vaxis");
const store_mod = @import("../store.zig");
const domain = @import("../domain.zig");
const player_mod = @import("../player.zig");

const AnimeRecord = store_mod.AnimeRecord;
const Anime = domain.Anime;
pub const PositionUpdate = player_mod.PositionUpdate;

/// Unified event type. vaxis fills key_press / winsize / focus; the rest are our
/// worker→UI messages, posted from background threads and drained in tick().
pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    /// History finished loading. The slice is arena-backed (run() owns the
    /// history arena and frees it at teardown); App only *borrows* it via
    /// setHistory — never free this with the gpa. On a quit-time interrupt the
    /// worker may post a partial slice that the exiting loop never drains.
    history_loaded: []AnimeRecord,
    /// History finished RELOADING after playback (ROD-191). Same arena-borrow
    /// contract as history_loaded; posted only by reloadHistoryTask so run()'s
    /// double-buffer reaper can tell a reload's outcome from the initial load.
    history_reloaded: []AnimeRecord,
    /// A post-playback history reload failed; the current slice is kept. Distinct
    /// from task_error so a transient reload failure neither wipes the watchlist nor
    /// raises the persistent load_error banner — it just clears the reload latch.
    history_reload_failed,
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
    /// Episode fetch failed; payload is the failure cause so the toast can name
    /// the class (network / blocked / server / generic — ROD-173). `anyerror` is
    /// a POD error code, safe to ship across the worker→UI boundary.
    episodes_error: anyerror,
    /// Cover image bytes were fetched + decoded. `rgba` and `for_id` are
    /// GPA-owned; App takes ownership on the fresh path.
    cover_done: struct {
        rgba: []u8,
        width: u32,
        height: u32,
        for_id: []const u8,
    },
    /// Cover fetch/decode failed for this show id.
    cover_error: []const u8,
    /// Live playback position from mpv IPC.
    position_update: struct {
        time_pos: f64,
        duration: f64,
    },
    /// mpv exited cleanly; payload carries the final observed authoritative position, if any.
    play_done: ?PositionUpdate,
    /// resolve failed or mpv exited badly. `final` carries the last observed
    /// position (if any) so a watch that errored at the very end still counts;
    /// `cause` is the failure reason, so a non-completed failure names its class
    /// (network / blocked / server — ROD-173). `cause` covers the resolve path;
    /// the mpv-spawn classes (MpvNotFound/MpvFailed) ride the same slot and are
    /// refined into their own copy by ROD-230.
    play_error: struct { final: ?PositionUpdate, cause: anyerror },
    /// Periodic 100ms heartbeat: advances spinner, fires debounced search.
    tick,
};

pub const Loop = vaxis.Loop(Event);
