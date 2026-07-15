//! TUI event types and loop alias.

const std = @import("std");
const vaxis = @import("vaxis");
const store_mod = @import("../store.zig");
const domain = @import("../domain.zig");
const player_mod = @import("../player.zig");
const anilist = @import("../anilist.zig");
const login_loopback = @import("../login_loopback.zig");

const AnimeRecord = store_mod.AnimeRecord;
const Anime = domain.Anime;
pub const PositionUpdate = player_mod.PositionUpdate;

/// Result of one action-triggered sync flush (ROD-291). POD (no owned memory);
/// ships worker→UI by value.
/// `pushed` / `reconciled` drive whisper + history reload; `expired` drops the
/// connected flag and seeds the ROD-295 reconnect nudge.
pub const SyncFlushOutcome = struct {
    pushed: usize = 0,
    reconciled: usize = 0,
    expired: bool = false,
};

/// Unified event type. vaxis fills key_press / winsize / focus; the rest are
/// worker→UI messages posted from background threads and drained in tick().
pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    /// History finished loading. Arena-backed (run() owns the arena); App only
    /// borrows via setHistory. Never free with the gpa. Quit-time interrupt may
    /// post a partial slice the exiting loop never drains.
    history_loaded: []AnimeRecord,
    /// History reloaded after playback (ROD-191). Same arena-borrow contract as
    /// history_loaded; only reloadHistoryTask posts this so the double-buffer
    /// reaper can tell reload from initial load.
    history_reloaded: []AnimeRecord,
    /// Post-playback reload failed; keep current slice. Distinct from task_error:
    /// clears the reload latch only, never wipes watchlist or raises load_error.
    history_reload_failed,
    /// Initial history load failed. load_error banner only (ROD-234). Distinct from
    /// task_error so Browse search/enrich cannot mark History "unavailable".
    history_load_failed: []const u8,
    /// Browse search/enrich failed. Toast only; never touches History (ROD-234).
    task_error: []const u8,
    /// Sync settled: action flush (ROD-291) or launch pull-refresh (ROD-293, always
    /// `pushed = 0`). Handler reloads history if reconciled, drops connected on
    /// expiry, whispers ↓/↑ counts. Soft failures stay silent (rows stay dirty).
    sync_flushed: SyncFlushOutcome,
    /// Boot update check found a newer release (ROD-370). Payloadless: toast names
    /// the command only; worker keeps the tag thread-local. Fired only when behind.
    update_available,
    /// In-TUI AniList connect settled (ROD-286). Posted once on real outcome
    /// (valid callback or hard listener error); NEVER on `.canceled` (esc tears
    /// the modal down; worker skips post so this cannot race a freed connect arena).
    /// POD by value. `.ok` carries nothing; handler reloads auth.zon.
    connect_result: login_loopback.ConnectOutcome,
    /// Search results. `results` gpa-owned (app takes ownership). `for_query` gpa-duped
    /// for stale check. `page` is the result set's page number.
    search_done: struct {
        results: []Anime,
        for_query: []const u8,
        page: u32,
    },
    /// Tier-A add-to-watchlist resolve (ROD-327). `ok`: mint binding (bindCanonical)
    /// and reload History. `!ok`: markUnbound (ROD-329) or "couldn't add" toast.
    /// `source_id` gpa-owned, freed by UI on either arm.
    resolve_add_result: struct {
        ok: bool,
        anilist_id: i64,
        source_id: []const u8,
        /// Provider that resolved (ROD-343): bind under THIS name, not registry default.
        /// Static vtable `name()`, never freed. Meaningful only when `ok`.
        source: []const u8,
        /// Definitive "not stocked" providers (ROD-347): persist absence rows on BOTH
        /// arms. Names static; slice gpa-owned, freed by UI.
        absent_sources: []const []const u8 = &.{},
    },
    /// Tier-C Play resolve (ROD-328): title-search when canonicalKey is null.
    /// `ok`: arm pending_bind and fire episode fetch (bind via `.episodes_done`).
    /// `!ok`: toast only; Play never mints unbound (add path only, ROD-329).
    /// `source_id` gpa-owned, freed by UI when non-empty.
    resolve_play_target: struct {
        ok: bool,
        anilist_id: i64,
        source_id: []const u8,
        /// Matching provider (ROD-343). Static vtable name. Meaningful only when `ok`.
        source: []const u8,
        /// Same contract as resolve_add_result.absent_sources (ROD-347); persist even
        /// if the staleness gate drops the result (catalog fact, not on-screen show).
        absent_sources: []const []const u8 = &.{},
    },
    /// Eager pre-warm settled one provider (ROD-351). Non-empty `source_id` (gpa-owned):
    /// mint binding HIDDEN (play reveals; History must not grow unengaged rows).
    /// Empty + `absent`: cache negative (ROD-347). Empty + !absent never posts.
    /// `source` is static vtable name.
    prewarm_result: struct {
        anilist_id: i64,
        source: []const u8,
        source_id: []const u8,
        absent: bool,
    },
    /// Pre-warm walk finished: clear single-flight guard for the next add/play.
    prewarm_done,
    /// One Discover feed page (ROD-336). Fully enriched AniList rows for `axis`.
    /// `results` gpa-owned; App takes into the per-axis slot. `has_next` is
    /// pageInfo.hasNextPage (§9.6).
    discover_feed: struct {
        results: []Anime,
        axis: anilist.DiscoverAxis,
        page: u32,
        has_next: bool,
    },
    /// Discover feed fetch failed (ROD-336). Distinct from task_error: feed owns its
    /// error UX without touching Browse.
    discover_feed_error: struct {
        axis: anilist.DiscoverAxis,
        cause: anyerror,
    },
    /// Refresh-on-view re-enriched a stale show (ROD-182). `result` / `source` gpa-owned.
    /// `answered` (ROD-278): stamp freshness + persist ONLY when true (confirmed match
    /// or no-match). Transport failure keeps `answered` false. Both fields freed in handler.
    enrichment_refreshed: struct {
        result: Anime,
        source: []const u8,
        answered: bool,
    },
    /// Episode list. `episodes` gpa-owned (each .raw owned); `for_id` gpa-duped for stale check.
    episodes_done: struct {
        episodes: []domain.EpisodeNumber,
        for_id: []const u8,
    },
    /// Episode fetch failed (ROD-173). `for_id` gpa-duped so handler can drop superseded
    /// failures (ROD-179 concurrent fetches). Handler frees `for_id`.
    episodes_error: struct {
        cause: anyerror,
        for_id: []const u8,
    },
    /// Cover decoded. `rgba` / `for_id` GPA-owned; App takes ownership on fresh path.
    cover_done: struct {
        rgba: []u8,
        width: u32,
        height: u32,
        for_id: []const u8,
    },
    /// Cover fetch/decode failed for this show id.
    cover_error: []const u8,
    /// Discover-grid cover done (ROD-243). URL-keyed, window-agnostic: no stale-drop.
    /// Handler frees `rgba` only if no slot can hold it (OOM).
    discover_cover_done: struct {
        url: []const u8,
        rgba: []u8,
        width: u32,
        height: u32,
    },
    /// Discover-grid cover failed (ROD-243). gpa-owned url; handler records cooldown and frees.
    discover_cover_error: []const u8,
    /// Live playback position from mpv IPC.
    position_update: struct {
        time_pos: f64,
        duration: f64,
    },
    /// mpv exited cleanly; final authoritative position if any.
    play_done: ?PositionUpdate,
    /// resolve failed or mpv exited badly. `final` still counts a late-end watch;
    /// `cause` classifies (ROD-173; MpvNotFound/MpvFailed refined by ROD-230).
    play_error: struct { final: ?PositionUpdate, cause: anyerror },
    /// Pre-playback stream open failed in a CDN penalty window; worker re-resolves
    /// after backoff (ROD-309). `attempt` 1-based, `max` total, for "retrying N/M" toast.
    play_retry: struct { attempt: u8, max: u8 },
    /// Periodic 100ms heartbeat: spinner + debounced search.
    tick,
};

pub const Loop = vaxis.Loop(Event);
