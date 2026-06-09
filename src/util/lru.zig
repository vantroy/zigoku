const std = @import("std");

const Allocator = std.mem.Allocator;

/// Value hooks for owned slice values.
pub fn SliceValueOps(comptime Slice: type) type {
    const info = @typeInfo(Slice);
    if (info != .pointer or info.pointer.size != .slice) {
        @compileError("SliceValueOps expects a slice type");
    }
    const Child = info.pointer.child;

    return struct {
        pub fn freeValue(alloc: Allocator, value: Slice) void {
            alloc.free(value);
        }

        pub fn valueBytes(value: Slice) usize {
            return value.len * @sizeOf(Child);
        }
    };
}

/// Tiny ownership-taking LRU for byte-slice keys and small fixed capacities.
///
/// Ownership for values is explicit: callers provide `Hooks.freeValue` and
/// `Hooks.valueBytes` for `V`. That keeps reuse honest instead of pretending the
/// cache can magically infer whether a struct field is owned or borrowed.
pub fn LruCache(comptime K: type, comptime V: type, comptime cap: usize, comptime Hooks: type) type {
    if (cap == 0) @compileError("LruCache cap must be > 0");
    comptime assertByteSliceKey(K);
    comptime assertHooks(V, Hooks);

    return struct {
        const Self = @This();
        const Entry = struct {
            key: K,
            value: V,
            bytes: usize,
        };

        entries: [cap]Entry = undefined,
        len: usize = 0,
        total_bytes: usize = 0,

        /// Lookup by key and promote the hit to most-recent.
        pub fn get(self: *Self, key: K) ?V {
            const idx = self.indexOf(key) orelse return null;
            if (idx != 0) self.promote(idx);
            return self.entries[0].value;
        }

        /// Insert a value the cache now owns. Existing values are freed.
        pub fn putOwned(self: *Self, alloc: Allocator, key: K, value: V) !void {
            if (self.indexOf(key)) |idx| {
                const key_len = self.entries[idx].key.len;
                self.total_bytes -= self.entries[idx].bytes;
                Hooks.freeValue(alloc, self.entries[idx].value);
                self.entries[idx].value = value;
                self.entries[idx].bytes = key_len + Hooks.valueBytes(value);
                self.total_bytes += self.entries[idx].bytes;
                if (idx != 0) self.promote(idx);
                return;
            }

            try self.insertOwned(alloc, key, value, key.len + Hooks.valueBytes(value));
        }

        /// Try to cache a value without letting total retained bytes exceed
        /// `max_total_bytes`. Returns true if the value was cached; false means
        /// the caller still owns `value` and should free or use it itself.
        pub fn putOwnedBounded(self: *Self, alloc: Allocator, key: K, value: V, max_total_bytes: usize) !bool {
            const entry_bytes = key.len + Hooks.valueBytes(value);
            if (entry_bytes > max_total_bytes) return false;

            try self.putOwned(alloc, key, value);
            while (self.total_bytes > max_total_bytes and self.len > 0) self.evictTail(alloc);
            return self.indexOf(key) != null;
        }

        pub fn currentBytes(self: *const Self) usize {
            return self.total_bytes;
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            while (self.len > 0) self.evictTail(alloc);
        }

        fn insertOwned(self: *Self, alloc: Allocator, key: K, value: V, entry_bytes: usize) !void {
            const key_copy = try dupKey(alloc, key);
            errdefer freeKey(alloc, key_copy);

            if (self.len == cap) self.evictTail(alloc);

            var i: usize = self.len;
            while (i > 0) : (i -= 1) self.entries[i] = self.entries[i - 1];
            self.entries[0] = .{ .key = key_copy, .value = value, .bytes = entry_bytes };
            self.len += 1;
            self.total_bytes += entry_bytes;
        }

        fn evictTail(self: *Self, alloc: Allocator) void {
            if (self.len == 0) return;
            const idx = self.len - 1;
            self.total_bytes -= self.entries[idx].bytes;
            freeEntry(alloc, &self.entries[idx]);
            self.len = idx;
        }

        fn indexOf(self: *const Self, key: K) ?usize {
            for (self.entries[0..self.len], 0..) |entry, i| {
                if (keysEql(entry.key, key)) return i;
            }
            return null;
        }

        fn promote(self: *Self, idx: usize) void {
            const hit = self.entries[idx];
            var i = idx;
            while (i > 0) : (i -= 1) self.entries[i] = self.entries[i - 1];
            self.entries[0] = hit;
        }

        fn freeEntry(alloc: Allocator, entry: *Entry) void {
            freeKey(alloc, entry.key);
            Hooks.freeValue(alloc, entry.value);
        }
    };
}

fn assertByteSliceKey(comptime K: type) void {
    const info = @typeInfo(K);
    if (info != .pointer or info.pointer.size != .slice or !isByteType(info.pointer.child)) {
        @compileError("LruCache keys must be []u8 or []const u8");
    }
}

fn isByteType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => |i| i.bits == 8,
        else => false,
    };
}

fn assertHooks(comptime V: type, comptime Hooks: type) void {
    if (!@hasDecl(Hooks, "freeValue") or !@hasDecl(Hooks, "valueBytes")) {
        @compileError("LruCache hooks must define freeValue(alloc, value) and valueBytes(value)");
    }
    const free_sig = @typeInfo(@TypeOf(Hooks.freeValue));
    const bytes_sig = @typeInfo(@TypeOf(Hooks.valueBytes));
    if (free_sig != .@"fn" or bytes_sig != .@"fn") {
        @compileError("LruCache hooks must expose functions");
    }
    if (free_sig.@"fn".params.len != 2 or free_sig.@"fn".params[1].type != V) {
        @compileError("Hooks.freeValue must accept (Allocator, V)");
    }
    if (bytes_sig.@"fn".params.len != 1 or bytes_sig.@"fn".params[0].type != V or bytes_sig.@"fn".return_type != usize) {
        @compileError("Hooks.valueBytes must accept (V) and return usize");
    }
}

fn keysEql(a: anytype, b: @TypeOf(a)) bool {
    return std.mem.eql(u8, a, b);
}

fn dupKey(alloc: Allocator, key: anytype) !@TypeOf(key) {
    const copy = try alloc.alloc(u8, key.len);
    @memcpy(copy, key);
    return copy;
}

fn freeKey(alloc: Allocator, key: anytype) void {
    alloc.free(key);
}

test "lru promotes hits and evicts least-recent entry" {
    const Cache = LruCache([]const u8, []u8, 2, SliceValueOps([]u8));
    var cache: Cache = .{};
    defer cache.deinit(std.testing.allocator);

    try cache.putOwned(std.testing.allocator, "one", try std.testing.allocator.dupe(u8, "1"));
    try cache.putOwned(std.testing.allocator, "two", try std.testing.allocator.dupe(u8, "2"));

    const hit = cache.get("one") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("1", hit);

    try cache.putOwned(std.testing.allocator, "three", try std.testing.allocator.dupe(u8, "3"));

    try std.testing.expect(cache.get("two") == null);
    try std.testing.expectEqualStrings("3", cache.get("three") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("1", cache.get("one") orelse return error.TestUnexpectedResult);
}

test "lru replacement frees old value and keeps key hot" {
    const Cache = LruCache([]const u8, []u8, 2, SliceValueOps([]u8));
    var cache: Cache = .{};
    defer cache.deinit(std.testing.allocator);

    try cache.putOwned(std.testing.allocator, "one", try std.testing.allocator.dupe(u8, "old"));
    try cache.putOwned(std.testing.allocator, "two", try std.testing.allocator.dupe(u8, "two"));
    try cache.putOwned(std.testing.allocator, "one", try std.testing.allocator.dupe(u8, "new"));

    try std.testing.expectEqualStrings("new", cache.get("one") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("two", cache.get("two") orelse return error.TestUnexpectedResult);
}

test "lru frees owned struct values through explicit hooks" {
    const Pixels = struct {
        rgba: []u8,
        w: u32,
        h: u32,
    };
    const PixelOps = struct {
        pub fn freeValue(alloc: Allocator, value: Pixels) void {
            alloc.free(value.rgba);
        }

        pub fn valueBytes(value: Pixels) usize {
            return value.rgba.len;
        }
    };
    const Cache = LruCache([]const u8, Pixels, 1, PixelOps);
    var cache: Cache = .{};
    defer cache.deinit(std.testing.allocator);

    try cache.putOwned(std.testing.allocator, "one", .{
        .rgba = try std.testing.allocator.alloc(u8, 4),
        .w = 1,
        .h = 1,
    });
    try cache.putOwned(std.testing.allocator, "two", .{
        .rgba = try std.testing.allocator.alloc(u8, 8),
        .w = 2,
        .h = 1,
    });

    try std.testing.expect(cache.get("one") == null);
    const hit = cache.get("two") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2), hit.w);
    try std.testing.expectEqual(@as(usize, 8), hit.rgba.len);
}

test "lru bounded insert evicts to stay within byte budget" {
    const Cache = LruCache([]const u8, []u8, 3, SliceValueOps([]u8));
    var cache: Cache = .{};
    defer cache.deinit(std.testing.allocator);

    try std.testing.expect(try cache.putOwnedBounded(std.testing.allocator, "a", try std.testing.allocator.dupe(u8, "111"), 8));
    try std.testing.expect(try cache.putOwnedBounded(std.testing.allocator, "b", try std.testing.allocator.dupe(u8, "222"), 8));
    try std.testing.expectEqual(@as(usize, 8), cache.currentBytes());
    try std.testing.expect(try cache.putOwnedBounded(std.testing.allocator, "c", try std.testing.allocator.dupe(u8, "333"), 8));
    try std.testing.expect(cache.currentBytes() <= 8);
    try std.testing.expect(cache.get("a") == null);
    try std.testing.expectEqualStrings("222", cache.get("b") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("333", cache.get("c") orelse return error.TestUnexpectedResult);
}

test "lru bounded insert rejects oversize value without taking ownership" {
    const Cache = LruCache([]const u8, []u8, 2, SliceValueOps([]u8));
    var cache: Cache = .{};
    defer cache.deinit(std.testing.allocator);

    const huge = try std.testing.allocator.alloc(u8, 9);
    defer std.testing.allocator.free(huge);
    try std.testing.expect(!(try cache.putOwnedBounded(std.testing.allocator, "x", huge, 8)));
    try std.testing.expectEqual(@as(usize, 0), cache.currentBytes());
}
