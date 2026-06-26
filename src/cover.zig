const std = @import("std");
const vaxis = @import("vaxis");

const Allocator = std.mem.Allocator;

// ── decode-path history (ROD-110) ────────────────────────────────────────────
// The original cover pipeline decoded with `zigimg` and had to *gate the real
// decode/render path out of Debug builds*, because Zig 0.16 blew up codegenning
// the exe when that path was live in Debug. ReleaseSafe carried the real path.
//
// That gate is GONE. Commit 11112d5 replaced the decode path with `stb_image`
// (C, via `src/c/stb_image_impl.c`), which sidesteps the codegen blowup — Debug,
// ReleaseSafe and `zig build test` now all run the same real decode. There is no
// longer a build-mode `if` around decoding; if you ever reintroduce a Zig-native
// decoder, re-verify Debug codegen before trusting it.

extern fn stbi_load_from_memory(
    buffer: [*c]const u8,
    len: c_int,
    x: [*c]c_int,
    y: [*c]c_int,
    channels_in_file: [*c]c_int,
    desired_channels: c_int,
) ?[*]u8;
extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;

pub const Pixels = struct {
    rgba: []u8,
    w: u32,
    h: u32,
};

pub const Dimensions = struct {
    w: u32,
    h: u32,
};

pub fn probeDimensions(encoded: []const u8) ?Dimensions {
    return probePngDimensions(encoded) orelse probeJpegDimensions(encoded);
}

pub fn decodeRgba(alloc: Allocator, encoded: []const u8) !Pixels {
    if (encoded.len == 0) return error.DecodeFailed;

    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const ptr = stbi_load_from_memory(
        encoded.ptr,
        @intCast(encoded.len),
        &w,
        &h,
        &channels,
        4,
    ) orelse return error.DecodeFailed;
    defer stbi_image_free(@ptrCast(ptr));

    if (w <= 0 or h <= 0) return error.DecodeFailed;
    const width: u32 = @intCast(w);
    const height: u32 = @intCast(h);
    const pixel_count = std.math.mul(usize, width, height) catch return error.DecodeFailed;
    const rgba_len = std.math.mul(usize, pixel_count, 4) catch return error.DecodeFailed;

    const rgba = try alloc.alloc(u8, rgba_len);
    @memcpy(rgba, @as([*]const u8, @ptrCast(ptr))[0..rgba_len]);
    return .{ .rgba = rgba, .w = width, .h = height };
}

fn readBeU16(buf: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, @ptrCast(buf[off..][0..2]), .big);
}

fn readBeU32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, @ptrCast(buf[off..][0..4]), .big);
}

fn probePngDimensions(encoded: []const u8) ?Dimensions {
    const png_sig = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    if (encoded.len < 24 or !std.mem.eql(u8, encoded[0..8], &png_sig)) return null;
    return .{
        .w = readBeU32(encoded, 16),
        .h = readBeU32(encoded, 20),
    };
}

fn probeJpegDimensions(encoded: []const u8) ?Dimensions {
    if (encoded.len < 4 or encoded[0] != 0xff or encoded[1] != 0xd8) return null;

    var i: usize = 2;
    while (i + 3 < encoded.len) {
        while (i < encoded.len and encoded[i] == 0xff) i += 1;
        if (i >= encoded.len) return null;

        const marker = encoded[i];
        i += 1;
        switch (marker) {
            0xd8, 0xd9, 0x01, 0xd0...0xd7 => continue,
            else => {},
        }
        if (i + 1 >= encoded.len) return null;
        const seg_len = readBeU16(encoded, i);
        if (seg_len < 2 or i + seg_len > encoded.len) return null;

        const is_sof = switch (marker) {
            0xc0...0xc3, 0xc5...0xc7, 0xc9...0xcb, 0xcd...0xcf => true,
            else => false,
        };
        if (is_sof) {
            if (seg_len < 7) return null;
            return .{
                .h = readBeU16(encoded, i + 3),
                .w = readBeU16(encoded, i + 5),
            };
        }
        i += seg_len;
    }
    return null;
}

pub fn dominantColor(pixels: Pixels) vaxis.Color {
    if (pixels.rgba.len < 4) return .{ .rgb = .{ 32, 32, 32 } };

    var sum_r: u64 = 0;
    var sum_g: u64 = 0;
    var sum_b: u64 = 0;
    var samples: u64 = 0;
    var i: usize = 0;
    while (i + 3 < pixels.rgba.len) : (i += 16) {
        const alpha = pixels.rgba[i + 3];
        if (alpha == 0) continue;
        sum_r += pixels.rgba[i];
        sum_g += pixels.rgba[i + 1];
        sum_b += pixels.rgba[i + 2];
        samples += 1;
    }
    if (samples == 0) return .{ .rgb = .{ 32, 32, 32 } };

    return .{ .rgb = .{
        @intCast(sum_r / samples),
        @intCast(sum_g / samples),
        @intCast(sum_b / samples),
    } };
}

test "probeDimensions reads png width and height" {
    const png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x04, 0x00, 0x00, 0x00, 0xb5, 0x1c, 0x0c,
        0x02, 0x00, 0x00, 0x00, 0x0b, 0x49, 0x44, 0x41,
        0x54, 0x78, 0xda, 0x63, 0xfc, 0xff, 0x1f, 0x00,
        0x03, 0x03, 0x02, 0x00, 0xef, 0x9a, 0xf6, 0x64,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44,
        0xae, 0x42, 0x60, 0x82,
    };
    const dims = probeDimensions(&png) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), dims.w);
    try std.testing.expectEqual(@as(u32, 1), dims.h);
}

test "decodeRgba decodes tiny png into owned rgba pixels" {
    const png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x04, 0x00, 0x00, 0x00, 0xb5, 0x1c, 0x0c,
        0x02, 0x00, 0x00, 0x00, 0x0b, 0x49, 0x44, 0x41,
        0x54, 0x78, 0xda, 0x63, 0xfc, 0xff, 0x1f, 0x00,
        0x03, 0x03, 0x02, 0x00, 0xef, 0x9a, 0xf6, 0x64,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44,
        0xae, 0x42, 0x60, 0x82,
    };

    const pixels = try decodeRgba(std.testing.allocator, &png);
    defer std.testing.allocator.free(pixels.rgba);

    try std.testing.expectEqual(@as(u32, 1), pixels.w);
    try std.testing.expectEqual(@as(u32, 1), pixels.h);
    try std.testing.expectEqual(@as(usize, 4), pixels.rgba.len);
}
