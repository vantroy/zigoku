//! Zigoku — Discover grid multi-cover coordinator (ROD-243).
//!
//! The single-cover `CoverState` renders ONE poster; the Discover grid shows many
//! at once. This owns a URL-keyed pool of cover slots — each with its own decoded
//! pixels, Kitty image, and failure cooldown — plus the PURE logic that decides
//! which visible cards to fetch (`FetchPlan`) and which off-screen slots to evict
//! (`planEvictions`). It shares App's mutex-guarded `CoverCaches`, so a cover
//! fetched in Browse is reused here for free, and — like every subsystem in the
//! controller/subsystem split — is driven through explicit dependencies; it never
//! reaches into App or navigation state.
//!
//! Phase boundary (ROD-243): this cut is the data shape, the pure decision core,
//! and the per-slot pixel/image lifecycle — NO threads, NO rendering. The
//! serialized fetch worker, the events, and the geometry-aware pump live in
//! app.zig (next chunk); the transmit/half-block render pass lives in
//! view/discover.zig. Storage is a bounded `ArrayListUnmanaged` with linear lookup
//! — matching `util/lru.zig`'s array style (the codebase keeps no std hashmaps) and
//! the small pool size (a couple grid pages; capacity is ROD-241).

const std = @import("std");
const vaxis = @import("vaxis");
const cover_mod = @import("../cover.zig");
const workers = @import("workers.zig");

const Allocator = std.mem.Allocator;
const CoverCaches = workers.CoverCaches;
const CoverState = @import("cover_state.zig").CoverState;

/// A failed cover suppresses refetch of the same url for this long, then allows one
/// retry — shared with the single-cover policy so both back off identically
/// (ROD-110). A changed selection elsewhere doesn't reset it; only cooldown expiry
/// or a successful fetch does.
pub const retry_cooldown_ms = CoverState.retry_cooldown_ms;

/// One grid cover. Owns an INDEPENDENT decoded-pixel copy — the shared decoded LRU
/// is tiny (cap 5) and is decode-avoidance, not the render store, so the slot is
/// the durable source that survives eviction and re-transmits on window re-entry.
pub const CoverSlot = struct {
    pub const Status = enum { idle, loading, ready, failed };

    /// gpa-owned key: the cover url. Duped on insert so a slot never borrows an
    /// `Anime.thumb` that a page-1 refetch (`DiscoverState.clearSlot`) could free
    /// out from under it (ROD-243).
    url: []const u8,
    status: Status = .idle,
    /// gpa-owned decoded pixels for `url`.
    pixels: ?struct { rgba: []u8, w: u32, h: u32 } = null,
    /// Quantized dominant colour for the non-Kitty half-block / flat fallback.
    fallback_color: vaxis.Color = .default,
    /// Uploaded Kitty image, once transmitted (render pass, UI thread).
    image: ?vaxis.Image = null,
    /// Superseded Kitty image id awaiting a `freeImage` on the next render flush
    /// (a same-url re-decode retires the old image here).
    pending_free_id: ?u32 = null,
    /// `now_ms` of the last failed fetch; gates the retry cooldown. 0 = never failed.
    failed_at_ms: i64 = 0,
    /// Render-frame stamp of the last time this slot was visible — recency for
    /// `planEvictions`, which keeps the slots nearest the viewport.
    last_seen_frame: u64 = 0,

    fn invalidateImage(self: *CoverSlot) void {
        if (self.image) |img| {
            self.pending_free_id = img.id;
            self.image = null;
        }
    }

    fn freeBuffers(self: *CoverSlot, gpa: Allocator) void {
        if (self.pixels) |px| {
            gpa.free(px.rgba);
            self.pixels = null;
        }
        self.fallback_color = .default;
    }

    /// Free everything the slot owns on the gpa: its url key and its pixels. The
    /// Kitty image id is NOT freed here (it needs `vx`/`writer` on the UI thread) —
    /// the pool lifts it into `pending_free` before dropping the slot.
    fn freeOwned(self: *CoverSlot, gpa: Allocator) void {
        self.freeBuffers(gpa);
        gpa.free(self.url);
    }

    /// Adopt freshly decoded pixels (caller transfers ownership of `rgba`) and
    /// derive the fallback colour. Retires any prior image into `pending_free_id`
    /// and frees prior pixels first — mirrors `CoverState.acceptPixels`.
    pub fn acceptPixels(self: *CoverSlot, gpa: Allocator, rgba: []u8, w: u32, h: u32) void {
        self.invalidateImage();
        self.freeBuffers(gpa);
        self.pixels = .{ .rgba = rgba, .w = w, .h = h };
        self.fallback_color = cover_mod.dominantColor(.{ .rgba = rgba, .w = w, .h = h });
        self.status = .ready;
        self.failed_at_ms = 0;
    }
};

/// Pure: pick which of the priority-ordered visible cards to fetch — those with no
/// pixels yet, not already in flight, and not inside the failure cooldown. Writes
/// the chosen indices (into the parallel input arrays) to `out` and returns the
/// count. No threads, no I/O — unit-testable, mirroring `CoverState.Decision.eval`.
/// The caller (the pump) builds the parallel arrays from live slot state for the
/// current visible+prefetch url set, then spawns a fetch for `out[0..n]`.
pub const FetchPlan = struct {
    /// Slot already holds decoded pixels (no fetch needed).
    has_pixels: []const bool,
    /// A fetch for this url is already in flight (queued or on the worker).
    inflight: []const bool,
    /// `failed_at_ms` per url (0 = never failed); with `now_ms` gates the cooldown.
    failed_at: []const i64,
    now_ms: i64,

    pub fn eval(p: FetchPlan, out: []usize) usize {
        std.debug.assert(p.inflight.len == p.has_pixels.len);
        std.debug.assert(p.failed_at.len == p.has_pixels.len);
        var n: usize = 0;
        for (p.has_pixels, 0..) |hp, i| {
            if (hp or p.inflight[i]) continue;
            const cooling = p.failed_at[i] != 0 and (p.now_ms -% p.failed_at[i]) < retry_cooldown_ms;
            if (cooling) continue;
            out[n] = i;
            n += 1;
        }
        return n;
    }
};

/// Pure: choose which slots to evict to get back to `cap`, dropping the slots
/// farthest from the viewport first (smallest `last_seen_frame`) and NEVER a
/// currently-visible slot. Writes evicted indices to `out` and returns the count.
/// Allocation-free: the pool is small, so an O(want·n) greedy selection beats
/// threading a sort scratch buffer through. `last_seen` and `visible` are parallel.
pub fn planEvictions(last_seen: []const u64, visible: []const bool, cap: usize, out: []usize) usize {
    std.debug.assert(last_seen.len == visible.len);
    const total = last_seen.len;
    if (total <= cap) return 0;

    var non_visible: usize = 0;
    for (visible) |v| {
        if (!v) non_visible += 1;
    }
    // Can't evict visible slots, so we can only shed down to `non_visible` of them.
    const want = @min(total - cap, non_visible);

    var n: usize = 0;
    while (n < want) : (n += 1) {
        var best: ?usize = null;
        for (last_seen, 0..) |ls, i| {
            if (visible[i]) continue;
            if (containsIdx(out[0..n], i)) continue;
            if (best == null or ls < last_seen[best.?]) best = i;
        }
        out[n] = best.?; // want ≤ non_visible guarantees a candidate exists
    }
    return n;
}

fn containsIdx(chosen: []const usize, i: usize) bool {
    for (chosen) |c| {
        if (c == i) return true;
    }
    return false;
}

/// The Discover grid multi-cover coordinator. Embed by value on App
/// (`discover_covers: DiscoverCovers = .{}`); the shared `CoverCaches` and the
/// fetch worker are wired in the next chunk. Holds the slot pool and the lifecycle.
pub const DiscoverCovers = struct {
    /// URL-keyed slot pool, linear-scanned. Bounded by the eviction cap; each slot
    /// owns its url key and pixels.
    slots: std.ArrayListUnmanaged(CoverSlot) = .empty,
    /// Kitty image ids awaiting release on the next render flush — populated when a
    /// slot is evicted (the slot is gone, but its image must still be freed on the
    /// UI thread). Same-url re-decodes use the slot's own `pending_free_id`.
    pending_free: std.ArrayListUnmanaged(u32) = .empty,
    /// Monotonic render-frame counter; stamps `last_seen_frame` for eviction recency.
    frame: u64 = 0,

    pub fn indexOf(self: *const DiscoverCovers, url: []const u8) ?usize {
        for (self.slots.items, 0..) |*s, i| {
            if (std.mem.eql(u8, s.url, url)) return i;
        }
        return null;
    }

    pub fn get(self: *DiscoverCovers, url: []const u8) ?*CoverSlot {
        const i = self.indexOf(url) orelse return null;
        return &self.slots.items[i];
    }

    /// Const lookup for the render pass (`view/discover.zig` holds `*const App`).
    pub fn getConst(self: *const DiscoverCovers, url: []const u8) ?*const CoverSlot {
        const i = self.indexOf(url) orelse return null;
        return &self.slots.items[i];
    }

    /// Return the slot for `url`, creating an idle one (with an owned key copy) if
    /// absent. Null only on OOM.
    pub fn ensureSlot(self: *DiscoverCovers, gpa: Allocator, url: []const u8) ?*CoverSlot {
        if (self.indexOf(url)) |i| return &self.slots.items[i];
        const key = gpa.dupe(u8, url) catch return null;
        self.slots.append(gpa, .{ .url = key }) catch {
            gpa.free(key);
            return null;
        };
        return &self.slots.items[self.slots.items.len - 1];
    }

    /// Adopt freshly decoded pixels for `url` into its slot (creating one if the
    /// slot was evicted mid-flight). Caller transfers ownership of `rgba`; on OOM
    /// with no slot to hold it, the pixels are freed rather than leaked.
    pub fn acceptPixels(self: *DiscoverCovers, gpa: Allocator, url: []const u8, rgba: []u8, w: u32, h: u32) void {
        const slot = self.ensureSlot(gpa, url) orelse {
            gpa.free(rgba);
            return;
        };
        slot.acceptPixels(gpa, rgba, w, h);
    }

    /// Mark `url`'s slot as a fetch-in-flight (creating it if needed).
    pub fn markLoading(self: *DiscoverCovers, gpa: Allocator, url: []const u8) void {
        if (self.ensureSlot(gpa, url)) |s| s.status = .loading;
    }

    /// Record a failed fetch so `FetchPlan` suppresses a refetch for the cooldown.
    /// Ensures the slot exists so a failure on the very first fetch still records.
    pub fn noteFailure(self: *DiscoverCovers, gpa: Allocator, url: []const u8, now_ms: i64) void {
        if (self.ensureSlot(gpa, url)) |s| {
            s.status = .failed;
            s.failed_at_ms = now_ms;
        }
    }

    /// Drop the slot for `url`: defer its Kitty image id(s) to `pending_free`, free
    /// its pixels and key, and swap-remove it. The image is released by the render
    /// flush (UI thread); a no-op if `url` has no slot.
    pub fn evict(self: *DiscoverCovers, gpa: Allocator, url: []const u8) void {
        const i = self.indexOf(url) orelse return;
        const slot = &self.slots.items[i];
        if (slot.image) |img| self.pending_free.append(gpa, img.id) catch {};
        if (slot.pending_free_id) |id| self.pending_free.append(gpa, id) catch {};
        slot.freeOwned(gpa);
        _ = self.slots.swapRemove(i);
    }

    /// Transmit the decoded pixels of every ready slot lacking a Kitty image to the
    /// terminal (ROD-243). UI-thread only — `transmitPreEncodedImage` mutates
    /// `vx.next_img_id` and writes the tty. Runs once per slot: a transmitted slot
    /// keeps its `image` and is skipped next frame. No-op without Kitty graphics
    /// (the grid uses the half-block fallback then). Mirrors `detail.ensureCoverImage`.
    pub fn ensureImages(self: *DiscoverCovers, gpa: Allocator, vx: *vaxis.Vaxis, writer: *std.Io.Writer) void {
        if (!vx.caps.kitty_graphics) return;
        for (self.slots.items) |*slot| {
            if (slot.image != null) continue;
            const px = slot.pixels orelse continue;
            if (px.w == 0 or px.h == 0 or px.w > std.math.maxInt(u16) or px.h > std.math.maxInt(u16)) continue;
            const enc_len = std.base64.standard.Encoder.calcSize(px.rgba.len);
            const b64 = gpa.alloc(u8, enc_len) catch continue;
            defer gpa.free(b64);
            const encoded = std.base64.standard.Encoder.encode(b64, px.rgba);
            slot.image = vx.transmitPreEncodedImage(writer, encoded, @intCast(px.w), @intCast(px.h), .rgba) catch continue;
        }
    }

    /// Release Kitty image ids superseded this frame: each slot's `pending_free_id`
    /// (a same-url re-decode retired the old image) and every id queued by an
    /// eviction. UI-thread only (`freeImage` writes the tty). Mirrors
    /// `CoverState.flushPendingFree`, but over the whole pool.
    pub fn flushPendingFrees(self: *DiscoverCovers, vx: *vaxis.Vaxis, writer: *std.Io.Writer) void {
        for (self.slots.items) |*slot| {
            if (slot.pending_free_id) |id| {
                vx.freeImage(writer, id);
                slot.pending_free_id = null;
            }
        }
        for (self.pending_free.items) |id| vx.freeImage(writer, id);
        self.pending_free.clearRetainingCapacity();
    }

    /// Teardown with image release: free every resident + pending Kitty image (UI
    /// thread), then the owned memory. Call from `deinitOwnedState` after the cover
    /// workers join. The quit `_exit` path skips this and relies on the global
    /// `a=d,q=2` clear; this is the error-unwind/test path. Mirrors `CoverState.freeAll`.
    pub fn freeAll(self: *DiscoverCovers, gpa: Allocator, vx: *vaxis.Vaxis, writer: *std.Io.Writer) void {
        self.flushPendingFrees(vx, writer);
        for (self.slots.items) |*slot| {
            if (slot.image) |img| vx.freeImage(writer, img.id);
            slot.image = null;
        }
        self.deinit(gpa);
    }

    /// Release the pool's owned memory: every slot's url + pixels, then the slot and
    /// pending-free lists. Kitty images are NOT freed here — `freeAll` flushes them
    /// first on the error-unwind path, and the quit-path global clear (`a=d,q=2`)
    /// catches them on the normal `_exit`.
    pub fn deinit(self: *DiscoverCovers, gpa: Allocator) void {
        for (self.slots.items) |*s| s.freeOwned(gpa);
        self.slots.deinit(gpa);
        self.slots = .empty;
        self.pending_free.deinit(gpa);
        self.pending_free = .empty;
    }
};

const testing = std.testing;

test "FetchPlan.eval selects only missing, not-inflight, not-cooling urls" {
    // 5 urls: 0 ready, 1 in-flight, 2 cooling (fresh failure), 3 cooled-off failure,
    // 4 untouched. Only 3 and 4 should be fetched.
    const now: i64 = 100_000;
    const p: FetchPlan = .{
        .has_pixels = &.{ true, false, false, false, false },
        .inflight = &.{ false, true, false, false, false },
        .failed_at = &.{ 0, 0, now - 1_000, now - (retry_cooldown_ms + 1), 0 },
        .now_ms = now,
    };
    var out: [5]usize = undefined;
    const n = p.eval(&out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 3), out[0]);
    try testing.expectEqual(@as(usize, 4), out[1]);
}

test "FetchPlan.eval re-admits a url exactly at the cooldown boundary" {
    const now: i64 = 50_000;
    const p: FetchPlan = .{
        .has_pixels = &.{false},
        .inflight = &.{false},
        // elapsed == retry_cooldown_ms is NOT < cooldown → admitted.
        .failed_at = &.{now - retry_cooldown_ms},
        .now_ms = now,
    };
    var out: [1]usize = undefined;
    try testing.expectEqual(@as(usize, 1), p.eval(&out));
}

test "planEvictions drops the farthest-from-viewport slots, never a visible one" {
    // 5 slots, cap 3 → drop 2. Slots 1 and 3 are visible (protected). Among the
    // non-visible {0,2,4}, evict the two oldest by last_seen: 4 (10) and 0 (20).
    const last_seen = [_]u64{ 20, 99, 30, 99, 10 };
    const visible = [_]bool{ false, true, false, true, false };
    var out: [5]usize = undefined;
    const n = planEvictions(&last_seen, &visible, 3, &out);
    try testing.expectEqual(@as(usize, 2), n);
    // Oldest-first: index 4 (10) then index 0 (20).
    try testing.expectEqual(@as(usize, 4), out[0]);
    try testing.expectEqual(@as(usize, 0), out[1]);
    // A visible slot is never chosen.
    try testing.expect(!containsIdx(out[0..n], 1));
    try testing.expect(!containsIdx(out[0..n], 3));
}

test "planEvictions can't shed below the visible floor" {
    // cap 1 but 3 of 4 slots are visible → only the single non-visible one evicts.
    const last_seen = [_]u64{ 5, 6, 7, 8 };
    const visible = [_]bool{ true, true, true, false };
    var out: [4]usize = undefined;
    const n = planEvictions(&last_seen, &visible, 1, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, 3), out[0]);
}

test "planEvictions is a no-op at or under cap" {
    const last_seen = [_]u64{ 1, 2, 3 };
    const visible = [_]bool{ false, false, false };
    var out: [3]usize = undefined;
    try testing.expectEqual(@as(usize, 0), planEvictions(&last_seen, &visible, 3, &out));
    try testing.expectEqual(@as(usize, 0), planEvictions(&last_seen, &visible, 9, &out));
}

test "DiscoverCovers.acceptPixels adopts pixels and re-accept frees the prior (leak-clean)" {
    var dc: DiscoverCovers = .{};
    defer dc.deinit(testing.allocator);

    const first = try testing.allocator.dupe(u8, &[_]u8{ 0x10, 0x20, 0x30, 0xff });
    dc.acceptPixels(testing.allocator, "https://img/a.png", first, 1, 1);

    const slot = dc.get("https://img/a.png") orelse return error.TestUnexpectedResult;
    try testing.expect(slot.status == .ready);
    try testing.expect(slot.pixels != null);
    try testing.expectEqual(@as(usize, 4), slot.pixels.?.rgba.len);

    // Re-accept for the same url must free the prior buffer (the testing allocator
    // fails the test on a leak or double-free) and replace it — one slot, not two.
    const second = try testing.allocator.dupe(u8, &[_]u8{ 0x44, 0x55, 0x66, 0xff });
    dc.acceptPixels(testing.allocator, "https://img/a.png", second, 1, 1);
    try testing.expectEqual(@as(usize, 1), dc.slots.items.len);
}

test "DiscoverCovers.evict frees the slot and defers a pending image id" {
    var dc: DiscoverCovers = .{};
    defer dc.deinit(testing.allocator);

    const rgba = try testing.allocator.dupe(u8, &[_]u8{ 0x01, 0x02, 0x03, 0xff });
    dc.acceptPixels(testing.allocator, "https://img/b.png", rgba, 1, 1);
    // Stand in for a transmitted image awaiting release (no vaxis.Image needed).
    dc.get("https://img/b.png").?.pending_free_id = 42;

    dc.evict(testing.allocator, "https://img/b.png");
    try testing.expectEqual(@as(usize, 0), dc.slots.items.len);
    try testing.expectEqual(@as(usize, 1), dc.pending_free.items.len);
    try testing.expectEqual(@as(u32, 42), dc.pending_free.items[0]);
    // Evicting an absent url is a no-op.
    dc.evict(testing.allocator, "https://img/missing.png");
}

test "noteFailure records a cooldown that a fetch plan then suppresses" {
    var dc: DiscoverCovers = .{};
    defer dc.deinit(testing.allocator);

    const now: i64 = 200_000;
    dc.noteFailure(testing.allocator, "https://img/c.png", now);
    const slot = dc.get("https://img/c.png") orelse return error.TestUnexpectedResult;
    try testing.expect(slot.status == .failed);

    // Feed that slot's state into the pure planner: still cooling → not fetched.
    const p: FetchPlan = .{
        .has_pixels = &.{slot.pixels != null},
        .inflight = &.{false},
        .failed_at = &.{slot.failed_at_ms},
        .now_ms = now + 1,
    };
    var out: [1]usize = undefined;
    try testing.expectEqual(@as(usize, 0), p.eval(&out));
}
