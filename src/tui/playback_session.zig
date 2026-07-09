//! Zigoku — mpv playback session subsystem (ROD-162).
//!
//! Owns the RECORD of the currently playing episode (what show/episode/source is playing,
//! the checkpoint high-water, the watched-state bookkeeping) and the persistence transitions
//! over a caller-supplied `Store`. Driven through explicit dependencies (`gpa`/`store`); it
//! never reaches back into App.
//!
//! Boundary: this struct owns the session record, not the transport. `playing`,
//! `play_thread`, `current_position`, and `current_duration` stay on App (app-shell concerns:
//! the loading flag, the thread handle the shell joins, the live position the UI renders).
//! The controller resolves selection context, orchestrates the thread, and does the transport
//! reset itself, calling in here for the session transitions. Embed by value; no `@fieldParentPtr`.

const std = @import("std");
const domain = @import("../domain.zig");
const store_mod = @import("../store.zig");
const event_mod = @import("event.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const PositionUpdate = event_mod.PositionUpdate;

/// The mpv playback session (ROD-162). Holds the record of one playback —
/// source/show/episode/translation + the checkpoint mark — and persists
/// progress + watched-state to a caller-supplied `Store`. Transport state
/// (`playing`/`play_thread`/`current_*`) lives on App, not here.
pub const PlaybackSession = struct {
    /// Last persisted checkpoint position for the current playback.
    last_checkpoint_pos: f64 = 0,
    /// Source name for the currently playing episode. Borrowed from either the
    /// provider vtable or the history arena, both of which outlive App.
    source: []const u8 = &.{},
    /// GPA-owned show id for the current playback session.
    anime_id: []const u8 = &.{},
    /// GPA-owned raw episode label for the current playback session.
    episode_raw: []const u8 = &.{},
    /// 1-based episode index used for recordPlay's high-water mark.
    episode_index: u32 = 0,
    /// Translation active when playback started; decoupled from live UI toggles.
    translation: domain.Translation = .sub,

    /// Free the GPA-owned strings and reset to the idle state. Idempotent.
    /// The `.len > 0` guard distinguishes a real GPA allocation from the
    /// `&.{}` idle sentinel (and from `source`, which is always a borrow) —
    /// freeing only what `begin` actually duped.
    pub fn clear(self: *PlaybackSession, gpa: Allocator) void {
        if (self.anime_id.len > 0) gpa.free(self.anime_id);
        if (self.episode_raw.len > 0) gpa.free(self.episode_raw);
        self.source = &.{};
        self.anime_id = &.{};
        self.episode_raw = &.{};
        self.episode_index = 0;
        self.translation = .sub;
        self.last_checkpoint_pos = 0;
    }

    /// Open a new session: dupe the id/episode into GPA-owned storage and seed
    /// the checkpoint mark from the resume offset. Returns false on OOM with the
    /// session left clear. The caller passes the active translation in — the
    /// session never reads App's live UI toggle.
    pub fn begin(
        self: *PlaybackSession,
        gpa: Allocator,
        source: []const u8,
        anime_id: []const u8,
        episode_raw: []const u8,
        episode_index: u32,
        translation: domain.Translation,
        start_seconds: u64,
    ) bool {
        self.clear(gpa);
        const owned_id = gpa.dupe(u8, anime_id) catch return false;
        const owned_episode = gpa.dupe(u8, episode_raw) catch {
            gpa.free(owned_id);
            return false;
        };

        self.source = source;
        self.anime_id = owned_id;
        self.episode_raw = owned_episode;
        self.episode_index = episode_index;
        self.translation = translation;
        self.last_checkpoint_pos = @floatFromInt(start_seconds);
        return true;
    }

    /// Persist a progress checkpoint if 30s have elapsed since the last one.
    /// No-op without a store or an open session.
    pub fn maybeCheckpoint(self: *PlaybackSession, store: ?*Store, time_pos: f64, duration: f64) void {
        const st = store orelse return;
        if (self.anime_id.len == 0 or self.episode_raw.len == 0) return;
        if (time_pos - self.last_checkpoint_pos < 30.0) return;

        st.saveProgress(
            self.source,
            self.anime_id,
            self.translation,
            self.episode_raw,
            time_pos,
            duration,
            Store.nowSecs(),
        ) catch |e| log.debug("saveProgress (checkpoint) failed: {s}", .{@errorName(e)});
        self.last_checkpoint_pos = time_pos;
    }

    /// Persist the session's final state (a meaningful final position records the
    /// play; the progress high-water mark advances only when `completed`) and
    /// clear it. The transport reset (`playing`/`current_*`) is the controller's
    /// job, not the session's — this only touches the store and its own record.
    /// See `PositionUpdate.isMeaningful` (worth-persisting) and
    /// `PositionUpdate.reachedCompletion` (watched bar).
    pub fn finish(self: *PlaybackSession, gpa: Allocator, store: ?*Store, final_update: ?PositionUpdate, completed: bool) void {
        if (store) |st| {
            if (self.anime_id.len > 0 and self.episode_raw.len > 0) {
                if (final_update) |update| {
                    // A meaningful position is a real play: persist the resume
                    // checkpoint and touch history (recordPlay bumps count /
                    // last_watched / visibility). `completed` (ROD-168) gates
                    // only the progress high-water mark inside recordPlay — a
                    // partial watch shows up in history but does not advance N.
                    if (update.isMeaningful()) {
                        st.saveProgress(
                            self.source,
                            self.anime_id,
                            self.translation,
                            self.episode_raw,
                            update.time_pos,
                            update.duration,
                            Store.nowSecs(),
                        ) catch |e| log.debug("saveProgress (final) failed: {s}", .{@errorName(e)});

                        if (self.episode_index > 0) {
                            st.recordPlay(self.source, self.anime_id, self.episode_index, Store.nowSecs(), completed) catch |e|
                                log.debug("recordPlay failed: {s}", .{@errorName(e)});
                        }
                    }
                }
            }
        }
        self.clear(gpa);
    }
};
