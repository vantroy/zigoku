const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const zigimg = @import("zigimg");

const Allocator = std.mem.Allocator;

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
    // Zig 0.16 currently blows up codegenning the exe in Debug mode when this
    // decode path is live. Keep Debug builds usable by degrading to the existing
    // no-art state there; ReleaseSafe/ReleaseFast carry the real cover pipeline.
    if (builtin.mode == .Debug) return error.DecodeUnavailableInDebug;
    if (encoded.len == 0) return error.DecodeFailed;

    var img = zigimg.Image.fromMemory(alloc, encoded) catch return error.DecodeFailed;
    defer img.deinit(alloc);

    img.convert(alloc, .rgba32) catch return error.DecodeFailed;
    const rgba = try alloc.dupe(u8, img.rawBytes());
    return .{
        .rgba = rgba,
        .w = @intCast(img.width),
        .h = @intCast(img.height),
    };
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
