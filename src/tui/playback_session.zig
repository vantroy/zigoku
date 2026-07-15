//! mpv playback session (ROD-162).
//!
//! Session record + store transitions only. Transport (`playing`, `play_thread`,
//! `current_position`/`current_duration`) stays on App; no `@fieldParentPtr`.

const std = @import("std");
const domain = @import("../domain.zig");
const store_mod = @import("../store.zig");
const event_mod = @import("event.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const PositionUpdate = event_mod.PositionUpdate;

/// One playback's record and store transitions (ROD-162). Transport stays on App.
pub const PlaybackSession = struct {
    last_checkpoint_pos: f64 = 0,
    /// Borrowed: provider vtable or history arena (both outlive App).
    source: []const u8 = &.{},
    /// GPA-owned; `&.{}` idle sentinel (see `clear`).
    anime_id: []const u8 = &.{},
    /// GPA-owned; `&.{}` idle sentinel (see `clear`).
    episode_raw: []const u8 = &.{},
    /// 1-based; used for recordPlay high-water.
    episode_index: u32 = 0,
    /// Snapshot at begin; not the live UI translation toggle.
    translation: domain.Translation = .sub,

    /// Free GPA strings; reset to idle. Idempotent.
    /// `.len > 0` only: free what `begin` duped (`&.{}` sentinel and borrowed `source` must not free).
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

    /// Dupe id/episode into GPA; seed checkpoint from resume. False on OOM (session left clear).
    /// Caller passes translation; session never reads App's live toggle.
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

    /// Checkpoint every 30s when store + open session present.
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

    /// Persist final state then clear. Transport reset is the controller's job.
    /// Meaningful position → history/resume; `completed` (ROD-168) only gates progress
    /// high-water inside recordPlay. See PositionUpdate.isMeaningful / reachedCompletion.
    pub fn finish(self: *PlaybackSession, gpa: Allocator, store: ?*Store, final_update: ?PositionUpdate, completed: bool) void {
        if (store) |st| {
            if (self.anime_id.len > 0 and self.episode_raw.len > 0) {
                if (final_update) |update| {
                    // Meaningful → resume + history. `completed` gates only high-water (ROD-168);
                    // partial watches appear in history without advancing N.
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
