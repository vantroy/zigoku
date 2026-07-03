//! Zigoku — TUI event types and loop alias.

const std = @import("std");
const vaxis = @import("vaxis");
const store_mod = @import("../store.zig");
const domain = @import("../domain.zig");
const player_mod = @import("../player.zig");
const source_mod = @import("../source.zig");

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
    /// The initial background history load failed; payload is a human-readable
    /// reason for the load_error banner. Distinct from task_error (ROD-234) so a
    /// Browse search/enrich failure can never falsely mark History "unavailable" —
    /// only a real history-load failure raises that banner.
    history_load_failed: []const u8,
    /// A background BROWSE task (search/enrich) failed; payload is a human-readable
    /// reason. Surfaces as a toast only — never touches History state (ROD-234).
    task_error: []const u8,
    /// Search results from background thread. `results` is gpa-allocated; app takes ownership.
    /// `for_query` is a gpa-duped copy of the query string at search time (for stale check).
    /// `page` is the page number this result set belongs to.
    search_done: struct {
        results: []Anime,
        for_query: []const u8,
        page: u32,
    },
    /// Popular-feed results from a background thread (ROD-239). `results` is
    /// gpa-allocated (each Anime's strings owned); App takes ownership into the
    /// feed slot for `window`. `window` is carried so a result lands in its own
    /// per-window cache slot even if the active window changed mid-flight; `page`
    /// is the page this set belongs to.
    popular_done: struct {
        results: []Anime,
        window: source_mod.PopularWindow,
        page: u32,
    },
    /// A Popular-feed fetch failed (ROD-239). `window` is the slot it was for (so
    /// the handler clears that slot's loading + marks it failed); `cause` names the
    /// failure class. Distinct from task_error so the feed owns its own error UX
    /// (in-view "can't reach the feed" + a feed toast) without touching Browse.
    popular_error: struct {
        window: source_mod.PopularWindow,
        cause: anyerror,
    },
    /// One Discover card lazily enriched from AniList for its zoom (ROD-239). The
    /// feed has no synopsis, so opening a card fetches it. `result` is gpa-owned;
    /// App merges it into `window`'s slot (matched by id) and takes ownership.
    discover_enriched: struct {
        result: Anime,
        window: source_mod.PopularWindow,
    },
    /// A whole Discover feed page batch-enriched from AniList in one fetch
    /// (ROD-247) — score + genres + season, the card signals the popular feed
    /// nulls. `results` is gpa-allocated (each Anime's strings owned); App merges
    /// each into `window`'s slot by id and takes ownership (orphans freed). Distinct
    /// from `discover_enriched` (the per-card zoom path) so the page batch and a
    /// zoom enrich never share a thread handle or block each other.
    discover_batch_enriched: struct {
        results: []Anime,
        window: source_mod.PopularWindow,
    },
    /// AniList-enriched metadata for a page slice. `results` is gpa-allocated;
    /// app takes ownership and merges fields into the live search results.
    search_enriched: struct {
        results: []Anime,
        for_query: []const u8,
        offset: usize,
    },
    /// ROD-182: refresh-on-view re-enriched a stale show. `result` is a gpa-owned
    /// identity stub filled with fresh AniList metadata (or unchanged on a miss);
    /// `source` is gpa-owned. The handler persists it (upsert stamps the freshness
    /// columns + overwrites drift fields via COALESCE) and flags a history reload,
    /// then frees both.
    enrichment_refreshed: struct {
        result: Anime,
        source: []const u8,
    },
    /// Episode list from background fetch. `episodes` is gpa-allocated (each .raw owned);
    /// `for_id` is a gpa-duped copy of the show id (for stale check). App takes ownership.
    episodes_done: struct {
        episodes: []domain.EpisodeNumber,
        for_id: []const u8,
    },
    /// Episode fetch failed. `cause` names the failure class for the toast
    /// (network / blocked / server / generic — ROD-173); `anyerror` is a POD
    /// error code, safe to ship across the worker→UI boundary. `for_id` is a
    /// gpa-duped copy of the show id (transferred from the worker) so the handler
    /// can keep-check a superseded failure and drop it — concurrent episode
    /// fetches became possible once supersede stopped joining (ROD-179). The
    /// handler frees `for_id`.
    episodes_error: struct {
        cause: anyerror,
        for_id: []const u8,
    },
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
    /// One Discover-grid cover finished fetching+decoding (ROD-243). `url` and
    /// `rgba` are gpa-owned and transferred to the handler, which adopts them into
    /// the slot for `url`. Covers are URL-keyed and window-agnostic, so a result is
    /// always a valid cover for `url` even if the window changed mid-flight — no
    /// stale-drop; the handler frees `rgba` only if no slot can hold it (OOM).
    discover_cover_done: struct {
        url: []const u8,
        rgba: []u8,
        width: u32,
        height: u32,
    },
    /// A Discover-grid cover fetch failed (ROD-243); payload is the gpa-owned url.
    /// The handler records the per-url failure cooldown (so a transient miss doesn't
    /// hammer the network) and frees the url.
    discover_cover_error: []const u8,
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
