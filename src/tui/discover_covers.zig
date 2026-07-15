//! Discover grid multi-cover coordinator (ROD-243).
//!
//! URL-keyed pool of cover slots (pixels, Kitty image, failure cooldown) plus pure
//! fetch/eviction plans. Shares App's mutex-guarded `CoverCaches`. No threads here:
//! pump/workers in app.zig; transmit/half-block in view/discover.zig. Bounded ArrayList
//! (no std hashmaps); capacity is ROD-241.

const std = @import("std");
const vaxis = @import("vaxis");
const cover_mod = @import("../cover.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const CoverState = @import("cover_state.zig").CoverState;

/// Deferred Kitty free queue capacity (one frame of evictions). Fixed array so eviction
/// never OOMs and drops an id (ROD-243 review).
pub const max_pending_free = 256;

/// Shared with single-cover policy (ROD-110). Only cooldown expiry or success resets it.
pub const retry_cooldown_ms = CoverState.retry_cooldown_ms;

/// One grid cover. Owns an independent decoded-pixel copy (shared decoded LRU is tiny;
/// slot is the durable render store).
pub const CoverSlot = struct {
    pub const Status = enum { idle, loading, ready, failed };

    /// gpa-owned key. Duped so a page-1 refetch cannot free `Anime.thumb` under us (ROD-243).
    url: []const u8,
    status: Status = .idle,
    pixels: ?struct { rgba: []u8, w: u32, h: u32 } = null,
    fallback_color: vaxis.Color = .default,
    image: ?vaxis.Image = null,
    /// Superseded Kitty id awaiting freeImage on next flush.
    pending_free_id: ?u32 = null,
    /// Last failed fetch; 0 = never. Gates retry cooldown.
    failed_at_ms: i64 = 0,
    /// Last visible frame stamp for eviction recency.
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

    /// Free gpa-owned url + pixels. Kitty id needs vx/writer; pool lifts to pending_free first.
    fn freeOwned(self: *CoverSlot, gpa: Allocator) void {
        self.freeBuffers(gpa);
        gpa.free(self.url);
    }

    /// Adopt pixels (caller transfers `rgba`). Retires prior image; frees prior pixels.
    pub fn acceptPixels(self: *CoverSlot, gpa: Allocator, rgba: []u8, w: u32, h: u32) void {
        self.invalidateImage();
        self.freeBuffers(gpa);
        self.pixels = .{ .rgba = rgba, .w = w, .h = h };
        self.fallback_color = cover_mod.dominantColor(.{ .rgba = rgba, .w = w, .h = h });
        self.status = .ready;
        self.failed_at_ms = 0;
    }
};

/// Pure: which priority-ordered cards need a fetch (no pixels, not inflight, not cooling).
pub const FetchPlan = struct {
    has_pixels: []const bool,
    inflight: []const bool,
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

/// Pure: evict farthest from viewport first; never a currently-visible slot.
pub fn planEvictions(last_seen: []const u64, visible: []const bool, cap: usize, out: []usize) usize {
    std.debug.assert(last_seen.len == visible.len);
    const total = last_seen.len;
    if (total <= cap) return 0;

    var non_visible: usize = 0;
    for (visible) |v| {
        if (!v) non_visible += 1;
    }
    const want = @min(total - cap, non_visible);

    var n: usize = 0;
    while (n < want) : (n += 1) {
        var best: ?usize = null;
        for (last_seen, 0..) |ls, i| {
            if (visible[i]) continue;
            if (containsIdx(out[0..n], i)) continue;
            if (best == null or ls < last_seen[best.?]) best = i;
        }
        std.debug.assert(best != null);
        out[n] = best.?;
    }
    return n;
}

fn containsIdx(chosen: []const usize, i: usize) bool {
    for (chosen) |c| {
        if (c == i) return true;
    }
    return false;
}

/// Embed on App by value. Holds slot pool + lifecycle; fetch worker wired by app.
pub const DiscoverCovers = struct {
    slots: std.ArrayListUnmanaged(CoverSlot) = .empty,
    /// Kitty ids for next render flush (eviction). Fixed array; never OOM here.
    pending_free: [max_pending_free]u32 = undefined,
    pending_free_len: usize = 0,
    frame: u64 = 0,

    fn queueFree(self: *DiscoverCovers, id: u32) void {
        if (self.pending_free_len < max_pending_free) {
            self.pending_free[self.pending_free_len] = id;
            self.pending_free_len += 1;
        } else {
            log.debug("discover cover pending-free overflow; image {d} dropped", .{id});
        }
    }

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

    pub fn getConst(self: *const DiscoverCovers, url: []const u8) ?*const CoverSlot {
        const i = self.indexOf(url) orelse return null;
        return &self.slots.items[i];
    }

    /// Slot for `url`, creating idle with owned key. Null only on OOM.
    pub fn ensureSlot(self: *DiscoverCovers, gpa: Allocator, url: []const u8) ?*CoverSlot {
        if (self.indexOf(url)) |i| return &self.slots.items[i];
        const key = gpa.dupe(u8, url) catch return null;
        self.slots.append(gpa, .{ .url = key }) catch {
            gpa.free(key);
            return null;
        };
        return &self.slots.items[self.slots.items.len - 1];
    }

    /// Adopt pixels; free `rgba` if no slot can hold them (OOM mid-flight).
    pub fn acceptPixels(self: *DiscoverCovers, gpa: Allocator, url: []const u8, rgba: []u8, w: u32, h: u32) void {
        const slot = self.ensureSlot(gpa, url) orelse {
            gpa.free(rgba);
            return;
        };
        slot.acceptPixels(gpa, rgba, w, h);
    }

    pub fn markLoading(self: *DiscoverCovers, gpa: Allocator, url: []const u8) void {
        if (self.ensureSlot(gpa, url)) |s| s.status = .loading;
    }

    pub fn noteFailure(self: *DiscoverCovers, gpa: Allocator, url: []const u8, now_ms: i64) void {
        if (self.ensureSlot(gpa, url)) |s| {
            s.status = .failed;
            s.failed_at_ms = now_ms;
        }
    }

    /// Drop slot: defer Kitty ids, free pixels/key, swap-remove.
    pub fn evict(self: *DiscoverCovers, gpa: Allocator, url: []const u8) void {
        const i = self.indexOf(url) orelse return;
        const slot = &self.slots.items[i];
        if (slot.image) |img| self.queueFree(img.id);
        if (slot.pending_free_id) |id| self.queueFree(id);
        slot.freeOwned(gpa);
        _ = self.slots.swapRemove(i);
    }

    /// Transmit ready slots lacking Kitty image. UI-thread only (ROD-243): mutates `vx.next_img_id` and writes the tty.
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

    /// Release superseded + evicted Kitty ids. UI-thread only.
    pub fn flushPendingFrees(self: *DiscoverCovers, vx: *vaxis.Vaxis, writer: *std.Io.Writer) void {
        for (self.slots.items) |*slot| {
            if (slot.pending_free_id) |id| {
                vx.freeImage(writer, id);
                slot.pending_free_id = null;
            }
        }
        for (self.pending_free[0..self.pending_free_len]) |id| vx.freeImage(writer, id);
        self.pending_free_len = 0;
    }

    /// Teardown with image release (error-unwind/test). Quit `_exit` uses global clear.
    pub fn freeAll(self: *DiscoverCovers, gpa: Allocator, vx: *vaxis.Vaxis, writer: *std.Io.Writer) void {
        self.flushPendingFrees(vx, writer);
        for (self.slots.items) |*slot| {
            if (slot.image) |img| vx.freeImage(writer, img.id);
            slot.image = null;
        }
        self.deinit(gpa);
    }

    /// Free urls + pixels. Kitty images via freeAll or quit-path global clear.
    pub fn deinit(self: *DiscoverCovers, gpa: Allocator) void {
        for (self.slots.items) |*s| s.freeOwned(gpa);
        self.slots.deinit(gpa);
        self.slots = .empty;
        self.pending_free_len = 0;
    }
};

const testing = std.testing;

test "FetchPlan.eval selects only missing, not-inflight, not-cooling urls" {
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
        .failed_at = &.{now - retry_cooldown_ms},
        .now_ms = now,
    };
    var out: [1]usize = undefined;
    try testing.expectEqual(@as(usize, 1), p.eval(&out));
}

test "planEvictions drops the farthest-from-viewport slots, never a visible one" {
    const last_seen = [_]u64{ 20, 99, 30, 99, 10 };
    const visible = [_]bool{ false, true, false, true, false };
    var out: [5]usize = undefined;
    const n = planEvictions(&last_seen, &visible, 3, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 4), out[0]);
    try testing.expectEqual(@as(usize, 0), out[1]);
    try testing.expect(!containsIdx(out[0..n], 1));
    try testing.expect(!containsIdx(out[0..n], 3));
}

test "planEvictions can't shed below the visible floor" {
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

    const second = try testing.allocator.dupe(u8, &[_]u8{ 0x44, 0x55, 0x66, 0xff });
    dc.acceptPixels(testing.allocator, "https://img/a.png", second, 1, 1);
    try testing.expectEqual(@as(usize, 1), dc.slots.items.len);
}

test "DiscoverCovers.evict frees the slot and defers a pending image id" {
    var dc: DiscoverCovers = .{};
    defer dc.deinit(testing.allocator);

    const rgba = try testing.allocator.dupe(u8, &[_]u8{ 0x01, 0x02, 0x03, 0xff });
    dc.acceptPixels(testing.allocator, "https://img/b.png", rgba, 1, 1);
    dc.get("https://img/b.png").?.pending_free_id = 42;

    dc.evict(testing.allocator, "https://img/b.png");
    try testing.expectEqual(@as(usize, 0), dc.slots.items.len);
    try testing.expectEqual(@as(usize, 1), dc.pending_free_len);
    try testing.expectEqual(@as(u32, 42), dc.pending_free[0]);
    dc.evict(testing.allocator, "https://img/missing.png");
}

test "noteFailure records a cooldown that a fetch plan then suppresses" {
    var dc: DiscoverCovers = .{};
    defer dc.deinit(testing.allocator);

    const now: i64 = 200_000;
    dc.noteFailure(testing.allocator, "https://img/c.png", now);
    const slot = dc.get("https://img/c.png") orelse return error.TestUnexpectedResult;
    try testing.expect(slot.status == .failed);

    const p: FetchPlan = .{
        .has_pixels = &.{slot.pixels != null},
        .inflight = &.{false},
        .failed_at = &.{slot.failed_at_ms},
        .now_ms = now + 1,
    };
    var out: [1]usize = undefined;
    try testing.expectEqual(@as(usize, 0), p.eval(&out));
}
