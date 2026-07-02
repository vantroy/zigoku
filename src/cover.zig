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

// libwebp decoder (ROD-244). AllAnime cover art is WebP served under a .png/.jpg
// extension, which stb_image cannot decode. WebPDecodeRGBA handles every WebP
// flavor — lossy VP8, lossless VP8L, and the extended VP8X container with its
// ALPH alpha plane — and hands back a freshly malloc'd RGBA buffer that we must
// return to WebPFree. WebPGetInfo reads dimensions without decoding pixels.
extern fn WebPDecodeRGBA(data: [*c]const u8, data_size: usize, width: [*c]c_int, height: [*c]c_int) ?[*]u8;
extern fn WebPGetInfo(data: [*c]const u8, data_size: usize, width: [*c]c_int, height: [*c]c_int) c_int;
extern fn WebPFree(ptr: ?*anyopaque) void;

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
    return probePngDimensions(encoded) orelse
        probeJpegDimensions(encoded) orelse
        probeWebpDimensions(encoded);
}

/// A RIFF/WEBP container? Covers arrive WebP-under-a-lie (the mcovers CDN serves
/// WebP whatever the extension claims), so both routing and probing sniff the
/// leading bytes and never trust the filename.
pub fn isWebp(encoded: []const u8) bool {
    return encoded.len >= 12 and
        std.mem.eql(u8, encoded[0..4], "RIFF") and
        std.mem.eql(u8, encoded[8..12], "WEBP");
}

pub fn decodeRgba(alloc: Allocator, encoded: []const u8) !Pixels {
    if (encoded.len == 0) return error.DecodeFailed;

    if (isWebp(encoded)) {
        var w: c_int = 0;
        var h: c_int = 0;
        const ptr = WebPDecodeRGBA(encoded.ptr, encoded.len, &w, &h) orelse
            return error.DecodeFailed;
        defer WebPFree(@ptrCast(ptr));
        return ownRgba(alloc, ptr, w, h);
    }

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
    return ownRgba(alloc, ptr, w, h);
}

// Copy a C decoder's RGBA output into an allocator-owned slice, validating the
// reported dimensions and guarding the size math. Shared by the stb and libwebp
// paths; the caller still owns freeing the C buffer.
fn ownRgba(alloc: Allocator, src: [*]const u8, w: c_int, h: c_int) !Pixels {
    if (w <= 0 or h <= 0) return error.DecodeFailed;
    const width: u32 = @intCast(w);
    const height: u32 = @intCast(h);
    const pixel_count = std.math.mul(usize, width, height) catch return error.DecodeFailed;
    const rgba_len = std.math.mul(usize, pixel_count, 4) catch return error.DecodeFailed;

    const rgba = try alloc.alloc(u8, rgba_len);
    @memcpy(rgba, src[0..rgba_len]);
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

// WebP dimensions come from libwebp itself (WebPGetInfo), which understands all
// three sub-formats' headers (VP8, VP8L, VP8X) without decoding pixels — far
// safer than hand-parsing the RIFF chunk layout ourselves.
fn probeWebpDimensions(encoded: []const u8) ?Dimensions {
    if (!isWebp(encoded)) return null;
    var w: c_int = 0;
    var h: c_int = 0;
    if (WebPGetInfo(encoded.ptr, encoded.len, &w, &h) == 0) return null;
    if (w <= 0 or h <= 0) return null;
    return .{ .w = @intCast(w), .h = @intCast(h) };
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

// ── WebP fixtures (ROD-244) ──────────────────────────────────────────────────
// Tiny 2×2 images encoded by libwebp, one per sub-format, so every decode path
// is exercised in-suite: VP8L lossless, VP8 lossy, and the VP8X container
// carrying an ALPH alpha plane over VP8. Row-major source pixels are
// (200,10,10) (10,200,10) / (10,10,200) (240,240,240); the alpha fixture drops
// the last pixel's alpha to 0x80.
const webp_lossless = [_]u8{
    0x52, 0x49, 0x46, 0x46, 0x3c, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50,
    0x56, 0x50, 0x38, 0x4c, 0x2f, 0x00, 0x00, 0x00, 0x2f, 0x01, 0x40, 0x00,
    0x00, 0x1f, 0x20, 0x10, 0x20, 0xb4, 0xf9, 0x0f, 0x90, 0x21, 0x47, 0x20,
    0x40, 0x7c, 0xc8, 0x11, 0xae, 0x49, 0x82, 0x40, 0x80, 0xd0, 0xe1, 0xbf,
    0x43, 0x93, 0x84, 0xf9, 0x8f, 0x7f, 0xc8, 0x80, 0x81, 0x82, 0xb4, 0x0d,
    0x58, 0xd4, 0xdd, 0x88, 0xfe, 0xc7, 0x03, 0x00,
};

const webp_lossy = [_]u8{
    0x52, 0x49, 0x46, 0x46, 0x40, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50,
    0x56, 0x50, 0x38, 0x20, 0x34, 0x00, 0x00, 0x00, 0x90, 0x01, 0x00, 0x9d,
    0x01, 0x2a, 0x02, 0x00, 0x02, 0x00, 0x00, 0xc0, 0x12, 0x25, 0xa4, 0x00,
    0x02, 0xe7, 0x4b, 0x2d, 0x00, 0x00, 0xfe, 0xf9, 0x09, 0xff, 0xda, 0xc3,
    0xd5, 0x7f, 0xcd, 0x7e, 0xa9, 0xfe, 0xb4, 0xff, 0xff, 0x18, 0xbc, 0x99,
    0x93, 0x2f, 0x34, 0x2a, 0xd3, 0x7c, 0xec, 0x11, 0x00, 0x00, 0x00, 0x00,
};

const webp_lossy_alpha = [_]u8{
    0x52, 0x49, 0x46, 0x46, 0x60, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50,
    0x56, 0x50, 0x38, 0x58, 0x0a, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x41, 0x4c, 0x50, 0x48, 0x05, 0x00,
    0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0x80, 0x00, 0x56, 0x50, 0x38, 0x20,
    0x34, 0x00, 0x00, 0x00, 0x90, 0x01, 0x00, 0x9d, 0x01, 0x2a, 0x02, 0x00,
    0x02, 0x00, 0x00, 0xc0, 0x12, 0x25, 0xa4, 0x00, 0x02, 0xe7, 0x4b, 0x2d,
    0x00, 0x00, 0xfe, 0xf9, 0x09, 0xff, 0xda, 0xc3, 0xd5, 0x7f, 0xcd, 0x7e,
    0xa9, 0xfe, 0xb4, 0xff, 0xff, 0x18, 0xbc, 0x99, 0x93, 0x2f, 0x34, 0x2a,
    0xd3, 0x7c, 0xec, 0x11, 0x00, 0x00, 0x00, 0x00,
};

test "isWebp sniffs RIFF/WEBP containers by bytes" {
    try std.testing.expect(isWebp(&webp_lossless));
    try std.testing.expect(isWebp(&webp_lossy));
    try std.testing.expect(isWebp(&webp_lossy_alpha));
    // PNG signature is not WebP.
    try std.testing.expect(!isWebp(&[_]u8{ 0x89, 'P', 'N', 'G', 0, 0, 0, 0, 0, 0, 0, 0 }));
    // A RIFF container that isn't WEBP (e.g. WAVE audio) must not match.
    try std.testing.expect(!isWebp("RIFF\x00\x00\x00\x00WAVEfmt "));
    // Too short to hold both fourccs.
    try std.testing.expect(!isWebp("RIFF"));
}

test "probeDimensions reads webp dimensions across sub-formats" {
    inline for (.{ &webp_lossless, &webp_lossy, &webp_lossy_alpha }) |fx| {
        const dims = probeDimensions(fx) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u32, 2), dims.w);
        try std.testing.expectEqual(@as(u32, 2), dims.h);
    }
}

test "decodeRgba decodes lossless webp exactly" {
    const px = try decodeRgba(std.testing.allocator, &webp_lossless);
    defer std.testing.allocator.free(px.rgba);

    try std.testing.expectEqual(@as(u32, 2), px.w);
    try std.testing.expectEqual(@as(u32, 2), px.h);
    // Lossless round-trips the source pixels byte-for-byte; alpha fills to 255.
    const want = [_]u8{
        200, 10, 10,  255, 10,  200, 10,  255,
        10,  10, 200, 255, 240, 240, 240, 255,
    };
    try std.testing.expectEqualSlices(u8, &want, px.rgba);
}

test "decodeRgba decodes lossy webp to opaque rgba" {
    const px = try decodeRgba(std.testing.allocator, &webp_lossy);
    defer std.testing.allocator.free(px.rgba);

    try std.testing.expectEqual(@as(u32, 2), px.w);
    try std.testing.expectEqual(@as(u32, 2), px.h);
    try std.testing.expectEqual(@as(usize, 16), px.rgba.len);
    // No alpha in the source → every pixel decodes fully opaque. (Lossy RGB is
    // approximate, so we assert on the alpha channel, not the colors.)
    var i: usize = 3;
    while (i < px.rgba.len) : (i += 4) {
        try std.testing.expectEqual(@as(u8, 255), px.rgba[i]);
    }
}

test "decodeRgba decodes lossy webp carrying an alpha plane" {
    const px = try decodeRgba(std.testing.allocator, &webp_lossy_alpha);
    defer std.testing.allocator.free(px.rgba);

    try std.testing.expectEqual(@as(u32, 2), px.w);
    try std.testing.expectEqual(@as(u32, 2), px.h);
    try std.testing.expectEqual(@as(usize, 16), px.rgba.len);
    // The ALPH plane is stored losslessly, so alpha survives exactly: three
    // opaque pixels then the 0x80 set on the last one.
    try std.testing.expectEqual(@as(u8, 255), px.rgba[3]);
    try std.testing.expectEqual(@as(u8, 255), px.rgba[7]);
    try std.testing.expectEqual(@as(u8, 255), px.rgba[11]);
    try std.testing.expectEqual(@as(u8, 0x80), px.rgba[15]);
}
