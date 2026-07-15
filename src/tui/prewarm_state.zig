//! Eager sibling-provider pre-warm walk (ROD-351): one background walk app-wide,
//! silent (no toast/spinner), yields to fallback and user-facing resolve.

const std = @import("std");
const domain = @import("../domain.zig");
const source_mod = @import("../source.zig");
const event_mod = @import("event.zig");
const workers = @import("workers.zig");

const Allocator = std.mem.Allocator;
const Anime = domain.Anime;
const SourceProvider = source_mod.SourceProvider;
const Loop = event_mod.Loop;
const ThreadDrain = workers.ThreadDrain;

pub const PrewarmState = struct {
    /// Floors walk spacing app-wide; ring alone can burst after eviction (ROD-309/351).
    pub const spacing_ms: i64 = 30_000;

    drain: ThreadDrain = .{},
    /// One walk app-wide; must not block user-facing resolve or vice versa.
    active: bool = false,
    /// Session ring of pre-warmed aids. Soft dedup (eviction harmless). `?i64` not a 0
    /// sentinel: nothing enforces anilist_id > 0.
    attempted: [32]?i64 = @splat(null),
    attempted_next: usize = 0,
    last_start_ms: ?i64 = null,
    /// Cooperative cancel between provider hops; set when a user fallback walk advances.
    cancel: std.atomic.Value(bool) = .init(false),

    /// Pure guard: true if a walk for `anilist_id` must not fire right now.
    pub fn blocked(
        self: *const PrewarmState,
        anilist_id: i64,
        now_ms: i64,
        add_resolving: bool,
        play_resolving: bool,
        fallback_active: bool,
    ) bool {
        if (self.active or add_resolving or play_resolving or fallback_active) return true;
        for (self.attempted) |a| if (a != null and a.? == anilist_id) return true;
        if (self.last_start_ms) |t| if (now_ms - t < spacing_ms) return true;
        return false;
    }

    pub fn markAttempted(self: *PrewarmState, anilist_id: i64, now_ms: i64) void {
        self.attempted[self.attempted_next] = anilist_id;
        self.attempted_next = (self.attempted_next + 1) % self.attempted.len;
        self.last_start_ms = now_ms;
    }

    pub fn cancelWalk(self: *PrewarmState) void {
        self.cancel.store(true, .release);
    }

    /// Spawn the walk over `providers`. Takes ownership of `providers` / `canonical` on
    /// every path (frees them itself on spawn failure). True iff the thread started.
    pub fn fire(
        self: *PrewarmState,
        gpa: Allocator,
        loop: *Loop,
        io: std.Io,
        providers: []const SourceProvider,
        canonical: Anime,
        anilist_id: i64,
        translation: domain.Translation,
    ) bool {
        self.cancel.store(false, .release);
        self.active = true;
        self.drain.begin();
        const t = std.Thread.spawn(.{}, workers.prewarmTask, .{
            loop, gpa, io, providers, canonical, anilist_id, translation, &self.cancel, &self.drain,
        }) catch {
            self.drain.finish();
            self.active = false;
            gpa.free(providers);
            workers.freeOwnedAnime(gpa, canonical);
            return false;
        };
        t.detach();
        return true;
    }
};
