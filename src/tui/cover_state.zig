//! Zigoku — cover/image subsystem (ROD-160).
//!
//! Extracted from app.zig as the pattern-setter for the controller/subsystem
//! split. Owns one selection's poster art — fetch policy, decoded-pixel +
//! Kitty-image state, worker-thread lifecycle — and is driven purely through
//! explicit dependencies (gpa/loop/io/now/vx). It has no dependency on App: the
//! controller resolves the target id/url from navigation state and passes the
//! primitives in.

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

/// The cover/image subsystem (ROD-160). Owns one selection's poster art: the
/// fetch/suppress/retry *policy*, the decoded-pixel + Kitty-image state, and the
/// worker-thread lifecycle. Extracted from App as the pattern-setter for the
/// controller/subsystem split — it holds only cover state and is driven through
/// explicit dependencies (`gpa`/`loop`/`io`/`now`/`vx`). It never reaches back
/// into App or navigation state: the caller resolves the target id/url and
/// passes them into `sync`. Embed by value on App (`cover: CoverState = .{}`);
/// no back-reference, no `@fieldParentPtr`.
pub const CoverState = struct {
    /// Cover fetch/decode failure suppression window (ROD-110). After a failure
    /// we suppress refetch of the *same id+url* for this long, then allow one
    /// retry on the next event — a lightweight backoff instead of permanent
    /// sticky suppression. A changed `thumb` URL clears suppression immediately
    /// (recovery without moving the selection); see `Decision`.
    pub const retry_cooldown_ms: i64 = 10_000;

    /// What `sync` should do for the current selection. Extracted from the
    /// side effects so the fetch/suppress/retry policy is unit-testable without
    /// spawning threads or relying on `builtin.is_test` (ROD-110).
    pub const Action = enum {
        /// Nothing to do — no target, or target already matches in-flight/loaded.
        none,
        /// Target has no art and stale cover state belongs to a different id; drop it.
        clear,
        /// A recent same-id+same-url failure is still inside the cooldown window.
        suppress,
        /// We're already loading or holding pixels for this exact id.
        up_to_date,
        /// Start a fresh fetch (clears any superseded failure record).
        fetch,
    };

    /// Pure inputs for the cover fetch decision. `now_ms`/`failed_at_ms` drive
    /// the cooldown; `failed_url` vs `target_url` drives URL-change recovery.
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
                // No art for this show. Only act if stale state belongs elsewhere.
                const stale = d.cover_for_id != null and
                    !std.mem.eql(u8, d.cover_for_id.?, target_id);
                return if (stale) .clear else .none;
            };

            // Already loading or holding pixels for this exact id → leave it be.
            // Checked before suppression so a live cover always wins over a stale
            // failure record, independent of the `clear` invariant.
            if (d.cover_for_id) |id| {
                if (std.mem.eql(u8, id, target_id) and (d.cover_loading or d.has_pixels)) {
                    return .up_to_date;
                }
            }

            // Failure suppression: same id + same url, still within cooldown. A
            // changed URL or an elapsed cooldown both fall through to a retry.
            // Failure records persist across navigation — they are cleared only by
            // cooldown expiry, a thumb URL change, or a successful fetch.
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

    /// Letterboxed placement of an image inside a half-block mosaic grid (ROD-110).
    pub const HalfBlockFit = struct { w: u32, h: u32, off_x: u32, off_y: u32 };

    /// Fit `img_w × img_h` into a `grid_w × grid_h` half-pixel grid, preserving
    /// aspect. A half-block cell (`▀`) is full-cell *wide* but half-cell *tall*, so
    /// a half-pixel is `ppc` wide and `pph/2` tall — only square when cells are 2:1.
    /// We therefore compare in physical-pixel space using the terminal's reported
    /// `ppc`/`pph` (pixels per column/row). Pass `ppc == 0` or `pph == 0` when the
    /// terminal won't report pixel metrics, which falls back to assuming square
    /// half-pixels (the pre-fix behavior — correct on 2:1 cells, off elsewhere).
    /// Extracted as a pure helper so the aspect math is unit-testable.
    pub fn halfBlockFit(img_w: u32, img_h: u32, grid_w: u32, grid_h: u32, ppc: u32, pph: u32) HalfBlockFit {
        var fit_w = grid_w;
        var fit_h = grid_h;
        if (img_w != 0 and img_h != 0 and grid_w != 0 and grid_h != 0) {
            if (ppc != 0 and pph != 0) {
                // phys_w = grid_w*ppc, phys_h = grid_h*pph/2. Compare aspects:
                //   img_w*phys_h vs img_h*phys_w  →  img_w*grid_h*pph vs 2*img_h*grid_w*ppc
                const lhs = @as(u64, img_w) * grid_h * pph;
                const rhs = @as(u64, img_h) * grid_w * ppc * 2;
                if (lhs > rhs) {
                    // width-bound: fit_h = 2*img_h*grid_w*ppc / (img_w*pph)
                    fit_h = @intCast(@max(1, @as(u64, img_h) * grid_w * ppc * 2 / (@as(u64, img_w) * pph)));
                } else {
                    // height-bound: fit_w = img_w*grid_h*pph / (2*img_h*ppc)
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

    // ── state ────────────────────────────────────────────────────────────────
    /// Handle for the most recent cover-fetch thread. Joined before a new spawn.
    thread: ?std.Thread = null,
    /// Decoded cover pixels for the currently tracked show id.
    pixels: ?struct { rgba: []u8, w: u32, h: u32 } = null,
    /// Which show id the current cover state belongs to.
    for_id: ?[]const u8 = null,
    /// Whether a cover fetch/decode is in flight.
    loading: bool = false,
    /// Last show id whose cover fetch/decode failed. With `failed_url` +
    /// `failed_at_ms` this drives the cooldown-based retry policy (ROD-110).
    failed_for_id: ?[]const u8 = null,
    /// GPA-owned copy of the URL that failed, for URL-change recovery.
    failed_url: ?[]const u8 = null,
    /// `now_ms` timestamp of the last cover failure; gates the retry cooldown.
    failed_at_ms: i64 = 0,
    /// GPA-owned copy of the URL currently being fetched. Recorded so a failure
    /// can attribute the exact url even if the selection moved mid-flight.
    inflight_url: ?[]const u8 = null,
    /// Dominant fallback color when Kitty graphics are unavailable.
    fallback_color: vaxis.Color = .default,
    /// Uploaded Kitty image for the current cover, if any.
    image: ?vaxis.Image = null,
    /// Old Kitty image id to delete on the next draw pass.
    pending_free_id: ?u32 = null,

    // ── methods ────────────────────────────────────────────────────────────────
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

    /// Record a fetch/decode failure for the cooldown-based retry policy. `url`
    /// is the URL that failed (borrowed; duped here) so a later selection on the
    /// same id can detect whether the `thumb` changed and a retry is warranted.
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

    /// Take ownership of freshly decoded pixels for the current selection and
    /// derive the non-Kitty fallback colour. Owns the staging the controller
    /// used to do inline (ROD-160 review): supersede any failure record,
    /// drop the spent in-flight url, retire the old Kitty image, and free the
    /// previous pixel buffer before adopting `rgba` (caller transfers ownership).
    pub fn acceptPixels(self: *CoverState, gpa: Allocator, rgba: []u8, w: u32, h: u32) void {
        self.clearFailure(gpa);
        self.clearInflight(gpa); // fetch succeeded; in-flight url no longer needed
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

    /// Reconcile cover state with the current selection. The caller resolves
    /// `target_id`/`target_url` from navigation state — this struct never does.
    /// Returns true iff a fetch thread was started, so the caller can mark its
    /// own async-start clock (kept on App, since it's shared across loaders).
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
        // .fetch implies a non-null target and supersedes any prior failure.
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
