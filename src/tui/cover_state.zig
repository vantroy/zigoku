//! Cover/image subsystem (ROD-160): one selection's poster art, fetch policy, Kitty state.
//! Driven via explicit deps; no `@fieldParentPtr`.

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const cover_mod = @import("../cover.zig");
const workers = @import("workers.zig");
const event_mod = @import("event.zig");

const Allocator = std.mem.Allocator;
const Loop = event_mod.Loop;
const CoverCaches = workers.CoverCaches;
const SourceProvider = @import("../source.zig").SourceProvider;
const coverTask = workers.coverTask;

/// One selection's poster art: fetch/suppress/retry, pixels, Kitty image, worker lifecycle.
pub const CoverState = struct {
    /// Same id+url failure suppress window (ROD-110). Changed `thumb` URL clears immediately.
    pub const retry_cooldown_ms: i64 = 10_000;

    /// Pure `sync` decision (ROD-110): unit-testable without threads / `builtin.is_test`.
    pub const Action = enum {
        none,
        /// Stale cover belongs to a different id; no art for target.
        clear,
        /// Same-id+same-url failure still inside cooldown.
        suppress,
        /// Already loading or holding pixels for this id.
        up_to_date,
        /// Fresh fetch (clears superseded failure record).
        fetch,
    };

    /// Pure inputs for the cover fetch decision.
    pub const Decision = struct {
        target_id: ?[]const u8,
        target_url: ?[]const u8,
        cover_for_id: ?[]const u8,
        cover_loading: bool,
        has_pixels: bool,
        failed_id: ?[]const u8,
        failed_url: ?[]const u8,
        failed_at_ms: i64,
        now_ms: i64,

        pub fn eval(d: Decision) Action {
            const target_id = d.target_id orelse return .none;

            const target_url = d.target_url orelse {
                // No art: clear only if loaded state is for another id.
                const stale = d.cover_for_id != null and
                    !std.mem.eql(u8, d.cover_for_id.?, target_id);
                return if (stale) .clear else .none;
            };

            // Live cover wins over a stale failure record (before suppress).
            if (d.cover_for_id) |id| {
                if (std.mem.eql(u8, id, target_id) and (d.cover_loading or d.has_pixels)) {
                    return .up_to_date;
                }
            }

            // Same id + same url + within cooldown → suppress. Failure records survive
            // navigation; cleared only by cooldown expiry, URL change, or successful fetch.
            if (d.failed_id) |fid| {
                if (std.mem.eql(u8, fid, target_id)) {
                    const same_url = d.failed_url != null and
                        std.mem.eql(u8, d.failed_url.?, target_url);
                    const within_cooldown = d.now_ms -% d.failed_at_ms < retry_cooldown_ms;
                    if (same_url and within_cooldown) return .suppress;
                }
            }

            return .fetch;
        }
    };

    /// Letterboxed placement inside a half-block mosaic grid (ROD-110).
    pub const HalfBlockFit = struct { w: u32, h: u32, off_x: u32, off_y: u32 };

    /// Fit image into half-pixel grid, aspect preserved. Half-block `▀` is full-cell wide,
    /// half tall: compare in physical pixels via terminal `ppc`/`pph`. Zero metrics assume
    /// square half-pixels (correct on 2:1 cells only). Pure for unit tests.
    pub fn halfBlockFit(img_w: u32, img_h: u32, grid_w: u32, grid_h: u32, ppc: u32, pph: u32) HalfBlockFit {
        var fit_w = grid_w;
        var fit_h = grid_h;
        if (img_w != 0 and img_h != 0 and grid_w != 0 and grid_h != 0) {
            if (ppc != 0 and pph != 0) {
                // phys_w = grid_w*ppc, phys_h = grid_h*pph/2:
                //   img_w*grid_h*pph vs 2*img_h*grid_w*ppc
                const lhs = @as(u64, img_w) * grid_h * pph;
                const rhs = @as(u64, img_h) * grid_w * ppc * 2;
                if (lhs > rhs) {
                    // width-bound
                    fit_h = @intCast(@max(1, @as(u64, img_h) * grid_w * ppc * 2 / (@as(u64, img_w) * pph)));
                } else {
                    // height-bound
                    fit_w = @intCast(@max(1, @as(u64, img_w) * grid_h * pph / (@as(u64, img_h) * ppc * 2)));
                }
            } else if (img_w * grid_h > img_h * grid_w) {
                fit_h = @max(1, img_h * grid_w / img_w); // width-bound, square half-pixel
            } else {
                fit_w = @max(1, img_w * grid_h / img_h); // height-bound, square half-pixel
            }
        }
        fit_w = @min(fit_w, grid_w);
        fit_h = @min(fit_h, grid_h);
        return .{ .w = fit_w, .h = fit_h, .off_x = (grid_w - fit_w) / 2, .off_y = (grid_h - fit_h) / 2 };
    }

    /// Joined before each new spawn.
    thread: ?std.Thread = null,
    pixels: ?struct { rgba: []u8, w: u32, h: u32 } = null,
    for_id: ?[]const u8 = null,
    loading: bool = false,
    /// Last failed id; with `failed_url` + `failed_at_ms` drives ROD-110 cooldown.
    failed_for_id: ?[]const u8 = null,
    /// GPA-owned; URL-change recovery.
    failed_url: ?[]const u8 = null,
    failed_at_ms: i64 = 0,
    /// GPA-owned URL in flight (attribute failure if selection moves mid-fetch).
    inflight_url: ?[]const u8 = null,
    fallback_color: vaxis.Color = .default,
    image: ?vaxis.Image = null,
    /// Deferred Kitty free: delete on next draw pass.
    pending_free_id: ?u32 = null,

    fn invalidateImage(self: *CoverState) void {
        if (self.image) |img| {
            self.pending_free_id = img.id;
            self.image = null;
        }
    }

    fn freeBuffers(self: *CoverState, gpa: Allocator) void {
        if (self.pixels) |px| {
            gpa.free(px.rgba);
            self.pixels = null;
        }
        self.fallback_color = .default;
    }

    pub fn clearFailure(self: *CoverState, gpa: Allocator) void {
        if (self.failed_for_id) |id| {
            gpa.free(id);
            self.failed_for_id = null;
        }
        if (self.failed_url) |u| {
            gpa.free(u);
            self.failed_url = null;
        }
        self.failed_at_ms = 0;
    }

    /// Record failure for cooldown retry. Dupes `url` so same-id later can detect thumb change.
    pub fn noteFailure(self: *CoverState, gpa: Allocator, now: i64, id: []const u8, url: ?[]const u8) void {
        self.clearFailure(gpa);
        self.failed_for_id = gpa.dupe(u8, id) catch null;
        self.failed_url = if (url) |u| (gpa.dupe(u8, u) catch null) else null;
        self.failed_at_ms = now;
    }

    fn clearInflight(self: *CoverState, gpa: Allocator) void {
        if (self.inflight_url) |u| {
            gpa.free(u);
            self.inflight_url = null;
        }
    }

    /// Take ownership of decoded pixels; supersede failure, drop inflight, retire Kitty/pixels.
    pub fn acceptPixels(self: *CoverState, gpa: Allocator, rgba: []u8, w: u32, h: u32) void {
        self.clearFailure(gpa);
        self.clearInflight(gpa);
        self.invalidateImage();
        self.freeBuffers(gpa);
        self.pixels = .{ .rgba = rgba, .w = w, .h = h };
        self.fallback_color = cover_mod.dominantColor(.{ .rgba = rgba, .w = w, .h = h });
    }

    pub fn clear(self: *CoverState, gpa: Allocator) void {
        self.invalidateImage();
        self.freeBuffers(gpa);
        if (self.for_id) |id| {
            gpa.free(id);
            self.for_id = null;
        }
        self.clearInflight(gpa);
        self.loading = false;
    }

    pub fn flushPendingFree(self: *CoverState, vx: *vaxis.Vaxis, writer: *std.Io.Writer) void {
        if (self.pending_free_id) |id| {
            vx.freeImage(writer, id);
            self.pending_free_id = null;
        }
    }

    pub fn freeAll(self: *CoverState, gpa: Allocator, vx: *vaxis.Vaxis, writer: *std.Io.Writer) void {
        self.flushPendingFree(vx, writer);
        if (self.image) |img| vx.freeImage(writer, img.id);
        self.image = null;
        self.clear(gpa);
        self.clearFailure(gpa);
    }

    pub fn joinThread(self: *CoverState) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Reconcile with caller-resolved `target_id`/`target_url`. True iff a fetch thread started
    /// (caller marks shared async-start clock on App).
    pub fn sync(
        self: *CoverState,
        gpa: Allocator,
        loop: *Loop,
        io: std.Io,
        provider: SourceProvider,
        caches: *CoverCaches,
        now: i64,
        target_id: ?[]const u8,
        target_url: ?[]const u8,
    ) bool {
        if (builtin.is_test) return false;

        const decision: Decision = .{
            .target_id = target_id,
            .target_url = target_url,
            .cover_for_id = self.for_id,
            .cover_loading = self.loading,
            .has_pixels = self.pixels != null,
            .failed_id = self.failed_for_id,
            .failed_url = self.failed_url,
            .failed_at_ms = self.failed_at_ms,
            .now_ms = now,
        };
        switch (decision.eval()) {
            .none, .suppress, .up_to_date => return false,
            .clear => {
                self.clear(gpa);
                return false;
            },
            .fetch => {},
        }
        // .fetch: non-null target; supersedes prior failure.
        self.clearFailure(gpa);
        const tid = target_id.?;
        const url = target_url.?;

        self.joinThread();

        self.clear(gpa);
        self.for_id = gpa.dupe(u8, tid) catch return false;
        self.inflight_url = gpa.dupe(u8, url) catch null;
        const id_for_event = gpa.dupe(u8, tid) catch {
            self.clear(gpa);
            return false;
        };
        const url_copy = gpa.dupe(u8, url) catch {
            gpa.free(id_for_event);
            self.clear(gpa);
            return false;
        };

        self.thread = std.Thread.spawn(.{}, coverTask, .{
            loop,
            gpa,
            io,
            provider,
            url_copy,
            id_for_event,
            caches,
        }) catch {
            gpa.free(url_copy);
            gpa.free(id_for_event);
            self.clear(gpa);
            return false;
        };
        self.loading = true;
        return true;
    }
};
